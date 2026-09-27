-- ***************************************************************************
--                  ScopeBridge GUI - Widget Helpers Body
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

with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;

with Gtk.Dialog;               use Gtk.Dialog;
with Gtk.File_Chooser;
with Gtk.File_Chooser_Dialog;  use Gtk.File_Chooser_Dialog;
with Gtk.Widget;               use Gtk.Widget;

package body Widgets is

   Parent : Gtk_Window;

   procedure Set_Parent (Window : Gtk_Window) is
   begin
      Parent := Window;
   end Set_Parent;

   function New_Combo (Items : String) return Gtk_Combo_Box_Text is
      --  Items separated by '|'
      Combo : Gtk_Combo_Box_Text;
      First : Positive := Items'First;
   begin
      Gtk_New (Combo);
      for I in Items'Range loop
         if Items (I) = '|' or else I = Items'Last then
            Combo.Append_Text
              (Items (First .. (if Items (I) = '|' then I - 1 else I)));
            First := I + 1;
         end if;
      end loop;
      return Combo;
   end New_Combo;

   function New_Label (Text : String) return Gtk_Label is
      L : Gtk_Label;
   begin
      Gtk_New (L, Text);
      L.Set_Halign (Align_Start);
      return L;
   end New_Label;

   function Ask_File_Name (Title, Suggested : String) return String is
      Dialog : Gtk_File_Chooser_Dialog;
      Dummy  : Gtk_Widget;
      Result : Unbounded_String;
   begin
      Gtk_New (Dialog, Title, Parent, Gtk.File_Chooser.Action_Save);
      Dummy := Dialog.Add_Button ("_Cancel", Gtk_Response_Cancel);
      Dummy := Dialog.Add_Button ("_Save", Gtk_Response_Accept);
      Dialog.Set_Do_Overwrite_Confirmation (True);
      Dialog.Set_Current_Name (Suggested);
      if Dialog.Run = Gtk_Response_Accept then
         Result := To_Unbounded_String (Dialog.Get_Filename);
      end if;
      Dialog.Destroy;
      return To_String (Result);
   end Ask_File_Name;

   function Ask_Open_File (Title : String) return String is
      Dialog : Gtk_File_Chooser_Dialog;
      Dummy  : Gtk_Widget;
      Result : Unbounded_String;
   begin
      Gtk_New (Dialog, Title, Parent, Gtk.File_Chooser.Action_Open);
      Dummy := Dialog.Add_Button ("_Cancel", Gtk_Response_Cancel);
      Dummy := Dialog.Add_Button ("_Open", Gtk_Response_Accept);
      if Dialog.Run = Gtk_Response_Accept then
         Result := To_Unbounded_String (Dialog.Get_Filename);
      end if;
      Dialog.Destroy;
      return To_String (Result);
   end Ask_Open_File;

   procedure Write_File (Name : String; Data : String) is
      use Ada.Streams.Stream_IO;
      F : File_Type;
   begin
      Create (F, Out_File, Name);
      String'Write (Stream (F), Data);
      Close (F);
   end Write_File;

   function New_Button (Label : String; Handler : Cb_Gtk_Button_Void)
                        return Gtk_Button is
      B : Gtk_Button;
   begin
      Gtk_New (B, Label);
      B.On_Clicked (Handler);
      return B;
   end New_Button;

   function New_Spin (Min, Max, Step : Gdouble; Decimals : Guint)
                      return Gtk_Spin_Button is
      S : Gtk_Spin_Button;
   begin
      Gtk_New (S, Min, Max, Step);
      S.Set_Digits (Decimals);
      return S;
   end New_Spin;

   function Framed (Title : String; Content : Gtk_Grid) return Gtk_Frame is
      F : Gtk_Frame;
   begin
      Gtk_New (F, Title);
      Content.Set_Border_Width (6);
      Content.Set_Row_Spacing (4);
      Content.Set_Column_Spacing (8);
      F.Add (Content);
      return F;
   end Framed;

   function Row_Grid return Gtk_Grid is
      G : Gtk_Grid;
   begin
      Gtk_New (G);
      return G;
   end Row_Grid;

end Widgets;
