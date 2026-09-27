-- ***************************************************************************
--                      Rigol - Channel Commands Body
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

with Ada.Strings.Fixed;

package body Rigol.Channel is

   --  Build ":CHANnel<n>" prefix
   function Ch_Prefix (Channel : Channel_Number) return String is
   begin
      return ":CHANnel" & Ada.Strings.Fixed.Trim
        (Channel_Number'Image (Channel), Ada.Strings.Left);
   end Ch_Prefix;

   --  Parse a "1"/"0" or "ON"/"OFF" reply into Boolean
   function Parse_Bool (S : String) return Boolean is
   begin
      return S = "1" or else S = "ON";
   end Parse_Bool;

   --  Parse a float reply (scientific notation or decimal)
   function Parse_Float (S : String) return Float is
   begin
      return Float'Value (S);
   end Parse_Float;

   -- -------------------------------------------------------------------------

   procedure Set_Display
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Enabled : in     Boolean)
   is
      Val : constant String := (if Enabled then "1" else "0");
   begin
      Send (Scope, Ch_Prefix (Channel) & ":DISPlay " & Val);
   end Set_Display;

   function Get_Display
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number) return Boolean
   is
   begin
      return Parse_Bool (Query (Scope, Ch_Prefix (Channel) & ":DISPlay?"));
   end Get_Display;

   -- -------------------------------------------------------------------------

   procedure Set_Coupling
     (Scope    : in out Oscilloscope;
      Channel  : in     Channel_Number;
      Coupling : in     Coupling_Type)
   is
      Val : constant String :=
        (case Coupling is
           when AC  => "AC",
           when DC  => "DC",
           when GND => "GND");
   begin
      Send (Scope, Ch_Prefix (Channel) & ":COUPling " & Val);
   end Set_Coupling;

   function Get_Coupling
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number) return Coupling_Type
   is
      R : constant String := Query (Scope, Ch_Prefix (Channel) & ":COUPling?");
   begin
      if    R = "AC"  then return AC;
      elsif R = "DC"  then return DC;
      else                 return GND;
      end if;
   end Get_Coupling;

   -- -------------------------------------------------------------------------

   procedure Set_Scale
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Volts   : in     Float)
   is
   begin
      Send (Scope, Ch_Prefix (Channel) & ":SCALe " & Image (Volts));
   end Set_Scale;

   function Get_Scale
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number) return Float
   is
   begin
      return Parse_Float (Query (Scope, Ch_Prefix (Channel) & ":SCALe?"));
   end Get_Scale;

   -- -------------------------------------------------------------------------

   procedure Set_Offset
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Volts   : in     Float)
   is
   begin
      Send (Scope, Ch_Prefix (Channel) & ":OFFSet " & Image (Volts));
   end Set_Offset;

   function Get_Offset
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number) return Float
   is
   begin
      return Parse_Float (Query (Scope, Ch_Prefix (Channel) & ":OFFSet?"));
   end Get_Offset;

   -- -------------------------------------------------------------------------

   procedure Set_BW_Limit
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Limit   : in     BW_Limit)
   is
      Val : constant String :=
        (case Limit is
           when Full     => "OFF",
           when BW_20MHz => "20M");
   begin
      Send (Scope, Ch_Prefix (Channel) & ":BWLimit " & Val);
   end Set_BW_Limit;

   -- -------------------------------------------------------------------------

   procedure Set_Invert
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Enabled : in     Boolean)
   is
   begin
      Send (Scope, Ch_Prefix (Channel) & ":INVert " &
            (if Enabled then "1" else "0"));
   end Set_Invert;

   -- -------------------------------------------------------------------------

   procedure Set_Probe
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Ratio   : in     Probe_Ratio)
   is
      Val : constant String :=
        (case Ratio is
           when X0_01  => "0.01", when X0_02  => "0.02",
           when X0_05  => "0.05", when X0_1   => "0.1",
           when X0_2   => "0.2",  when X0_5   => "0.5",
           when X1     => "1",    when X2     => "2",
           when X5     => "5",    when X10    => "10",
           when X20    => "20",   when X50    => "50",
           when X100   => "100",  when X200   => "200",
           when X500   => "500",  when X1000  => "1000");
   begin
      Send (Scope, Ch_Prefix (Channel) & ":PROBe " & Val);
   end Set_Probe;

   function Get_Probe
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number) return Probe_Ratio
   is
      R : constant String := Query (Scope, Ch_Prefix (Channel) & ":PROBe?");
      V : constant Float  := Float'Value (R);
   begin
      if    V <= 0.011  then return X0_01;
      elsif V <= 0.021  then return X0_02;
      elsif V <= 0.051  then return X0_05;
      elsif V <= 0.11   then return X0_1;
      elsif V <= 0.21   then return X0_2;
      elsif V <= 0.51   then return X0_5;
      elsif V <= 1.1    then return X1;
      elsif V <= 2.1    then return X2;
      elsif V <= 5.1    then return X5;
      elsif V <= 10.1   then return X10;
      elsif V <= 20.1   then return X20;
      elsif V <= 50.1   then return X50;
      elsif V <= 100.1  then return X100;
      elsif V <= 200.1  then return X200;
      elsif V <= 500.1  then return X500;
      else                   return X1000;
      end if;
   end Get_Probe;

   -- -------------------------------------------------------------------------

   procedure Set_Units
     (Scope   : in out Oscilloscope;
      Channel : in     Channel_Number;
      Units   : in     Units_Type)
   is
      Val : constant String :=
        (case Units is
           when Voltage => "VOLT",
           when Watt    => "WATT",
           when Ampere  => "AMP",
           when Unknown => "UNKN");
   begin
      Send (Scope, Ch_Prefix (Channel) & ":UNITs " & Val);
   end Set_Units;

end Rigol.Channel;
