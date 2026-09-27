-- ***************************************************************************
--                      Rigol - Mock Transport Body
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

package body Rigol_Transport.Mock is

   -- -------------------------------------------------------------------------
   --  Internal helpers
   -- -------------------------------------------------------------------------

   --  Store S into E, truncating anything past Max_Text.
   procedure Assign (E : out Text_Entry; S : String) is
      N : constant Natural := Natural'Min (S'Length, Max_Text);
   begin
      E.Text := (others => ' ');
      E.Text (1 .. N) := S (S'First .. S'First + N - 1);
      E.Len := N;
   end Assign;

   function Value (E : Text_Entry) return String is
   begin
      return E.Text (1 .. E.Len);
   end Value;

   --  Append S to the command log, dropping it if the log is full.
   procedure Record_Command (T : in out Handle; S : String) is
   begin
      if T.Log_Count < Max_Entries then
         T.Log_Count := T.Log_Count + 1;
         Assign (T.Log (T.Log_Count), S);
      end if;
   end Record_Command;

   -- -------------------------------------------------------------------------
   --  Priming
   -- -------------------------------------------------------------------------

   procedure Push_Response
     (T        : in out Handle;
      Response : in     String)
   is
   begin
      if T.Resp_Count < Max_Entries then
         T.Resp_Count := T.Resp_Count + 1;
         T.Responses (T.Resp_Count) := To_Unbounded_String (Response);
      end if;
   end Push_Response;

   procedure Set_Default_Response
     (T        : in out Handle;
      Response : in     String)
   is
   begin
      Assign (T.Default, Response);
   end Set_Default_Response;

   procedure Reset (T : in out Handle) is
   begin
      T.Log_Count  := 0;
      T.Resp_Count := 0;
      T.Resp_Next  := 1;
   end Reset;

   -- -------------------------------------------------------------------------
   --  Inspection
   -- -------------------------------------------------------------------------

   function Command_Count (T : Handle) return Natural is
   begin
      return T.Log_Count;
   end Command_Count;

   function Command (T : Handle; N : Positive) return String is
   begin
      if N > T.Log_Count then
         return "";
      end if;
      return Value (T.Log (N));
   end Command;

   function Last_Command (T : Handle) return String is
   begin
      if T.Log_Count = 0 then
         return "";
      end if;
      return Value (T.Log (T.Log_Count));
   end Last_Command;

   -- -------------------------------------------------------------------------
   --  Rigol_Transport interface
   -- -------------------------------------------------------------------------

   overriding procedure Send
     (T       : in out Handle;
      Command : in     String)
   is
   begin
      Record_Command (T, Command);
   end Send;

   overriding function Query
     (T       : in out Handle;
      Command : in     String) return String
   is
   begin
      Record_Command (T, Command);

      if T.Resp_Next <= T.Resp_Count then
         declare
            Index : constant Positive := T.Resp_Next;
         begin
            T.Resp_Next := T.Resp_Next + 1;
            return To_String (T.Responses (Index));
         end;
      end if;

      return Value (T.Default);
   end Query;

   overriding procedure Close (T : in out Handle) is
   begin
      T.Opened := False;
   end Close;

   overriding function Is_Open (T : Handle) return Boolean is
   begin
      return T.Opened;
   end Is_Open;

end Rigol_Transport.Mock;
