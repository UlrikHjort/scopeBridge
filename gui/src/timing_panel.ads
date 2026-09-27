-- ***************************************************************************
--            ScopeBridge GUI - Code Timing Panel Specification
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

--  Code timing in the GUI: a panel to analyse the blocks a program marks
--  on a pin (the marker channel, the other channel for the latency to it,
--  and a gap that splits bursts), and under the display the results: a
--  table of their statistics, a histogram, and buttons that zoom the
--  capture view to the longest or shortest one.

with Gtk.Widget;  use Gtk.Widget;

package Timing_Panel is

   type Reporter is access procedure (Text : String);

   --  The panel for the controls, and the results (hidden until
   --  something is analysed).  Say shows progress, Fail errors.
   function Create_Controls (Say, Fail : Reporter) return Gtk_Widget;
   function Create_Results return Gtk_Widget;

   --  After the window's Show_All: show only what should be
   procedure After_Show;

   --  A new capture is in: analyse it again, if results are shown
   procedure Captured;

end Timing_Panel;
