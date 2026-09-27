-- ***************************************************************************
--                      Rigol - LAN Demo
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

--  Exercises the LAN transport.  Read-only: it identifies the instrument
--  and reads back a few settings, and never issues *RST or changes state.
--
--  Build:  make lan_demo
--  Run:    ./bin/lan_demo [host] [port]      (default 192.168.1.100 5555)
--
--  It can be pointed at a stand-in rather than real hardware, which is the
--  easiest way to exercise the socket path with no instrument present:
--
--    socat TCP-LISTEN:5555,reuseaddr,fork \
--      SYSTEM:'while read -r c; do case "$c" in
--                *IDN*) echo "RIGOL,DS1202Z-E,FAKE,00.04";;
--                *)     echo "0";; esac; done'
--
--    ./bin/lan_demo 127.0.0.1 5555

with Ada.Text_IO;       use Ada.Text_IO;
with Ada.Command_Line;  use Ada.Command_Line;
with GNAT.Sockets;

with Rigol_Transport.LAN;
with Rigol;
with Rigol.IEEE488;
with Rigol.Channel;
with Rigol.Timebase;
with Rigol.Acquire;

procedure LAN_Demo is

   Default_Host : constant String := "192.168.1.100";

   Transport : aliased Rigol_Transport.LAN.Handle;
   Scope     : Rigol.Oscilloscope (Transport'Access);

   function Host return String is
     (if Argument_Count >= 1 then Argument (1) else Default_Host);

   function Port return GNAT.Sockets.Port_Type is
   begin
      if Argument_Count >= 2 then
         return GNAT.Sockets.Port_Type'Value (Argument (2));
      end if;
      return Rigol_Transport.LAN.Default_Port;
   end Port;

begin
   Put_Line ("Connecting to " & Host & ":" &
             GNAT.Sockets.Port_Type'Image (Port) & " ...");

   Rigol_Transport.LAN.Open (Transport, Host, Port);

   Put_Line ("IDN : " & Rigol.IEEE488.Get_IDN (Scope));

   --  Read back a few settings without disturbing the instrument.
   Put_Line ("CH1 scale  : " &
             Float'Image (Rigol.Channel.Get_Scale (Scope, 1)) & " V/div");
   Put_Line ("CH1 offset : " &
             Float'Image (Rigol.Channel.Get_Offset (Scope, 1)) & " V");
   Put_Line ("Timebase   : " &
             Float'Image (Rigol.Timebase.Get_Scale (Scope)) & " s/div");
   Put_Line ("Sample rate: " &
             Float'Image (Rigol.Acquire.Get_Sample_Rate (Scope)) & " Sa/s");

   Rigol.Disconnect (Scope);
   Put_Line ("Done.");

exception
   when Rigol_Transport.Device_Error =>
      Put_Line ("ERROR: Could not connect to " & Host);
      Put_Line ("  - Is the scope on the network and reachable?");
      Put_Line ("  - Check Utility -> IO for its address, and note that");
      Put_Line ("    not every DS1000Z-E has a LAN port fitted.");
      Set_Exit_Status (Failure);
   when Rigol_Transport.Communication_Error =>
      Put_Line ("ERROR: Communication failure");
      Set_Exit_Status (Failure);
   when Rigol.Not_Connected =>
      Put_Line ("ERROR: Oscilloscope disconnected unexpectedly");
      Set_Exit_Status (Failure);
end LAN_Demo;
