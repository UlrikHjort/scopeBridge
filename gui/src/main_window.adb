-- ***************************************************************************
--                    ScopeBridge GUI - Main Window Body
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

with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Calendar.Time_Zones;
with Ada.Characters.Handling;  use Ada.Characters.Handling;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Exceptions;           use Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;        use Ada.Strings.Fixed;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with Ada.Text_IO;

with GNATCOLL.JSON;            use GNATCOLL.JSON;

with Glib;                     use Glib;
with Glib.Main;
with Gtk.Box;                  use Gtk.Box;
with Gtk.Button;               use Gtk.Button;
with Gtk.Check_Button;         use Gtk.Check_Button;
with Gtk.Combo_Box;            use Gtk.Combo_Box;
with Gtk.Combo_Box_Text;       use Gtk.Combo_Box_Text;
with Gtk.Enums;                use Gtk.Enums;
with Gtk.Grid;                 use Gtk.Grid;
with Gtk.Label;                use Gtk.Label;
with Gtk.Main;
with Gtk.Progress_Bar;         use Gtk.Progress_Bar;
with Gtk.Scrolled_Window;      use Gtk.Scrolled_Window;
with Gtk.Spin_Button;          use Gtk.Spin_Button;
with Gtk.Toggle_Button;        use Gtk.Toggle_Button;
with Gtk.Widget;               use Gtk.Widget;
with Gtk.Window;               use Gtk.Window;

with About_Box;
with Decode_Panel;
with Timing_Panel;
with Server.Wire;
with Gui_Client;
with Scope_View;               use Scope_View;
with Spectrum_View;
with Units;                    use Units;
with Widgets;                  use Widgets;

