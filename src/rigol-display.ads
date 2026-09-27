-- ***************************************************************************
--                      Rigol - Display Commands Specification
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

--  :DISPlay command group: screen capture.

package Rigol.Display is

   type Image_Format is (BMP24, BMP8, PNG, JPEG, TIFF);

   --  :DISPlay:DATA? - the image currently on screen (800 x 480), as the
   --  bytes of an image file in the requested format.  Color => False
   --  gives an intensity-graded image; Invert inverts the colours.
   --
   --  On firmware 00.06.04, BMP24 (1.1 MB, ~1.5 s over USB) and JPEG are
   --  valid files.  PNG (~40 KB, ~0.7 s) has valid image data, but the
   --  scope writes a fixed, wrong CRC on its text (metadata) chunks, which
   --  most decoders only warn about.  BMP8 has a wrong file-size field,
   --  and TIFF decodes with warnings.  BMP24 is the default as the one
   --  format every reader accepts.

   function Screenshot
     (Scope  : in out Oscilloscope;
      Format : in     Image_Format := BMP24;
      Color  : in     Boolean      := True;
      Invert : in     Boolean      := False) return String;

   --  Screenshot, written to File_Name (overwritten if it exists)
   procedure Save_Screenshot
     (Scope     : in out Oscilloscope;
      File_Name : in     String;
      Format    : in     Image_Format := BMP24;
      Color     : in     Boolean      := True;
      Invert    : in     Boolean      := False);

end Rigol.Display;
