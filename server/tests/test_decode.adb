-- ***************************************************************************
--                 ScopeBridge Server - Bus Decoding Tests
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

--  Checks Server.Decode against synthetic UART, I2C and SPI signals.
--  Built and run by `make check-server`.

with Ada.Text_IO;  use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Containers;         use type Ada.Containers.Count_Type;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Interfaces;             use Interfaces;

with Server.Decode;          use Server.Decode;
with Rigol.Waveform;         use Rigol.Waveform;

procedure Test_Decode is
   Failed : Natural := 0;
   Passed : Natural := 0;

   procedure Check (Name : String; OK : Boolean) is
   begin
      if OK then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Put_Line ("FAIL  " & Name);
      end if;
   end Check;

   procedure Check (Name : String; Got, Want : Integer) is
   begin
      Check (Name & ": got" & Got'Image & ", want" & Want'Image, Got = Want);
   end Check;

   --  Levels as text, one character per bit time: '1' high, '0' low
   --  (for I2C, slots as in the simulator), turned into samples with a
   --  little noise
   Seed : Unsigned_32 := 12345;

   function Noise return Integer is
   begin
      Seed := Seed * 1_103_515_245 + 12_345;
      return Integer (Shift_Right (Seed, 16) mod 11) - 5;   --  -5 .. 5 counts
   end Noise;

   function Level (High : Boolean) return Raw_Sample is
     (Raw_Sample ((if High then 200 else 50) + Noise));

   function Samples (Bits : String; Per_Bit : Positive) return Raw_Array is
      Result : Raw_Array (1 .. Bits'Length * Per_Bit);
   begin
      for B in Bits'Range loop
         for S in 1 .. Per_Bit loop
            Result ((B - Bits'First) * Per_Bit + S) := Level (Bits (B) = '1');
         end loop;
      end loop;
      return Result;
   end Samples;

   function Digital_Of (Data : Raw_Array) return Digital is
      Threshold, Hysteresis : Float;
      Flat : Boolean;
   begin
      Auto_Threshold (Data, Data'First, Data'Last, Threshold, Hysteresis, Flat);
      Check ("signal not flat", not Flat);
      return Digitize (Data, Data'First, Data'Last, Threshold, Hysteresis);
   end Digital_Of;

   --  A UART frame: start, data bits, parity, stop bits
   function Frame (C : Character; Data_Bits : Positive := 8;
                   Parity : String := ""; Stop : String := "1";
                   MSB_First : Boolean := False) return String
   is
      Code   : constant Natural := Character'Pos (C);
      Result : Unbounded_String := To_Unbounded_String ("0");
   begin
      for B in 0 .. Data_Bits - 1 loop
         Append (Result, (if Code / 2**(if MSB_First then Data_Bits - 1 - B else B)
                                mod 2 = 1 then '1' else '0'));
      end loop;
      return To_String (Result) & Parity & Stop;
   end Frame;

   function Invert (S : String) return String is
      R : String := S;
   begin
      for C of R loop
         C := (if C = '1' then '0' else '1');
      end loop;
      return R;
   end Invert;

   Idle : constant String (1 .. 12) := (others => '1');

   Items : Item_Vectors.Vector;

   function Value (I : Positive) return Integer is (Integer (Items (I).Value));
begin
   --  UART 8N1: the capture starts inside a frame, whose remains must not
   --  decode; then "Hi!" after an idle line
   declare
      D : constant Digital := Digital_Of
        (Samples ("0110" & Idle & Frame ('H') & Frame ('i') & "11" & Frame ('!') & Idle, 50));
   begin
      Decode_UART (D, 1, (Samples_Per_Bit => 50.0, others => <>), Items, 100);
      Check ("uart items", Natural (Items.Length), 3);
      Check ("uart H", Value (1), Character'Pos ('H'));
      Check ("uart i", Value (2), Character'Pos ('i'));
      Check ("uart !", Value (3), Character'Pos ('!'));
      Check ("uart no errors", (for all I of Items => I.Error = None));
      Check ("uart first sample", Items (1).First, 16 * 50);
      Check ("uart frame length", Items (1).Last - Items (1).First + 1, 10 * 50);
      Check ("uart line", Items (1).Line, 1);
   end;

   --  Without an idle frame before it, nothing is trusted
   Items.Clear;
   declare
      D : constant Digital := Digital_Of (Samples (Frame ('A') & Frame ('B') & "1", 20));
   begin
      Decode_UART (D, 1, (Samples_Per_Bit => 20.0, others => <>), Items, 100);
      Check ("uart needs an idle start", Natural (Items.Length), 0);
   end;

   --  Even parity: a good frame, one with a wrong parity bit, one with a
   --  low stop bit
   Items.Clear;
   declare
      D : constant Digital := Digital_Of
        (Samples (Idle & Frame ('A', Parity => "0") & Frame ('C', Parity => "0") &
                  Frame ('E', Parity => "1", Stop => "0") & Idle, 30));
   begin
      Decode_UART (D, 2, (Samples_Per_Bit => 30.0, Parity => Even, others => <>),
                   Items, 100);
      Check ("parity items", Natural (Items.Length), 3);
      Check ("parity good", Items (1).Error = None and then Value (1) = 65);
      Check ("parity bad", Items (2).Error = Parity);
      Check ("framing bad", Items (3).Error = Framing);
      Check ("parity line", Items (1).Line, 2);
   end;

   --  Inverted line, 7 data bits, MSB first, 2 stop bits, 17.3 samples
   --  per bit (not a whole number)
   Items.Clear;
   declare
      Bits : constant String :=
        Idle & Frame ('R', 7, Stop => "11", MSB_First => True) &
        Frame ('x', 7, Stop => "11", MSB_First => True) & Idle;
      Raw  : Raw_Array (1 .. Natural (Float (Bits'Length) * 17.3));
   begin
      for I in Raw'Range loop
         Raw (I) := Level
           (Invert (Bits) (Bits'First + Natural (Float'Floor (Float (I - 1) / 17.3))) = '1');
      end loop;
      Decode_UART (Digital_Of (Raw), 1,
                   (Samples_Per_Bit => 17.3, Data_Bits => 7, Stop_Bits => 2.0,
                    Inverted => True, MSB_First => True, others => <>),
                   Items, 100);
      Check ("inverted items", Natural (Items.Length), 2);
      Check ("inverted R", Value (1), Character'Pos ('R'));
      Check ("inverted x", Value (2), Character'Pos ('x'));
      Check ("inverted no errors", (for all I of Items => I.Error = None));
   end;

   --  I2C: each slot 40 samples, SCL low, high, low in quarters
   declare
      function Byte (B : Natural; Ack : Character) return String is
         R : String (1 .. 9);
      begin
         for K in 1 .. 8 loop
            R (K) := (if B / 2**(8 - K) mod 2 = 1 then '1' else '0');
         end loop;
         R (9) := Ack;
         return R;
      end Byte;

      --  A write of 00 to 50h, then a read with a repeated start of A5
      --  3C, the last not acknowledged
      Slots : constant String :=
        "II" & "S" & Byte (16#A0#, '0') & Byte (16#00#, '0') &
        "S" & Byte (16#A1#, '0') & Byte (16#A5#, '0') & Byte (16#3C#, '1') & "PII";
      Per   : constant := 40;
      SCL_R : Raw_Array (1 .. Slots'Length * Per);
      SDA_R : Raw_Array (1 .. Slots'Length * Per);
      Clock_High, Data_High : Boolean;
   begin
      for I in SCL_R'Range loop
         declare
            Slot : constant Character := Slots (Slots'First + (I - 1) / Per);
            Frac : constant Float := Float ((I - 1) mod Per) / Float (Per);
         begin
            case Slot is
               when 'S' =>
                  Clock_High := Frac in 0.25 .. 0.75;
                  Data_High  := Frac < 0.5;
               when 'P' =>
                  Clock_High := Frac >= 0.25;
                  Data_High  := Frac >= 0.5;
               when '0' | '1' =>
                  Clock_High := Frac in 0.25 .. 0.75;
                  Data_High  := Slot = '1';
               when others =>
                  Clock_High := True;
                  Data_High  := True;
            end case;
            SCL_R (I) := Level (Clock_High);
            SDA_R (I) := Level (Data_High);
         end;
      end loop;
      Items.Clear;
      Decode_I2C (Digital_Of (SCL_R), Digital_Of (SDA_R), 2, Items, 100);
      Check ("i2c items", Natural (Items.Length), 8);
      if Items.Length = 8 then
         Check ("i2c start", Items (1).Kind = Start);
         Check ("i2c address", Items (2).Kind = Address and then Value (2) = 16#50#
                and then not Items (2).Read and then Items (2).Ack);
         Check ("i2c data 00", Items (3).Kind = Data and then Value (3) = 0
                and then Items (3).Ack);
         Check ("i2c repeated start", Items (4).Kind = Start);
         Check ("i2c read address", Items (5).Kind = Address and then Value (5) = 16#50#
                and then Items (5).Read);
         Check ("i2c A5", Value (6), 16#A5#);
         Check ("i2c 3C not acknowledged", Value (7) = 16#3C# and then not Items (7).Ack);
         Check ("i2c stop", Items (8).Kind = Stop);
         Check ("i2c line", Items (2).Line, 2);
      end if;

      Items.Clear;
      Decode_I2C (Digital_Of (SCL_R), Digital_Of (SDA_R), 2, Items, 3);
      Check ("i2c stops at max", Natural (Items.Length), 3);
   end;

   --  SPI mode 0: the capture starts with 3 bits of a word, then 9F EF,
   --  a pause, 40 18
   declare
      Per : constant := 20;   --  samples per bit, clock low then high

      function Word (W : Natural; Width : Positive) return String is
         R : String (1 .. Width);
      begin
         for K in 1 .. Width loop
            R (K) := (if W / 2**(Width - K) mod 2 = 1 then '1' else '0');
         end loop;
         return R;
      end Word;

      Bits : constant String :=
        "101" & "PPPPPP" & Word (16#9F#, 8) & Word (16#EF#, 8) & "PPPPPP" &
        Word (16#40#, 8) & Word (16#18#, 8) & "PPP";
      Clk  : Raw_Array (1 .. Bits'Length * Per);
      Dat  : Raw_Array (1 .. Bits'Length * Per);
      Used : Natural;
   begin
      for I in Clk'Range loop
         declare
            B    : constant Character := Bits (Bits'First + (I - 1) / Per);
            Half : constant Boolean := (I - 1) mod Per >= Per / 2;
         begin
            Clk (I) := Level (B /= 'P' and then Half);   --  P: a pause
            Dat (I) := Level (B = '1');
         end;
      end loop;

      Items.Clear;
      Decode_SPI (Digital_Of (Clk), Digital_Of (Dat), 2, (others => <>), Items, 100, Used);
      Check ("spi items", Natural (Items.Length), 4);
      if Items.Length = 4 then
         Check ("spi 9F", Value (1), 16#9F#);
         Check ("spi EF", Value (2), 16#EF#);
         Check ("spi 40", Value (3), 16#40#);
         Check ("spi 18", Value (4), 16#18#);
      end if;
      Check ("spi automatic timeout", Used, 3 * Per / 2);

      Items.Clear;
      Decode_SPI (Digital_Of (Clk), Digital_Of (Dat), 2,
                  (Width => 16, others => <>), Items, 100, Used);
      Check ("spi 16-bit items", Natural (Items.Length), 2);
      if Items.Length = 2 then
         Check ("spi 9FEF", Value (1), 16#9FEF#);
         Check ("spi 4018", Value (2), 16#4018#);
      end if;

      Items.Clear;
      Decode_SPI (Digital_Of (Clk), Digital_Of (Dat), 2,
                  (MSB_First => False, others => <>), Items, 100, Used);
      Check ("spi LSB first", Items.Length = 4 and then Value (1) = 16#F9#);

      --  Sampled on the falling edge the data has already moved on
      Items.Clear;
      Decode_SPI (Digital_Of (Clk), Digital_Of (Dat), 2,
                  (Sample_On_Rise => False, others => <>), Items, 100, Used);
      Check ("spi falling edge differs", Items.Length = 0 or else Value (1) /= 16#9F#);
   end;

   --  A flat line is no signal
   declare
      Flat_Line : constant Raw_Array (1 .. 1000) := (others => 128);
      Th, Hy : Float;
      Flat   : Boolean;
   begin
      Auto_Threshold (Flat_Line, 1, 1000, Th, Hy, Flat);
      Check ("flat detected", Flat);
   end;

   Put_Line ("passed:" & Passed'Image & "   failed:" & Failed'Image);
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Test_Decode;
