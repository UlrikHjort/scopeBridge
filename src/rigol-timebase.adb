-- ***************************************************************************
--                      Rigol - Timebase Commands Body
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

package body Rigol.Timebase is

   -- -------------------------------------------------------------------------

   procedure Set_Scale
     (Scope           : in out Oscilloscope;
      Seconds_Per_Div : in     Float)
   is
   begin
      Send (Scope, ":TIMebase:MAIN:SCALe " & Image (Seconds_Per_Div));
   end Set_Scale;

   function Get_Scale (Scope : in out Oscilloscope) return Float is
   begin
      return Float'Value (Query (Scope, ":TIMebase:MAIN:SCALe?"));
   end Get_Scale;

   -- -------------------------------------------------------------------------

   procedure Set_Offset
     (Scope   : in out Oscilloscope;
      Seconds : in     Float)
   is
   begin
      Send (Scope, ":TIMebase:MAIN:OFFSet " & Image (Seconds));
   end Set_Offset;

   function Get_Offset (Scope : in out Oscilloscope) return Float is
   begin
      return Float'Value (Query (Scope, ":TIMebase:MAIN:OFFSet?"));
   end Get_Offset;

   -- -------------------------------------------------------------------------

   procedure Set_Mode
     (Scope : in out Oscilloscope;
      Mode  : in     Timebase_Mode)
   is
      Val : constant String :=
        (case Mode is
           when YT   => "MAIN",
           when XY   => "XY",
           when Roll => "ROLL");
   begin
      Send (Scope, ":TIMebase:MODE " & Val);
   end Set_Mode;

   function Get_Mode (Scope : in out Oscilloscope) return Timebase_Mode is
      R : constant String := Query (Scope, ":TIMebase:MODE?");
   begin
      if    R = "XY"   then return XY;
      elsif R = "ROLL" then return Roll;
      else                  return YT;
      end if;
   end Get_Mode;

   -- -------------------------------------------------------------------------

   procedure Set_Delay_Enable
     (Scope   : in out Oscilloscope;
      Enabled : in     Boolean)
   is
   begin
      Send (Scope, ":TIMebase:DELay:ENABle " &
            (if Enabled then "1" else "0"));
   end Set_Delay_Enable;

   procedure Set_Delay_Scale
     (Scope           : in out Oscilloscope;
      Seconds_Per_Div : in     Float)
   is
   begin
      Send (Scope, ":TIMebase:DELay:SCALe " & Image (Seconds_Per_Div));
   end Set_Delay_Scale;

   procedure Set_Delay_Offset
     (Scope   : in out Oscilloscope;
      Seconds : in     Float)
   is
   begin
      Send (Scope, ":TIMebase:DELay:OFFSet " & Image (Seconds));
   end Set_Delay_Offset;

end Rigol.Timebase;
