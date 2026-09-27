-- ***************************************************************************
--                 ScopeBridge Server - Client Session Body
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
with Ada.Containers.Doubly_Linked_Lists;
with Ada.Containers.Ordered_Maps;
with Ada.Exceptions;           use Ada.Exceptions;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with Interfaces;

with GNATCOLL.JSON;            use GNATCOLL.JSON;

with Rigol.Channel;
with Rigol.Math;
with Rigol.Measure;
with Rigol.Trigger;
with Rigol.Waveform;           use Rigol.Waveform;
with Rigol_Transport;

with Server.Spectrum;
with Server.Web;
with Server.Wire;              use Server.Wire;

package body Server.Session is

   use GNAT.Sockets;

   subtype Channel is Rigol.Channel.Channel_Number;
   use type Rigol.Channel.Channel_Number;

   Max_Columns : constant := 10_000;
   Max_Samples : constant := 1_000_000;

   --  The most recent capture of each channel, kept across sessions
   type Capture is record
      Pre  : Preamble;
      Data : Raw_Array_Access;
   end record;

   Captures : array (Channel) of Capture;

   -- -------------------------------------------------------------------------
   --  Values in protocol form
   -- -------------------------------------------------------------------------

   Probe_Values : constant array (Rigol.Channel.Probe_Ratio) of Float :=
     (0.01, 0.02, 0.05, 0.1, 0.2, 0.5,
      1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0);

   function Lower_Image (S : String) return String renames To_Lower;

   function To_Bytes (Data : Raw_Array) return String is
      Result : String (1 .. Data'Length);
   begin
      for I in Data'Range loop
         Result (I - Data'First + 1) := Character'Val (Data (I));
      end loop;
      return Result;
   end To_Bytes;

   --  The waveform members of docs/PROTOCOL.md
   procedure Add_Waveform
     (Message : JSON_Value;
      Pre     : Preamble;
      Points  : Natural) is
   begin
      Set_Field (Message, "points",   Points);
      Set_Field (Message, "x_inc",    To_JSON (Pre.X_Increment));
      Set_Field (Message, "x_origin", To_JSON (Pre.X_Origin));
      Set_Field (Message, "y_inc",    To_JSON (Pre.Y_Increment));
      Set_Field (Message, "y_origin", To_JSON (Pre.Y_Origin));
      Set_Field (Message, "y_ref",    To_JSON (Pre.Y_Reference));
   end Add_Waveform;

   -- -------------------------------------------------------------------------
   --  Measurement items
   -- -------------------------------------------------------------------------

   subtype Item is Rigol.Measure.Measure_Item;
   type Item_List is array (Positive range <>) of Item;

   --  Items the protocol offers, in the order the docs list them
   Supported : constant Item_List :=
     (Rigol.Measure.Frequency, Rigol.Measure.Period,
      Rigol.Measure.VPP, Rigol.Measure.VMAX, Rigol.Measure.VMIN,
      Rigol.Measure.VTOP, Rigol.Measure.VBASE, Rigol.Measure.VAMP,
      Rigol.Measure.VAVG, Rigol.Measure.VRMS,
      Rigol.Measure.Rise_Time, Rigol.Measure.Fall_Time,
      Rigol.Measure.Pos_Width, Rigol.Measure.Neg_Width,
      Rigol.Measure.Pos_Duty, Rigol.Measure.Neg_Duty);

   function Item_Name (I : Item) return String is
     (case I is
         when Rigol.Measure.Frequency => "freq",
         when Rigol.Measure.Period    => "period",
         when Rigol.Measure.VPP       => "vpp",
         when Rigol.Measure.VMAX      => "vmax",
         when Rigol.Measure.VMIN      => "vmin",
         when Rigol.Measure.VTOP      => "vtop",
         when Rigol.Measure.VBASE     => "vbase",
         when Rigol.Measure.VAMP      => "vamp",
         when Rigol.Measure.VAVG      => "vavg",
         when Rigol.Measure.VRMS      => "vrms",
         when Rigol.Measure.Rise_Time => "rise",
         when Rigol.Measure.Fall_Time => "fall",
         when Rigol.Measure.Pos_Width => "pwidth",
         when Rigol.Measure.Neg_Width => "nwidth",
         when Rigol.Measure.Pos_Duty  => "pduty",
         when Rigol.Measure.Neg_Duty  => "nduty",
         when others                  => "");

   Default_Items : constant Item_List :=
     (Rigol.Measure.Frequency, Rigol.Measure.VPP, Rigol.Measure.VRMS);

   --  The scope keeps at most 5 measurement items armed; querying more
   --  makes it re-arm on every query (~0.4 s each instead of ~1 ms)
   Max_Live_Items : constant := 5;

   --  The items named in Request's array member Name (at most Max)
   function Items_Field
     (Request : JSON_Value;
      Name    : String;
      Max     : Natural) return Item_List
   is
      function Names return String is
         Result : Unbounded_String;
      begin
         for I of Supported loop
            Append (Result, (if Length (Result) = 0 then "" else ", ") &
                            Item_Name (I));
         end loop;
         return To_String (Result);
      end Names;
   begin
      if Kind (Get (Request, Name)) /= JSON_Array_Type then
         raise Request_Error with """" & Name & """ must be an array";
      end if;
      declare
         Names_In : constant JSON_Array := Get (Request, Name);
         Result   : Item_List (1 .. Length (Names_In));
      begin
         if Result'Length > Max then
            raise Request_Error
              with """" & Name & """ may have at most" & Max'Image & " items";
         end if;
         for K in Result'Range loop
            declare
               V     : constant JSON_Value := Get (Names_In, K);
               Found : Boolean := False;
            begin
               if Kind (V) = JSON_String_Type then
                  for I of Supported loop
                     if Item_Name (I) = String'(Get (V)) then
                        Result (K) := I;
                        Found := True;
                     end if;
                  end loop;
               end if;
               if not Found then
                  raise Request_Error
                    with """" & Name & """ items must be among: " & Names;
               end if;
            end;
         end loop;
         return Result;
      end;
   end Items_Field;

   function Measurement (X : Float) return JSON_Value is
     (if Rigol.Measure.Is_Valid (X) then To_JSON (X) else JSON_Null);

   -- -------------------------------------------------------------------------
   --  Request members
   -- -------------------------------------------------------------------------

   function Channel_Field (Request : JSON_Value) return Channel is
      N : constant Integer := Integer_Field (Request, "ch");
   begin
      if N not in 1 .. 2 then
         raise Request_Error with """ch"" must be 1 or 2";
      end if;
      return Channel (N);
   end Channel_Field;

   function Probe_Field
     (Request : JSON_Value) return Rigol.Channel.Probe_Ratio
   is
      Value : constant Float := Number_Field (Request, "probe");
   begin
      for P in Probe_Values'Range loop
         if abs (Value - Probe_Values (P)) <= Probe_Values (P) * 1.0E-3 then
            return P;
         end if;
      end loop;
      raise Request_Error with """probe"" must be one of 0.01, 0.02, 0.05, "
        & "0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000";
   end Probe_Field;

   function Coupling_Field
     (Request : JSON_Value) return Rigol.Channel.Coupling_Type
   is
      S : constant String := String_Field (Request, "coupling");
   begin
      if    S = "ac"  then return Rigol.Channel.AC;
      elsif S = "dc"  then return Rigol.Channel.DC;
      elsif S = "gnd" then return Rigol.Channel.GND;
      end if;
      raise Request_Error with """coupling"" must be ""ac"", ""dc"" or ""gnd""";
   end Coupling_Field;

   function Source_Field
     (Request : JSON_Value) return Rigol.Trigger.Trigger_Source
   is
      S : constant String := String_Field (Request, "source");
   begin
      if    S = "ch1" then return Rigol.Trigger.CH1;
      elsif S = "ch2" then return Rigol.Trigger.CH2;
      elsif S = "ac"  then return Rigol.Trigger.AC_Line;
      elsif S = "ext" then return Rigol.Trigger.EXT;
      end if;
      raise Request_Error
        with """source"" must be ""ch1"", ""ch2"", ""ac"" or ""ext""";
   end Source_Field;

   function Slope_Field
     (Request : JSON_Value) return Rigol.Trigger.Edge_Slope
   is
      S : constant String := String_Field (Request, "slope");
   begin
      if    S = "rising"  then return Rigol.Trigger.Rising;
      elsif S = "falling" then return Rigol.Trigger.Falling;
      elsif S = "either"  then return Rigol.Trigger.Either;
      end if;
      raise Request_Error
        with """slope"" must be ""rising"", ""falling"" or ""either""";
   end Slope_Field;

   function Sweep_Field
     (Request : JSON_Value) return Rigol.Trigger.Trigger_Sweep
   is
      S : constant String := String_Field (Request, "sweep");
   begin
      if    S = "auto"   then return Rigol.Trigger.Auto;
      elsif S = "normal" then return Rigol.Trigger.Normal;
      elsif S = "single" then return Rigol.Trigger.Single;
      end if;
      raise Request_Error
        with """sweep"" must be ""auto"", ""normal"" or ""single""";
   end Sweep_Field;

   function Source_Image (S : Rigol.Trigger.Trigger_Source) return String is
     (case S is
         when Rigol.Trigger.CH1     => "ch1",
         when Rigol.Trigger.CH2     => "ch2",
         when Rigol.Trigger.AC_Line => "ac",
         when Rigol.Trigger.EXT     => "ext");

   --  Sample range "first" .. "last" (0-based) of a capture, checked
   procedure Range_Fields
     (Request     : JSON_Value;
      Points      : Natural;
      First, Last : out Natural)
   is
      F : constant Integer := Integer_Field (Request, "first");
      L : constant Integer := Integer_Field (Request, "last");
   begin
      if F < 0 or else L < F or else L >= Points then
         raise Request_Error
           with "need 0 <= first <= last <" & Points'Image;
      end if;
      First := F;
      Last  := L;
   end Range_Fields;

   function Captured (Ch : Channel) return Capture is
   begin
      if Captures (Ch).Data = null then
         raise Request_Error with "channel" & Ch'Image & " not captured yet";
      end if;
      return Captures (Ch);
   end Captured;

   -- -------------------------------------------------------------------------
   --  Math and spectra
   -- -------------------------------------------------------------------------

   use Server.Spectrum;

   --  Float32 values, least significant byte first: the payload of "math"
   --  and "spectrum" messages
   function To_Float32_Bytes (Values : Real_Array) return String is
      function Bits is new Ada.Unchecked_Conversion
        (Interfaces.IEEE_Float_32, Interfaces.Unsigned_32);
      use type Interfaces.Unsigned_32;
      Result : String (1 .. 4 * Values'Length);
      P      : Positive := 1;
      B      : Interfaces.Unsigned_32;
   begin
      for V of Values loop
         B := Bits (Interfaces.IEEE_Float_32 (V));
         for K in 0 .. 3 loop
            Result (P + K) := Character'Val
              (Natural (Interfaces.Shift_Right (B, 8 * K) and 16#FF#));
         end loop;
         P := P + 4;
      end loop;
      return Result;
   end To_Float32_Bytes;

   function To_JSON (X : Long_Float) return JSON_Value is
     (Server.Wire.To_JSON (Float (X)));

   --  Server arithmetic on the two channels
   type Math_Op is (None, Add, Sub, Mul);

   function Math_Name (Op : Math_Op) return String is
     (case Op is when None => "none", when Add => "add",
                 when Sub => "sub", when Mul => "mul");

   function Math_Field (Request : JSON_Value; Name : String) return Math_Op is
      S : constant String := String_Field (Request, Name);
   begin
      for Op in Add .. Mul loop
         if S = Math_Name (Op) then
            return Op;
         end if;
      end loop;
      raise Request_Error with """" & Name & """ must be ""add"", ""sub"" or ""mul""";
   end Math_Field;

   function Apply (Op : Math_Op; A, B : Long_Float) return Long_Float is
     (case Op is when Add => A + B, when Sub => A - B, when Mul => A * B,
                 when None => 0.0);

   function Math_Unit (Op : Math_Op) return String is
     (if Op = Mul then "V^2" else "V");

   Window_Names : constant array (Window_Kind) of Unbounded_String :=
     (To_Unbounded_String ("rect"), To_Unbounded_String ("hann"),
      To_Unbounded_String ("hamming"), To_Unbounded_String ("blackman"),
      To_Unbounded_String ("flattop"));

   function Window_Name (W : Window_Kind) return String is
     (To_String (Window_Names (W)));

   function Window_Field (Request : JSON_Value) return Window_Kind is
      S : constant String := String_Field (Request, "window");
   begin
      for W in Window_Kind loop
         if S = Window_Name (W) then
            return W;
         end if;
      end loop;
      raise Request_Error with """window"" must be ""rect"", ""hann"", "
        & """hamming"", ""blackman"" or ""flattop""";
   end Window_Field;

   --  The spectrum members of docs/PROTOCOL.md
   procedure Add_Spectrum
     (Message   : JSON_Value;
      Points    : Natural;
      F0, DF    : Long_Float;
      Bin_Width : Long_Float;
      Unit      : String;
      Window    : String) is
   begin
      Set_Field (Message, "points", Points);
      Set_Field (Message, "f0", To_JSON (F0));
      Set_Field (Message, "df", To_JSON (DF));
      Set_Field (Message, "bin_width", To_JSON (Bin_Width));
      Set_Field (Message, "unit", Unit);
      Set_Field (Message, "window", Window);
   end Add_Spectrum;

   --  The last capture spectrum of each channel, so zooming and panning
   --  over it only re-reduces the bins
   type Real_Access is access Real_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Real_Array, Real_Access);

   type Spectrum_Cache is record
      First, Last : Natural     := 0;
      Window      : Window_Kind := Hann;
      Wide        : Boolean     := False;
      Bins        : Real_Access;
      Bin_Width   : Long_Float  := 0.0;   --  spacing of the bins
      Resolution  : Long_Float  := 0.0;   --  what they resolve (RBW)
      Decimation  : Positive    := 1;
   end record;

   Cached : array (Channel) of Spectrum_Cache;

   --  The scope's math channel, in protocol names
   function Operator_Name (Op : Rigol.Math.Operator) return String is
     (case Op is
         when Rigol.Math.Add      => "add",
         when Rigol.Math.Subtract => "sub",
         when Rigol.Math.Multiply => "mul",
         when Rigol.Math.Divide   => "div",
         when Rigol.Math.FFT      => "fft",
         when Rigol.Math.Other    => "other");

   function Source_Name (S : Rigol.Math.Source) return String is
     (case S is
         when Rigol.Math.CH1   => "ch1",
         when Rigol.Math.CH2   => "ch2",
         when Rigol.Math.Other => "other");

   function Scope_Window_Name (W : Rigol.Math.FFT_Window) return String is
     (case W is
         when Rigol.Math.Rectangle => "rect",
         when Rigol.Math.Hanning   => "hann",
         when Rigol.Math.Hamming   => "hamming",
         when Rigol.Math.Blackman  => "blackman",
         when Rigol.Math.Flattop   => "flattop",
         when Rigol.Math.Triangle  => "triangle");

   function Scope_Operator_Field
     (Request : JSON_Value) return Rigol.Math.Settable_Operator
   is
      S : constant String := String_Field (Request, "operator");
   begin
      for Op in Rigol.Math.Settable_Operator loop
         if S = Operator_Name (Op) then
            return Op;
         end if;
      end loop;
      raise Request_Error with """operator"" must be ""add"", ""sub"", "
        & """mul"", ""div"" or ""fft""";
   end Scope_Operator_Field;

   function Scope_Source_Field
     (Request : JSON_Value; Name : String) return Rigol.Math.Channel_Source
   is
      S : constant String := String_Field (Request, Name);
   begin
      if S = "ch1" then
         return Rigol.Math.CH1;
      elsif S = "ch2" then
         return Rigol.Math.CH2;
      end if;
      raise Request_Error with """" & Name & """ must be ""ch1"" or ""ch2""";
   end Scope_Source_Field;

   function Scope_Window_Field
     (Request : JSON_Value) return Rigol.Math.FFT_Window
   is
      S : constant String := String_Field (Request, "fft_window");
   begin
      for W in Rigol.Math.FFT_Window loop
         if S = Scope_Window_Name (W) then
            return W;
         end if;
      end loop;
      raise Request_Error with """fft_window"" must be ""rect"", ""hann"", "
        & """hamming"", ""blackman"", ""flattop"" or ""triangle""";
   end Scope_Window_Field;




   -- -------------------------------------------------------------------------
   --  Reference waveforms: screens kept by the server for comparison,
   --  shared by all clients
   -- -------------------------------------------------------------------------

   Max_Refs : constant := 4;
   subtype Ref_Slot is Positive range 1 .. Max_Refs;

   type Reference is record
      Used  : Boolean := False;
      Pre   : Preamble;
      Data  : Unbounded_String;   --  raw samples, one per character
      Ch    : Natural := 0;       --  channel it came from, 0 = loaded
      Label : Unbounded_String;
   end record;

   Refs : array (Ref_Slot) of Reference;

   Max_Ref_Points : constant := 1_000_000;


   -- -------------------------------------------------------------------------
   --  Clients
   --
   --  Each client has a reader task, which passes its request lines to the
   --  session loop through Inputs, and a writer task, which sends what the
   --  loop puts in its Outbox.  Only the session loop talks to the scope,
   --  one request at a time, and only it keeps the table of clients.
   -- -------------------------------------------------------------------------

   type Client_Id is new Positive;

   --  Live events a client may have waiting before further ones are
   --  dropped, so a slow client cannot hold up the others; replies are
   --  never dropped
   Max_Queued_Events : constant := 32;

   type Outgoing is record
      Data     : Unbounded_String;   --  message line and payload, encoded
      Is_Event : Boolean;
   end record;

   package Outgoing_Lists is new Ada.Containers.Doubly_Linked_Lists (Outgoing);

   protected type Outbox is
      procedure Put (Data : String; Is_Event : Boolean);
      procedure Close;
      --  The next message; Closed once the box is closed and empty
      entry Get (Data : out Unbounded_String; Closed : out Boolean);
   private
      Items     : Outgoing_Lists.List;
      Events    : Natural := 0;
      Is_Closed : Boolean := False;
   end Outbox;

   protected body Outbox is
      procedure Put (Data : String; Is_Event : Boolean) is
      begin
         if Is_Closed or else (Is_Event and then Events >= Max_Queued_Events)
         then
            return;
         end if;
         Items.Append ((To_Unbounded_String (Data), Is_Event));
         if Is_Event then
            Events := Events + 1;
         end if;
      end Put;

      procedure Close is
      begin
         Is_Closed := True;
      end Close;

      entry Get (Data : out Unbounded_String; Closed : out Boolean)
        when not Items.Is_Empty or else Is_Closed
      is
      begin
         Closed := Items.Is_Empty;
         if not Closed then
            Data := Items.First_Element.Data;
            if Items.First_Element.Is_Event then
               Events := Events - 1;
            end if;
            Items.Delete_First;
         end if;
      end Get;
   end Outbox;

   type Outbox_Access is access Outbox;

   --  What reaches the session loop
   type Input_Kind is (Connected, Line, Disconnected);

   type Input is record
      Kind   : Input_Kind;
      Client : Client_Id;
      Text   : Unbounded_String;   --  the request line, or the peer address
      Sock   : Socket_Type;        --  for Connected
      Web    : Boolean;            --  for Connected: a WebSocket client
   end record;

   package Input_Lists is new Ada.Containers.Doubly_Linked_Lists (Input);

   protected Inputs is
      procedure Put (Item : Input);
      entry Get (Item : out Input);
   private
      Items : Input_Lists.List;
   end Inputs;

   protected body Inputs is
      procedure Put (Item : Input) is
      begin
         Items.Append (Item);
      end Put;

      entry Get (Item : out Input) when not Items.Is_Empty is
      begin
         Item := Items.First_Element;
         Items.Delete_First;
      end Get;
   end Inputs;

   --  Web: the client speaks WebSocket (see Server.Web), else plain lines
   task type Reader (Id : Client_Id; Web : Boolean) is
      entry Start (Sock : Socket_Type);
   end Reader;

   task body Reader is
      Input_Stream : Line_Reader;
   begin
      accept Start (Sock : Socket_Type) do
         Attach (Input_Stream, Sock);
      end Start;
      loop
         Inputs.Put ((Line, Id,
                      To_Unbounded_String
                        (if Web then Server.Web.Read_Message (Input_Stream)
                         else Read_Line (Input_Stream)),
                      No_Socket, Web));
      end loop;
   exception
      when others =>   --  the client closed, or its writer shut the socket
         Inputs.Put ((Disconnected, Id, Null_Unbounded_String, No_Socket, Web));
   end Reader;

   task type Writer (Box : not null access Outbox; Web : Boolean) is
      entry Start (Sock : Socket_Type);
   end Writer;

   task body Writer is
      S      : Socket_Type;
      Data   : Unbounded_String;
      Closed : Boolean;
   begin
      accept Start (Sock : Socket_Type) do
         S := Sock;
      end Start;
      loop
         Box.Get (Data, Closed);
         exit when Closed;
         begin
            --  Straight from To_String: a copy of a payload of megabytes
            --  would not fit in this task's stack
            if Web then
               Server.Web.Send_Frames (S, To_String (Data));
            else
               Send_All (S, To_String (Data));
            end if;
         exception
            when others =>
               --  The client is gone: wake its reader, which reports it,
               --  then wait for the session loop to close the box
               begin
                  Shutdown_Socket (S);
               exception
                  when Socket_Error => null;
               end;
               loop
                  Box.Get (Data, Closed);
                  exit when Closed;
               end loop;
               exit;
         end;
      end loop;
      Close_Socket (S);
   exception
      when Socket_Error => null;
   end Writer;

   type Reader_Access is access Reader;
   type Writer_Access is access Writer;

   procedure Free is new Ada.Unchecked_Deallocation (Reader, Reader_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Writer, Writer_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Outbox, Outbox_Access);

   type Client is record
      Box       : Outbox_Access;
      Read_Task : Reader_Access;
      Send_Task : Writer_Access;
      Live      : Boolean := False;   --  subscribed to live events
   end record;

   package Client_Maps is new Ada.Containers.Ordered_Maps (Client_Id, Client);
   package Client_Lists is new Ada.Containers.Doubly_Linked_Lists (Client);

   --  Client numbers, shared by the acceptors
   protected Client_Numbers is
      procedure Next (Id : out Client_Id);
   private
      Last : Natural := 0;
   end Client_Numbers;

   protected body Client_Numbers is
      procedure Next (Id : out Client_Id) is
      begin
         Last := Last + 1;
         Id   := Client_Id (Last);
      end Next;
   end Client_Numbers;

   --  Accepts connections and announces them to the session loop.  On the
   --  web port it answers HTTP requests itself, and announces those that
   --  become WebSocket connections.
   task type Acceptor is
      entry Start (Listener : Socket_Type; Web : Boolean; Root : String);
   end Acceptor;

   task body Acceptor is
      Listening : Socket_Type;
      Is_Web    : Boolean := False;
      Web_Root  : Unbounded_String;
      Sock      : Socket_Type;
      Peer      : Sock_Addr_Type;
      Id        : Client_Id;
   begin
      accept Start (Listener : Socket_Type; Web : Boolean; Root : String) do
         Listening := Listener;
         Is_Web    := Web;
         Web_Root  := To_Unbounded_String (Root);
      end Start;
      loop
         Accept_Socket (Listening, Sock, Peer);
         if not Is_Web then
            Client_Numbers.Next (Id);
            Inputs.Put ((Connected, Id, To_Unbounded_String (Image (Peer)), Sock, False));
         else
            begin
               --  A client that sends no request must not hold up others
               Set_Socket_Option (Sock, Socket_Level, (Receive_Timeout, 5.0));
               if Server.Web.Answer (Sock, To_String (Web_Root)) then
                  Set_Socket_Option (Sock, Socket_Level, (Receive_Timeout, 0.0));
                  Client_Numbers.Next (Id);
                  Inputs.Put ((Connected, Id, To_Unbounded_String (Image (Peer)),
                               Sock, True));
               else
                  Close_Socket (Sock);
               end if;
            exception
               when others =>
                  Close_Socket (Sock);
            end;
         end if;
      end loop;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("accepting stopped: " & Exception_Message (E));
   end Acceptor;

   -- -------------------------------------------------------------------------

   procedure Run
     (Scope        : in out Rigol.Oscilloscope;
      Listener     : in     Socket_Type;
      Source       : in     String;
      Web_Listener : in     Socket_Type := No_Socket;
      Web_Root     : in     String      := "") is separate;

end Server.Session;
