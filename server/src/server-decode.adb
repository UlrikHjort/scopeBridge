-- ***************************************************************************
--              ScopeBridge Server - Serial Bus Decoding Body
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

package body Server.Decode is

   use Interfaces;
   use Rigol.Waveform;

   Min_Swing : constant := 10.0;   --  counts: less is no logic signal

   function Digitize
     (Data        : Raw_Array;
      First, Last : Positive;
      Threshold   : Float;
      Hysteresis  : Float) return Digital
   is
      High_At : constant Float := Threshold + Hysteresis;
      Low_At  : constant Float := Threshold - Hysteresis;
      Result  : Digital;
      Level   : Boolean;
      V       : Float;
   begin
      Result.Length  := Last - First + 1;
      Result.Initial := Float (Data (First)) > Threshold;
      Level := Result.Initial;
      for I in First + 1 .. Last loop
         V := Float (Data (I));
         if Level then
            if V < Low_At then
               Level := False;
               Result.Edges.Append (I - First);
            end if;
         elsif V > High_At then
            Level := True;
            Result.Edges.Append (I - First);
         end if;
      end loop;
      return Result;
   end Digitize;

   procedure Auto_Threshold
     (Data        : Raw_Array;
      First, Last : Positive;
      Threshold   : out Float;
      Hysteresis  : out Float;
      Flat        : out Boolean)
   is
      Lo : Raw_Sample := Raw_Sample'Last;
      Hi : Raw_Sample := Raw_Sample'First;
   begin
      for I in First .. Last loop
         Lo := Raw_Sample'Min (Lo, Data (I));
         Hi := Raw_Sample'Max (Hi, Data (I));
      end loop;
      Threshold  := (Float (Lo) + Float (Hi)) / 2.0;
      Hysteresis := Float'Max (1.0, (Float (Hi) - Float (Lo)) / 10.0);
      Flat       := Float (Hi) - Float (Lo) < Min_Swing;
   end Auto_Threshold;

   --  Number of edges at or before sample I
   function Edges_Upto (Line : Digital; I : Natural) return Natural is
      Lo : Natural := 0;                           --  Edges (1 .. Lo) are <= I
      Hi : Natural := Natural (Line.Edges.Length); --  Edges (Hi + 1 ..) are > I
      M  : Natural;
   begin
      while Lo < Hi loop
         M := (Lo + Hi + 1) / 2;
         if Line.Edges (M) <= I then
            Lo := M;
         else
            Hi := M - 1;
         end if;
      end loop;
      return Lo;
   end Edges_Upto;

   function Level_At (Line : Digital; I : Natural) return Boolean is
     (Line.Initial xor (Edges_Upto (Line, I) mod 2 = 1));

   --  The level after edge K
   function Level_After (Line : Digital; K : Positive) return Boolean is
     (Line.Initial xor (K mod 2 = 1));

   function Before (A, B : Item) return Boolean is (A.First < B.First);
   package Sorting is new Item_Vectors.Generic_Sorting (Before);

   procedure Sort (Items : in out Item_Vectors.Vector) is
   begin
      Sorting.Sort (Items);
   end Sort;

   -- -------------------------------------------------------------------------
   --  UART
   -- -------------------------------------------------------------------------

   procedure Decode_UART
     (Line      : Digital;
      Ch        : Positive;
      Settings  : UART_Settings;
      Items     : in out Item_Vectors.Vector;
      Max_Items : Positive)
   is
      S          : UART_Settings renames Settings;
      Idle       : constant Boolean := not S.Inverted;
      Parity_Bit : constant Natural := (if S.Parity = None then 0 else 1);
      Frame      : constant Long_Float :=
        S.Samples_Per_Bit *
          (Long_Float (1 + S.Data_Bits + Parity_Bit) + S.Stop_Bits);
      N_Edges    : constant Natural := Natural (Line.Edges.Length);
      Synced     : Boolean := False;
      K          : Positive := 1;

      --  Sample in the middle of bit B of the frame starting at E (the
      --  start bit is bit 0)
      function Middle (E : Natural; B : Natural) return Natural is
        (E + Natural (Long_Float'Floor ((Long_Float (B) + 0.5) * S.Samples_Per_Bit)));

      --  The logical bit value (a high line is 1, after inversion)
      function Bit (E : Natural; B : Natural) return Boolean is
        (Level_At (Line, Middle (E, B)) = Idle);
   begin
      while K <= N_Edges and then Natural (Items.Length) < Max_Items loop
         declare
            E : constant Natural := Line.Edges (K);
         begin
            --  A start bit begins where the line leaves idle
            if Level_After (Line, K) /= Idle then
               if not Synced then
                  --  Idle for a whole frame before it, within the capture
                  Synced := Long_Float (E - (if K = 1 then 0 else Line.Edges (K - 1)))
                              >= Frame;
               end if;
               if Synced then
                  exit when Long_Float (E) + Frame > Long_Float (Line.Length);
                  if Bit (E, 0) then
                     --  Back to idle by mid start bit: a glitch
                     K := K + 1;
                  else
                     declare
                        Value : Unsigned_32 := 0;
                        Ones  : Natural := 0;
                        Error : Error_Kind := None;
                        Stop  : constant Natural := 1 + S.Data_Bits + Parity_Bit;
                        Next  : Natural;
                     begin
                        for B in 1 .. S.Data_Bits loop
                           if Bit (E, B) then
                              Ones := Ones + 1;
                              if S.MSB_First then
                                 Value := Value or Shift_Left (1, S.Data_Bits - B);
                              else
                                 Value := Value or Shift_Left (1, B - 1);
                              end if;
                           end if;
                        end loop;
                        if S.Parity /= None then
                           if Bit (E, 1 + S.Data_Bits) then
                              Ones := Ones + 1;
                           end if;
                           if (Ones mod 2 = 0) /= (S.Parity = Even) then
                              Error := Parity;
                           end if;
                        end if;
                        if not Bit (E, Stop)
                          or else (S.Stop_Bits >= 2.0 and then not Bit (E, Stop + 1))
                        then
                           Error := Framing;
                        end if;
                        Items.Append
                          ((Kind  => Data,
                            Line  => Ch,
                            First => E,
                            Last  => Natural'Min
                              (Line.Length - 1,
                               E + Natural (Long_Float'Floor (Frame)) - 1),
                            Value => Value,
                            Error => Error,
                            others => <>));
                        --  The next start bit comes after the middle of
                        --  the (first) stop bit
                        Next := Middle (E, Stop);
                        while K <= N_Edges and then Line.Edges (K) <= Next loop
                           K := K + 1;
                        end loop;
                     end;
                  end if;
               else
                  K := K + 1;
               end if;
            else
               K := K + 1;
            end if;
         end;
      end loop;
   end Decode_UART;

   -- -------------------------------------------------------------------------
   --  I2C
   -- -------------------------------------------------------------------------

   procedure Decode_I2C
     (SCL, SDA  : Digital;
      SDA_Ch    : Positive;
      Items     : in out Item_Vectors.Vector;
      Max_Items : Positive)
   is
      Clock_High  : Boolean := SCL.Initial;
      Data_High   : Boolean := SDA.Initial;
      In_Frame    : Boolean := False;   --  after a start condition
      Pending     : Boolean := False;   --  a bit sampled, SCL still high
      Pending_Bit : Boolean := False;
      Pending_At  : Natural := 0;
      Bits        : Natural := 0;       --  of the byte so far
      Byte        : Unsigned_32 := 0;
      Byte_First  : Natural := 0;
      Is_Address  : Boolean := False;   --  the byte is the first of a frame
      KC          : Positive := 1;      --  next clock and data edges
      KD          : Positive := 1;

      --  A bit completes when SCL falls with no start or stop meanwhile
      procedure Commit (Bit : Boolean; At_Sample, Fall : Natural) is
      begin
         if Bits = 0 then
            Byte_First := At_Sample;
            Byte       := 0;
         end if;
         if Bits < 8 then
            Byte := Shift_Left (Byte, 1) or (if Bit then 1 else 0);
            Bits := Bits + 1;
         else
            --  The ninth bit: low is an acknowledge
            Items.Append
              ((Kind  => (if Is_Address then Address else Data),
                Line  => SDA_Ch,
                First => Byte_First,
                Last  => Fall,
                Value => (if Is_Address then Shift_Right (Byte, 1) else Byte),
                Read  => Is_Address and then (Byte and 1) = 1,
                Ack   => not Bit,
                others => <>));
            Is_Address := False;
            Bits       := 0;
         end if;
      end Commit;
   begin
      while Natural (Items.Length) < Max_Items loop
         declare
            Has_C : constant Boolean := KC <= Natural (SCL.Edges.Length);
            Has_D : constant Boolean := KD <= Natural (SDA.Edges.Length);
         begin
            exit when not Has_C and then not Has_D;
            --  At the same sample, the clock edge first
            if Has_C and then (not Has_D or else SCL.Edges (KC) <= SDA.Edges (KD)) then
               declare
                  E : constant Natural := SCL.Edges (KC);
               begin
                  Clock_High := Level_After (SCL, KC);
                  if Clock_High then
                     if In_Frame then
                        Pending     := True;
                        Pending_Bit := Data_High;
                        Pending_At  := E;
                     end if;
                  elsif Pending then
                     Pending := False;
                     Commit (Pending_Bit, Pending_At, E);
                  end if;
                  KC := KC + 1;
               end;
            else
               declare
                  E : constant Natural := SDA.Edges (KD);
               begin
                  Data_High := Level_After (SDA, KD);
                  if Clock_High then
                     --  SDA changing while SCL is high: start or stop
                     Pending := False;
                     Bits    := 0;
                     Items.Append
                       ((Kind => (if Data_High then Stop else Start),
                         Line => SDA_Ch, First => E, Last => E, others => <>));
                     In_Frame   := not Data_High;
                     Is_Address := In_Frame;
                  end if;
                  KD := KD + 1;
               end;
            end if;
         end;
      end loop;
   end Decode_I2C;

   -- -------------------------------------------------------------------------
   --  SPI
   -- -------------------------------------------------------------------------

   --  The median time between clock edges, from the first ones
   function Usual_Gap (Clock : Digital) return Natural is
      N : constant Natural :=
        Natural'Min (Natural (Clock.Edges.Length) - 1, 100_000);
      type Gap_Array is array (1 .. N) of Natural;
      Gaps : Gap_Array;
      procedure Sort_Gaps is
         --  Counting would do, but a heap sort needs no bound on the gaps
         procedure Sift (Root, Last : Natural) is
            R : Natural := Root;
            C : Natural;
            T : Natural;
         begin
            loop
               C := 2 * R;
               exit when C > Last;
               if C < Last and then Gaps (C + 1) > Gaps (C) then
                  C := C + 1;
               end if;
               exit when Gaps (R) >= Gaps (C);
               T := Gaps (R);
               Gaps (R) := Gaps (C);
               Gaps (C) := T;
               R := C;
            end loop;
         end Sift;
         T : Natural;
      begin
         for Root in reverse 1 .. N / 2 loop
            Sift (Root, N);
         end loop;
         for Last in reverse 2 .. N loop
            T := Gaps (1);
            Gaps (1) := Gaps (Last);
            Gaps (Last) := T;
            Sift (1, Last - 1);
         end loop;
      end Sort_Gaps;
   begin
      if N < 1 then
         return 0;
      end if;
      for I in Gaps'Range loop
         Gaps (I) := Clock.Edges (I + 1) - Clock.Edges (I);
      end loop;
      Sort_Gaps;
      return Gaps ((N + 1) / 2);
   end Usual_Gap;

   procedure Decode_SPI
     (Clock, Data  : Digital;
      Data_Ch      : Positive;
      Settings     : SPI_Settings;
      Items        : in out Item_Vectors.Vector;
      Max_Items    : Positive;
      Timeout_Used : out Natural)
   is
      S        : SPI_Settings renames Settings;
      Timeout  : constant Natural :=
        (if S.Timeout > 0 then S.Timeout
         else Natural'Max (2, 3 * Usual_Gap (Clock)));
      Synced   : Boolean := False;
      Bits     : Natural := 0;
      Word     : Unsigned_32 := 0;
      First    : Natural := 0;
      Previous : Natural := 0;
   begin
      Timeout_Used := Timeout;
      for K in 1 .. Natural (Clock.Edges.Length) loop
         exit when Natural (Items.Length) >= Max_Items;
         declare
            E : constant Natural := Clock.Edges (K);
         begin
            if E - Previous > Timeout then
               --  A pause: whatever came before is not part of this word
               Synced := True;
               Bits   := 0;
            end if;
            Previous := E;
            if Synced and then Level_After (Clock, K) = S.Sample_On_Rise then
               declare
                  Bit : constant Boolean := Level_At (Data, E) /= S.Inverted;
               begin
                  if Bits = 0 then
                     First := E;
                     Word  := 0;
                  end if;
                  if Bit then
                     Word := Word or
                       Shift_Left (1, (if S.MSB_First then S.Width - 1 - Bits else Bits));
                  end if;
                  Bits := Bits + 1;
                  if Bits = S.Width then
                     Items.Append
                       ((Kind => Server.Decode.Data, Line => Data_Ch, First => First, Last => E,
                         Value => Word, others => <>));
                     Bits := 0;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Decode_SPI;

end Server.Decode;
