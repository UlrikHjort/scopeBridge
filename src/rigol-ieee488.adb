-- ***************************************************************************
--                      Rigol - IEEE 488.2 Commands Body
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

package body Rigol.IEEE488 is

   function Get_IDN (Scope : in out Oscilloscope) return String is
   begin
      return Query (Scope, "*IDN?");
   end Get_IDN;

   procedure Reset (Scope : in out Oscilloscope) is
   begin
      Send (Scope, "*RST");
   end Reset;

   procedure Clear_Status (Scope : in out Oscilloscope) is
   begin
      Send (Scope, "*CLS");
   end Clear_Status;

   procedure Operation_Complete (Scope : in out Oscilloscope) is
   begin
      Send (Scope, "*OPC");
   end Operation_Complete;

   function Query_Operation_Complete
     (Scope : in out Oscilloscope) return Boolean
   is
      R : constant String := Query (Scope, "*OPC?");
   begin
      return R = "1";
   end Query_Operation_Complete;

   function Get_ESR (Scope : in out Oscilloscope) return Natural is
   begin
      return Natural'Value (Query (Scope, "*ESR?"));
   end Get_ESR;

   function Get_STB (Scope : in out Oscilloscope) return Natural is
   begin
      return Natural'Value (Query (Scope, "*STB?"));
   end Get_STB;

   function Self_Test (Scope : in out Oscilloscope) return Natural is
   begin
      return Natural'Value (Query (Scope, "*TST?"));
   end Self_Test;

   procedure Wait (Scope : in out Oscilloscope) is
   begin
      Send (Scope, "*WAI");
   end Wait;

end Rigol.IEEE488;
