-- ***************************************************************************
--                      Rigol - Timebase Commands Specification
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

--  :TIMebase command group.
--  Controls horizontal timebase scale, offset, and mode (YT / XY / Roll).
--  Also exposes the optional delayed-sweep (zoom) window.

package Rigol.Timebase is

   type Timebase_Mode is (YT, XY, Roll);

   -- -------------------------------------------------------------------------

   --  :TIMebase[:MAIN]:SCALe - seconds per division (main timebase)
   --  Range: 5ns/div to 50s/div depending on model
   procedure Set_Scale
     (Scope           : in out Oscilloscope;
      Seconds_Per_Div : in     Float);

   function Get_Scale
     (Scope : in out Oscilloscope) return Float;

   -- -------------------------------------------------------------------------

   --  :TIMebase[:MAIN]:OFFSet - horizontal offset in seconds
   procedure Set_Offset
     (Scope   : in out Oscilloscope;
      Seconds : in     Float);

   function Get_Offset
     (Scope : in out Oscilloscope) return Float;

   -- -------------------------------------------------------------------------

   --  :TIMebase:MODE - YT / XY / ROLL
   procedure Set_Mode
     (Scope : in out Oscilloscope;
      Mode  : in     Timebase_Mode);

   function Get_Mode
     (Scope : in out Oscilloscope) return Timebase_Mode;

   -- -------------------------------------------------------------------------
   --  Delayed sweep (zoom window)
   -- -------------------------------------------------------------------------

   --  :TIMebase:DELay:ENABle
   procedure Set_Delay_Enable
     (Scope   : in out Oscilloscope;
      Enabled : in     Boolean);

   --  :TIMebase:DELay:SCALe - delayed window seconds/div
   procedure Set_Delay_Scale
     (Scope           : in out Oscilloscope;
      Seconds_Per_Div : in     Float);

   --  :TIMebase:DELay:OFFSet - delayed window offset
   procedure Set_Delay_Offset
     (Scope   : in out Oscilloscope;
      Seconds : in     Float);

end Rigol.Timebase;
