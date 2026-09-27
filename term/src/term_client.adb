-- ***************************************************************************
--                ScopeBridge Terminal - Server Client Body
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

with Ada.Exceptions;  use Ada.Exceptions;

with Server.Wire;

package body Term_Client is

   use GNAT.Sockets;

   Sock    : Socket_Type;
   Input   : Server.Wire.Line_Reader;
   Greeted : JSON_Value := JSON_Null;
   Next_Id : Integer := 1;

   Default_Timeout : constant Duration := 60.0;   --  a capture takes seconds

   procedure Set_Timeout (Timeout : Duration) is
   begin
      Set_Socket_Option (Sock, Socket_Level,
                         (Name => Receive_Timeout, Timeout => Timeout));
   end Set_Timeout;

   --  The next message and its payload; Socket_Error on timeout
   procedure Read (Message : out JSON_Value; Payload : out Unbounded_String) is
   begin
      Message := Read (Server.Wire.Read_Line (Input));
      Payload := Null_Unbounded_String;
      if Has_Field (Message, "bytes") then
         Payload := To_Unbounded_String
           (Server.Wire.Read_Bytes (Input, Get (Message, "bytes")));
      end if;
   exception
      when E : Server.Wire.Connection_Closed =>
         raise Connection_Lost with "the server closed the connection " &
                                    Exception_Message (E);
   end Read;

   procedure Connect (Host : String; Port : Port_Type) is
      Address : Sock_Addr_Type;
      Payload : Unbounded_String;
   begin
      begin
         Address.Addr := Inet_Addr (Host);
      exception
         when Socket_Error =>
            Address.Addr := Addresses (Get_Host_By_Name (Host), 1);
      end;
      Address.Port := Port;
      Create_Socket (Sock);
      Connect_Socket (Sock, Address);
      Server.Wire.Attach (Input, Sock);
      Set_Timeout (Default_Timeout);
      Read (Greeted, Payload);
   exception
      when E : Socket_Error | Host_Error =>
         raise Connection_Lost with "cannot connect to scopebridge-server at " &
           Host & ":" & Port'Image & " (" & Exception_Message (E) & ")";
   end Connect;

   procedure Close is
   begin
      Close_Socket (Sock);
   exception
      when Socket_Error => null;
   end Close;

   function Hello return JSON_Value is (Greeted);

   procedure Request
     (Cmd      : String;
      Members  : JSON_Value;
      Reply    : out JSON_Value;
      Payload  : out Unbounded_String;
      On_Event : Event_Handler := null)
   is
      Message : constant JSON_Value := Create_Object;
      Id      : constant Integer := Next_Id;

      procedure Copy (Name : UTF8_String; Value : JSON_Value) is
      begin
         Set_Field (Message, Name, Value);
      end Copy;
   begin
      Next_Id := Next_Id + 1;
      if Kind (Members) = JSON_Object_Type then
         Map_JSON_Object (Members, Copy'Access);
      end if;
      Set_Field (Message, "id", Id);
      Set_Field (Message, "cmd", Cmd);
      Server.Wire.Write (Sock, Message);
      loop
         Read (Reply, Payload);
         if Has_Field (Reply, "event") then
            if On_Event /= null then
               On_Event (Reply, To_String (Payload));
            end if;
         elsif Has_Field (Reply, "id")
           and then Kind (Get (Reply, "id")) = JSON_Int_Type
           and then Integer'(Get (Reply, "id")) = Id
         then
            if not Boolean'(Get (Reply, "ok")) then
               raise Request_Failed with Get (Reply, "error");
            end if;
            return;
         end if;
      end loop;
   exception
      when E : Socket_Error | Server.Wire.Connection_Closed =>
         raise Connection_Lost with Exception_Message (E);
   end Request;

   procedure Request (Cmd : String; Members : JSON_Value := JSON_Null) is
      Reply   : JSON_Value;
      Payload : Unbounded_String;
   begin
      Request (Cmd, Members, Reply, Payload);
   end Request;

   procedure Next_Message
     (Timeout : Duration;
      Message : out JSON_Value;
      Payload : out Unbounded_String;
      Got     : out Boolean) is
   begin
      Set_Timeout (Timeout);
      begin
         Read (Message, Payload);
         Got := True;
      exception
         when Socket_Error =>   --  the timeout
            Got := False;
      end;
      Set_Timeout (Default_Timeout);
   end Next_Message;

end Term_Client;
