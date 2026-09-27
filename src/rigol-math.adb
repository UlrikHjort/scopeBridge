-- ***************************************************************************
--                      Rigol - Math Commands Body
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

package body Rigol.Math is

   procedure Unexpected (What, Reply : String) is
   begin
      raise Rigol_Transport.Communication_Error
        with "unexpected " & What & " """ & Reply & """";
   end Unexpected;

   function Source_Str (Src : Channel_Source) return String is
     (case Src is when CH1 => "CHANnel1", when CH2 => "CHANnel2");

   function To_Source (Reply : String) return Source is
     (if Reply = "CHAN1" then CH1 elsif Reply = "CHAN2" then CH2 else Other);

   procedure Set_Display (Scope : in out Oscilloscope; On : Boolean) is
   begin
      Send (Scope, ":MATH:DISPlay " & (if On then "ON" else "OFF"));
   end Set_Display;

   function Get_Display (Scope : in out Oscilloscope) return Boolean is
     (Query (Scope, ":MATH:DISPlay?") = "1");

   procedure Set_Operator (Scope : in out Oscilloscope; Op : Settable_Operator)
   is
   begin
      Send (Scope, ":MATH:OPERator " &
              (case Op is
                  when Add      => "ADD",
                  when Subtract => "SUBTract",
                  when Multiply => "MULTiply",
                  when Divide   => "DIVision",
                  when FFT      => "FFT"));
   end Set_Operator;

   function Get_Operator (Scope : in out Oscilloscope) return Operator is
      R : constant String := Query (Scope, ":MATH:OPERator?");
   begin
      return (if    R = "ADD"  then Add
              elsif R = "SUBT" then Subtract
              elsif R = "MULT" then Multiply
              elsif R = "DIV"  then Divide
              elsif R = "FFT"  then FFT
              else Other);
   end Get_Operator;

   procedure Set_Source1 (Scope : in out Oscilloscope; Src : Channel_Source) is
   begin
      Send (Scope, ":MATH:SOURce1 " & Source_Str (Src));
   end Set_Source1;

   function Get_Source1 (Scope : in out Oscilloscope) return Source is
     (To_Source (Query (Scope, ":MATH:SOURce1?")));

   procedure Set_Source2 (Scope : in out Oscilloscope; Src : Channel_Source) is
   begin
      Send (Scope, ":MATH:SOURce2 " & Source_Str (Src));
   end Set_Source2;

   function Get_Source2 (Scope : in out Oscilloscope) return Source is
     (To_Source (Query (Scope, ":MATH:SOURce2?")));

   procedure Set_Scale (Scope : in out Oscilloscope; Scale : Float) is
   begin
      Send (Scope, ":MATH:SCALe " & Image (Scale));
   end Set_Scale;

   function Get_Scale (Scope : in out Oscilloscope) return Float is
     (Float'Value (Query (Scope, ":MATH:SCALe?")));

   procedure Set_Offset (Scope : in out Oscilloscope; Offset : Float) is
   begin
      Send (Scope, ":MATH:OFFSet " & Image (Offset));
   end Set_Offset;

   function Get_Offset (Scope : in out Oscilloscope) return Float is
     (Float'Value (Query (Scope, ":MATH:OFFSet?")));

   procedure Set_FFT_Source (Scope : in out Oscilloscope; Src : Channel_Source) is
   begin
      Send (Scope, ":MATH:FFT:SOURce " & Source_Str (Src));
   end Set_FFT_Source;

   function Get_FFT_Source (Scope : in out Oscilloscope) return Source is
     (To_Source (Query (Scope, ":MATH:FFT:SOURce?")));

   procedure Set_FFT_Window (Scope : in out Oscilloscope; Window : FFT_Window)
   is
   begin
      Send (Scope, ":MATH:FFT:WINDow " &
              (case Window is
                  when Rectangle => "RECTangle",
                  when Hanning   => "HANNing",
                  when Hamming   => "HAMMing",
                  when Blackman  => "BLACkman",
                  when Flattop   => "FLATtop",
                  when Triangle  => "TRIangle"));
   end Set_FFT_Window;

   function Get_FFT_Window (Scope : in out Oscilloscope) return FFT_Window is
      R : constant String := Query (Scope, ":MATH:FFT:WINDow?");
   begin
      --  The guide documents BLAC but gives BLACK in an example
      if    R = "RECT" then return Rectangle;
      elsif R = "HANN" then return Hanning;
      elsif R = "HAMM" then return Hamming;
      elsif R in "BLAC" | "BLACK" then return Blackman;
      elsif R = "FLAT" then return Flattop;
      elsif R = "TRI"  then return Triangle;
      end if;
      Unexpected ("FFT window", R);
      return Rectangle;
   end Get_FFT_Window;

   procedure Set_FFT_Unit (Scope : in out Oscilloscope; Unit : FFT_Unit) is
   begin
      Send (Scope, ":MATH:FFT:UNIT " & (if Unit = dB then "DB" else "VRMS"));
   end Set_FFT_Unit;

   function Get_FFT_Unit (Scope : in out Oscilloscope) return FFT_Unit is
     (if Query (Scope, ":MATH:FFT:UNIT?") = "VRMS" then Vrms else dB);

   procedure Set_FFT_Mode (Scope : in out Oscilloscope; Mode : FFT_Mode) is
   begin
      Send (Scope, ":MATH:FFT:MODE " & (if Mode = Trace then "TRACe" else "MEMory"));
   end Set_FFT_Mode;

   function Get_FFT_Mode (Scope : in out Oscilloscope) return FFT_Mode is
     (if Query (Scope, ":MATH:FFT:MODE?") = "MEM" then Memory else Trace);

   procedure Set_FFT_HScale (Scope : in out Oscilloscope; Hz : Float) is
   begin
      Send (Scope, ":MATH:FFT:HSCale " & Image (Hz));
   end Set_FFT_HScale;

   function Get_FFT_HScale (Scope : in out Oscilloscope) return Float is
     (Float'Value (Query (Scope, ":MATH:FFT:HSCale?")));

   procedure Set_FFT_HCenter (Scope : in out Oscilloscope; Hz : Float) is
   begin
      Send (Scope, ":MATH:FFT:HCENter " & Image (Hz));
   end Set_FFT_HCenter;

   function Get_FFT_HCenter (Scope : in out Oscilloscope) return Float is
     (Float'Value (Query (Scope, ":MATH:FFT:HCENter?")));

end Rigol.Math;
