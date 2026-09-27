-- ***************************************************************************
--              ScopeBridge Server - Wire Format Specification
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

--  Message framing for docs/PROTOCOL.md: one JSON object per line, with
--  an optional binary payload after the line, announced by "bytes".
--  Also the typed field access that request handling needs.

with Ada.Strings.Unbounded;
with GNAT.Sockets;
with GNATCOLL.JSON;

package Server.Wire is

   use GNATCOLL.JSON;

   --  Raised when the peer closes the connection or a line is too long
   Connection_Closed : exception;

   --  Raised for a request that is malformed or has invalid members; the
   --  message is sent to the client as the error text.
   Request_Error : exception;

   Max_Line : constant := 65_536;

   --  Buffered line input from a socket
   type Line_Reader is limited private;

   procedure Attach
     (Reader : in out Line_Reader;
      Sock   : in     GNAT.Sockets.Socket_Type);

   --  The next line, without its LF (and CR, if any)
   function Read_Line (Reader : in out Line_Reader) return String;

   --  The next Count bytes, e.g. the payload after a message line
   function Read_Bytes
     (Reader : in out Line_Reader;
      Count  : Natural) return String;

   --  Message as one line, ready to send
   function Encode (Message : JSON_Value) return String;

   --  Message with a "bytes" member for Payload, as one line followed by
   --  Payload
   function Encode (Message : JSON_Value; Payload : String) return String;

   --  Send Data, all of it
   procedure Send_All (Sock : GNAT.Sockets.Socket_Type; Data : String);

   --  Send Message as one line
   procedure Write
     (Sock    : GNAT.Sockets.Socket_Type;
      Message : JSON_Value);

   --  Send Message with a "bytes" member for Payload, then Payload
   procedure Write
     (Sock    : GNAT.Sockets.Socket_Type;
      Message : JSON_Value;
      Payload : String);

   -- -------------------------------------------------------------------------
   --  Request members.  Each raises Request_Error, naming the member, if
   --  it is missing or of the wrong JSON type.
   -- -------------------------------------------------------------------------

   function Number_Field  (Request : JSON_Value; Name : String) return Float;
   function Integer_Field (Request : JSON_Value; Name : String) return Integer;
   function Boolean_Field (Request : JSON_Value; Name : String) return Boolean;
   function String_Field  (Request : JSON_Value; Name : String) return String;

   --  Binary data as base64 text, and back; From_Base64 raises
   --  Request_Error if Text is not base64
   function To_Base64 (Data : String) return String;
   function From_Base64 (Text : String) return String;

   --  X as a JSON number, written with Float's precision: 1.0E-05 rather
   --  than 1.00000000000000008E-05
   function To_JSON (X : Float) return JSON_Value;

private

   type Line_Reader is limited record
      Sock    : GNAT.Sockets.Socket_Type;
      Pending : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Server.Wire;
