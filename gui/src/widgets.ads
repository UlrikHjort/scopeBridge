-- ***************************************************************************
--              ScopeBridge GUI - Widget Helpers Specification
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

--  Small helpers for building the GUI's panels.

with Glib;               use Glib;
with Gtk.Button;         use Gtk.Button;
with Gtk.Combo_Box_Text; use Gtk.Combo_Box_Text;
with Gtk.Frame;          use Gtk.Frame;
with Gtk.Grid;           use Gtk.Grid;
with Gtk.Label;          use Gtk.Label;
with Gtk.Spin_Button;    use Gtk.Spin_Button;
with Gtk.Window;         use Gtk.Window;

package Widgets is

   --  The window file dialogs belong to
   procedure Set_Parent (Window : Gtk_Window);

   --  A combo box with Items, separated by '|'
   function New_Combo (Items : String) return Gtk_Combo_Box_Text;

   --  A label aligned to the left
   function New_Label (Text : String) return Gtk_Label;

   function New_Button (Label : String; Handler : Cb_Gtk_Button_Void)
                        return Gtk_Button;

   function New_Spin (Min, Max, Step : Gdouble; Decimals : Guint)
                      return Gtk_Spin_Button;

   --  Content in a frame with a title, spaced like the other panels
   function Framed (Title : String; Content : Gtk_Grid) return Gtk_Frame;

   function Row_Grid return Gtk_Grid;

   --  File dialogs: the file chosen, or "" if cancelled
   function Ask_File_Name (Title, Suggested : String) return String;
   function Ask_Open_File (Title : String) return String;

   procedure Write_File (Name : String; Data : String);

end Widgets;
