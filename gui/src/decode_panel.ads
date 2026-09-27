-- ***************************************************************************
--            ScopeBridge GUI - Bus Decoding Panel Specification
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

--  Bus decoding in the GUI: a panel for the settings (UART, I2C or SPI),
--  and a list of the decoded items for under the display.  Decoding works
--  on the capture: the items are also drawn along the bottom of the
--  capture view, and choosing one in the list zooms the view to it.  The
--  same settings can set up the scope's own bus decoder, which draws the
--  bus on its screen.

with Gtk.Widget;  use Gtk.Widget;

package Decode_Panel is

   type Reporter is access procedure (Text : String);

   --  The panel for the controls, and the list (hidden until something
   --  is decoded).  Say shows progress, Fail errors.
   function Create_Controls (Say, Fail : Reporter) return Gtk_Widget;
   function Create_Results return Gtk_Widget;

   --  After the window's Show_All: show only what should be
   procedure After_Show;

   --  A new capture is in: decode it again, if items are shown
   procedure Captured;

end Decode_Panel;
