-- ***************************************************************************
--                      Rigol - Acquire Commands Body
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

package body Rigol.Acquire is

   -- -------------------------------------------------------------------------

   procedure Set_Type
     (Scope : in out Oscilloscope;
      Mode  : in     Acquire_Type)
   is
      Val : constant String :=
        (case Mode is
           when Normal          => "NORMal",
           when Averages        => "AVERages",
           when Peak            => "PEAK",
           when High_Resolution => "HRESolution");
   begin
      Send (Scope, ":ACQuire:TYPE " & Val);
   end Set_Type;

   function Get_Type (Scope : in out Oscilloscope) return Acquire_Type is
      R : constant String := Query (Scope, ":ACQuire:TYPE?");
   begin
      if    R = "NORM" then return Normal;
      elsif R = "AVER" then return Averages;
      elsif R = "PEAK" then return Peak;
      else                  return High_Resolution;
      end if;
   end Get_Type;

   -- -------------------------------------------------------------------------

   procedure Set_Averages
     (Scope : in out Oscilloscope;
      Count : in     Average_Count)
   is
   begin
      Send (Scope, ":ACQuire:AVERages " &
            Image (Count));
   end Set_Averages;

   function Get_Averages (Scope : in out Oscilloscope) return Positive is
   begin
      return Positive'Value (Query (Scope, ":ACQuire:AVERages?"));
   end Get_Averages;

   -- -------------------------------------------------------------------------

   procedure Set_Memory_Depth
     (Scope : in out Oscilloscope;
      Depth : in     Memory_Depth)
   is
   begin
      Send (Scope, ":ACQuire:MDEPth " &
            (if Depth = Auto_Depth then "AUTO" else Image (Depth)));
   end Set_Memory_Depth;

   function Get_Memory_Depth
     (Scope : in out Oscilloscope) return Memory_Depth
   is
      R : constant String := Query (Scope, ":ACQuire:MDEPth?");
   begin
      return (if R = "AUTO" then Auto_Depth else Memory_Depth'Value (R));
   end Get_Memory_Depth;

   -- -------------------------------------------------------------------------

   function Get_Sample_Rate (Scope : in out Oscilloscope) return Float is
   begin
      return Float'Value (Query (Scope, ":ACQuire:SRATe?"));
   end Get_Sample_Rate;

end Rigol.Acquire;
