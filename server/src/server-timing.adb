-- ***************************************************************************
--                  ScopeBridge Server - Code Timing Body
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

with Ada.Numerics.Long_Elementary_Functions;

package body Server.Timing is

   --  The level after edge K
   function After (Line : Digital; K : Positive) return Boolean is
     (Line.Initial xor (K mod 2 = 1));

   function Edge_Count (Line : Digital) return Natural is
     (Natural (Line.Edges.Length));

   function Pulses (Line : Digital; High : Boolean) return Interval_List is
      Result : Interval_List;
   begin
      for K in 1 .. Edge_Count (Line) - 1 loop
         if After (Line, K) = High then
            Result.Append ((Start  => Line.Edges (K),
                            Length => Line.Edges (K + 1) - Line.Edges (K)));
         end if;
      end loop;
      return Result;
   end Pulses;

   function Periods (Line : Digital; High : Boolean) return Interval_List is
      Result : Interval_List;
   begin
      --  Edges into the same level are every other edge
      for K in 1 .. Edge_Count (Line) - 2 loop
         if After (Line, K) = High then
            Result.Append ((Start  => Line.Edges (K),
                            Length => Line.Edges (K + 2) - Line.Edges (K)));
         end if;
      end loop;
      return Result;
   end Periods;

   function Latencies
     (A, B : Digital; A_High, B_High : Boolean) return Interval_List
   is
      Result : Interval_List;
      J      : Positive := 1;   --  B's edges, walked alongside A's
   begin
      for K in 1 .. Edge_Count (A) loop
         if After (A, K) = A_High then
            while J <= Edge_Count (B)
              and then (B.Edges (J) < A.Edges (K) or else After (B, J) /= B_High)
            loop
               J := J + 1;
            end loop;
            exit when J > Edge_Count (B);
            Result.Append ((Start => A.Edges (K), Length => B.Edges (J) - A.Edges (K)));
         end if;
      end loop;
      return Result;
   end Latencies;

   procedure Bursts
     (Line   : Digital;
      High   : Boolean;
      Gap    : Positive;
      Spans  : out Interval_List;
      Counts : out Interval_List)
   is
      All_Pulses : constant Interval_List := Pulses (Line, High);
      First, Last : Interval;
      N           : Natural := 0;

      procedure Close is
      begin
         if N > 0 then
            Spans.Append ((First.Start, Last.Start + Last.Length - First.Start));
            Counts.Append ((First.Start, N));
         end if;
      end Close;
   begin
      Spans.Clear;
      Counts.Clear;
      for P of All_Pulses loop
         if N > 0 and then P.Start - (Last.Start + Last.Length) < Gap then
            Last := P;
            N    := N + 1;
         else
            Close;
            First := P;
            Last  := P;
            N     := 1;
         end if;
      end loop;
      --  The last burst may go on past the capture: only count it if a
      --  gap follows it within the capture
      if N > 0 and then Last.Start + Last.Length + Gap <= Line.Length then
         Close;
      end if;
      --  Likewise the first may have begun before the capture
      if not Spans.Is_Empty and then Spans.First_Element.Start < Gap then
         Spans.Delete_First;
         Counts.Delete_First;
      end if;
   end Bursts;

   package Natural_Vectors is new Ada.Containers.Vectors (Positive, Natural);
   package Sorting is new Natural_Vectors.Generic_Sorting;

   function Statistics (List : Interval_List) return Stats is
      use Ada.Numerics.Long_Elementary_Functions;
      S       : Stats;
      Sum     : Long_Float := 0.0;
      Squares : Long_Float := 0.0;
      Lengths : Natural_Vectors.Vector;
   begin
      S.Count := Natural (List.Length);
      if S.Count = 0 then
         return S;
      end if;
      S.Min    := Natural'Last;
      S.Max    := 0;
      for I of List loop
         if I.Length < S.Min then
            S.Min    := I.Length;
            S.Min_At := I;
         end if;
         if I.Length > S.Max then
            S.Max    := I.Length;
            S.Max_At := I;
         end if;
         Sum := Sum + Long_Float (I.Length);
         Lengths.Append (I.Length);
      end loop;
      S.Mean := Sum / Long_Float (S.Count);
      for I of List loop
         Squares := Squares + (Long_Float (I.Length) - S.Mean) ** 2;
      end loop;
      S.Std_Dev := Sqrt (Squares / Long_Float (S.Count));
      Sorting.Sort (Lengths);
      S.Median :=
        (if S.Count mod 2 = 1 then Long_Float (Lengths.Element ((S.Count + 1) / 2))
         else (Long_Float (Lengths.Element (S.Count / 2)) +
               Long_Float (Lengths.Element (S.Count / 2 + 1))) / 2.0);
      return S;
   end Statistics;

   function Histogram (List : Interval_List; Bins : Positive) return Counts_Array is
      S      : constant Stats := Statistics (List);
      Result : Counts_Array (1 .. (if S.Count = 0 or else S.Max = S.Min then 1 else Bins)) :=
        (others => 0);
      Span   : constant Natural := S.Max - S.Min;
   begin
      for I of List loop
         declare
            Bin : constant Positive :=
              (if Span = 0 then 1
               else Positive'Min (Result'Last,
                                  1 + (I.Length - S.Min) * Result'Length / Span));
         begin
            Result (Bin) := Result (Bin) + 1;
         end;
      end loop;
      return Result;
   end Histogram;

end Server.Timing;
