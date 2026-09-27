-- ***************************************************************************
--                  ScopeBridge Server - Command Log Body
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

with Ada.Calendar;             use Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Calendar.Time_Zones;
with Ada.Directories;
with Ada.Text_IO;

package body Server.Log is

   use GNATCOLL.JSON;

   File : Ada.Text_IO.File_Type;

   procedure Open (File_Name : String) is
   begin
      if Ada.Directories.Exists (File_Name) then
         Ada.Text_IO.Open (File, Ada.Text_IO.Append_File, File_Name);
      else
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, File_Name);
      end if;
   end Open;

   function Is_Open return Boolean is (Ada.Text_IO.Is_Open (File));

   procedure Write (Client : Positive; Key : String; Value : JSON_Value) is
      Line : constant JSON_Value := Create_Object;
   begin
      if not Is_Open then
         return;
      end if;
      Set_Field (Line, "t", Ada.Calendar.Formatting.Image
                   (Clock, Include_Time_Fraction => True,
                    Time_Zone => Ada.Calendar.Time_Zones.UTC_Time_Offset));
      Set_Field (Line, "client", Client);
      Set_Field (Line, Key, Value);
      Ada.Text_IO.Put_Line (File, GNATCOLL.JSON.Write (Line));
      Ada.Text_IO.Flush (File);
   end Write;

   procedure Connected (Client : Positive; Peer : String) is
   begin
      Write (Client, "connect", Create (Peer));
   end Connected;

   procedure Disconnected (Client : Positive) is
   begin
      Write (Client, "disconnect", Create (True));
   end Disconnected;

   procedure Request (Client : Positive; Text : String) is
   begin
      if Is_Open then
         begin
            Write (Client, "request", Read (Text));
         exception
            when Invalid_JSON_Stream =>
               Write (Client, "request", Create (Text));   --  as received
         end;
      end if;
   end Request;

   procedure Reply (Client : Positive; Reply : JSON_Value) is
   begin
      Write (Client, "reply", Reply);
   end Reply;

end Server.Log;
