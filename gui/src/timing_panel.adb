-- ***************************************************************************
--                   ScopeBridge GUI - Code Timing Panel
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

with Ada.Characters.Handling;  use Ada.Characters.Handling;
with Ada.Strings.Fixed;        use Ada.Strings.Fixed;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;

with GNATCOLL.JSON;            use GNATCOLL.JSON;

with Cairo;                    use Cairo;
with Glib;                     use Glib;
with Gtk.Box;                  use Gtk.Box;
with Gtk.Button;               use Gtk.Button;
with Gtk.Combo_Box;            use Gtk.Combo_Box;
with Gtk.Combo_Box_Text;       use Gtk.Combo_Box_Text;
with Gtk.Drawing_Area;         use Gtk.Drawing_Area;
with Gtk.Grid;                 use Gtk.Grid;
with Gtk.Label;                use Gtk.Label;
with Pango.Font;

with Server.Wire;
with Gui_Client;
with Scope_View;
with Units;                    use Units;
with Widgets;                  use Widgets;

package body Timing_Panel is

   Bins : constant := 40;

   Say_To, Fail_To : Reporter;

   Marker, Polarity, Latency_To, Gap : Gtk_Combo_Box_Text;

   Results   : Gtk_Hbox;
   Table     : Gtk_Label;
   Chart     : Gtk_Drawing_Area;
   Which     : Gtk_Combo_Box_Text;   --  the set the histogram shows

   Shown     : Boolean := False;     --  results are analysed and shown
   Result    : JSON_Value := JSON_Null;

   --  The sets of values Which chooses between, and their names
   Set_Keys  : constant array (0 .. 4) of String (1 .. 7) :=
     ("block  ", "idle   ", "period ", "latency", "burst  ");

   function Key return String is
     (Trim (Set_Keys (Integer'Max (0, Integer (Which.Get_Active))), Ada.Strings.Right));

   --  The chosen set, or JSON_Null if the result has none
   function Chosen return JSON_Value is
     (if Result /= JSON_Null and then Has_Field (Result, Key)
      then Get (Result, Key) else JSON_Null);

   function Num (V : JSON_Value; Name : String) return Float is
     (if Kind (Get (V, Name)) = JSON_Int_Type then Float (Integer'(Get (V, Name)))
      else Float (Get_Long_Float (V, Name)));

   --  "5u" -> 5.0e-6
   function Value_Of (Text : String) return Float is
      T      : constant String := Trim (Text, Ada.Strings.Both);
      Factor : Float := 1.0;
      Last   : Natural := T'Last;
   begin
      if T'Length > 1 then
         case T (T'Last) is
            when 'n' => Factor := 1.0E-9;
            when 'u' => Factor := 1.0E-6;
            when 'm' => Factor := 1.0E-3;
            when others => Last := T'Last + 1;
         end case;
         Last := Last - 1;
      end if;
      declare
         M : constant String := T (T'First .. Last);
      begin
         return Factor * Float'Value
           (if Index (M, ".") = 0 and then Index (To_Lower (M), "e") = 0
            then M & ".0" else M);
      end;
   end Value_Of;

   -- -------------------------------------------------------------------------

   function Pad (S : String; Width : Positive) return String is
     ((if S'Length < Width then (1 .. Width - S'Length => ' ') else "") & S);

   --  One line of the table: count, min, mean, max, standard deviation
   function Row (Name : String; S : JSON_Value; Unit : String) return String is
      Count : constant Integer := Get (S, "count");
      function V (Field : String) return String is
        (Pad (Eng (Num (S, Field), Unit), 10));
   begin
      return Name & (1 .. 15 - Name'Length => ' ') & Pad (Count'Image, 6) &
        (if Count = 0 then ""
         else V ("min") & V ("mean") & V ("max") & V ("std_dev")) & ASCII.LF;
   end Row;

   function Table_Text return String is
      R    : JSON_Value renames Result;
      Text : Unbounded_String := To_Unbounded_String
        ("               count       min      mean       max   std dev" & ASCII.LF);
   begin
      Append (Text, Row ("block", Get (R, "block"), "s"));
      Append (Text, Row ("idle", Get (R, "idle"), "s"));
      Append (Text, Row ("period", Get (R, "period"), "s"));
      if Has_Field (R, "latency") then
         Append (Text, Row ("latency to CH" & Trim (Integer'Image (Get (R, "to")), Ada.Strings.Left),
                            Get (R, "latency"), "s"));
      end if;
      if Has_Field (R, "burst") then
         Append (Text, Row ("burst", Get (R, "burst"), "s"));
         Append (Text, Row ("pulses/burst", Get (R, "burst_pulses"), ""));
      end if;
      if Has_Field (R, "duty") then
         Append (Text, "duty " & Eng (100.0 * Num (R, "duty"), "%") &
                   ", resolution " & Eng (Num (R, "resolution"), "s") &
                   ", over " & Eng (Num (R, "span"), "s"));
      end if;
      return To_String (Text);
   end Table_Text;

   -- -------------------------------------------------------------------------

   procedure Text (Cr : Cairo_Context; X, Y : Gdouble; S : String) is
   begin
      Move_To (Cr, X, Y);
      Show_Text (Cr, S);
   end Text;

   --  The histogram of the chosen set: a bar per bin
   function On_Draw
     (Self : access Gtk_Widget_Record'Class;
      Cr   : Cairo_Context) return Boolean
   is
      W : constant Gdouble := Gdouble (Self.Get_Allocated_Width);
      H : constant Gdouble := Gdouble (Self.Get_Allocated_Height);
      L : constant Gdouble := 8.0;
      T : constant Gdouble := 18.0;
      B : constant Gdouble := H - 20.0;   --  the bars' base line
      S : constant JSON_Value := Chosen;
   begin
      Set_Source_Rgb (Cr, 0.0, 0.0, 0.0);
      Paint (Cr);
      Select_Font_Face (Cr, "Monospace", Cairo_Font_Slant_Normal,
                        Cairo_Font_Weight_Normal);
      Set_Font_Size (Cr, 11.0);
      Set_Source_Rgb (Cr, 0.85, 0.85, 0.85);
      if S = JSON_Null or else Integer'(Get (S, "count")) = 0 then
         Text (Cr, L, H / 2.0, "Nothing to show");
         return True;
      end if;
      declare
         Hist   : constant JSON_Value := Get (S, "histogram");
         Counts : constant JSON_Array := Get (Hist, "counts");
         N      : constant Positive := Length (Counts);
         Most   : Integer := 1;
         Bar    : constant Gdouble := (W - 2.0 * L) / Gdouble (N);
      begin
         for K in 1 .. N loop
            Most := Integer'Max (Most, Get (Get (Counts, K)));
         end loop;
         Text (Cr, L, 12.0, Trim (Most'Image, Ada.Strings.Left) & " most in a bin");
         Text (Cr, L, H - 5.0, Eng (Num (Hist, "from"), "s"));
         declare
            Right : constant String := Eng (Num (Hist, "to"), "s");
         begin
            Text (Cr, W - L - 7.0 * Gdouble (Right'Length), H - 5.0, Right);
         end;
         if Integer'(Get (Result, "ch")) = 2 then
            Set_Source_Rgb (Cr, 0.0, 0.85, 1.0);
         else
            Set_Source_Rgb (Cr, 1.0, 0.9, 0.0);
         end if;
         for K in 1 .. N loop
            declare
               C      : constant Integer := Get (Get (Counts, K));
               --  At least 4 pixels: a single outlier among hundreds is
               --  the bar that matters most, and must not vanish
               Height : constant Gdouble :=
                 Gdouble'Max (4.0, (B - T) * Gdouble (C) / Gdouble (Most));
            begin
               if C > 0 then
                  Rectangle (Cr, L + Bar * Gdouble (K - 1) + 1.0, B - Height,
                             Gdouble'Max (1.0, Bar - 2.0), Height);
               end if;
            end;
         end loop;
         Cairo.Fill (Cr);
         Set_Source_Rgb (Cr, 0.4, 0.4, 0.4);
         Set_Line_Width (Cr, 1.0);
         Move_To (Cr, L, B + 0.5);
         Line_To (Cr, W - L, B + 0.5);
         Stroke (Cr);
      end;
      return True;
   end On_Draw;

   -- -------------------------------------------------------------------------

   procedure On_Analysed (Reply : JSON_Value; Payload : String) is
      pragma Unreferenced (Payload);
   begin
      if not Get (Reply, "ok") then
         Fail_To (Get (Reply, "error"));
         return;
      end if;
      Result := Reply;
      Table.Set_Text (Table_Text);
      Results.Show_All;
      Chart.Queue_Draw;
      Shown := True;
      Say_To ("Timed" & Integer'Image (Get (Get (Reply, "block"), "count")) &
              " blocks on CH" & Trim (Integer'Image (Get (Reply, "ch")), Ada.Strings.Left) &
              ".  Longest and Shortest zoom to them.");
   end On_Analysed;

   procedure Request_Timing is
      M  : constant JSON_Value := Create_Object;
      Ch : constant Integer := (if Marker.Get_Active = 1 then 2 else 1);
   begin
      if Scope_View."/=" (Scope_View.Mode, Scope_View.Capture) then
         Fail_To ("timing works on a capture: press Capture memory first");
         return;
      end if;
      Set_Field (M, "ch", Ch);
      Set_Field (M, "polarity", (if Polarity.Get_Active = 1 then "low" else "high"));
      Set_Field (M, "bins", Integer'(Bins));
      if Latency_To.Get_Active = 1 then
         Set_Field (M, "to", 3 - Ch);
      end if;
      declare
         G : constant String := To_Lower (Trim (Gap.Get_Active_Text, Ada.Strings.Both));
      begin
         if G /= "off" and then G /= "" then
            Set_Field (M, "burst_gap", Server.Wire.To_JSON (Value_Of (G)));
         end if;
      exception
         when Constraint_Error =>
            Fail_To ("the burst gap is not a number: off, or e.g. 50u");
            return;
      end;
      Gui_Client.Request ("timing", M, On_Analysed'Access);
      Say_To ("Timing ...");
   end Request_Timing;

   procedure On_Analyse (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Request_Timing;
   end On_Analyse;

   procedure On_Clear (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Shown := False;
      Result := JSON_Null;
      Results.Hide;
   end On_Clear;

   procedure Zoom (Which_One : String) is
      S : constant JSON_Value := Chosen;
   begin
      if S /= JSON_Null and then Integer'(Get (S, "count")) > 0 then
         declare
            At_It : constant JSON_Value := Get (S, Which_One);
         begin
            Scope_View.Zoom_To (Get (At_It, "first"), Get (At_It, "last"), Times => 2.0);
            Say_To ("The " & Which_One & " " & Key & ": " &
                    Eng (Num (S, (if Which_One = "longest" then "max" else "min")), "s") &
                    " at " & Eng (Num (At_It, "t"), "s"));
         end;
      end if;
   end Zoom;

   procedure On_Longest (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Zoom ("longest");
   end On_Longest;

   procedure On_Shortest (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Zoom ("shortest");
   end On_Shortest;

   procedure On_Which (Self : access Gtk_Combo_Box_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Chart.Queue_Draw;
   end On_Which;

   -- -------------------------------------------------------------------------

   function Create_Controls (Say, Fail : Reporter) return Gtk_Widget is
      G : constant Gtk_Grid := Row_Grid;
   begin
      Say_To  := Say;
      Fail_To := Fail;

      Marker     := New_Combo ("CH1|CH2");
      Polarity   := New_Combo ("high|low");
      Latency_To := New_Combo ("off|the other channel");
      Gtk_New_With_Entry (Gap);
      for T of Units.Float_Array'(0.0, 10.0, 50.0, 100.0, 1000.0) loop
         Gap.Append_Text (if T = 0.0 then "off"
                          else Trim (Integer'Image (Integer (T)), Ada.Strings.Left) & "u");
      end loop;
      Marker.Set_Active (0);
      Polarity.Set_Active (0);
      Latency_To.Set_Active (0);
      Gap.Set_Active (0);
      G.Attach (New_Label ("Marker"), 0, 0);
      G.Attach (Marker, 1, 0);
      G.Attach (New_Label ("Block is"), 0, 1);
      G.Attach (Polarity, 1, 1);
      G.Attach (New_Label ("Latency to"), 0, 2);
      G.Attach (Latency_To, 1, 2);
      G.Attach (New_Label ("Burst gap"), 0, 3);
      G.Attach (Gap, 1, 3);
      G.Attach (New_Button ("Time capture", On_Analyse'Access), 0, 4);
      G.Attach (New_Button ("Clear", On_Clear'Access), 1, 4);
      return Gtk_Widget (Framed ("Timing", G));
   end Create_Controls;

   function Create_Results return Gtk_Widget is
      Side : Gtk_Vbox;
      Keys : Gtk_Hbox;
   begin
      Gtk_New_Hbox (Results, Spacing => 8);
      Table := New_Label ("");
      Table.Set_Valign (Align_Start);
      Table.Set_Margin_Start (8);
      Table.Set_Selectable (True);
      Table.Override_Font (Pango.Font.From_String ("Monospace 9"));
      Results.Pack_Start (Table, Expand => False);

      Gtk_New_Vbox (Side, Spacing => 2);
      Gtk_New (Chart);
      Chart.Set_Size_Request (320, 130);
      Chart.On_Draw (On_Draw'Access);
      Side.Pack_Start (Chart, Expand => True, Fill => True);
      Gtk_New_Hbox (Keys, Spacing => 4);
      Which := New_Combo ("Block|Idle|Period|Latency|Burst");
      Which.Set_Active (0);
      Which.On_Changed (On_Which'Access);
      Keys.Pack_Start (Which, Expand => False);
      Keys.Pack_Start (New_Button ("Longest", On_Longest'Access), Expand => False);
      Keys.Pack_Start (New_Button ("Shortest", On_Shortest'Access), Expand => False);
      Side.Pack_Start (Keys, Expand => False);
      Results.Pack_Start (Side, Expand => True, Fill => True);
      return Gtk_Widget (Results);
   end Create_Results;

   procedure After_Show is
   begin
      if not Shown then
         Results.Hide;
      end if;
   end After_Show;

   procedure Captured is
   begin
      if Shown then
         Request_Timing;
      end if;
   end Captured;

end Timing_Panel;
