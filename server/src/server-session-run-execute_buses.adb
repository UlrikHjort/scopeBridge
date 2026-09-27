-- ***************************************************************************
--                ScopeBridge Server - Bus Decoding Requests
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

--  Bus decoding: decode (by the server, of captures) and set_decoder
--  (the scope's own decoder).

with Rigol.Decoder;

with Server.Decode;

separate (Server.Session.Run)
procedure Execute_Buses
  (Cmd     : String;
   Request : JSON_Value;
   Reply   : JSON_Value;
   Payload : in out Unbounded_String;
   Binary  : in out Boolean;
   Done    : out Boolean)
is
   pragma Unreferenced (Payload, Binary);   --  no binary replies here

   type Protocol_Kind is (UART, I2C, SPI);

   type Channel_Flags  is array (Channel) of Boolean;
   type Channel_Levels is array (Channel) of Float;

   type Bus_Config is record
      Protocol  : Protocol_Kind := UART;
      --  UART
      TX        : Channel  := 1;
      RX        : Natural  := 0;          --  0 = none
      Baud      : Positive := 9600;
      Bits      : Positive := 8;
      Parity    : Server.Decode.Parity_Kind := Server.Decode.None;
      Stop      : Long_Float := 1.0;
      Inverted  : Boolean  := False;
      MSB_First : Boolean  := False;
      --  I2C
      SCL       : Channel  := 1;
      SDA       : Channel  := 2;
      --  SPI (and Inverted, MSB_First)
      CLK       : Channel  := 1;
      Data      : Channel  := 2;
      Rising    : Boolean  := True;
      Width     : Positive := 8;
      Timeout   : Float    := 0.0;        --  s, 0 = automatic
      --  Thresholds in volts, if given
      Has_Threshold : Channel_Flags  := (others => False);
      Threshold     : Channel_Levels := (others => 0.0);
   end record;

   --  Channel member Name, or Default if absent
   function Line_Field
     (Request : JSON_Value; Name : String; Default : Channel) return Channel
   is
   begin
      if not Has_Field (Request, Name) then
         return Default;
      end if;
      declare
         N : constant Integer := Integer_Field (Request, Name);
      begin
         if N not in 1 .. 2 then
            raise Request_Error with """" & Name & """ must be 1 or 2";
         end if;
         return Channel (N);
      end;
   end Line_Field;

   function Bus_Fields (Request : JSON_Value) return Bus_Config is
      B : Bus_Config;
      P : constant String := String_Field (Request, "protocol");

      function Has (Name : String) return Boolean is (Has_Field (Request, Name));
   begin
      if P = "uart" then
         B.Protocol := UART;
      elsif P = "i2c" then
         B.Protocol := I2C;
      elsif P = "spi" then
         B.Protocol := SPI;
      else
         raise Request_Error with """protocol"" must be ""uart"", ""i2c"" or ""spi""";
      end if;

      case B.Protocol is
         when UART =>
            B.TX := Line_Field (Request, "tx", 1);
            if Has ("rx") and then Kind (Get (Request, "rx")) /= JSON_Null_Type then
               B.RX := Natural (Line_Field (Request, "rx", 1));
               if B.RX = Natural (B.TX) then
                  raise Request_Error with """tx"" and ""rx"" must differ";
               end if;
            end if;
            if Has ("baud") then
               if Integer_Field (Request, "baud") < 1 then
                  raise Request_Error with """baud"" must be positive";
               end if;
               B.Baud := Integer_Field (Request, "baud");
            end if;
            if Has ("bits") then
               if Integer_Field (Request, "bits") not in 5 .. 9 then
                  raise Request_Error with """bits"" must be 5 .. 9";
               end if;
               B.Bits := Integer_Field (Request, "bits");
            end if;
            if Has ("parity") then
               declare
                  S : constant String := String_Field (Request, "parity");
               begin
                  B.Parity := (if S = "none" then Server.Decode.None
                               elsif S = "even" then Server.Decode.Even
                               elsif S = "odd" then Server.Decode.Odd
                               else raise Request_Error
                                 with """parity"" must be ""none"", ""even"" or ""odd""");
               end;
            end if;
            if Has ("stop") then
               B.Stop := Long_Float (Number_Field (Request, "stop"));
               if B.Stop not in 1.0 | 1.5 | 2.0 then
                  raise Request_Error with """stop"" must be 1, 1.5 or 2";
               end if;
            end if;
            B.MSB_First := Has ("msb_first") and then Boolean_Field (Request, "msb_first");
         when I2C =>
            B.SCL := Line_Field (Request, "scl", 1);
            B.SDA := Line_Field (Request, "sda", (if B.SCL = 1 then 2 else 1));
            if B.SCL = B.SDA then
               raise Request_Error with """scl"" and ""sda"" must differ";
            end if;
         when SPI =>
            B.CLK  := Line_Field (Request, "clk", 1);
            B.Data := Line_Field (Request, "data", (if B.CLK = 1 then 2 else 1));
            if B.CLK = B.Data then
               raise Request_Error with """clk"" and ""data"" must differ";
            end if;
            if Has ("edge") then
               declare
                  S : constant String := String_Field (Request, "edge");
               begin
                  if S not in "rising" | "falling" then
                     raise Request_Error with """edge"" must be ""rising"" or ""falling""";
                  end if;
                  B.Rising := S = "rising";
               end;
            end if;
            if Has ("width") then
               if Integer_Field (Request, "width") not in 4 .. 32 then
                  raise Request_Error with """width"" must be 4 .. 32";
               end if;
               B.Width := Integer_Field (Request, "width");
            end if;
            if Has ("timeout") then
               B.Timeout := Number_Field (Request, "timeout");
               if B.Timeout <= 0.0 then
                  raise Request_Error with """timeout"" must be positive";
               end if;
            end if;
            B.MSB_First := not Has ("msb_first")
                             or else Boolean_Field (Request, "msb_first");
      end case;
      B.Inverted := Has ("inverted") and then Boolean_Field (Request, "inverted");

      for Ch in Channel loop
         declare
            Name : constant String := "threshold" & Character'Val (48 + Integer (Ch));
         begin
            if Has (Name) then
               B.Has_Threshold (Ch) := True;
               B.Threshold (Ch)     := Number_Field (Request, Name);
            end if;
         end;
      end loop;
      return B;
   end Bus_Fields;

   --  The channels a bus uses
   function Uses (B : Bus_Config; Ch : Channel) return Boolean is
     (case B.Protocol is
         when UART => Ch = B.TX or else Natural (Ch) = B.RX,
         when I2C  => Ch = B.SCL or else Ch = B.SDA,
         when SPI  => Ch = B.CLK or else Ch = B.Data);

   function Item_Type (K : Server.Decode.Item_Kind) return String is
     (case K is
         when Server.Decode.Start   => "start",
         when Server.Decode.Stop    => "stop",
         when Server.Decode.Address => "address",
         when Server.Decode.Data    => "data");
begin
   Done := True;
   if Cmd = "decode" then
      declare
         use Server.Decode;
         B       : constant Bus_Config := Bus_Fields (Request);
         Max     : constant Integer :=
           (if Has_Field (Request, "max_items")
            then Integer_Field (Request, "max_items") else 100_000);
         Main    : constant Channel :=
           (case B.Protocol is
               when UART => B.TX, when I2C => B.SCL, when SPI => B.CLK);
         C       : constant Capture := Captured (Main);
         First   : Natural := 0;
         Last    : Natural := C.Data'Length - 1;
         Lines   : array (Channel) of Digital;
         Levels  : constant JSON_Value := Create_Object;
         Items   : Item_Vectors.Vector;
         Full    : Boolean := False;   --  a decoder stopped at Max
         List    : JSON_Array := Empty_Array;
         X_Inc   : constant Long_Float := Long_Float (C.Pre.X_Increment);
      begin
         if Max not in 1 .. 1_000_000 then
            raise Request_Error with """max_items"" must be 1 .. 1000000";
         end if;
         for Ch in Channel loop
            if Uses (B, Ch) and then Ch /= Main then
               declare
                  Other : constant Capture := Captured (Ch);
               begin
                  if Other.Data'Length /= C.Data'Length
                    or else Other.Pre.X_Increment /= C.Pre.X_Increment
                  then
                     raise Request_Error
                       with "the captures of CH1 and CH2 differ; capture both again";
                  end if;
               end;
            end if;
         end loop;
         if Has_Field (Request, "first") or else Has_Field (Request, "last") then
            Range_Fields (Request, C.Data'Length, First, Last);
         end if;

         --  Logic levels of each line, at its threshold
         for Ch in Channel loop
            if Uses (B, Ch) then
               declare
                  D    : Raw_Array renames Captures (Ch).Data.all;
                  P    : Preamble renames Captures (Ch).Pre;
                  Th   : Float;
                  Hy   : Float;
                  Flat : Boolean;
               begin
                  Auto_Threshold (D, D'First + First, D'First + Last, Th, Hy, Flat);
                  if B.Has_Threshold (Ch) then
                     Th := B.Threshold (Ch) / P.Y_Increment
                             + P.Y_Reference + P.Y_Origin;
                  elsif Flat then
                     raise Request_Error with "CH" & Character'Val (48 + Integer (Ch))
                       & " shows no logic signal in the capture";
                  end if;
                  Lines (Ch) := Digitize (D, D'First + First, D'First + Last, Th, Hy);
                  Set_Field (Levels, "ch" & Character'Val (48 + Integer (Ch)),
                             To_JSON ((Th - P.Y_Reference - P.Y_Origin) * P.Y_Increment));
               end;
            end if;
         end loop;

         case B.Protocol is
            when UART =>
               declare
                  Per_Bit : constant Long_Float := 1.0 / (Long_Float (B.Baud) * X_Inc);
                  S       : constant UART_Settings :=
                    (Samples_Per_Bit => Per_Bit, Data_Bits => B.Bits,
                     Parity => B.Parity, Stop_Bits => B.Stop,
                     Inverted => B.Inverted, MSB_First => B.MSB_First);
                  More    : Item_Vectors.Vector;
               begin
                  if Per_Bit < Min_Samples_Per_Bit then
                     raise Request_Error with "the capture has" &
                       Integer'Image (Integer (Long_Float'Floor (Per_Bit))) &
                       " samples per bit at this baud rate; capture at a faster timebase";
                  end if;
                  Decode_UART (Lines (B.TX), Integer (B.TX), S, Items, Max);
                  Full := Integer (Items.Length) >= Max;
                  if B.RX /= 0 then
                     Decode_UART (Lines (Channel (B.RX)), B.RX, S, More, Max);
                     Full := Full or else Integer (More.Length) >= Max;
                     Items.Append (More);
                     Sort (Items);
                  end if;
                  Set_Field (Reply, "samples_per_bit", To_JSON (Per_Bit));
               end;
            when I2C =>
               Decode_I2C (Lines (B.SCL), Lines (B.SDA), Integer (B.SDA), Items, Max);
               Full := Integer (Items.Length) >= Max;
            when SPI =>
               declare
                  Used : Natural;
               begin
                  Decode_SPI
                    (Lines (B.CLK), Lines (B.Data), Integer (B.Data),
                     (Sample_On_Rise => B.Rising, Width => B.Width,
                      MSB_First => B.MSB_First, Inverted => B.Inverted,
                      Timeout => (if B.Timeout = 0.0 then 0
                                  else Natural'Max (1, Natural
                                    (Long_Float (B.Timeout) / X_Inc)))),
                     Items, Max, Used);
                  Full := Integer (Items.Length) >= Max;
                  Set_Field (Reply, "timeout", To_JSON (Long_Float (Used) * X_Inc));
               end;
         end case;

         while Integer (Items.Length) > Max loop
            Items.Delete_Last;
         end loop;
         for I of Items loop
            declare
               O : constant JSON_Value := Create_Object;
            begin
               Set_Field (O, "ch", I.Line);
               Set_Field (O, "type", Item_Type (I.Kind));
               Set_Field (O, "first", First + I.First);
               Set_Field (O, "last", First + I.Last);
               Set_Field (O, "t", To_JSON (Long_Float (C.Pre.X_Origin)
                                           + Long_Float (First + I.First) * X_Inc));
               if I.Kind in Address | Data then
                  Set_Field (O, "value", Create (Long_Long_Integer (I.Value)));
               end if;
               if B.Protocol = I2C and then I.Kind in Address | Data then
                  Set_Field (O, "ack", I.Ack);
                  if I.Kind = Address then
                     Set_Field (O, "read", I.Read);
                  end if;
               end if;
               if I.Error /= None then
                  Set_Field (O, "error", (if I.Error = Parity then "parity" else "framing"));
               end if;
               Append (List, O);
            end;
         end loop;
         Set_Field (Reply, "protocol", String_Field (Request, "protocol"));
         Set_Field (Reply, "count", Integer (Items.Length));
         Set_Field (Reply, "truncated", Full);
         Set_Field (Reply, "thresholds", Levels);
         Set_Field (Reply, "items", Create (List));
      end;

   elsif Cmd = "set_decoder" then
      declare
         use Rigol.Decoder;
         B       : constant Bus_Config := Bus_Fields (Request);
         N       : constant Integer :=
           (if Has_Field (Request, "bus") then Integer_Field (Request, "bus") else 1);
         Fmt     : constant String :=
           (if Has_Field (Request, "format") then String_Field (Request, "format")
            else "hex");
         Display : constant Boolean :=
           not Has_Field (Request, "display") or else Boolean_Field (Request, "display");

         function Source (Ch : Natural) return Line_Source is
           (case Ch is when 1 => CH1, when 2 => CH2, when others => Off);
      begin
         if N not in 1 .. 2 then
            raise Request_Error with """bus"" must be 1 or 2";
         elsif Fmt not in "hex" | "ascii" | "dec" | "bin" then
            raise Request_Error
              with """format"" must be ""hex"", ""ascii"", ""dec"" or ""bin""";
         elsif B.Protocol = UART and then B.Bits > 8 then
            raise Request_Error with "the scope decodes 5 .. 8 UART bits";
         elsif B.Protocol = SPI and then B.Width < 8 then
            raise Request_Error with "the scope decodes SPI words of 8 .. 32 bits";
         end if;
         declare
            Bus_N : constant Bus := Bus (N);
         begin
            case B.Protocol is
               when UART =>
                  Set_Mode (Scope, Bus_N, Rigol.Decoder.UART);
                  Set_UART_TX (Scope, Bus_N, Source (Natural (B.TX)));
                  Set_UART_RX (Scope, Bus_N, Source (B.RX));
                  Set_UART_Baud (Scope, Bus_N, B.Baud);
                  Set_UART_Width (Scope, Bus_N, B.Bits);
                  Set_UART_Parity (Scope, Bus_N,
                                   (case B.Parity is
                                       when Server.Decode.None => None,
                                       when Server.Decode.Even => Even,
                                       when Server.Decode.Odd  => Odd));
                  Set_UART_Stop (Scope, Bus_N,
                                 (if B.Stop = 1.0 then One
                                  elsif B.Stop = 1.5 then One_And_A_Half else Two));
                  Set_UART_Polarity (Scope, Bus_N,
                                     (if B.Inverted then Inverted else Normal));
                  Set_UART_Order (Scope, Bus_N,
                                  (if B.MSB_First then MSB_First else LSB_First));
               when I2C =>
                  Set_Mode (Scope, Bus_N, Rigol.Decoder.I2C);
                  Set_I2C_Clock (Scope, Bus_N, B.SCL);
                  Set_I2C_Data (Scope, Bus_N, B.SDA);
               when SPI =>
                  Set_Mode (Scope, Bus_N, Rigol.Decoder.SPI);
                  Set_SPI_Clock (Scope, Bus_N, B.CLK);
                  Set_SPI_MOSI (Scope, Bus_N, Source (Natural (B.Data)));
                  Set_SPI_MISO (Scope, Bus_N, Off);
                  Set_SPI_Edge (Scope, Bus_N, (if B.Rising then Rising else Falling));
                  Set_SPI_Width (Scope, Bus_N, B.Width);
                  Set_SPI_Order (Scope, Bus_N,
                                 (if B.MSB_First then MSB_First else LSB_First));
                  Set_SPI_Polarity (Scope, Bus_N,
                                    (if B.Inverted then Inverted else Normal));
                  if B.Timeout > 0.0 then
                     Set_SPI_Timeout (Scope, Bus_N, B.Timeout);
                  end if;
            end case;
            if B.Has_Threshold (1) or else B.Has_Threshold (2) then
               for Ch in Channel loop
                  if B.Has_Threshold (Ch) then
                     Set_Threshold (Scope, Bus_N, Ch, B.Threshold (Ch));
                  end if;
               end loop;
            else
               Set_Auto_Threshold (Scope, Bus_N, True);
            end if;
            Set_Format (Scope, Bus_N,
                        (if Fmt = "hex" then Hex elsif Fmt = "ascii" then Rigol.Decoder.ASCII
                         elsif Fmt = "dec" then Decimal else Rigol.Decoder.Binary));
            Set_Display (Scope, Bus_N, Display);
         end;
      end;

   else
      Done := False;
   end if;
end Execute_Buses;
