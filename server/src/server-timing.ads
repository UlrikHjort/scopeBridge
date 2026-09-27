-- ***************************************************************************
--              ScopeBridge Server - Code Timing Specification
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

--  Timing code with the scope: a program sets a pin while a block of code
--  runs and clears it after, and this measures every such block in a
--  capture.  From the pin's logic levels (Server.Decode.Digitize) it
--  finds complete pulses (both edges in the capture), the time between
--  them, their period, the latency from pulses on one channel to those on
--  another, and bursts of pulses (the iterations of a loop); and for each
--  kind statistics, a histogram and where the extremes are.
--
--  All durations are in samples; the caller scales them by the sample
--  interval.  They are exact to a sample.

with Ada.Containers.Vectors;

with Server.Decode;

package Server.Timing is

   use Server.Decode;

   --  A stretch of the capture: from sample Start, Length samples long
   --  (for pulse counts of bursts, Length is the count)
   type Interval is record
      Start  : Natural := 0;
      Length : Natural := 0;
   end record;

   package Interval_Vectors is new Ada.Containers.Vectors (Positive, Interval);
   subtype Interval_List is Interval_Vectors.Vector;

   --  Complete pulses at level High (True) or low: each from the edge into
   --  the level to the edge out of it
   function Pulses (Line : Digital; High : Boolean) return Interval_List;

   --  From each edge into level High to the next one: a pulse and the
   --  time after it
   function Periods (Line : Digital; High : Boolean) return Interval_List;

   --  From each edge of A into level A_High to the first edge of B into
   --  level B_High at or after it
   function Latencies
     (A, B : Digital; A_High, B_High : Boolean) return Interval_List;

   --  Pulses closer together than Gap samples, as bursts: Spans from the
   --  first pulse's start to the last one's end, Counts the pulses in each
   procedure Bursts
     (Line   : Digital;
      High   : Boolean;
      Gap    : Positive;
      Spans  : out Interval_List;
      Counts : out Interval_List);

   type Stats is record
      Count   : Natural := 0;
      Min     : Natural := 0;
      Max     : Natural := 0;
      Min_At  : Interval;          --  the shortest, and the longest
      Max_At  : Interval;
      Mean    : Long_Float := 0.0;
      Std_Dev : Long_Float := 0.0;   --  of the population
      Median  : Long_Float := 0.0;
   end record;

   function Statistics (List : Interval_List) return Stats;

   --  The lengths counted in Bins equal bins from the shortest to the
   --  longest (one bin if they are all equal)
   type Counts_Array is array (Positive range <>) of Natural;
   function Histogram (List : Interval_List; Bins : Positive) return Counts_Array;

end Server.Timing;
