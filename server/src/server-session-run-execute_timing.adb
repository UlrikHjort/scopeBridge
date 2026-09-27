-- ***************************************************************************
--                ScopeBridge Server - Code Timing Requests
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

--  Timing code: "timing" measures every block a program marks on a pin, in
--  a capture (see Server.Timing).

with Server.Decode;
with Server.Timing;

separate (Server.Session.Run)
procedure Execute_Timing
  (Cmd     : String;
   Request : JSON_Value;
   Reply   : JSON_Value;
   Payload : in out Unbounded_String;
   Binary  : in out Boolean;
   Done    : out Boolean)
is
   pragma Unreferenced (Payload, Binary);   --  no binary replies here
   use Server.Decode;
   use Server.Timing;

   Max_Bins : constant := 200;

   --  Channel Ch's samples First .. Last as logic levels, at Volts if
   --  given, else halfway between its lowest and highest; the threshold
   --  used goes into Levels
   function Levels_Of
     (Ch          : Channel;
      First, Last : Natural;
      Given       : Boolean;
      Volts       : Float;
      Levels      : JSON_Value) return Digital
   is
      D    : Raw_Array renames Captures (Ch).Data.all;
      P    : Preamble renames Captures (Ch).Pre;
      Th   : Float;
      Hy   : Float;
      Flat : Boolean;
   begin
      Auto_Threshold (D, D'First + First, D'First + Last, Th, Hy, Flat);
      if Given then
         Th := Volts / P.Y_Increment + P.Y_Reference + P.Y_Origin;
      elsif Flat then
         raise Request_Error with "CH" & Character'Val (48 + Integer (Ch))
           & " shows no pulses in the capture: it does not change";
      end if;
      Set_Field (Levels, "ch" & Character'Val (48 + Integer (Ch)),
                 To_JSON ((Th - P.Y_Reference - P.Y_Origin) * P.Y_Increment));
      return Digitize (D, D'First + First, D'First + Last, Th, Hy);
   end Levels_Of;
