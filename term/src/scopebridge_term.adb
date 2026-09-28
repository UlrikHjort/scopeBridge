-- ***************************************************************************
--                   ScopeBridge Terminal - Main Program
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

--  scopebridge-term: the scope from a terminal, as a client of scopebridge-server.
--
--    scopebridge-term [--host 127.0.0.1] [--port 5026]
--
--  Reads commands, one per line, from the keyboard or a pipe; "help"
--  lists them.  Numbers take SI suffixes: 500m, 2u, 1k.

with Ada.Command_Line;         use Ada.Command_Line;
with Ada.Characters.Handling;  use Ada.Characters.Handling;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Exceptions;           use Ada.Exceptions;
with Ada.Float_Text_IO;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;        use Ada.Strings.Fixed;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Unchecked_Conversion;
with Interfaces;               use Interfaces;
with Interfaces.C;
with GNAT.Sockets;
with GNATCOLL.JSON;            use GNATCOLL.JSON;

with Scopebridge_Version;
with Server;
with Server.Wire;
with Term_Client;

procedure Scopebridge_Term is

   Usage_Error : exception;   --  a command typed wrongly; message says how

   -- -------------------------------------------------------------------------
   --  Numbers
   -- -------------------------------------------------------------------------

   --  "500m" -> 0.5, "2u" -> 2.0e-6, "1.5k" -> 1500.0, "3" -> 3.0
   function Number (Text : String) return Float is
      Last   : constant Character := Text (Text'Last);
      Factor : Float := 1.0;
      Body_Last : Integer := Text'Last;
   begin
      case Last is
         when 'p' => Factor := 1.0E-12;
         when 'n' => Factor := 1.0E-9;
         when 'u' => Factor := 1.0E-6;
         when 'm' => Factor := 1.0E-3;
         when 'k' => Factor := 1.0E3;
         when 'M' => Factor := 1.0E6;
         when 'G' => Factor := 1.0E9;
         when others => Body_Last := Text'Last + 1;
      end case;
      if Body_Last = Text'Last then
         Body_Last := Text'Last - 1;
      else
         Body_Last := Text'Last;
      end if;
      declare
         Mantissa : constant String := Text (Text'First .. Body_Last);
      begin
         --  Float'Value wants a decimal point
         return Factor * Float'Value
           (if Index (Mantissa, ".") = 0 and then Index (Mantissa, "e") = 0
               and then Index (Mantissa, "E") = 0
            then Mantissa & ".0" else Mantissa);
      end;
   exception
      when Constraint_Error =>
         raise Usage_Error with "not a number: " & Text;
   end Number;

   --  1.00 kHz, 500 mV, 2.00 us
   function Eng (X : Float; Unit : String) return String is
      Prefixes : constant array (-4 .. 3) of String (1 .. 1) :=
        ("p", "n", "u", "m", " ", "k", "M", "G");
      Power : Integer := 0;
      M     : Float := X;
      Buf   : String (1 .. 20);
   begin
      if abs X >= 1.0E-15 then
         while abs M >= 1000.0 and then Power < 3 loop
            M := M / 1000.0;
            Power := Power + 1;
         end loop;
         while abs M < 1.0 and then Power > -4 loop
            M := M * 1000.0;
            Power := Power - 1;
         end loop;
         --  999.99 us would print as 1000.0 us
         if abs M >= 999.95 and then Power < 3 then
            M := M / 1000.0;
            Power := Power + 1;
         end if;
      end if;
      Ada.Float_Text_IO.Put
        (Buf, M, Aft => (if abs M >= 100.0 then 0 elsif abs M >= 10.0 then 1 else 2),
         Exp => 0);
      return Trim (Buf, Ada.Strings.Both) & " " &
             (if Power = 0 then "" else Prefixes (Power)) & Unit;
   end Eng;

   function Num (V : JSON_Value; Name : String) return Float is
     (if Kind (Get (V, Name)) = JSON_Int_Type then Float (Integer'(Get (V, Name)))
      else Float (Long_Float'(Get_Long_Float (V, Name))));

   function To_JSON (X : Float) return JSON_Value renames Server.Wire.To_JSON;

   -- -------------------------------------------------------------------------
   --  Words of a command line
   -- -------------------------------------------------------------------------

   type Word_Array is array (Positive range <>) of Unbounded_String;

   function Split (Line : String) return Word_Array is
      Result : Word_Array (1 .. Line'Length);
      Count  : Natural := 0;
      First  : Natural := 0;
   begin
      for I in Line'Range loop
         if Line (I) = ' ' or else Line (I) = ASCII.HT then
            if First /= 0 then
               Count := Count + 1;
               Result (Count) := To_Unbounded_String (Line (First .. I - 1));
               First := 0;
            end if;
         elsif First = 0 then
            First := I;
         end if;
      end loop;
      if First /= 0 then
         Count := Count + 1;
         Result (Count) := To_Unbounded_String (Line (First .. Line'Last));
      end if;
      return Result (1 .. Count);
   end Split;

   --  The text after the first N words of Line, as typed
   function Rest (Line : String; N : Natural) return String is
      I     : Natural := Line'First;
      Words : Natural := 0;
   begin
      while Words < N and then I <= Line'Last loop
         while I <= Line'Last and then Line (I) = ' ' loop
            I := I + 1;
         end loop;
         while I <= Line'Last and then Line (I) /= ' ' loop
            I := I + 1;
         end loop;
         Words := Words + 1;
      end loop;
      return Trim (Line (I .. Line'Last), Ada.Strings.Both);
   end Rest;

   function Channel_Arg (Word : Unbounded_String) return Integer is
      S : constant String := To_String (Word);
   begin
      if S = "1" or else S = "2" then
         return Integer'Value (S);
      end if;
      raise Usage_Error with "channel must be 1 or 2, not " & S;
   end Channel_Arg;

   function Obj return JSON_Value renames Create_Object;

   procedure Put_Field (O : JSON_Value; Name : String; Value : JSON_Value) is
   begin
      Set_Field (O, Name, Value);
   end Put_Field;

   -- -------------------------------------------------------------------------
   --  Terminal
   -- -------------------------------------------------------------------------

   function Isatty (FD : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, Isatty, "isatty");

   Interactive : constant Boolean := Integer (Isatty (0)) /= 0;

   Clear_Screen : constant String := ASCII.ESC & "[H" & ASCII.ESC & "[2J";

   -- -------------------------------------------------------------------------
   --  Commands
   -- -------------------------------------------------------------------------

   procedure Help is
   begin
      Put_Line ("  status                         the scope's settings");
      Put_Line ("  run | stop | single | auto | force");
      Put_Line ("  ch N [on|off] [scale V] [offset V] [coupling dc|ac|gnd] [probe X]");
      Put_Line ("  tb [scale S] [offset S] [mode yt|xy|roll]   timebase");
      Put_Line ("  acq [type normal|average|peak|hires] [averages N] [depth auto|N]");
      Put_Line ("                                 acquisition mode and memory depth");
      Put_Line ("  trig [level V] [slope rising|falling|either] [source ch1|ch2|ac|ext]");
      Put_Line ("       [sweep auto|normal|single] [mode edge|pulse|slope]");
      Put_Line ("  measure N [ITEM ...]           freq period vpp vmax vmin vavg vrms ...");
      Put_Line ("  watch [N|all] [FRAMES]         live waveform; Enter stops");
      Put_Line ("  sleep SECONDS                  pause, e.g. to let the scope acquire");
      Put_Line ("  wait [SECONDS]                 after single: until it has triggered");
      Put_Line ("  capture N                      read channel N's whole memory");
      Put_Line ("  save FILE [N]                  captured samples to CSV");
      Put_Line ("  spectrum N [WINDOW]            strongest lines of the capture");
      Put_Line ("  decode uart|i2c|spi [NAME VALUE ...] [show N]   decode the captures;");
      Put_Line ("       uart: tx N  rx N  baud B  bits N  parity none|even|odd  stop 1|1.5|2");
      Put_Line ("       i2c: scl N  sda N    spi: clk N  data N  edge rising|falling  width N");
      Put_Line ("       timeout S;  all: inverted on|off  msb_first on|off  threshold1 V ...");
      Put_Line ("  bus [1|2] uart|i2c|spi [NAME VALUE ...] [format hex|ascii|dec|bin]");
      Put_Line ("       the scope's own bus display, same settings;  bus [1|2] off");
      Put_Line ("  timing N [to M] [gap S] [low] [bins N] [threshold V]");
      Put_Line ("       time the blocks code marks on channel N (capture it first): lengths,");
      Put_Line ("       period, latency to channel M, bursts split by pauses over S");
      Put_Line ("  mask                           pass/fail counts");
      Put_Line ("  mask on|off|create|run|stop|reset  [x DIV] [y DIV] [source ch1|ch2]");
      Put_Line ("       [stop_on_fail on|off] [beep on|off]");
      Put_Line ("  ref                            the reference waveforms");
      Put_Line ("  ref save SLOT N | ref clear [SLOT] | ref export SLOT FILE");
      Put_Line ("  ref load SLOT FILE [N]         from a CSV of time, volts");
      Put_Line ("  screenshot FILE                the screen as BMP");
      Put_Line ("  setup save FILE | setup load FILE");
      Put_Line ("  scpi TEXT                      raw SCPI; a query ending in ? is answered");
      Put_Line ("  raw JSON                       a protocol request as is");
      Put_Line ("  quit");
      Put_Line ("  Numbers take SI suffixes: 500m, 2u, 1k.");
   end Help;

   procedure Show_Status is
      Reply   : JSON_Value;
      Payload : Unbounded_String;
   begin
      Term_Client.Request ("status", JSON_Null, Reply, Payload);
      declare
         Channels : constant JSON_Array := Get (Reply, "channels");
         TB       : constant JSON_Value := Get (Reply, "timebase");
         Trig     : constant JSON_Value := Get (Reply, "trigger");
      begin
         Put_Line ("  trigger status " & To_Upper (String'(Get (Reply, "trigger_status"))));
         for I in 1 .. Length (Channels) loop
            declare
               C : constant JSON_Value := Get (Channels, I);
            begin
               Put_Line ("  CH" & Trim (Integer'Image (Get (C, "ch")), Ada.Strings.Left) &
                         (if Get (C, "display") then "  on  " else "  off ") &
                         Eng (Num (C, "scale"), "V") & "/div  offset " &
                         Eng (Num (C, "offset"), "V") & "  " &
                         To_Upper (String'(Get (C, "coupling"))) & "  probe " &
                         Eng (Num (C, "probe"), "") & "x");
            end;
         end loop;
         Put_Line ("  timebase " & Eng (Num (TB, "scale"), "s") & "/div  offset " &
                   Eng (Num (TB, "offset"), "s") &
                   (if Has_Field (TB, "mode") and then String'(Get (TB, "mode")) /= "yt"
                    then "  mode " & To_Upper (String'(Get (TB, "mode"))) else ""));
         if Has_Field (Reply, "mask")
           and then Get (Get (Reply, "mask"), "enable")
         then
            declare
               M : constant JSON_Value := Get (Reply, "mask");
            begin
               Put_Line ("  pass/fail " & (if Get (M, "running") then "running" else "stopped") &
                         ": passed" & Long_Long_Integer'Image (Long_Long_Integer (Long_Integer'(Get (M, "passed")))) &
                         ", failed" & Long_Long_Integer'Image (Long_Long_Integer (Long_Integer'(Get (M, "failed")))));
            end;
         end if;
         if Has_Field (Reply, "acquire") then
            declare
               A     : constant JSON_Value := Get (Reply, "acquire");
               Kind  : constant String := Get (A, "type");
               Depth : constant Integer := Get (A, "memory_depth");
            begin
               Put_Line ("  acquisition " & Kind &
                         (if Kind = "average"
                          then " of" & Integer'Image (Get (A, "averages")) else "") &
                         ", memory " &
                         (if Depth = 0 then "auto" else Eng (Float (Depth), "pts")) &
                         ", " & Eng (Num (A, "sample_rate"), "Sa/s"));
            end;
         end if;
         Put_Line ("  trigger " & String'(Get (Trig, "mode")) & ", " &
                   String'(Get (Trig, "source")) & " " & String'(Get (Trig, "slope")) &
                   " at " & Eng (Num (Trig, "level"), "V") & ", sweep " &
                   String'(Get (Trig, "sweep")));
      end;
   end Show_Status;

   --  "set_channel" and the like from "name value" pairs in Words (From ..)
   procedure Settings
     (Cmd : String; Words : Word_Array; From : Positive; Base : JSON_Value)
   is
      I : Positive := From;
      Numbers : constant array (1 .. 4) of Unbounded_String :=
        (To_Unbounded_String ("scale"), To_Unbounded_String ("offset"),
         To_Unbounded_String ("probe"), To_Unbounded_String ("level"));
   begin
      while I <= Words'Last loop
         declare
            Name : constant String := To_Lower (To_String (Words (I)));
         begin
            if Name in "on" | "off" then
               Put_Field (Base, "display", Create (Name = "on"));
               I := I + 1;
            elsif I = Words'Last then
               raise Usage_Error with Name & " needs a value";
            elsif (for some N of Numbers => N = Name) then
               Put_Field (Base, Name, To_JSON (Number (To_String (Words (I + 1)))));
               I := I + 2;
            else
               Put_Field (Base, Name, Create (To_Lower (To_String (Words (I + 1)))));
               I := I + 2;
            end if;
         end;
      end loop;
      Term_Client.Request (Cmd, Base);
   end Settings;

   --  acq [type T] [averages N] [depth auto|N]
   procedure Acquire (Words : Word_Array) is
      Request : constant JSON_Value := Obj;
      I       : Positive := 2;
   begin
      if Words'Length = 1 then
         Show_Status;
         return;
      end if;
      while I <= Words'Last loop
         declare
            Name : constant String := To_Lower (To_String (Words (I)));
         begin
            if I = Words'Last then
               raise Usage_Error with Name & " needs a value";
            end if;
            declare
               Value : constant String := To_Lower (To_String (Words (I + 1)));
            begin
               if Name = "type" then
                  Put_Field (Request, "type", Create (Value));
               elsif Name = "averages" then
                  Put_Field (Request, "averages", Create (Integer (Number (Value))));
               elsif Name = "depth" then
                  Put_Field (Request, "memory_depth",
                             Create (Integer'(if Value = "auto" then 0 else Integer (Number (Value)))));
               else
                  raise Usage_Error with "acq: unknown " & Name;
               end if;
            end;
            I := I + 2;
         end;
      end loop;
      Term_Client.Request ("set_acquire", Request);
   end Acquire;

   procedure Measure (Words : Word_Array) is
      Request : constant JSON_Value := Obj;
      Names   : JSON_Array := Empty_Array;
      Reply   : JSON_Value;
      Payload : Unbounded_String;
   begin
      if Words'Length < 2 then
         raise Usage_Error with "measure N [ITEM ...]";
      end if;
      Put_Field (Request, "ch", Create (Channel_Arg (Words (2))));
      for I in 3 .. Words'Last loop
         Append (Names, Create (To_Lower (To_String (Words (I)))));
      end loop;
      if Words'Length > 2 then
         Put_Field (Request, "items", Create (Names));
      end if;
      Term_Client.Request ("measure", Request, Reply, Payload);
      Put ("  ");
      declare
         procedure Show (Name : UTF8_String; Value : JSON_Value) is
            Unit : constant String :=
              (if Name = "freq" then "Hz"
               elsif Name in "period" | "rise" | "fall" | "pwidth" | "nwidth" then "s"
               elsif Name in "pduty" | "nduty" then ""
               else "V");
         begin
            if Name not in "id" | "ok" | "ch" then
               Put (Name & " " &
                    (if Kind (Value) = JSON_Null_Type then "-"
                     elsif Unit = "" then Eng (100.0 * Num (Reply, Name), "%")
                     else Eng (Num (Reply, Name), Unit)) & "   ");
            end if;
         end Show;
      begin
         Map_JSON_Object (Reply, Show'Access);
      end;
      New_Line;
   end Measure;

   -- -------------------------------------------------------------------------
   --  watch: a live waveform drawn with characters
   -- -------------------------------------------------------------------------

   Plot_Width  : constant := 72;
   Plot_Height : constant := 17;   --  8 divisions of 2 rows, and a centre row

   type Plot is array (1 .. Plot_Height, 1 .. Plot_Width) of Character;

   procedure Graticule (P : out Plot) is
   begin
      for R in P'Range (1) loop
         for C in P'Range (2) loop
            P (R, C) :=
              (if (R - 1) mod 2 = 0 and then (C - 1) mod 6 = 0 then '.' else ' ');
         end loop;
      end loop;
   end Graticule;

   --  Channel settings for placing traces: scale and offset per channel
   Ch_Scale  : array (1 .. 2) of Float := (others => 1.0);
   Ch_Offset : array (1 .. 2) of Float := (others => 0.0);
   Ch_On     : array (1 .. 2) of Boolean := (others => False);
   TB_Scale  : Float := 1.0E-3;

   procedure Load_Settings is
      Reply   : JSON_Value;
      Payload : Unbounded_String;
   begin
      Term_Client.Request ("status", JSON_Null, Reply, Payload);
      declare
         Channels : constant JSON_Array := Get (Reply, "channels");
      begin
         for I in 1 .. Length (Channels) loop
            declare
               C  : constant JSON_Value := Get (Channels, I);
               Ch : constant Integer := Get (C, "ch");
            begin
               Ch_Scale (Ch)  := Num (C, "scale");
               Ch_Offset (Ch) := Num (C, "offset");
               Ch_On (Ch)     := Get (C, "display");
            end;
         end loop;
         TB_Scale := Num (Get (Reply, "timebase"), "scale");
      end;
   end Load_Settings;

   procedure Draw_Trace
     (P : in out Plot; Ch : Integer; Frame : JSON_Value; Raw : String)
   is
      Mark   : constant Character := (if Ch = 1 then '#' else 'o');
      Y_Inc  : constant Float := Num (Frame, "y_inc");
      Zero   : constant Float := Num (Frame, "y_ref") + Num (Frame, "y_origin");

      --  Row of a voltage: the centre row is 0 V at the channel's offset
      function Row (Volts : Float) return Integer is
        (Integer (Float (Plot_Height + 1) / 2.0 -
                  (Volts + Ch_Offset (Ch)) / Ch_Scale (Ch) * 2.0));
   begin
      for Col in 1 .. Plot_Width loop
         declare
            --  Samples of this column, on the scope's 1200-point screen, and
            --  the previous column's last, so that an edge between two
            --  columns is drawn too
            From : constant Integer :=
              Integer'Max (Raw'First, Raw'First + (Col - 1) * 1200 / Plot_Width - 1);
            To   : constant Integer :=
              Integer'Min (Raw'Last, Raw'First + Col * 1200 / Plot_Width - 1);
            Lo, Hi : Integer := 0;
            First  : Boolean := True;
         begin
            for I in From .. To loop
               declare
                  R : constant Integer :=
                    Row ((Float (Character'Pos (Raw (I))) - Zero) * Y_Inc);
               begin
                  if First then
                     Lo := R;
                     Hi := R;
                     First := False;
                  else
                     Lo := Integer'Min (Lo, R);
                     Hi := Integer'Max (Hi, R);
                  end if;
               end;
            end loop;
            if not First then
               for R in Integer'Max (1, Lo) .. Integer'Min (Plot_Height, Hi) loop
                  P (R, Col) := Mark;
               end loop;
            end if;
         end;
      end loop;
   end Draw_Trace;

   procedure Watch (Words : Word_Array) is
      --  "watch", "watch all" or "watch 0": both channels
      Only    : constant Integer :=
        (if Words'Length < 2 or else To_String (Words (2)) in "all" | "0" then 0
         else Channel_Arg (Words (2)));
      --  From a pipe nobody can press Enter: one frame unless told more
      Frames  : constant Natural :=
        (if Words'Length >= 3 then Natural'Value (To_String (Words (3)))
         elsif Interactive then 0 else 1);
      Shown   : Natural := 0;
      P       : Plot;
      Measure_Line : Unbounded_String;
      Members : constant JSON_Value := Obj;
      Message : JSON_Value;
      Payload : Unbounded_String;
      Got     : Boolean;
      Key     : Character;
      Pressed : Boolean;
   begin
      Load_Settings;
      Put_Field (Members, "on", Create (True));
      Put_Field (Members, "interval_ms", Create (Integer'(100)));
      if Only /= 0 then
         Put_Field (Members, "measure_ch", Create (Only));
      end if;
      Term_Client.Request ("live", Members);
      Graticule (P);
      loop
         Term_Client.Next_Message (1.0, Message, Payload, Got);
         if Got and then Has_Field (Message, "event") then
            declare
               Event : constant String := Get (Message, "event");
            begin
               if Event = "frame" then
                  declare
                     Ch : constant Integer := Get (Message, "ch");
                  begin
                     if Only = 0 or else Ch = Only then
                        if Ch = (if Only = 0 then 1 else Only) or else not Ch_On (1) then
                           Graticule (P);   --  a new sweep of the display
                        end if;
                        Draw_Trace (P, Ch, Message, To_String (Payload));
                        if Only /= 0 or else Ch = 2 or else not Ch_On (2) then
                           Shown := Shown + 1;
                           if Interactive then
                              Put (Clear_Screen);
                           end if;
                           Put_Line ("+" & (1 .. Plot_Width => '-') & "+   " &
                                     Eng (TB_Scale, "s") & "/div");
                           for R in P'Range (1) loop
                              Put ("|");
                              for C in P'Range (2) loop
                                 Put (P (R, C));
                              end loop;
                              Put_Line ("|");
                           end loop;
                           Put_Line ("+" & (1 .. Plot_Width => '-') & "+");
                           Put_Line ("  # CH1 " & Eng (Ch_Scale (1), "V") & "/div" &
                                     (if Ch_On (2) then "   o CH2 " & Eng (Ch_Scale (2), "V") & "/div"
                                      else "") & "   " & To_String (Measure_Line));
                           if Interactive then
                              Put_Line ("  Enter stops");
                           end if;
                        end if;
                     end if;
                  end;
               elsif Event = "measure" then
                  Measure_Line := To_Unbounded_String
                    ("CH" & Trim (Integer'Image (Get (Message, "ch")), Ada.Strings.Left) &
                     ":" &
                     (if Kind (Get (Message, "freq")) = JSON_Null_Type then " freq -"
                      else " freq " & Eng (Num (Message, "freq"), "Hz")) &
                     (if Kind (Get (Message, "vpp")) = JSON_Null_Type then "  vpp -"
                      else "  vpp " & Eng (Num (Message, "vpp"), "V")));
               elsif Event = "error" then
                  Put_Line ("  " & String'(Get (Message, "error")));
               end if;
            end;
         end if;
         exit when Frames > 0 and then Shown >= Frames;
         if Interactive then
            Get_Immediate (Key, Pressed);
            exit when Pressed;
         end if;
      end loop;
      Put_Field (Members, "on", Create (False));
      Term_Client.Request ("live", Members);
   end Watch;

   -- -------------------------------------------------------------------------
   --  Captures
   -- -------------------------------------------------------------------------

   Last_Captured : Integer := 0;
   Captured_Info : array (1 .. 2) of JSON_Value := (others => JSON_Null);

   procedure Progress (Event : JSON_Value; Payload : String) is
      pragma Unreferenced (Payload);
   begin
      if String'(Get (Event, "event")) = "progress" then
         Put (ASCII.CR & "  reading memory:" &
              Integer'Image (Integer (100.0 * Num (Event, "done") /
                                      Float'Max (1.0, Num (Event, "total")))) & " %");
         Flush;
      end if;
   end Progress;

   procedure Capture (Words : Word_Array) is
      Request : constant JSON_Value := Obj;
      Reply   : JSON_Value;
      Payload : Unbounded_String;
   begin
      if Words'Length < 2 then
         raise Usage_Error with "capture N";
      end if;
      Last_Captured := Channel_Arg (Words (2));
      Put_Field (Request, "ch", Create (Last_Captured));
      Term_Client.Request ("capture", Request, Reply, Payload,
                           Progress'Unrestricted_Access);
      Captured_Info (Last_Captured) := Reply;
      New_Line;
      Put_Line ("  CH" & Trim (Last_Captured'Image, Ada.Strings.Left) & ":" &
                Integer'Image (Get (Reply, "points")) & " points at " &
                Eng (1.0 / Num (Reply, "x_inc"), "Sa/s") & ", " &
                Eng (Float (Integer'(Get (Reply, "points"))) * Num (Reply, "x_inc"), "s") &
                "; the scope is stopped");
   end Capture;

   procedure Save (Words : Word_Array) is
      Ch : constant Integer :=
        (if Words'Length >= 3 then Channel_Arg (Words (3)) else Last_Captured);
   begin
      if Words'Length < 2 then
         raise Usage_Error with "save FILE [N]";
      elsif Ch = 0 or else Captured_Info (Ch) = JSON_Null then
         raise Usage_Error with "capture a channel first";
      end if;
      declare
         Info   : constant JSON_Value := Captured_Info (Ch);
         Points : constant Integer := Get (Info, "points");
         X_Inc  : constant Long_Float := Long_Float (Num (Info, "x_inc"));
         X_Orig : constant Long_Float := Long_Float (Num (Info, "x_origin"));
         Y_Inc  : constant Float := Num (Info, "y_inc");
         Zero   : constant Float := Num (Info, "y_ref") + Num (Info, "y_origin");
         F      : File_Type;
         First  : Natural := 0;
      begin
         Create (F, Out_File, To_String (Words (2)));
         Put_Line (F, "time_s,ch" & Trim (Ch'Image, Ada.Strings.Left) & "_V");
         while First < Points loop
            declare
               Request : constant JSON_Value := Obj;
               Reply   : JSON_Value;
               Payload : Unbounded_String;
               Last    : constant Natural := Natural'Min (Points - 1, First + 999_999);
            begin
               Put_Field (Request, "ch", Create (Ch));
               Put_Field (Request, "first", Create (First));
               Put_Field (Request, "last", Create (Last));
               Term_Client.Request ("samples", Request, Reply, Payload);
               for I in 1 .. Length (Payload) loop
                  Put_Line (F, Trim (Long_Float'Image (X_Orig + Long_Float (First + I - 1) * X_Inc),
                                     Ada.Strings.Left) & "," &
                               Trim (Float'Image ((Float (Character'Pos (Element (Payload, I))) - Zero) * Y_Inc),
                                     Ada.Strings.Left));
               end loop;
               First := Last + 1;
            end;
         end loop;
         Close (F);
         Put_Line ("  saved" & Points'Image & " samples to " & To_String (Words (2)));
      end;
   end Save;

   procedure Spectrum (Words : Word_Array) is
      function Bits is new Ada.Unchecked_Conversion (Unsigned_32, IEEE_Float_32);
      Request : constant JSON_Value := Obj;
      Reply   : JSON_Value;
      Payload : Unbounded_String;
   begin
      if Words'Length < 2 then
         raise Usage_Error with "spectrum N [WINDOW]";
      end if;
      Put_Field (Request, "ch", Create (Channel_Arg (Words (2))));
      Put_Field (Request, "window",
                 Create (if Words'Length >= 3 then To_Lower (To_String (Words (3)))
                         else "hann"));
      Term_Client.Request ("spectrum", Request, Reply, Payload);
      declare
         N     : constant Natural := Length (Payload) / 4;
         V     : array (0 .. N - 1) of Float;
         DF    : constant Float := Num (Reply, "df");
         F0    : constant Float := Num (Reply, "f0");
         RBW   : constant Float := Num (Reply, "bin_width");
         Skip  : constant Natural :=   --  the window's spread of DC
           Natural (Float'Ceiling (6.0 * RBW / DF));
         Used  : array (0 .. N - 1) of Boolean := (others => False);
         B     : Unsigned_32;
      begin
         for I in V'Range loop
            B := 0;
            for K in reverse 0 .. 3 loop
               B := Shift_Left (B, 8) or
                    Unsigned_32 (Character'Pos (Element (Payload, 4 * I + K + 1)));
            end loop;
            V (I) := Float (Bits (B));
         end loop;
         Put_Line ("  resolution " & Eng (RBW, "Hz") & ", " &
                   String'(Get (Reply, "window")) & " window; strongest lines:");
         --  The strongest local maxima, each hiding its neighbourhood
         for Line in 1 .. 8 loop
            declare
               Best : Integer := -1;
            begin
               for I in Skip .. N - 1 loop
                  if not Used (I) and then (Best < 0 or else V (I) > V (Best)) then
                     Best := I;
                  end if;
               end loop;
               exit when Best < 0;
               Put_Line ("   " & Line'Image & ".  " & Eng (F0 + Float (Best) * DF, "Hz") &
                         "   " & Eng (V (Best), "") & "dBV");
               for I in Integer'Max (0, Best - 2 * Skip) ..
                        Integer'Min (N - 1, Best + 2 * Skip)
               loop
                  Used (I) := True;
               end loop;
            end;
         end loop;
      end;
   end Spectrum;


   -- -------------------------------------------------------------------------
   --  Bus decoding, pass/fail and references
   -- -------------------------------------------------------------------------

   function Is_On (Word : Unbounded_String) return Boolean is
      S : constant String := To_Lower (To_String (Word));
   begin
      if S in "on" | "yes" | "true" | "1" then
         return True;
      elsif S in "off" | "no" | "false" | "0" then
         return False;
      end if;
      raise Usage_Error with "on or off, not " & S;
   end Is_On;

   --  "name value" pairs of a decode or bus command, from Words (From ..),
   --  into Request; "show N" goes to Show instead
   procedure Bus_Settings
     (Words : Word_Array; From : Positive; Request : JSON_Value;
      Show  : out Natural)
   is
      I : Positive := From;
   begin
      Show := 40;
      while I <= Words'Last loop
         if I = Words'Last then
            raise Usage_Error with To_String (Words (I)) & " needs a value";
         end if;
         declare
            Name  : constant String := To_Lower (To_String (Words (I)));
            Value : constant String := To_String (Words (I + 1));
         begin
            if Name = "show" then
               Show := Natural (Number (Value));
            elsif Name in "tx" | "rx" | "scl" | "sda" | "clk" | "data" then
               Put_Field (Request, Name, Create (Channel_Arg (Words (I + 1))));
            elsif Name in "baud" | "bits" | "width" | "first" | "last" | "max_items" then
               Put_Field (Request, Name, Create (Integer (Number (Value))));
            elsif Name in "stop" | "timeout" | "threshold1" | "threshold2" then
               Put_Field (Request, Name, To_JSON (Number (Value)));
            elsif Name in "inverted" | "msb_first" | "display" then
               Put_Field (Request, Name, Create (Is_On (Words (I + 1))));
            else
               Put_Field (Request, Name, Create (To_Lower (Value)));
            end if;
         end;
         I := I + 2;
      end loop;
   end Bus_Settings;

   function Hex (V : Long_Long_Integer; Digits_Wanted : Positive := 2) return String is
      H      : constant String := "0123456789ABCDEF";
      Result : Unbounded_String;
      X      : Long_Long_Integer := V;
   begin
      loop
         Result := H (Integer (X mod 16) + 1) & Result;
         X := X / 16;
         exit when X = 0 and then Length (Result) >= Digits_Wanted;
      end loop;
      return To_String (Result);
   end Hex;

   procedure Decode (Words : Word_Array) is
      Request : constant JSON_Value := Obj;
      Reply   : JSON_Value;
      Payload : Unbounded_String;
      Show    : Natural;
   begin
      if Words'Length < 2 then
         raise Usage_Error with "decode uart|i2c|spi [NAME VALUE ...]";
      end if;
      Put_Field (Request, "protocol", Create (To_Lower (To_String (Words (2)))));
      Bus_Settings (Words, 3, Request, Show);
      Term_Client.Request ("decode", Request, Reply, Payload);
      declare
         Items : constant JSON_Array := Get (Reply, "items");
         Proto : constant String := Get (Reply, "protocol");
         Text  : array (1 .. 2) of Unbounded_String;
      begin
         Put_Line ("  " & Trim (Integer'Image (Get (Reply, "count")), Ada.Strings.Left) &
                   " items" & (if Get (Reply, "truncated") then " (truncated)" else ""));
         for K in 1 .. Length (Items) loop
            declare
               It    : constant JSON_Value := Get (Items, K);
               Kind_S : constant String := Get (It, "type");
               Ch    : constant Integer := Get (It, "ch");
               Value : constant Long_Long_Integer :=
                 (if Has_Field (It, "value") then Long_Long_Integer (Long_Integer'(Get (It, "value"))) else 0);
               Line  : Unbounded_String := To_Unbounded_String
                 ("  " & Eng (Num (It, "t"), "s") & "  CH" &
                  Trim (Ch'Image, Ada.Strings.Left) & "  ");
            begin
               if Kind_S in "start" | "stop" then
                  Append (Line, To_Upper (Kind_S));
               elsif Kind_S = "address" then
                  Append (Line, "address " & Hex (Value) &
                          (if Get (It, "read") then " read" else " write"));
               else
                  Append (Line, Hex (Value));
                  if Value in 32 .. 126 then
                     Append (Line, "  '" & Character'Val (Value) & "'");
                  end if;
               end if;
               if Has_Field (It, "ack") then
                  Append (Line, (if Get (It, "ack") then "  ack" else "  nack"));
               end if;
               if Has_Field (It, "error") then
                  Append (Line, "  " & String'(Get (It, "error")) & " error");
               end if;
               if Proto = "uart" and then Kind_S = "data" and then Ch in 1 .. 2 then
                  Append (Text (Ch),
                          (if Value in 32 .. 126 then (1 => Character'Val (Value))
                           elsif Value = 10 then "\n" elsif Value = 13 then "\r"
                           else "\x" & Hex (Value)));
               end if;
               if K <= Show then
                  Put_Line (To_String (Line));
               elsif K = Show + 1 then
                  Put_Line ("  ...  (show N for more)");
               end if;
            end;
         end loop;
         for Ch in Text'Range loop
            if Length (Text (Ch)) > 0 then
               Put_Line ("  CH" & Trim (Ch'Image, Ada.Strings.Left) & " text: " &
                         To_String (Text (Ch)));
            end if;
         end loop;
      end;
   end Decode;

   procedure Bus (Words : Word_Array) is
      Request : constant JSON_Value := Obj;
      Show    : Natural;
      From    : Positive := 2;
   begin
      if Words'Length >= 2 and then To_String (Words (2)) in "1" | "2" then
         Put_Field (Request, "bus", Create (Integer'Value (To_String (Words (2)))));
         From := 3;
      end if;
      if Words'Length < From then
         raise Usage_Error with "bus [1|2] uart|i2c|spi [NAME VALUE ...] | bus [1|2] off";
      end if;
      declare
         Proto : constant String := To_Lower (To_String (Words (From)));
      begin
         if Proto = "off" then
            Put_Field (Request, "protocol", Create ("uart"));
            Put_Field (Request, "display", Create (False));
         else
            Put_Field (Request, "protocol", Create (Proto));
            Bus_Settings (Words, From + 1, Request, Show);
         end if;
      end;
      Term_Client.Request ("set_decoder", Request);
   end Bus;

   --  0.20, 1.04: mask margins
   function Fixed (X : Float) return String is
      Buf : String (1 .. 12);
   begin
      Ada.Float_Text_IO.Put (Buf, X, Aft => 2, Exp => 0);
      return Trim (Buf, Ada.Strings.Both);
   end Fixed;

   procedure Mask (Words : Word_Array) is
      Request : constant JSON_Value := Obj;
      Reply   : JSON_Value;
      Payload : Unbounded_String;
      I       : Positive := 2;
   begin
      while I <= Words'Last loop
         declare
            W : constant String := To_Lower (To_String (Words (I)));
         begin
            if W in "on" | "off" then
               Put_Field (Request, "enable", Create (W = "on"));
               I := I + 1;
            elsif W in "create" | "reset" then
               Put_Field (Request, W, Create (True));
               I := I + 1;
            elsif W in "run" | "stop" then
               Put_Field (Request, "run", Create (W = "run"));
               I := I + 1;
            elsif I = Words'Last then
               raise Usage_Error with W & " needs a value";
            elsif W in "x" | "y" then
               Put_Field (Request, W, To_JSON (Number (To_String (Words (I + 1)))));
               I := I + 2;
            elsif W in "stop_on_fail" | "beep" | "show_stats" then
               Put_Field (Request, W, Create (Is_On (Words (I + 1))));
               I := I + 2;
            elsif W = "source" then
               Put_Field (Request, W, Create (To_Lower (To_String (Words (I + 1)))));
               I := I + 2;
            else
               raise Usage_Error with "mask: unknown " & W;
            end if;
         end;
      end loop;
      if Words'Length > 1 then
         Term_Client.Request ("set_mask", Request);
      end if;
      Term_Client.Request ("mask", JSON_Null, Reply, Payload);
      Put_Line ("  pass/fail " & (if Get (Reply, "enable") then "on" else "off") &
                (if Get (Reply, "running") then ", running" else ", stopped") &
                ", " & String'(Get (Reply, "source")) &
                ", mask x " & Fixed (Num (Reply, "x")) & " div, y " &
                Fixed (Num (Reply, "y")) & " div" &
                (if Get (Reply, "stop_on_fail") then ", stops on fail" else ""));
      Put_Line ("  passed" & Long_Long_Integer'Image (Long_Long_Integer (Long_Integer'(Get (Reply, "passed")))) &
                "   failed" & Long_Long_Integer'Image (Long_Long_Integer (Long_Integer'(Get (Reply, "failed")))) &
                "   total" & Long_Long_Integer'Image (Long_Long_Integer (Long_Integer'(Get (Reply, "total")))));
   end Mask;

   type Point is record
      T, V : Long_Float;
   end record;
   package Point_Vectors is new Ada.Containers.Vectors (Positive, Point);

   --  timing N [to M] [gap S] [low] [bins N] [threshold V]: the blocks a
   --  program marks on channel N, with a histogram of their lengths
   procedure Timing (Words : Word_Array) is
      Request : constant JSON_Value := Obj;
      Reply   : JSON_Value;
      Payload : Unbounded_String;
      I       : Positive := 3;

      function Pad (S : String; Width : Positive) return String is
        ((if S'Length < Width then (1 .. Width - S'Length => ' ') else "") & S);

      procedure Row (Name : String; S : JSON_Value; Unit : String) is
         Count : constant Integer := Get (S, "count");
         function V (Field : String) return String is
           (if Unit = "" then Pad (Fixed (Num (S, Field)), 10)
            else Pad (Eng (Num (S, Field), Unit), 10));
      begin
         if Count = 0 then
            Put_Line ("  " & Name & (1 .. 16 - Name'Length => ' ') & Pad (Count'Image, 6));
         else
            Put_Line ("  " & Name & (1 .. 16 - Name'Length => ' ') & Pad (Count'Image, 6) &
                      V ("min") & V ("mean") & V ("max") & V ("std_dev"));
         end if;
      end Row;

      --  A bar per bin, the longest 40 characters
      procedure Histogram (Title : String; S : JSON_Value; Unit : String) is
         H      : constant JSON_Value := Get (S, "histogram");
         Counts : constant JSON_Array := Get (H, "counts");
         From   : constant Float := Num (H, "from");
         Step   : constant Float := (Num (H, "to") - From) / Float (Length (Counts));
         Most   : Integer := 1;
      begin
         for K in 1 .. Length (Counts) loop
            Most := Integer'Max (Most, Get (Get (Counts, K)));
         end loop;
         Put_Line ("  " & Title & ":");
         for K in 1 .. Length (Counts) loop
            declare
               N : constant Integer := Get (Get (Counts, K));
               X : constant Float := From + Step * Float (K - 1);
            begin
               Put_Line ("  " & Pad ((if Unit = "" then Fixed (X) else Eng (X, Unit)), 10) &
                         " |" & (1 .. (N * 40 + Most - 1) / Most => '#') &
                         (if N > 0 then N'Image else ""));
            end;
         end loop;
      end Histogram;
   begin
      if Words'Length < 2 then
         raise Usage_Error with "timing N [to M] [gap S] [low] [bins N] [threshold V]";
      end if;
      Put_Field (Request, "ch", Create (Channel_Arg (Words (2))));
      Put_Field (Request, "bins", Create (Integer'(12)));
      while I <= Words'Last loop
         declare
            Name : constant String := To_Lower (To_String (Words (I)));
         begin
            if Name in "low" | "high" then
               Put_Field (Request, "polarity", Create (Name));
               I := I + 1;
            elsif I = Words'Last then
               raise Usage_Error with Name & " needs a value";
            elsif Name = "to" then
               Put_Field (Request, "to", Create (Channel_Arg (Words (I + 1))));
               I := I + 2;
            elsif Name = "gap" then
               Put_Field (Request, "burst_gap", To_JSON (Number (To_String (Words (I + 1)))));
               I := I + 2;
            elsif Name = "bins" then
               Put_Field (Request, "bins", Create (Integer (Number (To_String (Words (I + 1))))));
               I := I + 2;
            elsif Name = "threshold" then
               Put_Field (Request, "threshold", To_JSON (Number (To_String (Words (I + 1)))));
               I := I + 2;
            else
               raise Usage_Error with "timing: unknown setting " & Name;
            end if;
         end;
      end loop;
      Term_Client.Request ("timing", Request, Reply, Payload);
      Put_Line ("                    count       min      mean       max   std dev");
      Row ("block", Get (Reply, "block"), "s");
      Row ("idle", Get (Reply, "idle"), "s");
      Row ("period", Get (Reply, "period"), "s");
      if Has_Field (Reply, "latency") then
         Row ("latency to CH" & Trim (Integer'Image (Get (Reply, "to")), Ada.Strings.Left),
              Get (Reply, "latency"), "s");
      end if;
      if Has_Field (Reply, "burst") then
         Row ("burst", Get (Reply, "burst"), "s");
         Row ("pulses/burst", Get (Reply, "burst_pulses"), "");
      end if;
      if Has_Field (Reply, "duty") then
         Put_Line ("  duty " & Fixed (100.0 * Num (Reply, "duty")) & " %, resolution " &
                   Eng (Num (Reply, "resolution"), "s") & ", over " & Eng (Num (Reply, "span"), "s"));
      end if;
      declare
         Block : constant JSON_Value := Get (Reply, "block");
      begin
         if Integer'(Get (Block, "count")) > 0 then
            Put_Line ("  longest block at " & Eng (Num (Get (Block, "longest"), "t"), "s") &
                      ", shortest at " & Eng (Num (Get (Block, "shortest"), "t"), "s"));
            Histogram ("block lengths", Block, "s");
         end if;
      end;
      if Has_Field (Reply, "burst")
        and then Integer'(Get (Get (Reply, "burst"), "count")) > 0
      then
         Histogram ("burst lengths", Get (Reply, "burst"), "s");
      end if;
   end Timing;

   procedure Ref (Words : Word_Array) is
      Request : constant JSON_Value := Obj;
      Reply   : JSON_Value;
      Payload : Unbounded_String;
      Sub     : constant String :=
        (if Words'Length >= 2 then To_Lower (To_String (Words (2))) else "list");

      function Slot return Integer is
      begin
         if Words'Length < 3 then
            raise Usage_Error with "ref " & Sub & " needs a slot, 1 .. 4";
         end if;
         return Integer (Number (To_String (Words (3))));
      end Slot;
   begin
      if Sub = "list" then
         Term_Client.Request ("refs", JSON_Null, Reply, Payload);
         declare
            List : constant JSON_Array := Get (Reply, "refs");
         begin
            if Length (List) = 0 then
               Put_Line ("  no references");
            end if;
            for K in 1 .. Length (List) loop
               declare
                  R : constant JSON_Value := Get (List, K);
               begin
                  Put_Line ("  R" & Trim (Integer'Image (Get (R, "slot")), Ada.Strings.Left) &
                            "  " & String'(Get (R, "label")) & "  " &
                            Trim (Integer'Image (Get (R, "points")), Ada.Strings.Left) &
                            " points over " &
                            Eng (Float (Integer'(Get (R, "points"))) * Num (R, "x_inc"), "s"));
               end;
            end loop;
         end;
      elsif Sub = "save" then
         if Words'Length < 4 then
            raise Usage_Error with "ref save SLOT N";
         end if;
         Put_Field (Request, "slot", Create (Slot));
         Put_Field (Request, "ch", Create (Channel_Arg (Words (4))));
         Term_Client.Request ("ref_save", Request, Reply, Payload);
         Put_Line ("  R" & Trim (Slot'Image, Ada.Strings.Left) & " = " &
                   String'(Get (Reply, "label")));
      elsif Sub = "clear" then
         if Words'Length >= 3 then
            Put_Field (Request, "slot", Create (Slot));
         end if;
         Term_Client.Request ("ref_clear", Request);
      elsif Sub = "export" then
         if Words'Length < 4 then
            raise Usage_Error with "ref export SLOT FILE";
         end if;
         Put_Field (Request, "slot", Create (Slot));
         Term_Client.Request ("ref", Request, Reply, Payload);
         declare
            F     : File_Type;
            X_Inc : constant Long_Float := Long_Float (Num (Reply, "x_inc"));
            X_Org : constant Long_Float := Long_Float (Num (Reply, "x_origin"));
            Y_Inc : constant Float := Num (Reply, "y_inc");
            Zero  : constant Float := Num (Reply, "y_ref") + Num (Reply, "y_origin");
         begin
            Create (F, Out_File, To_String (Words (4)));
            Put_Line (F, "time_s,volts");
            for I in 1 .. Length (Payload) loop
               Put_Line (F, Trim (Long_Float'Image (X_Org + Long_Float (I - 1) * X_Inc),
                                  Ada.Strings.Left) & "," &
                            Trim (Float'Image ((Float (Character'Pos (Element (Payload, I)))
                                                - Zero) * Y_Inc), Ada.Strings.Left));
            end loop;
            Close (F);
            Put_Line ("  saved" & Length (Payload)'Image & " points to " & To_String (Words (4)));
         end;
      elsif Sub = "load" then
         if Words'Length < 4 then
            raise Usage_Error with "ref load SLOT FILE [N]";
         end if;
         --  Time, volts per line after a header; the samples are stored
         --  as 8-bit values spanning the volts' range, as the scope does
         declare
            F      : File_Type;
            Points : Point_Vectors.Vector;
            N      : Natural := 0;
            Lo, Hi : Long_Float := 0.0;
         begin
            Open (F, In_File, To_String (Words (4)));
            while not End_Of_File (F) and then N < 1_000_000 loop
               declare
                  L     : constant String := Get_Line (F);
                  Comma : constant Natural := Index (L, ",");
               begin
                  if Comma > 0 then
                     Points.Append
                       ((T => Long_Float'Value (L (L'First .. Comma - 1)),
                         V => Long_Float'Value (L (Comma + 1 .. L'Last))));
                     N := N + 1;
                  end if;
               exception
                  when Constraint_Error => null;   --  the header
               end;
            end loop;
            Close (F);
            if N < 2 then
               raise Usage_Error with "no time,volts lines in " & To_String (Words (4));
            end if;
            Lo := Points (1).V;
            Hi := Points (1).V;
            for K in 1 .. N loop
               Lo := Long_Float'Min (Lo, Points (K).V);
               Hi := Long_Float'Max (Hi, Points (K).V);
            end loop;
            declare
               Y_Inc : constant Long_Float := Long_Float'Max (1.0E-6, (Hi - Lo) / 200.0);
               Raw   : String (1 .. N);
            begin
               --  volts = (raw - 127 - y_origin) * y_inc, with Lo at count 27
               for K in 1 .. N loop
                  Raw (K) := Character'Val
                    (Integer'Max (0, Integer'Min (255, Integer
                       (27.0 + (Points (K).V - Lo) / Y_Inc))));
               end loop;
               Put_Field (Request, "slot", Create (Slot));
               Put_Field (Request, "data", Create (Server.Wire.To_Base64 (Raw)));
               Put_Field (Request, "x_inc", To_JSON
                 (Float ((Points (N).T - Points (1).T) / Long_Float (N - 1))));
               Put_Field (Request, "x_origin", To_JSON (Float (Points (1).T)));
               Put_Field (Request, "y_inc", To_JSON (Float (Y_Inc)));
               Put_Field (Request, "y_origin", To_JSON (Float (-100.0 - Lo / Y_Inc)));
               Put_Field (Request, "y_ref", To_JSON (127.0));
               Put_Field (Request, "label", Create
                 (Ada.Directories.Simple_Name (To_String (Words (4)))));
               if Words'Length >= 5 then
                  Put_Field (Request, "ch", Create (Channel_Arg (Words (5))));
               end if;
               Term_Client.Request ("ref_load", Request);
               Put_Line ("  R" & Trim (Slot'Image, Ada.Strings.Left) & " loaded," &
                         N'Image & " points");
            end;
         end;
      else
         raise Usage_Error with "ref [list] | ref save|clear|export|load ...";
      end if;
   end Ref;

   procedure Write_Binary (Name, Data : String) is
      use Ada.Streams.Stream_IO;
      F : Ada.Streams.Stream_IO.File_Type;
   begin
      Create (F, Out_File, Name);
      String'Write (Stream (F), Data);
      Close (F);
   end Write_Binary;

   function Read_Binary (Name : String) return String is
      use Ada.Streams.Stream_IO;
      F    : Ada.Streams.Stream_IO.File_Type;
      Data : String (1 .. Natural (Ada.Directories.Size (Name)));
   begin
      Open (F, In_File, Name);
      String'Read (Stream (F), Data);
      Close (F);
      return Data;
   end Read_Binary;

   procedure Execute (Line : String) is
      Words : constant Word_Array := Split (Line);
      Cmd   : constant String :=
        (if Words'Length = 0 then "" else To_Lower (To_String (Words (1))));
      Reply   : JSON_Value;
      Payload : Unbounded_String;
   begin
      if Cmd = "" or else Cmd (Cmd'First) = '#' then
         null;
      elsif Cmd = "help" or else Cmd = "?" then
         Help;
      elsif Cmd = "status" then
         Show_Status;
      elsif Cmd in "run" | "stop" | "single" | "auto" | "force" then
         Term_Client.Request (Cmd);
      elsif Cmd = "ch" then
         if Words'Length < 2 then
            raise Usage_Error with "ch N [settings]";
         end if;
         declare
            Base : constant JSON_Value := Obj;
         begin
            Put_Field (Base, "ch", Create (Channel_Arg (Words (2))));
            if Words'Length = 2 then
               Show_Status;
            else
               Settings ("set_channel", Words, 3, Base);
            end if;
         end;
      elsif Cmd = "tb" then
         if Words'Length = 1 then
            Show_Status;
         else
            Settings ("set_timebase", Words, 2, Obj);
         end if;
      elsif Cmd = "trig" then
         if Words'Length = 1 then
            Show_Status;
         else
            Settings ("set_trigger", Words, 2, Obj);
         end if;
      elsif Cmd = "acq" then
         Acquire (Words);
      elsif Cmd = "sleep" then
         if Words'Length < 2 then
            raise Usage_Error with "sleep SECONDS";
         end if;
         delay Duration (Number (To_String (Words (2))));
      elsif Cmd = "wait" then
         --  After single: until the scope has triggered and stopped
         declare
            Limit : constant Float :=
              (if Words'Length >= 2 then Number (To_String (Words (2))) else 10.0);
            Waited : Float := 0.0;
         begin
            loop
               Term_Client.Request ("status", JSON_Null, Reply, Payload);
               exit when String'(Get (Reply, "trigger_status")) = "stop";
               if Waited >= Limit then
                  raise Usage_Error with "no trigger within" & Limit'Image & " s";
               end if;
               delay 0.1;
               Waited := Waited + 0.1;
            end loop;
            Put_Line ("  triggered");
         end;
      elsif Cmd = "measure" then
         Measure (Words);
      elsif Cmd = "watch" then
         Watch (Words);
      elsif Cmd = "capture" then
         Capture (Words);
      elsif Cmd = "save" then
         Save (Words);
      elsif Cmd = "spectrum" then
         Spectrum (Words);
      elsif Cmd = "decode" then
         Decode (Words);
      elsif Cmd = "bus" then
         Bus (Words);
      elsif Cmd = "mask" then
         Mask (Words);
      elsif Cmd = "timing" then
         Timing (Words);
      elsif Cmd = "ref" then
         Ref (Words);
      elsif Cmd = "screenshot" then
         if Words'Length < 2 then
            raise Usage_Error with "screenshot FILE";
         end if;
         Term_Client.Request ("screenshot", JSON_Null, Reply, Payload);
         Write_Binary (To_String (Words (2)), To_String (Payload));
         Put_Line ("  saved" & Length (Payload)'Image & " bytes to " & To_String (Words (2)));
      elsif Cmd = "setup" then
         if Words'Length < 3 then
            raise Usage_Error with "setup save FILE | setup load FILE";
         elsif To_String (Words (2)) = "save" then
            Term_Client.Request ("save_setup", JSON_Null, Reply, Payload);
            Write_Binary (To_String (Words (3)),
                          Server.Wire.From_Base64 (Get (Reply, "setup")));
            Put_Line ("  setup saved to " & To_String (Words (3)));
         else
            declare
               Request : constant JSON_Value := Obj;
            begin
               Put_Field (Request, "setup", Create
                 (Server.Wire.To_Base64 (Read_Binary (To_String (Words (3))))));
               Term_Client.Request ("load_setup", Request, Reply, Payload);
               Put_Line ("  setup loaded from " & To_String (Words (3)));
               if Has_Field (Reply, "warnings") then
                  declare
                     Warnings : constant JSON_Array := Get (Reply, "warnings");
                  begin
                     for K in 1 .. Length (Warnings) loop
                        Put_Line ("  not restored: " & String'(Get (Get (Warnings, K))));
                     end loop;
                  end;
               end if;
            end;
         end if;
      elsif Cmd = "scpi" then
         declare
            Text    : constant String := Rest (Line, 1);
            Request : constant JSON_Value := Obj;
            Query   : constant Boolean := Index (Text, "?") > 0;
         begin
            Put_Field (Request, "text", Create (Text));
            Put_Field (Request, "query", Create (Query));
            Term_Client.Request ("scpi", Request, Reply, Payload);
            if Query then
               Put_Line ("  " & String'(Get (Reply, "response")));
            end if;
         end;
      elsif Cmd = "raw" then
         declare
            Request : constant JSON_Value := Read (Rest (Line, 1));
         begin
            Term_Client.Request (Get (Request, "cmd"), Request, Reply, Payload);
            Put_Line ("  " & Write (Reply) &
                      (if Length (Payload) > 0 then "  +" & Length (Payload)'Image & " bytes"
                       else ""));
         end;
      else
         raise Usage_Error with "unknown command " & Cmd & "; try help";
      end if;
   end Execute;

   Host : Unbounded_String := To_Unbounded_String ("127.0.0.1");
   Port : GNAT.Sockets.Port_Type := Server.Default_Port;
   I    : Positive := 1;
   Failures : Natural := 0;
begin
   while I <= Argument_Count loop
      if Argument (I) = "--version" then
         Put_Line ("scopebridge-term " & Scopebridge_Version.Version);
         return;
      elsif Argument (I) = "--host" and then I < Argument_Count then
         Host := To_Unbounded_String (Argument (I + 1));
         I := I + 2;
      elsif Argument (I) = "--port" and then I < Argument_Count then
         Port := GNAT.Sockets.Port_Type'Value (Argument (I + 1));
         I := I + 2;
      else
         Put_Line (Standard_Error, "usage: scopebridge-term [--host HOST] [--port N] | --version");
         Set_Exit_Status (Failure);
         return;
      end if;
   end loop;

   Term_Client.Connect (To_String (Host), Port);
   if Interactive then
      Put_Line ("Connected to " & String'(Get (Term_Client.Hello, "source")) & ": " &
                (if Kind (Get (Term_Client.Hello, "idn")) = JSON_String_Type
                 then Get (Term_Client.Hello, "idn") else "no reply from the scope"));
      Put_Line ("Type help for the commands.");
   end if;

   loop
      if Interactive then
         Put ("scopebridge> ");
         Flush;
      end if;
      exit when End_Of_File;
      declare
         Line : constant String := Get_Line;
         Cmd  : constant String := To_Lower (Trim (Line, Ada.Strings.Both));
      begin
         exit when Cmd = "quit" or else Cmd = "exit";
         if not Interactive and then Cmd /= "" and then Cmd (Cmd'First) /= '#' then
            Put_Line ("> " & Trim (Line, Ada.Strings.Both));   --  echo in logs
         end if;
         Execute (Line);
      exception
         when E : Usage_Error | Term_Client.Request_Failed =>
            Put_Line ("  error: " & Exception_Message (E));
            Failures := Failures + 1;
         when E : Invalid_JSON_Stream =>
            Put_Line ("  error: not JSON: " & Exception_Message (E));
            Failures := Failures + 1;
      end;
   end loop;
   Term_Client.Close;
   if Failures > 0 and then not Interactive then
      Set_Exit_Status (Failure);   --  a script with a failing command
   end if;

exception
   when E : Term_Client.Connection_Lost =>
      Put_Line (Standard_Error, "scopebridge-term: " & Exception_Message (E));
      Set_Exit_Status (Failure);
end Scopebridge_Term;
