-- ***************************************************************************
--                         Rigol - Pass/Fail Test Body
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

package body Rigol.Mask is

   function On_Off (On : Boolean) return String is
     (if On then "ON" else "OFF");

   procedure Set_Enable (Scope : in out Oscilloscope; On : Boolean) is
   begin
      Send (Scope, ":MASK:ENABle " & On_Off (On));
   end Set_Enable;

   function Get_Enable (Scope : in out Oscilloscope) return Boolean is
     (Query (Scope, ":MASK:ENABle?") = "1");

   procedure Set_Source (Scope : in out Oscilloscope;
                         Ch    : Rigol.Channel.Channel_Number) is
   begin
      Send (Scope, ":MASK:SOURce CHANnel" & Image (Integer (Ch)));
   end Set_Source;

   function Get_Source (Scope : in out Oscilloscope)
                        return Rigol.Channel.Channel_Number is
     (if Query (Scope, ":MASK:SOURce?") = "CHAN2" then 2 else 1);

   procedure Set_Running (Scope : in out Oscilloscope; On : Boolean) is
   begin
      Send (Scope, ":MASK:OPERate " & (if On then "RUN" else "STOP"));
   end Set_Running;

   function Get_Running (Scope : in out Oscilloscope) return Boolean is
     (Query (Scope, ":MASK:OPERate?") = "RUN");

   procedure Set_Show_Statistics (Scope : in out Oscilloscope; On : Boolean) is
   begin
      Send (Scope, ":MASK:MDISplay " & On_Off (On));
   end Set_Show_Statistics;

   function Get_Show_Statistics (Scope : in out Oscilloscope) return Boolean is
     (Query (Scope, ":MASK:MDISplay?") = "1");

   procedure Set_Stop_On_Fail (Scope : in out Oscilloscope; On : Boolean) is
   begin
      Send (Scope, ":MASK:SOOutput " & On_Off (On));
   end Set_Stop_On_Fail;

   function Get_Stop_On_Fail (Scope : in out Oscilloscope) return Boolean is
     (Query (Scope, ":MASK:SOOutput?") = "1");

   procedure Set_Beep (Scope : in out Oscilloscope; On : Boolean) is
   begin
      Send (Scope, ":MASK:OUTPut " & On_Off (On));
   end Set_Beep;

   function Get_Beep (Scope : in out Oscilloscope) return Boolean is
     (Query (Scope, ":MASK:OUTPut?") = "1");

   procedure Set_X (Scope : in out Oscilloscope; Divisions : Float) is
   begin
      Send (Scope, ":MASK:X " & Image (Divisions));
   end Set_X;

   function Get_X (Scope : in out Oscilloscope) return Float is
     (Float'Value (Query (Scope, ":MASK:X?")));

   procedure Set_Y (Scope : in out Oscilloscope; Divisions : Float) is
   begin
      Send (Scope, ":MASK:Y " & Image (Divisions));
   end Set_Y;

   function Get_Y (Scope : in out Oscilloscope) return Float is
     (Float'Value (Query (Scope, ":MASK:Y?")));

   procedure Create_Mask (Scope : in out Oscilloscope) is
   begin
      Send (Scope, ":MASK:CREate");
   end Create_Mask;

   function Passed (Scope : in out Oscilloscope) return Long_Long_Integer is
     (Long_Long_Integer'Value (Query (Scope, ":MASK:PASSed?")));

   function Failed (Scope : in out Oscilloscope) return Long_Long_Integer is
     (Long_Long_Integer'Value (Query (Scope, ":MASK:FAILed?")));

   function Total (Scope : in out Oscilloscope) return Long_Long_Integer is
     (Long_Long_Integer'Value (Query (Scope, ":MASK:TOTal?")));

   procedure Reset (Scope : in out Oscilloscope) is
   begin
      Send (Scope, ":MASK:RESet");
   end Reset;

end Rigol.Mask;
