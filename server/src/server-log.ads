-- ***************************************************************************
--              ScopeBridge Server - Command Log Specification
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

--  The server's command log (scopebridge-server --log FILE): one JSON object per
--  line for every connection, request and reply, with a local timestamp:
--
--    {"t":"2026-09-26 10:15:02.12","client":1,"connect":"127.0.0.1:40122"}
--    {"t":"...","client":1,"request":{"id":3,"cmd":"set_channel",...}}
--    {"t":"...","client":1,"reply":{"id":3,"ok":true}}
--    {"t":"...","client":1,"disconnect":true}
--
--  Replies are logged without their binary payload ("bytes" gives its
--  size); events are not logged.  Each line is flushed at once.  The
--  requests of a log can be replayed (clients/python/scopebridge_run.py).

with GNATCOLL.JSON;

package Server.Log is

   --  Start logging to File_Name, appending if it exists
   procedure Open (File_Name : String);

   function Is_Open return Boolean;

   procedure Connected    (Client : Positive; Peer : String);
   procedure Disconnected (Client : Positive);

   --  A request line as received (logged as JSON if it is JSON)
   procedure Request (Client : Positive; Text : String);

   procedure Reply (Client : Positive; Reply : GNATCOLL.JSON.JSON_Value);

end Server.Log;
