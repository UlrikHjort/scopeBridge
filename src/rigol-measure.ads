-- ***************************************************************************
--                      Rigol - Measure Commands Specification
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

--  :MEASure command group.
--  Automated voltage and time measurements on analog channels.
--  Each measurement is a single query returning a Float value.

with Rigol.Channel;

package Rigol.Measure is

   --  All measurable parameters supported by :MEASure:ITEM
   type Measure_Item is
     (--  Voltage measurements
      VMAX, VMIN, VPP, VTOP, VBASE, VAMP, VAVG, VRMS,
      VUPPER, VMID, VLOWER, VARIANCE, PVRMS,
      --  Overshoot / preshoot
      OVER, PRES,
      --  Time / frequency measurements
      Period, Frequency,
      Rise_Time, Fall_Time,
      Pos_Width, Neg_Width,
      Pos_Duty, Neg_Duty,
      --  Delay / phase
      Rise_Delay, Fall_Delay,
      Rise_Phase, Fall_Phase,
      --  Slew rate
      Pos_Slew_Rate, Neg_Slew_Rate,
      --  Time-of extrema
      T_VMAX, T_VMIN);

   --  Source channel for a measurement
   subtype Measure_Source is Rigol.Channel.Channel_Number;

   -- -------------------------------------------------------------------------

   --  :MEASure:ITEM <item>,CHAN<n>
   --  Returns the numeric result.  Returns Float'Last on overflow / invalid,
   --  including when the scope cannot measure the item (it reports
   --  9.9E37, e.g. Frequency with no periodic signal on the channel).
   --  The measurement is not added to the scope's screen (see Show).
   --  The first Get of an item takes a few hundred milliseconds while the
   --  scope starts measuring it; after that about a millisecond.
   function Get
     (Scope   : in out Oscilloscope;
      Item    : in     Measure_Item;
      Channel : in     Measure_Source) return Float;

   --  :MEASure:ITEM <item>,CHAN<n> - show the measurement on the scope's
   --  screen.  Queries sent right after it wait ~50 ms while the scope
   --  applies it, so avoid it in fast loops.
   procedure Show
     (Scope   : in out Oscilloscope;
      Item    : in     Measure_Item;
      Channel : in     Measure_Source);

   --  False for the Float'Last "no valid result" value returned by Get
   --  and the convenience wrappers below.
   function Is_Valid (Value : Float) return Boolean is (Value /= Float'Last);

   -- -------------------------------------------------------------------------
   --  Convenience wrappers for the most common measurements
   -- -------------------------------------------------------------------------

   function Frequency   (Scope : in out Oscilloscope;
                         Ch    : Measure_Source) return Float;
   function Period      (Scope : in out Oscilloscope;
                         Ch    : Measure_Source) return Float;
   function VPP         (Scope : in out Oscilloscope;
                         Ch    : Measure_Source) return Float;
   function VRMS        (Scope : in out Oscilloscope;
                         Ch    : Measure_Source) return Float;
   function VMAX        (Scope : in out Oscilloscope;
                         Ch    : Measure_Source) return Float;
   function VMIN        (Scope : in out Oscilloscope;
                         Ch    : Measure_Source) return Float;
   function Rise_Time   (Scope : in out Oscilloscope;
                         Ch    : Measure_Source) return Float;
   function Fall_Time   (Scope : in out Oscilloscope;
                         Ch    : Measure_Source) return Float;

   -- -------------------------------------------------------------------------

   --  :MEASure:CLEar - remove all on-screen measurement items
   procedure Clear_All (Scope : in out Oscilloscope);

   --  :MEASure:SOURce CHAN<n> - set default measurement source
   procedure Set_Source
     (Scope   : in out Oscilloscope;
      Channel : in     Measure_Source);

end Rigol.Measure;
