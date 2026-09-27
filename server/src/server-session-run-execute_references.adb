-- ***************************************************************************
--             ScopeBridge Server - Reference Waveform Requests
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

--  Reference waveforms, kept by the server for all clients: ref_save,
--  ref_load, refs, ref and ref_clear.

separate (Server.Session.Run)
procedure Execute_References
  (Cmd     : String;
   Request : JSON_Value;
   Reply   : JSON_Value;
   Payload : in out Unbounded_String;
   Binary  : in out Boolean;
   Done    : out Boolean)
is
   function Slot_Field (Request : JSON_Value) return Ref_Slot is
      N : constant Integer := Integer_Field (Request, "slot");
   begin
      if N not in Ref_Slot then
         raise Request_Error with """slot"" must be 1 .." & Max_Refs'Image;
      end if;
      return N;
   end Slot_Field;

   --  The members describing reference Slot (without its samples)
   procedure Add_Reference (Message : JSON_Value; Slot : Ref_Slot) is
      R : Reference renames Refs (Slot);
   begin
      Set_Field (Message, "slot", Slot);
      Set_Field (Message, "ch", R.Ch);
      Set_Field (Message, "label", To_String (R.Label));
      Add_Waveform (Message, R.Pre, Length (R.Data));
   end Add_Reference;

   function Time_Image return String is
      Now : constant Time := Clock;
      function Two (N : Natural) return String is
        ((1 => Character'Val (48 + N / 10), 2 => Character'Val (48 + N mod 10)));
      S : constant Natural :=
        Natural'Min (86_399, Natural (Float'Floor (Float (Seconds (Now)))));
   begin
      return Two (S / 3600) & ":" & Two (S / 60 mod 60) & ":" & Two (S mod 60);
   end Time_Image;
begin
   Done := True;
   if Cmd = "ref_save" then
      declare
         Slot : constant Ref_Slot := Slot_Field (Request);
         Ch   : constant Channel := Channel_Field (Request);
         Pre  : Preamble;
      begin
         Select_Screen (Ch);
         declare
            Data : constant Raw_Array := Read_Prepared_Screen (Scope, Pre);
         begin
            if Data'Length = 0 then
               raise Request_Error with "the scope has no screen data yet; try again";
            end if;
            Refs (Slot) :=
              (Used  => True,
               Pre   => Pre,
               Data  => To_Unbounded_String (To_Bytes (Data)),
               Ch    => Natural (Ch),
               Label => To_Unbounded_String
                 ((if Has_Field (Request, "label") then String_Field (Request, "label")
                   else "CH" & Character'Val (48 + Integer (Ch)) & " " & Time_Image)));
         end;
         Add_Reference (Reply, Slot);
         Notify_All (Object ("event", "refs"));
      end;

   elsif Cmd = "ref_load" then
      declare
         Slot : constant Ref_Slot := Slot_Field (Request);
         Data : constant String := From_Base64 (String_Field (Request, "data"));
         Ch   : constant Integer :=
           (if Has_Field (Request, "ch") then Integer_Field (Request, "ch") else 0);
         Pre  : Preamble :=
           (Format => Byte, Mode => Normal, Points => Data'Length, Count => 1,
            X_Increment => Number_Field (Request, "x_inc"),
            X_Origin    => Number_Field (Request, "x_origin"),
            X_Reference => 0.0,
            Y_Increment => Number_Field (Request, "y_inc"),
            Y_Origin    => Number_Field (Request, "y_origin"),
            Y_Reference => Number_Field (Request, "y_ref"));
      begin
         if Data'Length < 2 or else Data'Length > Max_Ref_Points then
            raise Request_Error with "a reference has 2 .." & Max_Ref_Points'Image
              & " samples";
         elsif Pre.X_Increment <= 0.0 or else Pre.Y_Increment <= 0.0 then
            raise Request_Error with """x_inc"" and ""y_inc"" must be positive";
         elsif Ch not in 0 .. 2 then
            raise Request_Error with """ch"" must be 0, 1 or 2";
         end if;
         Pre.Points := Data'Length;
         Refs (Slot) :=
           (Used  => True,
            Pre   => Pre,
            Data  => To_Unbounded_String (Data),
            Ch    => Ch,
            Label => To_Unbounded_String
              ((if Has_Field (Request, "label") then String_Field (Request, "label")
                else "loaded " & Time_Image)));
         Add_Reference (Reply, Slot);
         Notify_All (Object ("event", "refs"));
      end;

   elsif Cmd = "refs" then
      declare
         List : JSON_Array := Empty_Array;
      begin
         for Slot in Ref_Slot loop
            if Refs (Slot).Used then
               declare
                  O : constant JSON_Value := Create_Object;
               begin
                  Add_Reference (O, Slot);
                  Append (List, O);
               end;
            end if;
         end loop;
         Set_Field (Reply, "refs", Create (List));
      end;

   elsif Cmd = "ref" then
      declare
         Slot : constant Ref_Slot := Slot_Field (Request);
      begin
         if not Refs (Slot).Used then
            raise Request_Error with "reference" & Slot'Image & " is empty";
         end if;
         Add_Reference (Reply, Slot);
         Payload := Refs (Slot).Data;
         Binary  := True;
      end;

   elsif Cmd = "ref_clear" then
      if Has_Field (Request, "slot") then
         Refs (Slot_Field (Request)) := (others => <>);
      else
         Refs := (others => (others => <>));
      end if;
      Notify_All (Object ("event", "refs"));

   else
      Done := False;
   end if;
end Execute_References;
