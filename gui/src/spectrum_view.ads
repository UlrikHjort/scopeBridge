-- ***************************************************************************
--             ScopeBridge GUI - Spectrum Display Specification
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

--  The spectrum display: level against frequency, on a linear or
--  logarithmic frequency axis.  It holds the whole spectrum and zooms
--  locally: the mouse wheel zooms around the pointer, dragging pans, a
--  right click shows everything, and hovering reads out frequency and
--  level.  The strongest line in view is marked.

with Gtk.Drawing_Area;
with Units;

package Spectrum_View is

   function Create return Gtk.Drawing_Area.Gtk_Drawing_Area;

   --  Show Values: point I at F0 + (I - Values'First) * DF Hz.  Unit is
   --  "dBV" (plotted at 10 dB per division) or "Vrms".  Label describes
   --  the source for the header, Bin_Width is the resolution, Window the
   --  protocol's window name.  The zoom is kept while successive spectra
   --  cover the same frequencies.
   procedure Show
     (Values    : Units.Float_Array;
      F0, DF    : Long_Float;
      Bin_Width : Long_Float;
      Unit      : String;
      Window    : String;
      Label     : String);

   procedure Clear;

   procedure Set_Log_Axis (On : Boolean);

end Spectrum_View;
