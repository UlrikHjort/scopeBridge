-- ***************************************************************************
--                      Rigol - Channel Commands Specification
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

--  :CHANnel<n> command group.
--  Controls vertical settings: coupling, scale, offset, bandwidth limit,
--  probe ratio, inversion, and display on/off.

package Rigol.Channel is

   type Channel_Number is range 1 .. 2;
   --  DS1202Z-E has 2 analog channels.

   type Coupling_Type is (AC, DC, GND);

   type BW_Limit is (Full, BW_20MHz);
   --  Full = no limit; BW_20MHz = 20 MHz hardware filter

   type Probe_Ratio is
     (X0_01, X0_02, X0_05, X0_1, X0_2, X0_5,
      X1, X2, X5, X10, X20, X50, X100, X200, X500, X1000);

   type Units_Type is (Voltage, Watt, Ampere, Unknown);

   -- -------------------------------------------------------------------------

   --  :CHANnel<n>:DISPlay - turn channel display on or off
   procedure Set_Display
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Enabled : in     Boolean);

   function Get_Display
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number) return Boolean;

   -- -------------------------------------------------------------------------

   --  :CHANnel<n>:COUPling - AC / DC / GND
   procedure Set_Coupling
     (Scope    : in out Oscilloscope;
      Channel  : in     Channel_Number;
      Coupling : in     Coupling_Type);

   function Get_Coupling
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number) return Coupling_Type;

   -- -------------------------------------------------------------------------

   --  :CHANnel<n>:SCALe - volts per division
   procedure Set_Scale
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Volts   : in     Float);

   function Get_Scale
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number) return Float;

   -- -------------------------------------------------------------------------

   --  :CHANnel<n>:OFFSet - vertical offset in volts
   procedure Set_Offset
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Volts   : in     Float);

   function Get_Offset
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number) return Float;

   -- -------------------------------------------------------------------------

   --  :CHANnel<n>:BWLimit - bandwidth limit
   procedure Set_BW_Limit
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Limit   : in     BW_Limit);

   -- -------------------------------------------------------------------------

   --  :CHANnel<n>:INVert - invert the channel waveform
   procedure Set_Invert
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Enabled : in     Boolean);

   -- -------------------------------------------------------------------------

   --  :CHANnel<n>:PROBe - probe attenuation ratio
   procedure Set_Probe
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Ratio   : in     Probe_Ratio);

   function Get_Probe
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number) return Probe_Ratio;

   -- -------------------------------------------------------------------------

   --  :CHANnel<n>:UNITs - measurement unit
   procedure Set_Units
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Units   : in     Units_Type);

end Rigol.Channel;
