-- ***************************************************************************
--                      Rigol - Capture Demo
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

--  Saves a screenshot and reads the whole acquisition memory of CH1,
--  reporting size, timing and a summary of the samples.  Works on
--  whatever the scope is currently showing; no settings are changed
--  except that acquisition is stopped for the memory read and restarted
--  afterwards.
--
--  Build:  make capture_demo
--  Run:    ./bin/capture_demo [device] [image]
--          defaults: /dev/usbtmc0  screen.bmp

with Ada.Text_IO;       use Ada.Text_IO;
with Ada.Command_Line;  use Ada.Command_Line;
with Ada.Calendar;      use Ada.Calendar;
with Ada.Exceptions;

with Rigol_Transport.USBTMC;
with Rigol;
with Rigol.IEEE488;
with Rigol.Display;
with Rigol.Waveform;

procedure Capture_Demo is

   Transport : aliased Rigol_Transport.USBTMC.Handle;
   Scope     : Rigol.Oscilloscope (Transport'Access);

   Device : constant String :=
     (if Argument_Count >= 1 then Argument (1) else "/dev/usbtmc0");
   Image  : constant String :=
     (if Argument_Count >= 2 then Argument (2) else "screen.bmp");

   function Seconds_Since (Start : Time) return String is
      D : constant Duration := Clock - Start;
   begin
      return Duration'Image (D) & " s";
   end Seconds_Since;

   Start : Time;

begin
   Rigol_Transport.USBTMC.Open (Transport, Device);

   --  The scope may take a few seconds to render the image before the
   --  first byte arrives; the driver's 5 s default is too tight.
   Rigol_Transport.USBTMC.Set_Timeout (Transport, 15.0);
   Put_Line ("IDN: " & Rigol.IEEE488.Get_IDN (Scope));

   --  1. Screenshot
   Start := Clock;
   Rigol.Display.Save_Screenshot (Scope, Image);
   Put_Line ("Screenshot saved to " & Image & " in" & Seconds_Since (Start));

   --  2. Whole acquisition memory of CH1
   declare
      use Rigol.Waveform;
      Pre   : Preamble;
      Data  : Sample_Array_Access;
      Min_V : Float := Float'Last;
      Max_V : Float := Float'First;
      Edges : Natural := 0;
      Low, High : Float;
      Is_High   : Boolean;
   begin
      Start := Clock;
      Read_Memory (Scope, 1, Pre, Data);
      Put_Line ("Memory read:" & Natural'Image (Data'Length) &
                " points in" & Seconds_Since (Start));
      Put_Line ("Sample rate:" & Float'Image (1.0 / Pre.X_Increment) &
                " Sa/s, record length" &
                Float'Image (Float (Data'Length) * Pre.X_Increment) & " s");

      for V of Data.all loop
         Min_V := Float'Min (Min_V, V);
         Max_V := Float'Max (Max_V, V);
      end loop;

      --  Count edges with hysteresis: at 500 MSa/s the noise on a single
      --  edge crosses any one threshold several times.
      Low     := Min_V + 0.25 * (Max_V - Min_V);
      High    := Min_V + 0.75 * (Max_V - Min_V);
      Is_High := Data (Data'First) > High;
      for V of Data.all loop
         if (Is_High and then V < Low) or else (not Is_High and then V > High)
         then
            Is_High := not Is_High;
            Edges   := Edges + 1;
         end if;
      end loop;

      Put_Line ("Min / max  :" & Float'Image (Min_V) & " V /" &
                Float'Image (Max_V) & " V");
      Put_Line ("Edges      :" & Natural'Image (Edges));
      Free (Data);
   end;

   Rigol.Run (Scope);
   Rigol.Disconnect (Scope);

exception
   when E : others =>
      Put_Line ("ERROR: " & Ada.Exceptions.Exception_Name (E) & ": " &
                Ada.Exceptions.Exception_Message (E));
      Set_Exit_Status (Failure);
end Capture_Demo;
