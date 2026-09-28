-- ***************************************************************************
--                       ScopeBridge GUI - About Box
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

with Ada.Calendar;                     use Ada.Calendar;
with Ada.Numerics;
with Ada.Numerics.Elementary_Functions; use Ada.Numerics.Elementary_Functions;

with Cairo;                            use Cairo;
with Glib;                             use Glib;
with Glib.Main;
with Gtk.Box;                          use Gtk.Box;
with Gtk.Dialog;                       use Gtk.Dialog;
with Gtk.Drawing_Area;                 use Gtk.Drawing_Area;
with Gtk.Label;                        use Gtk.Label;
with Gtk.Link_Button;                  use Gtk.Link_Button;
with Gtk.Widget;                       use Gtk.Widget;

with Scopebridge_Version;

package body About_Box is

   Project_Link : constant String := "https://github.com/UlrikHjort/scopeBridge";

   Two_Pi : constant := 2.0 * Ada.Numerics.Pi;

   --  The animation repeats every Cycle seconds: YT for a while, a morph
   --  into XY, the Lissajous figure turning, a morph back
   Cycle : constant := 12.0;

   Screen  : Gtk_Drawing_Area;
   Started : Time;

   --  0.0 .. 1.0, easing in and out
   function Smooth (X : Float) return Float is
     (X * X * (3.0 - 2.0 * X));

   --  How far into XY the screen is, 0.0 (YT) .. 1.0 (XY), at T seconds
   function Morph (T : Float) return Float is
      C : constant Float := T - Cycle * Float'Floor (T / Cycle);
   begin
      if C < 4.0 then
         return 0.0;
      elsif C < 6.0 then
         return Smooth ((C - 4.0) / 2.0);
      elsif C < 10.0 then
         return 1.0;
      else
         return 1.0 - Smooth ((C - 10.0) / 2.0);
      end if;
   end Morph;

   procedure Text (Cr : Cairo_Context; X, Y : Gdouble; S : String) is
   begin
      Move_To (Cr, X, Y);
      Show_Text (Cr, S);
   end Text;

   function On_Draw
     (Self : access Gtk_Widget_Record'Class;
      Cr   : Cairo_Context) return Boolean
   is
      W  : constant Gdouble := Gdouble (Self.Get_Allocated_Width);
      H  : constant Gdouble := Gdouble (Self.Get_Allocated_Height);
      T  : constant Float := Float (Clock - Started);
      M  : constant Float := Morph (T);
      N  : constant := 400;             --  points along the trace

      --  The running sine (YT) and the Lissajous figure (XY, 3:2, its
      --  phase drifting so that it seems to turn)
      Phase : constant Float := Two_Pi * 0.6 * T;
      Drift : constant Float := Two_Pi * 0.08 * T;
      Amp   : constant Float := 0.35 * Float (H);
      R     : constant Float := 0.36 * Float'Min (Float (W), Float (H));

      procedure Trace is
      begin
         for K in 0 .. N loop
            declare
               S  : constant Float := Float (K) / Float (N);
               Yt_X : constant Float := Float (W) * S;
               Yt_Y : constant Float := Float (H) / 2.0 - Amp * Sin (Two_Pi * 2.0 * S + Phase);
               Xy_X : constant Float := Float (W) / 2.0 + R * Sin (Two_Pi * 3.0 * S + Drift);
               Xy_Y : constant Float := Float (H) / 2.0 - R * Sin (Two_Pi * 2.0 * S);
               X    : constant Gdouble := Gdouble ((1.0 - M) * Yt_X + M * Xy_X);
               Y    : constant Gdouble := Gdouble ((1.0 - M) * Yt_Y + M * Xy_Y);
            begin
               if K = 0 then
                  Move_To (Cr, X, Y);
               else
                  Line_To (Cr, X, Y);
               end if;
            end;
         end loop;
      end Trace;
   begin
      Set_Source_Rgb (Cr, 0.0, 0.0, 0.0);
      Paint (Cr);

      --  The graticule: 10 x 8 divisions, dotted, as on the scope view
      Set_Line_Width (Cr, 1.0);
      Set_Source_Rgb (Cr, 0.33, 0.33, 0.33);
      Set_Dash (Cr, (1.0, 3.0), 0.0);
      for I in 1 .. 9 loop
         Move_To (Cr, Gdouble'Floor (W * Gdouble (I) / 10.0) + 0.5, 0.0);
         Rel_Line_To (Cr, 0.0, H);
      end loop;
      for I in 1 .. 7 loop
         Move_To (Cr, 0.0, Gdouble'Floor (H * Gdouble (I) / 8.0) + 0.5);
         Rel_Line_To (Cr, W, 0.0);
      end loop;
      Stroke (Cr);
      Set_Dash (Cr, No_Dashes, 0.0);
      Rectangle (Cr, 0.5, 0.5, W - 1.0, H - 1.0);
      Stroke (Cr);

      --  The trace, in CH1's yellow, with a phosphor glow: wide and faint
      --  under narrow and bright
      Set_Line_Join (Cr, Cairo_Line_Join_Round);
      for Pass in 1 .. 3 loop
         Trace;
         case Pass is
            when 1 =>
               Set_Line_Width (Cr, 7.0);
               Set_Source_Rgba (Cr, 1.0, 0.9, 0.0, 0.12);
            when 2 =>
               Set_Line_Width (Cr, 3.5);
               Set_Source_Rgba (Cr, 1.0, 0.9, 0.0, 0.25);
            when others =>
               Set_Line_Width (Cr, 1.4);
               Set_Source_Rgba (Cr, 1.0, 0.92, 0.3, 1.0);
         end case;
         Stroke (Cr);
      end loop;

      --  The readouts: the channel, and the mode it is in
      Select_Font_Face (Cr, "Monospace", Cairo_Font_Slant_Normal,
                        Cairo_Font_Weight_Normal);
      Set_Font_Size (Cr, 11.0);
      Set_Source_Rgb (Cr, 1.0, 0.9, 0.0);
      Text (Cr, 6.0, 14.0, "CH1");
      Set_Source_Rgb (Cr, 0.85, 0.85, 0.85);
      Text (Cr, W - 24.0, 14.0, (if M < 0.5 then "YT" else "XY"));
      return True;
   end On_Draw;

   function Tick return Boolean is
   begin
      Screen.Queue_Draw;
      return True;
   end Tick;

   procedure Show (Parent : Gtk_Window) is
      Dialog  : Gtk_Dialog;
      Content : Gtk_Box;
      Label   : Gtk_Label;
      Link    : Gtk_Link_Button;
      Timer   : Glib.Main.G_Source_Id;
      Dummy   : Gtk_Widget;
      Result  : Gtk_Response_Type;
      pragma Unreferenced (Dummy, Result);

      procedure Add (Markup : String) is
      begin
         Gtk_New (Label);
         Label.Set_Markup (Markup);
         Content.Pack_Start (Label, Expand => False);
      end Add;
   begin
      Gtk_New (Dialog, "About ScopeBridge", Parent, Modal);
      Content := Dialog.Get_Content_Area;
      Content.Set_Spacing (6);
      Content.Set_Border_Width (12);

      Add ("<span size='xx-large' weight='bold'>ScopeBridge</span>");
      Add ("Version " & Scopebridge_Version.Version);

      Gtk_New (Screen);
      Screen.Set_Size_Request (360, 180);
      Screen.On_Draw (On_Draw'Access);
      Content.Pack_Start (Screen, Expand => True, Fill => True, Padding => 6);

      Add ("Made by Ulrik Hørlyk Hjort");
      Add ("<small>Remote control of oscilloscopes, in Ada.  MIT licence.</small>");
      Gtk_New_With_Label (Link, Project_Link, "github.com/UlrikHjort/scopeBridge");
      Content.Pack_Start (Link, Expand => False);

      Dummy := Dialog.Add_Button ("Close", Gtk_Response_Close);
      Dialog.Show_All;

      Started := Clock;
      Timer := Glib.Main.Timeout_Add (33, Tick'Access);   --  about 30 frames a second
      Result := Dialog.Run;
      Glib.Main.Remove (Timer);
      Dialog.Destroy;
   end Show;

end About_Box;
