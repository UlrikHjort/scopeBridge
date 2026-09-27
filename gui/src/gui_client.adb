-- ***************************************************************************
--                   ScopeBridge GUI - Server Client Body
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

with Ada.Containers.Doubly_Linked_Lists;
with Ada.Containers.Ordered_Maps;
with Ada.Exceptions;         use Ada.Exceptions;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;
with Interfaces;

with Server.Wire;

package body Gui_Client is

   use GNAT.Sockets;

   type Received is record
      Text    : Unbounded_String;   --  the message line
      Payload : Unbounded_String;
   end record;

   package Message_Lists is new Ada.Containers.Doubly_Linked_Lists (Received);

   --  From the network task to Poll
   protected Inbox is
      procedure Put (Message : Received);
      procedure Close (Reason : String);
      procedure Take (Message : out Received; Found : out Boolean);
      function Closed return Boolean;
      function Reason return String;
   private
      Messages  : Message_Lists.List;
      Is_Closed : Boolean := False;
      Why       : Unbounded_String;
   end Inbox;

   protected body Inbox is
      procedure Put (Message : Received) is
      begin
         Messages.Append (Message);
      end Put;

      procedure Close (Reason : String) is
      begin
         Is_Closed := True;
         Why       := To_Unbounded_String (Reason);
      end Close;

      procedure Take (Message : out Received; Found : out Boolean) is
      begin
         Found := not Messages.Is_Empty;
         if Found then
            Message := Messages.First_Element;
            Messages.Delete_First;
         end if;
      end Take;

      function Closed return Boolean is (Is_Closed);
      function Reason return String is (To_String (Why));
   end Inbox;

   Sock      : Socket_Type;
   Connected : Boolean := False;
   Reported  : Boolean := False;   --  connection loss already reported

   task Receiver is
      entry Start;
   end Receiver;

   task body Receiver is
      Input : Server.Wire.Line_Reader;
   begin
      select
         accept Start;
      or
         terminate;
      end select;
      Server.Wire.Attach (Input, Sock);
      loop
         declare
            Line    : constant String := Server.Wire.Read_Line (Input);
            Message : Received := (To_Unbounded_String (Line),
                                   Null_Unbounded_String);
            Value   : constant JSON_Value := Read (Line);
         begin
            if Has_Field (Value, "bytes") then
               Message.Payload := To_Unbounded_String
                 (Server.Wire.Read_Bytes (Input, Get (Value, "bytes")));
            end if;
            Inbox.Put (Message);
         end;
      end loop;
   exception
      when E : others =>
         Inbox.Close (if Exception_Message (E) = ""
                      then "the server closed the connection"
                      else Exception_Message (E));
   end Receiver;

   package Handler_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type => Integer, Element_Type => Handler);

   Pending  : Handler_Maps.Map;   --  handlers of requests awaiting a reply
   Next_Id  : Integer := 1;
   On_Event : Handler;
   On_Error : Error_Handler;

   procedure Report (Text : String) is
   begin
      if On_Error /= null then
         On_Error (Text);
      end if;
   end Report;

   -- -------------------------------------------------------------------------

   procedure Connect
     (Host : String;
      Port : Port_Type)
   is
      Address : Sock_Addr_Type;
   begin
      --  Get_Host_By_Name does not accept a numeric address here
      begin
         Address.Addr := Inet_Addr (Host);
      exception
         when Socket_Error =>
            Address.Addr := Addresses (Get_Host_By_Name (Host), 1);
      end;
      Address.Port := Port;
      Create_Socket (Sock);
      Connect_Socket (Sock, Address);
      Connected := True;
      Receiver.Start;
   exception
      when E : Socket_Error | Host_Error =>
         raise Connect_Error with "cannot connect to scopebridge-server at " &
           Host & ":" & Port'Image & " (" & Exception_Message (E) & ")";
   end Connect;

   function Is_Connected return Boolean is
     (Connected and then not Inbox.Closed);

   procedure Disconnect is
   begin
      if Connected then
         Connected := False;
         Shutdown_Socket (Sock);
      end if;
   exception
      when Socket_Error => null;
   end Disconnect;

   procedure Set_Event_Handler (On_Event : Handler) is
   begin
      Gui_Client.On_Event := On_Event;
   end Set_Event_Handler;

   procedure Set_Error_Handler (On_Error : Error_Handler) is
   begin
      Gui_Client.On_Error := On_Error;
   end Set_Error_Handler;

   procedure Request
     (Cmd      : String;
      Members  : JSON_Value := JSON_Null;
      On_Reply : Handler    := null)
   is
      Message : constant JSON_Value := Create_Object;

      procedure Copy (Name : UTF8_String; Value : JSON_Value) is
      begin
         Set_Field (Message, Name, Value);
      end Copy;
   begin
      if not Is_Connected then
         return;   --  already reported
      end if;
      if Kind (Members) = JSON_Object_Type then
         Map_JSON_Object (Members, Copy'Access);
      end if;
      Set_Field (Message, "id", Next_Id);
      Set_Field (Message, "cmd", Cmd);
      Pending.Insert (Next_Id, On_Reply);
      Next_Id := Next_Id + 1;
      Server.Wire.Write (Sock, Message);
   exception
      when E : Socket_Error | Server.Wire.Connection_Closed =>
         Inbox.Close ("sending failed: " & Exception_Message (E));
   end Request;

   function Floats (Payload : String) return Units.Float_Array is
      function To_Float is new Ada.Unchecked_Conversion
        (Interfaces.Unsigned_32, Interfaces.IEEE_Float_32);
      use type Interfaces.Unsigned_32;
      Result : Units.Float_Array (1 .. Payload'Length / 4);
      Bits   : Interfaces.Unsigned_32;
      P      : Positive := Payload'First;
   begin
      for R of Result loop
         Bits := 0;
         for K in reverse 0 .. 3 loop   --  least significant byte first
            Bits := Interfaces.Shift_Left (Bits, 8) or
                    Interfaces.Unsigned_32 (Character'Pos (Payload (P + K)));
         end loop;
         R := Float (To_Float (Bits));
         P := P + 4;
      end loop;
      return Result;
   end Floats;

   procedure Poll is
      Message : Received;
      Found   : Boolean;
   begin
      for Count in 1 .. 100 loop   --  keep the GUI responsive under load
         Inbox.Take (Message, Found);
         exit when not Found;
         declare
            Value   : constant JSON_Value := Read (To_String (Message.Text));
            Payload : constant String     := To_String (Message.Payload);
         begin
            if Has_Field (Value, "event") then
               if On_Event /= null then
                  On_Event (Value, Payload);
               end if;
            elsif Has_Field (Value, "id")
              and then Kind (Get (Value, "id")) = JSON_Int_Type
              and then Pending.Contains (Get (Value, "id"))
            then
               declare
                  Id        : constant Integer := Get (Value, "id");
                  On_Reply  : constant Handler := Pending.Element (Id);
               begin
                  Pending.Delete (Id);
                  if On_Reply /= null then
                     On_Reply (Value, Payload);
                  elsif not Boolean'(Get (Value, "ok")) then
                     Report (Get (Value, "error"));
                  end if;
               end;
            end if;
         end;
      end loop;

      if Inbox.Closed and then not Reported then
         Reported := True;
         Report ("connection to scopebridge-server lost: " & Inbox.Reason);
      end if;
   end Poll;

end Gui_Client;
