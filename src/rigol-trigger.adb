-- ***************************************************************************
--                      Rigol - Trigger Commands Body
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

with Rigol_Transport;

package body Rigol.Trigger is

   -- -------------------------------------------------------------------------

   function Source_Str (S : Trigger_Source) return String is
   begin
      case S is
         when CH1     => return "CHAN1";
         when CH2     => return "CHAN2";
         when AC_Line => return "ACL";
         when EXT     => return "EXT";
      end case;
   end Source_Str;

   -- -------------------------------------------------------------------------

   procedure Set_Mode
     (Scope : in out Oscilloscope;
      Mode  : in     Trigger_Mode)
   is
      Val : constant String :=
        (case Mode is
           when Edge       => "EDGE",
           when Pulse      => "PULSe",
           when Slope      => "SLOPe",
           when Video      => "VIDeo",
           when Pattern    => "PATTern",
           when Duration   => "DURATion",
           when Timeout    => "TIMeout",
           when Runt       => "RUNT",
           when Windows    => "WINDows",
           when Trig_Delay => "DELay",
           when Setup_Hold => "SHOLd",
           when NEDGe      => "NEDGe",
           when RS232      => "RS232",
           when I2C        => "IIC",
           when SPI        => "SPI");
   begin
      Send (Scope, ":TRIGger:MODE " & Val);
   end Set_Mode;

   function Get_Mode (Scope : in out Oscilloscope) return Trigger_Mode is
      R : constant String := Query (Scope, ":TRIGger:MODE?");
   begin
      if    R = "EDGE"  then return Edge;
      elsif R = "PULS"  then return Pulse;
      elsif R = "SLOP"  then return Slope;
      elsif R = "VID"   then return Video;
      elsif R = "PATT"  then return Pattern;
      elsif R = "DUR"   then return Duration;
      elsif R = "TIM"   then return Timeout;
      elsif R = "RUNT"  then return Runt;
      elsif R = "WIND"  then return Windows;
      elsif R = "DEL"   then return Trig_Delay;
      elsif R = "SHOL"  then return Setup_Hold;
      elsif R = "NEDG"  then return NEDGe;
      elsif R = "RS232" then return RS232;
      elsif R = "IIC"   then return I2C;
      else                   return SPI;
      end if;
   end Get_Mode;

   -- -------------------------------------------------------------------------

   procedure Set_Sweep
     (Scope : in out Oscilloscope;
      Sweep : in     Trigger_Sweep)
   is
      Val : constant String :=
        (case Sweep is
           when Auto   => "AUTO",
           when Normal => "NORMal",
           when Single => "SINGle");
   begin
      Send (Scope, ":TRIGger:SWEep " & Val);
   end Set_Sweep;

   function Get_Sweep (Scope : in out Oscilloscope) return Trigger_Sweep is
      R : constant String := Query (Scope, ":TRIGger:SWEep?");
   begin
      if    R = "AUTO" then return Auto;
      elsif R = "NORM" then return Normal;
      else                  return Single;
      end if;
   end Get_Sweep;

   -- -------------------------------------------------------------------------

   procedure Set_Coupling
     (Scope    : in out Oscilloscope;
      Coupling : in     Trigger_Coupling)
   is
      Val : constant String :=
        (case Coupling is
           when AC        => "AC",
           when DC        => "DC",
           when LF_Reject => "LFReject",
           when HF_Reject => "HFReject");
   begin
      Send (Scope, ":TRIGger:COUPling " & Val);
   end Set_Coupling;

   -- -------------------------------------------------------------------------

   function Get_Status (Scope : in out Oscilloscope) return Trigger_Status is
      R : constant String := Query (Scope, ":TRIGger:STATus?");
   begin
      if    R = "TD"   then return TD;
      elsif R = "WAIT" then return Wait;
      elsif R = "RUN"  then return Run;
      elsif R = "AUTO" then return Auto;
      elsif R = "ARM"  then return Armed;
      else                  return Stop;
      end if;
   end Get_Status;

   -- -------------------------------------------------------------------------

   procedure Set_Holdoff
     (Scope   : in out Oscilloscope;
      Seconds : in     Float)
   is
   begin
      Send (Scope, ":TRIGger:HOLDoff " & Image (Seconds));
   end Set_Holdoff;

   -- -------------------------------------------------------------------------
   --  Edge trigger
   -- -------------------------------------------------------------------------

   procedure Set_Edge_Source
     (Scope  : in out Oscilloscope;
      Source : in     Trigger_Source)
   is
   begin
      Send (Scope, ":TRIGger:EDGe:SOURce " & Source_Str (Source));
   end Set_Edge_Source;

   procedure Set_Edge_Slope
     (Scope : in out Oscilloscope;
      Slope : in     Edge_Slope)
   is
      Val : constant String :=
        (case Slope is
           when Rising  => "POSitive",
           when Falling => "NEGative",
           when Either  => "RFALl");
   begin
      Send (Scope, ":TRIGger:EDGe:SLOPe " & Val);
   end Set_Edge_Slope;

   procedure Set_Edge_Level
     (Scope : in out Oscilloscope;
      Volts : in     Float)
   is
   begin
      Send (Scope, ":TRIGger:EDGe:LEVel " & Image (Volts));
   end Set_Edge_Level;

   function Get_Edge_Source
     (Scope : in out Oscilloscope) return Trigger_Source
   is
      R : constant String := Query (Scope, ":TRIGger:EDGe:SOURce?");
   begin
      for S in Trigger_Source loop
         if R = Source_Str (S) then
            return S;
         end if;
      end loop;
      raise Rigol_Transport.Communication_Error
        with "unexpected trigger source """ & R & """";
   end Get_Edge_Source;

   function Get_Edge_Slope
     (Scope : in out Oscilloscope) return Edge_Slope
   is
      R : constant String := Query (Scope, ":TRIGger:EDGe:SLOPe?");
   begin
      if    R = "POS"  then return Rising;
      elsif R = "NEG"  then return Falling;
      elsif R = "RFAL" then return Either;
      end if;
      raise Rigol_Transport.Communication_Error
        with "unexpected trigger slope """ & R & """";
   end Get_Edge_Slope;

   function Get_Edge_Level
     (Scope : in out Oscilloscope) return Float is
   begin
      return Float'Value (Query (Scope, ":TRIGger:EDGe:LEVel?"));
   end Get_Edge_Level;

   -- -------------------------------------------------------------------------
   --  Pulse trigger
   -- -------------------------------------------------------------------------

   function When_Str (C : Pulse_When) return String is
     (case C is
         when Pos_Greater  => "PGReater",
         when Pos_Less     => "PLESs",
         when Neg_Greater  => "NGReater",
         when Neg_Less     => "NLESs",
         when Pos_In_Range => "PGLess",
         when Neg_In_Range => "NGLess");

   function To_When (Reply : String) return Pulse_When is
   begin
      if    Reply = "PGR"  then return Pos_Greater;
      elsif Reply = "PLES" then return Pos_Less;
      elsif Reply = "NGR"  then return Neg_Greater;
      elsif Reply = "NLES" then return Neg_Less;
      elsif Reply = "PGL"  then return Pos_In_Range;
      elsif Reply = "NGL"  then return Neg_In_Range;
      end if;
      raise Rigol_Transport.Communication_Error
        with "unexpected trigger condition """ & Reply & """";
   end To_When;

   function To_Source (Reply : String) return Trigger_Source is
   begin
      for S in Trigger_Source loop
         if Reply = Source_Str (S) then
            return S;
         end if;
      end loop;
      raise Rigol_Transport.Communication_Error
        with "unexpected trigger source """ & Reply & """";
   end To_Source;

   function Get_Float (Scope : in out Oscilloscope; Query_Text : String)
     return Float is (Float'Value (Query (Scope, Query_Text)));

   --  Pulse

   procedure Set_Pulse_Source (Scope : in out Oscilloscope; Source : Trigger_Source) is
   begin
      Send (Scope, ":TRIGger:PULSe:SOURce " & Source_Str (Source));
   end Set_Pulse_Source;

   function Get_Pulse_Source (Scope : in out Oscilloscope) return Trigger_Source is
     (To_Source (Query (Scope, ":TRIGger:PULSe:SOURce?")));

   procedure Set_Pulse_When (Scope : in out Oscilloscope; Condition : Pulse_When) is
   begin
      Send (Scope, ":TRIGger:PULSe:WHEN " & When_Str (Condition));
   end Set_Pulse_When;

   function Get_Pulse_When (Scope : in out Oscilloscope) return Pulse_When is
     (To_When (Query (Scope, ":TRIGger:PULSe:WHEN?")));

   procedure Set_Pulse_Width (Scope : in out Oscilloscope; Seconds : Float) is
   begin
      Send (Scope, ":TRIGger:PULSe:WIDTh " & Image (Seconds));
   end Set_Pulse_Width;

   function Get_Pulse_Width (Scope : in out Oscilloscope) return Float is
     (Get_Float (Scope, ":TRIGger:PULSe:WIDTh?"));

   procedure Set_Pulse_Upper (Scope : in out Oscilloscope; Seconds : Float) is
   begin
      Send (Scope, ":TRIGger:PULSe:UWIDth " & Image (Seconds));
   end Set_Pulse_Upper;

   function Get_Pulse_Upper (Scope : in out Oscilloscope) return Float is
     (Get_Float (Scope, ":TRIGger:PULSe:UWIDth?"));

   procedure Set_Pulse_Lower (Scope : in out Oscilloscope; Seconds : Float) is
   begin
      Send (Scope, ":TRIGger:PULSe:LWIDth " & Image (Seconds));
   end Set_Pulse_Lower;

   function Get_Pulse_Lower (Scope : in out Oscilloscope) return Float is
     (Get_Float (Scope, ":TRIGger:PULSe:LWIDth?"));

   procedure Set_Pulse_Level (Scope : in out Oscilloscope; Volts : Float) is
   begin
      Send (Scope, ":TRIGger:PULSe:LEVel " & Image (Volts));
   end Set_Pulse_Level;

   function Get_Pulse_Level (Scope : in out Oscilloscope) return Float is
     (Get_Float (Scope, ":TRIGger:PULSe:LEVel?"));

   --  Slope

   procedure Set_Slope_Source (Scope : in out Oscilloscope; Source : Trigger_Source) is
   begin
      Send (Scope, ":TRIGger:SLOPe:SOURce " & Source_Str (Source));
   end Set_Slope_Source;

   function Get_Slope_Source (Scope : in out Oscilloscope) return Trigger_Source is
     (To_Source (Query (Scope, ":TRIGger:SLOPe:SOURce?")));

   procedure Set_Slope_When (Scope : in out Oscilloscope; Condition : Slope_When) is
   begin
      Send (Scope, ":TRIGger:SLOPe:WHEN " & When_Str (Condition));
   end Set_Slope_When;

   function Get_Slope_When (Scope : in out Oscilloscope) return Slope_When is
     (To_When (Query (Scope, ":TRIGger:SLOPe:WHEN?")));

   procedure Set_Slope_Time (Scope : in out Oscilloscope; Seconds : Float) is
   begin
      Send (Scope, ":TRIGger:SLOPe:TIME " & Image (Seconds));
   end Set_Slope_Time;

   function Get_Slope_Time (Scope : in out Oscilloscope) return Float is
     (Get_Float (Scope, ":TRIGger:SLOPe:TIME?"));

   procedure Set_Slope_Upper (Scope : in out Oscilloscope; Seconds : Float) is
   begin
      Send (Scope, ":TRIGger:SLOPe:TUPPer " & Image (Seconds));
   end Set_Slope_Upper;

   function Get_Slope_Upper (Scope : in out Oscilloscope) return Float is
     (Get_Float (Scope, ":TRIGger:SLOPe:TUPPer?"));

   procedure Set_Slope_Lower (Scope : in out Oscilloscope; Seconds : Float) is
   begin
      Send (Scope, ":TRIGger:SLOPe:TLOWer " & Image (Seconds));
   end Set_Slope_Lower;

   function Get_Slope_Lower (Scope : in out Oscilloscope) return Float is
     (Get_Float (Scope, ":TRIGger:SLOPe:TLOWer?"));

   procedure Set_Slope_Window (Scope : in out Oscilloscope; Window : Slope_Window) is
   begin
      Send (Scope, ":TRIGger:SLOPe:WINDow " &
              (case Window is when Level_A => "TA", when Level_B => "TB",
                              when Both => "TAB"));
   end Set_Slope_Window;

   function Get_Slope_Window (Scope : in out Oscilloscope) return Slope_Window is
      R : constant String := Query (Scope, ":TRIGger:SLOPe:WINDow?");
   begin
      return (if R = "TA" then Level_A elsif R = "TB" then Level_B else Both);
   end Get_Slope_Window;

   procedure Set_Slope_Level_A (Scope : in out Oscilloscope; Volts : Float) is
   begin
      Send (Scope, ":TRIGger:SLOPe:ALEVel " & Image (Volts));
   end Set_Slope_Level_A;

   function Get_Slope_Level_A (Scope : in out Oscilloscope) return Float is
     (Get_Float (Scope, ":TRIGger:SLOPe:ALEVel?"));

   procedure Set_Slope_Level_B (Scope : in out Oscilloscope; Volts : Float) is
   begin
      Send (Scope, ":TRIGger:SLOPe:BLEVel " & Image (Volts));
   end Set_Slope_Level_B;

   function Get_Slope_Level_B (Scope : in out Oscilloscope) return Float is
     (Get_Float (Scope, ":TRIGger:SLOPe:BLEVel?"));

end Rigol.Trigger;