package body Main_Window is

   use type Gtk_Widget;

   Live_Interval_MS : constant := 50;
   Max_Export       : constant := 2_000_000;   --  samples per channel

   --  Choices offered by the controls, and their protocol values
   Scale_Values : constant Float_Array := Steps_125 (1.0E-3, 100.0);
   Time_Values  : constant Float_Array := Steps_125 (5.0E-9, 50.0);
   Probe_Values : constant Float_Array :=
     (0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0,
      100.0, 200.0, 500.0, 1000.0);

   type Name_Array is array (Natural range <>) of Unbounded_String;
   function "+" (S : String) return Unbounded_String
     renames To_Unbounded_String;

   Couplings : constant Name_Array := (+"dc", +"ac", +"gnd");
   Sources   : constant Name_Array := (+"ch1", +"ch2", +"ac", +"ext");
   Slopes    : constant Name_Array := (+"rising", +"falling", +"either");
   Sweeps    : constant Name_Array := (+"auto", +"normal", +"single");
   Modes     : constant Name_Array := (+"edge", +"pulse", +"slope");
   Whens     : constant Name_Array :=
     (+"pos_greater", +"pos_less", +"neg_greater", +"neg_less",
      +"pos_in_range", +"neg_in_range");
   Slope_Windows : constant Name_Array := (+"a", +"b", +"both");
   Channels2 : constant Name_Array := (+"ch1", +"ch2");

   --  Pulse widths and slope times offered (8 ns .. 10 s on the scope)
   Trigger_Times : constant Float_Array := Steps_125 (1.0E-8, 10.0);

   type Gtk_Combo_Box_Text_Array is array (Positive range <>) of Gtk_Combo_Box_Text;

   -- -------------------------------------------------------------------------
   --  Widgets and state
   -- -------------------------------------------------------------------------

   Win         : Gtk_Window;
   Status_Line : Gtk_Label;
   Progress    : Gtk_Progress_Bar;

   Ch_On       : array (Channel) of Gtk_Check_Button;
   Ch_Scale    : array (Channel) of Gtk_Combo_Box_Text;
   Ch_Position : array (Channel) of Gtk_Spin_Button;   --  divisions
   Ch_Coupling : array (Channel) of Gtk_Combo_Box_Text;
   Ch_Probe    : array (Channel) of Gtk_Combo_Box_Text;

   TB_Scale    : Gtk_Combo_Box_Text;
   TB_Position : Gtk_Spin_Button;                      --  divisions

   --  Trigger mode, and each mode's controls (only the active mode's shown)
   Trig_Mode   : Gtk_Combo_Box_Text;                   --  Edge, Pulse, Slope
   Edge_Box, Pulse_Box, Slope_Box : Gtk_Grid;
   P_Source, P_When, P_Width, P_Lower, P_Upper : Gtk_Combo_Box_Text;
   P_Level     : Gtk_Spin_Button;
   S_Source, S_When, S_Time, S_Lower, S_Upper, S_Window : Gtk_Combo_Box_Text;
   S_Level_A, S_Level_B : Gtk_Spin_Button;

   Trig_Source : Gtk_Combo_Box_Text;
   Trig_Slope  : Gtk_Combo_Box_Text;
   Trig_Level  : Gtk_Spin_Button;                      --  volts
   Trig_Sweep  : Gtk_Combo_Box_Text;

   Meas_Channel : Gtk_Combo_Box_Text;                  --  CH1, CH2, off

   --  Measurement slots: the scope keeps at most 5 items armed
   Slots        : constant := 5;
   Slot_Item    : array (1 .. Slots) of Gtk_Combo_Box_Text;
   Slot_Value   : array (1 .. Slots) of Gtk_Label;

   --  Items offered, as protocol names; index 0 of a slot's combo is "-"
   type Item_Info is record
      Name, Label, Unit : Unbounded_String;
   end record;
   type Item_Table is array (Positive range <>) of Item_Info;

   function Item (Name, Label, Unit : String) return Item_Info is
     (+Name, +Label, +Unit);

   Items : constant Item_Table :=
     (Item ("freq",   "Frequency", "Hz"),
      Item ("period", "Period",    "s"),
      Item ("vpp",    "Vpp",       "V"),
      Item ("vmax",   "Vmax",      "V"),
      Item ("vmin",   "Vmin",      "V"),
      Item ("vtop",   "Vtop",      "V"),
      Item ("vbase",  "Vbase",     "V"),
      Item ("vamp",   "Vamp",      "V"),
      Item ("vavg",   "Vavg",      "V"),
      Item ("vrms",   "Vrms",      "V"),
      Item ("rise",   "Rise time", "s"),
      Item ("fall",   "Fall time", "s"),
      Item ("pwidth", "+Width",    "s"),
      Item ("nwidth", "-Width",    "s"),
      Item ("pduty",  "+Duty",     "%"),
      Item ("nduty",  "-Duty",     "%"));

   --  Math and FFT: each Off (0), done by the scope (1) or on the PC, by
   --  the server (2).  The scope has one math channel, so they cannot both
   --  use it.
   Math_Mode_Box  : Gtk_Combo_Box_Text;
   Math_Op_Box    : Gtk_Combo_Box_Text;     --  A+B, A-B, AxB, A/B
   Math_Scale_Box : Gtk_Combo_Box_Text;
   Math_Position  : Gtk_Spin_Button;        --  divisions
   FFT_Mode_Box   : Gtk_Combo_Box_Text;
   FFT_Source_Box : Gtk_Combo_Box_Text;     --  CH1, CH2
   FFT_Window_Box : Gtk_Combo_Box_Text;
   FFT_Data_Box   : Gtk_Combo_Box_Text;     --  scope FFT of screen or memory
   Spectrum_Area  : Gtk_Widget;

   Math_Scale_Values : constant Float_Array := Steps_125 (1.0E-3, 1000.0);
   Scope_Math_Used   : Boolean := False;    --  we switched its display on

   Default_Slots : constant array (1 .. Slots) of Positive :=
     (1, 2, 3, 10, 9);   --  Frequency, Period, Vpp, Vrms, Vavg

   --  The item in Slot, 0 = none
   function Slot_Index (Slot : Positive) return Natural is
     (Natural (Slot_Item (Slot).Get_Active));

   --  Set while controls are being updated from a status reply, so their
   --  "changed" handlers do not send the values straight back
   Updating       : Boolean := False;

   --  Last known settings, for converting positions (div) to offsets
   Scale_Now      : array (Channel) of Float := (others => 1.0);
   TB_Scale_Now   : Float := 1.0E-3;

   Display_Box    : Gtk_Combo_Box_Text;    --  YT, XY

   --  Acquisition mode and memory depth; the depths offered depend on
   --  whether one or both channels are on
   Acq_Type       : Gtk_Combo_Box_Text;    --  Normal, Average, Peak, High res
   Acq_Averages   : Gtk_Combo_Box_Text;    --  2 .. 1024
   Acq_Depth      : Gtk_Combo_Box_Text;    --  Auto, then Depths (Depth_Dual)
   Acq_Rate       : Gtk_Label;
   Depth_Dual     : Boolean := False;

   --  Pass/fail
   Mask_Source    : Gtk_Combo_Box_Text;
   Mask_X, Mask_Y : Gtk_Spin_Button;       --  divisions
   Mask_Stop      : Gtk_Check_Button;      --  stop on fail
   Mask_Counts    : Gtk_Label;

   --  References
   Ref_Slot_Box   : Gtk_Combo_Box_Text;    --  R1 .. R4
   Ref_Source     : Gtk_Combo_Box_Text;    --  CH1, CH2
   Ref_List       : Gtk_Label;

   Status_Pending : Boolean := False;
   Capturing      : Natural := 0;   --  capture replies still awaited

   Acq_Types   : constant Name_Array := (+"normal", +"average", +"peak", +"hires");

   type Depth_Array is array (1 .. 5) of Natural;
   Depths : constant array (Boolean) of Depth_Array :=
     (False => (12_000, 120_000, 1_200_000, 12_000_000, 24_000_000),
      True  => (6_000, 60_000, 600_000, 6_000_000, 12_000_000));

   Operators   : constant Name_Array := (+"add", +"sub", +"mul", +"div");
   FFT_Windows : constant Name_Array :=
     (+"rect", +"hann", +"hamming", +"blackman", +"flattop");
   Window_Labels : constant Name_Array :=
     (+"Rect", +"Hann", +"Hamming", +"Blackman", +"Flat top");

   function Current_Math return Scope_View.Math_Mode is
     (case Math_Mode_Box.Get_Active is
         when 1 => Scope_View.Scope, when 2 => Scope_View.PC,
         when others => Scope_View.Off);

   function FFT_Mode return Natural is
     (Natural'Max (0, Integer (FFT_Mode_Box.Get_Active)));

   function Current_Op return String is
     (To_String (Operators (Integer'Max (0, Integer (Math_Op_Box.Get_Active)))));

   function FFT_Channel return Channel is
     (if FFT_Source_Box.Get_Active = 1 then 2 else 1);

   function FFT_Window_Index return Natural is
     (Natural'Max (0, Integer (FFT_Window_Box.Get_Active)));

   function Math_Scale return Float is
     (Math_Scale_Values (Math_Scale_Values'First +
        Natural'Max (0, Integer (Math_Scale_Box.Get_Active))));

   --  Tell the display how to draw the math trace
   procedure Apply_Math_View is
   begin
      Scope_View.Set_Math
        (Current_Math, Current_Op, Math_Scale,
         Float (Math_Position.Get_Value) * Math_Scale);
   end Apply_Math_View;

   -- -------------------------------------------------------------------------
   --  Helpers
   -- -------------------------------------------------------------------------

   procedure Say (Text : String) is
   begin
      Status_Line.Set_Text (Text);
   end Say;

   procedure On_Error (Text : String) is
   begin
      Say ("Error: " & Text);
   end On_Error;

   function Number (V : JSON_Value; Name : String) return Float is
     (if Kind (Get (V, Name)) = JSON_Int_Type
      then Float (Integer'(Get (V, Name)))
      else Float (Long_Float'(Get_Long_Float (V, Name))));

   function Index_Of (Names : Name_Array; S : String) return Gint is
   begin
      for I in Names'Range loop
         if Names (I) = S then
            return Gint (I);
         end if;
      end loop;
      return 0;
   end Index_Of;

   function Members return JSON_Value renames Create_Object;

   function With_Field
     (Object : JSON_Value; Name : String; Value : JSON_Value) return JSON_Value
   is
   begin
      Set_Field (Object, Name, Value);
      return Object;
   end With_Field;

   function Ch_Members (Ch : Channel) return JSON_Value is
     (With_Field (Members, "ch", Create (Integer (Ch))));

   function Which (W : access Gtk_Widget_Record'Class;
                   Of_Channel : access function (Ch : Channel) return Gtk_Widget)
                   return Channel is
   begin
      return (if Gtk_Widget (W) = Of_Channel (1) then 1 else 2);
   end Which;






   --  Show the controls of the selected trigger mode only
   procedure Show_Trigger_Mode is
      M : constant Gint := Trig_Mode.Get_Active;
   begin
      Edge_Box.Set_Visible (M <= 0);
      Pulse_Box.Set_Visible (M = 1);
      Slope_Box.Set_Visible (M = 2);
   end Show_Trigger_Mode;

   function Image (X : Long_Float) return String is
     (Trim (Long_Float'Image (X), Ada.Strings.Left));

   function Image (X : Float) return String is
     (Trim (Float'Image (X), Ada.Strings.Left));

   -- -------------------------------------------------------------------------
   --  Status: the server's view of the scope settings, shown in the controls
   -- -------------------------------------------------------------------------

   --  The memory depths for the channels on
   procedure Fill_Depths is
   begin
      Acq_Depth.Remove_All;
      Acq_Depth.Append_Text ("Auto");
      for D of Depths (Depth_Dual) loop
         Acq_Depth.Append_Text (Eng (Float (D), "pts"));
      end loop;
   end Fill_Depths;

   procedure On_Status (Reply : JSON_Value; Payload : String) is
      pragma Unreferenced (Payload);
   begin
      Status_Pending := False;
      if not Get (Reply, "ok") then
         On_Error (Get (Reply, "error"));
         return;
      end if;

      Updating := True;
      declare
         Channels : constant JSON_Array := Get (Reply, "channels");
         TB       : constant JSON_Value := Get (Reply, "timebase");
         Trig     : constant JSON_Value := Get (Reply, "trigger");
         Source   : constant String     := Get (Trig, "source");
      begin
         for I in 1 .. Length (Channels) loop
            declare
               C      : constant JSON_Value := Get (Channels, I);
               Ch     : constant Channel := Get (C, "ch");
               Scale  : constant Float := Number (C, "scale");
               Offset : constant Float := Number (C, "offset");
               On     : constant Boolean := Get (C, "display");
            begin
               Scale_Now (Ch) := Scale;
               Ch_On (Ch).Set_Active (On);
               Ch_Scale (Ch).Set_Active
                 (Gint (Nearest (Scale_Values, Scale) - Scale_Values'First));
               Ch_Position (Ch).Set_Value (Gdouble (Offset / Scale));
               Ch_Coupling (Ch).Set_Active
                 (Index_Of (Couplings, Get (C, "coupling")));
               Ch_Probe (Ch).Set_Active
                 (Gint (Nearest (Probe_Values, Number (C, "probe")) - 1));
               Scope_View.Set_Channel (Ch, On, Scale, Offset);
            end;
         end loop;

         TB_Scale_Now := Number (TB, "scale");
         TB_Scale.Set_Active
           (Gint (Nearest (Time_Values, TB_Scale_Now) - Time_Values'First));
         TB_Position.Set_Value
           (Gdouble (Number (TB, "offset") / TB_Scale_Now));
         Scope_View.Set_Timebase (TB_Scale_Now, Number (TB, "offset"));

         Trig_Source.Set_Active (Index_Of (Sources, Source));
         Trig_Slope.Set_Active (Index_Of (Slopes, Get (Trig, "slope")));
         Trig_Sweep.Set_Active (Index_Of (Sweeps, Get (Trig, "sweep")));
         Trig_Level.Set_Value (Gdouble (Number (Trig, "level")));
         Scope_View.Set_Trigger
           ((if Source = "ch1" then 1 elsif Source = "ch2" then 2 else 0),
            Number (Trig, "level"));
         Scope_View.Set_Trigger_Status
           (To_Upper (String'(Get (Reply, "trigger_status"))));

         if Has_Field (Trig, "mode") then
            declare
               Mode : constant String := Get (Trig, "mode");
               function Time_Index (V : JSON_Value; Name : String) return Gint is
                 (Gint (Nearest (Trigger_Times, Number (V, Name)) - Trigger_Times'First));
            begin
               Trig_Mode.Set_Active (Index_Of (Modes, Mode));
               Show_Trigger_Mode;
               if Has_Field (Trig, "pulse") then
                  declare
                     P : constant JSON_Value := Get (Trig, "pulse");
                  begin
                     P_Source.Set_Active (Index_Of (Channels2, Get (P, "source")));
                     P_When.Set_Active (Index_Of (Whens, Get (P, "when")));
                     P_Width.Set_Active (Time_Index (P, "width"));
                     P_Lower.Set_Active (Time_Index (P, "lower"));
                     P_Upper.Set_Active (Time_Index (P, "upper"));
                     P_Level.Set_Value (Gdouble (Number (P, "level")));
                     Scope_View.Set_Trigger
                       (Integer (Index_Of (Channels2, Get (P, "source"))) + 1,
                        Number (P, "level"));
                  end;
               end if;
               if Has_Field (Trig, "slope_trigger") then
                  declare
                     L : constant JSON_Value := Get (Trig, "slope_trigger");
                  begin
                     S_Source.Set_Active (Index_Of (Channels2, Get (L, "source")));
                     S_When.Set_Active (Index_Of (Whens, Get (L, "when")));
                     S_Time.Set_Active (Time_Index (L, "time"));
                     S_Lower.Set_Active (Time_Index (L, "lower"));
                     S_Upper.Set_Active (Time_Index (L, "upper"));
                     S_Window.Set_Active (Index_Of (Slope_Windows, Get (L, "window")));
                     S_Level_A.Set_Value (Gdouble (Number (L, "level_a")));
                     S_Level_B.Set_Value (Gdouble (Number (L, "level_b")));
                     Scope_View.Set_Trigger (0, 0.0);   --  two levels: no marker
                  end;
               end if;
            end;
         end if;

         if Has_Field (Reply, "acquire") then
            declare
               A     : constant JSON_Value := Get (Reply, "acquire");
               Dual  : constant Boolean :=
                 Ch_On (1).Get_Active and then Ch_On (2).Get_Active;
               Depth : constant Integer := Get (A, "memory_depth");
            begin
               Acq_Type.Set_Active (Index_Of (Acq_Types, Get (A, "type")));
               Acq_Averages.Set_Active
                 (Gint (Nearest ((2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0, 256.0,
                                  512.0, 1024.0), Float (Integer'(Get (A, "averages"))))) - 1);
               Acq_Averages.Set_Sensitive (Acq_Type.Get_Active = 1);
               if Dual /= Depth_Dual then
                  Depth_Dual := Dual;
                  Fill_Depths;
               end if;
               Acq_Depth.Set_Active (0);
               for K in Depth_Array'Range loop
                  if Depths (Depth_Dual) (K) = Depth then
                     Acq_Depth.Set_Active (Gint (K));
                  end if;
               end loop;
               Acq_Rate.Set_Text (Eng (Number (A, "sample_rate"), "Sa/s"));
            end;
         end if;

         if Has_Field (Reply, "mask") then
            declare
               M : constant JSON_Value := Get (Reply, "mask");
            begin
               if not Get (M, "enable") then
                  Mask_Counts.Set_Text ("Test off");
               else
                  declare
                     Passed : constant Long_Integer := Get (M, "passed");
                     Failed : constant Long_Integer := Get (M, "failed");
                     Total  : constant Long_Integer := Get (M, "total");
                  begin
                     Mask_Counts.Set_Text
                       ((if Get (M, "running") then "Running: " else "Stopped: ") &
                        "passed" & Passed'Image & ", failed" & Failed'Image &
                        (if Total > 0
                         then " (" & Eng (100.0 * Float (Failed) / Float (Total), "") & "%)"
                         else ""));
                  end;
               end if;
            end;
         end if;

         if Current_Math = Scope_View.Scope and then Has_Field (Reply, "math") then
            declare
               M     : constant JSON_Value := Get (Reply, "math");
               Scale : constant Float := Number (M, "scale");
            begin
               Math_Scale_Box.Set_Active
                 (Gint (Nearest (Math_Scale_Values, Scale) - Math_Scale_Values'First));
               Math_Position.Set_Value (Gdouble (Number (M, "offset") / Scale));
               Scope_View.Set_Math (Scope_View.Scope, Current_Op, Scale,
                                    Number (M, "offset"));
            end;
         end if;
      end;
      Updating := False;
   exception
      when E : others =>
         Updating := False;
         On_Error ("unexpected status: " & Exception_Message (E));
   end On_Status;

   procedure Refresh_Status is
   begin
      if not Status_Pending then
         Status_Pending := True;
         Gui_Client.Request ("status", On_Reply => On_Status'Access);
      end if;
   end Refresh_Status;

   --  Reply to a settings request: report failure, then show what the
   --  scope actually did (it may round or clamp values)
   procedure On_Set (Reply : JSON_Value; Payload : String) is
      pragma Unreferenced (Payload);
   begin
      if not Get (Reply, "ok") then
         On_Error (Get (Reply, "error"));
      end if;
      Refresh_Status;
   end On_Set;

   procedure Set (Cmd : String; Fields : JSON_Value) is
   begin
      if not Updating then
         Gui_Client.Request (Cmd, Fields, On_Set'Access);
      end if;
   end Set;

   -- -------------------------------------------------------------------------
   --  Live mode and events
   -- -------------------------------------------------------------------------


   function Measured_Channel return Integer is
     (case Meas_Channel.Get_Active is
         when 0 => 1, when 1 => 2, when others => 0);

   procedure Start_Live is
      M : constant JSON_Value := Members;
   begin
      Set_Field (M, "on", True);
      Set_Field (M, "interval_ms", Integer'(Live_Interval_MS));
      Set_Field (M, "measure_ch", Measured_Channel);
      declare
         Names : JSON_Array := Empty_Array;
      begin
         for Slot in 1 .. Slots loop
            if Slot_Index (Slot) > 0 then
               Append (Names, Create (To_String (Items (Slot_Index (Slot)).Name)));
            end if;
         end loop;
         Set_Field (M, "measure_items", Create (Names));
      end;
      Set_Field (M, "scope_math",
                 Current_Math = Scope_View.Scope or else FFT_Mode = 1);
      if Current_Math = Scope_View.PC and then Current_Op /= "div" then
         Set_Field (M, "math", Current_Op);
      end if;
      if FFT_Mode = 2 then
         declare
            Spec : constant JSON_Value := Members;
         begin
            Set_Field (Spec, "ch", Integer (FFT_Channel));
            Set_Field (Spec, "window",
                       To_String (FFT_Windows (FFT_Window_Index)));
            Set_Field (M, "spectrum", Spec);
         end;
      end if;
      Gui_Client.Request ("live", M);
   end Start_Live;

   --  Set up the scope's math channel for whichever of math and FFT uses
   --  it, or switch it off if we switched it on and neither does now
   procedure Configure_Scope_Math is
      M : constant JSON_Value := Members;
   begin
      if FFT_Mode = 1 then
         Set_Field (M, "display", True);
         Set_Field (M, "operator", "fft");
         Set_Field (M, "fft_source", (if FFT_Channel = 1 then "ch1" else "ch2"));
         Set_Field (M, "fft_window", To_String (FFT_Windows (FFT_Window_Index)));
         Set_Field (M, "fft_mode",
                    (if FFT_Data_Box.Get_Active = 1 then "memory" else "trace"));
      elsif Current_Math = Scope_View.Scope then
         Set_Field (M, "display", True);
         Set_Field (M, "operator", Current_Op);
         Set_Field (M, "source1", "ch1");
         Set_Field (M, "source2", "ch2");
      elsif Scope_Math_Used then
         Set_Field (M, "display", False);
      else
         return;
      end if;
      Scope_Math_Used := FFT_Mode = 1 or else Current_Math = Scope_View.Scope;
      Gui_Client.Request ("set_math", M, On_Set'Access);
   end Configure_Scope_Math;

   --  "FFT CH1 (PC, hann)": Source is the protocol's "scope" or "server",
   --  shown as the user knows them from the controls
   function Spectrum_Label (Source : String; Ch : Integer;
                            Window : String; Capture : Boolean := False)
                            return String is
     ("FFT CH" & Character'Val (48 + Ch) & (if Capture then " capture" else "")
      & " (" & (if Source = "server" then "PC" else Source) & ", " & Window & ")");

   procedure On_Capture_Spectrum (Reply : JSON_Value; Payload : String) is
   begin
      if not Get (Reply, "ok") then
         On_Error (Get (Reply, "error"));
         return;
      end if;
      Spectrum_View.Show
        (Gui_Client.Floats (Payload),
         Long_Float (Number (Reply, "f0")), Long_Float (Number (Reply, "df")),
         Long_Float (Number (Reply, "bin_width")), Get (Reply, "unit"),
         Get (Reply, "window"),
         Spectrum_Label ("server", Get (Reply, "ch"), Get (Reply, "window"),
                         Capture => True));
      Say ("Spectrum of the capture: RBW " &
           Eng (Number (Reply, "bin_width"), "Hz"));
   end On_Capture_Spectrum;

   --  The server's spectrum of the captured FFT source channel
   procedure Request_Capture_Spectrum is
      M : constant JSON_Value := Members;
   begin
      if FFT_Mode = 2 and then Scope_View.Mode = Capture
        and then Scope_View.Is_Captured (FFT_Channel)
      then
         Set_Field (M, "ch", Integer (FFT_Channel));
         Set_Field (M, "window", To_String (FFT_Windows (FFT_Window_Index)));
         Gui_Client.Request ("spectrum", M, On_Capture_Spectrum'Access);
         Say ("Computing the spectrum of the capture ...");
      end if;
   end Request_Capture_Spectrum;

   procedure Show_Measurements (Event : JSON_Value) is
   begin
      for Slot in 1 .. Slots loop
         if Slot_Index (Slot) > 0 then
            declare
               Info : Item_Info renames Items (Slot_Index (Slot));
               Name : constant String := To_String (Info.Name);
            begin
               if not Has_Field (Event, Name)
                 or else Kind (Get (Event, Name)) = JSON_Null_Type
               then
                  Slot_Value (Slot).Set_Text ("-");
               elsif Info.Unit = "%" then
                  --  Duty cycles come as fractions
                  Slot_Value (Slot).Set_Text
                    (Eng (100.0 * Number (Event, Name), "") & "%");
               else
                  Slot_Value (Slot).Set_Text
                    (Eng (Number (Event, Name), To_String (Info.Unit)));
               end if;
            end;
         else
            Slot_Value (Slot).Set_Text ("");
         end if;
      end loop;
   end Show_Measurements;

   -- -------------------------------------------------------------------------
   --  Recording measurements to CSV
   -- -------------------------------------------------------------------------

   Record_Button : Gtk_Button;
   Recording     : Boolean := False;
   Record_File   : Ada.Text_IO.File_Type;
   Record_Name   : Unbounded_String;
   Record_Start  : Ada.Calendar.Time;
   Record_Rows   : Natural := 0;

   function Now_Image return String is
     (Ada.Calendar.Formatting.Image
        (Ada.Calendar.Clock, Include_Time_Fraction => True,
         Time_Zone => Ada.Calendar.Time_Zones.UTC_Time_Offset));

   --  One CSV row per measure event while recording: time, seconds since
   --  the start, channel, then the slots' values in protocol units
   procedure Record_Row (Event : JSON_Value) is
      use Ada.Text_IO;
      use type Ada.Calendar.Time;
      Elapsed : constant Duration := Ada.Calendar.Clock - Record_Start;
   begin
      Put (Record_File, Now_Image & "," &
           Trim (Duration'Image (Elapsed), Ada.Strings.Left) & "," &
           Trim (Integer'Image (Get (Event, "ch")), Ada.Strings.Left));
      for Slot in 1 .. Slots loop
         if Slot_Index (Slot) > 0 then
            declare
               Name : constant String := To_String (Items (Slot_Index (Slot)).Name);
            begin
               Put (Record_File, ",");
               if Has_Field (Event, Name)
                 and then Kind (Get (Event, Name)) /= JSON_Null_Type
               then
                  Put (Record_File, Image (Number (Event, Name)));
               end if;
            end;
         end if;
      end loop;
      New_Line (Record_File);
      Flush (Record_File);
      Record_Rows := Record_Rows + 1;
      if Record_Rows mod 10 = 1 then
         Say ("Recording to " & To_String (Record_Name) & ":" &
              Record_Rows'Image & " rows");
      end if;
   exception
      when E : others =>
         On_Error ("recording stopped: " & Exception_Message (E));
         Recording := False;
   end Record_Row;

   procedure Refresh_Refs;

   procedure On_Event (Event : JSON_Value; Payload : String) is
      Name : constant String := Get (Event, "event");
   begin
      if Name = "frame" then
         Scope_View.Live_Frame (Integer'(Get (Event, "ch")), Event, Payload);
      elsif Name = "measure" then
         Show_Measurements (Event);
         if Recording then
            Record_Row (Event);
         end if;
      elsif Name = "math" then
         Scope_View.Math_Frame (Event, Payload);
      elsif Name = "spectrum" then
         declare
            Source : constant String := Get (Event, "source");
         begin
            if (Source = "scope" and then FFT_Mode = 1)
              or else (Source = "server" and then FFT_Mode = 2)
            then
               Spectrum_View.Show
                 (Gui_Client.Floats (Payload),
                  Long_Float (Number (Event, "f0")),
                  Long_Float (Number (Event, "df")),
                  Long_Float (Number (Event, "bin_width")),
                  Get (Event, "unit"),
                  Get (Event, "window"),
                  Spectrum_Label (Source, Get (Event, "ch"), Get (Event, "window")));
            end if;
         end;
      elsif Name = "progress" then
         declare
            Done  : constant Float := Number (Event, "done");
            Total : constant Float := Number (Event, "total");
         begin
            Progress.Set_Show_Text (True);
            Progress.Set_Fraction (Gdouble (Done / Float'Max (1.0, Total)));
            Progress.Set_Text
              ("Reading memory: " & Eng (Done, "") & "of " &
               Eng (Total, "") & "points");
         end;
      elsif Name = "refs" then
         Refresh_Refs;
      elsif Name = "error" then
         On_Error (Get (Event, "error"));
      elsif Name = "hello" then
         Say ("Connected to " & Get (Event, "source") & ": " &
              (if Kind (Get (Event, "idn")) = JSON_String_Type
               then Get (Event, "idn") else "no reply from the scope"));
      end if;
   end On_Event;

   function Poll return Boolean is
   begin
      Gui_Client.Poll;
      return True;
   end Poll;

   function Periodic_Status return Boolean is
   begin
      if Scope_View.Mode = Live and then Capturing = 0 then
         Refresh_Status;
      end if;
      return True;
   end Periodic_Status;

   -- -------------------------------------------------------------------------
   --  Control handlers
   -- -------------------------------------------------------------------------

   function Ch_On_Widget (Ch : Channel) return Gtk_Widget is
     (Gtk_Widget (Ch_On (Ch)));
   function Ch_Scale_Widget (Ch : Channel) return Gtk_Widget is
     (Gtk_Widget (Ch_Scale (Ch)));
   function Ch_Position_Widget (Ch : Channel) return Gtk_Widget is
     (Gtk_Widget (Ch_Position (Ch)));
   function Ch_Coupling_Widget (Ch : Channel) return Gtk_Widget is
     (Gtk_Widget (Ch_Coupling (Ch)));
   function Ch_Probe_Widget (Ch : Channel) return Gtk_Widget is
     (Gtk_Widget (Ch_Probe (Ch)));

   procedure On_Ch_On (Self : access Gtk_Toggle_Button_Record'Class) is
      Ch : constant Channel := Which (Self, Ch_On_Widget'Access);
   begin
      Set ("set_channel", With_Field (Ch_Members (Ch), "display",
                                      Create (Boolean'(Self.Get_Active))));
   end On_Ch_On;

   procedure On_Ch_Scale (Self : access Gtk_Combo_Box_Record'Class) is
      Ch : constant Channel := Which (Self, Ch_Scale_Widget'Access);
      I  : constant Gint := Self.Get_Active;
   begin
      if I >= 0 then
         Set ("set_channel", With_Field
                (Ch_Members (Ch), "scale",
                 Server.Wire.To_JSON (Scale_Values (Scale_Values'First + Integer (I)))));
      end if;
   end On_Ch_Scale;

   procedure On_Ch_Position (Self : access Gtk_Spin_Button_Record'Class) is
      Ch : constant Channel := Which (Self, Ch_Position_Widget'Access);
   begin
      Set ("set_channel", With_Field
             (Ch_Members (Ch), "offset",
              Server.Wire.To_JSON (Float (Self.Get_Value) * Scale_Now (Ch))));
   end On_Ch_Position;

   procedure On_Ch_Coupling (Self : access Gtk_Combo_Box_Record'Class) is
      Ch : constant Channel := Which (Self, Ch_Coupling_Widget'Access);
      I  : constant Gint := Self.Get_Active;
   begin
      if I >= 0 then
         Set ("set_channel", With_Field
                (Ch_Members (Ch), "coupling",
                 Create (To_String (Couplings (Integer (I))))));
      end if;
   end On_Ch_Coupling;

   procedure On_Ch_Probe (Self : access Gtk_Combo_Box_Record'Class) is
      Ch : constant Channel := Which (Self, Ch_Probe_Widget'Access);
      I  : constant Gint := Self.Get_Active;
   begin
      if I >= 0 then
         Set ("set_channel", With_Field
                (Ch_Members (Ch), "probe",
                 Server.Wire.To_JSON (Probe_Values (Integer (I) + 1))));
      end if;
   end On_Ch_Probe;

   procedure On_TB_Scale (Self : access Gtk_Combo_Box_Record'Class) is
      I : constant Gint := Self.Get_Active;
   begin
      if I >= 0 then
         Set ("set_timebase", With_Field
                (Members, "scale",
                 Server.Wire.To_JSON (Time_Values (Time_Values'First + Integer (I)))));
      end if;
   end On_TB_Scale;

   procedure On_TB_Position (Self : access Gtk_Spin_Button_Record'Class) is
   begin
      Set ("set_timebase", With_Field
             (Members, "offset",
              Server.Wire.To_JSON (Float (Self.Get_Value) * TB_Scale_Now)));
   end On_TB_Position;

   procedure On_Trigger_Choice (Self : access Gtk_Combo_Box_Record'Class) is
      I : constant Integer := Integer (Self.Get_Active);
   begin
      if I < 0 then
         return;
      elsif Gtk_Widget (Self) = Gtk_Widget (Trig_Source) then
         Set ("set_trigger", With_Field (Members, "source",
                                         Create (To_String (Sources (I)))));
      elsif Gtk_Widget (Self) = Gtk_Widget (Trig_Slope) then
         Set ("set_trigger", With_Field (Members, "slope",
                                         Create (To_String (Slopes (I)))));
      else
         Set ("set_trigger", With_Field (Members, "sweep",
                                         Create (To_String (Sweeps (I)))));
      end if;
   end On_Trigger_Choice;

   procedure On_Trigger_Level (Self : access Gtk_Spin_Button_Record'Class) is
   begin
      Set ("set_trigger", With_Field
             (Members, "level", Server.Wire.To_JSON (Float (Self.Get_Value))));
   end On_Trigger_Level;

   procedure On_Trigger_Mode (Self : access Gtk_Combo_Box_Record'Class) is
      I : constant Integer := Integer (Self.Get_Active);
   begin
      Show_Trigger_Mode;
      if I >= 0 then
         Set ("set_trigger", With_Field (Members, "mode",
                                         Create (To_String (Modes (I)))));
      end if;
   end On_Trigger_Mode;

   --  One member of the pulse (Group = "pulse") or slope ("slope_trigger")
   --  settings
   procedure Set_Detail (Group, Name : String; Value : JSON_Value) is
   begin
      Set ("set_trigger", With_Field (Members, Group,
                                      With_Field (Members, Name, Value)));
   end Set_Detail;

   function Time_Of (Combo : Gtk_Combo_Box_Text) return JSON_Value is
     (Server.Wire.To_JSON
        (Trigger_Times (Trigger_Times'First + Integer (Combo.Get_Active))));

   procedure On_Pulse_Choice (Self : access Gtk_Combo_Box_Record'Class) is
      I : constant Integer := Integer (Self.Get_Active);
      W : constant Gtk_Widget := Gtk_Widget (Self);
   begin
      if I < 0 then
         return;
      elsif W = Gtk_Widget (P_Source) then
         Set_Detail ("pulse", "source", Create (To_String (Channels2 (I))));
      elsif W = Gtk_Widget (P_When) then
         Set_Detail ("pulse", "when", Create (To_String (Whens (I))));
      elsif W = Gtk_Widget (P_Width) then
         Set_Detail ("pulse", "width", Time_Of (P_Width));
      elsif W = Gtk_Widget (P_Lower) then
         Set_Detail ("pulse", "lower", Time_Of (P_Lower));
      else
         Set_Detail ("pulse", "upper", Time_Of (P_Upper));
      end if;
   end On_Pulse_Choice;

   procedure On_Pulse_Level (Self : access Gtk_Spin_Button_Record'Class) is
   begin
      Set_Detail ("pulse", "level", Server.Wire.To_JSON (Float (Self.Get_Value)));
   end On_Pulse_Level;

   procedure On_Slope_Choice (Self : access Gtk_Combo_Box_Record'Class) is
      I : constant Integer := Integer (Self.Get_Active);
      W : constant Gtk_Widget := Gtk_Widget (Self);
   begin
      if I < 0 then
         return;
      elsif W = Gtk_Widget (S_Source) then
         Set_Detail ("slope_trigger", "source", Create (To_String (Channels2 (I))));
      elsif W = Gtk_Widget (S_When) then
         Set_Detail ("slope_trigger", "when", Create (To_String (Whens (I))));
      elsif W = Gtk_Widget (S_Time) then
         Set_Detail ("slope_trigger", "time", Time_Of (S_Time));
      elsif W = Gtk_Widget (S_Lower) then
         Set_Detail ("slope_trigger", "lower", Time_Of (S_Lower));
      elsif W = Gtk_Widget (S_Upper) then
         Set_Detail ("slope_trigger", "upper", Time_Of (S_Upper));
      else
         Set_Detail ("slope_trigger", "window", Create (To_String (Slope_Windows (I))));
      end if;
   end On_Slope_Choice;

   procedure On_Slope_Level (Self : access Gtk_Spin_Button_Record'Class) is
   begin
      Set_Detail ("slope_trigger",
                  (if Gtk_Widget (Self) = Gtk_Widget (S_Level_A) then "level_a"
                   else "level_b"),
                  Server.Wire.To_JSON (Float (Self.Get_Value)));
   end On_Slope_Level;

   -- -------------------------------------------------------------------------
   --  Setups: the scope's complete setup, in a file on this computer
   -- -------------------------------------------------------------------------

   Setup_File : Unbounded_String;

   procedure On_Setup_Saved (Reply : JSON_Value; Payload : String) is
      pragma Unreferenced (Payload);
   begin
      if not Get (Reply, "ok") then
         On_Error (Get (Reply, "error"));
         return;
      end if;
      Write_File (To_String (Setup_File),
                  Server.Wire.From_Base64 (Get (Reply, "setup")));
      Say ("Setup saved to " & To_String (Setup_File));
   exception
      when E : others =>
         On_Error ("cannot save the setup: " & Exception_Message (E));
   end On_Setup_Saved;

   procedure On_Save_Setup (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
      Name : constant String := Ask_File_Name ("Save setup", "scope.setup");
   begin
      if Name /= "" then
         Setup_File := To_Unbounded_String (Name);
         Gui_Client.Request ("save_setup", On_Reply => On_Setup_Saved'Access);
      end if;
   end On_Save_Setup;

   procedure On_Acquire_Choice (Self : access Gtk_Combo_Box_Record'Class) is
      M : constant JSON_Value := Members;
   begin
      if Updating then
         return;
      end if;
      if Gtk_Widget (Self) = Gtk_Widget (Acq_Type) then
         Set_Field (M, "type", To_String (Acq_Types (Integer (Acq_Type.Get_Active))));
         Acq_Averages.Set_Sensitive (Acq_Type.Get_Active = 1);
      elsif Gtk_Widget (Self) = Gtk_Widget (Acq_Averages) then
         Set_Field (M, "averages", Integer'(2 ** (Integer (Acq_Averages.Get_Active) + 1)));
      else
         Set_Field (M, "memory_depth",
                    Integer'(if Acq_Depth.Get_Active <= 0 then 0
                             else Depths (Depth_Dual) (Integer (Acq_Depth.Get_Active))));
      end if;
      Set ("set_acquire", M);
   end On_Acquire_Choice;

   --  A setup is restored in full, bar settings the scope refused
   procedure On_Setup_Loaded (Reply : JSON_Value; Payload : String) is
      pragma Unreferenced (Payload);
   begin
      if not Get (Reply, "ok") then
         On_Error (Get (Reply, "error"));
      elsif Has_Field (Reply, "warnings") then
         declare
            Warnings : constant JSON_Array := Get (Reply, "warnings");
         begin
            On_Error ("setup loaded, but not all of it: " &
                      String'(Get (Get (Warnings, 1))));
         end;
      else
         Say ("Setup loaded");
      end if;
      Refresh_Status;
   end On_Setup_Loaded;

   procedure On_Load_Setup (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
      Name : constant String := Ask_Open_File ("Load setup");
   begin
      if Name = "" then
         return;
      end if;
      declare
         use Ada.Streams.Stream_IO;
         F    : File_Type;
         Data : String (1 .. Natural (Ada.Directories.Size (Name)));
      begin
         Open (F, In_File, Name);
         String'Read (Stream (F), Data);
         Close (F);
         Gui_Client.Request
           ("load_setup",
            With_Field (Members, "setup", Create (Server.Wire.To_Base64 (Data))),
            On_Setup_Loaded'Access);
         Say ("Loading the setup from " & Name & " ...");
      end;
   exception
      when E : others =>
         On_Error ("cannot load " & Name & ": " & Exception_Message (E));
   end On_Load_Setup;

   --  The measured channel or a slot changed
   procedure On_Meas_Choice (Self : access Gtk_Combo_Box_Record'Class) is
      pragma Unreferenced (Self);
   begin
      for Slot in 1 .. Slots loop
         Slot_Value (Slot).Set_Text (if Slot_Index (Slot) > 0 then "-" else "");
      end loop;
      if Scope_View.Mode = Live then
         Start_Live;
      end if;
   end On_Meas_Choice;

   procedure On_Cursors (Self : access Gtk_Toggle_Button_Record'Class) is
   begin
      Scope_View.Set_Cursors (Self.Get_Active);
   end On_Cursors;

   procedure On_Math_Choice (Self : access Gtk_Combo_Box_Record'Class) is
      Mode_Changed : constant Boolean := Gtk_Widget (Self) = Gtk_Widget (Math_Mode_Box);
   begin
      if Updating then
         return;
      end if;
      Updating := True;
      if Current_Math = Scope_View.Scope and then FFT_Mode = 1 then
         FFT_Mode_Box.Set_Active (0);
         Spectrum_Area.Hide;
         Say ("The scope has one math channel; its FFT is now off");
      end if;
      if Current_Math = Scope_View.PC and then Current_Op = "div" then
         Math_Op_Box.Set_Active (0);
         Say ("A/B is only available on the scope");
      end if;
      if Mode_Changed and then Current_Math = Scope_View.PC then
         --  A sensible start: CH1's scale
         Math_Scale_Box.Set_Active
           (Gint (Nearest (Math_Scale_Values, Scale_Now (1)) - Math_Scale_Values'First));
         Math_Position.Set_Value (0.0);
      end if;
      Updating := False;

      Configure_Scope_Math;
      Apply_Math_View;
      if Scope_View.Mode = Live then
         Start_Live;
      end if;
   end On_Math_Choice;

   procedure On_Math_Scale (Self : access Gtk_Widget_Record'Class) is
      pragma Unreferenced (Self);
      M : constant JSON_Value := Members;
   begin
      if Updating then
         return;
      end if;
      if Current_Math = Scope_View.Scope then
         Set_Field (M, "scale", Server.Wire.To_JSON (Math_Scale));
         Set_Field (M, "offset",
                    Server.Wire.To_JSON (Float (Math_Position.Get_Value) * Math_Scale));
         Set ("set_math", M);
      end if;
      Apply_Math_View;
   end On_Math_Scale;

   procedure On_Math_Scale_Combo (Self : access Gtk_Combo_Box_Record'Class) is
   begin
      On_Math_Scale (Self);
   end On_Math_Scale_Combo;

   procedure On_Math_Position (Self : access Gtk_Spin_Button_Record'Class) is
   begin
      On_Math_Scale (Self);
   end On_Math_Position;

   procedure On_FFT_Choice (Self : access Gtk_Combo_Box_Record'Class) is
      pragma Unreferenced (Self);
   begin
      if Updating then
         return;
      end if;
      Updating := True;
      if FFT_Mode = 1 and then Current_Math = Scope_View.Scope then
         Math_Mode_Box.Set_Active (0);
         Say ("The scope has one math channel; its math is now off");
      end if;
      Updating := False;
      Apply_Math_View;

      Spectrum_View.Clear;
      if FFT_Mode = 0 then
         Spectrum_Area.Hide;
      else
         Spectrum_Area.Show;
      end if;
      Configure_Scope_Math;
      if Scope_View.Mode = Live then
         Start_Live;
      else
         Request_Capture_Spectrum;
      end if;
   end On_FFT_Choice;

   --  While recording, the columns must not change
   procedure Lock_Measurement_Choice (Locked : Boolean) is
   begin
      Meas_Channel.Set_Sensitive (not Locked);
      for Slot in 1 .. Slots loop
         Slot_Item (Slot).Set_Sensitive (not Locked);
      end loop;
   end Lock_Measurement_Choice;

   procedure Stop_Recording is
   begin
      Recording := False;
      Ada.Text_IO.Close (Record_File);
      Lock_Measurement_Choice (False);
      Record_Button.Set_Label ("Record ...");
      Say ("Recorded" & Record_Rows'Image & " rows to " &
           To_String (Record_Name));
   end Stop_Recording;

   --  Append a header, then a row per measurement update, to File
   procedure Start_Recording (File : String) is
      use Ada.Text_IO;
   begin
      if Ada.Directories.Exists (File) then
         Open (Record_File, Append_File, File);
      else
         Create (Record_File, Out_File, File);
      end if;
      --  A header per recording, so appended recordings stay readable
      Put (Record_File, "time,elapsed_s,ch");
      for Slot in 1 .. Slots loop
         if Slot_Index (Slot) > 0 then
            declare
               Info : Item_Info renames Items (Slot_Index (Slot));
            begin
               Put (Record_File, "," & To_String (Info.Name) & "_" &
                      (if Info.Unit = "%" then "fraction"
                       else To_String (Info.Unit)));
            end;
         end if;
      end loop;
      New_Line (Record_File);
      Record_Name  := To_Unbounded_String (File);
      Record_Start := Ada.Calendar.Clock;
      Record_Rows  := 0;
      Recording    := True;
      Lock_Measurement_Choice (True);
      Record_Button.Set_Label ("Stop recording");
      Say ("Recording to " & File);
   exception
      when E : others =>
         On_Error ("cannot record to " & File & ": " & Exception_Message (E));
   end Start_Recording;

   procedure On_Record (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      if Recording then
         Stop_Recording;
      elsif Measured_Channel = 0 then
         On_Error ("choose a channel to measure first");
      else
         declare
            Name : constant String :=
              Ask_File_Name ("Record measurements", "measurements.csv");
         begin
            if Name /= "" then
               Start_Recording (Name);
            end if;
         end;
      end if;
   end On_Record;

   procedure On_FFT_Log (Self : access Gtk_Toggle_Button_Record'Class) is
   begin
      Spectrum_View.Set_Log_Axis (Self.Get_Active);
   end On_FFT_Log;

   procedure On_Acquisition (Self : access Gtk_Button_Record'Class) is
      Label : constant String := Self.Get_Label;
      Cmd   : constant String :=
        (if Label = "Run" then "run" elsif Label = "Stop" then "stop"
         elsif Label = "Single" then "single" elsif Label = "Auto" then "auto"
         else "force");
   begin
      Gui_Client.Request (Cmd, On_Reply => On_Set'Access);
   end On_Acquisition;


   -- -------------------------------------------------------------------------
   --  Display mode, pass/fail and references
   -- -------------------------------------------------------------------------

   procedure On_Display_Mode (Self : access Gtk_Combo_Box_Record'Class) is
   begin
      Scope_View.Set_XY (Self.Get_Active = 1);
      if Self.Get_Active = 1 and then not (Ch_On (1).Get_Active and then Ch_On (2).Get_Active)
      then
         Say ("XY plots CH1 against CH2: switch both channels on");
      end if;
   end On_Display_Mode;

   function Mask_Settings return JSON_Value is
      M : constant JSON_Value := Members;
   begin
      Set_Field (M, "enable", True);
      Set_Field (M, "source", (if Mask_Source.Get_Active = 1 then "ch2" else "ch1"));
      Set_Field (M, "x", Server.Wire.To_JSON (Float (Mask_X.Get_Value)));
      Set_Field (M, "y", Server.Wire.To_JSON (Float (Mask_Y.Get_Value)));
      Set_Field (M, "stop_on_fail", Mask_Stop.Get_Active);
      Set_Field (M, "show_stats", True);
      return M;
   end Mask_Settings;

   procedure On_Mask_Button (Self : access Gtk_Button_Record'Class) is
      Label : constant String := Self.Get_Label;
      M     : JSON_Value;
   begin
      if Label = "Create mask" then
         M := Mask_Settings;
         Set_Field (M, "create", True);
         Set_Field (M, "reset", True);
         Gui_Client.Request ("set_mask", M, On_Set'Access);
         Say ("A mask around " & (if Mask_Source.Get_Active = 1 then "CH2" else "CH1") &
              "'s waveform now; Start runs the test");
      elsif Label = "Start" then
         M := Mask_Settings;
         Set_Field (M, "run", True);
         Gui_Client.Request ("set_mask", M, On_Set'Access);
         Gui_Client.Request ("run", On_Reply => On_Set'Access);
      elsif Label = "Stop" then
         Gui_Client.Request ("set_mask", With_Field (Members, "run", Create (False)),
                             On_Set'Access);
      elsif Label = "Reset" then
         Gui_Client.Request ("set_mask", With_Field (Members, "reset", Create (True)),
                             On_Set'Access);
      else   --  Off
         Gui_Client.Request ("set_mask", With_Field (Members, "enable", Create (False)),
                             On_Set'Access);
      end if;
   end On_Mask_Button;

   --  References are kept by the server; every client is told when they
   --  change ("refs" event), and fetches them again

   procedure On_Ref_Data (Reply : JSON_Value; Payload : String) is
   begin
      if Get (Reply, "ok") then
         Scope_View.Set_Reference (Get (Reply, "slot"), Reply, Payload);
      end if;
   end On_Ref_Data;

   procedure On_Refs (Reply : JSON_Value; Payload : String) is
      pragma Unreferenced (Payload);
      Text : Unbounded_String;
   begin
      if not Get (Reply, "ok") then
         return;
      end if;
      Scope_View.Clear_References;
      declare
         List : constant JSON_Array := Get (Reply, "refs");
      begin
         for K in 1 .. Length (List) loop
            declare
               R    : constant JSON_Value := Get (List, K);
               Slot : constant Integer := Get (R, "slot");
            begin
               Append (Text, (if K > 1 then "" & ASCII.LF else "") &
                       "R" & Character'Val (48 + Slot) & "  " & String'(Get (R, "label")));
               Gui_Client.Request ("ref", With_Field (Members, "slot", Create (Slot)),
                                   On_Ref_Data'Access);
            end;
         end loop;
      end;
      Ref_List.Set_Text (if Length (Text) = 0 then "none" else To_String (Text));
   end On_Refs;

   procedure Refresh_Refs is
   begin
      Gui_Client.Request ("refs", On_Reply => On_Refs'Access);
   end Refresh_Refs;

   function Ref_Slot return Integer is (Integer (Ref_Slot_Box.Get_Active) + 1);

   Ref_File : Unbounded_String;

   procedure On_Ref_Export_Data (Reply : JSON_Value; Payload : String) is
      use Ada.Text_IO;
      F : File_Type;
   begin
      if not Get (Reply, "ok") then
         On_Error (Get (Reply, "error"));
         return;
      end if;
      Create (F, Out_File, To_String (Ref_File));
      Put_Line (F, "time_s,volts");
      for I in Payload'Range loop
         Put_Line (F, Image (Long_Float (Number (Reply, "x_origin")) +
                               Long_Float (I - Payload'First) *
                               Long_Float (Number (Reply, "x_inc"))) & "," &
                     Image ((Float (Character'Pos (Payload (I))) - Number (Reply, "y_ref")
                             - Number (Reply, "y_origin")) * Number (Reply, "y_inc")));
      end loop;
      Close (F);
      Say ("Saved R" & Character'Val (48 + Integer'(Get (Reply, "slot"))) & " to " &
           To_String (Ref_File));
   exception
      when E : others =>
         On_Error ("cannot write " & To_String (Ref_File) & ": " & Exception_Message (E));
   end On_Ref_Export_Data;

   --  A CSV of time, volts (a header line is skipped) as reference Slot:
   --  8-bit samples spanning the volts' range, as the scope's are
   package Float_Vectors is new Ada.Containers.Vectors (Positive, Float);

   procedure Import_Reference (Slot : Integer; Name : String) is
      use Ada.Text_IO;
      F     : File_Type;
      Times, Volts : Float_Vectors.Vector;
      N     : Natural := 0;
   begin
      Open (F, In_File, Name);
      while not End_Of_File (F) and then N < 1_000_000 loop
         declare
            L     : constant String := Get_Line (F);
            Comma : constant Natural := Index (L, ",");
         begin
            if Comma > 0 then
               declare
                  T : constant Float := Float'Value (L (L'First .. Comma - 1));
                  V : constant Float := Float'Value (L (Comma + 1 .. L'Last));
               begin
                  Times.Append (T);
                  Volts.Append (V);
                  N := N + 1;
               end;
            end if;
         exception
            when Constraint_Error => null;   --  the header
         end;
      end loop;
      Close (F);
      if N < 2 then
         On_Error ("no time,volts lines in " & Name);
         return;
      end if;
      declare
         Lo    : Float := Volts (1);
         Hi    : Float := Volts (1);
         Raw   : String (1 .. N);
         M     : constant JSON_Value := Members;
      begin
         for K in 1 .. N loop
            Lo := Float'Min (Lo, Volts (K));
            Hi := Float'Max (Hi, Volts (K));
         end loop;
         declare
            Y_Inc : constant Float := Float'Max (1.0E-6, (Hi - Lo) / 200.0);
         begin
            for K in 1 .. N loop
               Raw (K) := Character'Val (Integer'Max (0, Integer'Min
                 (255, Integer (27.0 + (Volts (K) - Lo) / Y_Inc))));
            end loop;
            Set_Field (M, "slot", Slot);
            Set_Field (M, "data", Server.Wire.To_Base64 (Raw));
            Set_Field (M, "x_inc", Server.Wire.To_JSON ((Times (N) - Times (1)) / Float (N - 1)));
            Set_Field (M, "x_origin", Server.Wire.To_JSON (Times (1)));
            Set_Field (M, "y_inc", Server.Wire.To_JSON (Y_Inc));
            Set_Field (M, "y_origin", Server.Wire.To_JSON (-100.0 - Lo / Y_Inc));
            Set_Field (M, "y_ref", Server.Wire.To_JSON (127.0));
            Set_Field (M, "ch", Integer (Ref_Source.Get_Active) + 1);
            Set_Field (M, "label", Ada.Directories.Simple_Name (Name));
            Gui_Client.Request ("ref_load", M, On_Set'Access);
         end;
      end;
   exception
      when E : others =>
         On_Error ("cannot read " & Name & ": " & Exception_Message (E));
   end Import_Reference;

   procedure On_Ref_Button (Self : access Gtk_Button_Record'Class) is
      Label : constant String := Self.Get_Label;
      M     : constant JSON_Value := With_Field (Members, "slot", Create (Ref_Slot));
   begin
      if Label = "Save" then
         Set_Field (M, "ch", Integer (Ref_Source.Get_Active) + 1);
         Gui_Client.Request ("ref_save", M, On_Set'Access);
      elsif Label = "Clear" then
         Gui_Client.Request ("ref_clear", M, On_Set'Access);
      elsif Label = "Export ..." then
         declare
            Name : constant String := Ask_File_Name
              ("Export reference", "reference" & Character'Val (48 + Ref_Slot) & ".csv");
         begin
            if Name /= "" then
               Ref_File := To_Unbounded_String (Name);
               Gui_Client.Request ("ref", M, On_Ref_Export_Data'Access);
            end if;
         end;
      else   --  Import
         declare
            Name : constant String := Ask_Open_File ("Import a reference (CSV: time, volts)");
         begin
            if Name /= "" then
               Import_Reference (Ref_Slot, Name);
            end if;
         end;
      end if;
   end On_Ref_Button;

   procedure On_Show_Refs (Self : access Gtk_Toggle_Button_Record'Class) is
   begin
      Scope_View.Show_References (Self.Get_Active);
   end On_Show_Refs;

   procedure Say_Text (Text : String) is
   begin
      Say (Text);
   end Say_Text;

   procedure Error_Text (Text : String) is
   begin
      On_Error (Text);
   end Error_Text;

   -- -------------------------------------------------------------------------
   --  Capture
   -- -------------------------------------------------------------------------

   procedure On_Captured (Ch : Channel; Reply : JSON_Value) is
   begin
      Capturing := Capturing - 1;
      if Get (Reply, "ok") then
         Scope_View.Captured (Ch, Reply);
      else
         On_Error (Get (Reply, "error"));
      end if;
      if Capturing = 0 then
         Progress.Set_Fraction (0.0);
         Progress.Set_Show_Text (False);
         if Scope_View.Is_Captured (1) or else Scope_View.Is_Captured (2) then
            Scope_View.Set_Mode (Capture);
            Say ("Captured; the scope is stopped.  Live returns to live view.");
            Request_Capture_Spectrum;
            Decode_Panel.Captured;
            Timing_Panel.Captured;
         end if;
         Refresh_Status;
      end if;
   end On_Captured;

   procedure On_Captured_1 (Reply : JSON_Value; Payload : String) is
      pragma Unreferenced (Payload);
   begin
      On_Captured (1, Reply);
   end On_Captured_1;

   procedure On_Captured_2 (Reply : JSON_Value; Payload : String) is
      pragma Unreferenced (Payload);
   begin
      On_Captured (2, Reply);
   end On_Captured_2;

   procedure On_Capture (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      if Capturing > 0 then
         return;
      end if;
      Scope_View.Clear_Captures;
      for Ch in Channel loop
         if Ch_On (Ch).Get_Active then
            Capturing := Capturing + 1;
            Gui_Client.Request
              ("capture", Ch_Members (Ch),
               (if Ch = 1 then On_Captured_1'Access else On_Captured_2'Access));
         end if;
      end loop;
      if Capturing = 0 then
         On_Error ("no channel is on");
      else
         Say ("Capturing the acquisition memory ...");
      end if;
   end On_Capture;

   procedure On_Live (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Scope_View.Set_Mode (Live);
      Gui_Client.Request ("run", On_Reply => On_Set'Access);
      Start_Live;
      Say ("Live");
   end On_Live;

   -- -------------------------------------------------------------------------
   --  Screenshot and export
   -- -------------------------------------------------------------------------

   Screenshot_File : Unbounded_String;


   procedure On_Screenshot_Data (Reply : JSON_Value; Payload : String) is
   begin
      if Get (Reply, "ok") then
         Write_File (To_String (Screenshot_File), Payload);
         Say ("Saved " & To_String (Screenshot_File));
      else
         On_Error (Get (Reply, "error"));
      end if;
   exception
      when E : others =>
         On_Error ("cannot write " & To_String (Screenshot_File) & ": " &
                   Exception_Message (E));
   end On_Screenshot_Data;

   procedure On_Screenshot (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
      Name : constant String := Ask_File_Name ("Save screenshot", "screen.bmp");
   begin
      if Name /= "" then
         Screenshot_File := To_Unbounded_String (Name);
         Gui_Client.Request ("screenshot", On_Reply => On_Screenshot_Data'Access);
      end if;
   end On_Screenshot;

   --  Capture export: samples are fetched in chunks, channel by channel,
   --  then written as time, CH1, CH2 columns
   Export_File  : Unbounded_String;
   Export_First : Natural := 0;
   Export_Last  : Natural := 0;
   Export_Ch    : Natural := 0;       --  channel being fetched
   Export_Next  : Natural := 0;       --  next sample to fetch
   Export_Data  : array (Channel) of Unbounded_String;

   Chunk : constant := 1_000_000;

   procedure Fetch_Export_Chunk;

   procedure Write_Capture_CSV is
      use Ada.Text_IO;
      F     : File_Type;
      Shown : array (Channel) of Boolean;
      Info  : array (Channel) of JSON_Value;
      Any   : Channel := 1;
   begin
      for Ch in Channel loop
         Shown (Ch) := Length (Export_Data (Ch)) > 0;
         Info (Ch)  := Scope_View.Capture_Info (Ch);
         if Shown (Ch) then
            Any := Ch;
         end if;
      end loop;
      Create (F, Out_File, To_String (Export_File));
      Put (F, "time_s");
      for Ch in Channel loop
         if Shown (Ch) then
            Put (F, ",ch" & Character'Val (48 + Ch) & "_V");
         end if;
      end loop;
      New_Line (F);
      declare
         X_Inc    : constant Long_Float :=
           Long_Float (Number (Info (Any), "x_inc"));
         X_Origin : constant Long_Float :=
           Long_Float (Number (Info (Any), "x_origin"));
      begin
         for I in 1 .. Export_Last - Export_First + 1 loop
            Put (F, Image (X_Origin + Long_Float (Export_First + I - 1) * X_Inc));
            for Ch in Channel loop
               if Shown (Ch) then
                  Put (F, "," & Image
                    ((Float (Character'Pos (Element (Export_Data (Ch), I)))
                      - Number (Info (Ch), "y_ref")
                      - Number (Info (Ch), "y_origin"))
                     * Number (Info (Ch), "y_inc")));
               end if;
            end loop;
            New_Line (F);
         end loop;
      end;
      Close (F);
      Say ("Exported" & Natural'Image (Export_Last - Export_First + 1) &
           " samples to " & To_String (Export_File));
   exception
      when E : others =>
         On_Error ("cannot write " & To_String (Export_File) & ": " &
                   Exception_Message (E));
   end Write_Capture_CSV;

   procedure On_Export_Chunk (Reply : JSON_Value; Payload : String) is
   begin
      if not Get (Reply, "ok") then
         On_Error (Get (Reply, "error"));
         Export_Ch := 0;
         return;
      end if;
      Append (Export_Data (Export_Ch), Payload);
      Export_Next := Export_Next + Payload'Length;
      Fetch_Export_Chunk;
   end On_Export_Chunk;

   --  Request the next chunk, or write the file when all are in
   procedure Fetch_Export_Chunk is
   begin
      while Export_Ch <= 2
        and then (not Scope_View.Is_Captured (Export_Ch)
                  or else Export_Next > Export_Last)
      loop
         Export_Ch   := Export_Ch + 1;
         Export_Next := Export_First;
      end loop;
      if Export_Ch > 2 then
         Export_Ch := 0;
         Write_Capture_CSV;
         return;
      end if;
      declare
         M : constant JSON_Value := Ch_Members (Export_Ch);
      begin
         Set_Field (M, "first", Export_Next);
         Set_Field (M, "last", Natural'Min (Export_Last, Export_Next + Chunk - 1));
         Gui_Client.Request ("samples", M, On_Export_Chunk'Access);
         Say ("Exporting CH" & Character'Val (48 + Export_Ch) & " ...");
      end;
   end Fetch_Export_Chunk;

   procedure Write_Live_CSV (Name : String) is
      use Ada.Text_IO;
      F      : File_Type;
      P1     : constant Point_Array := Scope_View.Live_Points (1);
      P2     : constant Point_Array := Scope_View.Live_Points (2);
      Has    : constant array (Channel) of Boolean :=
        (Ch_On (1).Get_Active and then P1'Length > 0,
         Ch_On (2).Get_Active and then P2'Length > 0);
      N      : constant Natural :=
        (if Has (1) then P1'Length else P2'Length);
   begin
      if not (Has (1) or else Has (2)) then
         On_Error ("no live data to export");
         return;
      end if;
      Create (F, Out_File, Name);
      Put (F, "time_s");
      for Ch in Channel loop
         if Has (Ch) then
            Put (F, ",ch" & Character'Val (48 + Ch) & "_V");
         end if;
      end loop;
      New_Line (F);
      for I in 1 .. N loop
         Put (F, Image (if Has (1) then P1 (I).Time else P2 (I).Time));
         if Has (1) then
            Put (F, "," & Image (P1 (I).Volts));
         end if;
         if Has (2) and then I <= P2'Length then
            Put (F, "," & Image (P2 (I).Volts));
         end if;
         New_Line (F);
      end loop;
      Close (F);
      Say ("Exported the live screen to " & Name);
   exception
      when E : others =>
         On_Error ("cannot write " & Name & ": " & Exception_Message (E));
   end Write_Live_CSV;

   procedure On_Export (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      if Scope_View.Mode = Live then
         declare
            Name : constant String := Ask_File_Name ("Export screen", "screen.csv");
         begin
            if Name /= "" then
               Write_Live_CSV (Name);
            end if;
         end;
         return;
      end if;

      if Export_Ch /= 0 then
         return;   --  an export is running
      end if;
      Scope_View.View_Range (Export_First, Export_Last);
      if Export_Last - Export_First + 1 > Max_Export then
         On_Error ("the view holds" & Natural'Image (Export_Last - Export_First + 1)
                   & " samples; zoom in to at most" & Natural'Image (Max_Export)
                   & " to export");
         return;
      end if;
      declare
         Name : constant String := Ask_File_Name ("Export capture", "capture.csv");
      begin
         if Name /= "" then
            Export_File := To_Unbounded_String (Name);
            Export_Data := (others => Null_Unbounded_String);
            Export_Ch   := 1;
            Export_Next := Export_First;
            Fetch_Export_Chunk;
         end if;
      end;
   end On_Export;

   -- -------------------------------------------------------------------------
   --  Layout
   -- -------------------------------------------------------------------------





   function Scale_Items (Values : Float_Array; Unit : String) return String is
      Result : Unbounded_String;
   begin
      for V of Values loop
         if Length (Result) > 0 then
            Append (Result, "|");
         end if;
         Append (Result, Eng (V, Unit) & "/div");
      end loop;
      return To_String (Result);
   end Scale_Items;

   procedure On_Destroy (Self : access Gtk_Widget_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Gtk.Main.Main_Quit;
   end On_Destroy;

   procedure On_About (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      About_Box.Show (Win);
   end On_About;

   procedure Create is
      Top    : Gtk_Hbox;
      Panel  : Gtk_Vbox;
      Scroll : Gtk_Scrolled_Window;
      Dummy  : Glib.Main.G_Source_Id;
   begin
      Gtk_New (Win);
      Win.Set_Title ("ScopeBridge");
      Win.Set_Default_Size (1280, 760);
      Win.On_Destroy (On_Destroy'Access);
      Widgets.Set_Parent (Win);

      Gtk_New_Hbox (Top, Spacing => 6);
      Win.Add (Top);

      declare
         Left : Gtk_Vbox;
      begin
         Gtk_New_Vbox (Left, Spacing => 4);
         Left.Pack_Start (Scope_View.Create, Expand => True, Fill => True);
         Spectrum_Area := Gtk_Widget (Spectrum_View.Create);
         Left.Pack_Start (Spectrum_Area, Expand => False, Fill => True);
         Left.Pack_Start (Decode_Panel.Create_Results, Expand => False, Fill => True);
         Left.Pack_Start (Timing_Panel.Create_Results, Expand => False, Fill => True);
         Status_Line := New_Label ("Connecting ...");
         Status_Line.Set_Margin_Start (8);
         Left.Pack_Start (Status_Line, Expand => False, Fill => False, Padding => 2);
         Top.Pack_Start (Left, Expand => True, Fill => True);
      end;

      Gtk_New (Scroll);
      Scroll.Set_Policy (Policy_Never, Policy_Automatic);
      Scroll.Set_Size_Request (340, -1);
      Top.Pack_Start (Scroll, Expand => False, Fill => True);
      Gtk_New_Vbox (Panel, Spacing => 6);
      Panel.Set_Border_Width (6);
      Scroll.Add (Panel);

      --  Acquisition
      declare
         G : constant Gtk_Grid := Row_Grid;
      begin
         G.Attach (New_Button ("Run",    On_Acquisition'Access), 0, 0);
         G.Attach (New_Button ("Stop",   On_Acquisition'Access), 1, 0);
         G.Attach (New_Button ("Single", On_Acquisition'Access), 2, 0);
         G.Attach (New_Button ("Auto",   On_Acquisition'Access), 3, 0);
         G.Attach (New_Button ("Force",  On_Acquisition'Access), 4, 0);
         Acq_Type     := New_Combo ("Normal|Average|Peak detect|High res");
         Acq_Averages := New_Combo ("2|4|8|16|32|64|128|256|512|1024");
         Gtk_New (Acq_Depth);
         Fill_Depths;
         Acq_Rate := New_Label ("");
         Acq_Type.Set_Active (0);
         Acq_Averages.Set_Active (3);
         Acq_Depth.Set_Active (0);
         G.Attach (Acq_Type, 0, 1, 3);
         G.Attach (Acq_Averages, 3, 1, 2);
         G.Attach (New_Label ("Memory"), 0, 2);
         G.Attach (Acq_Depth, 1, 2, 2);
         G.Attach (Acq_Rate, 3, 2, 2);
         Acq_Type.On_Changed (On_Acquire_Choice'Access);
         Acq_Averages.On_Changed (On_Acquire_Choice'Access);
         Acq_Depth.On_Changed (On_Acquire_Choice'Access);
         Panel.Pack_Start (Framed ("Acquisition", G), Expand => False);
      end;

      --  Channels
      for Ch in Channel loop
         declare
            G : constant Gtk_Grid := Row_Grid;
         begin
            Gtk_New (Ch_On (Ch), "On");
            Ch_Scale (Ch)    := New_Combo (Scale_Items (Scale_Values, "V"));
            Ch_Position (Ch) := New_Spin (-50.0, 50.0, 0.1, 1);
            Ch_Coupling (Ch) := New_Combo ("DC|AC|GND");
            Ch_Probe (Ch)    := New_Combo
              ("0.01x|0.02x|0.05x|0.1x|0.2x|0.5x|1x|2x|5x|10x|20x|50x|100x|200x|500x|1000x");
            G.Attach (Ch_On (Ch), 0, 0);
            G.Attach (Ch_Scale (Ch), 1, 0);
            G.Attach (New_Label ("Position (div)"), 0, 1);
            G.Attach (Ch_Position (Ch), 1, 1);
            G.Attach (Ch_Coupling (Ch), 0, 2);
            G.Attach (Ch_Probe (Ch), 1, 2);
            Ch_On (Ch).On_Toggled (On_Ch_On'Access);
            Ch_Scale (Ch).On_Changed (On_Ch_Scale'Access);
            Ch_Position (Ch).On_Value_Changed (On_Ch_Position'Access);
            Ch_Coupling (Ch).On_Changed (On_Ch_Coupling'Access);
            Ch_Probe (Ch).On_Changed (On_Ch_Probe'Access);
            Panel.Pack_Start
              (Framed ("Channel" & Ch'Image, G), Expand => False);
         end;
      end loop;

      --  Timebase
      declare
         G : constant Gtk_Grid := Row_Grid;
      begin
         TB_Scale    := New_Combo (Scale_Items (Time_Values, "s"));
         TB_Position := New_Spin (-10_000.0, 10_000.0, 0.1, 1);
         G.Attach (TB_Scale, 0, 0, 2);
         G.Attach (New_Label ("Position (div)"), 0, 1);
         G.Attach (TB_Position, 1, 1);
         TB_Scale.On_Changed (On_TB_Scale'Access);
         TB_Position.On_Value_Changed (On_TB_Position'Access);
         Panel.Pack_Start (Framed ("Timebase", G), Expand => False);
      end;

      --  Trigger
      declare
         G : constant Gtk_Grid := Row_Grid;

         function Time_Combo return Gtk_Combo_Box_Text is
            C : Gtk_Combo_Box_Text;
         begin
            Gtk_New (C);
            for V of Trigger_Times loop
               C.Append_Text (Eng (V, "s"));
            end loop;
            return C;
         end Time_Combo;

         Condition_Labels : constant String :=
           "+ > width|+ < width|- > width|- < width|+ in range|- in range";
      begin
         Trig_Mode := New_Combo ("Edge|Pulse|Slope");
         Trig_Mode.Set_Active (0);
         G.Attach (New_Label ("Mode"), 0, 0);
         G.Attach (Trig_Mode, 1, 0);

         --  Edge
         Edge_Box    := Row_Grid;
         Edge_Box.Set_Row_Spacing (4);
         Edge_Box.Set_Column_Spacing (8);
         Trig_Source := New_Combo ("CH1|CH2|AC line|EXT");
         Trig_Slope  := New_Combo ("Rising|Falling|Either");
         Trig_Level  := New_Spin (-100.0, 100.0, 0.01, 2);
         Edge_Box.Attach (Trig_Source, 0, 0);
         Edge_Box.Attach (Trig_Slope, 1, 0);
         Edge_Box.Attach (New_Label ("Level (V)"), 0, 1);
         Edge_Box.Attach (Trig_Level, 1, 1);
         G.Attach (Edge_Box, 0, 1, 2);

         --  Pulse width
         Pulse_Box := Row_Grid;
         Pulse_Box.Set_Row_Spacing (4);
         Pulse_Box.Set_Column_Spacing (8);
         P_Source := New_Combo ("CH1|CH2");
         P_When   := New_Combo (Condition_Labels);
         P_Width  := Time_Combo;
         P_Lower  := Time_Combo;
         P_Upper  := Time_Combo;
         P_Level  := New_Spin (-100.0, 100.0, 0.01, 2);
         Pulse_Box.Attach (P_Source, 0, 0);
         Pulse_Box.Attach (P_When, 1, 0);
         Pulse_Box.Attach (New_Label ("Width"), 0, 1);
         Pulse_Box.Attach (P_Width, 1, 1);
         Pulse_Box.Attach (New_Label ("Range from"), 0, 2);
         Pulse_Box.Attach (P_Lower, 1, 2);
         Pulse_Box.Attach (New_Label ("to"), 0, 3);
         Pulse_Box.Attach (P_Upper, 1, 3);
         Pulse_Box.Attach (New_Label ("Level (V)"), 0, 4);
         Pulse_Box.Attach (P_Level, 1, 4);
         G.Attach (Pulse_Box, 0, 2, 2);

         --  Slope
         Slope_Box := Row_Grid;
         Slope_Box.Set_Row_Spacing (4);
         Slope_Box.Set_Column_Spacing (8);
         S_Source  := New_Combo ("CH1|CH2");
         S_When    := New_Combo
           ("rise > time|rise < time|fall > time|fall < time|rise in range|fall in range");
         S_Time    := Time_Combo;
         S_Lower   := Time_Combo;
         S_Upper   := Time_Combo;
         S_Window  := New_Combo ("Level A|Level B|A and B");
         S_Level_A := New_Spin (-100.0, 100.0, 0.01, 2);
         S_Level_B := New_Spin (-100.0, 100.0, 0.01, 2);
         Slope_Box.Attach (S_Source, 0, 0);
         Slope_Box.Attach (S_When, 1, 0);
         Slope_Box.Attach (New_Label ("Time"), 0, 1);
         Slope_Box.Attach (S_Time, 1, 1);
         Slope_Box.Attach (New_Label ("Range from"), 0, 2);
         Slope_Box.Attach (S_Lower, 1, 2);
         Slope_Box.Attach (New_Label ("to"), 0, 3);
         Slope_Box.Attach (S_Upper, 1, 3);
         Slope_Box.Attach (New_Label ("Adjust"), 0, 4);
         Slope_Box.Attach (S_Window, 1, 4);
         Slope_Box.Attach (New_Label ("Level A (V)"), 0, 5);
         Slope_Box.Attach (S_Level_A, 1, 5);
         Slope_Box.Attach (New_Label ("Level B (V)"), 0, 6);
         Slope_Box.Attach (S_Level_B, 1, 6);
         G.Attach (Slope_Box, 0, 3, 2);

         Trig_Sweep := New_Combo ("Auto|Normal|Single");
         G.Attach (New_Label ("Sweep"), 0, 4);
         G.Attach (Trig_Sweep, 1, 4);

         Trig_Mode.On_Changed (On_Trigger_Mode'Access);
         Trig_Source.On_Changed (On_Trigger_Choice'Access);
         Trig_Slope.On_Changed (On_Trigger_Choice'Access);
         Trig_Sweep.On_Changed (On_Trigger_Choice'Access);
         Trig_Level.On_Value_Changed (On_Trigger_Level'Access);
         for C of Gtk_Combo_Box_Text_Array'(P_Source, P_When, P_Width, P_Lower, P_Upper) loop
            C.On_Changed (On_Pulse_Choice'Access);
         end loop;
         P_Level.On_Value_Changed (On_Pulse_Level'Access);
         for C of Gtk_Combo_Box_Text_Array'
           (S_Source, S_When, S_Time, S_Lower, S_Upper, S_Window)
         loop
            C.On_Changed (On_Slope_Choice'Access);
         end loop;
         S_Level_A.On_Value_Changed (On_Slope_Level'Access);
         S_Level_B.On_Value_Changed (On_Slope_Level'Access);
         Panel.Pack_Start (Framed ("Trigger", G), Expand => False);
      end;

      --  Measurements
      declare
         G : constant Gtk_Grid := Row_Grid;
      begin
         Meas_Channel := New_Combo ("CH1|CH2|Off");
         Meas_Channel.Set_Active (0);
         G.Attach (New_Label ("Channel"), 0, 0);
         G.Attach (Meas_Channel, 1, 0);
         for Slot in 1 .. Slots loop
            Gtk_New (Slot_Item (Slot));
            Slot_Item (Slot).Append_Text ("-");
            for I of Items loop
               Slot_Item (Slot).Append_Text (To_String (I.Label));
            end loop;
            Slot_Item (Slot).Set_Active (Gint (Default_Slots (Slot)));
            Slot_Value (Slot) := New_Label ("-");
            Slot_Value (Slot).Set_Width_Chars (11);
            G.Attach (Slot_Item (Slot), 0, Gint (Slot));
            G.Attach (Slot_Value (Slot), 1, Gint (Slot));
            Slot_Item (Slot).On_Changed (On_Meas_Choice'Access);
         end loop;
         Meas_Channel.On_Changed (On_Meas_Choice'Access);
         Record_Button := New_Button ("Record ...", On_Record'Access);
         G.Attach (Record_Button, 0, Gint (Slots) + 1, 2);
         Panel.Pack_Start (Framed ("Measurements", G), Expand => False);
      end;

      --  Math
      declare
         G : constant Gtk_Grid := Row_Grid;
      begin
         Math_Mode_Box  := New_Combo ("Off|Scope|PC");
         Math_Op_Box    := New_Combo ("A+B|A-B|AxB|A/B");
         Math_Scale_Box := New_Combo (Scale_Items (Math_Scale_Values, ""));
         Math_Position  := New_Spin (-50.0, 50.0, 0.1, 1);
         Math_Position.Set_Value (0.0);   --  a spin button starts at its minimum
         Math_Mode_Box.Set_Active (0);
         Math_Op_Box.Set_Active (0);
         Math_Scale_Box.Set_Active
           (Gint (Nearest (Math_Scale_Values, 1.0) - Math_Scale_Values'First));
         G.Attach (Math_Mode_Box, 0, 0);
         G.Attach (Math_Op_Box, 1, 0);
         G.Attach (New_Label ("Scale"), 0, 1);
         G.Attach (Math_Scale_Box, 1, 1);
         G.Attach (New_Label ("Position (div)"), 0, 2);
         G.Attach (Math_Position, 1, 2);
         G.Attach (New_Label ("A = CH1, B = CH2"), 0, 3, 2);
         Math_Mode_Box.On_Changed (On_Math_Choice'Access);
         Math_Op_Box.On_Changed (On_Math_Choice'Access);
         Math_Scale_Box.On_Changed (On_Math_Scale_Combo'Access);
         Math_Position.On_Value_Changed (On_Math_Position'Access);
         Panel.Pack_Start (Framed ("Math", G), Expand => False);
      end;

      --  FFT
      declare
         G   : constant Gtk_Grid := Row_Grid;
         Log : Gtk_Check_Button;
         Windows : Unbounded_String;
      begin
         for W of Window_Labels loop
            Append (Windows, (if Length (Windows) = 0 then "" else "|") & To_String (W));
         end loop;
         FFT_Mode_Box   := New_Combo ("Off|Scope|PC");
         FFT_Source_Box := New_Combo ("CH1|CH2");
         FFT_Window_Box := New_Combo (To_String (Windows));
         FFT_Data_Box   := New_Combo ("Screen|Memory");
         FFT_Mode_Box.Set_Active (0);
         FFT_Source_Box.Set_Active (0);
         FFT_Window_Box.Set_Active (1);   --  Hann
         FFT_Data_Box.Set_Active (0);
         Gtk_New (Log, "Log frequency axis");
         G.Attach (FFT_Mode_Box, 0, 0);
         G.Attach (FFT_Source_Box, 1, 0);
         G.Attach (New_Label ("Window"), 0, 1);
         G.Attach (FFT_Window_Box, 1, 1);
         G.Attach (New_Label ("Scope FFT of"), 0, 2);
         G.Attach (FFT_Data_Box, 1, 2);
         G.Attach (Log, 0, 3, 2);
         FFT_Mode_Box.On_Changed (On_FFT_Choice'Access);
         FFT_Source_Box.On_Changed (On_FFT_Choice'Access);
         FFT_Window_Box.On_Changed (On_FFT_Choice'Access);
         FFT_Data_Box.On_Changed (On_FFT_Choice'Access);
         Log.On_Toggled (On_FFT_Log'Access);
         Panel.Pack_Start (Framed ("FFT", G), Expand => False);
      end;

      --  Cursors
      declare
         G    : constant Gtk_Grid := Row_Grid;
         Show : Gtk_Check_Button;
      begin
         Gtk_New (Show, "Show cursors");
         Show.On_Toggled (On_Cursors'Access);
         G.Attach (Show, 0, 0);
         G.Attach (New_Label ("Drag the A and B lines"), 0, 1);
         Panel.Pack_Start (Framed ("Cursors", G), Expand => False);
      end;

      --  Display: YT or XY
      declare
         G    : constant Gtk_Grid := Row_Grid;
      begin
         Display_Box := New_Combo ("YT (time)|XY (CH1 across, CH2 up)");
         Display_Box.Set_Active (0);
         Display_Box.On_Changed (On_Display_Mode'Access);
         G.Attach (Display_Box, 0, 0);
         Panel.Pack_Start (Framed ("Display", G), Expand => False);
      end;

      --  Pass/fail
      declare
         G : constant Gtk_Grid := Row_Grid;
      begin
         Mask_Source := New_Combo ("CH1|CH2");
         Mask_Source.Set_Active (0);
         Mask_X := New_Spin (0.02, 4.0, 0.02, 2);
         Mask_X.Set_Value (0.2);
         Mask_Y := New_Spin (0.04, 5.12, 0.04, 2);
         Mask_Y.Set_Value (0.48);
         Gtk_New (Mask_Stop, "Stop on fail");
         Mask_Counts := New_Label ("Test off");
         G.Attach (New_Label ("Source"), 0, 0);
         G.Attach (Mask_Source, 1, 0);
         G.Attach (New_Label ("Margin X (div)"), 0, 1);
         G.Attach (Mask_X, 1, 1);
         G.Attach (New_Label ("Margin Y (div)"), 0, 2);
         G.Attach (Mask_Y, 1, 2);
         G.Attach (Mask_Stop, 0, 3, 2);
         G.Attach (New_Button ("Create mask", On_Mask_Button'Access), 0, 4);
         G.Attach (New_Button ("Start", On_Mask_Button'Access), 1, 4);
         G.Attach (New_Button ("Stop", On_Mask_Button'Access), 0, 5);
         G.Attach (New_Button ("Reset", On_Mask_Button'Access), 1, 5);
         G.Attach (New_Button ("Off", On_Mask_Button'Access), 0, 6);
         G.Attach (Mask_Counts, 0, 7, 2);
         Panel.Pack_Start (Framed ("Pass/fail", G), Expand => False);
      end;

      --  References
      declare
         G    : constant Gtk_Grid := Row_Grid;
         Show : Gtk_Check_Button;
      begin
         Ref_Slot_Box := New_Combo ("R1|R2|R3|R4");
         Ref_Slot_Box.Set_Active (0);
         Ref_Source := New_Combo ("CH1|CH2");
         Ref_Source.Set_Active (0);
         Ref_List := New_Label ("none");
         Gtk_New (Show, "Show references");
         Show.Set_Active (True);
         Show.On_Toggled (On_Show_Refs'Access);
         G.Attach (Ref_Slot_Box, 0, 0);
         G.Attach (Ref_Source, 1, 0);
         G.Attach (New_Button ("Save", On_Ref_Button'Access), 0, 1);
         G.Attach (New_Button ("Clear", On_Ref_Button'Access), 1, 1);
         G.Attach (New_Button ("Export ...", On_Ref_Button'Access), 0, 2);
         G.Attach (New_Button ("Import ...", On_Ref_Button'Access), 1, 2);
         G.Attach (Show, 0, 3, 2);
         G.Attach (Ref_List, 0, 4, 2);
         Panel.Pack_Start (Framed ("References", G), Expand => False);
      end;

      Panel.Pack_Start
        (Decode_Panel.Create_Controls (Say_Text'Access, Error_Text'Access),
         Expand => False);
      Panel.Pack_Start
        (Timing_Panel.Create_Controls (Say_Text'Access, Error_Text'Access),
         Expand => False);

      --  Setups
      declare
         G : constant Gtk_Grid := Row_Grid;
      begin
         G.Attach (New_Button ("Save setup ...", On_Save_Setup'Access), 0, 0);
         G.Attach (New_Button ("Load setup ...", On_Load_Setup'Access), 1, 0);
         Panel.Pack_Start (Framed ("Setups", G), Expand => False);
      end;

      --  Capture and files
      declare
         G : constant Gtk_Grid := Row_Grid;
      begin
         Gtk_New (Progress);
         Progress.Set_Show_Text (False);
         G.Attach (New_Button ("Capture memory", On_Capture'Access), 0, 0);
         G.Attach (New_Button ("Live", On_Live'Access), 1, 0);
         G.Attach (Progress, 0, 1, 2);
         G.Attach (New_Button ("Screenshot ...", On_Screenshot'Access), 0, 2);
         G.Attach (New_Button ("Export CSV ...", On_Export'Access), 1, 2);
         Panel.Pack_Start (Framed ("Capture", G), Expand => False);
      end;

      --  About, small, at the bottom
      declare
         B : constant Gtk_Button := New_Button ("About", On_About'Access);
      begin
         B.Set_Halign (Align_End);
         Panel.Pack_Start (B, Expand => False, Padding => 4);
      end;

      Gui_Client.Set_Event_Handler (On_Event'Access);
      Gui_Client.Set_Error_Handler (On_Error'Access);
      Dummy := Glib.Main.Timeout_Add (20, Poll'Access);
      Dummy := Glib.Main.Timeout_Add (1500, Periodic_Status'Access);

      Win.Show_All;
      Spectrum_Area.Hide;   --  until an FFT is chosen
      Show_Trigger_Mode;
      Decode_Panel.After_Show;
      Timing_Panel.After_Show;
      Refresh_Status;
      Refresh_Refs;
      Start_Live;
   end Create;

end Main_Window;
