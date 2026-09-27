-- ***************************************************************************
--                      Rigol - Transport Interface Specification
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

--  Abstract transport interface for SCPI communication.
--  Concrete implementations: Rigol_Transport.USBTMC, Rigol_Transport.LAN

package Rigol_Transport is

   --  Raised when a device cannot be opened or is not found
   Device_Error        : exception;

   --  Raised on read/write failures
   Communication_Error : exception;

   --  Abstract base type for all transport implementations.
   --  Limited: transport handles represent hardware resources and must
   --  not be copied.
   type Handle is abstract tagged limited null record;
   type Handle_Access is access all Handle'Class;

   --  Send a SCPI command string to the instrument.
   procedure Send
     (T       : in out Handle;
      Command : in     String) is abstract;

   --  Send a query command and return the response string.
   --  The trailing newline/CR is stripped from the response.
   function Query
     (T       : in out Handle;
      Command : in     String) return String is abstract;

   --  Close the transport connection and release resources.
   procedure Close (T : in out Handle) is abstract;

   --  Return True if the transport is currently open/connected.
   function Is_Open (T : Handle) return Boolean is abstract;

end Rigol_Transport;
