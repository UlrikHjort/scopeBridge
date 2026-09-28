-- ***************************************************************************
--                 ScopeBridge Server - Web Interface Body
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

with Ada.Characters.Handling;  use Ada.Characters.Handling;
with Ada.Directories;          use Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;              use Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;        use Ada.Strings.Fixed;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
with GNAT.SHA1;

package body Server.Web is

   use GNAT.Sockets;
   use Server.Wire;
   use type Interfaces.Unsigned_8;

   CRLF : constant String := ASCII.CR & ASCII.LF;

   -- -------------------------------------------------------------------------
   --  Files
   -- -------------------------------------------------------------------------

   --  The directory this program's file is in (via /proc/self/exe, as the
   --  program may have been started through the PATH)
   function Program_Directory return String is
      use Interfaces.C;
      function Readlink
        (Path : Interfaces.C.Strings.chars_ptr;
         Buf  : in out char_array;
         Size : size_t) return long;
      pragma Import (C, Readlink, "readlink");
      Path : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String ("/proc/self/exe");
      Buf  : char_array (1 .. 4096);
      N    : constant long := Readlink (Path, Buf, Buf'Length);
   begin
      Interfaces.C.Strings.Free (Path);
      if N <= 0 then
         return "";
      end if;
      return Containing_Directory
        (To_Ada (Buf (1 .. size_t (N)), Trim_Nul => False));
   end Program_Directory;

   function Default_Root return String is
      Here : constant String := Program_Directory;
   begin
      if Ada.Environment_Variables.Exists ("SCOPEBRIDGE_WEB") then
         return Ada.Environment_Variables.Value ("SCOPEBRIDGE_WEB");
      elsif Here = "" then
         return "";
      end if;
      declare
         Up : constant String := Containing_Directory (Here);
      begin
         if Exists (Compose (Up, "web") & "/index.html") then
            return Compose (Up, "web");
         elsif Exists (Up & "/share/scopebridge/web/index.html") then
            return Up & "/share/scopebridge/web";
         end if;
      end;
      return "";
   end Default_Root;

   function Content_Type (Name : String) return String is
      Ext : constant String := To_Lower (Extension (Name));
   begin
      return (if    Ext = "html" then "text/html; charset=utf-8"
              elsif Ext = "js"   then "text/javascript; charset=utf-8"
              elsif Ext = "css"  then "text/css; charset=utf-8"
              elsif Ext = "svg"  then "image/svg+xml"
              elsif Ext = "png"  then "image/png"
              elsif Ext = "ico"  then "image/x-icon"
              elsif Ext = "json" then "application/json"
              else "application/octet-stream");
   end Content_Type;

   --  A file name of the web directory: letters, digits, '-', '_' and
   --  '.', not starting with '.', so nothing outside it can be named
   function Safe (Name : String) return Boolean is
     (Name'Length in 1 .. 100
      and then Name (Name'First) /= '.'
      and then (for all C of Name =>
                  Is_Alphanumeric (C) or else C in '-' | '_' | '.'));

   function Read_File (Name : String) return String is
      use Ada.Streams.Stream_IO;
      F    : File_Type;
      Data : String (1 .. Natural (Size (Name)));
   begin
      Open (F, In_File, Name);
      String'Read (Stream (F), Data);
      Close (F);
      return Data;
   end Read_File;

   procedure Respond
     (Sock    : Socket_Type;
      Status  : String;
      Kind    : String;
      Content : String) is
   begin
      Send_All
        (Sock,
         "HTTP/1.1 " & Status & CRLF &
         "Content-Type: " & Kind & CRLF &
         "Content-Length:" & Content'Length'Image & CRLF &
         "Cache-Control: no-cache" & CRLF &
         "Connection: close" & CRLF & CRLF & Content);
   end Respond;

   -- -------------------------------------------------------------------------
   --  HTTP and the WebSocket handshake
   -- -------------------------------------------------------------------------

   --  RFC 6455: the accept key is base64 (SHA-1 (key & this GUID))
   GUID : constant String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

   function Accept_Key (Key : String) return String is
      Digest : constant GNAT.SHA1.Binary_Message_Digest :=
        GNAT.SHA1.Digest (Key & GUID);
      Bytes  : String (1 .. Digest'Length);
   begin
      for I in Bytes'Range loop
         Bytes (I) := Character'Val (Digest (Stream_Element_Offset (I)));
      end loop;
      return To_Base64 (Bytes);
   end Accept_Key;

   function Answer (Sock : Socket_Type; Root : String) return Boolean is
      Reader  : Line_Reader;
      Target  : Unbounded_String;
      Key     : Unbounded_String;
      Upgrade : Boolean := False;
   begin
      Attach (Reader, Sock);
      declare
         Request : constant String := Read_Line (Reader);   --  GET /x HTTP/1.1
         First   : constant Natural := Index (Request, " ");
         Last    : constant Natural :=
           (if First = 0 then 0 else Index (Request, " ", First + 1));
      begin
         if First = 0 or else Last = 0
           or else Request (Request'First .. First - 1) /= "GET"
         then
            Respond (Sock, "405 Method Not Allowed", "text/plain", "GET only" & CRLF);
            return False;
         end if;
         Target := To_Unbounded_String (Request (First + 1 .. Last - 1));
      end;
      loop
         declare
            Line  : constant String := Read_Line (Reader);
            Colon : constant Natural := Index (Line, ":");
         begin
            exit when Line = "";
            if Colon > 0 then
               declare
                  Name  : constant String := To_Lower (Line (Line'First .. Colon - 1));
                  Value : constant String :=
                    Trim (Line (Colon + 1 .. Line'Last), Ada.Strings.Both);
               begin
                  if Name = "sec-websocket-key" then
                     Key := To_Unbounded_String (Value);
                  elsif Name = "upgrade" then
                     Upgrade := To_Lower (Value) = "websocket";
                  end if;
               end;
            end if;
         end;
      end loop;

      declare
         Path : constant String := To_String (Target);
         Q    : constant Natural := Index (Path, "?");
         Name : constant String :=
           (if Q = 0 then Path else Path (Path'First .. Q - 1));
      begin
         if Name = "/ws" then
            if not Upgrade or else Length (Key) = 0 then
               Respond (Sock, "400 Bad Request", "text/plain",
                        "a WebSocket upgrade is needed" & CRLF);
               return False;
            end if;
            Send_All
              (Sock,
               "HTTP/1.1 101 Switching Protocols" & CRLF &
               "Upgrade: websocket" & CRLF &
               "Connection: Upgrade" & CRLF &
               "Sec-WebSocket-Accept: " & Accept_Key (To_String (Key)) & CRLF & CRLF);
            return True;
         end if;

         declare
            File : constant String :=
              (if Name = "/" then "index.html" else Name (Name'First + 1 .. Name'Last));
         begin
            if Root /= "" and then Safe (File)
              and then Exists (Root & "/" & File)
              and then Kind (Root & "/" & File) = Ordinary_File
            then
               Respond (Sock, "200 OK", Content_Type (File), Read_File (Root & "/" & File));
            else
               Respond (Sock, "404 Not Found", "text/plain",
                        (if Root = "" then "no web files found: give --web-root"
                         else "not found") & CRLF);
            end if;
         end;
      end;
      return False;
   end Answer;

   -- -------------------------------------------------------------------------
   --  WebSocket frames (RFC 6455, section 5)
   -- -------------------------------------------------------------------------

   Op_Continuation : constant := 0;
   Op_Text         : constant := 1;
   Op_Binary       : constant := 2;
   Op_Close        : constant := 8;

   function Pos (C : Character) return Natural is (Character'Pos (C));

   function Read_Message (Reader : in out Line_Reader) return String is
      Message : Unbounded_String;
      Opcode  : Natural := Op_Text;
   begin
      loop
         declare
            Head   : constant String := Read_Bytes (Reader, 2);
            Final  : constant Boolean := Pos (Head (1)) >= 128;
            Op     : constant Natural := Pos (Head (1)) mod 16;
            Masked : constant Boolean := Pos (Head (2)) >= 128;
            Size   : Long_Long_Integer := Long_Long_Integer (Pos (Head (2)) mod 128);
         begin
            if Size = 126 then
               declare
                  B : constant String := Read_Bytes (Reader, 2);
               begin
                  Size := Long_Long_Integer (Pos (B (1)) * 256 + Pos (B (2)));
               end;
            elsif Size = 127 then
               declare
                  B : constant String := Read_Bytes (Reader, 8);
               begin
                  Size := 0;
                  for C of B loop
                     Size := Size * 256 + Long_Long_Integer (Pos (C));
                  end loop;
               end;
            end if;
            if Size > Long_Long_Integer (Max_Line) then
               raise Connection_Closed with "WebSocket message too long";
            end if;
            declare
               Mask : constant String :=
                 (if Masked then Read_Bytes (Reader, 4) else (1 .. 4 => ASCII.NUL));
               Data : String := Read_Bytes (Reader, Natural (Size));
            begin
               if Op = Op_Close then
                  raise Connection_Closed;
               end if;
               for I in Data'Range loop
                  Data (I) := Character'Val
                    (Interfaces.Unsigned_8'(Character'Pos (Data (I)))
                     xor Interfaces.Unsigned_8'(Character'Pos
                                                  (Mask (1 + (I - Data'First) mod 4))));
               end loop;
               if Op in Op_Text | Op_Binary then
                  Opcode  := Op;
                  Message := To_Unbounded_String (Data);
               elsif Op = Op_Continuation then
                  Append (Message, Data);
               end if;
               --  Pings and pongs (Op 9, 10) are ignored: browsers do not
               --  ping, and a WebSocket stays open without
               if Final and then Op in Op_Text | Op_Binary | Op_Continuation then
                  if Opcode = Op_Text then
                     return To_String (Message);
                  end if;
                  Message := Null_Unbounded_String;   --  binary: not a request
               end if;
            end;
         end;
      end loop;
   end Read_Message;

   --  The header of an unmasked, final frame of Size bytes
   function Header (Opcode : Natural; Size : Natural) return String is
      function Byte (X : Natural) return Character is (Character'Val (X mod 256));
   begin
      return Byte (128 + Opcode) &
        (if Size < 126 then (1 => Byte (Size))
         elsif Size < 65_536 then Byte (126) & Byte (Size / 256) & Byte (Size)
         else Byte (127) & Byte (0) & Byte (0) & Byte (0) & Byte (0) &
              Byte (Size / 2**24) & Byte (Size / 2**16) & Byte (Size / 256) & Byte (Size));
   end Header;

   procedure Send_Frames (Sock : Socket_Type; Encoded : String) is
      LF   : constant Natural := Index (Encoded, (1 => ASCII.LF));
      Line : constant Natural := (if LF = 0 then Encoded'Last else LF - 1);
   begin
      Send_All (Sock, Header (Op_Text, Line - Encoded'First + 1));
      Send_All (Sock, Encoded (Encoded'First .. Line));
      if LF /= 0 and then LF < Encoded'Last then
         Send_All (Sock, Header (Op_Binary, Encoded'Last - LF));
         Send_All (Sock, Encoded (LF + 1 .. Encoded'Last));
      end if;
   end Send_Frames;

end Server.Web;