begin
   Done := True;
   if Cmd /= "timing" then
      Done := False;
      return;
   end if;

   declare
      Ch       : constant Channel := Channel_Field (Request);
      C        : constant Capture := Captured (Ch);
      Polarity : constant String :=
        (if Has_Field (Request, "polarity") then String_Field (Request, "polarity")
         else "high");
      High     : constant Boolean := Polarity = "high";
      To       : constant Integer :=
        (if Has_Field (Request, "to") and then Kind (Get (Request, "to")) /= JSON_Null_Type
         then Integer_Field (Request, "to") else 0);
      Bins     : constant Integer :=
        (if Has_Field (Request, "bins") then Integer_Field (Request, "bins") else 40);
      Gap_S    : constant Float :=
        (if Has_Field (Request, "burst_gap") then Number_Field (Request, "burst_gap") else 0.0);
      X_Inc    : constant Long_Float := Long_Float (C.Pre.X_Increment);
      First    : Natural := 0;
      Last     : Natural := C.Data'Length - 1;
      Levels   : constant JSON_Value := Create_Object;

      --  Statistics of List, scaled by Scale (the sample interval, or 1
      --  for counts), with where the shortest and longest are
      function Stats_Object (List : Interval_List; Scale : Long_Float) return JSON_Value is
         S    : constant Stats := Statistics (List);
         O    : constant JSON_Value := Create_Object;
         H    : constant JSON_Value := Create_Object;
         Hist : JSON_Array := Empty_Array;

         function At_Object (I : Server.Timing.Interval; Length : Natural) return JSON_Value is
            A : constant JSON_Value := Create_Object;
         begin
            Set_Field (A, "first", First + I.Start);
            Set_Field (A, "last", First + I.Start + Length - 1);
            Set_Field (A, "t", To_JSON (Long_Float (C.Pre.X_Origin)
                                        + Long_Float (First + I.Start) * X_Inc));
            return A;
         end At_Object;
      begin
         Set_Field (O, "count", S.Count);
         if S.Count = 0 then
            return O;
         end if;
         Set_Field (O, "min", To_JSON (Long_Float (S.Min) * Scale));
         Set_Field (O, "max", To_JSON (Long_Float (S.Max) * Scale));
         Set_Field (O, "mean", To_JSON (S.Mean * Scale));
         Set_Field (O, "std_dev", To_JSON (S.Std_Dev * Scale));
         Set_Field (O, "median", To_JSON (S.Median * Scale));
         --  For counts, the burst they belong to is Length samples long
         --  only as a count: place it by its start alone
         Set_Field (O, "shortest", At_Object (S.Min_At, (if Scale = 1.0 then 1 else S.Min_At.Length)));
         Set_Field (O, "longest", At_Object (S.Max_At, (if Scale = 1.0 then 1 else S.Max_At.Length)));
         for N of Histogram (List, Bins) loop
            Append (Hist, Create (N));
         end loop;
         Set_Field (H, "from", To_JSON (Long_Float (S.Min) * Scale));
         Set_Field (H, "to", To_JSON (Long_Float (S.Max) * Scale));
         Set_Field (H, "counts", Create (Hist));
         Set_Field (O, "histogram", H);
         return O;
      end Stats_Object;
   begin
      if Polarity not in "high" | "low" then
         raise Request_Error with """polarity"" must be ""high"" or ""low""";
      elsif Bins not in 1 .. Max_Bins then
         raise Request_Error with """bins"" must be 1 .." & Max_Bins'Image;
      elsif Has_Field (Request, "burst_gap") and then Gap_S <= 0.0 then
         raise Request_Error with """burst_gap"" must be positive";
      elsif To not in 0 .. 2 or else To = Integer (Ch) then
         raise Request_Error with """to"" must be the other channel";
      end if;
      if To /= 0 then
         declare
            Other : constant Capture := Captured (Channel (To));
         begin
            if Other.Data'Length /= C.Data'Length
              or else Other.Pre.X_Increment /= C.Pre.X_Increment
            then
               raise Request_Error
                 with "the captures of CH1 and CH2 differ; capture both again";
            end if;
         end;
      end if;
      if Has_Field (Request, "first") or else Has_Field (Request, "last") then
         Range_Fields (Request, C.Data'Length, First, Last);
      end if;

      declare
         Line : constant Digital :=
           Levels_Of (Ch, First, Last, Has_Field (Request, "threshold"),
                      (if Has_Field (Request, "threshold")
                       then Number_Field (Request, "threshold") else 0.0), Levels);
         Blocks  : constant Interval_List := Pulses (Line, High);
         Periods_List : constant Interval_List := Periods (Line, High);
         Block_S  : constant Stats := Statistics (Blocks);
         Period_S : constant Stats := Statistics (Periods_List);
      begin
         Set_Field (Reply, "ch", Integer (Ch));
         Set_Field (Reply, "polarity", Polarity);
         Set_Field (Reply, "resolution", To_JSON (X_Inc));
         Set_Field (Reply, "span", To_JSON (Long_Float (Last - First + 1) * X_Inc));
         Set_Field (Reply, "block", Stats_Object (Blocks, X_Inc));
         Set_Field (Reply, "idle", Stats_Object (Pulses (Line, not High), X_Inc));
         Set_Field (Reply, "period", Stats_Object (Periods_List, X_Inc));
         if Block_S.Count > 0 and then Period_S.Count > 0 then
            Set_Field (Reply, "duty", To_JSON (Block_S.Mean / Period_S.Mean));
         end if;
         if To /= 0 then
            Set_Field (Reply, "to", To);
            Set_Field (Reply, "latency", Stats_Object
              (Latencies (Line, Levels_Of (Channel (To), First, Last, False, 0.0, Levels),
                          High, High), X_Inc));
         end if;
         if Has_Field (Request, "burst_gap") then
            declare
               Spans, Counts : Interval_List;
            begin
               Bursts (Line, High,
                       Positive'Max (1, Natural (Long_Float (Gap_S) / X_Inc)), Spans, Counts);
               Set_Field (Reply, "burst", Stats_Object (Spans, X_Inc));
               Set_Field (Reply, "burst_pulses", Stats_Object (Counts, 1.0));
            end;
         end if;
         Set_Field (Reply, "thresholds", Levels);
      end;
   end;
end Execute_Timing;
