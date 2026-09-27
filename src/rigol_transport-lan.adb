-- ***************************************************************************
--                      Rigol - LAN Transport Body
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

with Ada.Streams;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;

package body Rigol_Transport.LAN is

   use GNAT.Sockets;

   --  Needed to compare Stream_Element_Offset values returned by
   --  Send_Socket / Receive_Socket against array bounds.
   use type Ada.Streams.Stream_Element_Offset;

   Terminator : constant String := "" & ASCII.LF;

   -- -------------------------------------------------------------------------

   function Address_Of (Host : String) return Inet_Addr_Type is
   begin
      --  Get_Host_By_Name does not accept a numeric address here
      begin
         return Inet_Addr (Host);
      exception
         when Socket_Error =>
            null;   --  not a numeric address: a name
      end;
      return Addresses (Get_Host_By_Name (Host), 1);
   exception
      when Host_Error =>
         raise Device_Error with "Unknown host: " & Host;
   end Address_Of;

   --  A connection to T.Host, T.Port
   procedure Connect (T : in out Handle) is
      Host    : constant String := To_String (T.Host);
      Port    : constant Port_Type := T.Port;
      Address : Sock_Addr_Type;
   begin
      --  GNAT.Sockets no longer requires an explicit Initialize call;
      --  the runtime performs the one-time setup itself.
      Address.Addr := Address_Of (Host);
      Address.Port := Port;

      Create_Socket (T.Sock);
      Set_Socket_Option (T.Sock, Socket_Level,
                         (Name => Reuse_Address, Enabled => True));

      --  Send each command at once.  With Nagle's algorithm a query right
      --  after a setting waits for the scope's delayed ACK: measured on a
      --  DS1202Z-E over Wi-Fi, 175 ms per setting+query pair instead of 57.
      Set_Socket_Option (T.Sock, IP_Protocol_For_TCP_Level,
                         (Name => No_Delay, Enabled => True));
      Set_Socket_Option (T.Sock, Socket_Level,
                         (Name => Receive_Timeout, Timeout => T.Timeout));

      begin
         Connect_Socket (T.Sock, Address);
      exception
         when Socket_Error =>
            Close_Socket (T.Sock);
            T.Sock      := No_Socket;
            T.Connected := False;
            raise Device_Error
              with "Cannot connect to " & Host & ":" & Port'Image;
      end;

      T.Connected := True;
      T.Broken    := False;
   end Connect;

   procedure Open
     (T    : out Handle;
      Host : in  String;
      Port : in  Port_Type := Default_Port) is
   begin
      T.Host := To_Unbounded_String (Host);
      T.Port := Port;
      Connect (T);
   end Open;

   --  After the connection broke: the old socket goes, and the next
   --  command connects again
   procedure Lost (T : in out Handle) is
   begin
      if not T.Broken then
         Close_Socket (T.Sock);
         T.Sock   := No_Socket;
         T.Broken := True;
      end if;
   exception
      when Socket_Error =>
         T.Broken := True;
   end Lost;

   -- -------------------------------------------------------------------------

   --  Throw away anything the scope sent that no reply read.  Replies are
   --  matched to queries only by order, so one stray byte would shift
   --  every later reply by one: the DS1202Z-E ends "measure error!" with
   --  two LFs, and the second would otherwise be taken as the answer to
   --  the next query.  Anything still unread when a new command goes out
   --  belongs to no query.
   procedure Discard_Leftovers (T : Handle) is
      Pending : Request_Type (N_Bytes_To_Read);
      Chunk   : Ada.Streams.Stream_Element_Array (1 .. 4_096);
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      loop
         Control_Socket (T.Sock, Pending);
         exit when Pending.Size = 0;
         Receive_Socket
           (T.Sock,
            Chunk (1 .. Ada.Streams.Stream_Element_Offset
                          (Natural'Min (Chunk'Length, Pending.Size))),
            Last);
         exit when Last < Chunk'First;   --  closed; the next read reports it
      end loop;
   exception
      when Socket_Error =>
         null;   --  the next read reports a broken connection
   end Discard_Leftovers;

   overriding procedure Send
     (T       : in out Handle;
      Command : in     String)
   is
      Msg  : constant String := Command & Terminator;
      Data : Ada.Streams.Stream_Element_Array (1 .. Msg'Length);
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      if T.Broken then
         begin
            Connect (T);
         exception
            when Device_Error =>
               raise Communication_Error with "LAN connection lost, and "
                 & To_String (T.Host) & " does not answer";
         end;
      end if;
      Discard_Leftovers (T);
      for I in Msg'Range loop
         Data (Ada.Streams.Stream_Element_Offset (I - Msg'First + 1)) :=
           Character'Pos (Msg (I));
      end loop;

      begin
         Send_Socket (T.Sock, Data, Last);
      exception
         when Socket_Error =>
            Lost (T);
            raise Communication_Error with "LAN connection lost";
      end;
      if Last /= Data'Last then
         raise Communication_Error with "LAN send incomplete";
      end if;
   end Send;

   -- -------------------------------------------------------------------------

   --  Receive exactly Count bytes
   procedure Set_Timeout
     (T       : in out Handle;
      Timeout : in     Duration) is
   begin
      T.Timeout := Timeout;
      if T.Connected then
         Set_Socket_Option (T.Sock, Socket_Level,
                            (Name => Receive_Timeout, Timeout => Timeout));
      end if;
   end Set_Timeout;

   function Receive_Exact (T : in out Handle; Count : Natural) return String is
      use Ada.Streams;
      Result : String (1 .. Count);
      Got    : Natural := 0;
      Chunk  : Stream_Element_Array (1 .. 65_536);
      Last   : Stream_Element_Offset;
   begin
      while Got < Count loop
         begin
            Receive_Socket
              (T.Sock,
               Chunk (1 .. Stream_Element_Offset
                             (Natural'Min (Chunk'Length, Count - Got))),
               Last);
         exception
            when E : Socket_Error =>
               --  A read timeout is Resource_Temporarily_Unavailable: the
               --  connection is fine, the scope just did not answer
               if Resolve_Exception (E) in Connection_Reset_By_Peer | Connection_Refused
                                         | Network_Is_Unreachable | Broken_Pipe
                                         | Transport_Endpoint_Not_Connected
                                         | Connection_Timed_Out
               then
                  Lost (T);
                  raise Communication_Error with "LAN connection lost";
               end if;
               raise Communication_Error with "LAN read failed or timed out";
         end;
         if Last < Chunk'First then
            Lost (T);
            raise Communication_Error with "LAN connection closed";
         end if;
         for I in 1 .. Last loop
            Result (Got + Natural (I)) := Character'Val (Chunk (I));
         end loop;
         Got := Got + Natural (Last);
      end loop;
      return Result;
   end Receive_Exact;

   --  What the scope sends, unterminated, for a query it does not know
   Command_Error : constant String := "Command error";

   overriding function Query
     (T       : in out Handle;
      Command : in     String) return String
   is
      First : Character;
   begin
      Send (T, Command);
      First := Receive_Exact (T, 1) (1);

      if First = '#' then
         --  Definite-length block, #<n><length><data>: binary data may
         --  contain LF, so it is read by length, not up to a terminator.
         declare
            N_Digits : constant Character := Receive_Exact (T, 1) (1);
         begin
            if N_Digits not in '1' .. '9' then
               raise Communication_Error with "LAN: malformed block header";
            end if;
            declare
               Len_Str : constant String :=
                 Receive_Exact (T, Character'Pos (N_Digits) -
                                   Character'Pos ('0'));
               Data    : constant String :=
                 Receive_Exact (T, Natural'Value (Len_Str));
               Term    : Character := Receive_Exact (T, 1) (1);
            begin
               if Term = ASCII.CR then
                  Term := Receive_Exact (T, 1) (1);
               end if;
               return '#' & N_Digits & Len_Str & Data;
            end;
         end;
      end if;

      --  Text response: read up to the LF terminator
      declare
         Result : Unbounded_String := To_Unbounded_String ((1 => First));
         Ch     : Character := First;
      begin
         while Ch /= ASCII.LF loop
            if Result = Command_Error then
               --  Probably the scope's unterminated reply to an unknown
               --  query: if nothing follows at once, it is
               begin
                  Set_Socket_Option (T.Sock, Socket_Level,
                                     (Name => Receive_Timeout, Timeout => 0.3));
                  Ch := Receive_Exact (T, 1) (1);
                  Set_Socket_Option (T.Sock, Socket_Level,
                                     (Name => Receive_Timeout, Timeout => T.Timeout));
               exception
                  when Communication_Error =>
                     Set_Socket_Option (T.Sock, Socket_Level,
                                        (Name => Receive_Timeout, Timeout => T.Timeout));
                     raise Communication_Error
                       with "the scope rejected the query (Command error)";
               end;
            else
               Ch := Receive_Exact (T, 1) (1);
            end if;
            Append (Result, Ch);
         end loop;

         --  Strip the LF and a CR before it
         Head (Result, Length (Result) - 1);
         if Length (Result) > 0
           and then Element (Result, Length (Result)) = ASCII.CR
         then
            Head (Result, Length (Result) - 1);
         end if;
         return To_String (Result);
      end;
   end Query;

   -- -------------------------------------------------------------------------

   overriding procedure Close (T : in out Handle) is
   begin
      if T.Connected and then not T.Broken then
         Close_Socket (T.Sock);
         T.Sock      := No_Socket;
         T.Connected := False;
      end if;
   end Close;

   -- -------------------------------------------------------------------------

   overriding function Is_Open (T : Handle) return Boolean is
   begin
      return T.Connected;
   end Is_Open;

end Rigol_Transport.LAN;
