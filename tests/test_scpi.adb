-- ***************************************************************************
--                      Rigol - SCPI Generation / Parsing Tests
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

--  Exercises the library against Rigol_Transport.Mock: no instrument and
--  no network involved.  Two things are checked here - the exact SCPI text
--  the library emits, and the parsing of instrument replies back into Ada
--  values.
--
--  Build:  make tests
--  Run:    ./bin/test_scpi   (exit status 0 = all passed)

with Ada.Text_IO;           use Ada.Text_IO;
with Ada.Command_Line;

with Rigol_Transport.Mock;
with Rigol;
with Rigol.IEEE488;
with Rigol.Channel;
with Rigol.Acquire;
with Rigol.Timebase;
with Rigol.Trigger;
with Rigol.Waveform;
with Rigol.Measure;
with Rigol.Display;
with Rigol.Math;
with Rigol.Setups;
with Rigol_Transport.Simulator;

procedure Test_SCPI is

   Passed : Natural := 0;
   Failed : Natural := 0;

   T     : aliased Rigol_Transport.Mock.Handle;
   Scope : Rigol.Oscilloscope (T'Access);

   -- -------------------------------------------------------------------------
   --  Assertion helpers
   -- -------------------------------------------------------------------------

   procedure Check (Name : String; Got : String; Want : String) is
   begin
      if Got = Want then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Put_Line ("FAIL  " & Name);
         Put_Line ("        want: [" & Want & "]");
         Put_Line ("        got : [" & Got  & "]");
      end if;
   end Check;

   procedure Check_Float
     (Name      : String;
      Got, Want : Float;
      Tolerance : Float := 1.0e-9)
   is
   begin
      if abs (Got - Want) <= Tolerance then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Put_Line ("FAIL  " & Name);
         Put_Line ("        want: " & Float'Image (Want));
         Put_Line ("        got : " & Float'Image (Got));
      end if;
   end Check_Float;

   procedure Check_Int (Name : String; Got, Want : Integer) is
   begin
      Check (Name, Integer'Image (Got), Integer'Image (Want));
   end Check_Int;

   procedure Check_Bool (Name : String; Got, Want : Boolean) is
   begin
      Check (Name, Boolean'Image (Got), Boolean'Image (Want));
   end Check_Bool;

   --  Run one command and compare the SCPI text it produced.
   --  The mock is cleared first so Last_Command is unambiguous.
   procedure Clear is
   begin
      Rigol_Transport.Mock.Reset (T);
   end Clear;

   function Sent return String is
     (Rigol_Transport.Mock.Last_Command (T));

   procedure Section (Title : String) is
   begin
      Put_Line ("-- " & Title);
   end Section;

begin
   -- =========================================================================
   Section ("Mock transport itself");
   -- =========================================================================

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "first");
   Rigol_Transport.Mock.Push_Response (T, "second");
   Check ("queued response 1", Rigol.Query (Scope, ":A?"), "first");
   Check ("queued response 2", Rigol.Query (Scope, ":B?"), "second");
   Check ("default after queue drained", Rigol.Query (Scope, ":C?"), "0");
   Check_Int ("commands logged", Rigol_Transport.Mock.Command_Count (T), 3);
   Check ("log preserves order",
          Rigol_Transport.Mock.Command (T, 1), ":A?");
   Check ("log records queries too",
          Rigol_Transport.Mock.Command (T, 3), ":C?");

   -- =========================================================================
   Section ("Root acquisition control");
   -- =========================================================================

   Clear; Rigol.Run (Scope);           Check ("Run",           Sent, ":RUN");
   Clear; Rigol.Stop (Scope);          Check ("Stop",          Sent, ":STOP");
   Clear; Rigol.Single (Scope);        Check ("Single",        Sent, ":SINGle");
   Clear; Rigol.Auto_Scale (Scope);    Check ("Auto_Scale",    Sent, ":AUToscale");
   Clear; Rigol.Clear (Scope);         Check ("Clear",         Sent, ":CLEar");
   Clear; Rigol.Force_Trigger (Scope); Check ("Force_Trigger", Sent, ":TFORce");

   -- =========================================================================
   Section ("IEEE 488.2 common commands");
   -- =========================================================================

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "RIGOL TECHNOLOGIES,DS1202Z-E,DS1ZE,00.04.03");
   Check ("Get_IDN reply", Rigol.IEEE488.Get_IDN (Scope),
          "RIGOL TECHNOLOGIES,DS1202Z-E,DS1ZE,00.04.03");
   Check ("Get_IDN command", Sent, "*IDN?");

   Clear; Rigol.IEEE488.Reset (Scope);        Check ("Reset",  Sent, "*RST");
   Clear; Rigol.IEEE488.Clear_Status (Scope); Check ("*CLS",   Sent, "*CLS");
   Clear; Rigol.IEEE488.Wait (Scope);         Check ("*WAI",   Sent, "*WAI");

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "32");
   Check_Int ("Get_ESR parses", Rigol.IEEE488.Get_ESR (Scope), 32);
   Check ("Get_ESR command", Sent, "*ESR?");

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "0");
   Check_Int ("Self_Test parses", Rigol.IEEE488.Self_Test (Scope), 0);

   -- =========================================================================
   Section ("Channel");
   -- =========================================================================

   Clear; Rigol.Channel.Set_Display (Scope, 1, True);
   Check ("Set_Display on", Sent, ":CHANnel1:DISPlay 1");

   Clear; Rigol.Channel.Set_Display (Scope, 2, False);
   Check ("Set_Display off ch2", Sent, ":CHANnel2:DISPlay 0");

   Clear; Rigol.Channel.Set_Coupling (Scope, 1, Rigol.Channel.DC);
   Check ("Set_Coupling DC", Sent, ":CHANnel1:COUPling DC");

   Clear; Rigol.Channel.Set_Coupling (Scope, 2, Rigol.Channel.GND);
   Check ("Set_Coupling GND", Sent, ":CHANnel2:COUPling GND");

   Clear; Rigol.Channel.Set_Invert (Scope, 1, True);
   Check ("Set_Invert", Sent, ":CHANnel1:INVert 1");

   --  Numeric arguments must carry no leading space: Rigol.Image trims
   --  the one that 'Image puts in front of non-negative values.
   Clear; Rigol.Channel.Set_Scale (Scope, 1, 1.0);
   Check ("Set_Scale positive", Sent, ":CHANnel1:SCALe 1.00000E+00");

   Clear; Rigol.Channel.Set_Offset (Scope, 1, -5.0e-1);
   Check ("Set_Offset negative", Sent, ":CHANnel1:OFFSet -5.00000E-01");

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "1");
   Check_Bool ("Get_Display parses 1",
               Rigol.Channel.Get_Display (Scope, 1), True);
   Check ("Get_Display command", Sent, ":CHANnel1:DISPlay?");

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "2.000000e-01");
   Check_Float ("Get_Scale parses",
                Rigol.Channel.Get_Scale (Scope, 1), 0.2, 1.0e-7);

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "AC");
   Check ("Get_Coupling parses AC",
          Rigol.Channel.Coupling_Type'Image
            (Rigol.Channel.Get_Coupling (Scope, 1)),
          "AC");

   -- =========================================================================
   Section ("Timebase");
   -- =========================================================================

   Clear; Rigol.Timebase.Set_Mode (Scope, Rigol.Timebase.XY);
   Check ("Timebase mode XY", Sent, ":TIMebase:MODE XY");

   Clear; Rigol.Timebase.Set_Delay_Enable (Scope, True);
   Check ("Delay enable", Sent, ":TIMebase:DELay:ENABle 1");

   Clear; Rigol.Timebase.Set_Scale (Scope, 1.0e-3);
   Check ("Timebase scale", Sent, ":TIMebase:MAIN:SCALe 1.00000E-03");

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "1.000000e-03");
   Check_Float ("Get_Scale parses",
                Rigol.Timebase.Get_Scale (Scope), 1.0e-3, 1.0e-9);

   -- =========================================================================
   Section ("Acquire");
   -- =========================================================================

   Clear; Rigol.Acquire.Set_Type (Scope, Rigol.Acquire.Averages);
   Check ("Acquire type AVER", Sent, ":ACQuire:TYPE AVERages");

   Clear; Rigol.Acquire.Set_Averages (Scope, 16);
   Check ("Acquire averages", Sent, ":ACQuire:AVERages 16");

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "1.000000e+09");
   Check_Float ("Sample rate parses",
                Rigol.Acquire.Get_Sample_Rate (Scope), 1.0e9, 1.0);

   Clear; Rigol.Acquire.Set_Memory_Depth (Scope, 120_000);
   Check ("Memory depth", Sent, ":ACQuire:MDEPth 120000");

   Clear; Rigol.Acquire.Set_Memory_Depth (Scope, Rigol.Acquire.Auto_Depth);
   Check ("Memory depth auto", Sent, ":ACQuire:MDEPth AUTO");

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "AUTO");
   Check ("Memory depth AUTO reads as 0",
          Rigol.Acquire.Get_Memory_Depth (Scope)'Image, " 0");

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "12000000");
   Check ("Memory depth parses",
          Rigol.Acquire.Get_Memory_Depth (Scope)'Image, " 12000000");

   -- =========================================================================
   Section ("Trigger");
   -- =========================================================================

   Clear; Rigol.Trigger.Set_Mode (Scope, Rigol.Trigger.Edge);
   Check ("Trigger mode EDGE", Sent, ":TRIGger:MODE EDGE");

   Clear; Rigol.Trigger.Set_Sweep (Scope, Rigol.Trigger.Normal);
   Check ("Trigger sweep NORMal", Sent, ":TRIGger:SWEep NORMal");

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "TD");
   Check ("Trigger status parses",
          Rigol.Trigger.Trigger_Status'Image
            (Rigol.Trigger.Get_Status (Scope)),
          "TD");

   -- =========================================================================
   Section ("Waveform setup commands");
   -- =========================================================================

   Clear; Rigol.Waveform.Set_Source (Scope, 2);
   Check ("Waveform source", Sent, ":WAVeform:SOURce CHAN2");

   Clear; Rigol.Waveform.Set_Mode (Scope, Rigol.Waveform.Raw);
   Check ("Waveform mode RAW", Sent, ":WAVeform:MODE RAW");

   Clear; Rigol.Waveform.Set_Format (Scope, Rigol.Waveform.Byte);
   Check ("Waveform format BYTE", Sent, ":WAVeform:FORMat BYTE");

   Clear; Rigol.Waveform.Set_Start (Scope, 1);
   Check ("Waveform start", Sent, ":WAVeform:STARt 1");

   Clear; Rigol.Waveform.Set_Stop (Scope, 1200);
   Check ("Waveform stop", Sent, ":WAVeform:STOP 1200");

   -- =========================================================================
   Section ("Waveform preamble parsing");
   -- =========================================================================

   Clear;
   --  fmt,type,points,count,xinc,xorig,xref,yinc,yorig,yref
   Rigol_Transport.Mock.Push_Response
     (T, "0,0,1200,1,1.000000e-08,-6.000000e-06,0,1.000000e-02,0,127");

   declare
      Pre : constant Rigol.Waveform.Preamble :=
        Rigol.Waveform.Get_Preamble (Scope);
   begin
      Check ("Preamble command", Sent, ":WAVeform:PREamble?");
      Check ("Preamble format",
             Rigol.Waveform.Waveform_Format'Image (Pre.Format), "BYTE");
      Check ("Preamble mode",
             Rigol.Waveform.Waveform_Mode'Image (Pre.Mode), "NORMAL");
      Check_Int   ("Preamble points",      Pre.Points, 1200);
      Check_Int   ("Preamble count",       Pre.Count, 1);
      Check_Float ("Preamble X_Increment", Pre.X_Increment, 1.0e-8, 1.0e-12);
      Check_Float ("Preamble X_Origin",    Pre.X_Origin, -6.0e-6, 1.0e-10);
      Check_Float ("Preamble X_Reference", Pre.X_Reference, 0.0);
      Check_Float ("Preamble Y_Increment", Pre.Y_Increment, 1.0e-2, 1.0e-9);
      Check_Float ("Preamble Y_Origin",    Pre.Y_Origin, 0.0);
      Check_Float ("Preamble Y_Reference", Pre.Y_Reference, 127.0);

      --  Sample_Time: X_Origin + (I - X_Reference) * X_Increment
      Check_Float ("Sample_Time (1)",
                   Rigol.Waveform.Sample_Time (Pre, 1), -6.0e-6 + 1.0e-8,
                   1.0e-12);
      Check_Float ("Sample_Time (101)",
                   Rigol.Waveform.Sample_Time (Pre, 101), -6.0e-6 + 101.0e-8,
                   1.0e-12);
   end;

   -- =========================================================================
   Section ("Waveform data decoding (BYTE)");
   -- =========================================================================

   --  Definite-length block: '#' <digit count> <byte count> <data>.
   --  Here: 1 digit, 4 bytes of payload.
   --  With Y_Reference 127 and Y_Increment 0.01, raw 127 is 0 V.
   --

   Clear;
   declare
      Pre : constant Rigol.Waveform.Preamble :=
        (Format      => Rigol.Waveform.Byte,
         Mode        => Rigol.Waveform.Normal,
         Points      => 4,
         Count       => 1,
         X_Increment => 1.0e-8,
         X_Origin    => 0.0,
         X_Reference => 0.0,
         Y_Increment => 1.0e-2,
         Y_Origin    => 0.0,
         Y_Reference => 127.0);

      Block : constant String :=
        "#14"
        & Character'Val (127)   --   0.00 V
        & Character'Val (137)   --  +0.10 V
        & Character'Val (117)   --  -0.10 V
        & Character'Val (255);  --  +1.28 V
   begin
      Rigol_Transport.Mock.Push_Response (T, Block);

      declare
         Data : constant Rigol.Waveform.Sample_Array :=
           Rigol.Waveform.Get_Data (Scope, Pre);
      begin
         Check ("Get_Data command", Sent, ":WAVeform:DATA?");
         Check_Int   ("Get_Data length", Data'Length, 4);
         Check_Float ("sample 1 (mid-scale)", Data (1),  0.00, 1.0e-6);
         Check_Float ("sample 2 (+10 counts)", Data (2), 0.10, 1.0e-6);
         Check_Float ("sample 3 (-10 counts)", Data (3), -0.10, 1.0e-6);
         Check_Float ("sample 4 (full scale)", Data (4), 1.28, 1.0e-6);
      end;
   end;

   -- =========================================================================
   Section ("Waveform with nothing acquired");
   -- =========================================================================

   --  A single sweep that has not triggered yet reports 0 points.
   Clear;
   Rigol_Transport.Mock.Push_Response
     (T, "0,0,0,1,0.000000,0.000000,0,0.000000,0,0");
   declare
      Pre : constant Rigol.Waveform.Preamble :=
        Rigol.Waveform.Get_Preamble (Scope);
   begin
      Check_Int ("Empty preamble points", Pre.Points, 0);
   end;

   -- =========================================================================
   Section ("Measure");
   -- =========================================================================

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "9.999999E+02");
   declare
      F : constant Float := Rigol.Measure.Frequency (Scope, 1);
   begin
      Check ("Measure query", Sent, ":MEASure:ITEM? FREQ,CHAN1");
      Check_Float ("Frequency value", F, 999.9999, 1.0e-3);
      Check_Bool  ("Frequency valid", Rigol.Measure.Is_Valid (F), True);
   end;

   --  Some items answer with text when they cannot be measured
   Clear;
   Rigol_Transport.Mock.Push_Response (T, "measure error!");
   Check_Bool ("""measure error!"" is invalid",
               Rigol.Measure.Is_Valid (Rigol.Measure.Rise_Time (Scope, 1)),
               False);

   --  9.9E37 is the scope's "cannot measure" answer
   Clear;
   Rigol_Transport.Mock.Push_Response (T, "9.9E37");
   Check_Bool ("9.9E37 is invalid",
               Rigol.Measure.Is_Valid (Rigol.Measure.Frequency (Scope, 1)),
               False);

   -- =========================================================================
   Section ("Waveform data decoding (WORD)");
   -- =========================================================================

   --  WORD: the 8-bit sample in the low byte, least significant first
   Clear;
   declare
      Pre : constant Rigol.Waveform.Preamble :=
        (Format      => Rigol.Waveform.Word,
         Mode        => Rigol.Waveform.Normal,
         Points      => 3,
         Count       => 1,
         X_Increment => 1.0e-8,
         X_Origin    => 0.0,
         X_Reference => 0.0,
         Y_Increment => 1.0e-2,
         Y_Origin    => 0.0,
         Y_Reference => 127.0);
      Z : constant Character := Character'Val (0);
   begin
      Rigol_Transport.Mock.Push_Response
        (T, "#16" & Character'Val (127) & Z & Character'Val (137) & Z &
                    Character'Val (117) & Z);
      declare
         Data : constant Rigol.Waveform.Sample_Array :=
           Rigol.Waveform.Get_Data (Scope, Pre);
      begin
         Check_Int   ("WORD length", Data'Length, 3);
         Check_Float ("WORD sample 1", Data (1),  0.00, 1.0e-6);
         Check_Float ("WORD sample 2", Data (2),  0.10, 1.0e-6);
         Check_Float ("WORD sample 3", Data (3), -0.10, 1.0e-6);
      end;
   end;

   -- =========================================================================
   Section ("Definite-length blocks");
   -- =========================================================================

   Check ("block payload", Rigol.Block_Data ("#15hello"), "hello");
   Check ("block with LF inside",
          Rigol.Block_Data ("#13a" & ASCII.LF & "b"), "a" & ASCII.LF & "b");
   Check ("empty block", Rigol.Block_Data ("#10"), "");
   Check ("bytes after the block ignored",
          Rigol.Block_Data ("#12ab" & ASCII.LF), "ab");

   declare
      procedure Check_Rejects (Name : String; Response : String) is
      begin
         declare
            Data : constant String := Rigol.Block_Data (Response);
         begin
            Check_Bool (Name & " rejected (got """ & Data & """)",
                        False, True);
         end;
      exception
         when Rigol_Transport.Communication_Error =>
            Check_Bool (Name & " rejected", True, True);
      end Check_Rejects;
   begin
      Check_Rejects ("text instead of block", "0,0,1200");
      Check_Rejects ("zero digit count",     "#0");
      Check_Rejects ("truncated length",     "#51200");
      Check_Rejects ("non-digit length",     "#2x5hello");
      Check_Rejects ("truncated payload",    "#15hel");
   end;

   -- =========================================================================
   Section ("Screenshot");
   -- =========================================================================

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "#14BM" & ASCII.LF & "x");
   Check ("Screenshot data", Rigol.Display.Screenshot (Scope),
          "BM" & ASCII.LF & "x");
   Check ("Screenshot command", Sent, ":DISPlay:DATA? ON,OFF,BMP24");

   Clear;
   Rigol_Transport.Mock.Push_Response (T, "#10");
   Check ("Screenshot options",
          Rigol.Display.Screenshot (Scope, Rigol.Display.PNG,
                                    Color => False, Invert => True), "");
   Check ("Screenshot options command", Sent, ":DISPlay:DATA? OFF,ON,PNG");

   -- =========================================================================
   Section ("Memory read in batches");
   -- =========================================================================

   --  600 000 points need three batches: 250 000 + 250 000 + 100 000.
   --  Each batch is 0 V (raw 127) except its last sample, which carries
   --  the batch number as +0.01 V * n, so misplaced batches show up.
   Clear;
   Rigol_Transport.Mock.Push_Response
     (T, "0,2,600000,1,2.000000e-09,-6.000000e-03,0,1.000000e-02,0,127");
   declare
      function Batch (Size : Positive; N : Positive) return String is
         Digits_9 : constant String := Rigol.Image (1_000_000_000 + Size);
      begin
         return "#9" & Digits_9 (2 .. 10) &
                (1 .. Size - 1 => Character'Val (127)) &
                Character'Val (127 + N);
      end Batch;

      use Rigol.Waveform;
      Pre  : Preamble;
      Data : Sample_Array_Access;
   begin
      Rigol_Transport.Mock.Push_Response (T, Batch (250_000, 1));
      Rigol_Transport.Mock.Push_Response (T, Batch (250_000, 2));
      Rigol_Transport.Mock.Push_Response (T, Batch (100_000, 3));

      Read_Memory (Scope, 1, Pre, Data);

      Check_Int   ("Memory points",  Data'Length, 600_000);
      Check_Float ("Batch 1 last",   Data (250_000), 0.01, 1.0e-6);
      Check_Float ("Batch 2 first",  Data (250_001), 0.00, 1.0e-6);
      Check_Float ("Batch 2 last",   Data (500_000), 0.02, 1.0e-6);
      Check_Float ("Batch 3 last",   Data (600_000), 0.03, 1.0e-6);
      Free (Data);
      Check_Bool  ("Free nulls the access", Data = null, True);

      Check ("Memory cmd 1",  Rigol_Transport.Mock.Command (T, 1),
             ":STOP");
      Check ("Memory cmd 3",  Rigol_Transport.Mock.Command (T, 3),
             ":WAVeform:MODE RAW");
      Check ("Memory cmd 6",  Rigol_Transport.Mock.Command (T, 6),
             ":WAVeform:STARt 1");
      Check ("Memory cmd 7",  Rigol_Transport.Mock.Command (T, 7),
             ":WAVeform:STOP 250000");
      Check ("Memory cmd 9",  Rigol_Transport.Mock.Command (T, 9),
             ":WAVeform:STARt 250001");
      Check ("Memory cmd 13", Rigol_Transport.Mock.Command (T, 13),
             ":WAVeform:STOP 600000");
      Check_Int ("Memory command count",
                 Rigol_Transport.Mock.Command_Count (T), 14);
   end;

   --  A batch shorter than requested is an error, not silent zeros
   Clear;
   Rigol_Transport.Mock.Push_Response
     (T, "0,2,1000,1,2.000000e-09,0.0,0,1.000000e-02,0,127");
   Rigol_Transport.Mock.Push_Response (T, "#3999" & (1 .. 999 => 'x'));
   declare
      use Rigol.Waveform;
      Pre  : Preamble;
      Data : Sample_Array_Access;
   begin
      Read_Memory (Scope, 1, Pre, Data);
      Check_Bool ("Short batch rejected", False, True);
   exception
      when Rigol_Transport.Communication_Error =>
         Check_Bool ("Short batch rejected", True, True);
   end;

   -- =========================================================================
   Section ("Simulator, through the library");
   -- =========================================================================

   declare
      use Rigol.Waveform;
      Sim    : aliased Rigol_Transport.Simulator.Handle;
      Scope2 : Rigol.Oscilloscope (Sim'Access);
      Pre    : Preamble;
      Calls  : Natural := 0;
      Last_Done : Natural := 0;

      procedure Count (Done, Total : Natural) is
      begin
         Calls := Calls + 1;
         Last_Done := Done;
         pragma Unreferenced (Total);
      end Count;
   begin
      Rigol_Transport.Simulator.Open (Sim);
      Check ("Sim IDN", Rigol.IEEE488.Get_IDN (Scope2),
             "RIGOL TECHNOLOGIES,DS1202Z-E,SIMULATED,00.06.04");

      Rigol.Channel.Set_Scale (Scope2, 1, 0.5);
      Check_Float ("Sim scale round trip",
                   Rigol.Channel.Get_Scale (Scope2, 1), 0.5, 1.0e-6);
      --  Back to 1 V/div: at 0.5 V/div the 3 V level is off screen and
      --  clips, as on the real scope
      Rigol.Channel.Set_Scale (Scope2, 1, 1.0);
      Rigol.Trigger.Set_Edge_Slope (Scope2, Rigol.Trigger.Falling);
      Check ("Sim trigger slope",
             Rigol.Trigger.Edge_Slope'Image
               (Rigol.Trigger.Get_Edge_Slope (Scope2)), "FALLING");
      Rigol.Trigger.Set_Edge_Source (Scope2, Rigol.Trigger.CH2);
      Check ("Sim trigger source",
             Rigol.Trigger.Trigger_Source'Image
               (Rigol.Trigger.Get_Edge_Source (Scope2)), "CH2");
      Rigol.Trigger.Set_Edge_Level (Scope2, 0.25);
      Check_Float ("Sim trigger level",
                   Rigol.Trigger.Get_Edge_Level (Scope2), 0.25, 1.0e-6);

      declare
         Data : constant Raw_Array := Read_Screen_Raw (Scope2, 1, Pre);
         Lo   : Float := Float'Last;
         Hi   : Float := Float'First;
      begin
         Check_Int ("Sim screen points", Data'Length, 1200);
         for R of Data loop
            Lo := Float'Min (Lo, Volts (Pre, R));
            Hi := Float'Max (Hi, Volts (Pre, R));
         end loop;
         Check_Float ("Sim CH1 low",  Lo, 0.0, 0.05);
         Check_Float ("Sim CH1 high", Hi, 3.0, 0.05);
      end;

      declare
         Mem : Raw_Array_Access;
      begin
         Read_Memory_Raw (Scope2, 1, Pre, Mem, Count'Access);
         Check_Int ("Sim memory points", Mem'Length,
                    Rigol_Transport.Simulator.Memory_Depth);
         Check_Int ("Sim progress calls", Calls, 5);   --  1.2M / 250k
         Check_Int ("Sim progress final", Last_Done,
                    Rigol_Transport.Simulator.Memory_Depth);
         Free (Mem);
      end;
      --  A memory read leaves STARt/STOP at its last batch; screen reads
      --  must reset them (on the real scope this once returned 1 point)
      declare
         Data : constant Raw_Array := Read_Screen_Raw (Scope2, 1, Pre);
      begin
         Check_Int ("Sim screen after memory read", Data'Length, 1200);
      end;
      Check_Int ("Sim Capture after memory read",
                 Rigol.Waveform.Capture (Scope2, 1)'Length, 1200);

      Check ("Sim stopped by memory read",
             Rigol.Trigger.Trigger_Status'Image
               (Rigol.Trigger.Get_Status (Scope2)), "STOP");

      Check_Float ("Sim CH1 frequency",
                   Rigol.Measure.Frequency (Scope2, 1), 1000.0, 1.0e-3);
      Check_Bool  ("Sim CH2 hidden: invalid",
                   Rigol.Measure.Is_Valid (Rigol.Measure.VPP (Scope2, 2)),
                   False);

      declare
         Image : constant String := Rigol.Display.Screenshot (Scope2);
      begin
         Check_Int ("Sim screenshot size", Image'Length, 1_152_054);
         Check ("Sim screenshot is BMP", Image (Image'First .. Image'First + 1),
                "BM");
      end;

      begin
         declare
            R : constant String := Rigol.Query (Scope2, ":NOSuch:THING?");
         begin
            Check_Bool ("Sim unknown query raises (got " & R & ")",
                        False, True);
         end;
      exception
         when Rigol_Transport.Communication_Error =>
            Check_Bool ("Sim unknown query raises", True, True);
      end;
   end;

   -- =========================================================================
   Section ("Math channel, on the simulator");
   -- =========================================================================

   declare
      use Rigol.Waveform;
      Sim    : aliased Rigol_Transport.Simulator.Handle;
      Scope3 : Rigol.Oscilloscope (Sim'Access);
      Pre    : Preamble;
   begin
      Rigol_Transport.Simulator.Open (Sim);
      Rigol.Math.Set_Display  (Scope3, True);
      Rigol.Math.Set_Operator (Scope3, Rigol.Math.Add);
      Rigol.Math.Set_Source1  (Scope3, Rigol.Math.CH1);
      Rigol.Math.Set_Source2  (Scope3, Rigol.Math.CH2);
      Check ("Math operator", Rigol.Math.Operator'Image
               (Rigol.Math.Get_Operator (Scope3)), "ADD");
      Check ("Math source 2", Rigol.Math.Source'Image
               (Rigol.Math.Get_Source2 (Scope3)), "CH2");
      Rigol.Math.Set_Scale (Scope3, 2.0);
      Check_Float ("Math scale", Rigol.Math.Get_Scale (Scope3), 2.0, 1.0E-6);

      Prepare_Math_Read (Scope3);
      --  Right after the operator changed there is no data yet
      Check_Int ("Math settling", Read_Prepared_Screen (Scope3, Pre)'Length, 0);
      Check_Int ("Math settling", Read_Prepared_Screen (Scope3, Pre)'Length, 0);
      declare
         Data : constant Raw_Array := Read_Prepared_Screen (Scope3, Pre);
         Lo   : Float := Float'Last;
         Hi   : Float := Float'First;
      begin
         Check_Int ("Math A+B points", Data'Length, 1200);
         for R of Data loop
            Lo := Float'Min (Lo, Volts (Pre, R));
            Hi := Float'Max (Hi, Volts (Pre, R));
         end loop;
         --  0 .. 3 V square plus 1 V sine
         Check_Float ("Math A+B low",  Lo, -1.0, 0.1);
         Check_Float ("Math A+B high", Hi,  4.0, 0.1);
      end;

      Rigol.Math.Set_Operator   (Scope3, Rigol.Math.FFT);
      Rigol.Math.Set_FFT_Source (Scope3, Rigol.Math.CH1);
      Rigol.Math.Set_FFT_Window (Scope3, Rigol.Math.Hanning);
      Check ("FFT window", Rigol.Math.FFT_Window'Image
               (Rigol.Math.Get_FFT_Window (Scope3)), "HANNING");
      Rigol.Math.Set_FFT_HScale  (Scope3, 2500.0);
      Rigol.Math.Set_FFT_HCenter (Scope3, 10_000.0);
      declare
         Dummy : Raw_Array := Read_Prepared_Screen (Scope3, Pre);
      begin
         Dummy := Read_Prepared_Screen (Scope3, Pre);
      end;
      declare
         --  Screen -5 .. 25 kHz: data from 0 Hz, 25 Hz per point
         Data  : constant Raw_Array := Read_Prepared_Screen (Scope3, Pre);
         Best  : Positive := Data'First + 1;
      begin
         Check_Int   ("FFT points (0 .. 25 kHz)", Data'Length, 1000);
         Check_Float ("FFT Hz per point", Pre.X_Increment, 25.0, 1.0E-3);
         Check_Float ("FFT x origin (screen edge)", Pre.X_Origin, -5000.0, 1.0E-3);
         for I in Data'First + 1 .. Data'Last loop
            if Data (I) > Data (Best) then
               Best := I;
            end if;
         end loop;
         --  Strongest non-DC line: the 1 kHz fundamental, 2.6 dBV
         Check_Float ("FFT peak frequency",
                      Float (Best - Data'First) * Pre.X_Increment, 1000.0, 25.0);
         Check_Float ("FFT peak level", Volts (Pre, Data (Best)), 2.6, 0.5);
      end;
   end;

   -- =========================================================================
   Section ("Pulse and slope triggers, setups, on the simulator");
   -- =========================================================================

   declare
      use Rigol.Trigger;
      Sim    : aliased Rigol_Transport.Simulator.Handle;
      Scope4 : Rigol.Oscilloscope (Sim'Access);
   begin
      Rigol_Transport.Simulator.Open (Sim);
      Set_Mode (Scope4, Pulse);
      Set_Pulse_When (Scope4, Neg_Less);
      Set_Pulse_Width (Scope4, 3.0E-4);
      Check ("Trigger mode", Trigger_Mode'Image (Get_Mode (Scope4)), "PULSE");
      Check ("Pulse when", Pulse_When'Image (Get_Pulse_When (Scope4)), "NEG_LESS");
      Check_Float ("Pulse width", Get_Pulse_Width (Scope4), 3.0E-4, 1.0E-9);

      --  Lower is kept below upper: set upper, lower, upper to widen
      Set_Pulse_Lower (Scope4, 1.0E-4);
      Check_Bool ("Pulse lower clamped below old upper",
                  Get_Pulse_Lower (Scope4) < 2.0E-6, True);
      Set_Pulse_Upper (Scope4, 8.0E-4);
      Set_Pulse_Lower (Scope4, 1.0E-4);
      Set_Pulse_Upper (Scope4, 8.0E-4);
      Check_Float ("Pulse range lower", Get_Pulse_Lower (Scope4), 1.0E-4, 1.0E-9);
      Check_Float ("Pulse range upper", Get_Pulse_Upper (Scope4), 8.0E-4, 1.0E-9);

      Set_Mode (Scope4, Slope);
      Set_Slope_When (Scope4, Pos_In_Range);
      Set_Slope_Window (Scope4, Both);
      Set_Slope_Level_A (Scope4, 2.5);
      Check ("Slope when", Slope_When'Image (Get_Slope_When (Scope4)), "POS_IN_RANGE");
      Check ("Slope window", Slope_Window'Image (Get_Slope_Window (Scope4)), "BOTH");
      Check_Float ("Slope level A", Get_Slope_Level_A (Scope4), 2.5, 1.0E-6);

      declare
         Saved : constant String := Rigol.Setups.Save (Scope4);
      begin
         Rigol.Timebase.Set_Scale (Scope4, 5.0E-3);
         Rigol.Channel.Set_Scale (Scope4, 1, 2.0);
         Set_Mode (Scope4, Edge);
         Rigol.Setups.Restore (Scope4, Saved);
         Check_Float ("Setup restores timebase",
                      Rigol.Timebase.Get_Scale (Scope4), 1.0E-3, 1.0E-9);
         --  Like the DS1202Z-E, only some settings come back from the
         --  scope's block (scopebridge-server restores the rest itself)
         Check_Float ("Setup leaves CH1 scale",
                      Rigol.Channel.Get_Scale (Scope4, 1), 2.0, 1.0E-6);
      end;
   end;

   -- =========================================================================
   New_Line;
   Put_Line ("passed:" & Natural'Image (Passed) &
             "   failed:" & Natural'Image (Failed));

   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Test_SCPI;
