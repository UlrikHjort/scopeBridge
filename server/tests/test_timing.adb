-- ***************************************************************************
--                  ScopeBridge Server - Code Timing Tests
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

--  Checks Server.Timing against signals whose every edge is known.
--  Built and run by `make check-server`.

with Ada.Text_IO;            use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Containers;         use type Ada.Containers.Count_Type;
with Interfaces;             use Interfaces;

with Server.Decode;          use Server.Decode;
with Server.Timing;          use Server.Timing;
with Rigol.Waveform;         use Rigol.Waveform;

procedure Test_Timing is
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

   procedure Check (Name : String; Got, Want : Long_Float; Tolerance : Long_Float := 1.0E-9) is
   begin
      Check (Name & ": got" & Got'Image & ", want" & Want'Image,
             abs (Got - Want) <= Tolerance);
   end Check;

   Seed : Unsigned_32 := 7;

   function Noise return Integer is
   begin
      Seed := Seed * 1_103_515_245 + 12_345;
      return Integer (Shift_Right (Seed, 16) mod 9) - 4;
   end Noise;

   --  Samples from a list of (level, length) runs, with a little noise
   type Run is record
      High   : Boolean;
      Length : Positive;
   end record;
   type Runs is array (Positive range <>) of Run;

   function Line (R : Runs) return Digital is
      Total : Natural := 0;
   begin
      for X of R loop
         Total := Total + X.Length;
      end loop;
      declare
         Data : Raw_Array (1 .. Total);
         P    : Positive := 1;
      begin
         for X of R loop
            for K in 1 .. X.Length loop
               Data (P) := Raw_Sample ((if X.High then 200 else 50) + Noise);
               P := P + 1;
            end loop;
         end loop;
         return Digitize (Data, 1, Total, 125.0, 15.0);
      end;
   end Line;

   H : constant Boolean := True;
   L : constant Boolean := False;

   --  A block of 100, 110, 120, 300 samples, idle 400 each; the capture
   --  starts inside a block (not complete) and ends idle
   A : constant Digital := Line
     (Runs'((H, 50), (L, 400), (H, 100), (L, 400), (H, 110), (L, 400), (H, 120),
      (L, 400), (H, 300), (L, 400)));
begin
   declare
      P : constant Interval_List := Pulses (A, High => True);
      S : constant Stats := Statistics (P);
   begin
      Check ("four complete blocks", P.Length = 4);
      Check ("first block starts at 450", P.First_Element.Start = 450);
      Check ("count", Long_Float (S.Count), 4.0);
      Check ("min", Long_Float (S.Min), 100.0);
      Check ("max", Long_Float (S.Max), 300.0);
      Check ("mean", S.Mean, 157.5);
      Check ("median of an even count", S.Median, 115.0);
      Check ("std dev", S.Std_Dev, 82.5757, 1.0E-3);
      Check ("the longest starts at 1980", S.Max_At.Start = 1980);
      Check ("the shortest starts at 450", S.Min_At.Start = 450);
   end;

   declare
      P : constant Interval_List := Pulses (A, High => False);
      S : constant Stats := Statistics (P);
   begin
      --  Idle stretches between blocks; the last runs off the capture
      Check ("four complete idles", P.Length = 4);
      Check ("idle min = max = 400", S.Min = 400 and then S.Max = 400);
   end;

   declare
      P : constant Interval_List := Periods (A, High => True);
      S : constant Stats := Statistics (P);
   begin
      Check ("three periods", P.Length = 3);
      Check ("periods 500 .. 520", S.Min = 500 and then S.Max = 520);
   end;

   --  B starts 40 samples after A's first block, 30 after the next two,
   --  and not after the last
   declare
      B : constant Digital := Line
        (Runs'((L, 490), (H, 20), (L, 470), (H, 20), (L, 490), (H, 20), (L, 1000)));
      P : constant Interval_List := Latencies (A, B, True, True);
      S : constant Stats := Statistics (P);
   begin
      Check ("latencies for the blocks B follows", P.Length = 3);
      Check ("latency 40 then 30", S.Max = 40 and then S.Min = 30);
   end;

   --  Bursts: a loop of 3 iterations, then of 5, then 3, each pulse 10
   --  high and 10 low; 200 idle between loops; the capture begins and ends
   --  inside a burst
   declare
      function Burst (N : Positive) return Runs is
         R : Runs (1 .. 2 * N - 1);
      begin
         for K in 1 .. N loop
            R (2 * K - 1) := (H, 10);
            if K < N then
               R (2 * K) := (L, 10);
            end if;
         end loop;
         return R;
      end Burst;
      Idle : constant Runs := (1 => (L, 200));
      C : constant Digital := Line
        (Runs'(1 => (L, 5)) & Burst (2) & Idle & Burst (3) & Idle &
         Burst (5) & Idle & Burst (3) & Idle & Burst (2));
      Spans, Counts : Interval_List;
   begin
      Bursts (C, True, 50, Spans, Counts);
      Check ("three whole bursts (the first and last cut off)", Spans.Length = 3);
      if Counts.Length = 3 then
         Check ("3, 5, 3 iterations", Counts (1).Length = 3 and then Counts (2).Length = 5
                and then Counts (3).Length = 3);
         Check ("a burst of 3 spans 50", Spans (1).Length = 50);
         Check ("a burst of 5 spans 90", Spans (2).Length = 90);
      end if;
   end;

   --  Histogram: the four blocks over 100 .. 300 in 4 bins
   declare
      Hist : constant Counts_Array := Histogram (Pulses (A, True), 4);
   begin
      Check ("histogram bins", Hist'Length = 4);
      Check ("histogram counts", Hist = (3, 0, 0, 1));
      Check ("one bin when all equal", Histogram (Pulses (A, False), 4)'Length = 1);
   end;

   --  Active low: the block is low
   declare
      N : constant Digital := Line (Runs'((H, 100), (L, 70), (H, 100), (L, 80), (H, 100)));
      S : constant Stats := Statistics (Pulses (N, High => False));
   begin
      Check ("active low blocks", S.Count = 2 and then S.Min = 70 and then S.Max = 80);
   end;

   Check ("nothing to measure", Statistics (Pulses (Line (Runs'(1 => (H, 100))), True)).Count = 0);

   Put_Line ("passed:" & Passed'Image & "   failed:" & Failed'Image);
   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Test_Timing;
