-- ***************************************************************************
--                      Rigol - Acquire Commands Specification
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

--  :ACQuire command group.
--  Controls acquisition mode, memory depth, averages count,
--  and provides read-back of the current sample rate.

package Rigol.Acquire is

   type Acquire_Type is (Normal, Averages, Peak, High_Resolution);
   --  NORM, AVER, PEAK, HRES

   --  Number of averages: must be a power of 2 in range 2 .. 1024
   subtype Average_Count is Positive
     with Dynamic_Predicate =>
       Average_Count in 2 | 4 | 8 | 16 | 32 | 64 | 128 | 256 | 512 | 1024;

   --  Memory depth in points; Auto_Depth lets the scope choose from the
   --  timebase.  The DS1000Z-E offers different depths for one and two
   --  channels, and converts between them when the number of channels
   --  on changes (120000 with one channel is 60000 with two).  It
   --  ignores a depth not offered for the channels on, and any change of
   --  depth while it is stopped.
   subtype Memory_Depth is Natural;
   Auto_Depth : constant Memory_Depth := 0;

   type Depth_List is array (Positive range <>) of Memory_Depth;
   Single_Channel_Depths : constant Depth_List :=
     (12_000, 120_000, 1_200_000, 12_000_000, 24_000_000);
   Dual_Channel_Depths   : constant Depth_List :=
     (6_000, 60_000, 600_000, 6_000_000, 12_000_000);

   -- -------------------------------------------------------------------------

   --  :ACQuire:TYPE - set acquisition mode
   procedure Set_Type
     (Scope : in out Oscilloscope;
      Mode  : in     Acquire_Type);

   function Get_Type
     (Scope : in out Oscilloscope) return Acquire_Type;

   -- -------------------------------------------------------------------------

   --  :ACQuire:AVERages - number of averages (only used in AVER mode)
   procedure Set_Averages
     (Scope : in out Oscilloscope;
      Count : in     Average_Count);

   function Get_Averages
     (Scope : in out Oscilloscope) return Positive;

   -- -------------------------------------------------------------------------

   --  :ACQuire:MDEPth - memory depth, or Auto_Depth
   procedure Set_Memory_Depth
     (Scope : in out Oscilloscope;
      Depth : in     Memory_Depth);

   function Get_Memory_Depth
     (Scope : in out Oscilloscope) return Memory_Depth;

   -- -------------------------------------------------------------------------

   --  :ACQuire:SRATe? - current sample rate in Sa/s (read-only)
   function Get_Sample_Rate
     (Scope : in out Oscilloscope) return Float;

end Rigol.Acquire;
