-- ***************************************************************************
--                      Rigol - Setup Save and Restore Specification
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

--  The scope's setup block, as its Storage > Setups would keep it, for
--  saving on the computer and restoring later.
--
--  On the DS1202Z-E (firmware 00.06.04) the block is not the complete
--  setup: restoring it brings back the timebase but not the channels'
--  scales, and the trigger level is not saved in it at all.
--  rigol_server's setups therefore keep the settings it knows as well,
--  and set them after restoring the block.

package Rigol.Setups is

   --  :SYSTem:SETup? - the setup as the scope sends it: an opaque binary
   --  block of about 2 KB, to be kept as it is
   function Save (Scope : in out Oscilloscope) return String;

   --  :SYSTem:SETup - restore a setup returned by Save.  The scope takes a
   --  moment to apply it, and applies only some of it (see above).
   procedure Restore (Scope : in out Oscilloscope; Setup : String);

end Rigol.Setups;
