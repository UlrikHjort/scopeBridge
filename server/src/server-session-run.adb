-- ***************************************************************************
--                    ScopeBridge Server - Session Loop
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

--  The session loop: clients come and go, their requests run one at a
--  time, and live updates run between them.  The requests themselves are
--  in the Execute_* subunits, by group.

with Ada.Calendar;  use Ada.Calendar;

with Rigol.Display;
with Rigol.IEEE488;

with Server.Log;

separate (Server.Session)
procedure Run
  (Scope        : in out Rigol.Oscilloscope;
   Listener     : in     Socket_Type;
   Source       : in     String;
   Web_Listener : in     Socket_Type := No_Socket;
   Web_Root     : in     String      := "")
is
   Clients : Client_Maps.Map;
   Dead    : Client_Lists.List;   --  gone; freed once their tasks end
   Current : Client_Id := 1;      --  the client whose request runs

   Interval  : Duration := 0.2;
   Next_Tick : Time     := Clock;

   --  What the scope's :WAVeform settings are known to be.  Each setting
   --  costs ~50 ms before the next query, so live updates send only the
   --  ones that change: after the first full preparation, switching
   --  channels needs only the source.
   Screen_Ready : Boolean := False;  --  mode, format and range prepared
   Wave_Source  : Natural := 0;      --  channel selected, 0 = unknown

   procedure Forget_Waveform_Settings is
   begin
      Screen_Ready := False;
      Wave_Source  := 0;
   end Forget_Waveform_Settings;

   --  Channel measured in live mode; 0 = none, -1 = the lowest
   --  displayed one.  One channel only: the scope takes ~0.5 s to
   --  re-arm its measurements whenever the measured channel changes.
   Live_Measure : Integer := -1;

   --  Items measured in live mode
   Live_Items      : Item_List (1 .. Max_Live_Items) :=
     (Default_Items & (Default_Items'Length + 1 .. Max_Live_Items =>
                         Rigol.Measure.Frequency));
   Live_Item_Count : Natural := Default_Items'Length;

   --  Live math and spectra: the scope's math channel, server
   --  arithmetic, and the server's FFT of one channel
   Live_Scope_Math : Boolean     := False;
   Live_Math       : Math_Op     := None;
   Live_Spectrum   : Natural     := 0;      --  channel, 0 = off
   Live_Window     : Window_Kind := Hann;

   Math_Source : constant := 3;   --  Wave_Source value for MATH

   function Object (Key, Value : String) return JSON_Value is
      Result : constant JSON_Value := Create_Object;
   begin
      Set_Field (Result, Key, Value);
      return Result;
   end Object;

   --  Whether any client is subscribed to live events
   function Live return Boolean is
   begin
      for C of Clients loop
         if C.Live then
            return True;
         end if;
      end loop;
      return False;
   end Live;

   --  To the client whose request is running
   procedure Send (Message : JSON_Value) is
   begin
      if Clients.Contains (Current) then
         Clients (Current).Box.Put (Encode (Message), Is_Event => True);
      end if;
   end Send;

   --  To every client subscribed to live events
   procedure Broadcast (Data : String) is
   begin
      for C of Clients loop
         if C.Live then
            C.Box.Put (Data, Is_Event => True);
         end if;
      end loop;
   end Broadcast;

   procedure Broadcast (Message : JSON_Value) is
   begin
      Broadcast (Encode (Message));
   end Broadcast;

   procedure Broadcast (Message : JSON_Value; Payload : String) is
   begin
      Broadcast (Encode (Message, Payload));
   end Broadcast;

   --  To every client: changes to state they share, such as references
   procedure Notify_All (Message : JSON_Value) is
      Data : constant String := Encode (Message);
   begin
      for C of Clients loop
         C.Box.Put (Data, Is_Event => True);
      end loop;
   end Notify_All;

   procedure Send_Error_Event (Text : String) is
      Event : constant JSON_Value := Object ("event", "error");
   begin
      Set_Field (Event, "error", Text);
      Broadcast (Event);
   end Send_Error_Event;

   function Measure_Object
     (Ch    : Channel;
      Items : Item_List) return JSON_Value
   is
      Result : constant JSON_Value := Create_Object;
   begin
      Set_Field (Result, "ch", Integer (Ch));
      for I of Items loop
         Set_Field (Result, Item_Name (I),
                    Measurement (Rigol.Measure.Get (Scope, I, Ch)));
      end loop;
      return Result;
   end Measure_Object;

   -- ----------------------------------------------------------------------
   --  Live mode
   -- ----------------------------------------------------------------------

   --  Make Ch's screen waveform the one :WAVeform:DATA? reads, sending
   --  only the settings that are not already right
   procedure Select_Screen (Ch : Channel) is
   begin
      if not Screen_Ready then
         Forget_Waveform_Settings;   --  in case preparing fails
         Prepare_Screen_Read (Scope, Ch);
         Screen_Ready := True;
         Wave_Source  := Natural (Ch);
      elsif Wave_Source /= Natural (Ch) then
         Wave_Source := 0;
         Set_Source (Scope, Ch);
         Wave_Source := Natural (Ch);
      end if;
   end Select_Screen;

   procedure Live_Update is separate;

   -- ----------------------------------------------------------------------
   --  Requests
   -- ----------------------------------------------------------------------

   --  Requests, by group: each executes Cmd if it is one of its own,
   --  and sets Done
   type Request_Group is (Settings, Live_Mode, Capturing, Buses, Timing, References);

   procedure Execute_Settings
     (Cmd     : String;
      Request : JSON_Value;
      Reply   : JSON_Value;
      Payload : in out Unbounded_String;
      Binary  : in out Boolean;
      Done    : out Boolean) is separate;

   procedure Execute_Live
     (Cmd     : String;
      Request : JSON_Value;
      Reply   : JSON_Value;
      Payload : in out Unbounded_String;
      Binary  : in out Boolean;
      Done    : out Boolean) is separate;

   procedure Execute_Captures
     (Cmd     : String;
      Request : JSON_Value;
      Reply   : JSON_Value;
      Payload : in out Unbounded_String;
      Binary  : in out Boolean;
      Done    : out Boolean) is separate;

   procedure Execute_Buses
     (Cmd     : String;
      Request : JSON_Value;
      Reply   : JSON_Value;
      Payload : in out Unbounded_String;
      Binary  : in out Boolean;
      Done    : out Boolean) is separate;

   procedure Execute_Timing
     (Cmd     : String;
      Request : JSON_Value;
      Reply   : JSON_Value;
      Payload : in out Unbounded_String;
      Binary  : in out Boolean;
      Done    : out Boolean) is separate;

   procedure Execute_References
     (Cmd     : String;
      Request : JSON_Value;
      Reply   : JSON_Value;
      Payload : in out Unbounded_String;
      Binary  : in out Boolean;
      Done    : out Boolean) is separate;

   --  Execute Request, filling Reply; Payload is set for replies that
   --  carry binary data
   procedure Execute
     (Request : JSON_Value;
      Reply   : JSON_Value;
      Payload : out Unbounded_String;
      Binary  : out Boolean)
   is
      Cmd : constant String := String_Field (Request, "cmd");
   begin
      Binary := False;

      if Cmd = "run" then
         Rigol.Run (Scope);
      elsif Cmd = "stop" then
         Rigol.Stop (Scope);
      elsif Cmd = "single" then
         Rigol.Single (Scope);
      elsif Cmd = "auto" then
         Rigol.Auto_Scale (Scope);
      elsif Cmd = "force" then
         Rigol.Force_Trigger (Scope);

      elsif Cmd = "screenshot" then
         Set_Field (Reply, "format", "bmp");
         Payload := To_Unbounded_String (Rigol.Display.Screenshot (Scope));
         Binary  := True;

      elsif Cmd = "scpi" then
         declare
            Text  : constant String  := String_Field (Request, "text");
            Query : constant Boolean :=
              Has_Field (Request, "query")
                and then Boolean_Field (Request, "query");
         begin
            Forget_Waveform_Settings;   --  the command may change them
            if Query then
               Set_Field (Reply, "response", Rigol.Query (Scope, Text));
            else
               Rigol.Send (Scope, Text);
            end if;
         end;

      else
         --  The request groups, each in its own file
         declare
            Done : Boolean;
         begin
            for Group in Request_Group loop
               case Group is
                  when Settings   => Execute_Settings   (Cmd, Request, Reply, Payload, Binary, Done);
                  when Live_Mode  => Execute_Live       (Cmd, Request, Reply, Payload, Binary, Done);
                  when Capturing  => Execute_Captures   (Cmd, Request, Reply, Payload, Binary, Done);
                  when Buses      => Execute_Buses      (Cmd, Request, Reply, Payload, Binary, Done);
                  when Timing     => Execute_Timing     (Cmd, Request, Reply, Payload, Binary, Done);
                  when References => Execute_References (Cmd, Request, Reply, Payload, Binary, Done);
               end case;
               exit when Done;
            end loop;
            if not Done then
               raise Request_Error with "unknown cmd """ & Cmd & """";
            end if;
         end;
      end if;
   end Execute;

   procedure Handle (Text : String) is
      Request : JSON_Value;
      Reply   : constant JSON_Value := Create_Object;
      Payload : Unbounded_String;
      Binary  : Boolean := False;

      procedure Fail (Message : String) is
      begin
         Set_Field (Reply, "ok", False);
         Set_Field (Reply, "error", Message);
      end Fail;
   begin
      Set_Field (Reply, "id", JSON_Null);
      begin
         Request := Read (Text);
         if Kind (Request) /= JSON_Object_Type then
            raise Request_Error with "a request must be a JSON object";
         end if;
         if Has_Field (Request, "id") then
            Set_Field (Reply, "id", JSON_Value'(Get (Request, "id")));
         end if;
         Set_Field (Reply, "ok", True);
         Execute (Request, Reply, Payload, Binary);
      exception
         when E : Request_Error =>
            Fail (Exception_Message (E));
         when E : Rigol_Transport.Communication_Error
                | Rigol_Transport.Device_Error =>
            Fail ("scope: " & Exception_Message (E));
         when Rigol.Not_Connected =>
            Fail ("scope: not connected");
         when E : Constraint_Error =>
            Fail ("invalid value: " & Exception_Message (E));
         when E : others =>
            Fail (Exception_Name (E) & ": " & Exception_Message (E));
      end;

      declare
         --  Encoding adds "bytes" for a payload, which the log shows
         Data : constant String :=
           (if Binary and then Get (Reply, "ok")
            then Encode (Reply, To_String (Payload)) else Encode (Reply));
      begin
         Server.Log.Reply (Positive (Current), Reply);
         if Clients.Contains (Current) then
            Clients (Current).Box.Put (Data, Is_Event => False);
         end if;
      end;
   end Handle;

   procedure Say (Text : String) is
   begin
      Ada.Text_IO.Put_Line (Text);
      Ada.Text_IO.Flush;
   end Say;

   procedure Hello (Id : Client_Id) is
      Message : constant JSON_Value := Object ("event", "hello");
   begin
      Set_Field (Message, "protocol", Integer (Protocol_Version));
      Set_Field (Message, "source", Source);
      Set_Field (Message, "client", Integer (Id));
      begin
         Set_Field (Message, "idn", Rigol.IEEE488.Get_IDN (Scope));
      exception
         when E : Rigol_Transport.Communication_Error =>
            Set_Field (Message, "idn", JSON_Null);
            Set_Field (Message, "error", "scope: " & Exception_Message (E));
      end;
      Clients (Id).Box.Put (Encode (Message), Is_Event => False);
   end Hello;

   --  Free clients that are gone once their tasks have ended
   procedure Reap is
      use Client_Lists;
      Position : Cursor := Dead.First;
      Next     : Cursor;
   begin
      while Has_Element (Position) loop
         Next := Client_Lists.Next (Position);
         declare
            C : Client := Element (Position);
         begin
            if C.Read_Task'Terminated and then C.Send_Task'Terminated then
               Free (C.Read_Task);
               Free (C.Send_Task);
               Free (C.Box);
               Dead.Delete (Position);
            end if;
         end;
         Position := Next;
      end loop;
   end Reap;

   procedure Process (Item : Input) is
   begin
      case Item.Kind is
         when Connected =>
            Reap;
            declare
               C : Client;
            begin
               C.Box       := new Outbox;
               C.Send_Task := new Writer (C.Box, Item.Web);
               C.Read_Task := new Reader (Item.Client, Item.Web);
               C.Send_Task.Start (Item.Sock);
               C.Read_Task.Start (Item.Sock);
               Clients.Insert (Item.Client, C);
            end;
            Say ("client" & Item.Client'Image & " connected from " &
                 To_String (Item.Text) & (if Item.Web then " (web)" else ""));
            Server.Log.Connected (Positive (Item.Client), To_String (Item.Text));
            Hello (Item.Client);

         when Line =>
            if Clients.Contains (Item.Client) then
               Current := Item.Client;
               Server.Log.Request (Positive (Current), To_String (Item.Text));
               Handle (To_String (Item.Text));
            end if;

         when Disconnected =>
            if Clients.Contains (Item.Client) then
               Clients (Item.Client).Box.Close;
               Dead.Append (Clients (Item.Client));
               Clients.Delete (Item.Client);
               Say ("client" & Item.Client'Image & " disconnected");
               Server.Log.Disconnected (Positive (Item.Client));
            end if;
      end case;
   end Process;

   Accepting     : Acceptor;
   Web_Accepting : Acceptor;
   Item          : Input;
begin
   Accepting.Start (Listener, False, "");
   if Web_Listener /= No_Socket then
      Web_Accepting.Start (Web_Listener, True, Web_Root);
   end if;
   loop
      if Live then
         select
            Inputs.Get (Item);
            Process (Item);
         or
            delay until Next_Tick;
            Next_Tick := Clock + Interval;   --  Live_Update may delay it
            Live_Update;
         end select;
      else
         Inputs.Get (Item);
         Process (Item);
      end if;
   end loop;
end Run;
