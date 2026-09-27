-- ***************************************************************************
--                      Rigol - Oscilloscope Package Body
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

package body Rigol is

   -- -------------------------------------------------------------------------

   function Image (Value : Float) return String is
   begin
      return Ada.Strings.Fixed.Trim (Float'Image (Value), Ada.Strings.Left);
   end Image;

   function Image (Value : Integer) return String is
   begin
      return Ada.Strings.Fixed.Trim (Integer'Image (Value), Ada.Strings.Left);
   end Image;

   -- -------------------------------------------------------------------------

   procedure Check_Connected (Scope : Oscilloscope) is
   begin
      if Scope.Transport = null then
         raise Not_Connected with "Oscilloscope is not connected";
      end if;
   end Check_Connected;

   -- -------------------------------------------------------------------------

   procedure Disconnect (Scope : in out Oscilloscope) is
   begin
      if Scope.Transport /= null then
         Scope.Transport.Close;
      end if;
   end Disconnect;

   -- -------------------------------------------------------------------------

   function Is_Connected (Scope : Oscilloscope) return Boolean is
   begin
      return Scope.Transport /= null and then Scope.Transport.Is_Open;
   end Is_Connected;

   -- -------------------------------------------------------------------------

   procedure Send
     (Scope   : in out Oscilloscope;
      Command : in     String)
   is
   begin
      Check_Connected (Scope);
      Scope.Transport.Send (Command);
   end Send;

   -- -------------------------------------------------------------------------

   function Query
     (Scope   : in out Oscilloscope;
      Command : in     String) return String
   is
   begin
      Check_Connected (Scope);
      return Scope.Transport.Query (Command);
   end Query;

   -- -------------------------------------------------------------------------

   function Block_Data (Response : String) return String is
      F : constant Integer := Response'First;
      Digits_Count : Natural;
      Length       : Natural := 0;
   begin
      if Response'Length < 2
        or else Response (F) /= '#'
        or else Response (F + 1) not in '1' .. '9'
      then
         raise Rigol_Transport.Communication_Error
           with "expected a definite-length block, got """ &
                Response (F .. Integer'Min (Response'Last, F + 15)) & """";
      end if;

      Digits_Count := Character'Pos (Response (F + 1)) - Character'Pos ('0');
      if Response'Length < 2 + Digits_Count then
         raise Rigol_Transport.Communication_Error with "truncated block header";
      end if;
      for C of Response (F + 2 .. F + 1 + Digits_Count) loop
         if C not in '0' .. '9' then
            raise Rigol_Transport.Communication_Error
              with "malformed block length";
         end if;
         Length := Length * 10 + (Character'Pos (C) - Character'Pos ('0'));
      end loop;

      declare
         Data_First : constant Integer := F + 2 + Digits_Count;
      begin
         if Data_First + Length - 1 > Response'Last then
            raise Rigol_Transport.Communication_Error
              with "block announces" & Length'Image & " bytes, got" &
                   Integer'Image (Response'Last - Data_First + 1);
         end if;
         return Response (Data_First .. Data_First + Length - 1);
      end;
   end Block_Data;

   function Query_Block
     (Scope   : in out Oscilloscope;
      Command : in     String) return String is
   begin
      return Block_Data (Query (Scope, Command));
   end Query_Block;

   -- -------------------------------------------------------------------------

   procedure Run (Scope : in out Oscilloscope) is
   begin
      Send (Scope, ":RUN");
   end Run;

   procedure Stop (Scope : in out Oscilloscope) is
   begin
      Send (Scope, ":STOP");
   end Stop;

   procedure Single (Scope : in out Oscilloscope) is
   begin
      Send (Scope, ":SINGle");
   end Single;

   procedure Auto_Scale (Scope : in out Oscilloscope) is
   begin
      Send (Scope, ":AUToscale");
   end Auto_Scale;

   procedure Clear (Scope : in out Oscilloscope) is
   begin
      Send (Scope, ":CLEar");
   end Clear;

   procedure Force_Trigger (Scope : in out Oscilloscope) is
   begin
      Send (Scope, ":TFORce");
   end Force_Trigger;

end Rigol;
