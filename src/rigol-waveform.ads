-- ***************************************************************************
--                      Rigol - Waveform Commands Specification
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

--  :WAVeform command group.
--  Retrieves raw sample data from the oscilloscope and converts it to
--  engineering values using the preamble scaling parameters.
--
--  Typical usage:
--    Rigol.Waveform.Set_Source (Scope, 1);
--    Rigol.Waveform.Set_Mode   (Scope, Normal);
--    Rigol.Waveform.Set_Format (Scope, Byte);
--    declare
--       Pre  : constant Preamble := Rigol.Waveform.Get_Preamble (Scope);
--       Data : constant Sample_Array := Rigol.Waveform.Get_Data (Scope, Pre);
--    begin
--       ...
--    end;

with Rigol.Channel;

package Rigol.Waveform is

   type Waveform_Format is (Byte, Word, ASCII_Fmt);
   --  BYTE = 8-bit unsigned, WORD = 16-bit unsigned, ASCii = comma-separated

   type Waveform_Mode is (Normal, Maximum, Raw);
   --  NORMal = screen samples, MAXimum = max stored, RAW = internal memory

   --  Scaling / meta-data returned by :WAVeform:PREamble?
   type Preamble is record
      Format      : Waveform_Format;
      Mode        : Waveform_Mode;
      Points      : Natural;    --  number of data points (0: nothing acquired)
      Count       : Natural;    --  number of averages
      X_Increment : Float;      --  time between samples (s)
      X_Origin    : Float;      --  time of first sample (s)
      X_Reference : Float;      --  reference sample index
      Y_Increment : Float;      --  voltage per ADC count
      Y_Origin    : Float;      --  voltage at ADC zero
      Y_Reference : Float;      --  ADC count at voltage origin
   end record;

   --  Array of voltage samples (converted from raw ADC counts)
   type Sample_Array is array (Positive range <>) of Float;

   --  For memory reads: up to 24M points, too large for the stack
   type Sample_Array_Access is access Sample_Array;
   procedure Free (Data : in out Sample_Array_Access);

   --  Most points one :WAVeform:DATA? may return from internal memory in
   --  BYTE format (programming guide, :WAVeform:DATA?)
   Max_Raw_Batch : constant := 250_000;

   --  Samples as the scope sends them: 8-bit ADC counts, scaled to volts
   --  by the preamble (see Volts).  A quarter the size of Sample_Array.
   type Raw_Sample is mod 2**8;
   type Raw_Array is array (Positive range <>) of Raw_Sample;
   type Raw_Array_Access is access Raw_Array;
   procedure Free (Data : in out Raw_Array_Access);

   function Volts (Pre : Preamble; Raw : Raw_Sample) return Float is
     ((Float (Raw) - Pre.Y_Reference - Pre.Y_Origin) * Pre.Y_Increment);


   -- -------------------------------------------------------------------------

   --  :WAVeform:SOURce CHAN<n>
   procedure Set_Source
     (Scope   : in out Oscilloscope;
      Channel : in     Rigol.Channel.Channel_Number);

   --  :WAVeform:MODE NORMal | MAXimum | RAW
   procedure Set_Mode
     (Scope : in out Oscilloscope;
      Mode  : in     Waveform_Mode);

   --  :WAVeform:FORMat BYTE | WORD | ASCii
   procedure Set_Format
     (Scope  : in out Oscilloscope;
      Format : in     Waveform_Format);

   --  :WAVeform:STARt - first point to transfer (1-based)
   procedure Set_Start
     (Scope : in out Oscilloscope;
      Point : in     Positive);

   --  :WAVeform:STOP - last point to transfer
   procedure Set_Stop
     (Scope : in out Oscilloscope;
      Point : in     Positive);

   -- -------------------------------------------------------------------------

   --  :WAVeform:PREamble? - retrieve and parse the scaling preamble
   function Get_Preamble
     (Scope : in out Oscilloscope) return Preamble;

   --  :WAVeform:DATA? - retrieve waveform data and convert to volts.
   --  The Preamble (obtained from Get_Preamble) provides the scaling and
   --  the sample format.  Returns the samples the scope sent, at most
   --  Pre.Points of them.  In RAW mode a single call is limited to
   --  Max_Raw_Batch points; Read_Memory handles the batching.
   function Get_Data
     (Scope : in out Oscilloscope;
      Pre   : in     Preamble) return Sample_Array;

   -- -------------------------------------------------------------------------

   --  Convenience: configure source/mode/format, read preamble + data in one
   --  call.  Format is always Byte for efficiency.
   function Capture
     (Scope   : in out Oscilloscope;
      Channel : in     Rigol.Channel.Channel_Number;
      Mode    : in     Waveform_Mode := Normal) return Sample_Array;

   --  Read the whole acquisition memory of Channel (RAW mode): stops the
   --  scope, reads it in batches of Max_Raw_Batch points and returns all
   --  samples in volts, with the preamble that scales them.  Pre.Points
   --  is the memory depth (up to 24M points).  The scope is left stopped.
   --  The caller owns Data and releases it with Free.  Progress, if
   --  given, is called after each batch.
   procedure Read_Memory
     (Scope    : in out Oscilloscope;
      Channel  : in     Rigol.Channel.Channel_Number;
      Pre      :    out Preamble;
      Data     :    out Sample_Array_Access;
      Progress : access procedure (Done, Total : Natural) := null);

   --  As Read_Memory, keeping the raw samples
   procedure Read_Memory_Raw
     (Scope    : in out Oscilloscope;
      Channel  : in     Rigol.Channel.Channel_Number;
      Pre      :    out Preamble;
      Data     :    out Raw_Array_Access;
      Progress : access procedure (Done, Total : Natural) := null);

   --  Points in a NORMal-mode (screen) read on the DS1000Z-E
   Screen_Points : constant := 1200;

   --  Set up :WAVeform:DATA? to read Channel's screen waveform: source,
   --  NORMal mode, BYTE format and the full 1 .. Screen_Points range (a
   --  memory read leaves STARt/STOP elsewhere).  Queries right after this
   --  wait ~50 ms per changed setting while the scope applies it, so a
   --  loop reading one channel should prepare once, not per read.
   procedure Prepare_Screen_Read
     (Scope   : in out Oscilloscope;
      Channel : in     Rigol.Channel.Channel_Number);

   --  The same for the math channel (see Rigol.Math); only screen data
   --  can be read from it
   procedure Prepare_Math_Read (Scope : in out Oscilloscope);

   --  Select the math channel as source, the rest as prepared before
   procedure Set_Source_Math (Scope : in out Oscilloscope);

   --  The screen waveform as prepared by Prepare_Screen_Read, as raw
   --  samples with its preamble.  About 3 ms over USB.
   function Read_Prepared_Screen
     (Scope : in out Oscilloscope;
      Pre   :    out Preamble) return Raw_Array;

   --  Prepare_Screen_Read, then Read_Prepared_Screen
   function Read_Screen_Raw
     (Scope   : in out Oscilloscope;
      Channel : in     Rigol.Channel.Channel_Number;
      Pre     :    out Preamble) return Raw_Array;

   --  Return the time value corresponding to sample index I,
   --  given the preamble.
   function Sample_Time (Pre : Preamble; I : Positive) return Float;

end Rigol.Waveform;
