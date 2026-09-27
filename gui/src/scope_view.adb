-- ***************************************************************************
--                   ScopeBridge GUI - Scope Display Body
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

with Ada.Containers.Vectors;
with Ada.Strings.Fixed;      use Ada.Strings.Fixed;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with Cairo;                  use Cairo;
with Gdk.Event;              use Gdk.Event;
with Glib;                   use Glib;
with Gtk.Widget;             use Gtk.Widget;

with Gui_Client;
with Units;                  use Units;

package body Scope_View is

   Area : Gtk.Drawing_Area.Gtk_Drawing_Area;

   type Chan_State is record
      --  Settings, from status
      Display     : Boolean := False;
      Scale       : Float   := 1.0;
      Offset      : Float   := 0.0;

      --  Live frame
      Has_Frame   : Boolean := False;
      Frame       : Unbounded_String;
      F_Y_Inc     : Float := 1.0;
      F_Y_Origin  : Float := 0.0;
      F_Y_Ref     : Float := 127.0;
      F_X_Inc     : Float := 1.0;
      F_X_Origin  : Float := 0.0;

      --  Capture: scaling, and the vertical settings when it was taken
      Captured    : Boolean := False;
      Info        : JSON_Value := JSON_Null;
      C_Y_Inc     : Float := 1.0;
      C_Y_Origin  : Float := 0.0;
      C_Y_Ref     : Float := 127.0;
      C_Scale     : Float := 1.0;
      C_Offset    : Float := 0.0;

      --  Columns of the last "view" reply: min, max raw per column, over
      --  samples Col_First .. Col_Last
      Columns     : Unbounded_String;
      Col_Count   : Natural := 0;
      Col_First   : Natural := 0;
      Col_Last    : Natural := 0;
      Req_First   : Natural := 0;
      Req_Last    : Natural := 0;
      Pending     : Boolean := False;   --  a view request is out
      Dirty       : Boolean := False;   --  the view moved meanwhile
   end record;

   Chans : array (Channel) of Chan_State;

   --  Points across the scope's screen.  At slow timebases the scope sends
   --  the screen while its sweep fills it, from the left: fewer points,
   --  which are placed where they are on the scope, not stretched.
   Screen_Points : constant := 1200;

   type Float_Access is access Float_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Float_Array, Float_Access);

   --  The math trace
   M_Mode      : Math_Mode := Off;
   M_Op        : Unbounded_String := To_Unbounded_String ("add");
   M_Scale     : Float := 1.0;
   M_Offset    : Float := 0.0;
   M_Frame     : Float_Access;           --  live values
   M_Cols      : Float_Access;           --  capture: min, max per column
   M_Col_First : Natural := 0;
   M_Col_Last  : Natural := 0;
   M_Req_First : Natural := 0;
   M_Req_Last  : Natural := 0;
   M_Pending   : Boolean := False;
   M_Dirty     : Boolean := False;

   Math_Colour_R : constant := 0.95;
   Math_Colour_G : constant := 0.35;
   Math_Colour_B : constant := 0.85;

   function Op_Symbol return String is
     (if M_Op = "sub" then "A-B" elsif M_Op = "mul" then "AxB"
      elsif M_Op = "div" then "A/B" else "A+B");

   TB_Scale     : Float := 1.0E-3;
   TB_Offset    : Float := 0.0;
   Trig_Source  : Natural := 0;
   Trig_Level   : Float := 0.0;
   Trig_Status  : Unbounded_String;
   Current_Mode : Mode_Type := Live;

   --  Capture view: the whole capture has Cap_Total samples, of which
   --  V_First .. V_Last are shown
   Cap_Total    : Natural := 0;
   Cap_X_Inc    : Float := 1.0;
   Cap_X_Origin : Float := 0.0;
   V_First      : Natural := 0;
   V_Last       : Natural := 0;

   Dragging     : Boolean := False;
   Drag_X       : Gdouble := 0.0;
   Drag_First   : Natural := 0;
   Hovering     : Boolean := False;
   Hover_X      : Gdouble := 0.0;

   --  Plot area inside the widget
   Margin_Side  : constant Gdouble := 10.0;
   Margin_Top   : constant Gdouble := 26.0;
   Margin_Foot  : constant Gdouble := 26.0;

   type Colour is record
      R, G, B : Gdouble;
   end record;

   Trace_Colour : constant array (Channel) of Colour :=
     ((1.0, 0.9, 0.0), (0.0, 0.85, 1.0));
   Grid_Colour  : constant Colour := (0.33, 0.33, 0.33);
   Text_Colour  : constant Colour := (0.85, 0.85, 0.85);


   -- -------------------------------------------------------------------------
   --  XY, references and decoded items
   -- -------------------------------------------------------------------------

   XY_On : Boolean := False;

   type Reference is record
      Used   : Boolean := False;
      Ch     : Channel := 1;
      Label  : Unbounded_String;
      Data   : Unbounded_String;
      X_Inc, X_Origin, Y_Inc, Y_Origin, Y_Ref : Float := 0.0;
   end record;

   Refs      : array (Ref_Slot) of Reference;
   Refs_On   : Boolean := True;

   Ref_Colour : constant array (Ref_Slot) of Colour :=
     ((0.92, 0.92, 0.92), (1.0, 0.6, 0.2), (0.5, 1.0, 0.5), (1.0, 0.55, 0.75));

   type Decoded is record
      First, Last : Natural := 0;
      Ch          : Channel := 1;
      Kind        : Character := 'D';   --  D data, A address, S start, P stop
      Bad         : Boolean := False;   --  an error, or not acknowledged
      Label       : Unbounded_String;
   end record;

   package Decoded_Vectors is new Ada.Containers.Vectors (Positive, Decoded);
   Items_Shown : Decoded_Vectors.Vector;
   Lane_Of     : array (Channel) of Natural := (others => 0);   --  0 = none

   procedure Set_Colour (Cr : Cairo_Context; C : Colour) is
   begin
      Set_Source_Rgb (Cr, C.R, C.G, C.B);
   end Set_Colour;

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

   function Get_Float (V : JSON_Value; Name : String) return Float is
     (if Kind (Get (V, Name)) = JSON_Int_Type
      then Float (Integer'(Get (V, Name)))
      else Float (Long_Float'(Get_Long_Float (V, Name))));

   -- -------------------------------------------------------------------------
   --  Capture views
   -- -------------------------------------------------------------------------

   procedure Request_View (Ch : Channel);

   procedure On_View (Ch : Channel; Reply : JSON_Value; Payload : String) is
      C : Chan_State renames Chans (Ch);
   begin
      C.Pending := False;
      if Get (Reply, "ok") then
         C.Columns   := To_Unbounded_String (Payload);
         C.Col_Count := Get (Reply, "columns");
         C.Col_First := C.Req_First;
         C.Col_Last  := C.Req_Last;
      end if;
      if C.Dirty then
         C.Dirty := False;
         Request_View (Ch);
      end if;
      Redraw;
   end On_View;

   procedure On_View_1 (Reply : JSON_Value; Payload : String) is
   begin
      On_View (1, Reply, Payload);
   end On_View_1;

   procedure On_View_2 (Reply : JSON_Value; Payload : String) is
   begin
      On_View (2, Reply, Payload);
   end On_View_2;

   --  Ask for the columns of the current view; at most one request per
   --  channel is out at a time, so dragging never floods the server
   procedure Request_View (Ch : Channel) is
      C       : Chan_State renames Chans (Ch);
      L, T, W, H : Gdouble;
      Members : constant JSON_Value := Create_Object;
   begin
      if not C.Captured or else Cap_Total = 0 then
         return;
      end if;
      if C.Pending then
         C.Dirty := True;
         return;
      end if;
      Geometry (L, T, W, H);
      C.Req_First := V_First;
      C.Req_Last  := V_Last;
      C.Pending   := True;
      Set_Field (Members, "ch", Integer (Ch));
      Set_Field (Members, "first", V_First);
      Set_Field (Members, "last", V_Last);
      Set_Field (Members, "columns", Integer'Max (1, Integer'Min (10_000, Integer (W))));
      Gui_Client.Request
        ("view", Members,
         (if Ch = 1 then On_View_1'Access else On_View_2'Access));
   end Request_View;

   procedure Request_Math_View;

   procedure On_Math_View (Reply : JSON_Value; Payload : String) is
   begin
      M_Pending := False;
      if Get (Reply, "ok") then
         Free (M_Cols);
         M_Cols      := new Float_Array'(Gui_Client.Floats (Payload));
         M_Col_First := M_Req_First;
         M_Col_Last  := M_Req_Last;
      end if;
      if M_Dirty then
         M_Dirty := False;
         Request_Math_View;
      end if;
      Redraw;
   end On_Math_View;

   --  Server math of the two captures, for the current view
   procedure Request_Math_View is
      L, T, W, H : Gdouble;
      Members    : JSON_Value;
   begin
      if M_Mode /= PC or else M_Op = "div" or else Cap_Total = 0
        or else not (Chans (1).Captured and then Chans (2).Captured)
      then
         return;
      end if;
      if M_Pending then
         M_Dirty := True;
         return;
      end if;
      Geometry (L, T, W, H);
      Members := Create_Object;
      Set_Field (Members, "operator", To_String (M_Op));
      Set_Field (Members, "first", V_First);
      Set_Field (Members, "last", V_Last);
      Set_Field (Members, "columns", Integer'Max (1, Integer'Min (10_000, Integer (W))));
      M_Req_First := V_First;
      M_Req_Last  := V_Last;
      M_Pending   := True;
      Gui_Client.Request ("math_view", Members, On_Math_View'Access);
   end Request_Math_View;

   procedure Request_Views is
   begin
      for Ch in Channel loop
         Request_View (Ch);
      end loop;
      Request_Math_View;
   end Request_Views;

   --  Show samples First .. First + Span - 1, clamped to the capture
   procedure Show_Samples (First, Span : Long_Float) is
      S : constant Long_Float :=
        Long_Float'Max (10.0, Long_Float'Min (Span, Long_Float (Cap_Total)));
      F : constant Long_Float :=
        Long_Float'Max (0.0, Long_Float'Min (First, Long_Float (Cap_Total) - S));
   begin
      V_First := Natural (Long_Float'Floor (F));
      V_Last  := Natural'Min (Cap_Total - 1,
                              V_First + Natural (Long_Float'Floor (S)) - 1);
      Request_Views;
      Redraw;
   end Show_Samples;

   -- -------------------------------------------------------------------------
   --  Cursors
   -- -------------------------------------------------------------------------

   type Cursor is (A, B);

   Cursors_On  : Boolean := False;
   Cur_Time    : array (Cursor) of Long_Float := (others => 0.0);   --  s
   Cursor_Drag : Boolean := False;
   Dragged     : Cursor  := A;

   --  In capture mode, the exact sample under each cursor, fetched with a
   --  "samples" request per cursor and channel.  Cur_Raw is valid when
   --  Cur_Index is the sample the cursor is on.
   Cur_Raw     : array (Cursor, Channel) of Natural := (others => (others => 0));
   Cur_Index   : array (Cursor, Channel) of Integer := (others => (others => -1));
   Cur_Req     : array (Cursor, Channel) of Integer := (others => (others => -1));
   Cur_Pending : array (Cursor, Channel) of Boolean := (others => (others => False));
   Cur_Dirty   : array (Cursor, Channel) of Boolean := (others => (others => False));

   --  Times at the left and right edge of the plot
   procedure Window (T0, T1 : out Long_Float) is
   begin
      if Current_Mode = Capture and then Cap_Total > 0 then
         T0 := Long_Float (Cap_X_Origin) + Long_Float (V_First) * Long_Float (Cap_X_Inc);
         T1 := Long_Float (Cap_X_Origin) + Long_Float (V_Last + 1) * Long_Float (Cap_X_Inc);
         return;
      end if;
      for C of Chans loop
         if C.Display and then C.Has_Frame and then Length (C.Frame) > 1 then
            T0 := Long_Float (C.F_X_Origin);
            T1 := T0 + Long_Float (Screen_Points - 1) * Long_Float (C.F_X_Inc);
            return;
         end if;
      end loop;
      T0 := Long_Float (TB_Offset - 6.0 * TB_Scale);
      T1 := Long_Float (TB_Offset + 6.0 * TB_Scale);
   end Window;

   --  The capture sample at time T
   function Sample_At (T : Long_Float) return Natural is
     (Natural (Long_Float'Max (0.0, Long_Float'Min
        (Long_Float (Cap_Total - 1),
         Long_Float'Rounding ((T - Long_Float (Cap_X_Origin)) / Long_Float (Cap_X_Inc))))));

   procedure Request_Cursor_Sample (C : Cursor; Ch : Channel);

   procedure On_Cursor_Sample
     (C : Cursor; Ch : Channel; Reply : JSON_Value; Payload : String) is
   begin
      Cur_Pending (C, Ch) := False;
      if Get (Reply, "ok") and then Payload'Length = 1 then
         Cur_Raw (C, Ch)   := Character'Pos (Payload (Payload'First));
         Cur_Index (C, Ch) := Cur_Req (C, Ch);
      end if;
      if Cur_Dirty (C, Ch) then
         Cur_Dirty (C, Ch) := False;
         Request_Cursor_Sample (C, Ch);
      end if;
      Redraw;
   end On_Cursor_Sample;

   procedure On_A1 (Reply : JSON_Value; Payload : String) is
   begin
      On_Cursor_Sample (A, 1, Reply, Payload);
   end On_A1;
   procedure On_A2 (Reply : JSON_Value; Payload : String) is
   begin
      On_Cursor_Sample (A, 2, Reply, Payload);
   end On_A2;
   procedure On_B1 (Reply : JSON_Value; Payload : String) is
   begin
      On_Cursor_Sample (B, 1, Reply, Payload);
   end On_B1;
   procedure On_B2 (Reply : JSON_Value; Payload : String) is
   begin
      On_Cursor_Sample (B, 2, Reply, Payload);
   end On_B2;

   --  Fetch the sample under cursor C of channel Ch, unless known; one
   --  request per cursor and channel at a time, as for views
   procedure Request_Cursor_Sample (C : Cursor; Ch : Channel) is
      Index   : Natural;
      Members : JSON_Value;
   begin
      if not (Cursors_On and then Current_Mode = Capture
              and then Chans (Ch).Captured and then Cap_Total > 0)
      then
         return;
      end if;
      Index := Sample_At (Cur_Time (C));
      if Cur_Index (C, Ch) = Index then
         return;
      elsif Cur_Pending (C, Ch) then
         Cur_Dirty (C, Ch) := True;
         return;
      end if;
      Members := Create_Object;
      Set_Field (Members, "ch", Integer (Ch));
      Set_Field (Members, "first", Index);
      Set_Field (Members, "last", Index);
      Cur_Req (C, Ch)     := Index;
      Cur_Pending (C, Ch) := True;
      Gui_Client.Request
        ("samples", Members,
         (case C is
             when A => (if Ch = 1 then On_A1'Access else On_A2'Access),
             when B => (if Ch = 1 then On_B1'Access else On_B2'Access)));
   end Request_Cursor_Sample;

   procedure Request_Cursor_Samples is
   begin
      for C in Cursor loop
         for Ch in Channel loop
            Request_Cursor_Sample (C, Ch);
         end loop;
      end loop;
   end Request_Cursor_Samples;

   --  Ch's voltage at cursor C; Known is False if there is none (yet)
   procedure Cursor_Volts
     (C : Cursor; Ch : Channel; Volts : out Float; Known : out Boolean)
   is
      Ch_State : Chan_State renames Chans (Ch);
   begin
      Volts := 0.0;
      Known := False;
      if Current_Mode = Capture then
         if Ch_State.Captured and then Cur_Index (C, Ch) = Sample_At (Cur_Time (C))
         then
            Volts := (Float (Cur_Raw (C, Ch)) - Ch_State.C_Y_Ref
                      - Ch_State.C_Y_Origin) * Ch_State.C_Y_Inc;
            Known := True;
         end if;
      elsif Ch_State.Display and then Ch_State.Has_Frame then
         declare
            N : constant Natural := Length (Ch_State.Frame);
            I : constant Long_Float := Long_Float'Rounding
              ((Cur_Time (C) - Long_Float (Ch_State.F_X_Origin))
               / Long_Float (Ch_State.F_X_Inc));
         begin
            if I >= 0.0 and then I <= Long_Float (N - 1) then
               Volts := (Float (Character'Pos (Element (Ch_State.Frame, Natural (I) + 1)))
                         - Ch_State.F_Y_Ref - Ch_State.F_Y_Origin) * Ch_State.F_Y_Inc;
               Known := True;
            end if;
         end;
      end if;
   end Cursor_Volts;

   -- -------------------------------------------------------------------------
   --  Drawing
   -- -------------------------------------------------------------------------

   procedure Text (Cr : Cairo_Context; X, Y : Gdouble; S : String; C : Colour)
   is
   begin
      Set_Colour (Cr, C);
      Move_To (Cr, X, Y);
      Show_Text (Cr, S);
   end Text;

   --  Width of S in the display font (monospace)
   function Text_Width (S : String) return Gdouble is
     (7.2 * Gdouble (S'Length));

   procedure Draw_Graticule (Cr : Cairo_Context; L, T, W, H : Gdouble) is
   begin
      Set_Line_Width (Cr, 1.0);
      Set_Colour (Cr, Grid_Colour);
      Set_Dash (Cr, (1.0, 4.0), 0.0);
      for I in 1 .. 11 loop
         Move_To (Cr, Gdouble'Floor (L + W * Gdouble (I) / 12.0) + 0.5, T);
         Rel_Line_To (Cr, 0.0, H);
      end loop;
      for J in 1 .. 7 loop
         Move_To (Cr, L, Gdouble'Floor (T + H * Gdouble (J) / 8.0) + 0.5);
         Rel_Line_To (Cr, W, 0.0);
      end loop;
      Stroke (Cr);
      Set_Dash (Cr, No_Dashes, 0.0);
      Rectangle (Cr, L + 0.5, T + 0.5, W - 1.0, H - 1.0);
      Stroke (Cr);
   end Draw_Graticule;

   --  Y of Volts on a channel shown at Scale V/div, Offset V
   function Y_Of (Volts, Scale, Offset : Float; T, H : Gdouble) return Gdouble
   is
     (T + H / 2.0 - Gdouble ((Volts + Offset) / Scale) * H / 8.0);

   procedure Draw_Live (Cr : Cairo_Context; L, T, W, H : Gdouble) is
   begin
      for Ch in Channel loop
         declare
            C : Chan_State renames Chans (Ch);
            N : constant Natural := Length (C.Frame);
         begin
            if C.Display and then C.Has_Frame and then N > 1 then
               Set_Colour (Cr, Trace_Colour (Ch));
               Set_Line_Width (Cr, 1.5);
               for I in 1 .. N loop
                  declare
                     Raw : constant Float :=
                       Float (Character'Pos (Element (C.Frame, I)));
                     X   : constant Gdouble :=
                       L + W * Gdouble (I - 1) / Gdouble (Screen_Points - 1);
                     Y   : constant Gdouble :=
                       Y_Of ((Raw - C.F_Y_Ref - C.F_Y_Origin) * C.F_Y_Inc,
                             C.Scale, C.Offset, T, H);
                  begin
                     if I = 1 then
                        Move_To (Cr, X, Y);
                     else
                        Line_To (Cr, X, Y);
                     end if;
                  end;
               end loop;
               Stroke (Cr);
            end if;
         end;
      end loop;

      --  Trigger level: a short line at the right edge
      if Trig_Source in Channel and then Chans (Trig_Source).Display then
         declare
            C : Chan_State renames Chans (Trig_Source);
            Y : constant Gdouble := Y_Of (Trig_Level, C.Scale, C.Offset, T, H);
         begin
            Set_Colour (Cr, Trace_Colour (Trig_Source));
            Set_Line_Width (Cr, 2.0);
            Move_To (Cr, L + W - 14.0, Y);
            Line_To (Cr, L + W, Y);
            Stroke (Cr);
         end;
      end if;
   end Draw_Live;

   procedure Draw_Capture (Cr : Cairo_Context; L, T, W, H : Gdouble) is
      Span : constant Long_Float := Long_Float (V_Last - V_First + 1);

      function X_Of (Sample : Long_Float) return Gdouble is
        (L + W * Gdouble ((Sample - Long_Float (V_First)) / Span));
   begin
      for Ch in Channel loop
         declare
            C    : Chan_State renames Chans (Ch);
            N    : constant Long_Float := Long_Float (C.Col_Last - C.Col_First + 1);
            Cols : constant Natural := C.Col_Count;

            function Volts (Raw : Character) return Float is
              ((Float (Character'Pos (Raw)) - C.C_Y_Ref - C.C_Y_Origin) * C.C_Y_Inc);

            function Y (Raw : Character) return Gdouble is
              (Y_Of (Volts (Raw), C.C_Scale, C.C_Offset, T, H));
         begin
            if C.Captured and then Cols > 0 then
               Set_Colour (Cr, Trace_Colour (Ch));
               if Long_Float (Cols) < Long_Float (W) / 3.0 then
                  --  Few samples: join them, and mark each
                  Set_Line_Width (Cr, 1.5);
                  for K in 0 .. Cols - 1 loop
                     declare
                        X : constant Gdouble := X_Of
                          (Long_Float (C.Col_First) + Long_Float (K) * N / Long_Float (Cols));
                        Yk : constant Gdouble := Y (Element (C.Columns, 2 * K + 1));
                     begin
                        if K = 0 then
                           Move_To (Cr, X, Yk);
                        else
                           Line_To (Cr, X, Yk);
                        end if;
                     end;
                  end loop;
                  Stroke (Cr);
                  if Long_Float (Cols) < Long_Float (W) / 8.0 then
                     for K in 0 .. Cols - 1 loop
                        Rectangle
                          (Cr,
                           X_Of (Long_Float (C.Col_First) +
                                   Long_Float (K) * N / Long_Float (Cols)) - 2.0,
                           Y (Element (C.Columns, 2 * K + 1)) - 2.0, 4.0, 4.0);
                     end loop;
                     Fill (Cr);
                  end if;
               else
                  --  One vertical stroke per column, from its lowest to its
                  --  highest sample, so a short glitch still shows
                  Set_Line_Width (Cr, 1.0);
                  for K in 0 .. Cols - 1 loop
                     declare
                        X0 : constant Gdouble := X_Of
                          (Long_Float (C.Col_First) + Long_Float (K) * N / Long_Float (Cols));
                        Lo : constant Gdouble := Y (Element (C.Columns, 2 * K + 1));
                        Hi : constant Gdouble := Y (Element (C.Columns, 2 * K + 2));
                     begin
                        Move_To (Cr, Gdouble'Floor (X0) + 0.5, Lo + 0.5);
                        Line_To (Cr, Gdouble'Floor (X0) + 0.5, Hi - 0.5);
                     end;
                  end loop;
                  Stroke (Cr);
               end if;
            end if;
         end;
      end loop;
   end Draw_Capture;

   --  "t = 1.23 ms   CH1 0.00 .. 3.04 V" for the pointer position
   function Hover_Text (L, W : Gdouble) return String is
      Frac   : constant Long_Float :=
        Long_Float'Max (0.0, Long_Float'Min (1.0, Long_Float ((Hover_X - L) / W)));
      Sample : constant Long_Float :=
        Long_Float (V_First) + Frac * Long_Float (V_Last - V_First + 1);
      Result : Unbounded_String := To_Unbounded_String
        ("t = " & Eng (Cap_X_Origin + Float (Sample) * Cap_X_Inc, "s"));
   begin
      for Ch in Channel loop
         declare
            C : Chan_State renames Chans (Ch);
         begin
            if C.Captured and then C.Col_Count > 0 then
               declare
                  N : constant Long_Float := Long_Float (C.Col_Last - C.Col_First + 1);
                  K : constant Integer := Integer (Long_Float'Floor
                    ((Sample - Long_Float (C.Col_First)) * Long_Float (C.Col_Count) / N));
               begin
                  if K in 0 .. C.Col_Count - 1 then
                     declare
                        Lo : constant Float := (Float (Character'Pos (Element (C.Columns, 2 * K + 1)))
                                                - C.C_Y_Ref - C.C_Y_Origin) * C.C_Y_Inc;
                        Hi : constant Float := (Float (Character'Pos (Element (C.Columns, 2 * K + 2)))
                                                - C.C_Y_Ref - C.C_Y_Origin) * C.C_Y_Inc;
                     begin
                        Append (Result, "   CH" & Character'Val (48 + Ch) & " " &
                                  (if Hi - Lo < C.C_Y_Inc * 0.5 then Eng (Lo, "V")
                                   else Eng (Lo, "V") & " .. " & Eng (Hi, "V")));
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
      return To_String (Result);
   end Hover_Text;

   procedure Draw_Math (Cr : Cairo_Context; L, T, W, H : Gdouble) is
      function Y (V : Float) return Gdouble is
        (Y_Of (V, M_Scale, M_Offset, T, H));
   begin
      if M_Mode = Off then
         return;
      end if;
      Set_Source_Rgb (Cr, Math_Colour_R, Math_Colour_G, Math_Colour_B);
      if Current_Mode = Live then
         if M_Frame /= null and then M_Frame'Length > 1 then
            Set_Line_Width (Cr, 1.5);
            for I in M_Frame'Range loop
               declare
                  X : constant Gdouble :=
                    L + W * Gdouble (I - M_Frame'First) / Gdouble (Screen_Points - 1);
               begin
                  if I = M_Frame'First then
                     Move_To (Cr, X, Y (M_Frame (I)));
                  else
                     Line_To (Cr, X, Y (M_Frame (I)));
                  end if;
               end;
            end loop;
            Stroke (Cr);
         end if;
      elsif M_Cols /= null and then M_Cols'Length >= 2 then
         declare
            Cols : constant Natural := M_Cols'Length / 2;
            N    : constant Long_Float := Long_Float (M_Col_Last - M_Col_First + 1);
            Span : constant Long_Float := Long_Float (V_Last - V_First + 1);
         begin
            Set_Line_Width (Cr, 1.0);
            for K in 0 .. Cols - 1 loop
               declare
                  Sample : constant Long_Float :=
                    Long_Float (M_Col_First) + Long_Float (K) * N / Long_Float (Cols);
                  X  : constant Gdouble :=
                    Gdouble'Floor (L + W * Gdouble ((Sample - Long_Float (V_First)) / Span)) + 0.5;
                  Lo : constant Float := M_Cols (M_Cols'First + 2 * K);
                  Hi : constant Float := M_Cols (M_Cols'First + 2 * K + 1);
               begin
                  if Cols < Natural (W) / 3 then
                     if K = 0 then
                        Move_To (Cr, X, Y (Lo));
                     else
                        Line_To (Cr, X, Y (Lo));
                     end if;
                  else
                     Move_To (Cr, X, Y (Lo) + 0.5);
                     Line_To (Cr, X, Y (Hi) - 0.5);
                  end if;
               end;
            end loop;
            Stroke (Cr);
         end;
      end if;
   end Draw_Math;


   --  XY: CH1 across, CH2 up, on a centred square of 8 x 8 divisions
   procedure Draw_XY (Cr : Cairo_Context; L, T, W, H : Gdouble) is
      Side : constant Gdouble := Gdouble'Min (W, H);
      X0   : constant Gdouble := L + (W - Side) / 2.0;
      Y0   : constant Gdouble := T + (H - Side) / 2.0;
      A    : Chan_State renames Chans (1);
      B    : Chan_State renames Chans (2);
      N    : constant Natural :=
        Natural'Min (Length (A.Frame), Length (B.Frame));

      function Volts (C : Chan_State; I : Positive) return Float is
        ((Float (Character'Pos (Element (C.Frame, I))) - C.F_Y_Ref - C.F_Y_Origin)
         * C.F_Y_Inc);
   begin
      Set_Line_Width (Cr, 1.0);
      Set_Colour (Cr, Grid_Colour);
      Set_Dash (Cr, (1.0, 4.0), 0.0);
      for I in 1 .. 7 loop
         Move_To (Cr, Gdouble'Floor (X0 + Side * Gdouble (I) / 8.0) + 0.5, Y0);
         Rel_Line_To (Cr, 0.0, Side);
         Move_To (Cr, X0, Gdouble'Floor (Y0 + Side * Gdouble (I) / 8.0) + 0.5);
         Rel_Line_To (Cr, Side, 0.0);
      end loop;
      Stroke (Cr);
      Set_Dash (Cr, No_Dashes, 0.0);
      Rectangle (Cr, X0 + 0.5, Y0 + 0.5, Side - 1.0, Side - 1.0);
      Stroke (Cr);

      if not (A.Has_Frame and then B.Has_Frame) or else N < 2 then
         Text (Cr, X0 + 12.0, Y0 + 24.0, "XY needs both channels on", Text_Colour);
         return;
      end if;
      Set_Source_Rgb (Cr, 0.4, 1.0, 0.4);
      for I in 1 .. N loop
         Rectangle
           (Cr,
            X0 + Side / 2.0 + Gdouble ((Volts (A, I) + A.Offset) / A.Scale) * Side / 8.0 - 1.0,
            Y0 + Side / 2.0 - Gdouble ((Volts (B, I) + B.Offset) / B.Scale) * Side / 8.0 - 1.0,
            2.0, 2.0);
      end loop;
      Fill (Cr);
   end Draw_XY;

   procedure Draw_References (Cr : Cairo_Context; L, T, W, H : Gdouble) is
      T0, T1 : Long_Float;
   begin
      if not Refs_On then
         return;
      end if;
      Window (T0, T1);
      for Slot in Ref_Slot loop
         declare
            R : Reference renames Refs (Slot);
            C : Chan_State renames Chans (R.Ch);
            N : constant Natural := Length (R.Data);
            --  Placed like its channel as that is shown now
            Scale  : constant Float :=
              (if Current_Mode = Capture and then C.Captured then C.C_Scale else C.Scale);
            Offset : constant Float :=
              (if Current_Mode = Capture and then C.Captured then C.C_Offset else C.Offset);
            Step   : constant Positive := Positive'Max (1, N / Natural (2.0 * W + 1.0));
            I      : Positive := 1;
            First  : Boolean := True;
         begin
            if R.Used and then N > 1 and then T1 > T0 then
               Set_Source_Rgba (Cr, Ref_Colour (Slot).R, Ref_Colour (Slot).G,
                                Ref_Colour (Slot).B, 0.8);
               Set_Line_Width (Cr, 1.2);
               while I <= N loop
                  declare
                     Time : constant Long_Float :=
                       Long_Float (R.X_Origin) + Long_Float (I - 1) * Long_Float (R.X_Inc);
                     X    : constant Gdouble := L + W * Gdouble ((Time - T0) / (T1 - T0));
                     V    : constant Float :=
                       (Float (Character'Pos (Element (R.Data, I))) - R.Y_Ref - R.Y_Origin)
                       * R.Y_Inc;
                     Y    : constant Gdouble := Y_Of (V, Scale, Offset, T, H);
                  begin
                     if First then
                        Move_To (Cr, X, Y);
                        First := False;
                     else
                        Line_To (Cr, X, Y);
                     end if;
                  end;
                  I := I + Step;
               end loop;
               Stroke (Cr);
            end if;
         end;
      end loop;
   end Draw_References;

   --  The index of the first item that may be in view (items are in order
   --  of their first sample)
   function First_In_View return Positive is
      Lo : Natural := 0;
      Hi : Natural := Natural (Items_Shown.Length);
      M  : Natural;
   begin
      --  Items 1 .. Lo start before V_First
      while Lo < Hi loop
         M := (Lo + Hi + 1) / 2;
         if Items_Shown (M).First < V_First then
            Lo := M;
         else
            Hi := M - 1;
         end if;
      end loop;
      return Positive'Max (1, Lo);
   end First_In_View;

   procedure Draw_Decoded (Cr : Cairo_Context; L, T, W, H : Gdouble) is
      Span   : constant Long_Float := Long_Float (V_Last - V_First + 1);
      Box_H  : constant Gdouble := 16.0;

      function X_Of (Sample : Natural) return Gdouble is
        (L + W * Gdouble ((Long_Float (Sample) - Long_Float (V_First)) / Span));
   begin
      if Items_Shown.Is_Empty or else Cap_Total = 0 then
         return;
      end if;
      Set_Line_Width (Cr, 1.0);
      for K in First_In_View .. Natural (Items_Shown.Length) loop
         declare
            It  : Decoded renames Items_Shown (K);
            X0  : constant Gdouble := Gdouble'Max (L - 2.0, X_Of (It.First));
            X1  : constant Gdouble := Gdouble'Min (L + W + 2.0, X_Of (It.Last + 1));
            Y   : constant Gdouble :=
              T + H - 6.0 - Box_H - Gdouble (Lane_Of (It.Ch) - 1) * (Box_H + 4.0);
            Col : constant Colour := Trace_Colour (It.Ch);
            S   : constant String := To_String (It.Label);
         begin
            exit when It.First > V_Last;
            if It.Last >= V_First then
               if It.Kind in 'S' | 'P' then
                  --  Start and stop: a marker with S or P
                  Set_Source_Rgb (Cr, (if It.Kind = 'S' then 0.3 else 1.0),
                                  (if It.Kind = 'S' then 1.0 else 0.35), 0.35);
                  Move_To (Cr, Gdouble'Floor (X0) + 0.5, Y);
                  Rel_Line_To (Cr, 0.0, Box_H);
                  Stroke (Cr);
                  Move_To (Cr, X0 + 2.0, Y + 12.0);
                  Show_Text (Cr, S);
               else
                  --  A box the length of the item, pointed at both ends
                  declare
                     Tip : constant Gdouble := Gdouble'Min (4.0, (X1 - X0) / 2.0);
                  begin
                     Move_To (Cr, X0, Y + Box_H / 2.0);
                     Line_To (Cr, X0 + Tip, Y);
                     Line_To (Cr, X1 - Tip, Y);
                     Line_To (Cr, X1, Y + Box_H / 2.0);
                     Line_To (Cr, X1 - Tip, Y + Box_H);
                     Line_To (Cr, X0 + Tip, Y + Box_H);
                     Close_Path (Cr);
                     Set_Source_Rgba (Cr, Col.R * 0.35, Col.G * 0.35, Col.B * 0.35, 0.9);
                     Fill_Preserve (Cr);
                     if It.Bad then
                        Set_Source_Rgb (Cr, 1.0, 0.25, 0.25);
                     else
                        Set_Colour (Cr, Col);
                     end if;
                     Stroke (Cr);
                     if X1 - X0 > Text_Width (S) + 8.0 then
                        Text (Cr, (X0 + X1 - Text_Width (S)) / 2.0, Y + 12.0, S,
                              (if It.Bad then (1.0, 0.5, 0.5) else Text_Colour));
                     end if;
                  end;
               end if;
            end if;
         end;
      end loop;
   end Draw_Decoded;

   Cursor_Colour : constant array (Cursor) of Colour :=
     ((1.0, 0.55, 0.2), (0.8, 0.5, 1.0));

   procedure Draw_Cursors (Cr : Cairo_Context; L, T, W, H : Gdouble) is
      T0, T1 : Long_Float;
      Lines  : array (1 .. 4) of Unbounded_String;
      Count  : Natural := 0;
      Widest : Natural := 0;

      procedure Add (S : String) is
      begin
         Count := Count + 1;
         Lines (Count) := To_Unbounded_String (S);
         Widest := Natural'Max (Widest, S'Length);
      end Add;

      Line_Colour : array (1 .. 4) of Colour := (others => Text_Colour);
      DT : constant Long_Float := Cur_Time (B) - Cur_Time (A);
   begin
      Window (T0, T1);
      for C in Cursor loop
         declare
            X : constant Gdouble :=
              L + W * Gdouble ((Cur_Time (C) - T0) / (T1 - T0));
         begin
            if X >= L and then X <= L + W then
               Set_Colour (Cr, Cursor_Colour (C));
               Set_Line_Width (Cr, 1.0);
               Set_Dash (Cr, (6.0, 4.0), 0.0);
               Move_To (Cr, Gdouble'Floor (X) + 0.5, T);
               Rel_Line_To (Cr, 0.0, H);
               Stroke (Cr);
               Set_Dash (Cr, No_Dashes, 0.0);
               Text (Cr, X + 4.0, T + H - 6.0, Cursor'Image (C), Cursor_Colour (C));
            end if;
         end;
      end loop;

      --  Readout, in a box at the top left of the plot
      Add ("A " & Eng (Float (Cur_Time (A)), "s") & "   B " &
           Eng (Float (Cur_Time (B)), "s"));
      Add ("ΔT " & Eng (Float (DT), "s") &
           (if abs DT > 0.0 then "   1/ΔT " & Eng (Float (1.0 / abs DT), "Hz")
            else ""));
      for Ch in Channel loop
         if (if Current_Mode = Capture then Chans (Ch).Captured
             else Chans (Ch).Display and then Chans (Ch).Has_Frame)
         then
            declare
               VA, VB : Float;
               KA, KB : Boolean;
            begin
               Cursor_Volts (A, Ch, VA, KA);
               Cursor_Volts (B, Ch, VB, KB);
               Add ("CH" & Character'Val (48 + Ch) &
                    "  A " & (if KA then Eng (VA, "V") else "...") &
                    "  B " & (if KB then Eng (VB, "V") else "...") &
                    (if KA and KB then "  ΔV " & Eng (VB - VA, "V") else ""));
               Line_Colour (Count) := Trace_Colour (Ch);
            end;
         end if;
      end loop;

      Set_Source_Rgba (Cr, 0.0, 0.0, 0.0, 0.75);
      Rectangle (Cr, L + 6.0, T + 6.0,
                 Text_Width ((1 .. Widest => ' ')) + 12.0,
                 16.0 * Gdouble (Count) + 8.0);
      Fill (Cr);
      for I in 1 .. Count loop
         Text (Cr, L + 12.0, T + 6.0 + 16.0 * Gdouble (I),
               To_String (Lines (I)), Line_Colour (I));
      end loop;
   end Draw_Cursors;

   function On_Draw
     (Self : access Gtk_Widget_Record'Class;
      Cr   : Cairo_Context) return Boolean
   is
      pragma Unreferenced (Self);
      L, T, W, H : Gdouble;
      X          : Gdouble;
   begin
      Set_Source_Rgb (Cr, 0.0, 0.0, 0.0);
      Paint (Cr);
      Geometry (L, T, W, H);
      Draw_Graticule (Cr, L, T, W, H);

      Save (Cr);
      Rectangle (Cr, L, T, W, H);
      Clip (Cr);
      Select_Font_Face (Cr, "Monospace", Cairo_Font_Slant_Normal,
                        Cairo_Font_Weight_Normal);
      Set_Font_Size (Cr, 12.0);
      if Current_Mode = Live and then XY_On then
         --  Its own square graticule over a blank plot
         Set_Source_Rgb (Cr, 0.0, 0.0, 0.0);
         Paint (Cr);
         Draw_XY (Cr, L, T, W, H);
      elsif Current_Mode = Live then
         Draw_References (Cr, L, T, W, H);
         Draw_Live (Cr, L, T, W, H);
         Draw_Math (Cr, L, T, W, H);
      else
         Draw_References (Cr, L, T, W, H);
         Draw_Capture (Cr, L, T, W, H);
         Draw_Math (Cr, L, T, W, H);
         Draw_Decoded (Cr, L, T, W, H);
         if Hovering then
            Set_Colour (Cr, Text_Colour);
            Set_Line_Width (Cr, 1.0);
            Set_Dash (Cr, (3.0, 3.0), 0.0);
            Move_To (Cr, Gdouble'Floor (Hover_X) + 0.5, T);
            Rel_Line_To (Cr, 0.0, H);
            Stroke (Cr);
            Set_Dash (Cr, No_Dashes, 0.0);
         end if;
      end if;
      Restore (Cr);

      --  Header: channel scales, timebase, trigger status
      Select_Font_Face (Cr, "Monospace", Cairo_Font_Slant_Normal,
                        Cairo_Font_Weight_Normal);
      Set_Font_Size (Cr, 12.0);
      if Cursors_On and then not (XY_On and then Current_Mode = Live) then
         Draw_Cursors (Cr, L, T, W, H);
      end if;
      X := L;
      for Ch in Channel loop
         declare
            Show : constant Boolean :=
              (if Current_Mode = Live then Chans (Ch).Display
               else Chans (Ch).Captured);
            Scale : constant Float :=
              (if Current_Mode = Live then Chans (Ch).Scale else Chans (Ch).C_Scale);
            S : constant String :=
              "CH" & Character'Val (48 + Ch) & " " & Eng (Scale, "V") & "/div";
         begin
            if Show then
               Text (Cr, X, 17.0, S, Trace_Colour (Ch));
               X := X + Text_Width (S) + 20.0;
            end if;
         end;
      end loop;
      if Refs_On and then not (XY_On and then Current_Mode = Live) then
         for Slot in Ref_Slot loop
            if Refs (Slot).Used then
               declare
                  S : constant String := "R" & Character'Val (48 + Slot);
               begin
                  Text (Cr, X, 17.0, S, Ref_Colour (Slot));
                  X := X + Text_Width (S) + 10.0;
               end;
            end if;
         end loop;
         X := X + 10.0;
      end if;
      if M_Mode /= Off then
         declare
            S : constant String :=
              "MATH " & Op_Symbol & " " & Eng (M_Scale, "") & "/div" &
              (if M_Mode = PC then " (PC)" else "");
         begin
            Set_Source_Rgb (Cr, Math_Colour_R, Math_Colour_G, Math_Colour_B);
            Move_To (Cr, X, 17.0);
            Show_Text (Cr, S);
            X := X + Text_Width (S) + 20.0;
         end;
      end if;
      declare
         Per_Div : constant Float :=
           (if Current_Mode = Live then TB_Scale
            else Float (V_Last - V_First + 1) * Cap_X_Inc / 12.0);
         S : constant String :=
           (if XY_On and then Current_Mode = Live then "XY  (X = CH1, Y = CH2)" else
            "H " & Eng (Per_Div, "s") & "/div") &
           (if Current_Mode = Live and then TB_Offset /= 0.0
            then "  pos " & Eng (TB_Offset, "s") else "");
         Status : constant String :=
           (if Current_Mode = Live then To_String (Trig_Status) else "CAPTURE");
      begin
         Text (Cr, X, 17.0, S, Text_Colour);
         Text (Cr, L + W - Text_Width (Status), 17.0, Status, Text_Colour);
      end;

      --  Footer: capture position and pointer readout
      if Current_Mode = Capture and then Cap_Total > 0 then
         declare
            T0 : constant Float := Cap_X_Origin + Float (V_First) * Cap_X_Inc;
            T1 : constant Float := Cap_X_Origin + Float (V_Last) * Cap_X_Inc;
         begin
            Text (Cr, L, T + H + 18.0,
                  (if Hovering then Hover_Text (L, W)
                   else Eng (T0, "s") & " .. " & Eng (T1, "s") & "   (" &
                        Natural'Image (V_Last - V_First + 1) & " of" &
                        Natural'Image (Cap_Total) & " samples;"
                        & " wheel zooms, drag pans, right click shows all)"),
                  Text_Colour);
         end;
      end if;
      return True;
   end On_Draw;

   -- -------------------------------------------------------------------------
   --  Mouse
   -- -------------------------------------------------------------------------

   function On_Scroll
     (Self  : access Gtk_Widget_Record'Class;
      Event : Gdk_Event_Scroll) return Boolean
   is
      pragma Unreferenced (Self);
      L, T, W, H : Gdouble;
      Factor     : Long_Float;
   begin
      if Current_Mode /= Capture or else Cap_Total = 0 then
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
         Span   : constant Long_Float := Long_Float (V_Last - V_First + 1);
         Anchor : constant Long_Float := Long_Float (V_First) + Frac * Span;
         New_Span : constant Long_Float := Span * Factor;
      begin
         Show_Samples (Anchor - Frac * New_Span, New_Span);
      end;
      return True;
   end On_Scroll;

   function On_Press
     (Self  : access Gtk_Widget_Record'Class;
      Event : Gdk_Event_Button) return Boolean
   is
      pragma Unreferenced (Self);
      L, T, W, H : Gdouble;
      T0, T1     : Long_Float;
   begin
      --  A press on or near a cursor line grabs that cursor
      if Cursors_On and then Event.Button = 1 then
         Geometry (L, T, W, H);
         Window (T0, T1);
         for C in Cursor loop
            if abs (Event.X - (L + W * Gdouble ((Cur_Time (C) - T0) / (T1 - T0))))
              <= 6.0
            then
               Cursor_Drag := True;
               Dragged     := C;
               return True;
            end if;
         end loop;
      end if;

      if Current_Mode /= Capture or else Cap_Total = 0 then
         return False;
      end if;
      if Event.Button = 1 then
         Dragging   := True;
         Drag_X     := Event.X;
         Drag_First := V_First;
      elsif Event.Button = 3 then
         Show_Samples (0.0, Long_Float (Cap_Total));
      end if;
      return True;
   end On_Press;

   function On_Release
     (Self  : access Gtk_Widget_Record'Class;
      Event : Gdk_Event_Button) return Boolean
   is
      pragma Unreferenced (Self, Event);
   begin
      Dragging    := False;
      Cursor_Drag := False;
      return False;
   end On_Release;

   function On_Motion
     (Self  : access Gtk_Widget_Record'Class;
      Event : Gdk_Event_Motion) return Boolean
   is
      pragma Unreferenced (Self);
      L, T, W, H : Gdouble;
      T0, T1     : Long_Float;
   begin
      Geometry (L, T, W, H);
      if Cursor_Drag then
         Window (T0, T1);
         Cur_Time (Dragged) := T0 + (T1 - T0) * Long_Float'Max
           (0.0, Long_Float'Min (1.0, Long_Float ((Event.X - L) / W)));
         Request_Cursor_Samples;
         Redraw;
         return True;
      end if;

      if Current_Mode /= Capture or else Cap_Total = 0 then
         return False;
      end if;
      Hovering := Event.X >= L and then Event.X <= L + W;
      Hover_X  := Event.X;
      if Dragging then
         declare
            Span : constant Long_Float := Long_Float (V_Last - V_First + 1);
         begin
            Show_Samples
              (Long_Float (Drag_First) +
                 Long_Float ((Drag_X - Event.X) / W) * Span, Span);
         end;
      else
         Redraw;
      end if;
      return True;
   end On_Motion;

   -- -------------------------------------------------------------------------
   --  Interface
   -- -------------------------------------------------------------------------

   function Create return Gtk.Drawing_Area.Gtk_Drawing_Area is
   begin
      Gtk.Drawing_Area.Gtk_New (Area);
      Area.Set_Size_Request (640, 420);
      Area.Add_Events (Scroll_Mask or Smooth_Scroll_Mask or Button_Press_Mask
                       or Button_Release_Mask or Pointer_Motion_Mask);
      Area.On_Draw (On_Draw'Access);
      Area.On_Scroll_Event (On_Scroll'Access);
      Area.On_Button_Press_Event (On_Press'Access);
      Area.On_Button_Release_Event (On_Release'Access);
      Area.On_Motion_Notify_Event (On_Motion'Access);
      return Area;
   end Create;


   procedure Set_XY (On : Boolean) is
   begin
      XY_On := On;
      Redraw;
   end Set_XY;

   procedure Set_Reference (Slot : Ref_Slot; Info : JSON_Value; Payload : String) is
      Ch : constant Integer := Get (Info, "ch");
   begin
      Refs (Slot) :=
        (Used     => True,
         Ch       => (if Ch in Channel then Ch else 1),
         Label    => To_Unbounded_String (String'(Get (Info, "label"))),
         Data     => To_Unbounded_String (Payload),
         X_Inc    => Get_Float (Info, "x_inc"),
         X_Origin => Get_Float (Info, "x_origin"),
         Y_Inc    => Get_Float (Info, "y_inc"),
         Y_Origin => Get_Float (Info, "y_origin"),
         Y_Ref    => Get_Float (Info, "y_ref"));
      Redraw;
   end Set_Reference;

   procedure Clear_References is
   begin
      Refs := (others => <>);
      Redraw;
   end Clear_References;

   procedure Show_References (On : Boolean) is
   begin
      Refs_On := On;
      Redraw;
   end Show_References;

   function Item_Label (Item : JSON_Value; Format : String; Width : Positive)
                        return String
   is
      Kind_S : constant String := Get (Item, "type");

      function Hex (V : Long_Long_Integer; Nibbles : Positive) return String is
         H : constant String := "0123456789ABCDEF";
         R : String (1 .. Nibbles);
         X : Long_Long_Integer := V;
      begin
         for K in reverse R'Range loop
            R (K) := H (Integer (X mod 16) + 1);
            X := X / 16;
         end loop;
         return R;
      end Hex;

      function Value_Image (V : Long_Long_Integer; Bits : Positive) return String is
      begin
         if Format = "dec" then
            return Trim (V'Image, Ada.Strings.Left);
         elsif Format = "bin" then
            declare
               R : String (1 .. Bits);
            begin
               for K in R'Range loop
                  R (K) := (if V / 2**(Bits - K) mod 2 = 1 then '1' else '0');
               end loop;
               return R;
            end;
         elsif Format = "ascii" and then V = 32 then
            return "SP";
         elsif Format = "ascii" and then V in 33 .. 126 then
            return (1 => Character'Val (V));
         elsif Format = "ascii" then
            return "\x" & Hex (V, 2);
         else
            return Hex (V, (Bits + 3) / 4);
         end if;
      end Value_Image;
   begin
      if Kind_S = "start" then
         return "S";
      elsif Kind_S = "stop" then
         return "P";
      end if;
      declare
         V : constant Long_Long_Integer := Long_Long_Integer (Long_Integer'(Get (Item, "value")));
      begin
         if Kind_S = "address" then
            return (if Get (Item, "read") then "R " else "W ") & Hex (V, 2);
         end if;
         return Value_Image (V, Width);
      end;
   end Item_Label;

   procedure Set_Decoded (Items : JSON_Array; Format : String; Width : Positive) is
      Lanes : Natural := 0;
   begin
      Items_Shown.Clear;
      Lane_Of := (others => 0);
      for K in 1 .. Length (Items) loop
         declare
            It     : constant JSON_Value := Get (Items, K);
            Kind_S : constant String := Get (It, "type");
            Ch     : constant Integer := Get (It, "ch");
         begin
            if Ch in Channel then
               if Lane_Of (Ch) = 0 then
                  Lanes := Lanes + 1;
                  Lane_Of (Ch) := Lanes;
               end if;
               Items_Shown.Append
                 ((First => Get (It, "first"),
                   Last  => Get (It, "last"),
                   Ch    => Ch,
                   Kind  => (if Kind_S = "start" then 'S' elsif Kind_S = "stop" then 'P'
                             elsif Kind_S = "address" then 'A' else 'D'),
                   Bad   => Has_Field (It, "error")
                              or else (Has_Field (It, "ack") and then not Get (It, "ack")),
                   Label => To_Unbounded_String (Item_Label (It, Format, Width))));
            end if;
         end;
      end loop;
      Redraw;
   end Set_Decoded;

   procedure Clear_Decoded is
   begin
      Items_Shown.Clear;
      Redraw;
   end Clear_Decoded;

   procedure Zoom_To (First, Last : Natural; Times : Long_Float := 12.0) is
      Length_Of : constant Long_Float := Long_Float (Last - First + 1);
      Span      : constant Long_Float := Long_Float'Max (Length_Of * Times, 200.0);
   begin
      if Cap_Total > 0 then
         Show_Samples (Long_Float (First) + Length_Of / 2.0 - Span / 2.0, Span);
      end if;
   end Zoom_To;

   procedure Set_Math
     (Mode     : Math_Mode;
      Operator : String;
      Scale    : Float;
      Offset   : Float)
   is
      Changed : constant Boolean := Mode /= M_Mode or else M_Op /= Operator;
   begin
      M_Mode   := Mode;
      M_Op     := To_Unbounded_String (Operator);
      M_Scale  := Float'Max (1.0E-12, Scale);
      M_Offset := Offset;
      if Changed then
         Free (M_Frame);
         Free (M_Cols);
         if Current_Mode = Capture then
            Request_Math_View;
         end if;
      end if;
      Redraw;
   end Set_Math;

   procedure Math_Frame (Event : JSON_Value; Payload : String) is
      Source : constant String := Get (Event, "source");
   begin
      --  Only the kind of math currently shown
      if (Source = "scope") = (M_Mode = Scope) and then M_Mode /= Off then
         Free (M_Frame);
         M_Frame := new Float_Array'(Gui_Client.Floats (Payload));
         if Current_Mode = Live then
            Redraw;
         end if;
      end if;
   end Math_Frame;

   procedure Set_Cursors (On : Boolean) is
      T0, T1 : Long_Float;
   begin
      Cursors_On := On;
      if On then
         Window (T0, T1);
         Cur_Time (A) := T0 + (T1 - T0) / 3.0;
         Cur_Time (B) := T0 + 2.0 * (T1 - T0) / 3.0;
         Request_Cursor_Samples;
      end if;
      Redraw;
   end Set_Cursors;

   procedure Set_Channel
     (Ch      : Channel;
      Display : Boolean;
      Scale   : Float;
      Offset  : Float) is
   begin
      Chans (Ch).Display := Display;
      Chans (Ch).Scale   := Scale;
      Chans (Ch).Offset  := Offset;
      Redraw;
   end Set_Channel;

   procedure Set_Timebase (Scale, Offset : Float) is
   begin
      TB_Scale  := Scale;
      TB_Offset := Offset;
      Redraw;
   end Set_Timebase;

   procedure Set_Trigger (Source : Natural; Level : Float) is
   begin
      Trig_Source := Source;
      Trig_Level  := Level;
      Redraw;
   end Set_Trigger;

   procedure Set_Trigger_Status (Text : String) is
   begin
      Trig_Status := To_Unbounded_String (Text);
      Redraw;
   end Set_Trigger_Status;

   procedure Live_Frame (Ch : Channel; Frame : JSON_Value; Payload : String)
   is
      C : Chan_State renames Chans (Ch);
   begin
      C.Has_Frame  := True;
      C.Frame      := To_Unbounded_String (Payload);
      C.F_Y_Inc    := Get_Float (Frame, "y_inc");
      C.F_Y_Origin := Get_Float (Frame, "y_origin");
      C.F_Y_Ref    := Get_Float (Frame, "y_ref");
      C.F_X_Inc    := Get_Float (Frame, "x_inc");
      C.F_X_Origin := Get_Float (Frame, "x_origin");
      if Current_Mode = Live then
         Redraw;
      end if;
   end Live_Frame;

   procedure Set_Mode (Mode : Mode_Type) is
   begin
      Current_Mode := Mode;
      Hovering     := False;
      Dragging     := False;
      if Mode = Capture then
         Request_Views;
         Request_Cursor_Samples;
      end if;
      Redraw;
   end Set_Mode;

   function Mode return Mode_Type is (Current_Mode);

   procedure Clear_Captures is
   begin
      for C of Chans loop
         C.Captured  := False;
         C.Col_Count := 0;
         C.Info      := JSON_Null;
      end loop;
      Cap_Total := 0;
      Cur_Index := (others => (others => -1));
      Free (M_Cols);
      Redraw;
   end Clear_Captures;

   procedure Captured (Ch : Channel; Info : JSON_Value) is
      C : Chan_State renames Chans (Ch);
      First_Capture : constant Boolean := Cap_Total = 0;
   begin
      C.Captured   := True;
      C.Info       := Info;
      C.Col_Count  := 0;
      C.C_Y_Inc    := Get_Float (Info, "y_inc");
      C.C_Y_Origin := Get_Float (Info, "y_origin");
      C.C_Y_Ref    := Get_Float (Info, "y_ref");
      C.C_Scale    := C.Scale;
      C.C_Offset   := C.Offset;
      Cap_Total    := Get (Info, "points");
      Cap_X_Inc    := Get_Float (Info, "x_inc");
      Cap_X_Origin := Get_Float (Info, "x_origin");
      if First_Capture then
         V_First := 0;
         V_Last  := Cap_Total - 1;
      end if;
      Request_View (Ch);
      Request_Cursor_Samples;
      Redraw;
   end Captured;

   function Is_Captured (Ch : Channel) return Boolean is (Chans (Ch).Captured);

   procedure View_Range (First, Last : out Natural) is
   begin
      First := V_First;
      Last  := V_Last;
   end View_Range;

   function Capture_Info (Ch : Channel) return JSON_Value is (Chans (Ch).Info);

   function Live_Points (Ch : Channel) return Point_Array is
      C : Chan_State renames Chans (Ch);
      N : constant Natural := (if C.Has_Frame then Length (C.Frame) else 0);
      Result : Point_Array (1 .. N);
   begin
      for I in Result'Range loop
         Result (I) :=
           (Time  => C.F_X_Origin + Float (I - 1) * C.F_X_Inc,
            Volts => (Float (Character'Pos (Element (C.Frame, I))) - C.F_Y_Ref
                      - C.F_Y_Origin) * C.F_Y_Inc);
      end loop;
      return Result;
   end Live_Points;

end Scope_View;
