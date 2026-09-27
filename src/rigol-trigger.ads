-- ***************************************************************************
--                      Rigol - Trigger Commands Specification
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

--  :TRIGger command group.
--  Covers trigger mode, sweep, coupling, status, hold-off,
--  and the most common trigger types: Edge, Pulse, Slope.

package Rigol.Trigger is

   type Trigger_Mode is
     (Edge, Pulse, Slope, Video, Pattern, Duration,
      Timeout, Runt, Windows, Trig_Delay, Setup_Hold, NEDGe, RS232, I2C, SPI);

   type Trigger_Sweep is (Auto, Normal, Single);

   type Trigger_Coupling is (AC, DC, LF_Reject, HF_Reject);

   type Trigger_Status is (TD, Wait, Run, Auto, Armed, Stop);

   type Edge_Slope is (Rising, Falling, Either);

   type Trigger_Source is
     (CH1, CH2, AC_Line, EXT);

   -- -------------------------------------------------------------------------

   --  :TRIGger:MODE - trigger type
   procedure Set_Mode
     (Scope : in out Oscilloscope;
      Mode  : in     Trigger_Mode);

   function Get_Mode
     (Scope : in out Oscilloscope) return Trigger_Mode;

   -- -------------------------------------------------------------------------

   --  :TRIGger:SWEep - Auto / Normal / Single
   procedure Set_Sweep
     (Scope : in out Oscilloscope;
      Sweep : in     Trigger_Sweep);

   function Get_Sweep
     (Scope : in out Oscilloscope) return Trigger_Sweep;

   -- -------------------------------------------------------------------------

   --  :TRIGger:COUPling - trigger coupling
   procedure Set_Coupling
     (Scope    : in out Oscilloscope;
      Coupling : in     Trigger_Coupling);

   -- -------------------------------------------------------------------------

   --  :TRIGger:STATus? - read current trigger state (read-only)
   function Get_Status
     (Scope : in out Oscilloscope) return Trigger_Status;

   -- -------------------------------------------------------------------------

   --  :TRIGger:HOLDoff - holdoff time in seconds (16ns .. 10s)
   procedure Set_Holdoff
     (Scope   : in out Oscilloscope;
      Seconds : in     Float);

   -- -------------------------------------------------------------------------
   --  Edge trigger sub-group  (:TRIGger:EDGe:...)
   -- -------------------------------------------------------------------------

   procedure Set_Edge_Source
     (Scope  : in out Oscilloscope;
      Source : in     Trigger_Source);

   procedure Set_Edge_Slope
     (Scope : in out Oscilloscope;
      Slope : in     Edge_Slope);

   procedure Set_Edge_Level
     (Scope  : in out Oscilloscope;
      Volts  : in     Float);

   function Get_Edge_Source
     (Scope : in out Oscilloscope) return Trigger_Source;

   function Get_Edge_Slope
     (Scope : in out Oscilloscope) return Edge_Slope;

   function Get_Edge_Level
     (Scope : in out Oscilloscope) return Float;

   -- -------------------------------------------------------------------------
   --  Pulse trigger sub-group  (:TRIGger:PULse:...)
   -- -------------------------------------------------------------------------

   --  When a pulse trigger fires: the positive or negative pulse width is
   --  greater or less than a width, or within a range (lower .. upper).
   --  The slope trigger uses the same conditions for its slope time.
   type Pulse_When is
     (Pos_Greater, Pos_Less, Neg_Greater, Neg_Less, Pos_In_Range, Neg_In_Range);
   subtype Slope_When is Pulse_When;

   --  Pulse and slope triggers take CH1 or CH2 only
   procedure Set_Pulse_Source (Scope : in out Oscilloscope; Source : Trigger_Source);
   function  Get_Pulse_Source (Scope : in out Oscilloscope) return Trigger_Source;
   procedure Set_Pulse_When   (Scope : in out Oscilloscope; Condition : Pulse_When);
   function  Get_Pulse_When   (Scope : in out Oscilloscope) return Pulse_When;
   --  For the greater and less conditions (8 ns .. 10 s)
   procedure Set_Pulse_Width  (Scope : in out Oscilloscope; Seconds : Float);
   function  Get_Pulse_Width  (Scope : in out Oscilloscope) return Float;
   --  For the range conditions.  The scope keeps lower below upper by
   --  clamping the one being set, so set upper, lower, then upper again to
   --  move a range anywhere.
   procedure Set_Pulse_Upper  (Scope : in out Oscilloscope; Seconds : Float);
   function  Get_Pulse_Upper  (Scope : in out Oscilloscope) return Float;
   procedure Set_Pulse_Lower  (Scope : in out Oscilloscope; Seconds : Float);
   function  Get_Pulse_Lower  (Scope : in out Oscilloscope) return Float;
   procedure Set_Pulse_Level  (Scope : in out Oscilloscope; Volts : Float);
   function  Get_Pulse_Level  (Scope : in out Oscilloscope) return Float;

   -- -------------------------------------------------------------------------
   --  Slope trigger sub-group  (:TRIGger:SLOPe:...): fires on the time the
   --  signal takes to cross from one level to another
   -- -------------------------------------------------------------------------

   --  Which of the two levels is adjusted: A (upper), B (lower), or both
   type Slope_Window is (Level_A, Level_B, Both);

   procedure Set_Slope_Source  (Scope : in out Oscilloscope; Source : Trigger_Source);
   function  Get_Slope_Source  (Scope : in out Oscilloscope) return Trigger_Source;
   procedure Set_Slope_When    (Scope : in out Oscilloscope; Condition : Slope_When);
   function  Get_Slope_When    (Scope : in out Oscilloscope) return Slope_When;
   procedure Set_Slope_Time    (Scope : in out Oscilloscope; Seconds : Float);
   function  Get_Slope_Time    (Scope : in out Oscilloscope) return Float;
   procedure Set_Slope_Upper   (Scope : in out Oscilloscope; Seconds : Float);
   function  Get_Slope_Upper   (Scope : in out Oscilloscope) return Float;
   procedure Set_Slope_Lower   (Scope : in out Oscilloscope; Seconds : Float);
   function  Get_Slope_Lower   (Scope : in out Oscilloscope) return Float;
   procedure Set_Slope_Window  (Scope : in out Oscilloscope; Window : Slope_Window);
   function  Get_Slope_Window  (Scope : in out Oscilloscope) return Slope_Window;
   procedure Set_Slope_Level_A (Scope : in out Oscilloscope; Volts : Float);
   function  Get_Slope_Level_A (Scope : in out Oscilloscope) return Float;
   procedure Set_Slope_Level_B (Scope : in out Oscilloscope; Volts : Float);
   function  Get_Slope_Level_B (Scope : in out Oscilloscope) return Float;

end Rigol.Trigger;
