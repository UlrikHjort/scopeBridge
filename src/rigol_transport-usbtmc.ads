-- ***************************************************************************
--                      Rigol - USB-TMC Transport Specification
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

--  USB-TMC transport via the Linux kernel usbtmc driver.
--  The driver exposes the oscilloscope as a character device,
--  typically /dev/usbtmc0.
--
--  All traffic goes through the driver's raw ioctl interface
--  (USBTMC_IOCTL_WRITE / USBTMC_IOCTL_READ, driver API version >= 2)
--  and is framed here, because the DS1000Z-E ends each 64-byte bulk
--  packet as if it were a short packet: a plain read() returns only
--  the first 52 bytes of every response and silently drops the rest.
--
--  Failures are recoverable: a query that gets no reply raises
--  Communication_Error when the timeout expires, and the handle stays
--  usable.  A reply abandoned part-way (an exception, or a program that
--  exits mid-transfer) is discarded by the scope when the next command
--  arrives.  Verified on a DS1202Z-E, firmware 00.06.04.

with Interfaces.C;
use  Interfaces.C;

package Rigol_Transport.USBTMC is

   type Handle is new Rigol_Transport.Handle with private;

   --  Open the usbtmc character device.
   --  Raises Device_Error if the device cannot be opened.
   procedure Open
     (T           : out Handle;
      Device_Path : in  String := "/dev/usbtmc0");

   --  How long one USB read or write may take before it fails; the
   --  kernel driver's default is 5 s.  Raise it for slow responses such
   --  as large screenshots.  Raises Communication_Error if refused.
   procedure Set_Timeout
     (T       : in out Handle;
      Timeout : in     Duration);

   overriding procedure Send
     (T       : in out Handle;
      Command : in     String);

   overriding function Query
     (T       : in out Handle;
      Command : in     String) return String;

   overriding procedure Close   (T : in out Handle);
   overriding function  Is_Open (T :        Handle) return Boolean;

private

   Invalid_FD : constant int := -1;

   type Handle is new Rigol_Transport.Handle with record
      FD   : int := Invalid_FD;
      BTag : unsigned_char := 0;  --  last USBTMC bTag used, 1 .. 255
   end record;

end Rigol_Transport.USBTMC;
