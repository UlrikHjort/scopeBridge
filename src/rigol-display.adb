-- ***************************************************************************
--                      Rigol - Display Commands Body
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

with Ada.Streams.Stream_IO;

package body Rigol.Display is

   function Screenshot
     (Scope  : in out Oscilloscope;
      Format : in     Image_Format := BMP24;
      Color  : in     Boolean      := True;
      Invert : in     Boolean      := False) return String
   is
      Fmt : constant String := Image_Format'Image (Format);
   begin
      return Query_Block
        (Scope, ":DISPlay:DATA? " &
                (if Color then "ON" else "OFF") & "," &
                (if Invert then "ON" else "OFF") & "," & Fmt);
   end Screenshot;

   procedure Save_Screenshot
     (Scope     : in out Oscilloscope;
      File_Name : in     String;
      Format    : in     Image_Format := BMP24;
      Color     : in     Boolean      := True;
      Invert    : in     Boolean      := False)
   is
      use Ada.Streams.Stream_IO;
      Image : constant String := Screenshot (Scope, Format, Color, Invert);
      File  : File_Type;
   begin
      Create (File, Out_File, File_Name);
      String'Write (Stream (File), Image);
      Close (File);
   end Save_Screenshot;

end Rigol.Display;
