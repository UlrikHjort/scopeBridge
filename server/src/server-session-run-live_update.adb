-- ***************************************************************************
--                    ScopeBridge Server - Live Updates
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

--  One update of live mode: frames, measurements, math and spectra, to
--  the subscribed clients.

separate (Server.Session.Run)
procedure Live_Update is
   Shown : array (Channel) of Boolean;
   M     : Natural := 0;   --  channel to measure, 0 = none

   --  This update's frames in volts, for server math and spectra
   type Frame_Volts is record
      N      : Natural := 0;
      X_Inc  : Float   := 0.0;
      X_Orig : Float   := 0.0;
      V      : Real_Array (0 .. Screen_Points - 1);
   end record;
   Frames : array (Channel) of Frame_Volts;

   procedure Send_Measurements is
      Event : constant JSON_Value :=
        Measure_Object (Channel (M), Live_Items (1 .. Live_Item_Count));
   begin
      Set_Field (Event, "event", "measure");
      Broadcast (Event);
   end Send_Measurements;
begin
   for Ch in Channel loop
      Shown (Ch) := Rigol.Channel.Get_Display (Scope, Ch);
   end loop;

   if Live_Measure > 0 then
      M := Live_Measure;
   elsif Live_Measure < 0 then
      for Ch in reverse Channel loop
         if Shown (Ch) then
            M := Natural (Ch);
         end if;
      end loop;
   end if;

   for Ch in Channel loop
      if Shown (Ch) then
         Select_Screen (Ch);

         declare
            Pre   : Preamble;
            Data  : constant Raw_Array := Read_Prepared_Screen (Scope, Pre);
            Event : constant JSON_Value := Object ("event", "frame");
         begin
            --  Right after a source switch the scope sometimes has
            --  no screen data yet; skip rather than send nothing
            if Data'Length > 0 then
               Set_Field (Event, "ch", Integer (Ch));
               Add_Waveform (Event, Pre, Data'Length);
               Broadcast (Event, To_Bytes (Data));

               Frames (Ch).N := Natural'Min (Data'Length, Screen_Points);
               Frames (Ch).X_Inc  := Pre.X_Increment;
               Frames (Ch).X_Orig := Pre.X_Origin;
               for I in 0 .. Frames (Ch).N - 1 loop
                  Frames (Ch).V (I) :=
                    Long_Float (Volts (Pre, Data (Data'First + I)));
               end loop;
            end if;
         end;

         --  Measuring a channel right after reading its screen, before
         --  the source moves on, avoids the scope re-arming its
         --  measurements
         if M = Natural (Ch) then
            Send_Measurements;
         end if;
      end if;
   end loop;

   if M /= 0 and then not Shown (Channel (M)) then
      Send_Measurements;
   end if;

   --  Server arithmetic, on this update's frames of both channels
   if Live_Math /= None
     and then Frames (1).N > 0 and then Frames (1).N = Frames (2).N
   then
      declare
         N      : constant Natural := Frames (1).N;
         Result : Real_Array (0 .. N - 1);
         Event  : constant JSON_Value := Object ("event", "math");
      begin
         for I in Result'Range loop
            Result (I) := Apply (Live_Math, Frames (1).V (I), Frames (2).V (I));
         end loop;
         Set_Field (Event, "source", "server");
         Set_Field (Event, "operator", Math_Name (Live_Math));
         Set_Field (Event, "points", N);
         Set_Field (Event, "x_inc", To_JSON (Frames (1).X_Inc));
         Set_Field (Event, "x_origin", To_JSON (Frames (1).X_Orig));
         Set_Field (Event, "unit", Math_Unit (Live_Math));
         Broadcast (Event, To_Float32_Bytes (Result));
      end;
   end if;

   --  Server FFT of one channel's frame
   if Live_Spectrum /= 0
     and then Frames (Channel (Live_Spectrum)).N >= Min_Length
   then
      declare
         F     : Frame_Volts renames Frames (Channel (Live_Spectrum));
         Width : Long_Float;
         Bins  : constant Real_Array :=
           Compute (F.V (0 .. F.N - 1), Long_Float (F.X_Inc), Live_Window,
                    Width);
         Event : constant JSON_Value := Object ("event", "spectrum");
      begin
         Set_Field (Event, "source", "server");
         Set_Field (Event, "ch", Live_Spectrum);
         Add_Spectrum (Event, Bins'Length, 0.0, Width, Width, "dBV",
                       Window_Name (Live_Window));
         Broadcast (Event, To_Float32_Bytes (Bins));
      end;
   end if;

   --  The scope's math channel: a trace, or a spectrum for FFT
   if Live_Scope_Math and then Rigol.Math.Get_Display (Scope) then
      if not Screen_Ready then
         Forget_Waveform_Settings;
         Prepare_Math_Read (Scope);
         Screen_Ready := True;
         Wave_Source  := Math_Source;
      elsif Wave_Source /= Math_Source then
         Wave_Source := 0;
         Set_Source_Math (Scope);
         Wave_Source := Math_Source;
      end if;
      declare
         Pre    : Preamble;
         Data   : constant Raw_Array := Read_Prepared_Screen (Scope, Pre);
         Values : Real_Array (0 .. Data'Length - 1);
      begin
         --  Empty for a moment after the operator changes
         if Data'Length > 0 then
            for I in Values'Range loop
               Values (I) := Long_Float (Volts (Pre, Data (Data'First + I)));
            end loop;
            declare
               use type Rigol.Math.Operator;
               Op : constant Rigol.Math.Operator :=
                 Rigol.Math.Get_Operator (Scope);
            begin
               if Op = Rigol.Math.FFT then
                  declare
                     use type Rigol.Math.FFT_Unit;
                     Event : constant JSON_Value := Object ("event", "spectrum");
                     Src   : constant Rigol.Math.Source :=
                       Rigol.Math.Get_FFT_Source (Scope);
                     Unit  : constant String :=
                       (if Rigol.Math.Get_FFT_Unit (Scope) = Rigol.Math.dB
                        then "dBV" else "Vrms");
                  begin
                     --  The scope sends the screen from max (0, left
                     --  edge), X_Origin being the left edge
                     Set_Field (Event, "source", "scope");
                     Set_Field (Event, "ch",
                                Integer'(Rigol.Math.Source'Pos (Src) + 1));
                     Add_Spectrum
                       (Event, Values'Length,
                        Long_Float'Max (0.0, Long_Float (Pre.X_Origin)),
                        Long_Float (Pre.X_Increment),
                        Long_Float (Pre.X_Increment), Unit,
                        Scope_Window_Name (Rigol.Math.Get_FFT_Window (Scope)));
                     Broadcast (Event, To_Float32_Bytes (Values));
                  end;
               else
                  declare
                     Event : constant JSON_Value := Object ("event", "math");
                  begin
                     Set_Field (Event, "source", "scope");
                     Set_Field (Event, "operator", Operator_Name (Op));
                     Set_Field (Event, "points", Integer'(Values'Length));
                     Set_Field (Event, "x_inc", To_JSON (Pre.X_Increment));
                     Set_Field (Event, "x_origin", To_JSON (Pre.X_Origin));
                     Set_Field (Event, "unit",
                                (if Op = Rigol.Math.Multiply then "V^2" else "V"));
                     Broadcast (Event, To_Float32_Bytes (Values));
                  end;
               end if;
            end;
         end if;
      end;
   end if;
exception
   when E : Rigol_Transport.Communication_Error
          | Rigol_Transport.Device_Error
          | Rigol.Not_Connected
          | Constraint_Error =>
      --  Report it and keep going after a pause: most failures pass
      --  (a timeout while the scope is busy), and clients should not
      --  have to notice and restart live mode
      Send_Error_Event ("live update failed: " & Exception_Message (E));
      Forget_Waveform_Settings;
      Next_Tick := Clock + 1.0;
end Live_Update;
