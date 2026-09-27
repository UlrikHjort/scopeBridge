-- ***************************************************************************
--                    ScopeBridge Server - Main Program
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

--  scopebridge-server: serves the oscilloscope over the protocol in
--  docs/PROTOCOL.md.
--
--    scopebridge-server --usb /dev/usbtmc4 | --usb auto | --lan host[:port] | --sim
--                 [--port 5026] [--listen 127.0.0.1] [--log FILE]
--                 [--web PORT [--web-root DIR]]

with Ada.Command_Line;       use Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;         use Ada.Exceptions;
with Ada.Strings.Fixed;      use Ada.Strings.Fixed;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Ada.Text_IO;            use Ada.Text_IO;
with GNAT.Sockets;           use GNAT.Sockets;
with Interfaces.C;
with System;
with System.Storage_Elements;

with Rigol;
with Rigol_Transport;
with Rigol_Transport.LAN;
with Rigol_Transport.Simulator;
with Rigol_Transport.USBTMC;

with Server;
with Server.Log;
with Server.Session;
with Server.Web;

procedure Scopebridge_Server is

   type Source_Kind is (None, USB, LAN, Sim);

   Kind      : Source_Kind := None;
   Target    : Unbounded_String;   --  device node, or host[:port]
   Port      : Port_Type := Server.Default_Port;
   Listen_On : Unbounded_String := To_Unbounded_String ("127.0.0.1");
   Log_File  : Unbounded_String;   --  empty: no command log
   Web_Port  : Natural := 0;       --  0: no web interface
   Web_Root  : Unbounded_String;   --  empty: Server.Web.Default_Root

   Usage_Error : exception;

   procedure Usage is
   begin
      Put_Line (Standard_Error,
        "usage: scopebridge-server --usb DEVICE|auto | --lan HOST[:PORT] | --sim");
      Put_Line (Standard_Error,
        "                    [--port N] [--listen ADDRESS] [--log FILE]");
      Put_Line (Standard_Error,
        "                    [--web PORT [--web-root DIR]]");
      Put_Line (Standard_Error,
        "  Serves the scope over the protocol in docs/PROTOCOL.md,");
      Put_Line (Standard_Error,
        "  on 127.0.0.1:" & Trim (Server.Default_Port'Image, Ada.Strings.Left)
        & " unless told otherwise.  --web also serves the browser");
      Put_Line (Standard_Error,
        "  interface (web/) on PORT, at the same address.");
   end Usage;

   procedure Parse_Arguments is
      I : Positive := 1;

      function Value return String is
      begin
         if I = Argument_Count then
            raise Usage_Error with Argument (I) & " needs a value";
         end if;
         I := I + 1;
         return Argument (I);
      end Value;

      procedure Set_Source (K : Source_Kind; T : String) is
      begin
         if Kind /= None then
            raise Usage_Error with "give only one of --usb, --lan, --sim";
         end if;
         Kind   := K;
         Target := To_Unbounded_String (T);
      end Set_Source;
   begin
      while I <= Argument_Count loop
         declare
            A : constant String := Argument (I);
         begin
            if    A = "--usb"    then Set_Source (USB, Value);
            elsif A = "--lan"    then Set_Source (LAN, Value);
            elsif A = "--sim"    then Set_Source (Sim, "");
            elsif A = "--port"   then Port := Port_Type'Value (Value);
            elsif A = "--listen" then Listen_On := To_Unbounded_String (Value);
            elsif A = "--log"    then Log_File := To_Unbounded_String (Value);
            elsif A = "--web"    then Web_Port := Natural'Value (Value);
            elsif A = "--web-root" then Web_Root := To_Unbounded_String (Value);
            elsif A in "-h" | "--help" then
               Usage;
               raise Usage_Error with "";
            else
               raise Usage_Error with "unknown argument " & A;
            end if;
         end;
         I := I + 1;
      end loop;
      if Kind = None then
         raise Usage_Error with "give one of --usb, --lan, --sim";
      end if;
   end Parse_Arguments;

   --  The usbtmc device node of the first Rigol scope (USB vendor 1ab1),
   --  as the kernel numbers them anew on every connection
   function Find_Rigol return String is
      use Ada.Directories;
      Search : Search_Type;
      Item   : Directory_Entry_Type;
   begin
      if Exists ("/sys/class/usbmisc") then
         Start_Search (Search, "/sys/class/usbmisc", "usbtmc*");
         while More_Entries (Search) loop
            Get_Next_Entry (Search, Item);
            declare
               Vendor : constant String :=
                 Full_Name (Item) & "/device/../idVendor";
               F      : File_Type;
            begin
               if Exists (Vendor) then
                  Open (F, In_File, Vendor);
                  if Get_Line (F) = "1ab1" then
                     Close (F);
                     End_Search (Search);
                     return "/dev/" & Simple_Name (Item);
                  end if;
                  Close (F);
               end if;
            end;
         end loop;
         End_Search (Search);
      end if;
      raise Rigol_Transport.Device_Error
        with "no Rigol scope found on USB (is it on and connected?)";
   end Find_Rigol;

   --  A client that disconnects while we write would otherwise kill the
   --  process with SIGPIPE; ignored, the write fails with an error instead.
   procedure Ignore_SIGPIPE is
      function C_Signal
        (Sig : Interfaces.C.int; Handler : System.Address) return System.Address;
      pragma Import (C, C_Signal, "signal");
      SIGPIPE : constant := 13;
      SIG_IGN : constant System.Address := System.Storage_Elements.To_Address (1);
      Dummy   : constant System.Address := C_Signal (SIGPIPE, SIG_IGN);
   begin
      null;
   end Ignore_SIGPIPE;

   USB_T : aliased Rigol_Transport.USBTMC.Handle;
   LAN_T : aliased Rigol_Transport.LAN.Handle;
   Sim_T : aliased Rigol_Transport.Simulator.Handle;

begin
   Parse_Arguments;
   Ignore_SIGPIPE;
   if Length (Log_File) > 0 then
      Server.Log.Open (To_String (Log_File));
   end if;

   case Kind is
      when USB =>
         if Target = "auto" then
            Target := To_Unbounded_String (Find_Rigol);
         end if;
         Rigol_Transport.USBTMC.Open (USB_T, To_String (Target));
         Rigol_Transport.USBTMC.Set_Timeout (USB_T, 10.0);
      when LAN =>
         declare
            T     : constant String  := To_String (Target);
            Colon : constant Natural := Index (T, ":");
         begin
            if Colon = 0 then
               Rigol_Transport.LAN.Open (LAN_T, T);
            else
               Rigol_Transport.LAN.Open
                 (LAN_T, T (T'First .. Colon - 1),
                  Port_Type'Value (T (Colon + 1 .. T'Last)));
            end if;
         end;
      when Sim =>
         Rigol_Transport.Simulator.Open (Sim_T);
      when None =>
         null;
   end case;

   declare
      Scope  : Rigol.Oscilloscope
        (case Kind is
            when USB  => USB_T'Access,
            when LAN  => LAN_T'Access,
            when Sim | None => Sim_T'Access);
      Source : constant String :=
        (case Kind is
            when USB  => "usb:" & To_String (Target),
            when LAN  => "lan:" & To_String (Target),
            when Sim | None => "sim");
      Listener     : Socket_Type;
      Web_Listener : Socket_Type := No_Socket;

      --  A socket listening on Listen_On at P
      function Listen (P : Port_Type) return Socket_Type is
         S       : Socket_Type;
         Address : Sock_Addr_Type;
      begin
         Create_Socket (S);
         Set_Socket_Option (S, Socket_Level, (Reuse_Address, True));
         Address.Addr := Inet_Addr (To_String (Listen_On));
         Address.Port := P;
         Bind_Socket (S, Address);
         Listen_Socket (S);
         return S;
      end Listen;

      Root : constant String :=
        (if Length (Web_Root) > 0 then To_String (Web_Root)
         else Server.Web.Default_Root);
   begin
      Listener := Listen (Port);
      Put_Line ("scopebridge-server: " & Source & ", listening on " &
                To_String (Listen_On) & ":" & Trim (Port'Image, Ada.Strings.Left));
      if Web_Port /= 0 then
         Web_Listener := Listen (Port_Type (Web_Port));
         Put_Line ("scopebridge-server: web interface on http://" &
                   (if To_String (Listen_On) = "0.0.0.0" then "<this computer>"
                    else To_String (Listen_On)) &
                   ":" & Trim (Web_Port'Image, Ada.Strings.Left) & "/" &
                   (if Root = "" then "  (no web files found: give --web-root)"
                    else ""));
      end if;
      Flush;
      Server.Session.Run (Scope, Listener, Source, Web_Listener, Root);
   end;

exception
   when E : Usage_Error =>
      if Exception_Message (E) /= "" then
         Put_Line (Standard_Error, "scopebridge-server: " & Exception_Message (E));
         Usage;
      end if;
      Set_Exit_Status (Failure);
   when E : Rigol_Transport.Device_Error =>
      Put_Line (Standard_Error, "scopebridge-server: " & Exception_Message (E));
      Set_Exit_Status (Failure);
   when E : Socket_Error =>
      Put_Line (Standard_Error, "scopebridge-server: network: " & Exception_Message (E));
      Set_Exit_Status (Failure);
end Scopebridge_Server;
