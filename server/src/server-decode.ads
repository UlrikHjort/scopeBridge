-- ***************************************************************************
--          ScopeBridge Server - Serial Bus Decoding Specification
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

--  Decoding of UART, I2C and SPI traffic from captured samples, for the
--  server's "decode" request.
--
--  A capture is first reduced to logic levels (Digitize), then decoded
--  into items: bytes or words, and for I2C also start and stop
--  conditions.  Sample numbers are counted from the first sample
--  digitized.
--
--  Decoding starts where the bus is known to be idle, so that a capture
--  starting in the middle of a frame does not produce a wrong one: a UART
--  line must have been idle for a whole frame, and an SPI clock quiet for
--  longer than the timeout, before the first item.  I2C starts at the
--  first start condition.

with Ada.Containers.Vectors;
with Interfaces;

with Rigol.Waveform;

package Server.Decode is

   package Index_Vectors is new Ada.Containers.Vectors (Positive, Natural);

   --  A line as logic levels: the level of sample 0, and the samples at
   --  which it changes (each the first sample at the new level), in order
   type Digital is record
      Length  : Natural := 0;
      Initial : Boolean := False;
      Edges   : Index_Vectors.Vector;
   end record;

   --  Samples First .. Last of Data as logic levels, in raw counts: a low
   --  line goes high above Threshold + Hysteresis, a high one low below
   --  Threshold - Hysteresis, so noise near the threshold makes no edges
   function Digitize
     (Data        : Rigol.Waveform.Raw_Array;
      First, Last : Positive;
      Threshold   : Float;
      Hysteresis  : Float) return Digital;

   --  A threshold halfway between the lowest and highest of samples
   --  First .. Last, with a tenth of that swing as hysteresis.  Flat if
   --  the swing is too small to be a logic signal.
   procedure Auto_Threshold
     (Data        : Rigol.Waveform.Raw_Array;
      First, Last : Positive;
      Threshold   : out Float;
      Hysteresis  : out Float;
      Flat        : out Boolean);

   --  The level of sample I
   function Level_At (Line : Digital; I : Natural) return Boolean;

   -- -------------------------------------------------------------------------

   type Item_Kind  is (Start, Stop, Address, Data);
   type Error_Kind is (None, Parity, Framing);

   type Item is record
      Kind  : Item_Kind;
      Line  : Positive := 1;        --  channel carrying the data
      First : Natural  := 0;        --  samples covered
      Last  : Natural  := 0;
      Value : Interfaces.Unsigned_32 := 0;   --  I2C address: 7 bits
      Read  : Boolean := False;     --  I2C address: R/W bit set
      Ack   : Boolean := False;     --  I2C address or data: acknowledged
      Error : Error_Kind := None;   --  UART
   end record;

   package Item_Vectors is new Ada.Containers.Vectors (Positive, Item);

   --  Items in order of their first sample
   procedure Sort (Items : in out Item_Vectors.Vector);

   --  Decoders append to Items until it holds Max_Items

   type Parity_Kind is (None, Even, Odd);

   type UART_Settings is record
      Samples_Per_Bit : Long_Float;
      Data_Bits       : Positive range 5 .. 9 := 8;
      Parity          : Parity_Kind := None;
      Stop_Bits       : Long_Float  := 1.0;     --  1.0, 1.5 or 2.0
      Inverted        : Boolean     := False;   --  idle low
      MSB_First       : Boolean     := False;
   end record;

   --  Fewer samples per bit cannot place the bits reliably
   Min_Samples_Per_Bit : constant := 4.0;

   procedure Decode_UART
     (Line      : Digital;
      Ch        : Positive;
      Settings  : UART_Settings;
      Items     : in out Item_Vectors.Vector;
      Max_Items : Positive);

   --  Start and stop conditions, addresses (7-bit) and data bytes
   procedure Decode_I2C
     (SCL, SDA  : Digital;
      SDA_Ch    : Positive;
      Items     : in out Item_Vectors.Vector;
      Max_Items : Positive);

   type SPI_Settings is record
      Sample_On_Rise : Boolean  := True;    --  data valid on the rising edge
      Width          : Positive range 4 .. 32 := 8;
      MSB_First      : Boolean  := True;
      Inverted       : Boolean  := False;   --  data active low
      Timeout        : Natural  := 0;       --  samples; 0 = automatic
   end record;

   --  Words of Width bits.  A pause between clock edges longer than the
   --  timeout ends a word; the automatic timeout is three times the usual
   --  time between clock edges, returned as Timeout_Used.
   procedure Decode_SPI
     (Clock, Data  : Digital;
      Data_Ch      : Positive;
      Settings     : SPI_Settings;
      Items        : in out Item_Vectors.Vector;
      Max_Items    : Positive;
      Timeout_Used : out Natural);

end Server.Decode;
