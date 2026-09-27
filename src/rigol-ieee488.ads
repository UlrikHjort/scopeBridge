-- ***************************************************************************
--                      Rigol - IEEE 488.2 Commands Specification
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

--  IEEE 488.2 common commands (*CLS, *ESE, *ESR?, *IDN?, *OPC, *RST, ...).
--  These are device-independent and defined by the IEEE 488.2 standard.

package Rigol.IEEE488 is

   --  *IDN? - identification string: RIGOL,DS1202Z-E,<serial>,<sw version>
   function Get_IDN (Scope : in out Oscilloscope) return String;

   --  *RST - reset the instrument to factory defaults
   procedure Reset (Scope : in out Oscilloscope);

   --  *CLS - clear status registers (ESR, SBR, output queue)
   procedure Clear_Status (Scope : in out Oscilloscope);

   --  *OPC - set OPC bit in ESR when all pending ops are complete
   procedure Operation_Complete (Scope : in out Oscilloscope);

   --  *OPC? - block until all pending operations complete, returns "1"
   function Query_Operation_Complete
     (Scope : in out Oscilloscope) return Boolean;

   --  *ESR? - read and clear the event status register
   function Get_ESR (Scope : in out Oscilloscope) return Natural;

   --  *STB? - read the status byte register
   function Get_STB (Scope : in out Oscilloscope) return Natural;

   --  *TST? - self-test; returns 0 on pass
   function Self_Test (Scope : in out Oscilloscope) return Natural;

   --  *WAI - wait for all pending commands to finish before proceeding
   procedure Wait (Scope : in out Oscilloscope);

end Rigol.IEEE488;
