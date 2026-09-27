-- ***************************************************************************
--                  ScopeBridge Server - Capture Requests
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

--  The acquisition memory: capture, and view, spectrum, math_view and
--  samples of what was captured.

separate (Server.Session.Run)
procedure Execute_Captures
  (Cmd     : String;
   Request : JSON_Value;
   Reply   : JSON_Value;
   Payload : in out Unbounded_String;
   Binary  : in out Boolean;
   Done    : out Boolean)
is
begin
   Done := True;
   if Cmd = "capture" then
      declare
         Ch : constant Channel := Channel_Field (Request);

         procedure Progress (Done, Total : Natural) is
            Event : constant JSON_Value := Object ("event", "progress");
         begin
            Set_Field (Event, "done", Done);
            Set_Field (Event, "total", Total);
            Send (Event);
         end Progress;
      begin
         Clients (Current).Live := False;
         Forget_Waveform_Settings;   --  the memory read changes them
         Free (Captures (Ch).Data);
         Free (Cached (Ch).Bins);
         Read_Memory_Raw
           (Scope, Ch, Captures (Ch).Pre, Captures (Ch).Data,
            Progress'Access);
         Set_Field (Reply, "ch", Integer (Ch));
         Add_Waveform (Reply, Captures (Ch).Pre, Captures (Ch).Data'Length);
      end;

   elsif Cmd = "view" then
      declare
         C       : constant Capture := Captured (Channel_Field (Request));
         First   : Natural;
         Last    : Natural;
         Columns : constant Integer := Integer_Field (Request, "columns");
      begin
         Range_Fields (Request, C.Data'Length, First, Last);
         if Columns not in 1 .. Max_Columns then
            raise Request_Error
              with """columns"" must be 1 .." & Max_Columns'Image;
         end if;
         declare
            N     : constant Long_Long_Integer :=
              Long_Long_Integer (Last - First + 1);
            Cols  : constant Positive :=
              Positive (Long_Long_Integer'Min (N, Long_Long_Integer (Columns)));
            Bytes : String (1 .. 2 * Cols);
            Lo, Hi : Raw_Sample;
            From, To : Positive;
         begin
            for Col in 0 .. Cols - 1 loop
               --  Samples of this column, as 1-based indices of Data
               From := C.Data'First + First + Natural
                 (Long_Long_Integer (Col) * N / Long_Long_Integer (Cols));
               To   := C.Data'First + First - 1 + Natural
                 ((Long_Long_Integer (Col) + 1) * N /
                    Long_Long_Integer (Cols));
               Lo := Raw_Sample'Last;
               Hi := Raw_Sample'First;
               for I in From .. To loop
                  Lo := Raw_Sample'Min (Lo, C.Data (I));
                  Hi := Raw_Sample'Max (Hi, C.Data (I));
               end loop;
               Bytes (2 * Col + 1) := Character'Val (Lo);
               Bytes (2 * Col + 2) := Character'Val (Hi);
            end loop;
            Set_Field (Reply, "columns", Cols);
            Payload := To_Unbounded_String (Bytes);
            Binary  := True;
         end;
      end;

   elsif Cmd = "spectrum" then
      declare
         Ch     : constant Channel := Channel_Field (Request);
         C      : constant Capture := Captured (Ch);
         First  : Natural := 0;
         Last   : Natural := C.Data'Length - 1;
         Window : constant Window_Kind :=
           (if Has_Field (Request, "window") then Window_Field (Request)
            else Hann);
         Res    : constant String :=
           (if Has_Field (Request, "resolution")
            then String_Field (Request, "resolution") else "fine");
         Wide   : constant Boolean := Res = "wide";
      begin
         if Res not in "fine" | "wide" then
            raise Request_Error with """resolution"" must be ""fine"" or ""wide""";
         end if;
         if Has_Field (Request, "first") or else Has_Field (Request, "last")
         then
            Range_Fields (Request, C.Data'Length, First, Last);
         end if;
         if Last - First + 1 < Min_Length then
            raise Request_Error
              with "need at least" & Min_Length'Image & " samples";
         end if;

         --  Transform, unless this range and window are cached
         declare
            K : Spectrum_Cache renames Cached (Ch);
         begin
            if K.Bins = null or else K.First /= First or else K.Last /= Last
              or else K.Window /= Window or else K.Wide /= Wide
            then
               Free (K.Bins);
               declare
                  Length : constant Positive := Last - First + 1;

                  function Sample (I : Natural) return Long_Float is
                    (Long_Float (Volts (C.Pre, C.Data (C.Data'First + First + I))));

                  --  Fine: the whole range in one transform, after
                  --  averaging blocks of D samples so it fits; the
                  --  resolution is then about 1 / duration
                  D : constant Positive :=
                    (if Wide then 1
                     else (Length + Max_Segment - 1) / Max_Segment);

                  function Average (I : Natural) return Long_Float is
                     Sum : Long_Float := 0.0;
                  begin
                     for J in I * D .. I * D + D - 1 loop
                        Sum := Sum + Sample (J);
                     end loop;
                     return Sum / Long_Float (D);
                  end Average;
               begin
                  K.Bins := new Real_Array'
                    (if Wide
                     then Compute (Length, Sample'Access,
                                   Long_Float (C.Pre.X_Increment), Window,
                                   K.Bin_Width)
                     else Compute (Length / D, Average'Access,
                                   Long_Float (C.Pre.X_Increment) * Long_Float (D),
                                   Window, K.Bin_Width, Whole => True));
                  K.Decimation := D;
                  --  Zero padding makes the bins finer than what the
                  --  data resolves: that is 1 / duration
                  K.Resolution :=
                    (if Wide then K.Bin_Width
                     else 1.0 / (Long_Float ((Length / D) * D)
                                 * Long_Float (C.Pre.X_Increment)));
               end;
               K.First  := First;
               K.Last   := Last;
               K.Window := Window;
               K.Wide   := Wide;
            end if;
         end;

         declare
            K        : Spectrum_Cache renames Cached (Ch);
            Nyquist  : constant Long_Float :=
              Long_Float (K.Bins'Last) * K.Bin_Width;
            F_Min    : constant Long_Float :=
              (if Has_Field (Request, "f_min")
               then Long_Float (Number_Field (Request, "f_min")) else 0.0);
            F_Max    : constant Long_Float :=
              (if Has_Field (Request, "f_max")
               then Long_Float (Number_Field (Request, "f_max")) else Nyquist);
            K0       : constant Natural := Natural'Min
              (K.Bins'Last, Natural (Long_Float'Ceiling
                 (Long_Float'Max (0.0, F_Min) / K.Bin_Width)));
            K1       : constant Natural := Natural'Max
              (K0, Natural'Min (K.Bins'Last, Natural (Long_Float'Floor
                 (Long_Float'Max (0.0, F_Max) / K.Bin_Width))));
            N        : constant Positive := K1 - K0 + 1;
            Columns  : constant Integer :=
              (if Has_Field (Request, "columns")
               then Integer_Field (Request, "columns") else N);
         begin
            if F_Max < F_Min then
               raise Request_Error with "need f_min <= f_max";
            elsif Columns not in 1 .. Max_Columns
              and then Has_Field (Request, "columns")
            then
               raise Request_Error
                 with """columns"" must be 1 .." & Max_Columns'Image;
            end if;
            Set_Field (Reply, "ch", Integer (Ch));
            Set_Field (Reply, "resolution", (if K.Wide then "wide" else "fine"));
            Set_Field (Reply, "decimation", K.Decimation);
            if Columns >= N then
               Add_Spectrum (Reply, N, Long_Float (K0) * K.Bin_Width,
                             K.Bin_Width, K.Resolution, "dBV",
                             Window_Name (Window));
               Payload := To_Unbounded_String
                 (To_Float32_Bytes (K.Bins (K0 .. K1)));
            else
               --  The highest bin per column, so peaks never vanish
               declare
                  Reduced : Real_Array (0 .. Columns - 1);
                  From, To : Natural;
               begin
                  for Col in Reduced'Range loop
                     From := K0 + Natural (Long_Long_Integer (Col) *
                               Long_Long_Integer (N) / Long_Long_Integer (Columns));
                     To   := K0 + Natural ((Long_Long_Integer (Col) + 1) *
                               Long_Long_Integer (N) / Long_Long_Integer (Columns)) - 1;
                     Reduced (Col) := Min_dBV;
                     for B in From .. Natural'Max (From, To) loop
                        Reduced (Col) := Long_Float'Max (Reduced (Col), K.Bins (B));
                     end loop;
                  end loop;
                  Add_Spectrum (Reply, Columns, Long_Float (K0) * K.Bin_Width,
                                Long_Float (N) * K.Bin_Width / Long_Float (Columns),
                                K.Resolution, "dBV", Window_Name (Window));
                  Payload := To_Unbounded_String (To_Float32_Bytes (Reduced));
               end;
            end if;
            Binary := True;
         end;
      end;

   elsif Cmd = "math_view" then
      declare
         Op      : constant Math_Op := Math_Field (Request, "operator");
         A       : constant Capture := Captured (1);
         B       : constant Capture := Captured (2);
         First   : Natural;
         Last    : Natural;
         Columns : constant Integer := Integer_Field (Request, "columns");
      begin
         if A.Data'Length /= B.Data'Length then
            raise Request_Error
              with "the two captures differ in length; capture both again";
         end if;
         Range_Fields (Request, A.Data'Length, First, Last);
         if Columns not in 1 .. Max_Columns then
            raise Request_Error
              with """columns"" must be 1 .." & Max_Columns'Image;
         end if;
         declare
            N      : constant Long_Long_Integer := Long_Long_Integer (Last - First + 1);
            Cols   : constant Positive :=
              Positive (Long_Long_Integer'Min (N, Long_Long_Integer (Columns)));
            Pairs  : Real_Array (0 .. 2 * Cols - 1);
            From, To : Natural;
            V      : Long_Float;
         begin
            for Col in 0 .. Cols - 1 loop
               From := First + Natural (Long_Long_Integer (Col) * N / Long_Long_Integer (Cols));
               To   := First + Natural ((Long_Long_Integer (Col) + 1) * N /
                                        Long_Long_Integer (Cols)) - 1;
               Pairs (2 * Col)     := Long_Float'Last;
               Pairs (2 * Col + 1) := Long_Float'First;
               for I in From .. To loop
                  V := Apply (Op,
                              Long_Float (Volts (A.Pre, A.Data (A.Data'First + I))),
                              Long_Float (Volts (B.Pre, B.Data (B.Data'First + I))));
                  Pairs (2 * Col)     := Long_Float'Min (Pairs (2 * Col), V);
                  Pairs (2 * Col + 1) := Long_Float'Max (Pairs (2 * Col + 1), V);
               end loop;
            end loop;
            Set_Field (Reply, "columns", Cols);
            Set_Field (Reply, "unit", Math_Unit (Op));
            Payload := To_Unbounded_String (To_Float32_Bytes (Pairs));
            Binary  := True;
         end;
      end;

   elsif Cmd = "samples" then
      declare
         C     : constant Capture := Captured (Channel_Field (Request));
         First : Natural;
         Last  : Natural;
      begin
         Range_Fields (Request, C.Data'Length, First, Last);
         if Last - First + 1 > Max_Samples then
            raise Request_Error
              with "at most" & Max_Samples'Image & " samples per request";
         end if;
         Payload := To_Unbounded_String
           (To_Bytes (C.Data (C.Data'First + First ..
                              C.Data'First + Last)));
         Binary := True;
      end;

   else
      Done := False;
   end if;
end Execute_Captures;
