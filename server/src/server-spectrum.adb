-- ***************************************************************************
--                    ScopeBridge Server - Spectrum Body
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

with Ada.Numerics;
with Ada.Unchecked_Deallocation;
with Ada.Numerics.Long_Elementary_Functions;
use  Ada.Numerics.Long_Elementary_Functions;

package body Server.Spectrum is

   Pi : constant := Ada.Numerics.Pi;

   type Complex is record
      Re, Im : Long_Float;
   end record;

   type Complex_Array is array (Natural range <>) of Complex;
   type Complex_Access is access Complex_Array;

   --  In-place iterative radix-2 FFT; X'Length must be a power of two
   procedure FFT (X : in out Complex_Array) is
      N : constant Natural := X'Length;
      J : Natural := 0;
      Len : Natural := 2;
   begin
      --  Bit-reversal permutation
      for I in 0 .. N - 2 loop
         if I < J then
            declare
               T : constant Complex := X (X'First + I);
            begin
               X (X'First + I) := X (X'First + J);
               X (X'First + J) := T;
            end;
         end if;
         declare
            M : Natural := N / 2;
         begin
            while M >= 1 and then J >= M loop
               J := J - M;
               M := M / 2;
            end loop;
            J := J + M;
         end;
      end loop;

      --  Butterflies
      while Len <= N loop
         declare
            Angle : constant Long_Float := -2.0 * Pi / Long_Float (Len);
            W_Re  : constant Long_Float := Cos (Angle);
            W_Im  : constant Long_Float := Sin (Angle);
            Half  : constant Natural := Len / 2;
         begin
            for Start in 0 .. N / Len - 1 loop
               declare
                  U_Re : Long_Float := 1.0;
                  U_Im : Long_Float := 0.0;
                  T    : Long_Float;
               begin
                  for K in 0 .. Half - 1 loop
                     declare
                        A : constant Natural := X'First + Start * Len + K;
                        B : constant Natural := A + Half;
                        V_Re : constant Long_Float :=
                          X (B).Re * U_Re - X (B).Im * U_Im;
                        V_Im : constant Long_Float :=
                          X (B).Re * U_Im + X (B).Im * U_Re;
                     begin
                        X (B) := (X (A).Re - V_Re, X (A).Im - V_Im);
                        X (A) := (X (A).Re + V_Re, X (A).Im + V_Im);
                     end;
                     T    := U_Re * W_Re - U_Im * W_Im;
                     U_Im := U_Re * W_Im + U_Im * W_Re;
                     U_Re := T;
                  end loop;
               end;
            end loop;
         end;
         Len := Len * 2;
      end loop;
   end FFT;

   function Window_Value (Kind : Window_Kind; I, N : Natural) return Long_Float
   is
      X : constant Long_Float := 2.0 * Pi * Long_Float (I) / Long_Float (N);
   begin
      case Kind is
         when Rectangle => return 1.0;
         when Hann      => return 0.5 - 0.5 * Cos (X);
         when Hamming   => return 0.54 - 0.46 * Cos (X);
         when Blackman  => return 0.42 - 0.5 * Cos (X) + 0.08 * Cos (2.0 * X);
         when Flattop   =>
            return 0.21557895 - 0.41663158 * Cos (X) + 0.277263158 * Cos (2.0 * X)
                   - 0.083578947 * Cos (3.0 * X) + 0.006947368 * Cos (4.0 * X);
      end case;
   end Window_Value;

   type Real_Access is access Real_Array;

   procedure Free is new Ada.Unchecked_Deallocation (Real_Array, Real_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Complex_Array, Complex_Access);

   function Compute
     (Length          : Natural;
      Sample          : not null access function (I : Natural) return Long_Float;
      Sample_Interval : Long_Float;
      Window          : Window_Kind;
      Bin_Width       : out Long_Float;
      Whole           : Boolean := False) return Real_Array
   is
      N    : Natural := 1;
      Used : Natural;   --  samples per segment that carry data
   begin
      if Length < Min_Length then
         raise Constraint_Error with "too few samples for a spectrum";
      elsif Whole and then Length > Max_Segment then
         raise Constraint_Error with "too many samples for one transform";
      end if;
      if Whole then
         while N < Length loop   --  the next power of two
            N := N * 2;
         end loop;
         Used := Length;
      else
         while N * 2 <= Length and then N * 2 <= Max_Segment loop
            N := N * 2;
         end loop;
         Used := N;
      end if;
      Bin_Width := 1.0 / (Long_Float (N) * Sample_Interval);

      declare
         --  Up to 1M points each: on the heap, not the stack
         Weights  : Real_Access    := new Real_Array (0 .. Used - 1);
         Power    : Real_Access    := new Real_Array'(0 .. N / 2 => 0.0);
         Buffer   : Complex_Access := new Complex_Array (0 .. N - 1);
         Segments : constant Positive := (if Whole then 1 else Length / N);
         Gain     : Long_Float := 0.0;    --  sum of the window
      begin
         --  The window spans the samples, not the zero padding
         for I in Weights'Range loop
            Weights (I) := Window_Value (Window, I, Used);
            Gain := Gain + Weights (I);
         end loop;

         for S in 0 .. Segments - 1 loop
            for I in 0 .. N - 1 loop
               Buffer (I) :=
                 (if I < Used then (Sample (S * N + I) * Weights (I), 0.0)
                  else (0.0, 0.0));
            end loop;
            FFT (Buffer.all);
            for K in Power'Range loop
               Power (K) := Power (K) + Buffer (K).Re ** 2 + Buffer (K).Im ** 2;
            end loop;
         end loop;

         return Result : Real_Array (0 .. N / 2) do
            --  |X(k)| / Gain is the peak amplitude of a sine in bin k,
            --  halved by the negative frequencies except at DC and
            --  Nyquist; RMS is peak / sqrt 2
            for K in Result'Range loop
               declare
                  Peak : constant Long_Float :=
                    Sqrt (Power (K) / Long_Float (Segments)) / Gain *
                    (if K = 0 or else K = N / 2 then 1.0 else 2.0);
                  RMS  : constant Long_Float :=
                    (if K = 0 then Peak else Peak / Sqrt (2.0));
               begin
                  Result (K) :=
                    (if RMS <= 1.0E-10 then Min_dBV else 20.0 * Log (RMS, 10.0));
               end;
            end loop;
            Free (Weights);
            Free (Power);
            Free (Buffer);
         end return;
      end;
   end Compute;

   function Compute
     (Samples         : Real_Array;
      Sample_Interval : Long_Float;
      Window          : Window_Kind;
      Bin_Width       : out Long_Float) return Real_Array
   is
      function Sample (I : Natural) return Long_Float is
        (Samples (Samples'First + I));
   begin
      return Compute (Samples'Length, Sample'Access, Sample_Interval, Window,
                      Bin_Width);
   end Compute;

end Server.Spectrum;
