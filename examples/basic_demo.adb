-- ***************************************************************************
--                      Rigol - Basic Demo
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

--  Basic demonstration of the Rigol DS1000Z-E Ada interface.
--
--  Set up for the scope's own probe-compensation output: connect the
--  CH1 probe tip to the calibration terminal (1 kHz, 3 V square wave)
--  and its ground clip to the ground terminal.  Set Probe_Ratio below
--  to match the switch on your probe.
--
--  Connects via USB-TMC (/dev/usbtmc0 unless another device node is
--  given on the command line), identifies the scope,
--  configures CH1, takes an edge trigger, captures a waveform and
--  prints the first 10 samples with their timestamps.
--
--  Build:  make demo
--  Run:    ./bin/basic_demo [device]      e.g. ./bin/basic_demo /dev/usbtmc4

with Ada.Text_IO;       use Ada.Text_IO;
with Ada.Command_Line;  use Ada.Command_Line;
with Ada.Exceptions;
with Ada.Float_Text_IO;

with Rigol_Transport.USBTMC;
with Rigol;
with Rigol.IEEE488;
with Rigol.Channel;
with Rigol.Acquire;
with Rigol.Timebase;
with Rigol.Trigger;
with Rigol.Measure;
with Rigol.Waveform;

procedure Basic_Demo is

   Transport : aliased Rigol_Transport.USBTMC.Handle;
   Scope     : Rigol.Oscilloscope (Transport'Access);

   --  Must match the probe's attenuation switch, or all voltages will be
   --  off by the ratio between the two.
   Probe_Ratio : constant Rigol.Channel.Probe_Ratio := Rigol.Channel.X1;

   Device : constant String :=
     (if Argument_Count >= 1 then Argument (1) else "/dev/usbtmc0");

   use Rigol.Channel;
   use Rigol.Trigger;

   procedure Put_Measurement (Name : String; Value : Float; Unit : String) is
   begin
      Put (Name & (Name'Length + 1 .. 10 => ' ') & ": ");
      if Rigol.Measure.Is_Valid (Value) then
         Ada.Float_Text_IO.Put (Value, Fore => 8, Aft => 4, Exp => 0);
         Put_Line (" " & Unit);
      else
         Put_Line ("(no valid reading)");
      end if;
   end Put_Measurement;

begin
   --  1. Open transport (Scope is already bound to it by discriminant)
   Put_Line ("Opening " & Device & " ...");
   Rigol_Transport.USBTMC.Open (Transport, Device);

   --  3. Identify instrument
   Put_Line ("IDN: " & Rigol.IEEE488.Get_IDN (Scope));

   --  4. Reset to known state
   Rigol.IEEE488.Reset (Scope);
   Rigol.IEEE488.Clear_Status (Scope);

   --  5. Configure CH1
   Set_Display  (Scope, 1, True);
   Set_Coupling (Scope, 1, DC);
   Set_Probe    (Scope, 1, Probe_Ratio);
   Set_Scale    (Scope, 1, 1.0);   --  1 V/div
   Set_Offset   (Scope, 1, 0.0);

   --  6. Timebase: 1 ms/div
   Rigol.Timebase.Set_Scale  (Scope, 1.0e-3);
   Rigol.Timebase.Set_Offset (Scope, 0.0);

   --  7. Acquisition: normal mode
   Rigol.Acquire.Set_Type (Scope, Rigol.Acquire.Normal);

   --  8. Trigger: rising edge on CH1 at 1.5 V, halfway up the 3 V
   --     calibration square wave
   Set_Mode       (Scope, Edge);
   Set_Sweep      (Scope, Normal);
   Set_Edge_Source (Scope, CH1);
   Set_Edge_Slope  (Scope, Rising);
   Set_Edge_Level  (Scope, 1.5);

   --  9. Single acquisition
   Rigol.Single (Scope);
   Put_Line ("Waiting for trigger ...");
   delay 2.0;

   --  10. Print basic measurements
   Put_Measurement ("Frequency", Rigol.Measure.Frequency (Scope, 1), "Hz");
   Put_Measurement ("VPP",       Rigol.Measure.VPP (Scope, 1),       "V");
   Put_Measurement ("VRMS",      Rigol.Measure.VRMS (Scope, 1),      "V");

   --  11. Capture waveform from CH1
   Put_Line ("Capturing waveform ...");
   declare
      Data : constant Rigol.Waveform.Sample_Array :=
        Rigol.Waveform.Capture (Scope, 1);
      Pre  : constant Rigol.Waveform.Preamble :=
        Rigol.Waveform.Get_Preamble (Scope);
   begin
      if Pre.Points = 0 then
         Put_Line ("No waveform acquired (the scope did not trigger)");
      end if;
      Put_Line ("Points : " & Natural'Image (Pre.Points));
      Put_Line ("dt     : " & Float'Image (Pre.X_Increment) & " s");
      New_Line;
      Put_Line ("  Sample        Time (s)        Voltage (V)");
      Put_Line ("  ------  -----------------  ----------------");

      for I in Data'First .. Integer'Min (Data'First + 9, Data'Last) loop
         Put ("  ");
         Ada.Float_Text_IO.Put (Float (I), Fore => 6, Aft => 0, Exp => 0);
         Put ("  ");
         Ada.Float_Text_IO.Put (Rigol.Waveform.Sample_Time (Pre, I),
                                Fore => 10, Aft => 6, Exp => 0);
         Put ("  ");
         Ada.Float_Text_IO.Put (Data (I), Fore => 8, Aft => 6, Exp => 0);
         New_Line;
      end loop;
   end;

   --  12. Leave scope running
   Rigol.Run (Scope);
   Rigol.Disconnect (Scope);
   Put_Line ("Done.");

exception
   when Rigol_Transport.Device_Error =>
      Put_Line ("ERROR: Could not open " & Device);
      Put_Line ("  - Is the oscilloscope connected and powered on?");
      Put_Line ("  - Do you have read/write permission on " & Device & "?");
      Put_Line ("    (try: sudo chmod a+rw " & Device & ")");
   when Rigol.Not_Connected =>
      Put_Line ("ERROR: Oscilloscope disconnected unexpectedly");
   when E : Rigol_Transport.Communication_Error =>
      Put_Line ("ERROR: Communication failure: " &
                Ada.Exceptions.Exception_Message (E));
end Basic_Demo;
