-- ***************************************************************************
--                    Rigol - Pass/Fail Test Specification
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

--  :MASK command group: the pass/fail test.  The scope builds a mask
--  around the source channel's waveform, X divisions wide and Y
--  divisions high on either side of it (Create_Mask), then counts the
--  frames that stay inside it (passed) and those that leave it (failed).
--
--  The test needs the channel displayed, and does not run in XY or ROLL
--  mode, at 200 ms/div or slower, or while recording.  The mask can only
--  be created while the test is enabled and stopped.

with Rigol.Channel;

package Rigol.Mask is

   procedure Set_Enable (Scope : in out Oscilloscope; On : Boolean);
   function  Get_Enable (Scope : in out Oscilloscope) return Boolean;

   procedure Set_Source (Scope : in out Oscilloscope;
                         Ch    : Rigol.Channel.Channel_Number);
   function  Get_Source (Scope : in out Oscilloscope)
                         return Rigol.Channel.Channel_Number;

   --  :MASK:OPERate RUN / STOP
   procedure Set_Running (Scope : in out Oscilloscope; On : Boolean);
   function  Get_Running (Scope : in out Oscilloscope) return Boolean;

   --  The counts on the scope's screen
   procedure Set_Show_Statistics (Scope : in out Oscilloscope; On : Boolean);
   function  Get_Show_Statistics (Scope : in out Oscilloscope) return Boolean;

   --  Stop acquiring at the first failed frame
   procedure Set_Stop_On_Fail (Scope : in out Oscilloscope; On : Boolean);
   function  Get_Stop_On_Fail (Scope : in out Oscilloscope) return Boolean;

   --  Beep on a failed frame
   procedure Set_Beep (Scope : in out Oscilloscope; On : Boolean);
   function  Get_Beep (Scope : in out Oscilloscope) return Boolean;

   --  Mask margins, in divisions: X 0.02 .. 4, Y 0.04 .. 5.12 (steps of
   --  0.02 and 0.04)
   procedure Set_X (Scope : in out Oscilloscope; Divisions : Float);
   function  Get_X (Scope : in out Oscilloscope) return Float;
   procedure Set_Y (Scope : in out Oscilloscope; Divisions : Float);
   function  Get_Y (Scope : in out Oscilloscope) return Float;

   --  :MASK:CREate - a new mask around the current waveform
   procedure Create_Mask (Scope : in out Oscilloscope);

   --  Frame counts since the last Reset
   function Passed (Scope : in out Oscilloscope) return Long_Long_Integer;
   function Failed (Scope : in out Oscilloscope) return Long_Long_Integer;
   function Total  (Scope : in out Oscilloscope) return Long_Long_Integer;
   procedure Reset (Scope : in out Oscilloscope);

end Rigol.Mask;
