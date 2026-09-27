-- ***************************************************************************
--            ScopeBridge Terminal - Server Client Specification
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

--  A synchronous client of scopebridge-server (docs/PROTOCOL.md) for the
--  terminal: a request waits for its reply; events arriving meanwhile go
--  to a handler.

with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with GNAT.Sockets;
with GNATCOLL.JSON;          use GNATCOLL.JSON;

package Term_Client is

   --  A request the server answered with "ok": false; the message is the
   --  server's error text
   Request_Failed : exception;

   --  The server cannot be reached, or closed the connection
   Connection_Lost : exception;

   type Event_Handler is access procedure (Event : JSON_Value; Payload : String);

   procedure Connect (Host : String; Port : GNAT.Sockets.Port_Type);
   procedure Close;

   --  The server's hello event
   function Hello return JSON_Value;

   --  Send {"cmd": Cmd, ...Members} and wait for the reply.  Events that
   --  arrive meanwhile go to On_Event, if given.
   procedure Request
     (Cmd      : String;
      Members  : JSON_Value;
      Reply    : out JSON_Value;
      Payload  : out Unbounded_String;
      On_Event : Event_Handler := null);

   --  The same, when neither reply nor payload is needed
   procedure Request (Cmd : String; Members : JSON_Value := JSON_Null);

   --  Wait up to Timeout for the next message (an event, or a reply to
   --  nothing); Got is False if none came
   procedure Next_Message
     (Timeout : Duration;
      Message : out JSON_Value;
      Payload : out Unbounded_String;
      Got     : out Boolean);

end Term_Client;
