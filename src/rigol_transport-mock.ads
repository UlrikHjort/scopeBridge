-- ***************************************************************************
--                      Rigol - Mock Transport Specification
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

--  In-memory transport used for testing without an instrument.
--
--  Every command passed to Send or Query is recorded in an ordered log,
--  so a test can assert on the exact SCPI text the library produced.
--  Responses returned by Query are taken from a queue primed by the test
--  via Push_Response; once the queue is exhausted, Default_Response is
--  returned instead (initially "0", which parses safely as False, 0 and
--  0.0 for every Get_* function in the library).
--
--  Typical usage:
--
--    T     : aliased Rigol_Transport.Mock.Handle;
--    Scope : Rigol.Oscilloscope (T'Access);
--  begin
--    Rigol.Channel.Set_Coupling (Scope, 1, Rigol.Channel.DC);
--    pragma Assert (Last_Command (T) = ":CHANnel1:COUPling DC");

with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;

package Rigol_Transport.Mock is

   --  Longest command (or default response) the mock will store.  Text
   --  beyond this is truncated rather than raising, so a test failure
   --  reports a readable mismatch instead of an exception.  Queued
   --  responses are not limited: they may be large binary blocks.
   Max_Text : constant := 512;

   --  Depth of the command log and of the response queue.
   Max_Entries : constant := 128;

   type Handle is new Rigol_Transport.Handle with private;

   -- -------------------------------------------------------------------------
   --  Priming the mock
   -- -------------------------------------------------------------------------

   --  Queue one response, returned by a later Query in FIFO order.
   procedure Push_Response
     (T        : in out Handle;
      Response : in     String);

   --  Response handed out once the queue is empty.  Defaults to "0".
   procedure Set_Default_Response
     (T        : in out Handle;
      Response : in     String);

   --  Forget all logged commands and all queued responses.
   procedure Reset (T : in out Handle);

   -- -------------------------------------------------------------------------
   --  Inspecting what the library sent
   -- -------------------------------------------------------------------------

   --  Number of commands recorded so far (Send and Query both count).
   function Command_Count (T : Handle) return Natural;

   --  The N'th recorded command, 1-based in the order it was issued.
   --  Returns "" if N is beyond Command_Count.
   function Command (T : Handle; N : Positive) return String;

   --  The most recently recorded command, or "" if none.
   function Last_Command (T : Handle) return String;

   -- -------------------------------------------------------------------------
   --  Rigol_Transport interface
   -- -------------------------------------------------------------------------

   overriding procedure Send
     (T       : in out Handle;
      Command : in     String);

   overriding function Query
     (T       : in out Handle;
      Command : in     String) return String;

   overriding procedure Close   (T : in out Handle);
   overriding function  Is_Open (T :        Handle) return Boolean;

private

   type Text_Entry is record
      Text : String (1 .. Max_Text) := (others => ' ');
      Len  : Natural                := 0;
   end record;

   type Entry_List is array (1 .. Max_Entries) of Text_Entry;

   type Response_List is array (1 .. Max_Entries) of Unbounded_String;

   --  "0" as the initial default response.
   Zero_Entry : constant Text_Entry :=
     (Text => ('0', others => ' '), Len => 1);

   type Handle is new Rigol_Transport.Handle with record
      Log        : Entry_List;
      Log_Count  : Natural    := 0;

      Responses  : Response_List;
      Resp_Count : Natural    := 0;
      Resp_Next  : Positive   := 1;

      Default    : Text_Entry := Zero_Entry;
      Opened     : Boolean    := True;
   end record;

end Rigol_Transport.Mock;
