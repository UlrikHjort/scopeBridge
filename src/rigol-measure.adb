-- ***************************************************************************
--                      Rigol - Measure Commands Body
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

package body Rigol.Measure is

   function Item_Str (Item : Measure_Item) return String is
   begin
      case Item is
         when VMAX           => return "VMAX";
         when VMIN           => return "VMIN";
         when VPP            => return "VPP";
         when VTOP           => return "VTOP";
         when VBASE          => return "VBAS";
         when VAMP           => return "VAMP";
         when VAVG           => return "VAVG";
         when VRMS           => return "VRMS";
         when VUPPER         => return "VUPP";
         when VMID           => return "VMID";
         when VLOWER         => return "VLOW";
         when VARIANCE       => return "VARI";
         when PVRMS          => return "PVRMS";
         when OVER           => return "OVER";
         when PRES           => return "PRES";
         when Period         => return "PER";
         when Frequency      => return "FREQ";
         when Rise_Time      => return "RTIM";
         when Fall_Time      => return "FTIM";
         when Pos_Width      => return "PWID";
         when Neg_Width      => return "NWID";
         when Pos_Duty       => return "PDUT";
         when Neg_Duty       => return "NDUT";
         when Rise_Delay     => return "RDEL";
         when Fall_Delay     => return "FDEL";
         when Rise_Phase     => return "RPH";
         when Fall_Phase     => return "FPH";
         when Pos_Slew_Rate  => return "PSLE";
         when Neg_Slew_Rate  => return "NSLE";
         when T_VMAX         => return "TVMAX";
         when T_VMIN         => return "TVMIN";
      end case;
   end Item_Str;

   function Ch_Str (Ch : Measure_Source) return String is
   begin
      return "CHAN" & Ada.Strings.Fixed.Trim
        (Measure_Source'Image (Ch), Ada.Strings.Left);
   end Ch_Str;

   --  The scope answers 9.9E37 when a measurement cannot be made
   Invalid_Reading : constant Float := 9.9E37;

   -- -------------------------------------------------------------------------

   function Get
     (Scope   : in out Oscilloscope;
      Item    : in     Measure_Item;
      Channel : in     Measure_Source) return Float
   is
      Reply : constant String := Query (Scope,
        ":MEASure:ITEM? " & Item_Str (Item) & "," & Ch_Str (Channel));
   begin
      --  Parsed here, not in the declarations, so that this handler sees
      --  replies that are not numbers ("measure error!")
      declare
         Value : constant Float := Float'Value (Reply);
      begin
         return (if Value >= Invalid_Reading then Float'Last else Value);
      end;
   exception
      when Constraint_Error => return Float'Last;
   end Get;

   procedure Show
     (Scope   : in out Oscilloscope;
      Item    : in     Measure_Item;
      Channel : in     Measure_Source) is
   begin
      Send (Scope, ":MEASure:ITEM " & Item_Str (Item) & "," & Ch_Str (Channel));
   end Show;

   -- -------------------------------------------------------------------------

   function Frequency (Scope : in out Oscilloscope; Ch : Measure_Source) return Float is
   begin
      return Get (Scope, Rigol.Measure.Frequency, Ch);
   end Frequency;

   function Period (Scope : in out Oscilloscope; Ch : Measure_Source) return Float is
   begin
      return Get (Scope, Rigol.Measure.Period, Ch);
   end Period;

   function VPP (Scope : in out Oscilloscope; Ch : Measure_Source) return Float is
   begin
      return Get (Scope, Rigol.Measure.VPP, Ch);
   end VPP;

   function VRMS (Scope : in out Oscilloscope; Ch : Measure_Source) return Float is
   begin
      return Get (Scope, Rigol.Measure.VRMS, Ch);
   end VRMS;

   function VMAX (Scope : in out Oscilloscope; Ch : Measure_Source) return Float is
   begin
      return Get (Scope, Rigol.Measure.VMAX, Ch);
   end VMAX;

   function VMIN (Scope : in out Oscilloscope; Ch : Measure_Source) return Float is
   begin
      return Get (Scope, Rigol.Measure.VMIN, Ch);
   end VMIN;

   function Rise_Time (Scope : in out Oscilloscope; Ch : Measure_Source) return Float is
   begin
      return Get (Scope, Rigol.Measure.Rise_Time, Ch);
   end Rise_Time;

   function Fall_Time (Scope : in out Oscilloscope; Ch : Measure_Source) return Float is
   begin
      return Get (Scope, Rigol.Measure.Fall_Time, Ch);
   end Fall_Time;

   -- -------------------------------------------------------------------------

   procedure Clear_All (Scope : in out Oscilloscope) is
   begin
      Send (Scope, ":MEASure:CLEar");
   end Clear_All;

   procedure Set_Source
     (Scope   : in out Oscilloscope;
      Channel : in     Measure_Source)
   is
   begin
      Send (Scope, ":MEASure:SOURce " & Ch_Str (Channel));
   end Set_Source;

end Rigol.Measure;
