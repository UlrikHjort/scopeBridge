-- ***************************************************************************
--                 ScopeBridge GUI - Engineering Units Body
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

with Ada.Numerics.Elementary_Functions;  use Ada.Numerics.Elementary_Functions;
with Ada.Strings.Fixed;                  use Ada.Strings.Fixed;

package body Units is

   function Eng (X : Float; Unit : String) return String is
      Prefixes : constant String := "pnum kMG";   --  ' ' = none
      A        : constant Float  := abs X;
      Power    : Integer := 0;     --  of 1000
      M        : Float;

      function Image (V : Float; Decimals : Natural) return String is
         Scaled : constant Integer := Integer (V * 10.0 ** Decimals);
         Digits_Image : constant String :=
           Trim (Integer'Image (abs Scaled), Ada.Strings.Left);
         Padded : constant String :=
           (1 .. Decimals + 1 - Integer'Min (Digits_Image'Length, Decimals + 1)
              => '0') & Digits_Image;
         Sign   : constant String := (if Scaled < 0 then "-" else "");
      begin
         if Decimals = 0 then
            return Sign & Padded;
         end if;
         return Sign & Padded (Padded'First .. Padded'Last - Decimals) & "." &
                Padded (Padded'Last - Decimals + 1 .. Padded'Last);
      end Image;
   begin
      if A < 1.0E-15 then
         return "0 " & Unit;
      end if;
      Power := Integer (Float'Floor (Log (A, 10.0) / 3.0));
      Power := Integer'Max (-4, Integer'Min (3, Power));
      M := X / 1000.0 ** Power;
      --  999.99 us would show as 1000 us
      if abs M >= 999.5 and then Power < 3 then
         Power := Power + 1;
         M := X / 1000.0 ** Power;
      end if;

      declare
         Decimals : constant Natural :=
           (if abs M >= 99.95 then 0 elsif abs M >= 9.995 then 1 else 2);
         P        : constant Character := Prefixes (Power + 5);
      begin
         return Image (M, Decimals) & " " &
                (if P = ' ' then "" elsif P = 'u' then "µ" else (1 => P)) &
                Unit;
      end;
   end Eng;

   function Steps_125 (Low, High : Float) return Float_Array is
      Result : Float_Array (1 .. 64);
      N      : Natural := 0;
      Decade : Float   := 10.0 ** Integer (Float'Floor (Log (Low, 10.0)));
   begin
      loop
         for Mantissa of Float_Array'(1.0, 2.0, 5.0) loop
            declare
               V : constant Float := Mantissa * Decade;
            begin
               if V >= Low * 0.999 and then V <= High * 1.001 then
                  N := N + 1;
                  Result (N) := V;
               end if;
            end;
         end loop;
         Decade := Decade * 10.0;
         exit when Decade > High * 1.001 or else N = Result'Last - 3;
      end loop;
      return Result (1 .. N);
   end Steps_125;

   function Nearest (Values : Float_Array; X : Float) return Positive is
      Best : Positive := Values'First;
   begin
      if X <= 0.0 then
         return Best;
      end if;
      for I in Values'Range loop
         if abs (Log (Values (I) / X)) < abs (Log (Values (Best) / X)) then
            Best := I;
         end if;
      end loop;
      return Best;
   end Nearest;

end Units;
