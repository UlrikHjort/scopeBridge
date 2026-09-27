-- ***************************************************************************
--                      Rigol - LAN Transport Specification
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

--  LAN/TCP transport using SCPI raw socket (port 5555).
--  Uses GNAT.Sockets for the TCP connection.
--  Text responses are read up to the newline terminator; definite-length
--  blocks (#<n><length><data>, e.g. waveform data and screen images) are
--  read by their declared length, since binary data may contain newlines.
--
--  Over LAN the DS1202Z-E answers a query it does not know with
--  "Command error" and no terminator; Query raises Communication_Error
--  for it.  A query without any answer times out (see Set_Timeout).
--
--  A connection that breaks (the scope switched off and on, the network
--  gone for a moment) fails the command it happened in with
--  Communication_Error, and the next command connects again.

with Ada.Strings.Unbounded;
with GNAT.Sockets;

package Rigol_Transport.LAN is

   Default_Port : constant := 5555;

   type Handle is new Rigol_Transport.Handle with private;

   --  Open a TCP connection to the oscilloscope.
   --  Host may be a dotted-decimal IP address or a hostname.
   --  Raises Device_Error if the host is unknown or the connection cannot
   --  be established.
   procedure Open
     (T    : out Handle;
      Host : in  String;
      Port : in  GNAT.Sockets.Port_Type := Default_Port);

   --  How long a read may wait for the scope before Query raises
   --  Communication_Error; 10 s by default
   procedure Set_Timeout
     (T       : in out Handle;
      Timeout : in     Duration);

   --  The address of Host: a dotted-decimal address as it is, otherwise
   --  looked up by name.  Raises Device_Error if the name is unknown.
   function Address_Of (Host : String) return GNAT.Sockets.Inet_Addr_Type;

   overriding procedure Send
     (T       : in out Handle;
      Command : in     String);

   overriding function Query
     (T       : in out Handle;
      Command : in     String) return String;

   overriding procedure Close   (T : in out Handle);
   overriding function  Is_Open (T :        Handle) return Boolean;

private

   type Handle is new Rigol_Transport.Handle with record
      Sock      : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Connected : Boolean                  := False;   --  opened, not closed
      Broken    : Boolean                  := False;   --  to connect again
      Timeout   : Duration                 := 10.0;
      Host      : Ada.Strings.Unbounded.Unbounded_String;
      Port      : GNAT.Sockets.Port_Type   := Default_Port;
   end record;

end Rigol_Transport.LAN;
