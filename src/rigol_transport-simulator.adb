-- ***************************************************************************
--                      Rigol - Simulated Oscilloscope Transport Body
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

with Ada.Characters.Handling;          use Ada.Characters.Handling;
with Ada.Float_Text_IO;
with Ada.Numerics;
with Ada.Numerics.Elementary_Functions; use Ada.Numerics.Elementary_Functions;
with Ada.Numerics.Float_Random;
with Ada.Strings.Fixed;                 use Ada.Strings.Fixed;

package body Rigol_Transport.Simulator is

   Screen_Points : constant := 1200;
   Max_Batch     : constant := 250_000;
   Invalid       : constant String := "9.9E37";

   -- -------------------------------------------------------------------------
   --  Formatting and parsing
   -- -------------------------------------------------------------------------

   --  The scope's number format: 1.500000e+00
   function Sci (X : Float) return String is
      Buf : String (1 .. 20);
   begin
      Ada.Float_Text_IO.Put (Buf, X, Aft => 6, Exp => 2);
      return To_Lower (Trim (Buf, Ada.Strings.Both));
   end Sci;

   function Int (N : Integer) return String is
     (Trim (Integer'Image (N), Ada.Strings.Left));

   --  SCPI mnemonics in their short form: ":CHANnel1:SCALe?" becomes
   --  ":CHAN1:SCAL?", "POSitive" becomes "POS".  Numbers are left alone
   --  by only applying this to headers and enumerated arguments.
   function Short (S : String) return String is
      Result : String (1 .. S'Length);
      Last   : Natural := 0;
   begin
      for C of S loop
         if Is_Upper (C) or else Is_Digit (C) or else C in ':' | '*' | '?' | ','
         then
            Last := Last + 1;
            Result (Last) := C;
         end if;
      end loop;
      return Result (1 .. Last);
   end Short;

   function Header_Of (Command : String) return String is
      Space : constant Natural := Index (Command, " ");
   begin
      return Short (if Space = 0 then Command
                    else Command (Command'First .. Space - 1));
   end Header_Of;

   function Args_Of (Command : String) return String is
      Space : constant Natural := Index (Command, " ");
   begin
      return (if Space = 0 then ""
              else Trim (Command (Space + 1 .. Command'Last), Ada.Strings.Both));
   end Args_Of;

   function To_Bool (Arg : String) return Boolean is
     (Arg = "1" or else Short (Arg) = "ON");

   --  Channel number in ":CHANn..." or "CHANn", 0 if none
   function Channel_Of (S : String) return Natural is
      P : constant Natural := Index (S, "CHAN");
   begin
      if P = 0 or else P + 4 > S'Last or else S (P + 4) not in '1' .. '2' then
         return 0;
      end if;
      return Character'Pos (S (P + 4)) - Character'Pos ('0');
   end Channel_Of;

   function Block (Data : String) return String is
      Len : constant String := Int (Data'Length);
   begin
      return "#9" & (1 .. 9 - Len'Length => '0') & Len & Data;
   end Block;

   -- -------------------------------------------------------------------------
   --  Signals
   -- -------------------------------------------------------------------------

   Logic_High : constant := 3.3;   --  V, of the serial signals

   --  Position of Time within repeats of Period: 0 .. Period (rounding
   --  may give a hair below 0 otherwise)
   function Phase (Time, Period : Float) return Float is
     (Float'Max (0.0, Time - Period * Float'Floor (Time / Period)));

   --  UART, 8N1: the line level Time seconds after Text started
   function UART_Line (Text : String; Time : Float) return Boolean is
      Bit_Time : constant Float := 1.0 / 115_200.0;
      Bit      : constant Integer := Integer (Float'Floor (Time / Bit_Time));
   begin
      if Time < 0.0 or else Bit >= 10 * Text'Length then
         return True;                     --  idle
      end if;
      declare
         Code : constant Natural :=
           Character'Pos (Text (Text'First + Bit / 10));
         K    : constant Natural := Bit mod 10;
      begin
         return (if K = 0 then False                       --  start bit
                 elsif K = 9 then True                     --  stop bit
                 else Code / 2**(K - 1) mod 2 = 1);        --  LSB first
      end;
   end UART_Line;

   --  I2C traffic as 10 us slots: S start, P stop, 0 and 1 data bits
   --  (the acknowledge included), I idle
   function Bits (Byte : Natural; Ack : Character) return String is
      Result : String (1 .. 9);
   begin
      for K in 1 .. 8 loop
         Result (K) := (if Byte / 2**(8 - K) mod 2 = 1 then '1' else '0');
      end loop;
      Result (9) := Ack;
      return Result;
   end Bits;

   --  As examples/arduino/i2c.c sends: a write of 10 to register 00, then
   --  a read of two bytes from 00, the register address written first and
   --  the read after a repeated start
   I2C_Slots : constant String :=
     "IIS" & Bits (16#A0#, '0') & Bits (16#00#, '0') & Bits (16#10#, '0') &
     "PIIIIIS" & Bits (16#A0#, '0') & Bits (16#00#, '0') &
     "S" & Bits (16#A1#, '0') & Bits (16#A5#, '0') & Bits (16#3C#, '1') & "PII";

   --  SCL and SDA of a slot, at Frac (0 .. 1) of it: data changes while
   --  SCL is low, a start is SDA falling and a stop SDA rising while SCL
   --  is high
   procedure I2C_Lines (Slot : Character; Frac : Float; SCL, SDA : out Boolean)
   is
   begin
      case Slot is
         when 'S' =>
            SCL := Frac in 0.25 .. 0.75;
            SDA := Frac < 0.5;
         when 'P' =>
            SCL := Frac >= 0.25;
            SDA := Frac >= 0.5;
         when '0' | '1' =>
            SCL := Frac in 0.25 .. 0.75;
            SDA := Slot = '1';
         when others =>
            SCL := True;
            SDA := True;
      end case;
   end I2C_Lines;

   SPI_Bytes : constant array (1 .. 4) of Natural := (16#9F#, 16#EF#, 16#40#, 16#18#);

   function Serial_Signal (Kind : Signal_Kind; Channel : Positive; Time : Float)
                           return Float
   is
      function Level (High : Boolean) return Float is
        (if High then Logic_High else 0.0);
   begin
      case Kind is
         when UART =>
            return Level
              (if Channel = 1
               then UART_Line ("Hello, Rigol!" & ASCII.CR & ASCII.LF,
                               Phase (Time, 2.0E-3) - 1.0E-4)
               else UART_Line ("OK" & ASCII.CR & ASCII.LF,
                               Phase (Time, 2.0E-3) - 1.5E-3));
         when I2C =>
            declare
               Slot_Time : constant Float := 1.0E-5;
               P         : constant Float := Phase (Time, 1.0E-3) / Slot_Time;
               N         : constant Natural := Natural (Float'Floor (P));
               SCL, SDA  : Boolean;
            begin
               I2C_Lines ((if N < I2C_Slots'Length
                           then I2C_Slots (I2C_Slots'First + N) else 'I'),
                          P - Float (N), SCL, SDA);
               return Level (if Channel = 1 then SCL else SDA);
            end;
         when SPI =>
            declare
               P : constant Float := Phase (Time, 1.0E-4) / 1.0E-6;   --  in bits
               N : constant Natural := Natural (Float'Floor (P));
            begin
               if N >= 8 * SPI_Bytes'Length then
                  return 0.0;                --  idle: both low
               elsif Channel = 1 then
                  return Level (P - Float (N) >= 0.5);
               else
                  return Level
                    (SPI_Bytes (1 + N / 8) / 2**(7 - N mod 8) mod 2 = 1);
               end if;
            end;
         when Timing =>
            declare
               Run    : constant Integer := Integer (Float'Floor (Time / 1.0E-3));
               P      : constant Float := Phase (Time, 1.0E-3) - 1.0E-4;   --  from the block's start
               Slow   : constant Boolean := Run mod 7 = 3;
               Block  : constant Float :=
                 2.0E-4 + 2.0E-6 * Float (Run mod 5) + (if Slow then 1.5E-4 else 0.0);
               Loop_P : constant Float := P - (2.0E-5 + 5.0E-6 * Float (Run mod 3));
               N      : constant Integer := Integer (Float'Floor (Loop_P / 1.5E-5));
            begin
               if Channel = 1 then
                  return Level (P >= 0.0 and then P < Block);
               end if;
               return Level (Loop_P >= 0.0 and then N < (if Slow then 12 else 8)
                             and then Loop_P - 1.5E-5 * Float (N) < 1.0E-5);
            end;
         when Normal =>
            return 0.0;
      end case;
   end Serial_Signal;

   --  Noise-free signal of Channel at time Time (s)
   function Signal (T : Handle; Channel : Positive; Time : Float) return Float is
      Cycles : constant Float := Time * 1000.0;
      Frac   : constant Float := Cycles - Float'Floor (Cycles);
   begin
      if T.State.Signal /= Normal then
         return Serial_Signal (T.State.Signal, Channel, Time);
      elsif Channel = 1 then
         return (if Frac < 0.5 then 3.0 else 0.0);
      else
         return Sin (2.0 * Ada.Numerics.Pi * Frac);
      end if;
   end Signal;

   Noise_Amplitude : constant := 0.02;   --  V, peak

   --  Averaging N frames lowers random noise by sqrt N
   function Noise (T : Handle) return Float is
     (if T.State.Acq_Type = "AVER"
      then Noise_Amplitude / Sqrt (Float (T.State.Averages))
      else Noise_Amplitude);

   Single_Depths : constant array (1 .. 5) of Positive :=
     (12_000, 120_000, 1_200_000, 12_000_000, 24_000_000);
   Dual_Depths   : constant array (1 .. 5) of Positive :=
     (6_000, 60_000, 600_000, 6_000_000, 12_000_000);

   function Dual (T : Handle) return Boolean is
     (T.State.Channels (1).Display and then T.State.Channels (2).Display);

   --  Points in memory
   function Depth (T : Handle) return Positive is
     (if T.State.Mem_Depth = 0 then Memory_Depth else T.State.Mem_Depth);

   --  Vertical scaling as the scope reports it in the preamble:
   --  volts = (raw - 127 - y_origin) * y_inc
   function Y_Inc (T : Handle; Ch : Positive) return Float is
     (T.State.Channels (Ch).Scale / 25.0);

   function Y_Origin (T : Handle; Ch : Positive) return Integer is
     (Integer (T.State.Channels (Ch).Offset / Y_Inc (T, Ch)));

   function To_Raw (T : Handle; Ch : Positive; Volts : Float) return Character
   is
      Counts : constant Float :=
        Volts / Y_Inc (T, Ch) + 127.0 + Float (Y_Origin (T, Ch));
   begin
      return Character'Val
        (Integer (Float'Max (0.0, Float'Min (255.0, Counts))));
   end To_Raw;

   --  Raw samples First .. Last of an acquisition of Points points over
   --  the 12 screen divisions
   function Samples
     (T : Handle; Ch : Positive; Points, First, Last : Positive) return String
   is
      use Ada.Numerics.Float_Random;
      Gen    : Generator;
      X_Inc  : constant Float := 12.0 * T.State.TB_Scale / Float (Points);
      X_Orig : constant Float := T.State.TB_Offset - 6.0 * T.State.TB_Scale;
      Result : String (First .. Last);
   begin
      Reset (Gen, T.State.Acquisition * 2 + Ch);
      for I in Result'Range loop
         Result (I) := To_Raw
           (T, Ch,
            Signal (T, Ch, X_Orig + Float (I - 1) * X_Inc) +
            Noise (T) * (2.0 * Random (Gen) - 1.0));
      end loop;
      return Result;
   end Samples;

   -- -------------------------------------------------------------------------
   --  Math channel
   -- -------------------------------------------------------------------------

   function Math_Op (T : Handle) return String is
     (Trim (T.State.Math_Op, Ada.Strings.Right));

   --  RMS level of the Harmonic'th harmonic of channel Ch's signal (0 = DC)
   function Harmonic_RMS (Ch : Positive; Harmonic : Natural) return Float is
   begin
      if Ch = 1 then
         if Harmonic = 0 then
            return 1.5;
         elsif Harmonic mod 2 = 1 then
            --  Square wave 0 .. 3 V: 4/pi * 1.5 / n peak
            return 4.0 / Ada.Numerics.Pi * 1.5 / Float (Harmonic) / Sqrt (2.0);
         end if;
      elsif Harmonic = 1 then
         return 1.0 / Sqrt (2.0);
      end if;
      return 0.0;
   end Harmonic_RMS;

   --  First and last frequency sent, per the scope: the screen from
   --  max (0, left edge) to the right edge
   procedure FFT_Axis (T : Handle; Left, First_F, X_Inc : out Float;
                       Points : out Natural) is
   begin
      Left    := T.State.FFT_HCenter - 6.0 * T.State.FFT_HScale;
      First_F := Float'Max (0.0, Left);
      X_Inc   := 12.0 * T.State.FFT_HScale / Float (Screen_Points);
      Points  := Natural'Min
        (Screen_Points,
         Natural ((T.State.FFT_HCenter + 6.0 * T.State.FFT_HScale - First_F) / X_Inc));
   end FFT_Axis;

   function Math_Ready (T : Handle) return Boolean is
     (T.State.Math_Display and then T.State.Math_Settling = 0);

   function Math_Points (T : Handle) return Natural is
      Left, First_F, X_Inc : Float;
      Points : Natural;
   begin
      if not Math_Ready (T) then
         return 0;
      elsif Math_Op (T) = "FFT" then
         FFT_Axis (T, Left, First_F, X_Inc, Points);
         return Points;
      end if;
      return Screen_Points;
   end Math_Points;

   function Math_Y_Inc (T : Handle) return Float is (T.State.Math_Scale / 25.0);

   function Math_Y_Origin (T : Handle) return Integer is
     (Integer (T.State.Math_Offset / Math_Y_Inc (T)));

   function Math_Preamble (T : Handle) return String is
      Left, First_F, X_Inc : Float;
      Points : Natural;
   begin
      if Math_Op (T) = "FFT" then
         FFT_Axis (T, Left, First_F, X_Inc, Points);
      else
         X_Inc := 12.0 * T.State.TB_Scale / Float (Screen_Points);
         Left  := T.State.TB_Offset - 6.0 * T.State.TB_Scale;
      end if;
      return "0,0," & Int (Math_Points (T)) & ",1," & Sci (X_Inc) & "," &
        Sci (Left) & ",0," & Sci (Math_Y_Inc (T)) & "," &
        Int (Math_Y_Origin (T)) & ",127";
   end Math_Preamble;

   function Math_Data (T : in out Handle) return String is
      Points : constant Natural := Math_Points (T);
      Result : String (1 .. Natural'Max (1, Points)) := (others => Character'Val (0));

      function Raw (Value : Float) return Character is
        (Character'Val (Integer (Float'Max (0.0, Float'Min (255.0,
           Value / Math_Y_Inc (T) + 127.0 + Float (Math_Y_Origin (T)))))));
   begin
      if T.State.Math_Settling > 0 then
         T.State.Math_Settling := T.State.Math_Settling - 1;
      end if;
      if Points = 0 then
         return Block (Result);   --  the scope sends one meaningless byte
      end if;

      if Math_Op (T) = "FFT" then
         declare
            Left, First_F, X_Inc : Float;
            N : Natural;
            Db : constant Boolean := T.State.FFT_Unit (1 .. 2) = "DB";
         begin
            FFT_Axis (T, Left, First_F, X_Inc, N);
            for I in 1 .. Points loop
               declare
                  F     : constant Float := First_F + Float (I - 1) * X_Inc;
                  H     : constant Natural := Natural (F / 1000.0);
                  Level : Float := 1.0E-4;   --  noise floor, Vrms
               begin
                  if abs (F - Float (H) * 1000.0) <= X_Inc / 2.0 then
                     Level := Float'Max (Level, Harmonic_RMS (T.State.FFT_Src, H));
                  end if;
                  Result (I) := Raw (if Db then 20.0 * Log (Level, 10.0) else Level);
               end;
            end loop;
         end;
      else
         declare
            X_Inc  : constant Float := 12.0 * T.State.TB_Scale / Float (Screen_Points);
            X_Orig : constant Float := T.State.TB_Offset - 6.0 * T.State.TB_Scale;
            Op     : constant String := Math_Op (T);
         begin
            for I in 1 .. Points loop
               declare
                  Time : constant Float := X_Orig + Float (I - 1) * X_Inc;
                  A    : constant Float := Signal (T, T.State.Math_Src1, Time);
                  B    : constant Float := Signal (T, T.State.Math_Src2, Time);
               begin
                  Result (I) := Raw
                    (if    Op = "SUBT" then A - B
                     elsif Op = "MULT" then A * B
                     elsif Op = "DIV"  then (if abs B < 1.0E-3 then 0.0 else A / B)
                     else A + B);
               end;
            end loop;
         end;
      end if;
      return Block (Result);
   end Math_Data;

   function Preamble (T : Handle) return String is
      Points : constant Positive :=
        (if T.State.Wav_Raw then Depth (T) else Screen_Points);
      Ch     : constant Positive := T.State.Wav_Source;
   begin
      return "0," & (if T.State.Wav_Raw then "2" else "0") & "," & Int (Points) &
        ",1," & Sci (12.0 * T.State.TB_Scale / Float (Points)) & "," &
        Sci (T.State.TB_Offset - 6.0 * T.State.TB_Scale) & ",0," &
        Sci (Y_Inc (T, Ch)) & "," & Int (Y_Origin (T, Ch)) & ",127";
   end Preamble;

   function Waveform_Data (T : in out Handle) return String is
   begin
      if T.State.Wav_Math then
         return Math_Data (T);
      end if;
      if T.State.Wav_Raw then
         declare
            First : constant Positive := Positive'Min (T.State.Wav_Start, Depth (T));
            Last  : constant Positive :=
              Positive'Min (Positive'Min (T.State.Wav_Stop, Depth (T)),
                            First + Max_Batch - 1);
         begin
            return Block (Samples (T, T.State.Wav_Source, Depth (T), First, Last));
         end;
      end if;

      if T.State.Running then
         T.State.Acquisition := T.State.Acquisition + 1;
         if T.State.Mask_Enable and then T.State.Mask_Running then
            if T.State.Channels (T.State.Mask_Source).Offset = T.State.Mask_Offset
            then
               T.State.Mask_Passed := T.State.Mask_Passed + 1;
            else
               T.State.Mask_Failed := T.State.Mask_Failed + 1;
               if T.State.Mask_Stop then
                  T.State.Running := False;
               end if;
            end if;
         end if;
      end if;
      --  STARt/STOP apply to screen reads too, clamped to the screen: a
      --  range left over from a memory read gives a single point, as on
      --  the real scope
      declare
         First : constant Positive :=
           Positive'Min (T.State.Wav_Start, Screen_Points);
         Last  : constant Positive :=
           Positive'Max (First, Positive'Min (T.State.Wav_Stop, Screen_Points));
      begin
         return Block
           (Samples (T, T.State.Wav_Source, Screen_Points, First, Last));
      end;
   end Waveform_Data;

   function Measurement (T : Handle; Args : String) return String is
      Comma : constant Natural := Index (Args, ",");
      Item  : constant String :=
        Short (if Comma = 0 then Args else Args (Args'First .. Comma - 1));
      Ch    : constant Natural := Channel_Of (Args);
   begin
      if Ch = 0 or else not T.State.Channels (Ch).Display then
         return Invalid;
      elsif Item = "FREQ" then
         return Sci (1000.0);
      elsif Item = "PER" then
         return Sci (1.0E-3);
      elsif Item = "VPP" then
         return Sci (if Ch = 1 then 3.0 else 2.0);
      elsif Item = "VMAX" then
         return Sci (if Ch = 1 then 3.0 else 1.0);
      elsif Item = "VMIN" then
         return Sci (if Ch = 1 then 0.0 else -1.0);
      elsif Item = "VRMS" then
         return Sci (if Ch = 1 then 2.12132 else 0.707107);
      elsif Item = "VTOP" then
         return Sci (if Ch = 1 then 3.0 else 1.0);
      elsif Item = "VBAS" then
         return Sci (if Ch = 1 then 0.0 else -1.0);
      elsif Item = "VAMP" then
         return Sci (if Ch = 1 then 3.0 else 2.0);
      elsif Item = "VAVG" then
         return Sci (if Ch = 1 then 1.5 else 0.0);
      elsif Item in "PWID" | "NWID" then
         return Sci (5.0E-4);
      elsif Item in "PDUT" | "NDUT" then
         return Sci (0.5);
      elsif Item in "RTIM" | "FTIM" then
         --  The square's edges are too fast to measure, as on the real
         --  scope at this timebase; the sine's 10-90 % time is 0.295 T
         return (if Ch = 1 then "measure error!" else Sci (2.952E-4));
      end if;
      return Invalid;
   end Measurement;

   -- -------------------------------------------------------------------------
   --  Screen image: the traces on a graticule, as a 24-bit BMP
   -- -------------------------------------------------------------------------

   function Screenshot (T : Handle) return String is
      Width    : constant := 800;
      Height   : constant := 480;
      Div      : constant := 50;             --  pixels per division
      Left     : constant := (Width - 12 * Div) / 2;
      Top      : constant := (Height - 8 * Div) / 2;
      Row_Size : constant := Width * 3;
      Pixels   : String (1 .. Row_Size * Height) := (others => Character'Val (0));

      procedure Plot (X, Y : Integer; R, G, B : Natural) is
         --  BMP rows run bottom-up, pixels are B, G, R
         P : Positive;
      begin
         if X in 0 .. Width - 1 and then Y in 0 .. Height - 1 then
            P := (Height - 1 - Y) * Row_Size + X * 3 + 1;
            Pixels (P)     := Character'Val (B);
            Pixels (P + 1) := Character'Val (G);
            Pixels (P + 2) := Character'Val (R);
         end if;
      end Plot;

      function LE32 (N : Natural) return String is
        (Character'Val (N mod 256) & Character'Val (N / 2**8 mod 256) &
         Character'Val (N / 2**16 mod 256) & Character'Val (N / 2**24));

      function LE16 (N : Natural) return String is
        (Character'Val (N mod 256) & Character'Val (N / 256));

      Y_Prev : Integer;
      Y      : Integer;
   begin
      --  Graticule: dotted lines on every division
      for I in 0 .. 12 loop
         for Yp in Top .. Top + 8 * Div loop
            if Yp mod 5 = 0 then
               Plot (Left + I * Div, Yp, 90, 90, 90);
            end if;
         end loop;
      end loop;
      for J in 0 .. 8 loop
         for Xp in Left .. Left + 12 * Div loop
            if Xp mod 5 = 0 then
               Plot (Xp, Top + J * Div, 90, 90, 90);
            end if;
         end loop;
      end loop;

      --  Traces: CH1 yellow, CH2 cyan
      for Ch in 1 .. 2 loop
         if T.State.Channels (Ch).Display then
            Y_Prev := Integer'First;
            for Xp in 0 .. 12 * Div - 1 loop
               Y := Top + 4 * Div - Integer
                 ((Signal (T, Ch, T.State.TB_Offset - 6.0 * T.State.TB_Scale +
                              Float (Xp) * T.State.TB_Scale / Float (Div)) +
                   T.State.Channels (Ch).Offset) / T.State.Channels (Ch).Scale *
                  Float (Div));
               if Y_Prev = Integer'First then
                  Y_Prev := Y;
               end if;
               for Yp in Integer'Min (Y, Y_Prev) .. Integer'Max (Y, Y_Prev) loop
                  if Yp in Top .. Top + 8 * Div then
                     if Ch = 1 then
                        Plot (Left + Xp, Yp, 255, 255, 0);
                     else
                        Plot (Left + Xp, Yp, 0, 255, 255);
                     end if;
                  end if;
               end loop;
               Y_Prev := Y;
            end loop;
         end if;
      end loop;

      return Block
        ("BM" & LE32 (54 + Pixels'Length) & LE32 (0) & LE32 (54) &
         LE32 (40) & LE32 (Width) & LE32 (Height) & LE16 (1) & LE16 (24) &
         LE32 (0) & LE32 (Pixels'Length) & LE32 (2835) & LE32 (2835) &
         LE32 (0) & LE32 (0) & Pixels);
   end Screenshot;

   -- -------------------------------------------------------------------------
   --  Setups: the settings as "key=value;" text in a block
   -- -------------------------------------------------------------------------

   function Setup_Text (T : Handle) return String is
      St : Scope_State renames T.State;
      function Ch (N : Positive) return String is
        ("c" & Int (N) & "d=" & (if St.Channels (N).Display then "1" else "0") &
         ";c" & Int (N) & "s=" & Sci (St.Channels (N).Scale) &
         ";c" & Int (N) & "o=" & Sci (St.Channels (N).Offset) & ";");
   begin
      return "SIMSETUP;" & Ch (1) & Ch (2) &
        "tbs=" & Sci (St.TB_Scale) & ";tbo=" & Sci (St.TB_Offset) &
        ";tm=" & St.Trig_Mode & ";tl=" & Sci (St.Trig_Level) &
        ";pw=" & Sci (St.Pulse_Width) & ";st=" & Sci (St.Slope_Time) & ";";
   end Setup_Text;

   procedure Restore_Setup (T : in out Handle; Block_Text : String) is
      St    : Scope_State renames T.State;
      --  Past "#9" and the nine length digits
      Text  : constant String :=
        (if Block_Text'Length > 11
         then Block_Text (Block_Text'First + 11 .. Block_Text'Last) else "");
      First : Positive := Text'First;
   begin
      for I in Text'Range loop
         if Text (I) = ';' then
            declare
               Item : constant String := Text (First .. I - 1);
               Eq   : constant Natural := Index (Item, "=");
            begin
               if Eq > 0 then
                  declare
                     K : constant String := Item (Item'First .. Eq - 1);
                     V : constant String := Item (Eq + 1 .. Item'Last);
                  begin
                     --  Like the DS1202Z-E, only the timebase comes back
                     --  from the block
                     if    K = "tbs" then St.TB_Scale := Float'Value (V);
                     elsif K = "tbo" then St.TB_Offset := Float'Value (V);
                     end if;
                  end;
               end if;
            end;
            First := I + 1;
         end if;
      end loop;
   end Restore_Setup;

   -- -------------------------------------------------------------------------
   --  Transport interface
   -- -------------------------------------------------------------------------

   procedure Open (T : out Handle) is
   begin
      T.Opened := True;
      T.State  := (others => <>);
   end Open;

   overriding procedure Send
     (T       : in out Handle;
      Command : in     String)
   is
      H    : constant String  := Header_Of (Command);
      Args : constant String  := Args_Of (Command);
      Ch   : constant Natural := Channel_Of (H);
   begin
      if H = "*RST" then
         T.State := (others => <>);

      elsif H = ":RUN" then
         T.State.Running := True;
      elsif H = ":STOP" then
         T.State.Running := False;
      elsif H = ":SING" then
         T.State.Acquisition := T.State.Acquisition + 1;
         T.State.Running := False;
      elsif H = ":AUT" then
         T.State.Channels (1) := (Display => True, Scale => 1.0, Offset => -1.5,
                            others => <>);
         T.State.TB_Scale  := 5.0E-4;
         T.State.TB_Offset := 0.0;
         T.State.Running   := True;

      elsif Ch /= 0 and then H'Length > 6 then
         declare
            Item : constant String := H (H'First + 6 .. H'Last);
            C    : Channel_State renames T.State.Channels (Ch);
         begin
            if    Item = ":DISP" then
               declare
                  Was_Dual : constant Boolean := Dual (T);
               begin
                  C.Display := To_Bool (Args);
                  if T.State.Mem_Depth /= 0 and then Dual (T) /= Was_Dual then
                     for K in Single_Depths'Range loop
                        if T.State.Mem_Depth = (if Was_Dual then Dual_Depths (K)
                                                else Single_Depths (K))
                        then
                           T.State.Mem_Depth := (if Was_Dual then Single_Depths (K)
                                                 else Dual_Depths (K));
                           exit;
                        end if;
                     end loop;
                  end if;
               end;
            elsif Item = ":SCAL" then C.Scale   := Float'Value (Args);
            elsif Item = ":OFFS" then C.Offset  := Float'Value (Args);
            elsif Item = ":PROB" then C.Probe   := Float'Value (Args);
            elsif Item = ":COUP" then
               C.Coupling := Head (Short (Args), 3);
            end if;
         end;

      elsif H = ":TIM:MAIN:SCAL" then
         T.State.TB_Scale := Float'Value (Args);
      elsif H = ":TIM:MAIN:OFFS" then
         T.State.TB_Offset := Float'Value (Args);
      elsif H = ":TIM:MODE" then
         T.State.TB_Mode := Head (Short (Args), 4);

      elsif H = ":ACQ:TYPE" then
         T.State.Acq_Type := Head (Short (Args), 4);
      elsif H = ":ACQ:AVER" then
         T.State.Averages := Positive'Value (Args);
      elsif H = ":ACQ:MDEP" then
         if not T.State.Running then
            null;   --  like the scope: not while stopped
         elsif Short (Args) = "AUTO" then
            T.State.Mem_Depth := 0;
         else
            --  Only a depth offered for the channels on
            declare
               N : constant Natural := Natural'Value (Args);
            begin
               for K in Single_Depths'Range loop
                  if N = (if Dual (T) then Dual_Depths (K) else Single_Depths (K)) then
                     T.State.Mem_Depth := N;
                  end if;
               end loop;
            end;
         end if;

      elsif H = ":MASK:ENAB" then
         T.State.Mask_Enable  := To_Bool (Args);
         T.State.Mask_Running := T.State.Mask_Running and then T.State.Mask_Enable;
      elsif H = ":MASK:SOUR" then
         T.State.Mask_Source := Positive'Max (1, Channel_Of (Short (Args)));
      elsif H = ":MASK:OPER" then
         T.State.Mask_Running := T.State.Mask_Enable and then Short (Args) = "RUN";
      elsif H = ":MASK:MDIS" then
         T.State.Mask_Stats := To_Bool (Args);
      elsif H = ":MASK:SOO" then
         T.State.Mask_Stop := To_Bool (Args);
      elsif H = ":MASK:OUTP" then
         T.State.Mask_Beep := To_Bool (Args);
      elsif H = ":MASK:X" then
         T.State.Mask_X := Float'Max (0.02, Float'Min (4.0, Float'Value (Args)));
      elsif H = ":MASK:Y" then
         T.State.Mask_Y := Float'Max (0.04, Float'Min (5.12, Float'Value (Args)));
      elsif H = ":MASK:CRE" then
         if T.State.Mask_Enable and then not T.State.Mask_Running then
            T.State.Mask_Offset := T.State.Channels (T.State.Mask_Source).Offset;
         end if;
      elsif H = ":MASK:RES" then
         T.State.Mask_Passed := 0;
         T.State.Mask_Failed := 0;

      elsif H = ":SIM:SIGN" then
         declare
            S : constant String := Short (Args);
         begin
            T.State.Signal := (if S = "UART" then UART elsif S = "IIC" then I2C
                               elsif S = "SPI" then SPI elsif S = "TIM" then Timing
                               else Normal);
         end;

      elsif H = ":TRIG:EDG:SOUR" then
         declare
            S : constant String := Short (Args);
         begin
            T.State.Trig_Source := (if S = "CHAN1" then 1 elsif S = "CHAN2" then 2
                              elsif S = "ACL" then 3 else 4);
         end;
      elsif H = ":TRIG:EDG:SLOP" then
         T.State.Trig_Slope := Head (Short (Args), 4);
      elsif H = ":TRIG:EDG:LEV" then
         T.State.Trig_Level := Float'Value (Args);
      elsif H = ":TRIG:SWE" then
         T.State.Trig_Sweep := Head (Short (Args), 4);
      elsif H = ":TRIG:MODE" then
         T.State.Trig_Mode := Head (Short (Args), 4);

      elsif H = ":TRIG:PULS:SOUR" then
         T.State.Pulse_Source := Positive'Max (1, Channel_Of (Short (Args)));
      elsif H = ":TRIG:PULS:WHEN" then
         T.State.Pulse_When := Head (Short (Args), 4);
      elsif H = ":TRIG:PULS:WIDT" then
         T.State.Pulse_Width := Float'Value (Args);
      elsif H = ":TRIG:PULS:UWID" then
         T.State.Pulse_Upper := Float'Max (Float'Value (Args), T.State.Pulse_Lower);
      elsif H = ":TRIG:PULS:LWID" then
         --  Kept below the upper limit, as the scope does
         T.State.Pulse_Lower := Float'Min (Float'Value (Args), T.State.Pulse_Upper - 1.0E-8);
      elsif H = ":TRIG:PULS:LEV" then
         T.State.Pulse_Level := Float'Value (Args);
      elsif H = ":TRIG:SLOP:SOUR" then
         T.State.Slope_Source := Positive'Max (1, Channel_Of (Short (Args)));
      elsif H = ":TRIG:SLOP:WHEN" then
         T.State.Slope_When := Head (Short (Args), 4);
      elsif H = ":TRIG:SLOP:TIME" then
         T.State.Slope_Time := Float'Value (Args);
      elsif H = ":TRIG:SLOP:TUPP" then
         T.State.Slope_Upper := Float'Max (Float'Value (Args), T.State.Slope_Lower);
      elsif H = ":TRIG:SLOP:TLOW" then
         T.State.Slope_Lower := Float'Min (Float'Value (Args), T.State.Slope_Upper - 1.0E-8);
      elsif H = ":TRIG:SLOP:WIND" then
         T.State.Slope_Window := Head (Short (Args), 3);
      elsif H = ":TRIG:SLOP:ALEV" then
         T.State.Slope_Level_A := Float'Value (Args);
      elsif H = ":TRIG:SLOP:BLEV" then
         T.State.Slope_Level_B := Float'Value (Args);
      elsif H = ":SYST:SET" then
         Restore_Setup (T, Args);

      elsif H = ":WAV:SOUR" then
         T.State.Wav_Math := Short (Args) = "MATH";
         if not T.State.Wav_Math then
            T.State.Wav_Source := Positive'Max (1, Channel_Of (Short (Args)));
         end if;

      elsif H = ":MATH:DISP" then
         T.State.Math_Display := To_Bool (Args);
      elsif H = ":MATH:OPER" then
         T.State.Math_Op := Head (Short (Args), 4);
         T.State.Math_Settling := 2;
         --  Like the scope, pick a scale that suits the result
         if Math_Op (T) = "FFT" then
            T.State.Math_Scale  := 10.0;
            T.State.Math_Offset := 0.0;
         else
            T.State.Math_Scale  := T.State.Channels (1).Scale;
            T.State.Math_Offset := 0.0;
         end if;
      elsif H = ":MATH:SOUR1" then
         T.State.Math_Src1 := Positive'Max (1, Channel_Of (Short (Args)));
      elsif H = ":MATH:SOUR2" then
         T.State.Math_Src2 := Positive'Max (1, Channel_Of (Short (Args)));
      elsif H = ":MATH:SCAL" then
         T.State.Math_Scale := Float'Value (Args);
      elsif H = ":MATH:OFFS" then
         T.State.Math_Offset := Float'Value (Args);
      elsif H = ":MATH:FFT:SOUR" then
         T.State.FFT_Src := Positive'Max (1, Channel_Of (Short (Args)));
      elsif H = ":MATH:FFT:WIND" then
         T.State.FFT_Window := Head (Short (Args), 4);
      elsif H = ":MATH:FFT:UNIT" then
         T.State.FFT_Unit := Head (Short (Args), 4);
      elsif H = ":MATH:FFT:MODE" then
         T.State.FFT_Mode := Head (Short (Args), 4);
      elsif H = ":MATH:FFT:HSC" then
         T.State.FFT_HScale := Float'Value (Args);
      elsif H = ":MATH:FFT:HCEN" then
         T.State.FFT_HCenter := Float'Value (Args);
      elsif H = ":WAV:MODE" then
         T.State.Wav_Raw := Short (Args) = "RAW";
      elsif H = ":WAV:STAR" then
         T.State.Wav_Start := Positive'Value (Args);
      elsif H = ":WAV:STOP" then
         T.State.Wav_Stop := Positive'Value (Args);
      end if;
      --  Anything else is accepted and ignored, as the scope would log
      --  an error but carry on.
   end Send;

   overriding function Query
     (T       : in out Handle;
      Command : in     String) return String
   is
      H    : constant String  := Header_Of (Command);
      Args : constant String  := Args_Of (Command);
      Ch   : constant Natural := Channel_Of (H);
   begin
      if H = "*IDN?" then
         return "RIGOL TECHNOLOGIES,DS1202Z-E,SIMULATED,00.06.04";
      elsif H = "*OPC?" then
         return "1";
      elsif H in "*ESR?" | "*STB?" | "*TST?" then
         return "0";
      elsif H = ":SYST:ERR?" then
         return "0,""No error""";

      elsif Ch /= 0 and then H'Length > 6 then
         declare
            Item : constant String := H (H'First + 6 .. H'Last);
            C    : Channel_State renames T.State.Channels (Ch);
         begin
            if    Item = ":DISP?" then return (if C.Display then "1" else "0");
            elsif Item = ":SCAL?" then return Sci (C.Scale);
            elsif Item = ":OFFS?" then return Sci (C.Offset);
            elsif Item = ":PROB?" then return Sci (C.Probe);
            elsif Item = ":COUP?" then return Trim (C.Coupling, Ada.Strings.Right);
            end if;
         end;

      elsif H = ":TIM:MAIN:SCAL?" then
         return Sci (T.State.TB_Scale);
      elsif H = ":TIM:MAIN:OFFS?" then
         return Sci (T.State.TB_Offset);
      elsif H = ":TIM:MODE?" then
         return Trim (T.State.TB_Mode, Ada.Strings.Right);

      elsif H = ":MASK:ENAB?" then
         return (if T.State.Mask_Enable then "1" else "0");
      elsif H = ":MASK:SOUR?" then
         return "CHAN" & Int (T.State.Mask_Source);
      elsif H = ":MASK:OPER?" then
         return (if T.State.Mask_Running then "RUN" else "STOP");
      elsif H = ":MASK:MDIS?" then
         return (if T.State.Mask_Stats then "1" else "0");
      elsif H = ":MASK:SOO?" then
         return (if T.State.Mask_Stop then "1" else "0");
      elsif H = ":MASK:OUTP?" then
         return (if T.State.Mask_Beep then "1" else "0");
      elsif H = ":MASK:X?" then
         return Sci (T.State.Mask_X);
      elsif H = ":MASK:Y?" then
         return Sci (T.State.Mask_Y);
      elsif H = ":MASK:PASS?" then
         return Int (T.State.Mask_Passed);
      elsif H = ":MASK:FAIL?" then
         return Int (T.State.Mask_Failed);
      elsif H = ":MASK:TOT?" then
         return Int (T.State.Mask_Passed + T.State.Mask_Failed);

      elsif H = ":TRIG:STAT?" then
         return (if T.State.Running then "TD" else "STOP");
      elsif H = ":TRIG:MODE?" then
         return Trim (T.State.Trig_Mode, Ada.Strings.Right);
      elsif H = ":TRIG:PULS:SOUR?" then
         return "CHAN" & Int (T.State.Pulse_Source);
      elsif H = ":TRIG:PULS:WHEN?" then
         return Trim (T.State.Pulse_When, Ada.Strings.Right);
      elsif H = ":TRIG:PULS:WIDT?" then
         return Sci (T.State.Pulse_Width);
      elsif H = ":TRIG:PULS:UWID?" then
         return Sci (T.State.Pulse_Upper);
      elsif H = ":TRIG:PULS:LWID?" then
         return Sci (T.State.Pulse_Lower);
      elsif H = ":TRIG:PULS:LEV?" then
         return Sci (T.State.Pulse_Level);
      elsif H = ":TRIG:SLOP:SOUR?" then
         return "CHAN" & Int (T.State.Slope_Source);
      elsif H = ":TRIG:SLOP:WHEN?" then
         return Trim (T.State.Slope_When, Ada.Strings.Right);
      elsif H = ":TRIG:SLOP:TIME?" then
         return Sci (T.State.Slope_Time);
      elsif H = ":TRIG:SLOP:TUPP?" then
         return Sci (T.State.Slope_Upper);
      elsif H = ":TRIG:SLOP:TLOW?" then
         return Sci (T.State.Slope_Lower);
      elsif H = ":TRIG:SLOP:WIND?" then
         return Trim (T.State.Slope_Window, Ada.Strings.Right);
      elsif H = ":TRIG:SLOP:ALEV?" then
         return Sci (T.State.Slope_Level_A);
      elsif H = ":TRIG:SLOP:BLEV?" then
         return Sci (T.State.Slope_Level_B);
      elsif H = ":SYST:SET?" then
         return Block (Setup_Text (T));
      elsif H = ":TRIG:SWE?" then
         return Trim (T.State.Trig_Sweep, Ada.Strings.Right);
      elsif H = ":TRIG:EDG:SOUR?" then
         return (case T.State.Trig_Source is
                    when 1 => "CHAN1", when 2 => "CHAN2",
                    when 3 => "ACL",   when others => "EXT");
      elsif H = ":TRIG:EDG:SLOP?" then
         return Trim (T.State.Trig_Slope, Ada.Strings.Right);
      elsif H = ":TRIG:EDG:LEV?" then
         return Sci (T.State.Trig_Level);

      elsif H = ":ACQ:SRAT?" then
         return Sci (Float (Depth (T)) / (12.0 * T.State.TB_Scale));
      elsif H = ":ACQ:MDEP?" then
         return (if T.State.Mem_Depth = 0 then "AUTO" else Int (T.State.Mem_Depth));
      elsif H = ":ACQ:TYPE?" then
         return Trim (T.State.Acq_Type, Ada.Strings.Right);
      elsif H = ":ACQ:AVER?" then
         return Int (T.State.Averages);

      elsif H = ":WAV:PRE?" then
         return (if T.State.Wav_Math then Math_Preamble (T) else Preamble (T));
      elsif H = ":WAV:DATA?" then
         return Waveform_Data (T);
      elsif H = ":WAV:SOUR?" then
         return (if T.State.Wav_Math then "MATH"
                 else "CHAN" & Int (T.State.Wav_Source));

      elsif H = ":MATH:DISP?" then
         return (if T.State.Math_Display then "1" else "0");
      elsif H = ":MATH:OPER?" then
         return Math_Op (T);
      elsif H = ":MATH:SOUR1?" then
         return "CHAN" & Int (T.State.Math_Src1);
      elsif H = ":MATH:SOUR2?" then
         return "CHAN" & Int (T.State.Math_Src2);
      elsif H = ":MATH:SCAL?" then
         return Sci (T.State.Math_Scale);
      elsif H = ":MATH:OFFS?" then
         return Sci (T.State.Math_Offset);
      elsif H = ":MATH:FFT:SOUR?" then
         return "CHAN" & Int (T.State.FFT_Src);
      elsif H = ":MATH:FFT:WIND?" then
         return Trim (T.State.FFT_Window, Ada.Strings.Right);
      elsif H = ":MATH:FFT:UNIT?" then
         return Trim (T.State.FFT_Unit, Ada.Strings.Right);
      elsif H = ":MATH:FFT:MODE?" then
         return Trim (T.State.FFT_Mode, Ada.Strings.Right);
      elsif H = ":MATH:FFT:HSC?" then
         return Sci (T.State.FFT_HScale);
      elsif H = ":MATH:FFT:HCEN?" then
         return Sci (T.State.FFT_HCenter);
      elsif H = ":WAV:MODE?" then
         return (if T.State.Wav_Raw then "RAW" else "NORM");
      elsif H = ":WAV:FORM?" then
         return "BYTE";

      elsif H = ":MEAS:ITEM?" then
         return Measurement (T, Args);

      elsif H = ":DISP:DATA?" then
         return Screenshot (T);
      end if;

      raise Communication_Error
        with "no reply (the simulator does not answer """ & Command & """)";
   end Query;

   overriding procedure Close (T : in out Handle) is
   begin
      T.Opened := False;
   end Close;

   overriding function Is_Open (T : Handle) return Boolean is
     (T.Opened);

end Rigol_Transport.Simulator;
