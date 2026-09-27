-- ***************************************************************************
--              ScopeBridge GUI - Server Client Specification
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

--  Connection to scopebridge-server (docs/PROTOCOL.md) for the GUI.
--
--  A network task receives messages; Poll, called from a GTK timer,
--  hands them to their handlers on the GUI thread, which is the only
--  thread allowed to touch widgets.  Requests are sent without waiting,
--  so a slow request (a memory capture takes seconds) never freezes the
--  window: its handler simply runs when the reply arrives.

with GNAT.Sockets;
with GNATCOLL.JSON;  use GNATCOLL.JSON;

with Units;

package Gui_Client is

   --  Called with a reply or an event, and its binary payload ("" if none)
   type Handler is access procedure (Message : JSON_Value; Payload : String);

   --  Called when a request without handler fails, or the connection is
   --  lost
   type Error_Handler is access procedure (Text : String);

   Connect_Error : exception;

   procedure Connect
     (Host : String;
      Port : GNAT.Sockets.Port_Type);

   function Is_Connected return Boolean;

   --  Close the connection.  Needed before the program ends, which
   --  otherwise waits for the network task.
   procedure Disconnect;

   procedure Set_Event_Handler (On_Event : Handler);
   procedure Set_Error_Handler (On_Error : Error_Handler);

   --  Send {"cmd": Cmd, ...Members}.  On_Reply gets the reply, whether
   --  it succeeded or not ("ok"); without one, failures go to the error
   --  handler.
   procedure Request
     (Cmd      : String;
      Members  : JSON_Value := JSON_Null;
      On_Reply : Handler    := null);

   --  Deliver the messages received so far.  Call from the GUI thread.
   procedure Poll;

   --  The float32 values of a "math", "spectrum" or "math_view" payload
   function Floats (Payload : String) return Units.Float_Array;

end Gui_Client;
