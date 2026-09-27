-- ***************************************************************************
--              ScopeBridge GUI - Scope Display Specification
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

--  The oscilloscope display: a 12 x 8 division graticule with the traces
--  of both channels, drawn with Cairo.
--
--  Live mode shows the frames the server pushes.  Capture mode shows the
--  server's copy of the acquisition memory: the mouse wheel zooms around
--  the pointer, dragging pans, a right click shows everything again, and
--  hovering reads out time and voltage.  Both modes have time cursors.  The view fetches what it needs
--  with "view" requests, so any memory depth stays fast.

with Gtk.Drawing_Area;
with GNATCOLL.JSON;  use GNATCOLL.JSON;

package Scope_View is

   subtype Channel is Positive range 1 .. 2;

   --  The display widget (one per program)
   function Create return Gtk.Drawing_Area.Gtk_Drawing_Area;

   --  Settings that place the traces, from the server's status
   procedure Set_Channel
     (Ch      : Channel;
      Display : Boolean;
      Scale   : Float;      --  V/div
      Offset  : Float);     --  V
   procedure Set_Timebase (Scale, Offset : Float);
   procedure Set_Trigger (Source : Natural; Level : Float);   --  0 = none
   procedure Set_Trigger_Status (Text : String);

   --  Show or hide the two time cursors, A and B.  Showing places them at
   --  a third and two thirds of the display; drag a cursor line to move
   --  it.  A readout gives both times, their difference and its inverse,
   --  and each channel's voltage at the cursors (exact samples in capture
   --  mode) and their difference.
   procedure Set_Cursors (On : Boolean);

   --  The math trace, drawn in a third colour.  Scope: the scope's math
   --  channel, from live "math" events.  PC: the server's arithmetic
   --  on the two channels, from live "math" events and, for captures of
   --  both channels, "math_view" requests.  Operator is the protocol name
   --  ("add", "sub", "mul", "div"); Scale is units per division and Offset
   --  moves the trace up by Offset / Scale divisions, as for channels.
   type Math_Mode is (Off, Scope, PC);
   procedure Set_Math
     (Mode     : Math_Mode;
      Operator : String;
      Scale    : Float;
      Offset   : Float);

   --  A live "math" event
   procedure Math_Frame (Event : JSON_Value; Payload : String);

   --  A live "frame" event
   procedure Live_Frame (Ch : Channel; Frame : JSON_Value; Payload : String);

   --  XY display, in live mode: CH1 across and CH2 up, each at its own
   --  V/div and position, on a square of 8 x 8 divisions.  Drawn here from
   --  the channels' frames; the scope itself stays in YT mode, since its
   --  waveform reads and measurements do not work in XY.
   procedure Set_XY (On : Boolean);

   --  Reference waveforms: a "ref" reply each, drawn in its own colour
   --  over live and capture views.  A reference is placed at its own
   --  times, and in volts like the channel it came from (CH1 if none), so
   --  it lines up with that channel however its settings change.
   Max_Refs : constant := 4;
   subtype Ref_Slot is Positive range 1 .. Max_Refs;
   procedure Set_Reference (Slot : Ref_Slot; Info : JSON_Value; Payload : String);
   procedure Clear_References;
   procedure Show_References (On : Boolean);

   --  Decoded bus items (the items of a "decode" reply), drawn in capture
   --  mode as a lane per channel along the bottom.  Format is "hex",
   --  "ascii", "dec" or "bin"; Width the bits per data word.
   procedure Set_Decoded (Items : JSON_Array; Format : String; Width : Positive);
   procedure Clear_Decoded;

   --  An item's text as the lanes show it
   function Item_Label (Item : JSON_Value; Format : String; Width : Positive)
                        return String;

   --  Show capture samples First .. Last, centred, with some around them:
   --  the view spans Times their length
   procedure Zoom_To (First, Last : Natural; Times : Long_Float := 12.0);

   type Mode_Type is (Live, Capture);
   procedure Set_Mode (Mode : Mode_Type);
   function Mode return Mode_Type;

   --  A "capture" reply: Ch's memory is now in the server.  Shows the
   --  whole capture of the channels captured since Clear_Captures.
   procedure Clear_Captures;
   procedure Captured (Ch : Channel; Info : JSON_Value);
   function Is_Captured (Ch : Channel) return Boolean;

   --  The capture's sample range in view (0-based, inclusive)
   procedure View_Range (First, Last : out Natural);

   --  Waveform scaling of Ch's capture, as in its "capture" reply
   function Capture_Info (Ch : Channel) return JSON_Value;

   --  The live frame of Ch as (time, volts) pairs, for export; empty if
   --  none
   type Point is record
      Time, Volts : Float;
   end record;
   type Point_Array is array (Positive range <>) of Point;
   function Live_Points (Ch : Channel) return Point_Array;

end Scope_View;
