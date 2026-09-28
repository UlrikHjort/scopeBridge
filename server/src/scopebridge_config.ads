-- ***************************************************************************
--                ScopeBridge - Settings File Specification
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

--  The settings in ~/.scopebridgerc, which give the programs their
--  defaults; options on the command line win over them.
--
--    # comments, also after a setting
--    [server]
--    source = usb auto       usb DEVICE|auto, lan HOST[:PORT] or sim
--    port   = 5026
--    listen = 127.0.0.1
--    web    = 8080           empty: no web interface
--    [client]
--    host   = 192.168.0.19
--    port   = 5026
--
--  $SCOPEBRIDGE_RC names another file instead; set but empty, no file is
--  read (the tests use that, so that nobody's own settings reach them).
--  The file is read once, at the first question. A line it cannot use
--  gives a warning on standard error, with its line number, and is
--  skipped.

package Scopebridge_Config is

   --  The setting, or "" if it is not set
   function Get (Section, Key : String) return String;

   --  Whether the setting is in the file, even if empty
   function Is_Set (Section, Key : String) return Boolean;

   --  The file's name, for messages ("" if none is read)
   function File_Name return String;

end Scopebridge_Config;
