-- ***************************************************************************
--             ScopeBridge Server - Web Interface Specification
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

--  The web interface: scopebridge-server with --web PORT serves the files of
--  the browser client (web/) over HTTP, and the protocol over WebSocket
--  at /ws, so that any browser is a client like the others.
--
--  Over WebSocket each protocol message is one text frame, holding the
--  JSON object, and a message with a binary payload ("bytes": N) is
--  followed by a binary frame holding the N bytes.  Requests come as
--  text frames.

with GNAT.Sockets;

with Server.Wire;

package Server.Web is

   --  Where the browser client's files are: $SCOPEBRIDGE_WEB if set, else web/
   --  next to bin/ (the source tree), else share/scopebridge/web next to bin/
   --  (installed).  "" if none is found.
   function Default_Root return String;

   --  Answer one HTTP request on Sock, which has just been accepted: a
   --  file from Root, then the connection is closed (False); or, for
   --  /ws, the WebSocket handshake, after which Sock carries WebSocket
   --  frames (True).  Raises Server.Wire.Connection_Closed for a request
   --  that cannot be read.
   function Answer (Sock : GNAT.Sockets.Socket_Type; Root : String) return Boolean;

   --  The next text message from a WebSocket client.  Raises
   --  Server.Wire.Connection_Closed when the client closes.
   function Read_Message (Reader : in out Server.Wire.Line_Reader) return String;

   --  Send a message as Server.Wire.Encode gives it (a line, then any
   --  payload) as WebSocket frames: the line as text, the payload as
   --  binary.  Sent in place, without copying: a payload may be megabytes,
   --  more than a task's stack holds.
   procedure Send_Frames (Sock : GNAT.Sockets.Socket_Type; Encoded : String);

end Server.Web;
