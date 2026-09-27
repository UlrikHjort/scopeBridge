-- ***************************************************************************
--                  ScopeBridge Server - Settings Requests
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

--  The requests for the scope's settings: status, set_channel, set_math,
--  set_timebase, set_trigger, set_acquire, save_setup, load_setup, set_mask
--  and mask.

with Ada.Strings.Fixed;

with Rigol.Acquire;
with Rigol.Mask;
with Rigol.Setups;
with Rigol.Timebase;

separate (Server.Session.Run)
procedure Execute_Settings
  (Cmd     : String;
   Request : JSON_Value;
   Reply   : JSON_Value;
   Payload : in out Unbounded_String;
   Binary  : in out Boolean;
   Done    : out Boolean)
is
   pragma Unreferenced (Payload, Binary);   --  no binary replies here

   function When_Name (W : Rigol.Trigger.Pulse_When) return String is
     (Lower_Image (Rigol.Trigger.Pulse_When'Image (W)));

   function When_Field (Object : JSON_Value) return Rigol.Trigger.Pulse_When is
      S : constant String := String_Field (Object, "when");
   begin
      for W in Rigol.Trigger.Pulse_When loop
         if S = When_Name (W) then
            return W;
         end if;
      end loop;
      raise Request_Error with """when"" must be ""pos_greater"", ""pos_less"", "
        & """neg_greater"", ""neg_less"", ""pos_in_range"" or ""neg_in_range""";
   end When_Field;

   function Window_Name (W : Rigol.Trigger.Slope_Window) return String is
     (case W is
         when Rigol.Trigger.Level_A => "a",
         when Rigol.Trigger.Level_B => "b",
         when Rigol.Trigger.Both    => "both");

   function Slope_Window_Field
     (Object : JSON_Value) return Rigol.Trigger.Slope_Window
   is
      S : constant String := String_Field (Object, "window");
   begin
      for W in Rigol.Trigger.Slope_Window loop
         if S = Window_Name (W) then
            return W;
         end if;
      end loop;
      raise Request_Error with """window"" must be ""a"", ""b"" or ""both""";
   end Slope_Window_Field;

   --  Pulse and slope triggers take CH1 or CH2 only
   function Channel_Source_Field
     (Object : JSON_Value) return Rigol.Trigger.Trigger_Source
   is
      S : constant String := String_Field (Object, "source");
   begin
      if S = "ch1" then
         return Rigol.Trigger.CH1;
      elsif S = "ch2" then
         return Rigol.Trigger.CH2;
      end if;
      raise Request_Error with """source"" must be ""ch1"" or ""ch2""";
   end Channel_Source_Field;

   --  An optional object member, or JSON_Null
   function Object_Field (Request : JSON_Value; Name : String) return JSON_Value
   is
   begin
      if not Has_Field (Request, Name) then
         return JSON_Null;
      elsif Kind (Get (Request, Name)) /= JSON_Object_Type then
         raise Request_Error with """" & Name & """ must be an object";
      end if;
      return Get (Request, Name);
   end Object_Field;

   function Time_Field (Object : JSON_Value; Name : String) return Float is
      X : constant Float := Number_Field (Object, Name);
   begin
      if X <= 0.0 then
         raise Request_Error with """" & Name & """ must be positive";
      end if;
      return X;
   end Time_Field;
   -- -------------------------------------------------------------------------
   --  Acquisition
   -- -------------------------------------------------------------------------

   function Acquire_Name (T : Rigol.Acquire.Acquire_Type) return String is
     (case T is
         when Rigol.Acquire.Normal          => "normal",
         when Rigol.Acquire.Averages        => "average",
         when Rigol.Acquire.Peak            => "peak",
         when Rigol.Acquire.High_Resolution => "hires");

   --  "12000, 120000, ... or 24000000"
   function Depth_Names (Depths : Rigol.Acquire.Depth_List) return String is
      Result : Unbounded_String;
   begin
      for K in Depths'Range loop
         Append (Result, String'(if K = Depths'First then ""
                                 elsif K = Depths'Last then " or " else ", ") &
                   Ada.Strings.Fixed.Trim (Depths (K)'Image, Ada.Strings.Left));
      end loop;
      return To_String (Result);
   end Depth_Names;

   -- -------------------------------------------------------------------------
   --  Setups: the scope's own setup block, which on the DS1202Z-E restores
   --  only some settings (the timebase, not the channels' scales, and the
   --  trigger level is not even saved), with the settings "status" gives,
   --  which load_setup applies after it
   -- -------------------------------------------------------------------------

   Setup_Magic : constant String := "RIGOL-SERVER-SETUP 1" & ASCII.LF;

   --  Apply settings saved as "status" gives them, a group at a time
   --  through the set_ requests; a group that fails is reported in
   --  Warnings and the others are still applied
   procedure Apply (Saved : JSON_Value; Warnings : in out JSON_Array) is

      procedure Set (Cmd : String; Members : JSON_Value) is
         Result  : constant JSON_Value := Create_Object;
         Payload : Unbounded_String;
         Binary  : Boolean := False;
         Done    : Boolean;
      begin
         Execute_Settings (Cmd, Members, Result, Payload, Binary, Done);
      exception
         when E : Request_Error | Rigol_Transport.Communication_Error
                | Rigol_Transport.Device_Error | Constraint_Error =>
            Append (Warnings, Create (Cmd & ": " & Exception_Message (E)));
      end Set;

      --  Members Names of From, into a new object, leaving out values
      --  "other" (settings this protocol does not set)
      function Copy (From : JSON_Value; Names : String) return JSON_Value is
         Result : constant JSON_Value := Create_Object;
         First  : Positive := Names'First;
      begin
         for I in Names'Range loop
            if Names (I) = ' ' or else I = Names'Last then
               declare
                  Name : constant String :=
                    Names (First .. (if Names (I) = ' ' then I - 1 else I));
               begin
                  if Has_Field (From, Name)
                    and then not (Kind (Get (From, Name)) = JSON_String_Type
                                  and then String'(Get (From, Name)) = "other")
                  then
                     Set_Field (Result, Name, JSON_Value'(Get (From, Name)));
                  end if;
               end;
               First := I + 1;
            end if;
         end loop;
         return Result;
      end Copy;

      function Has (Name : String) return Boolean is (Has_Field (Saved, Name));
   begin
      if Has ("acquire") then
         Set ("set_acquire", Copy (Get (Saved, "acquire"), "type averages"));
      end if;
      if Has ("channels") then
         declare
            Channels : constant JSON_Array := Get (Saved, "channels");
         begin
            for K in 1 .. Length (Channels) loop
               Set ("set_channel", Copy (Get (Channels, K),
                                         "ch display probe scale offset coupling"));
            end loop;
         end;
      end if;
      if Has ("timebase") then
         Set ("set_timebase", Copy (Get (Saved, "timebase"), "mode scale offset"));
      end if;
      if Has ("trigger") then
         Set ("set_trigger",
              Copy (Get (Saved, "trigger"),
                    "mode sweep source slope level pulse slope_trigger"));
      end if;
      if Has ("math") then
         Set ("set_math",
              Copy (Get (Saved, "math"),
                    "operator source1 source2 fft_source fft_window fft_unit " &
                    "fft_mode scale offset fft_hscale fft_hcenter display"));
      end if;
      --  Last: the depths offered depend on the channels on
      if Has ("acquire") then
         Set ("set_acquire", Copy (Get (Saved, "acquire"), "memory_depth"));
      end if;
   end Apply;

   --  The scope's settings, as "status" reports them, added to Message
   procedure Add_Status (Message : JSON_Value) is
   begin
   declare
         Channels : JSON_Array := Empty_Array;
         TB       : constant JSON_Value := Create_Object;
         Trig     : constant JSON_Value := Create_Object;
      begin
         Set_Field
           (Message, "trigger_status",
            Lower_Image (Rigol.Trigger.Trigger_Status'Image
                           (Rigol.Trigger.Get_Status (Scope))));
         for Ch in Channel loop
            declare
               C : constant JSON_Value := Create_Object;
            begin
               Set_Field (C, "ch", Integer (Ch));
               Set_Field (C, "display",
                          Rigol.Channel.Get_Display (Scope, Ch));
               Set_Field (C, "scale",
                          To_JSON (Rigol.Channel.Get_Scale (Scope, Ch)));
               Set_Field (C, "offset",
                          To_JSON (Rigol.Channel.Get_Offset (Scope, Ch)));
               Set_Field (C, "coupling",
                          Lower_Image (Rigol.Channel.Coupling_Type'Image
                            (Rigol.Channel.Get_Coupling (Scope, Ch))));
               Set_Field (C, "probe",
                          To_JSON (Probe_Values
                            (Rigol.Channel.Get_Probe (Scope, Ch))));
               Append (Channels, C);
            end;
         end loop;
         Set_Field (Message, "channels", Create (Channels));

         Set_Field (TB, "scale",
                    To_JSON (Rigol.Timebase.Get_Scale (Scope)));
         Set_Field (TB, "offset",
                    To_JSON (Rigol.Timebase.Get_Offset (Scope)));
         Set_Field (TB, "mode",
                    (case Rigol.Timebase.Get_Mode (Scope) is
                        when Rigol.Timebase.YT   => "yt",
                        when Rigol.Timebase.XY   => "xy",
                        when Rigol.Timebase.Roll => "roll"));
         Set_Field (Message, "timebase", TB);

         --  The pass/fail test's counts, when it is on
         declare
            M : constant JSON_Value := Create_Object;
         begin
            Set_Field (M, "enable", Rigol.Mask.Get_Enable (Scope));
            if Get (M, "enable") then
               Set_Field (M, "running", Rigol.Mask.Get_Running (Scope));
               Set_Field (M, "passed", Create (Rigol.Mask.Passed (Scope)));
               Set_Field (M, "failed", Create (Rigol.Mask.Failed (Scope)));
               Set_Field (M, "total", Create (Rigol.Mask.Total (Scope)));
            end if;
            Set_Field (Message, "mask", M);
         end;

         Set_Field (Trig, "source",
                    Source_Image (Rigol.Trigger.Get_Edge_Source (Scope)));
         Set_Field (Trig, "slope",
                    Lower_Image (Rigol.Trigger.Edge_Slope'Image
                                   (Rigol.Trigger.Get_Edge_Slope (Scope))));
         Set_Field (Trig, "level",
                    To_JSON (Rigol.Trigger.Get_Edge_Level (Scope)));
         Set_Field (Trig, "sweep",
                    Lower_Image (Rigol.Trigger.Trigger_Sweep'Image
                                   (Rigol.Trigger.Get_Sweep (Scope))));
         declare
            use Rigol.Trigger;
            Mode : constant Trigger_Mode := Get_Mode (Scope);
            D    : constant JSON_Value := Create_Object;
         begin
            Set_Field (Trig, "mode",
                       (case Mode is when Edge => "edge", when Pulse => "pulse",
                                     when Slope => "slope", when others => "other"));
            --  The active mode's details only: every query costs time
            if Mode = Pulse then
               Set_Field (D, "source", Source_Image (Get_Pulse_Source (Scope)));
               Set_Field (D, "when", When_Name (Get_Pulse_When (Scope)));
               Set_Field (D, "width", To_JSON (Get_Pulse_Width (Scope)));
               Set_Field (D, "lower", To_JSON (Get_Pulse_Lower (Scope)));
               Set_Field (D, "upper", To_JSON (Get_Pulse_Upper (Scope)));
               Set_Field (D, "level", To_JSON (Get_Pulse_Level (Scope)));
               Set_Field (Trig, "pulse", D);
            elsif Mode = Slope then
               Set_Field (D, "source", Source_Image (Get_Slope_Source (Scope)));
               Set_Field (D, "when", When_Name (Get_Slope_When (Scope)));
               Set_Field (D, "time", To_JSON (Get_Slope_Time (Scope)));
               Set_Field (D, "lower", To_JSON (Get_Slope_Lower (Scope)));
               Set_Field (D, "upper", To_JSON (Get_Slope_Upper (Scope)));
               Set_Field (D, "window", Window_Name (Get_Slope_Window (Scope)));
               Set_Field (D, "level_a", To_JSON (Get_Slope_Level_A (Scope)));
               Set_Field (D, "level_b", To_JSON (Get_Slope_Level_B (Scope)));
               Set_Field (Trig, "slope_trigger", D);
            end if;
         end;
         Set_Field (Message, "trigger", Trig);

         declare
            M : constant JSON_Value := Create_Object;
            use Rigol.Math;
         begin
            Set_Field (M, "display", Get_Display (Scope));
            Set_Field (M, "operator", Operator_Name (Get_Operator (Scope)));
            Set_Field (M, "source1", Source_Name (Get_Source1 (Scope)));
            Set_Field (M, "source2", Source_Name (Get_Source2 (Scope)));
            Set_Field (M, "scale", To_JSON (Get_Scale (Scope)));
            Set_Field (M, "offset", To_JSON (Get_Offset (Scope)));
            Set_Field (M, "fft_source", Source_Name (Get_FFT_Source (Scope)));
            Set_Field (M, "fft_window",
                       Scope_Window_Name (Get_FFT_Window (Scope)));
            Set_Field (M, "fft_unit",
                       (if Get_FFT_Unit (Scope) = dB then "db" else "vrms"));
            Set_Field (M, "fft_mode",
                       (if Get_FFT_Mode (Scope) = Trace then "trace" else "memory"));
            Set_Field (M, "fft_hscale", To_JSON (Get_FFT_HScale (Scope)));
            Set_Field (M, "fft_hcenter", To_JSON (Get_FFT_HCenter (Scope)));
            Set_Field (Message, "math", M);
         end;

         declare
            use Rigol.Acquire;
            A : constant JSON_Value := Create_Object;
         begin
            Set_Field (A, "type", Acquire_Name (Get_Type (Scope)));
            Set_Field (A, "averages", Get_Averages (Scope));
            Set_Field (A, "memory_depth", Get_Memory_Depth (Scope));
            Set_Field (A, "sample_rate", To_JSON (Get_Sample_Rate (Scope)));
            Set_Field (Message, "acquire", A);
         end;
      end;
   end Add_Status;

begin
   Done := True;
   if Cmd = "status" then
      Add_Status (Reply);

   elsif Cmd = "set_channel" then
      declare
         Ch : constant Channel := Channel_Field (Request);
      begin
         --  Validate every member before changing anything
         declare
            Display  : constant Boolean :=
              (if Has_Field (Request, "display")
               then Boolean_Field (Request, "display") else False);
            Scale    : constant Float :=
              (if Has_Field (Request, "scale")
               then Number_Field (Request, "scale") else 1.0);
            Offset   : constant Float :=
              (if Has_Field (Request, "offset")
               then Number_Field (Request, "offset") else 0.0);
            Coupling : constant Rigol.Channel.Coupling_Type :=
              (if Has_Field (Request, "coupling")
               then Coupling_Field (Request) else Rigol.Channel.DC);
            Probe    : constant Rigol.Channel.Probe_Ratio :=
              (if Has_Field (Request, "probe")
               then Probe_Field (Request) else Rigol.Channel.X1);
         begin
            if Scale <= 0.0 then
               raise Request_Error with """scale"" must be positive";
            end if;
            if Has_Field (Request, "display") then
               Rigol.Channel.Set_Display (Scope, Ch, Display);
            end if;
            if Has_Field (Request, "probe") then
               --  Before scale and offset, which the scope expresses
               --  at the probe tip
               Rigol.Channel.Set_Probe (Scope, Ch, Probe);
            end if;
            if Has_Field (Request, "scale") then
               Rigol.Channel.Set_Scale (Scope, Ch, Scale);
            end if;
            if Has_Field (Request, "offset") then
               Rigol.Channel.Set_Offset (Scope, Ch, Offset);
            end if;
            if Has_Field (Request, "coupling") then
               Rigol.Channel.Set_Coupling (Scope, Ch, Coupling);
            end if;
         end;
      end;

   elsif Cmd = "set_math" then
      declare
         use Rigol.Math;
         function Has (Name : String) return Boolean is
           (Has_Field (Request, Name));
         --  Validate every member before changing anything
         Display : constant Boolean :=
           (if Has ("display") then Boolean_Field (Request, "display") else False);
         Op      : constant Settable_Operator :=
           (if Has ("operator") then Scope_Operator_Field (Request) else Add);
         Src1    : constant Channel_Source :=
           (if Has ("source1") then Scope_Source_Field (Request, "source1") else CH1);
         Src2    : constant Channel_Source :=
           (if Has ("source2") then Scope_Source_Field (Request, "source2") else CH1);
         Scale   : constant Float :=
           (if Has ("scale") then Number_Field (Request, "scale") else 1.0);
         Offset  : constant Float :=
           (if Has ("offset") then Number_Field (Request, "offset") else 0.0);
         F_Src   : constant Channel_Source :=
           (if Has ("fft_source") then Scope_Source_Field (Request, "fft_source")
            else CH1);
         F_Win   : constant FFT_Window :=
           (if Has ("fft_window") then Scope_Window_Field (Request) else Rectangle);
         F_Unit  : constant String :=
           (if Has ("fft_unit") then String_Field (Request, "fft_unit") else "db");
         F_Mode  : constant String :=
           (if Has ("fft_mode") then String_Field (Request, "fft_mode") else "trace");
         HScale  : constant Float :=
           (if Has ("fft_hscale") then Number_Field (Request, "fft_hscale") else 1.0);
         HCenter : constant Float :=
           (if Has ("fft_hcenter") then Number_Field (Request, "fft_hcenter") else 0.0);
      begin
         if Scale <= 0.0 or else HScale <= 0.0 then
            raise Request_Error with "scales must be positive";
         elsif HCenter < 0.0 then
            raise Request_Error with """fft_hcenter"" must not be negative";
         elsif F_Unit not in "db" | "vrms" then
            raise Request_Error with """fft_unit"" must be ""db"" or ""vrms""";
         elsif F_Mode not in "trace" | "memory" then
            raise Request_Error with """fft_mode"" must be ""trace"" or ""memory""";
         end if;
         --  Operator first: the scope picks a new scale for it
         if Has ("operator") then
            Set_Operator (Scope, Op);
         end if;
         if Has ("source1") then
            Set_Source1 (Scope, Src1);
         end if;
         if Has ("source2") then
            Set_Source2 (Scope, Src2);
         end if;
         if Has ("fft_source") then
            Set_FFT_Source (Scope, F_Src);
         end if;
         if Has ("fft_window") then
            Set_FFT_Window (Scope, F_Win);
         end if;
         if Has ("fft_unit") then
            Set_FFT_Unit (Scope, (if F_Unit = "db" then dB else Vrms));
         end if;
         if Has ("fft_mode") then
            Set_FFT_Mode (Scope, (if F_Mode = "trace" then Trace else Memory));
         end if;
         if Has ("scale") then
            Set_Scale (Scope, Scale);
         end if;
         if Has ("offset") then
            Set_Offset (Scope, Offset);
         end if;
         if Has ("fft_hscale") then
            Set_FFT_HScale (Scope, HScale);
         end if;
         if Has ("fft_hcenter") then
            Set_FFT_HCenter (Scope, HCenter);
         end if;
         if Has ("display") then
            Set_Display (Scope, Display);
         end if;
      end;

   elsif Cmd = "set_timebase" then
      declare
         Scale  : constant Float :=
           (if Has_Field (Request, "scale")
            then Number_Field (Request, "scale") else 1.0);
         Offset : constant Float :=
           (if Has_Field (Request, "offset")
            then Number_Field (Request, "offset") else 0.0);
         Mode   : constant String :=
           (if Has_Field (Request, "mode")
            then String_Field (Request, "mode") else "yt");
      begin
         if Scale <= 0.0 then
            raise Request_Error with """scale"" must be positive";
         elsif Mode not in "yt" | "xy" | "roll" then
            raise Request_Error with """mode"" must be ""yt"", ""xy"" or ""roll""";
         end if;
         if Has_Field (Request, "mode") then
            Rigol.Timebase.Set_Mode
              (Scope, (if Mode = "xy" then Rigol.Timebase.XY
                       elsif Mode = "roll" then Rigol.Timebase.Roll
                       else Rigol.Timebase.YT));
            Forget_Waveform_Settings;
         end if;
         if Has_Field (Request, "scale") then
            Rigol.Timebase.Set_Scale (Scope, Scale);
         end if;
         if Has_Field (Request, "offset") then
            Rigol.Timebase.Set_Offset (Scope, Offset);
         end if;
      end;

   elsif Cmd = "set_trigger" then
      declare
         use Rigol.Trigger;
         --  Validate every member before changing anything
         Source : constant Trigger_Source :=
           (if Has_Field (Request, "source")
            then Source_Field (Request) else CH1);
         Slope  : constant Edge_Slope :=
           (if Has_Field (Request, "slope")
            then Slope_Field (Request) else Rising);
         Level  : constant Float :=
           (if Has_Field (Request, "level")
            then Number_Field (Request, "level") else 0.0);
         Sweep  : constant Trigger_Sweep :=
           (if Has_Field (Request, "sweep")
            then Sweep_Field (Request) else Auto);
         Mode_S : constant String :=
           (if Has_Field (Request, "mode")
            then String_Field (Request, "mode") else "edge");
         P      : constant JSON_Value := Object_Field (Request, "pulse");
         L      : constant JSON_Value := Object_Field (Request, "slope_trigger");

         function Has (Object : JSON_Value; Name : String) return Boolean is
           (Kind (Object) = JSON_Object_Type and then Has_Field (Object, Name));

         P_Source : constant Trigger_Source :=
           (if Has (P, "source") then Channel_Source_Field (P) else CH1);
         P_When   : constant Pulse_When :=
           (if Has (P, "when") then When_Field (P) else Pos_Greater);
         P_Width  : constant Float :=
           (if Has (P, "width") then Time_Field (P, "width") else 1.0);
         P_Lower  : constant Float :=
           (if Has (P, "lower") then Time_Field (P, "lower") else 1.0);
         P_Upper  : constant Float :=
           (if Has (P, "upper") then Time_Field (P, "upper") else 1.0);
         P_Level  : constant Float :=
           (if Has (P, "level") then Number_Field (P, "level") else 0.0);
         L_Source : constant Trigger_Source :=
           (if Has (L, "source") then Channel_Source_Field (L) else CH1);
         L_When   : constant Slope_When :=
           (if Has (L, "when") then When_Field (L) else Pos_Greater);
         L_Time   : constant Float :=
           (if Has (L, "time") then Time_Field (L, "time") else 1.0);
         L_Lower  : constant Float :=
           (if Has (L, "lower") then Time_Field (L, "lower") else 1.0);
         L_Upper  : constant Float :=
           (if Has (L, "upper") then Time_Field (L, "upper") else 1.0);
         L_Window : constant Slope_Window :=
           (if Has (L, "window") then Slope_Window_Field (L) else Level_A);
         L_A      : constant Float :=
           (if Has (L, "level_a") then Number_Field (L, "level_a") else 0.0);
         L_B      : constant Float :=
           (if Has (L, "level_b") then Number_Field (L, "level_b") else 0.0);
      begin
         if Mode_S not in "edge" | "pulse" | "slope" then
            raise Request_Error
              with """mode"" must be ""edge"", ""pulse"" or ""slope""";
         end if;
         if (Has (P, "lower") and then Has (P, "upper") and then P_Lower >= P_Upper)
           or else (Has (L, "lower") and then Has (L, "upper")
                    and then L_Lower >= L_Upper)
         then
            raise Request_Error with "need lower < upper";
         end if;

         if Has_Field (Request, "mode") then
            Set_Mode (Scope, (if Mode_S = "edge" then Edge
                              elsif Mode_S = "pulse" then Pulse
                              else Trigger_Mode'(Rigol.Trigger.Slope)));
         end if;
         if Has_Field (Request, "source") then
            Set_Edge_Source (Scope, Source);
         end if;
         if Has_Field (Request, "slope") then
            Set_Edge_Slope (Scope, Slope);
         end if;
         if Has_Field (Request, "level") then
            Set_Edge_Level (Scope, Level);
         end if;
         if Has_Field (Request, "sweep") then
            Set_Sweep (Scope, Sweep);
         end if;

         if Has (P, "source") then
            Set_Pulse_Source (Scope, P_Source);
         end if;
         if Has (P, "when") then
            Set_Pulse_When (Scope, P_When);
         end if;
         if Has (P, "width") then
            Set_Pulse_Width (Scope, P_Width);
         end if;
         --  The scope keeps lower below upper by clamping: upper,
         --  lower, upper moves the range either way
         if Has (P, "upper") then
            Set_Pulse_Upper (Scope, P_Upper);
         end if;
         if Has (P, "lower") then
            Set_Pulse_Lower (Scope, P_Lower);
            if Has (P, "upper") then
               Set_Pulse_Upper (Scope, P_Upper);
            end if;
         end if;
         if Has (P, "level") then
            Set_Pulse_Level (Scope, P_Level);
         end if;

         if Has (L, "source") then
            Set_Slope_Source (Scope, L_Source);
         end if;
         if Has (L, "when") then
            Set_Slope_When (Scope, L_When);
         end if;
         if Has (L, "time") then
            Set_Slope_Time (Scope, L_Time);
         end if;
         if Has (L, "upper") then
            Set_Slope_Upper (Scope, L_Upper);
         end if;
         if Has (L, "lower") then
            Set_Slope_Lower (Scope, L_Lower);
            if Has (L, "upper") then
               Set_Slope_Upper (Scope, L_Upper);
            end if;
         end if;
         if Has (L, "window") then
            Set_Slope_Window (Scope, L_Window);
         end if;
         if Has (L, "level_a") then
            Set_Slope_Level_A (Scope, L_A);
         end if;
         if Has (L, "level_b") then
            Set_Slope_Level_B (Scope, L_B);
         end if;
      end;

   elsif Cmd = "save_setup" then
      declare
         Settings : constant JSON_Value := Create_Object;
      begin
         Add_Status (Settings);
         --  Not settings
         Unset_Field (Settings, "trigger_status");
         Unset_Field (Settings, "mask");
         Set_Field (Reply, "setup",
                    To_Base64 (Setup_Magic & Write (Settings) & ASCII.LF &
                               Rigol.Setups.Save (Scope)));
      end;

   elsif Cmd = "load_setup" then
      declare
         Setup    : constant String :=
           From_Base64 (String_Field (Request, "setup"));
         Ours     : constant Boolean :=
           Setup'Length > Setup_Magic'Length
             and then Setup (Setup'First .. Setup'First + Setup_Magic'Length - 1)
                        = Setup_Magic;
         Warnings : JSON_Array := Empty_Array;
      begin
         if Setup'Length = 0 then
            raise Request_Error with """setup"" is empty";
         end if;
         Forget_Waveform_Settings;   --  the setup may change them
         if Ours then
            declare
               Rest  : constant String :=
                 Setup (Setup'First + Setup_Magic'Length .. Setup'Last);
               Line  : constant Natural :=
                 Ada.Strings.Fixed.Index (Rest, (1 => ASCII.LF));
               Saved : JSON_Value;
            begin
               if Line = 0 then
                  raise Request_Error with """setup"" is damaged";
               end if;
               Saved := Read (Rest (Rest'First .. Line - 1));
               Rigol.Setups.Restore (Scope, Rest (Line + 1 .. Rest'Last));
               Apply (Saved, Warnings);
            exception
               when Invalid_JSON_Stream =>
                  raise Request_Error with """setup"" is damaged";
            end;
         else
            --  The scope's own block alone, as saved by earlier versions
            Rigol.Setups.Restore (Scope, Setup);
         end if;
         if Length (Warnings) > 0 then
            Set_Field (Reply, "warnings", Create (Warnings));
         end if;
      end;

   elsif Cmd = "set_acquire" then
      declare
         use Rigol.Acquire;
         function Has (Name : String) return Boolean is (Has_Field (Request, Name));
         --  Validate every member before changing anything
         Type_S   : constant String :=
           (if Has ("type") then String_Field (Request, "type") else "normal");
         Averages : constant Integer :=
           (if Has ("averages") then Integer_Field (Request, "averages") else 2);
         Depth    : constant Integer :=
           (if Has ("memory_depth") then Integer_Field (Request, "memory_depth") else 0);
         Mode     : Acquire_Type := Normal;
         Found    : Boolean := False;
      begin
         for T in Acquire_Type loop
            if Acquire_Name (T) = Type_S then
               Mode  := T;
               Found := True;
            end if;
         end loop;
         if not Found then
            raise Request_Error
              with """type"" must be ""normal"", ""average"", ""peak"" or ""hires""";
         elsif Averages not in 2 | 4 | 8 | 16 | 32 | 64 | 128 | 256 | 512 | 1024 then
            raise Request_Error with """averages"" must be a power of two, 2 .. 1024";
         end if;
         if Has ("memory_depth") and then Depth /= Auto_Depth then
            --  The scope ignores a depth it does not offer for the
            --  channels on, silently
            declare
               Dual   : constant Boolean :=
                 Rigol.Channel.Get_Display (Scope, 1)
                   and then Rigol.Channel.Get_Display (Scope, 2);
               Depths : constant Depth_List :=
                 (if Dual then Dual_Channel_Depths else Single_Channel_Depths);
            begin
               if (for all D of Depths => D /= Depth) then
                  raise Request_Error with """memory_depth"" must be 0 (automatic) or, "
                    & (if Dual then "with both channels on, " else "with one channel on, ")
                    & Depth_Names (Depths);
               end if;
            end;
         end if;
         if Has ("memory_depth") then
            --  Also ignored, silently, while the scope is stopped (as it is
            --  after a capture)
            declare
               use type Rigol.Trigger.Trigger_Status;
            begin
               if Rigol.Trigger.Get_Status (Scope) = Rigol.Trigger.Stop then
                  raise Request_Error
                    with "the scope changes the memory depth only while running: run it first";
               end if;
            end;
         end if;
         if Has ("type") then
            Set_Type (Scope, Mode);
         end if;
         if Has ("averages") then
            Set_Averages (Scope, Averages);
         end if;
         if Has ("memory_depth") then
            Set_Memory_Depth (Scope, Depth);
         end if;
      end;

   elsif Cmd = "set_mask" then
      declare
         use Rigol.Mask;
         function Has (Name : String) return Boolean is
           (Has_Field (Request, Name));
         function Flag (Name : String) return Boolean is
           (Has (Name) and then Boolean_Field (Request, Name));
         --  Validate every member before changing anything
         Src : constant Rigol.Trigger.Trigger_Source :=
           (if Has ("source") then Channel_Source_Field (Request)
            else Rigol.Trigger.CH1);
         X   : constant Float :=
           (if Has ("x") then Number_Field (Request, "x") else 0.02);
         Y   : constant Float :=
           (if Has ("y") then Number_Field (Request, "y") else 0.96);
         Run_It : constant Boolean := Flag ("run");
         Flags  : constant array (1 .. 7) of Unbounded_String :=
           (To_Unbounded_String ("enable"), To_Unbounded_String ("stop_on_fail"),
            To_Unbounded_String ("beep"), To_Unbounded_String ("show_stats"),
            To_Unbounded_String ("create"), To_Unbounded_String ("reset"),
            To_Unbounded_String ("run"));
         Dummy  : Boolean;
      begin
         if X not in 0.02 .. 4.0 then
            raise Request_Error with """x"" must be 0.02 .. 4 (divisions)";
         elsif Y not in 0.04 .. 5.12 then
            raise Request_Error with """y"" must be 0.04 .. 5.12 (divisions)";
         end if;
         for Name of Flags loop
            if Has (To_String (Name)) then
               --  Raises Request_Error unless a bool
               Dummy := Boolean_Field (Request, To_String (Name));
            end if;
         end loop;

         if Has ("enable") then
            Set_Enable (Scope, Flag ("enable"));
         end if;
         if Has ("source") then
            Rigol.Mask.Set_Source (Scope, (if Rigol.Trigger."=" (Src, Rigol.Trigger.CH2) then 2 else 1));
         end if;
         if Has ("x") then
            Set_X (Scope, X);
         end if;
         if Has ("y") then
            Set_Y (Scope, Y);
         end if;
         if Has ("stop_on_fail") then
            Set_Stop_On_Fail (Scope, Flag ("stop_on_fail"));
         end if;
         if Has ("beep") then
            Set_Beep (Scope, Flag ("beep"));
         end if;
         if Has ("show_stats") then
            Set_Show_Statistics (Scope, Flag ("show_stats"));
         end if;
         if Flag ("create") then
            --  Only while stopped
            Set_Running (Scope, False);
            Create_Mask (Scope);
         end if;
         if Flag ("reset") then
            Reset (Scope);
         end if;
         if Has ("run") then
            Set_Running (Scope, Run_It);
         end if;
      end;

   elsif Cmd = "mask" then
      declare
         use Rigol.Mask;
      begin
         Set_Field (Reply, "enable", Get_Enable (Scope));
         Set_Field (Reply, "source",
                    (if Get_Source (Scope) = 2 then "ch2" else "ch1"));
         Set_Field (Reply, "running", Get_Running (Scope));
         Set_Field (Reply, "x", To_JSON (Get_X (Scope)));
         Set_Field (Reply, "y", To_JSON (Get_Y (Scope)));
         Set_Field (Reply, "stop_on_fail", Get_Stop_On_Fail (Scope));
         Set_Field (Reply, "beep", Get_Beep (Scope));
         Set_Field (Reply, "show_stats", Get_Show_Statistics (Scope));
         Set_Field (Reply, "passed", Create (Passed (Scope)));
         Set_Field (Reply, "failed", Create (Failed (Scope)));
         Set_Field (Reply, "total", Create (Total (Scope)));
      end;

   else
      Done := False;
   end if;
end Execute_Settings;
