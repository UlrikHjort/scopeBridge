-- ***************************************************************************
--                          Rigol - Bus Decoder Body
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

package body Rigol.Decoder is

   --  ":DECoder1:" and so on
   function Prefix (B : Bus) return String is
     (":DECoder" & Image (Integer (B)) & ":");

   procedure Set (Scope : in out Oscilloscope; B : Bus; Command : String) is
   begin
      Send (Scope, Prefix (B) & Command);
   end Set;

   function On_Off (On : Boolean) return String is
     (if On then "ON" else "OFF");

   function Channel_Str (Ch : Channel) return String is
     ("CHANnel" & Image (Integer (Ch)));

   function Source_Str (Src : Line_Source) return String is
     (case Src is when Off => "OFF", when CH1 => "CHANnel1", when CH2 => "CHANnel2");

   function Order_Str (Order : Bit_Order) return String is
     (case Order is when LSB_First => "LSB", when MSB_First => "MSB");

   function Polarity_Str (P : Polarity) return String is
     (case P is when Normal => "POSitive", when Inverted => "NEGative");

   procedure Set_Mode (Scope : in out Oscilloscope; B : Bus; Mode : Decode_Mode) is
   begin
      Set (Scope, B, "MODE " &
             (case Mode is
                 when Parallel => "PARallel", when UART => "UART",
                 when SPI      => "SPI",      when I2C  => "IIC"));
   end Set_Mode;

   function Get_Mode (Scope : in out Oscilloscope; B : Bus) return Decode_Mode is
      R : constant String := Query (Scope, Prefix (B) & "MODE?");
   begin
      return (if    R = "UART" then UART
              elsif R = "SPI"  then SPI
              elsif R = "IIC"  then I2C
              else Parallel);
   end Get_Mode;

   procedure Set_Display (Scope : in out Oscilloscope; B : Bus; On : Boolean) is
   begin
      Set (Scope, B, "DISPlay " & On_Off (On));
   end Set_Display;

   function Get_Display (Scope : in out Oscilloscope; B : Bus) return Boolean is
     (Query (Scope, Prefix (B) & "DISPlay?") = "1");

   procedure Set_Format (Scope : in out Oscilloscope; B : Bus; Format : Bus_Format) is
   begin
      Set (Scope, B, "FORMat " &
             (case Format is
                 when Hex     => "HEX", when ASCII  => "ASCii",
                 when Decimal => "DEC", when Binary => "BIN",
                 when Line    => "LINE"));
   end Set_Format;

   procedure Set_Position (Scope : in out Oscilloscope; B : Bus; Position : Positive) is
   begin
      Set (Scope, B, "POSition " & Image (Position));
   end Set_Position;

   procedure Set_Auto_Threshold (Scope : in out Oscilloscope; B : Bus; On : Boolean) is
   begin
      Set (Scope, B, "THREshold:AUTO " & On_Off (On));
   end Set_Auto_Threshold;

   procedure Set_Threshold
     (Scope : in out Oscilloscope; B : Bus; Ch : Channel; Volts : Float) is
   begin
      Set_Auto_Threshold (Scope, B, False);
      Set (Scope, B, "THREshold:" & Channel_Str (Ch) & " " & Image (Volts));
   end Set_Threshold;

   -- -------------------------------------------------------------------------

   procedure Set_UART_TX (Scope : in out Oscilloscope; B : Bus; Src : Line_Source) is
   begin
      Set (Scope, B, "UART:TX " & Source_Str (Src));
   end Set_UART_TX;

   procedure Set_UART_RX (Scope : in out Oscilloscope; B : Bus; Src : Line_Source) is
   begin
      Set (Scope, B, "UART:RX " & Source_Str (Src));
   end Set_UART_RX;

   procedure Set_UART_Polarity (Scope : in out Oscilloscope; B : Bus; P : Polarity) is
   begin
      Set (Scope, B, "UART:POLarity " & Polarity_Str (P));
   end Set_UART_Polarity;

   procedure Set_UART_Order (Scope : in out Oscilloscope; B : Bus; Order : Bit_Order) is
   begin
      Set (Scope, B, "UART:ENDian " & Order_Str (Order));
   end Set_UART_Order;

   procedure Set_UART_Baud (Scope : in out Oscilloscope; B : Bus; Baud : Positive) is
   begin
      Set (Scope, B, "UART:BAUD " & Image (Baud));
   end Set_UART_Baud;

   procedure Set_UART_Width (Scope : in out Oscilloscope; B : Bus; Bits : Positive) is
   begin
      Set (Scope, B, "UART:WIDTh " & Image (Bits));
   end Set_UART_Width;

   procedure Set_UART_Stop (Scope : in out Oscilloscope; B : Bus; Stop : Stop_Bits) is
   begin
      Set (Scope, B, "UART:STOP " &
             (case Stop is when One => "1", when One_And_A_Half => "1.5",
                           when Two => "2"));
   end Set_UART_Stop;

   procedure Set_UART_Parity (Scope : in out Oscilloscope; B : Bus; P : Parity) is
   begin
      Set (Scope, B, "UART:PARity " &
             (case P is when None => "NONE", when Even => "EVEN", when Odd => "ODD"));
   end Set_UART_Parity;

   -- -------------------------------------------------------------------------

   procedure Set_I2C_Clock (Scope : in out Oscilloscope; B : Bus; Ch : Channel) is
   begin
      Set (Scope, B, "IIC:CLK " & Channel_Str (Ch));
   end Set_I2C_Clock;

   procedure Set_I2C_Data (Scope : in out Oscilloscope; B : Bus; Ch : Channel) is
   begin
      Set (Scope, B, "IIC:DATA " & Channel_Str (Ch));
   end Set_I2C_Data;

   procedure Set_I2C_Address_With_RW
     (Scope : in out Oscilloscope; B : Bus; On : Boolean) is
   begin
      Set (Scope, B, "IIC:ADDRess " & (if On then "RW" else "NORMal"));
   end Set_I2C_Address_With_RW;

   -- -------------------------------------------------------------------------

   procedure Set_SPI_Clock (Scope : in out Oscilloscope; B : Bus; Ch : Channel) is
   begin
      Set (Scope, B, "SPI:CLK " & Channel_Str (Ch));
   end Set_SPI_Clock;

   procedure Set_SPI_MISO (Scope : in out Oscilloscope; B : Bus; Src : Line_Source) is
   begin
      Set (Scope, B, "SPI:MISO " & Source_Str (Src));
   end Set_SPI_MISO;

   procedure Set_SPI_MOSI (Scope : in out Oscilloscope; B : Bus; Src : Line_Source) is
   begin
      Set (Scope, B, "SPI:MOSI " & Source_Str (Src));
   end Set_SPI_MOSI;

   procedure Set_SPI_Timeout (Scope : in out Oscilloscope; B : Bus; Seconds : Float) is
   begin
      Set (Scope, B, "SPI:MODE TIMeout");
      Set (Scope, B, "SPI:TIMeout " & Image (Seconds));
   end Set_SPI_Timeout;

   procedure Set_SPI_Polarity (Scope : in out Oscilloscope; B : Bus; P : Polarity) is
   begin
      Set (Scope, B, "SPI:POLarity " & Polarity_Str (P));
   end Set_SPI_Polarity;

   procedure Set_SPI_Edge (Scope : in out Oscilloscope; B : Bus; Edge : Clock_Edge) is
   begin
      Set (Scope, B, "SPI:EDGE " & (if Edge = Rising then "RISE" else "FALL"));
   end Set_SPI_Edge;

   procedure Set_SPI_Order (Scope : in out Oscilloscope; B : Bus; Order : Bit_Order) is
   begin
      Set (Scope, B, "SPI:ENDian " & Order_Str (Order));
   end Set_SPI_Order;

   procedure Set_SPI_Width (Scope : in out Oscilloscope; B : Bus; Bits : Positive) is
   begin
      Set (Scope, B, "SPI:WIDTh " & Image (Bits));
   end Set_SPI_Width;

end Rigol.Decoder;
