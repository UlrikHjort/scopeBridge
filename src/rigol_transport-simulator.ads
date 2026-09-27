-- ***************************************************************************
--                      Rigol - Simulated Oscilloscope Transport Specification
--
--           Copyright (C) 2026 By Ulrik Hørlyk Hjort
--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
-- NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
-- LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
-- OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
-- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-- ***************************************************************************

--  A transport that is a simulated DS1202Z-E, for developing and testing
--  programs without an instrument (rigol_server --sim).
--
--  It understands the SCPI this library sends, keeps the settings it is
--  given (channels, timebase, trigger, run/stop) and answers queries the
--  way the real scope does, including the formats of its replies:
--
--  - CH1 carries a 1 kHz, 0 .. 3 V square wave, like the probe
--    compensation output; CH2 a 1 kHz, 2 Vpp sine.  Both have a little
--    noise, and the screen waveform drifts while running, so a live view
--    visibly updates.
--  - Screen data (NORMal) is 1200 points over the 12 divisions; memory
--    (RAW) is 1.2M points, readable in batches via :WAVeform:STARt/STOP.
--  - Measurements are the signals' nominal values, or 9.9E37 for a
--    channel that is not displayed.
--  - :DISPlay:DATA? returns a 24-bit BMP of the traces.
--  - The math channel computes A+B, A-B, A*B, A/B of the two signals, or
--    an FFT with the scope's frequency axis (see Rigol.Math): peaks at
--    the square's odd harmonics or at the sine's frequency.  Like the
--    scope, it reads as 0 points for a moment after the operator changes.
--  - :SYSTem:SETup? returns the settings as a block (text, unlike the
--    scope's binary one).  :SYSTem:SETup restores only the timebase from
--    it, as the DS1202Z-E restores only some settings from its own.
--  - :ACQuire:TYPE, :AVERages and :MDEPth are kept; averaging lowers the
--    noise, and memory reads have the depth chosen.  Like the scope, a
--    depth not offered for the channels on, or set while stopped, is
--    ignored, and a depth follows when the number of channels on changes.
--  - The pass/fail test (:MASK) counts a frame per screen read while it
--    runs; a frame fails while the source channel's offset differs from
--    what it was when the mask was created.
--  - A query it does not know gets no reply: Query raises
--    Communication_Error, as a timeout on the real scope would.
--
--  One command is the simulator's own, for testing bus decoders:
--  ":SIMulator:SIGNal UART|IIC|SPI|TIMing|NORMal" puts serial traffic, or
--  timing markers (0 .. 3.3 V), on the channels instead of the square and
--  sine:
--
--  - UART: CH1 (TX) sends "Hello, Rigol!" CR LF and CH2 (RX) "OK" CR LF,
--    at 115200 baud, 8N1, every 2 ms.
--  - IIC: CH1 is SCL, CH2 SDA, at 100 kHz, every 1 ms, as the Arduino
--    example i2c.c sends: a write of 00 10 to address 50h, then 00
--    written, a repeated start and a read of A5 3C (the last not
--    acknowledged).
--  - SPI: CH1 is the clock (idle low, data valid on the rising edge),
--    CH2 the data, at 1 MHz, most significant bit first: 9F EF 40 18
--    every 100 us.
--  - TIMing: pins marking code for timing it.  CH1 is high while a block
--    runs, every 1 ms: 200 us plus 2 us for each of k mod 5 (k counting
--    the runs), and 150 us more when k mod 7 = 3.  CH2 marks the
--    iterations of a loop in it: 8 (12 in the slow runs) pulses of 10 us,
--    5 us apart, the first 20 + 5 * (k mod 3) us after the block starts.

package Rigol_Transport.Simulator is

   type Handle is new Rigol_Transport.Handle with private;

   procedure Open (T : out Handle);

   overriding procedure Send
     (T       : in out Handle;
      Command : in     String);

   overriding function Query
     (T       : in out Handle;
      Command : in     String) return String;

   overriding procedure Close   (T : in out Handle);
   overriding function  Is_Open (T :        Handle) return Boolean;

   --  Memory depth of the simulated acquisition when it is AUTO; the
   --  depths of :ACQuire:MDEPth are simulated too
   Memory_Depth : constant := 1_200_000;

private

   type Channel_State is record
      Display  : Boolean := False;
      Scale    : Float   := 1.0;    --  V/div
      Offset   : Float   := 0.0;    --  V
      Coupling : String (1 .. 3) := "DC ";
      Probe    : Float   := 10.0;
   end record;

   type Channel_States is array (1 .. 2) of Channel_State;

   type Signal_Kind is (Normal, UART, I2C, SPI, Timing);

   --  Everything *RST puts back to its initial value
   type Scope_State is record
      Running      : Boolean := True;
      Channels     : Channel_States :=
        (1 => (Display => True, others => <>), 2 => (others => <>));
      TB_Scale     : Float := 1.0E-3;   --  s/div
      TB_Offset    : Float := 0.0;
      TB_Mode      : String (1 .. 4) := "MAIN";   --  MAIN, XY, ROLL
      Trig_Source  : Positive := 1;     --  1, 2 = CH1, CH2; 3 = ACL; 4 = EXT
      Trig_Slope   : String (1 .. 4) := "POS ";
      Trig_Level   : Float := 1.5;
      Trig_Sweep   : String (1 .. 4) := "AUTO";
      Trig_Mode    : String (1 .. 4) := "EDGE";   --  EDGE, PULS, SLOP

      Pulse_Source : Positive := 1;
      Pulse_When   : String (1 .. 4) := "PGR ";
      Pulse_Width  : Float    := 1.0E-6;
      Pulse_Upper  : Float    := 2.0E-6;
      Pulse_Lower  : Float    := 1.0E-6;
      Pulse_Level  : Float    := 0.0;
      Slope_Source : Positive := 1;
      Slope_When   : String (1 .. 4) := "PGR ";
      Slope_Time   : Float    := 1.0E-6;
      Slope_Upper  : Float    := 2.0E-6;
      Slope_Lower  : Float    := 1.0E-6;
      Slope_Window : String (1 .. 3) := "TA ";
      Slope_Level_A : Float   := 2.0;
      Slope_Level_B : Float   := 0.0;
      Wav_Source   : Positive := 1;
      Wav_Math     : Boolean  := False;    --  :WAVeform:SOURce MATH

      Math_Display : Boolean  := False;
      Math_Op      : String (1 .. 4) := "ADD ";   --  ADD, SUBT, MULT, DIV, FFT
      Math_Src1    : Positive := 1;
      Math_Src2    : Positive := 2;
      Math_Scale   : Float    := 1.0;
      Math_Offset  : Float    := 0.0;
      FFT_Src      : Positive := 1;
      FFT_Window   : String (1 .. 4) := "RECT";
      FFT_Unit     : String (1 .. 4) := "DB  ";
      FFT_Mode     : String (1 .. 4) := "TRAC";
      FFT_HScale   : Float    := 5000.0;   --  Hz/div
      FFT_HCenter  : Float    := 25000.0;  --  Hz
      Math_Settling : Natural := 0;        --  data reads left with no data
      Wav_Raw      : Boolean  := False;
      Wav_Start    : Positive := 1;
      Wav_Stop     : Positive := 1200;
      Acquisition  : Natural  := 0;     --  counts screen reads while running;
                                        --  seeds the noise, so a stopped
                                        --  scope shows a frozen trace
      Mask_Enable  : Boolean  := False;
      Mask_Running : Boolean  := False;
      Mask_Source  : Positive := 1;
      Mask_X       : Float    := 0.02;
      Mask_Y       : Float    := 0.96;
      Mask_Stats   : Boolean  := False;
      Mask_Stop    : Boolean  := False;   --  stop on fail
      Mask_Beep    : Boolean  := False;
      Mask_Offset  : Float    := 0.0;     --  the source's offset at :CREate
      Mask_Passed  : Natural  := 0;
      Mask_Failed  : Natural  := 0;
      Signal       : Signal_Kind := Normal;
      Acq_Type     : String (1 .. 4) := "NORM";   --  NORM, AVER, PEAK, HRES
      Averages     : Positive := 2;
      Mem_Depth    : Natural  := 0;               --  0 = AUTO
   end record;

   type Handle is new Rigol_Transport.Handle with record
      Opened : Boolean := False;
      State  : Scope_State;
   end record;

end Rigol_Transport.Simulator;
