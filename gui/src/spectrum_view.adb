-- ***************************************************************************
--                 ScopeBridge GUI - Spectrum Display Body
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

with Ada.Numerics.Long_Elementary_Functions;
use  Ada.Numerics.Long_Elementary_Functions;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with Cairo;                  use Cairo;
with Gdk.Event;              use Gdk.Event;
with Glib;                   use Glib;
with Gtk.Widget;             use Gtk.Widget;

with Units;                  use Units;

package body Spectrum_View is

   Area : Gtk.Drawing_Area.Gtk_Drawing_Area;

   type Float_Access is access Float_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Float_Array, Float_Access);

   Data      : Float_Access;           --  the spectrum, or null
   Data_F0   : Long_Float := 0.0;
   Data_DF   : Long_Float := 1.0;
   Data_RBW  : Long_Float := 1.0;

   --  Below this, the window's main lobe spreads the DC level; the peak
   --  search starts above it
   DC_Limit  : Long_Float := 0.0;

   function DC_Lobe_Bins (Window : String) return Long_Float is
     (if    Window = "rect"     then 1.0
      elsif Window = "blackman" then 3.0
      elsif Window = "flattop"  then 5.0
      else 2.0);   --  hann, hamming, triangle
   Is_dB     : Boolean    := True;
   Header    : Unbounded_String;

   --  Frequencies at the plot's edges
   View_Lo   : Long_Float := 0.0;
   View_Hi   : Long_Float := 1.0;
   Log_Axis  : Boolean    := False;

   --  Top of the level axis, kept steady while levels wobble
   Top       : Float := 20.0;

   Dragging   : Boolean := False;
   Drag_X     : Gdouble := 0.0;
   Drag_Lo    : Long_Float := 0.0;
   Drag_Hi    : Long_Float := 0.0;
   Hovering   : Boolean := False;
   Hover_X    : Gdouble := 0.0;

   Margin_Side : constant Gdouble := 10.0;
   Margin_Top  : constant Gdouble := 22.0;
   Margin_Foot : constant Gdouble := 22.0;

   Divisions_Y : constant := 10;

   procedure Redraw is
   begin
      if Gtk.Drawing_Area."/=" (Area, null) then
         Area.Queue_Draw;
      end if;
   end Redraw;

   procedure Geometry (L, T, W, H : out Gdouble) is
   begin
      L := Margin_Side;
      T := Margin_Top;
      W := Gdouble'Max (1.0, Gdouble (Area.Get_Allocated_Width) - 2.0 * Margin_Side);
      H := Gdouble'Max (1.0, Gdouble (Area.Get_Allocated_Height)
                               - Margin_Top - Margin_Foot);
   end Geometry;

   --  Whole range of the data; on a log axis from the first bin above 0
   procedure Full_Range (Lo, Hi : out Long_Float) is
   begin
      Hi := Data_F0 + Long_Float (Data'Length - 1) * Data_DF;
      Lo := (if Log_Axis then Long_Float'Max (Data_F0, Data_DF) else Data_F0);
      if Hi <= Lo then
         Hi := Lo + Data_DF;
      end if;
   end Full_Range;

   --  Position (0 .. 1 across the plot) of frequency F, and back
   function Frac_Of (F : Long_Float) return Long_Float is
   begin
      if Log_Axis then
         return (Log (Long_Float'Max (F, View_Lo * 1.0E-3)) - Log (View_Lo))
                / (Log (View_Hi) - Log (View_Lo));
      end if;
      return (F - View_Lo) / (View_Hi - View_Lo);
   end Frac_Of;

   function F_Of (Frac : Long_Float) return Long_Float is
   begin
      if Log_Axis then
         return Exp (Log (View_Lo) + Frac * (Log (View_Hi) - Log (View_Lo)));
      end if;
      return View_Lo + Frac * (View_Hi - View_Lo);
   end F_Of;

   --  Show View_Lo .. View_Hi clamped to the data
   procedure Clamp_View is
      Lo, Hi : Long_Float;
      Min_Span : constant Long_Float := 4.0 * Data_DF;
   begin
      Full_Range (Lo, Hi);
      if Log_Axis then
         View_Lo := Long_Float'Max (Lo, View_Lo);
         View_Hi := Long_Float'Min (Hi, View_Hi);
         if View_Hi <= View_Lo * 1.001 then
            View_Hi := Long_Float'Min (Hi, View_Lo * 1.01);
         end if;
      else
         declare
            Span : constant Long_Float :=
              Long_Float'Max (Min_Span, Long_Float'Min (Hi - Lo, View_Hi - View_Lo));
         begin
            View_Lo := Long_Float'Max (Lo, Long_Float'Min (View_Lo, Hi - Span));
            View_Hi := View_Lo + Span;
         end;
      end if;
   end Clamp_View;

   function Level_Text (V : Float) return String is
     (if Is_dB then Eng (V, "") & "dBV" else Eng (V, "V"));

   -- -------------------------------------------------------------------------

   procedure Text (Cr : Cairo_Context; X, Y : Gdouble; S : String;
                   R, G, B : Gdouble := 0.85) is
   begin
      Set_Source_Rgb (Cr, R, G, B);
      Move_To (Cr, X, Y);
      Show_Text (Cr, S);
   end Text;

   function On_Draw
     (Self : access Gtk_Widget_Record'Class;
      Cr   : Cairo_Context) return Boolean
   is
      pragma Unreferenced (Self);
      L, T, W, H : Gdouble;
      Bottom     : Float;
      Peak_I     : Integer := -1;
   begin
      Set_Source_Rgb (Cr, 0.0, 0.0, 0.0);
      Paint (Cr);
      Geometry (L, T, W, H);
      Select_Font_Face (Cr, "Monospace", Cairo_Font_Slant_Normal,
                        Cairo_Font_Weight_Normal);
      Set_Font_Size (Cr, 12.0);

      if Data = null or else Data'Length < 2 then
         Text (Cr, L, T + H / 2.0, "No spectrum yet");
         return True;
      end if;

      Bottom := (if Is_dB then Top - 10.0 * Float (Divisions_Y) else 0.0);

      --  Graticule: 10 x 10 divisions
      Set_Line_Width (Cr, 1.0);
      Set_Source_Rgb (Cr, 0.33, 0.33, 0.33);
      Set_Dash (Cr, (1.0, 4.0), 0.0);
      for I in 1 .. 9 loop
         Move_To (Cr, Gdouble'Floor (L + W * Gdouble (I) / 10.0) + 0.5, T);
         Rel_Line_To (Cr, 0.0, H);
         Move_To (Cr, L, Gdouble'Floor (T + H * Gdouble (I) / 10.0) + 0.5);
         Rel_Line_To (Cr, W, 0.0);
      end loop;
      Stroke (Cr);
      Set_Dash (Cr, No_Dashes, 0.0);
      Rectangle (Cr, L + 0.5, T + 0.5, W - 1.0, H - 1.0);
      Stroke (Cr);

      --  The spectrum: per pixel column, the highest point in it, so no
      --  line is lost when zoomed out
      declare
         function Y (V : Float) return Gdouble is
           (T + H * Gdouble ((Top - V) / (Top - Bottom)));
         First_Point : Boolean := True;
         Peak_V      : Float   := Float'First;
      begin
         Save (Cr);
         Rectangle (Cr, L, T, W, H);
         Clip (Cr);
         Set_Source_Rgb (Cr, 0.95, 0.35, 0.85);
         Set_Line_Width (Cr, 1.2);
         for Px in 0 .. Integer (W) - 1 loop
            declare
               F_A : constant Long_Float := F_Of (Long_Float (Px) / Long_Float (W));
               F_B : constant Long_Float := F_Of (Long_Float (Px + 1) / Long_Float (W));
               I_A : constant Long_Float := (F_A - Data_F0) / Data_DF;
               I_B : constant Long_Float := (F_B - Data_F0) / Data_DF;
               From : constant Integer := Integer (Long_Float'Floor (I_A));
               To   : constant Integer := Integer'Max (From, Integer (Long_Float'Ceiling (I_B)) - 1);
               V    : Float := Float'First;
               Best : Integer := -1;
            begin
               for I in Integer'Max (0, From) .. Integer'Min (Data'Length - 1, To) loop
                  if Data (Data'First + I) > V then
                     V    := Data (Data'First + I);
                     Best := I;
                  end if;
               end loop;
               if Best >= 0 then
                  if First_Point then
                     Move_To (Cr, L + Gdouble (Px), Y (V));
                     First_Point := False;
                  else
                     Line_To (Cr, L + Gdouble (Px), Y (V));
                  end if;
               end if;
            end;
         end loop;
         Stroke (Cr);

         --  Strongest line in view, searched over the bins (a pixel
         --  column may hold DC and the fundamental together); DC skipped
         declare
            I_Lo : constant Integer := Integer'Max
              (0, Integer (Long_Float'Ceiling ((View_Lo - Data_F0) / Data_DF)));
            I_Hi : constant Integer := Integer'Min
              (Data'Length - 1, Integer (Long_Float'Floor ((View_Hi - Data_F0) / Data_DF)));
         begin
            for I in I_Lo .. I_Hi loop
               if Data_F0 + Long_Float (I) * Data_DF > DC_Limit
                 and then Data (Data'First + I) > Peak_V
               then
                  Peak_V := Data (Data'First + I);
                  Peak_I := I;
               end if;
            end loop;
         end;

         if Peak_I >= 0 then
            declare
               F : constant Long_Float := Data_F0 + Long_Float (Peak_I) * Data_DF;
               X : constant Gdouble := L + W * Gdouble (Frac_Of (F));
            begin
               Set_Source_Rgb (Cr, 1.0, 1.0, 1.0);
               Move_To (Cr, X, Y (Peak_V) - 12.0);
               Rel_Line_To (Cr, -5.0, -8.0);
               Rel_Line_To (Cr, 10.0, 0.0);
               Close_Path (Cr);
               Fill (Cr);
            end;
         end if;

         if Hovering then
            Set_Source_Rgb (Cr, 0.85, 0.85, 0.85);
            Set_Dash (Cr, (3.0, 3.0), 0.0);
            Move_To (Cr, Gdouble'Floor (Hover_X) + 0.5, T);
            Rel_Line_To (Cr, 0.0, H);
            Stroke (Cr);
            Set_Dash (Cr, No_Dashes, 0.0);
         end if;
         Restore (Cr);
      end;

      --  Header and footer
      Text (Cr, L, 15.0, To_String (Header) & "   RBW " &
            Eng (Float (Data_RBW), "Hz") &
            (if Is_dB then "   " & Eng (Top, "") & "dBV top, 10 dB/div" else ""),
            0.95, 0.35, 0.85);
      if Peak_I >= 0 then
         declare
            F : constant Long_Float := Data_F0 + Long_Float (Peak_I) * Data_DF;
            S : constant String := "peak " & Eng (Float (F), "Hz") & " " &
                                   Level_Text (Data (Data'First + Peak_I));
         begin
            Text (Cr, L + W - 7.2 * Gdouble (S'Length), 15.0, S);
         end;
      end if;

      if Hovering then
         declare
            F : constant Long_Float := F_Of (Long_Float ((Hover_X - L) / W));
            I : constant Integer := Integer ((F - Data_F0) / Data_DF);
         begin
            Text (Cr, L, T + H + 16.0,
                  "f = " & Eng (Float (F), "Hz") &
                  (if I in 0 .. Data'Length - 1
                   then "   " & Level_Text (Data (Data'First + I)) else ""));
         end;
      else
         Text (Cr, L, T + H + 16.0,
               Eng (Float (View_Lo), "Hz") & " .. " & Eng (Float (View_Hi), "Hz") &
               (if Log_Axis then " (log)" else "") &
               "   wheel zooms, drag pans, right click shows all");
      end if;
      return True;
   end On_Draw;

   -- -------------------------------------------------------------------------

   function On_Scroll
     (Self  : access Gtk_Widget_Record'Class;
      Event : Gdk_Event_Scroll) return Boolean
   is
      pragma Unreferenced (Self);
      L, T, W, H : Gdouble;
      Factor     : Long_Float;
   begin
      if Data = null then
         return False;
      end if;
      case Event.Direction is
         when Scroll_Up   => Factor := 0.8;
         when Scroll_Down => Factor := 1.25;
         when Scroll_Smooth =>
            if Event.Delta_Y < 0.0 then
               Factor := 0.8;
            elsif Event.Delta_Y > 0.0 then
               Factor := 1.25;
            else
               return False;
            end if;
         when others => return False;
      end case;
      Geometry (L, T, W, H);
      declare
         Frac   : constant Long_Float :=
           Long_Float'Max (0.0, Long_Float'Min (1.0, Long_Float ((Event.X - L) / W)));
         Anchor : constant Long_Float := F_Of (Frac);
      begin
         if Log_Axis then
            View_Lo := Exp (Log (Anchor) - (Log (Anchor) - Log (View_Lo)) * Factor);
            View_Hi := Exp (Log (Anchor) + (Log (View_Hi) - Log (Anchor)) * Factor);
         else
            View_Lo := Anchor - (Anchor - View_Lo) * Factor;
            View_Hi := Anchor + (View_Hi - Anchor) * Factor;
         end if;
      end;
      Clamp_View;
      Redraw;
      return True;
   end On_Scroll;

   function On_Press
     (Self  : access Gtk_Widget_Record'Class;
      Event : Gdk_Event_Button) return Boolean
   is
      pragma Unreferenced (Self);
   begin
      if Data = null then
         return False;
      end if;
      if Event.Button = 1 then
         Dragging := True;
         Drag_X   := Event.X;
         Drag_Lo  := View_Lo;
         Drag_Hi  := View_Hi;
      elsif Event.Button = 3 then
         Full_Range (View_Lo, View_Hi);
         Redraw;
      end if;
      return True;
   end On_Press;

   function On_Release
     (Self  : access Gtk_Widget_Record'Class;
      Event : Gdk_Event_Button) return Boolean
   is
      pragma Unreferenced (Self, Event);
   begin
      Dragging := False;
      return False;
   end On_Release;

   function On_Motion
     (Self  : access Gtk_Widget_Record'Class;
      Event : Gdk_Event_Motion) return Boolean
   is
      pragma Unreferenced (Self);
      L, T, W, H : Gdouble;
   begin
      if Data = null then
         return False;
      end if;
      Geometry (L, T, W, H);
      Hovering := Event.X >= L and then Event.X <= L + W;
      Hover_X  := Event.X;
      if Dragging then
         declare
            Shift : constant Long_Float := Long_Float ((Drag_X - Event.X) / W);
         begin
            if Log_Axis then
               declare
                  D : constant Long_Float := Shift * (Log (Drag_Hi) - Log (Drag_Lo));
               begin
                  View_Lo := Exp (Log (Drag_Lo) + D);
                  View_Hi := Exp (Log (Drag_Hi) + D);
               end;
            else
               View_Lo := Drag_Lo + Shift * (Drag_Hi - Drag_Lo);
               View_Hi := Drag_Hi + Shift * (Drag_Hi - Drag_Lo);
            end if;
            Clamp_View;
         end;
      end if;
      Redraw;
      return True;
   end On_Motion;

   -- -------------------------------------------------------------------------

   function Create return Gtk.Drawing_Area.Gtk_Drawing_Area is
   begin
      Gtk.Drawing_Area.Gtk_New (Area);
      Area.Set_Size_Request (640, 240);
      Area.Add_Events (Scroll_Mask or Smooth_Scroll_Mask or Button_Press_Mask
                       or Button_Release_Mask or Pointer_Motion_Mask);
      Area.On_Draw (On_Draw'Access);
      Area.On_Scroll_Event (On_Scroll'Access);
      Area.On_Button_Press_Event (On_Press'Access);
      Area.On_Button_Release_Event (On_Release'Access);
      Area.On_Motion_Notify_Event (On_Motion'Access);
      return Area;
   end Create;

   procedure Show
     (Values    : Float_Array;
      F0, DF    : Long_Float;
      Bin_Width : Long_Float;
      Unit      : String;
      Window    : String;
      Label     : String)
   is
      Old_Lo, Old_Hi, New_Lo, New_Hi : Long_Float := 0.0;
      Had : constant Boolean := Data /= null;
      Peak : Float := Float'First;
   begin
      if Values'Length < 2 or else DF <= 0.0 then
         return;
      end if;
      if Had then
         Full_Range (Old_Lo, Old_Hi);
      end if;
      Free (Data);
      Data     := new Float_Array'(Values);
      Data_F0  := F0;
      Data_DF  := DF;
      Data_RBW := Bin_Width;
      Is_dB    := Unit = "dBV";
      DC_Limit := Long_Float'Max
        (1.5 * DF, (DC_Lobe_Bins (Window) + 0.5) * Bin_Width);
      Header   := To_Unbounded_String (Label);
      Full_Range (New_Lo, New_Hi);

      --  A new frequency range starts at the whole of it; a spectrum over
      --  the same range (the next live update) keeps the zoom
      if not Had or else abs (New_Hi - Old_Hi) > 0.01 * (Old_Hi - Old_Lo)
        or else abs (New_Lo - Old_Lo) > 0.01 * (Old_Hi - Old_Lo)
      then
         View_Lo := New_Lo;
         View_Hi := New_Hi;

         --  A capture spectrum may reach hundreds of MHz while the signal
         --  is at kHz: start at 20 times its strongest line then (a right
         --  click shows everything)
         declare
            Peak_F : Long_Float := 0.0;
            Peak_V : Float := Float'First;
         begin
            for I in Values'Range loop
               declare
                  F : constant Long_Float := F0 + Long_Float (I - Values'First) * DF;
               begin
                  if F > DC_Limit and then Values (I) > Peak_V then
                     Peak_V := Values (I);
                     Peak_F := F;
                  end if;
               end;
            end loop;
            if Peak_F > 0.0 and then New_Hi > 1000.0 * Peak_F then
               View_Hi := Long_Float'Max (20.0 * Peak_F, 100.0 * DF);
            end if;
         end;
      end if;
      Clamp_View;

      --  Level axis: move the top only when the peak leaves the top
      --  division or drops two below it, so it does not jitter
      for V of Values loop
         Peak := Float'Max (Peak, V);
      end loop;
      if Is_dB then
         if Peak > Top or else Peak < Top - 20.0 then
            Top := 10.0 * Float'Ceiling (Peak / 10.0) + 10.0;
         end if;
      else
         if Peak > Top or else Peak < Top / 4.0 then
            Top := Float'Max (1.0E-6, Peak * 1.25);
         end if;
      end if;
      Redraw;
   end Show;

   procedure Clear is
   begin
      Free (Data);
      Redraw;
   end Clear;

   procedure Set_Log_Axis (On : Boolean) is
   begin
      Log_Axis := On;
      if Data /= null then
         Full_Range (View_Lo, View_Hi);
      end if;
      Redraw;
   end Set_Log_Axis;

end Spectrum_View;
