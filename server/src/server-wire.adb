-- ***************************************************************************
--                  ScopeBridge Server - Wire Format Body
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

with Ada.Streams;            use Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;

package body Server.Wire is

   use GNAT.Sockets;

   procedure Attach
     (Reader : in out Line_Reader;
      Sock   : in     Socket_Type) is
   begin
      Reader.Sock    := Sock;
      Reader.Pending := Null_Unbounded_String;
   end Attach;

   function Read_Line (Reader : in out Line_Reader) return String is
      Chunk : Stream_Element_Array (1 .. 4_096);
      Last  : Stream_Element_Offset;
      LF    : Natural;
   begin
      loop
         LF := Index (Reader.Pending, (1 => ASCII.LF));
         if LF > 0 then
            declare
               Line : constant String := Slice (Reader.Pending, 1, LF - 1);
            begin
               Delete (Reader.Pending, 1, LF);
               if Line'Length > 0 and then Line (Line'Last) = ASCII.CR then
                  return Line (Line'First .. Line'Last - 1);
               end if;
               return Line;
            end;
         end if;

         if Length (Reader.Pending) > Max_Line then
            raise Connection_Closed with "request line too long";
         end if;

         Receive_Socket (Reader.Sock, Chunk, Last);
         if Last < Chunk'First then
            raise Connection_Closed;
         end if;
         for E of Chunk (1 .. Last) loop
            Append (Reader.Pending, Character'Val (E));
         end loop;
      end loop;
   end Read_Line;

   function Read_Bytes
     (Reader : in out Line_Reader;
      Count  : Natural) return String
   is
      Chunk : Stream_Element_Array (1 .. 65_536);
      Last  : Stream_Element_Offset;
   begin
      while Length (Reader.Pending) < Count loop
         Receive_Socket (Reader.Sock, Chunk, Last);
         if Last < Chunk'First then
            raise Connection_Closed;
         end if;
         declare
            Text : String (1 .. Natural (Last));
         begin
            for I in Text'Range loop
               Text (I) := Character'Val (Chunk (Stream_Element_Offset (I)));
            end loop;
            Append (Reader.Pending, Text);
         end;
      end loop;
      return Result : constant String := Slice (Reader.Pending, 1, Count) do
         Delete (Reader.Pending, 1, Count);
      end return;
   end Read_Bytes;

   --  Send all of Data, however many calls the kernel needs
   procedure Send_All (Sock : Socket_Type; Data : String) is
      Chunk_Size : constant := 65_536;
      Chunk      : Stream_Element_Array (1 .. Chunk_Size);
      First      : Integer := Data'First;
      N          : Stream_Element_Offset;
      Sent       : Stream_Element_Offset;
      Done       : Stream_Element_Offset;
   begin
      while First <= Data'Last loop
         N := Stream_Element_Offset
           (Integer'Min (Chunk_Size, Data'Last - First + 1));
         for I in 1 .. N loop
            Chunk (I) :=
              Character'Pos (Data (First + Integer (I) - 1));
         end loop;
         Done := 0;
         while Done < N loop
            Send_Socket (Sock, Chunk (Done + 1 .. N), Sent);
            if Sent <= Done then
               raise Connection_Closed;
            end if;
            Done := Sent;
         end loop;
         First := First + Integer (N);
      end loop;
   end Send_All;

   function Encode (Message : JSON_Value) return String is
     (GNATCOLL.JSON.Write (Message) & ASCII.LF);

   function Encode (Message : JSON_Value; Payload : String) return String is
   begin
      Set_Field (Message, "bytes", Integer'(Payload'Length));
      return GNATCOLL.JSON.Write (Message) & ASCII.LF & Payload;
   end Encode;

   procedure Write
     (Sock    : Socket_Type;
      Message : JSON_Value) is
   begin
      Send_All (Sock, Encode (Message));
   end Write;

   procedure Write
     (Sock    : Socket_Type;
      Message : JSON_Value;
      Payload : String) is
   begin
      Send_All (Sock, Encode (Message, Payload));
   end Write;

   -- -------------------------------------------------------------------------

   function Field
     (Request : JSON_Value;
      Name    : String;
      Kinds   : String) return JSON_Value
   is
   begin
      if not Has_Field (Request, Name) then
         raise Request_Error with "missing """ & Name & """";
      end if;
      declare
         V : constant JSON_Value := Get (Request, Name);
      begin
         if (Kinds = "number"
             and then Kind (V) not in JSON_Int_Type | JSON_Float_Type)
           or else (Kinds = "integer" and then Kind (V) /= JSON_Int_Type)
           or else (Kinds = "boolean" and then Kind (V) /= JSON_Boolean_Type)
           or else (Kinds = "string" and then Kind (V) /= JSON_String_Type)
         then
            raise Request_Error with """" & Name & """ must be a " & Kinds;
         end if;
         return V;
      end;
   end Field;

   function Number_Field (Request : JSON_Value; Name : String) return Float is
      V : constant JSON_Value := Field (Request, Name, "number");
   begin
      if Kind (V) = JSON_Int_Type then
         return Float (Integer'(Get (V)));
      else
         return Float (Long_Float'(Get_Long_Float (V)));
      end if;
   end Number_Field;

   function Integer_Field (Request : JSON_Value; Name : String) return Integer
   is (Get (Field (Request, Name, "integer")));

   function Boolean_Field (Request : JSON_Value; Name : String) return Boolean
   is (Get (Field (Request, Name, "boolean")));

   function String_Field (Request : JSON_Value; Name : String) return String
   is (Get (Field (Request, Name, "string")));

   Alphabet : constant String :=
     "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

   function To_Base64 (Data : String) return String is
      Result : String (1 .. 4 * ((Data'Length + 2) / 3));
      R      : Natural := 0;
      I      : Integer := Data'First;
   begin
      while I <= Data'Last loop
         declare
            N     : constant Natural := Natural'Min (3, Data'Last - I + 1);
            B0    : constant Natural := Character'Pos (Data (I));
            B1    : constant Natural := (if N > 1 then Character'Pos (Data (I + 1)) else 0);
            B2    : constant Natural := (if N > 2 then Character'Pos (Data (I + 2)) else 0);
            Group : constant Natural := B0 * 2**16 + B1 * 2**8 + B2;
         begin
            Result (R + 1) := Alphabet (Group / 2**18 + 1);
            Result (R + 2) := Alphabet (Group / 2**12 mod 64 + 1);
            Result (R + 3) := (if N > 1 then Alphabet (Group / 2**6 mod 64 + 1) else '=');
            Result (R + 4) := (if N > 2 then Alphabet (Group mod 64 + 1) else '=');
            R := R + 4;
            I := I + 3;
         end;
      end loop;
      return Result;
   end To_Base64;

   function From_Base64 (Text : String) return String is
      Result : String (1 .. 3 * (Text'Length / 4));
      R      : Natural := 0;
      Group  : Natural := 0;
      Count  : Natural := 0;   --  sextets in Group
      Pad    : Natural := 0;
   begin
      if Text'Length mod 4 /= 0 then
         raise Request_Error with "not base64: length not a multiple of 4";
      end if;
      for C of Text loop
         declare
            V : Natural;
         begin
            if C = '=' then
               Pad := Pad + 1;
               V := 0;
            else
               V := Ada.Strings.Fixed.Index (Alphabet, (1 => C));
               if V = 0 or else Pad > 0 then
                  raise Request_Error with "not base64";
               end if;
               V := V - 1;
            end if;
            Group := Group * 64 + V;
            Count := Count + 1;
            if Count = 4 then
               Result (R + 1) := Character'Val (Group / 2**16);
               Result (R + 2) := Character'Val (Group / 2**8 mod 256);
               Result (R + 3) := Character'Val (Group mod 256);
               R := R + 3;
               Group := 0;
               Count := 0;
            end if;
         end;
      end loop;
      if Pad > 2 then
         raise Request_Error with "not base64";
      end if;
      return Result (1 .. R - Pad);
   end From_Base64;

   function To_JSON (X : Float) return JSON_Value is
     (Create (Long_Float'Value (Float'Image (X))));

end Server.Wire;
