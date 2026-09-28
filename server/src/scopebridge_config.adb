-- ***************************************************************************
--                       ScopeBridge - Settings File
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

with Ada.Characters.Handling;         use Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;               use Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;           use Ada.Strings.Unbounded;
with Ada.Text_IO;                     use Ada.Text_IO;

package body Scopebridge_Config is

   package Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => String,
      Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   Settings : Maps.Map;          --  "section.key" -> value
   Loaded   : Boolean := False;
   Name     : Unbounded_String;  --  the file read, if any

   --  The settings there are, as "section.key"
   Known : constant array (1 .. 6) of access constant String :=
     (new String'("server.source"), new String'("server.port"),
      new String'("server.listen"), new String'("server.web"),
      new String'("client.host"),   new String'("client.port"));

   function Is_Known (Setting : String) return Boolean is
     (for some K of Known => K.all = Setting);

   procedure Load is
      F       : File_Type;
      Section : Unbounded_String;
      Number  : Natural := 0;

      procedure Warn (Text : String) is
      begin
         Put_Line (Standard_Error, To_String (Name) & ":" &
                   Trim (Number'Image, Ada.Strings.Left) & ": " & Text);
      end Warn;
   begin
      Loaded := True;
      if Ada.Environment_Variables.Exists ("SCOPEBRIDGE_RC") then
         Name := To_Unbounded_String (Ada.Environment_Variables.Value ("SCOPEBRIDGE_RC"));
      elsif Ada.Environment_Variables.Exists ("HOME") then
         Name := To_Unbounded_String (Ada.Environment_Variables.Value ("HOME") & "/.scopebridgerc");
      end if;
      if Length (Name) = 0 then
         return;
      end if;
      begin
         Open (F, In_File, To_String (Name));
      exception
         when Name_Error | Use_Error =>
            Name := Null_Unbounded_String;   --  no file: no settings
            return;
      end;
      while not End_Of_File (F) loop
         declare
            Raw     : constant String := Get_Line (F);
            Hash    : constant Natural := Index (Raw, "#");
            Line    : constant String :=
              Trim ((if Hash = 0 then Raw else Raw (Raw'First .. Hash - 1)), Ada.Strings.Both);
            Equals  : constant Natural := Index (Line, "=");
         begin
            Number := Number + 1;
            if Line'Length = 0 then
               null;
            elsif Line (Line'First) = '[' and then Line (Line'Last) = ']' then
               Section := To_Unbounded_String
                 (To_Lower (Trim (Line (Line'First + 1 .. Line'Last - 1), Ada.Strings.Both)));
               if To_String (Section) not in "server" | "client" then
                  Warn ("unknown section [" & To_String (Section) & "], its settings are skipped");
               end if;
            elsif Equals = 0 then
               Warn ("not a setting (name = value): " & Line);
            else
               declare
                  Key     : constant String :=
                    To_Lower (Trim (Line (Line'First .. Equals - 1), Ada.Strings.Both));
                  Value   : constant String := Trim (Line (Equals + 1 .. Line'Last), Ada.Strings.Both);
                  Setting : constant String := To_String (Section) & "." & Key;
               begin
                  if Length (Section) = 0 then
                     Warn ("a setting before any [section]: " & Key);
                  elsif To_String (Section) in "server" | "client" then
                     if Is_Known (Setting) then
                        Settings.Include (Setting, Value);
                     else
                        Warn ("unknown setting " & Key & " in [" & To_String (Section) & "]");
                     end if;
                  end if;
               end;
            end if;
         end;
      end loop;
      Close (F);
   end Load;

   function Get (Section, Key : String) return String is
   begin
      if not Loaded then
         Load;
      end if;
      return (if Settings.Contains (Section & "." & Key)
              then Settings.Element (Section & "." & Key) else "");
   end Get;

   function Is_Set (Section, Key : String) return Boolean is
   begin
      if not Loaded then
         Load;
      end if;
      return Settings.Contains (Section & "." & Key);
   end Is_Set;

   function File_Name return String is
   begin
      if not Loaded then
         Load;
      end if;
      return To_String (Name);
   end File_Name;

end Scopebridge_Config;
