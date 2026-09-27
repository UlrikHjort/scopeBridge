-- ***************************************************************************
--                      Rigol - USB-TMC Transport Body
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

with Ada.Calendar;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Interfaces.C.Strings;
with System;

package body Rigol_Transport.USBTMC is

   --  POSIX O_RDWR flag (Linux/x86-64)
   O_RDWR : constant int := 2;

   --  POSIX bindings
   function C_Open
     (Path  : Strings.chars_ptr;
      Flags : int) return int;
   pragma Import (C, C_Open, "open");



   function C_Close (FD : int) return int;
   pragma Import (C, C_Close, "close");

   --  ioctl is variadic in C.  Binding it as a fixed three-argument
   --  function is sound on Linux on x86-64, ARM and AArch64 (Raspberry
   --  Pi): an integer or pointer third argument travels in the same
   --  register either way, and no floating-point arguments are passed.
   function C_Ioctl
     (FD      : int;
      Request : unsigned_long;
      Arg     : System.Address) return int;
   pragma Import (C, C_Ioctl, "ioctl");

   --  <linux/usb/tmc.h>
   --  USBTMC_IOCTL_WRITE = _IOWR ('[', 13, struct usbtmc_message)
   --  USBTMC_IOCTL_READ  = _IOWR ('[', 14, struct usbtmc_message)
   --
   --  USBTMC_IOCTL_CLEAR is deliberately not used: sent as the first
   --  request after the DS1202Z-E has booted, it leaves the instrument's
   --  USB interface unresponsive until the next power cycle.
   --  USBTMC_IOCTL_SET_TIMEOUT = _IOW ('[', 10, __u32), in milliseconds
   --
   --  struct usbtmc_message is packed: three 32-bit counts and a pointer,
   --  20 bytes on a 64-bit system and 16 on a 32-bit one (such as 32-bit
   --  Raspberry Pi OS).  The ioctl numbers encode that size, so both are
   --  derived from the size of an address here.
   Pointer_Bits  : constant := Standard'Address_Size;   --  static, unlike Address'Size
   Message_Bytes : constant := 12 + Pointer_Bits / 8;

   --  _IOW and _IOWR: the direction in bits 30 .. 31, the size of the
   --  argument in bits 16 .. 29, then the type ('[') and the number
   function IOC (Direction, Size, Number : unsigned_long) return unsigned_long is
     (Direction * 2**30 + Size * 2**16 + 16#5B# * 2**8 + Number);

   IOC_Write      : constant := 1;
   IOC_Read_Write : constant := 3;

   USBTMC_IOCTL_SET_TIMEOUT : constant unsigned_long := IOC (IOC_Write, 4, 10);
   USBTMC_IOCTL_WRITE : constant unsigned_long :=
     IOC (IOC_Read_Write, Message_Bytes, 13);
   USBTMC_IOCTL_READ  : constant unsigned_long :=
     IOC (IOC_Read_Write, Message_Bytes, 14);

   type Usbtmc_Message is record
      Transfer_Size : unsigned;
      Transferred   : unsigned;
      Flags         : unsigned;
      Message       : System.Address;
   end record;
   for Usbtmc_Message use record
      Transfer_Size at  0 range 0 .. 31;
      Transferred   at  4 range 0 .. 31;
      Flags         at  8 range 0 .. 31;
      Message       at 12 range 0 .. Pointer_Bits - 1;
   end record;
   for Usbtmc_Message'Size use 8 * Message_Bytes;

   --  USBTMC Bulk-IN framing (USBTMC spec, section 3.2)
   Header_Size            : constant := 12;
   DEV_DEP_MSG_OUT        : constant := 1;  --  MsgID
   REQUEST_DEV_DEP_MSG_IN : constant := 2;  --  MsgID, also echoed on IN

   --  Largest transfer to request.  The DS1000Z-E assembles each transfer
   --  in a 512-byte buffer: in a longer one, the bytes past 512 are also
   --  written over the start of the transfer, silently corrupting screen
   --  data, memory reads and screenshots alike.  12 + 500 = 512, which is
   --  also the size the scope picks itself when it is free to.
   Max_Transfer           : constant := 500;

   --  SCPI message terminator
   Terminator : constant String := "" & ASCII.LF;

   -- -------------------------------------------------------------------------

   procedure Open
     (T           : out Handle;
      Device_Path : in  String := "/dev/usbtmc0")
   is
      C_Path : Strings.chars_ptr := Strings.New_String (Device_Path);
   begin
      T.FD := C_Open (C_Path, O_RDWR);
      Strings.Free (C_Path);
      if T.FD = Invalid_FD then
         raise Device_Error
           with "Cannot open USB-TMC device: " & Device_Path;
      end if;

      --  Start the bTag sequence somewhere arbitrary: the scope ignores a
      --  message whose tag repeats the previous one, which may have come
      --  from the program that used the device before us
      T.BTag := unsigned_char
        (Integer (Ada.Calendar.Seconds (Ada.Calendar.Clock) * 1000.0) mod 255);
   end Open;

   -- -------------------------------------------------------------------------


   -- -------------------------------------------------------------------------

   procedure Set_Timeout
     (T       : in out Handle;
      Timeout : in     Duration)
   is
      MS : aliased unsigned := unsigned (Timeout * 1000);
   begin
      if C_Ioctl (T.FD, USBTMC_IOCTL_SET_TIMEOUT, MS'Address) < 0 then
         raise Communication_Error with "USB-TMC timeout not accepted";
      end if;
   end Set_Timeout;

   -- -------------------------------------------------------------------------
   --  Raw USBTMC response reading
   -- -------------------------------------------------------------------------

   procedure Raw_Write (T : in out Handle; Data : in String) is
      Msg : aliased Usbtmc_Message :=
        (Transfer_Size => unsigned (Data'Length),
         Transferred   => 0,
         Flags         => 0,
         Message       => Data'Address);
   begin
      if C_Ioctl (T.FD, USBTMC_IOCTL_WRITE, Msg'Address) < 0
        or else Msg.Transferred /= unsigned (Data'Length)
      then
         raise Communication_Error with "USB-TMC request failed";
      end if;
   end Raw_Write;

   --  Read raw bulk-IN bytes into Buf (First .. Buf'Last); return the
   --  number of bytes received.  The DS1000Z-E completes one call per
   --  64-byte packet, so callers loop.
   function Raw_Read
     (T     : in out Handle;
      Buf   : in out String;
      First : in     Positive) return Natural
   is
      Msg : aliased Usbtmc_Message :=
        (Transfer_Size => unsigned (Buf'Last - First + 1),
         Transferred   => 0,
         Flags         => 0,
         Message       => Buf (First)'Address);
   begin
      if C_Ioctl (T.FD, USBTMC_IOCTL_READ, Msg'Address) < 0 then
         raise Communication_Error with "USB-TMC read failed or timed out";
      end if;
      return Natural (Msg.Transferred);
   end Raw_Read;

   function Byte (N : Natural) return Character is
     (Character'Val (N mod 256));

   function Pos (C : Character) return Natural is (Character'Pos (C));

   --  Every Bulk-OUT message needs a bTag different from the previous
   --  one.  All of them are sent from here, with one counter; mixing in
   --  the kernel's write() would give two independent counters that both
   --  start at 1 on a fresh connection, and the scope ignores a request
   --  whose tag repeats the command's.
   function Next_Tag (T : in out Handle) return Character is
   begin
      T.BTag := (if T.BTag = 255 then 1 else T.BTag + 1);
      return Character'Val (T.BTag);
   end Next_Tag;

   function Bulk_Out_Header
     (Msg_ID : Natural;
      Tag    : Character;
      Size   : Natural;
      Attr   : Natural) return String
   is
     (Byte (Msg_ID) & Tag & Byte (255 - Pos (Tag)) & Byte (0) &
      Byte (Size) & Byte (Size / 2**8) & Byte (Size / 2**16) &
      Byte (Size / 2**24) &
      Byte (Attr) & Byte (0) & Byte (0) & Byte (0));

   -- -------------------------------------------------------------------------

   overriding procedure Send
     (T       : in out Handle;
      Command : in     String)
   is
      Msg   : constant String := Command & Terminator;
      First : Positive := Msg'First;
   begin
      --  In transfers of at most Max_Transfer bytes, like replies: a long
      --  command (a setup block is about 2 KB) would otherwise meet the
      --  scope's 512-byte transfer buffer.  Attr 1 = EOM marks the last.
      loop
         declare
            Last  : constant Natural :=
              Natural'Min (Msg'Last, First + Max_Transfer - 1);
            Chunk : String renames Msg (First .. Last);
            Pad   : constant Natural := (4 - Chunk'Length mod 4) mod 4;
         begin
            Raw_Write (T,
              Bulk_Out_Header (DEV_DEP_MSG_OUT, Next_Tag (T), Chunk'Length,
                               (if Last = Msg'Last then 1 else 0)) &
              Chunk & (1 .. Pad => ASCII.NUL));
            exit when Last = Msg'Last;
            First := Last + 1;
         end;
      end loop;
   end Send;

   -- -------------------------------------------------------------------------

   --  Request one device-dependent message transfer, read it whole and
   --  append its payload to Result.  EOM reports whether the instrument
   --  marked it as the last transfer of the response.
   procedure Read_Transfer
     (T      : in out Handle;
      Result : in out Unbounded_String;
      EOM    :    out Boolean)
   is
      Tag  : Character;
      Size : constant Natural := Max_Transfer;
      Buf  : String (1 .. Header_Size + Max_Transfer + 3);  --  + alignment
      Got  : Natural := 0;
      N    : Natural;
      N_Chars : Natural;
   begin
      Tag := Next_Tag (T);
      Raw_Write (T, Bulk_Out_Header (REQUEST_DEV_DEP_MSG_IN, Tag, Size, 0));

      --  Keep reading until the header and all announced bytes are in
      loop
         N := Raw_Read (T, Buf, Got + 1);

         --  A transfer whose length is a multiple of the 64-byte packet
         --  size (12 + 500 = 512 for the scope's data chunks) is closed
         --  by a zero-length packet, which is still queued when the next
         --  transfer is read.  Skip it.  An empty read part-way through
         --  a transfer is a real error; a missing reply times out in
         --  Raw_Read.
         if N = 0 and then Got > 0 then
            raise Communication_Error with "USB-TMC short transfer";
         end if;
         Got := Got + N;

         if Got >= Header_Size then
            N_Chars := Pos (Buf (5)) + Pos (Buf (6)) * 2**8 +
                       Pos (Buf (7)) * 2**16 + Pos (Buf (8)) * 2**24;
            exit when Got >= Header_Size + N_Chars;
         end if;
         if Got = Buf'Length then
            raise Communication_Error with "USB-TMC transfer overrun";
         end if;
      end loop;

      if Pos (Buf (1)) /= REQUEST_DEV_DEP_MSG_IN
        or else Buf (2) /= Tag
        or else N_Chars > Size
      then
         raise Communication_Error with "USB-TMC bad response header";
      end if;

      Append (Result, Buf (Header_Size + 1 .. Header_Size + N_Chars));
      EOM := Pos (Buf (9)) mod 2 = 1;
   end Read_Transfer;

   -- -------------------------------------------------------------------------

   overriding function Query
     (T       : in out Handle;
      Command : in     String) return String
   is
      Result : Unbounded_String;
      Len    : Natural;
      EOM    : Boolean := False;
   begin
      Send (T, Command);

      --  One Query may span several USBTMC transfers: the scope sends
      --  large responses in pieces (500 bytes each on the DS1000Z-E)
      --  and flags the last one with EOM.
      while not EOM loop
         Read_Transfer (T, Result, EOM);
      end loop;
      Len := Length (Result);

      --  Strip the SCPI terminator (LF, optionally preceded by CR).
      --  Only one is removed: a binary block may legitimately end in
      --  bytes that happen to equal CR or LF.
      if Len > 0 and then Element (Result, Len) = ASCII.LF then
         Len := Len - 1;
         if Len > 0 and then Element (Result, Len) = ASCII.CR then
            Len := Len - 1;
         end if;
      end if;

      return Slice (Result, 1, Len);
   end Query;

   -- -------------------------------------------------------------------------

   overriding procedure Close (T : in out Handle) is
      Dummy : int;
   begin
      if T.FD /= Invalid_FD then
         Dummy := C_Close (T.FD);
         T.FD  := Invalid_FD;
      end if;
   end Close;

   -- -------------------------------------------------------------------------

   overriding function Is_Open (T : Handle) return Boolean is
   begin
      return T.FD /= Invalid_FD;
   end Is_Open;

end Rigol_Transport.USBTMC;
