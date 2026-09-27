-- ***************************************************************************
--                      Rigol - Setup Save and Restore Body
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

with Ada.Strings.Fixed;

package body Rigol.Setups is

   function Save (Scope : in out Oscilloscope) return String is
     (Query_Block (Scope, ":SYSTem:SETup?"));

   procedure Restore (Scope : in out Oscilloscope; Setup : String) is
      Length : constant String :=
        Ada.Strings.Fixed.Trim (Natural'Image (Setup'Length), Ada.Strings.Left);
   begin
      --  As a definite-length block, #9 and nine length digits
      Send (Scope, ":SYSTem:SETup #9" & (1 .. 9 - Length'Length => '0') &
                   Length & Setup);
   end Restore;

end Rigol.Setups;
