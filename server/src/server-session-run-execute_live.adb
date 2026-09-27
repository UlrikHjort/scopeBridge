-- ***************************************************************************
--                 ScopeBridge Server - Live Mode Requests
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

--  Live mode and single reads of the screen: live, measure and screen.

separate (Server.Session.Run)
procedure Execute_Live
  (Cmd     : String;
   Request : JSON_Value;
   Reply   : JSON_Value;
   Payload : in out Unbounded_String;
   Binary  : in out Boolean;
   Done    : out Boolean)
is
begin
   Done := True;
   if Cmd = "live" then
      declare
         --  Validate every member before changing anything
         On      : constant Boolean := Boolean_Field (Request, "on");
         MS      : constant Integer :=
           (if Has_Field (Request, "interval_ms")
            then Integer_Field (Request, "interval_ms") else 200);
         Measure : constant Integer :=
           (if Has_Field (Request, "measure_ch")
            then Integer_Field (Request, "measure_ch") else -1);
         Items   : constant Item_List :=
           (if Has_Field (Request, "measure_items")
            then Items_Field (Request, "measure_items", Max_Live_Items)
            else Default_Items);
         Scope_M : constant Boolean :=
           Has_Field (Request, "scope_math")
             and then Boolean_Field (Request, "scope_math");
         Op      : constant Math_Op :=
           (if Has_Field (Request, "math")
               and then Kind (Get (Request, "math")) /= JSON_Null_Type
            then Math_Field (Request, "math") else None);
         Spec    : constant JSON_Value :=
           (if Has_Field (Request, "spectrum") then Get (Request, "spectrum")
            else JSON_Null);
         Spec_Ch : constant Natural :=
           (if Kind (Spec) = JSON_Object_Type
            then Natural (Channel_Field (Spec)) else 0);
         Spec_W  : constant Window_Kind :=
           (if Kind (Spec) = JSON_Object_Type and then Has_Field (Spec, "window")
            then Window_Field (Spec) else Hann);
      begin
         if Kind (Spec) not in JSON_Null_Type | JSON_Object_Type then
            raise Request_Error
              with """spectrum"" must be an object like {""ch"": 1}, or null";
         end if;
         if MS < 50 then
            raise Request_Error with """interval_ms"" must be >= 50";
         end if;
         if Measure not in -1 .. 2
           or else (Measure = -1 and then Has_Field (Request, "measure_ch"))
         then
            raise Request_Error with """measure_ch"" must be 0, 1 or 2";
         end if;
         Live_Measure    := Measure;
         Live_Items (1 .. Items'Length) := Items;
         Live_Item_Count := Items'Length;
         Live_Scope_Math := Scope_M;
         Live_Math       := Op;
         Live_Spectrum   := Spec_Ch;
         Live_Window     := Spec_W;
         --  Options are shared by all clients; the subscription is
         --  this client's
         Clients (Current).Live := On;
         Interval  := Duration (MS) / 1000.0;
         Next_Tick := Clock;
      end;

   elsif Cmd = "measure" then
      declare
         M : constant JSON_Value :=
           Measure_Object
             (Channel_Field (Request),
              (if Has_Field (Request, "items")
               then Items_Field (Request, "items", Supported'Length * 2)
               else Default_Items));
         procedure Copy (Name : UTF8_String; Value : JSON_Value) is
         begin
            Set_Field (Reply, Name, Value);
         end Copy;
      begin
         Map_JSON_Object (M, Copy'Access);
      end;

   elsif Cmd = "screen" then
      declare
         Ch  : constant Channel := Channel_Field (Request);
         Pre : Preamble;
      begin
         Select_Screen (Ch);
         declare
            Data : constant Raw_Array := Read_Prepared_Screen (Scope, Pre);
         begin
            Set_Field (Reply, "ch", Integer (Ch));
            Add_Waveform (Reply, Pre, Data'Length);
            Payload := To_Unbounded_String (To_Bytes (Data));
            Binary  := True;
         end;
      end;

   else
      Done := False;
   end if;
end Execute_Live;
