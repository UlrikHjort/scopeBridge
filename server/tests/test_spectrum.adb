-- ***************************************************************************
--                   ScopeBridge Server - Spectrum Tests
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

--  Checks Server.Spectrum against signals with known spectra.
--  Built and run by `make check-server`.

with Ada.Text_IO;  use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Numerics;
with Ada.Numerics.Long_Elementary_Functions;
use  Ada.Numerics.Long_Elementary_Functions;

with Server.Spectrum;  use Server.Spectrum;

procedure Test_Spectrum is
   Failed : Natural := 0;
   Passed : Natural := 0;

   procedure Check (Name : String; Got, Want, Tolerance : Long_Float) is
   begin
      if abs (Got - Want) <= Tolerance then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Put_Line ("FAIL  " & Name & ": got" & Got'Image & ", want" & Want'Image);
      end if;
   end Check;

   Rate : constant Long_Float := 100_000.0;          --  Sa/s
   Dt   : constant Long_Float := 1.0 / Rate;

   --  A 1 V amplitude sine at F Hz plus DC, N samples
   function Sine (N : Positive; F, DC : Long_Float) return Real_Array is
      R : Real_Array (0 .. N - 1);
   begin
      for I in R'Range loop
         R (I) := DC + Sin (2.0 * Ada.Numerics.Pi * F * Long_Float (I) * Dt);
      end loop;
      return R;
   end Sine;

   function Peak_Bin (S : Real_Array) return Natural is
      Best : Natural := S'First + 1;
   begin
      for K in S'First + 1 .. S'Last loop
         if S (K) > S (Best) then
            Best := K;
         end if;
      end loop;
      return Best;
   end Peak_Bin;

   Width : Long_Float;
begin
   --  Exactly on a bin: 4096 samples, bin width 24.414 Hz, bin 41 = 1000.98 Hz
   declare
      F : constant Long_Float := 41.0 * Rate / 4096.0;
      S : constant Real_Array := Compute (Sine (4096, F, 0.5), Dt, Rectangle, Width);
   begin
      Check ("bin width", Width, Rate / 4096.0, 1.0E-9);
      Check ("bins", Long_Float (S'Length), 2049.0, 0.0);
      Check ("peak bin", Long_Float (Peak_Bin (S)), 41.0, 0.0);
      Check ("1 V sine is -3.01 dBV", S (41), -3.0103, 0.01);
      Check ("0.5 V DC is -6.02 dBV", S (0), -6.0206, 0.01);
      Check ("elsewhere nothing", S (100), Min_dBV, 0.0);
   end;

   --  Off a bin: windows keep the level within their scalloping loss
   for W in Window_Kind loop
      declare
         S : constant Real_Array := Compute (Sine (4096, 1000.0, 0.0), Dt, W, Width);
         Tol : constant Long_Float :=
           (case W is when Rectangle => 4.0, when Flattop => 0.05, when others => 1.5);
      begin
         Check (W'Image & " peak near 1 kHz",
                Long_Float (Peak_Bin (S)) * Width, 1000.0, Width);
         Check (W'Image & " level", S (Peak_Bin (S)), -3.0103, Tol);
      end;
   end loop;

   --  Longer than a segment: averaged, same level; 5000 samples use 4096
   declare
      S : constant Real_Array := Compute (Sine (20_000, 41.0 * Rate / 4096.0, 0.0),
                                          Dt, Hann, Width);
   begin
      Check ("segment length", Width, Rate / 16384.0, 1.0E-9);
      Check ("averaged level", S (Peak_Bin (S)), -3.0103 - 6.02 + 6.02, 1.5);
   end;

   --  Whole: 3000 samples padded to 4096 in one transform; the level
   --  holds, and the bins are those of 4096 points
   declare
      Data : constant Real_Array := Sine (3000, 41.0 * Rate / 4096.0, 0.0);
      function Sample (I : Natural) return Long_Float is (Data (I));
      S : constant Real_Array :=
        Compute (3000, Sample'Access, Dt, Flattop, Width, Whole => True);
   begin
      Check ("whole: bins of the padded length", Width, Rate / 4096.0, 1.0E-9);
      Check ("whole: peak bin", Long_Float (Peak_Bin (S)), 41.0, 1.0);
      Check ("whole: level", S (Peak_Bin (S)), -3.0103, 0.1);
   end;

   begin
      declare
         S : constant Real_Array := Compute (Sine (10, 1000.0, 0.0), Dt, Hann, Width);
      begin
         Check ("too short rejected", Long_Float (S'Length), -1.0, 0.0);
      end;
   exception
      when Constraint_Error => Passed := Passed + 1;
   end;

   Put_Line ("passed:" & Passed'Image & "   failed:" & Failed'Image);
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Test_Spectrum;
