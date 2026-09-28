-- ***************************************************************************
--                      ScopeBridge GUI - Main Program
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

--  scopebridge-gui: GtkAda front end for scopebridge-server.
--
--    scopebridge-gui [--host 127.0.0.1] [--port 5026]
--
--  Start the server first, e.g.  scopebridge-server --usb /dev/usbtmc4

with Ada.Command_Line;       use Ada.Command_Line;
with Ada.Exceptions;         use Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Ada.Text_IO;            use Ada.Text_IO;
with GNAT.Sockets;

with Gtk.Main;

with Scopebridge_Config;
with Scopebridge_Version;
with Server;
with Gui_Client;
with Main_Window;

procedure Scopebridge_Gui is
   --  The defaults: ~/.scopebridgerc's [client], else this computer
   function Setting (Key, Default : String) return String is
     (if Scopebridge_Config.Get ("client", Key) /= ""
      then Scopebridge_Config.Get ("client", Key) else Default);

   Host : Unbounded_String := To_Unbounded_String (Setting ("host", "127.0.0.1"));
   Port : GNAT.Sockets.Port_Type := Server.Default_Port;
   I    : Positive := 1;
begin
   begin
      Port := GNAT.Sockets.Port_Type'Value
        (Setting ("port", Ada.Strings.Fixed.Trim (Server.Default_Port'Image, Ada.Strings.Left)));
   exception
      when Constraint_Error =>
         Put_Line (Standard_Error, "scopebridge-gui: " & Scopebridge_Config.File_Name
                   & ": [client] port is not a port number; using"
                   & Server.Default_Port'Image);
   end;
   while I <= Argument_Count loop
      if Argument (I) = "--version" then
         Put_Line ("scopebridge-gui " & Scopebridge_Version.Version);
         return;
      elsif Argument (I) = "--host" and then I < Argument_Count then
         Host := To_Unbounded_String (Argument (I + 1));
         I := I + 2;
      elsif Argument (I) = "--port" and then I < Argument_Count then
         Port := GNAT.Sockets.Port_Type'Value (Argument (I + 1));
         I := I + 2;
      else
         Put_Line (Standard_Error, "usage: scopebridge-gui [--host HOST] [--port N] | --version");
         Set_Exit_Status (Failure);
         return;
      end if;
   end loop;

   Gui_Client.Connect (To_String (Host), Port);
   Gtk.Main.Init;
   Main_Window.Create;
   Gtk.Main.Main;
   Gui_Client.Disconnect;

exception
   when E : Gui_Client.Connect_Error =>
      Put_Line (Standard_Error, "scopebridge-gui: " & Exception_Message (E));
      Put_Line (Standard_Error,
                "Start the server first, e.g.  scopebridge-server --usb /dev/usbtmc0");
      Set_Exit_Status (Failure);
end Scopebridge_Gui;
