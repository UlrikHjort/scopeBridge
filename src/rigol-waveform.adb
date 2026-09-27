-- ***************************************************************************
--                      Rigol - Waveform Commands Body
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
with Ada.Unchecked_Deallocation;

with Rigol_Transport;

package body Rigol.Waveform is

   -- -------------------------------------------------------------------------
   --  Internal helpers
   -- -------------------------------------------------------------------------

   function Ch_Str (Ch : Rigol.Channel.Channel_Number) return String is
   begin
      return "CHAN" & Ada.Strings.Fixed.Trim
        (Rigol.Channel.Channel_Number'Image (Ch), Ada.Strings.Left);
   end Ch_Str;

   --  Advance Pos past any leading spaces in S
   procedure Skip_Spaces (S : String; Pos : in out Natural) is
   begin
      while Pos <= S'Last and then S (Pos) = ' ' loop
         Pos := Pos + 1;
      end loop;
   end Skip_Spaces;

   --  Read a comma-delimited token from S starting at Pos; advance Pos.
   procedure Next_Token
     (S     :     String;
      Pos   : in out Natural;
      Token : out String;
      Last  : out Natural)
   is
      Start : Natural := Pos;
   begin
      Skip_Spaces (S, Start);
      Pos := Start;
      while Pos <= S'Last and then S (Pos) /= ',' loop
         Pos := Pos + 1;
      end loop;
      Last := Pos - 1;
      Token (Token'First .. Token'First + (Last - Start)) :=
        S (Start .. Last);
      Last := Token'First + (Last - Start);
      if Pos <= S'Last then
         Pos := Pos + 1;  --  skip comma
      end if;
   end Next_Token;

   -- -------------------------------------------------------------------------
   --  Set commands
   -- -------------------------------------------------------------------------

   procedure Set_Source
     (Scope   : in out Oscilloscope;
      Channel : in     Rigol.Channel.Channel_Number)
   is
   begin
      Send (Scope, ":WAVeform:SOURce " & Ch_Str (Channel));
   end Set_Source;

   procedure Set_Mode
     (Scope : in out Oscilloscope;
      Mode  : in     Waveform_Mode)
   is
      Val : constant String :=
        (case Mode is
           when Normal  => "NORMal",
           when Maximum => "MAXimum",
           when Raw     => "RAW");
   begin
      Send (Scope, ":WAVeform:MODE " & Val);
   end Set_Mode;

   procedure Set_Format
     (Scope  : in out Oscilloscope;
      Format : in     Waveform_Format)
   is
      Val : constant String :=
        (case Format is
           when Byte      => "BYTE",
           when Word      => "WORD",
           when ASCII_Fmt => "ASCii");
   begin
      Send (Scope, ":WAVeform:FORMat " & Val);
   end Set_Format;

   procedure Set_Start
     (Scope : in out Oscilloscope;
      Point : in     Positive)
   is
   begin
      Send (Scope, ":WAVeform:STARt " &
            Ada.Strings.Fixed.Trim (Positive'Image (Point), Ada.Strings.Left));
   end Set_Start;

   procedure Set_Stop
     (Scope : in out Oscilloscope;
      Point : in     Positive)
   is
   begin
      Send (Scope, ":WAVeform:STOP " &
            Ada.Strings.Fixed.Trim (Positive'Image (Point), Ada.Strings.Left));
   end Set_Stop;

   -- -------------------------------------------------------------------------
   --  Preamble parsing
   --  Response: <fmt>,<type>,<pts>,<cnt>,<xi>,<xo>,<xr>,<yi>,<yo>,<yr>
   -- -------------------------------------------------------------------------

   function Get_Preamble (Scope : in out Oscilloscope) return Preamble is
      Resp : constant String := Query (Scope, ":WAVeform:PREamble?");
      Pre  : Preamble;
      Buf  : String (1 .. 64);
      Last : Natural;
      Pos  : Natural := Resp'First;
   begin
      Next_Token (Resp, Pos, Buf, Last);
      declare
         Fmt_Code : constant Integer := Integer'Value (Buf (Buf'First .. Last));
      begin
         Pre.Format := (case Fmt_Code is
                          when 0 => Byte,
                          when 1 => Word,
                          when others => ASCII_Fmt);
      end;

      Next_Token (Resp, Pos, Buf, Last);
      declare
         Mode_Code : constant Integer := Integer'Value (Buf (Buf'First .. Last));
      begin
         Pre.Mode := (case Mode_Code is
                        when 0 => Normal,
                        when 1 => Maximum,
                        when others => Waveform_Mode'(Raw));
      end;

      Next_Token (Resp, Pos, Buf, Last);
      Pre.Points := Natural'Value (Buf (Buf'First .. Last));

      Next_Token (Resp, Pos, Buf, Last);
      Pre.Count := Natural'Value (Buf (Buf'First .. Last));

      Next_Token (Resp, Pos, Buf, Last);
      Pre.X_Increment := Float'Value (Buf (Buf'First .. Last));

      Next_Token (Resp, Pos, Buf, Last);
      Pre.X_Origin := Float'Value (Buf (Buf'First .. Last));

      Next_Token (Resp, Pos, Buf, Last);
      Pre.X_Reference := Float'Value (Buf (Buf'First .. Last));

      Next_Token (Resp, Pos, Buf, Last);
      Pre.Y_Increment := Float'Value (Buf (Buf'First .. Last));

      Next_Token (Resp, Pos, Buf, Last);
      Pre.Y_Origin := Float'Value (Buf (Buf'First .. Last));

      Next_Token (Resp, Pos, Buf, Last);
      Pre.Y_Reference := Float'Value (Buf (Buf'First .. Last));

      return Pre;
   end Get_Preamble;

   -- -------------------------------------------------------------------------
   --  Waveform data acquisition
   --  Binary response format:  #N<N-digit-count><data bytes>
   -- -------------------------------------------------------------------------

   --  Bytes per sample in a :WAVeform:DATA? block.  WORD carries the 8-bit
   --  sample in its low byte, least significant byte first; the high byte
   --  is always 0.
   function Sample_Size (Format : Waveform_Format) return Positive is
     (if Format = Word then 2 else 1);

   --  Convert the samples in Block (the payload of a :WAVeform:DATA?
   --  response) to volts, into Into (From ..).  Returns the number of
   --  samples decoded.
   function Decode
     (Block : String;
      Pre   : Preamble;
      Into  : in out Sample_Array;
      From  : Positive) return Natural
   is
      Step  : constant Positive := Sample_Size (Pre.Format);
      Count : constant Natural  :=
        Natural'Min (Block'Length / Step, Into'Last - From + 1);
   begin
      for I in 0 .. Count - 1 loop
         Into (From + I) := Volts
           (Pre, Raw_Sample (Character'Pos (Block (Block'First + I * Step))));
      end loop;
      return Count;
   end Decode;

   function Get_Data
     (Scope : in out Oscilloscope;
      Pre   : in     Preamble) return Sample_Array
   is
      Block  : constant String := Query_Block (Scope, ":WAVeform:DATA?");
      Result : Sample_Array (1 .. Pre.Points);
      Count  : constant Natural := Decode (Block, Pre, Result, 1);
   begin
      --  The scope sends what it has; never return undecoded elements.
      return Result (1 .. Count);
   end Get_Data;

   -- -------------------------------------------------------------------------

   procedure Free_Samples is new Ada.Unchecked_Deallocation
     (Sample_Array, Sample_Array_Access);

   procedure Free (Data : in out Sample_Array_Access) is
   begin
      Free_Samples (Data);
   end Free;

   procedure Free_Raw is new Ada.Unchecked_Deallocation
     (Raw_Array, Raw_Array_Access);

   procedure Free (Data : in out Raw_Array_Access) is
   begin
      Free_Raw (Data);
   end Free;

   --  Copy the samples in Block into Into (From ..); returns the count
   function Decode_Raw
     (Block : String;
      Pre   : Preamble;
      Into  : in out Raw_Array;
      From  : Positive) return Natural
   is
      Step  : constant Positive := Sample_Size (Pre.Format);
      Count : constant Natural  :=
        Natural'Min (Block'Length / Step, Into'Last - From + 1);
   begin
      for I in 0 .. Count - 1 loop
         Into (From + I) :=
           Raw_Sample (Character'Pos (Block (Block'First + I * Step)));
      end loop;
      return Count;
   end Decode_Raw;

   procedure Read_Memory_Raw
     (Scope    : in out Oscilloscope;
      Channel  : in     Rigol.Channel.Channel_Number;
      Pre      :    out Preamble;
      Data     :    out Raw_Array_Access;
      Progress : access procedure (Done, Total : Natural) := null)
   is
      First : Positive := 1;
      Last  : Positive;
   begin
      --  Internal memory can only be read with acquisition stopped
      Stop (Scope);
      Set_Source (Scope, Channel);
      Set_Mode   (Scope, Raw);
      Set_Format (Scope, Byte);
      Pre  := Get_Preamble (Scope);  --  Points = memory depth in RAW mode
      Data := new Raw_Array (1 .. Pre.Points);

      while First <= Pre.Points loop
         Last := Natural'Min (First + Max_Raw_Batch - 1, Pre.Points);
         Set_Start (Scope, First);
         Set_Stop  (Scope, Last);
         declare
            Block : constant String := Query_Block (Scope, ":WAVeform:DATA?");
         begin
            if Decode_Raw (Block, Pre, Data.all, First) /= Last - First + 1
            then
               raise Rigol_Transport.Communication_Error
                 with "memory batch" & First'Image & " .." & Last'Image &
                      " returned" & Block'Length'Image & " samples";
            end if;
         end;
         if Progress /= null then
            Progress (Last, Pre.Points);
         end if;
         First := Last + 1;
      end loop;
   exception
      when others =>
         Free (Data);
         raise;
   end Read_Memory_Raw;

   procedure Read_Memory
     (Scope    : in out Oscilloscope;
      Channel  : in     Rigol.Channel.Channel_Number;
      Pre      :    out Preamble;
      Data     :    out Sample_Array_Access;
      Progress : access procedure (Done, Total : Natural) := null)
   is
      Raw_Data : Raw_Array_Access;
   begin
      Read_Memory_Raw (Scope, Channel, Pre, Raw_Data, Progress);
      Data := new Sample_Array (Raw_Data'Range);
      for I in Raw_Data'Range loop
         Data (I) := Volts (Pre, Raw_Data (I));
      end loop;
      Free (Raw_Data);
   exception
      when others =>
         Free (Raw_Data);
         raise;
   end Read_Memory;

   procedure Prepare_Screen_Read
     (Scope   : in out Oscilloscope;
      Channel : in     Rigol.Channel.Channel_Number) is
   begin
      Set_Source (Scope, Channel);
      Set_Mode   (Scope, Normal);
      Set_Format (Scope, Byte);
      Set_Start  (Scope, 1);
      Set_Stop   (Scope, Screen_Points);
   end Prepare_Screen_Read;

   procedure Set_Source_Math (Scope : in out Oscilloscope) is
   begin
      Send (Scope, ":WAVeform:SOURce MATH");
   end Set_Source_Math;

   procedure Prepare_Math_Read (Scope : in out Oscilloscope) is
   begin
      Set_Source_Math (Scope);
      Set_Mode   (Scope, Normal);
      Set_Format (Scope, Byte);
      Set_Start  (Scope, 1);
      Set_Stop   (Scope, Screen_Points);
   end Prepare_Math_Read;

   function Read_Prepared_Screen
     (Scope : in out Oscilloscope;
      Pre   :    out Preamble) return Raw_Array is
   begin
      Pre := Get_Preamble (Scope);
      declare
         Block  : constant String := Query_Block (Scope, ":WAVeform:DATA?");
         Result : Raw_Array (1 .. Pre.Points);
         Count  : constant Natural := Decode_Raw (Block, Pre, Result, 1);
      begin
         return Result (1 .. Count);
      end;
   end Read_Prepared_Screen;

   function Read_Screen_Raw
     (Scope   : in out Oscilloscope;
      Channel : in     Rigol.Channel.Channel_Number;
      Pre     :    out Preamble) return Raw_Array is
   begin
      Prepare_Screen_Read (Scope, Channel);
      return Read_Prepared_Screen (Scope, Pre);
   end Read_Screen_Raw;

   -- -------------------------------------------------------------------------

   function Capture
     (Scope   : in out Oscilloscope;
      Channel : in     Rigol.Channel.Channel_Number;
      Mode    : in     Waveform_Mode := Normal) return Sample_Array
   is
      Pre : Preamble;
   begin
      Set_Source (Scope, Channel);
      Set_Mode   (Scope, Mode);
      Set_Format (Scope, Byte);
      if Mode = Normal then
         --  A memory read leaves STARt/STOP outside the screen range
         Set_Start (Scope, 1);
         Set_Stop  (Scope, Screen_Points);
      end if;
      Pre := Get_Preamble (Scope);
      return Get_Data (Scope, Pre);
   end Capture;

   -- -------------------------------------------------------------------------

   function Sample_Time (Pre : Preamble; I : Positive) return Float is
   begin
      return Pre.X_Origin +
             (Float (I) - Pre.X_Reference) * Pre.X_Increment;
   end Sample_Time;

end Rigol.Waveform;
