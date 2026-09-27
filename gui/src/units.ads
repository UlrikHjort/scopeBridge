-- ***************************************************************************
--            ScopeBridge GUI - Engineering Units Specification
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

--  Numbers for display: 1.00 ms, 500 mV, 1.50 kHz

package Units is

   --  X with an SI prefix and Unit, to three significant digits
   function Eng (X : Float; Unit : String) return String;

   --  The 1-2-5 sequence of steps between Low and High (inclusive), as
   --  scope knobs step: 1, 2, 5, 10, 20, 50, ...
   type Float_Array is array (Positive range <>) of Float;
   function Steps_125 (Low, High : Float) return Float_Array;

   --  Index of the value in Values closest to X (on a log scale)
   function Nearest (Values : Float_Array; X : Float) return Positive;

end Units;
