-- ***************************************************************************
--                      Rigol - Bus Decoder Specification
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

--  :DECoder command group: the scope's two bus decoders, which draw a
--  decoded bus (UART, I2C or SPI) on its screen.  The scope has no
--  command that returns the decoded data; rigol_server decodes captured
--  memory itself for that (its "decode" request).
--
--  With two channels, SPI is a clock and one data line, framed by a
--  timeout: a pause in the clock longer than it starts a new word.

with Rigol.Channel;

package Rigol.Decoder is

   type Bus is range 1 .. 2;

   subtype Channel is Rigol.Channel.Channel_Number;

   type Decode_Mode is (Parallel, UART, SPI, I2C);
   type Bus_Format  is (Hex, ASCII, Decimal, Binary, Line);
   type Line_Source is (Off, CH1, CH2);           --  for lines that may be off
   type Bit_Order   is (LSB_First, MSB_First);
   type Polarity    is (Normal, Inverted);     --  POSitive, NEGative
   type Parity      is (None, Even, Odd);
   type Stop_Bits   is (One, One_And_A_Half, Two);
   type Clock_Edge  is (Rising, Falling);

   procedure Set_Mode    (Scope : in out Oscilloscope; B : Bus; Mode : Decode_Mode);
   function  Get_Mode    (Scope : in out Oscilloscope; B : Bus) return Decode_Mode;
   procedure Set_Display (Scope : in out Oscilloscope; B : Bus; On : Boolean);
   function  Get_Display (Scope : in out Oscilloscope; B : Bus) return Boolean;
   procedure Set_Format  (Scope : in out Oscilloscope; B : Bus; Format : Bus_Format);

   --  Vertical position of the bus on the screen: 50 (top) .. 350
   procedure Set_Position (Scope : in out Oscilloscope; B : Bus; Position : Positive);

   --  Thresholds: automatic, or Volts for channel Ch (which switches the
   --  automatic threshold off)
   procedure Set_Auto_Threshold (Scope : in out Oscilloscope; B : Bus; On : Boolean);
   procedure Set_Threshold
     (Scope : in out Oscilloscope; B : Bus; Ch : Channel; Volts : Float);

   --  UART (RS232)
   procedure Set_UART_TX       (Scope : in out Oscilloscope; B : Bus; Src : Line_Source);
   procedure Set_UART_RX       (Scope : in out Oscilloscope; B : Bus; Src : Line_Source);
   procedure Set_UART_Polarity (Scope : in out Oscilloscope; B : Bus; P : Polarity);
   procedure Set_UART_Order    (Scope : in out Oscilloscope; B : Bus; Order : Bit_Order);
   procedure Set_UART_Baud     (Scope : in out Oscilloscope; B : Bus; Baud : Positive);
   procedure Set_UART_Width    (Scope : in out Oscilloscope; B : Bus; Bits : Positive);
   procedure Set_UART_Stop     (Scope : in out Oscilloscope; B : Bus; Stop : Stop_Bits);
   procedure Set_UART_Parity   (Scope : in out Oscilloscope; B : Bus; P : Parity);

   --  I2C.  Address_With_RW: show the address byte including the R/W bit
   procedure Set_I2C_Clock (Scope : in out Oscilloscope; B : Bus; Ch : Channel);
   procedure Set_I2C_Data  (Scope : in out Oscilloscope; B : Bus; Ch : Channel);
   procedure Set_I2C_Address_With_RW
     (Scope : in out Oscilloscope; B : Bus; On : Boolean);

   --  SPI, framed by a timeout (seconds)
   procedure Set_SPI_Clock    (Scope : in out Oscilloscope; B : Bus; Ch : Channel);
   procedure Set_SPI_MISO     (Scope : in out Oscilloscope; B : Bus; Src : Line_Source);
   procedure Set_SPI_MOSI     (Scope : in out Oscilloscope; B : Bus; Src : Line_Source);
   procedure Set_SPI_Timeout  (Scope : in out Oscilloscope; B : Bus; Seconds : Float);
   procedure Set_SPI_Polarity (Scope : in out Oscilloscope; B : Bus; P : Polarity);
   procedure Set_SPI_Edge     (Scope : in out Oscilloscope; B : Bus; Edge : Clock_Edge);
   procedure Set_SPI_Order    (Scope : in out Oscilloscope; B : Bus; Order : Bit_Order);
   procedure Set_SPI_Width    (Scope : in out Oscilloscope; B : Bus; Bits : Positive);

end Rigol.Decoder;
