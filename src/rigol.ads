-- ***************************************************************************
--                      Rigol - Oscilloscope Package Specification
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

--  Root package for the Rigol DS1000Z-E oscilloscope interface.
--  Developed and tested with a DS1202Z-E, firmware 00.06.04: channel
--  numbers are 1 .. 2, and the transports work around behaviour found on
--  that instrument (see README.md, Compatibility).
--
--  The Oscilloscope tagged type is bound to a transport implementation
--  (USB-TMC or LAN) by an access discriminant, so the binding is fixed
--  when the scope object is declared.  All subsystem child packages
--  (Rigol.Channel, Rigol.Acquire, ...) accept an Oscilloscope parameter
--  and delegate to Send / Query defined here.
--
--  The discriminant is what makes the transport safe to keep: because it
--  is an access discriminant rather than an ordinary component, its
--  accessibility is that of the scope object rather than of the type, so
--  a transport declared alongside the scope is accepted and one that
--  would not outlive the scope is rejected at compile time.
--
--  Typical usage:
--
--    T     : aliased Rigol_Transport.USBTMC.Handle;
--    Scope : Rigol.Oscilloscope (T'Access);
--  begin
--    Rigol_Transport.USBTMC.Open (T);
--    Rigol.Run (Scope);
--    ...
--    Rigol.Disconnect (Scope);

with Rigol_Transport;

package Rigol is

   --  Raised when an operation is attempted on a disconnected scope
   Not_Connected : exception;

   type Oscilloscope
     (Transport : access Rigol_Transport.Handle'Class) is tagged limited private;

   -- -------------------------------------------------------------------------
   --  Connection management
   -- -------------------------------------------------------------------------

   --  Close the underlying transport.  The scope stays bound to it - the
   --  discriminant cannot be reseated - so this ends the session rather
   --  than freeing the object for reuse with a different transport.
   procedure Disconnect (Scope : in out Oscilloscope);

   function Is_Connected (Scope : Oscilloscope) return Boolean;

   -- -------------------------------------------------------------------------
   --  Basic acquisition control  (IEEE 488.2 / root-level SCPI commands)
   -- -------------------------------------------------------------------------

   --  :RUN - start continuous acquisition
   procedure Run (Scope : in out Oscilloscope);

   --  :STOP - freeze the display
   procedure Stop (Scope : in out Oscilloscope);

   --  :SINGle - arm for a single triggered acquisition
   procedure Single (Scope : in out Oscilloscope);

   --  :AUToscale - auto-set vertical/horizontal/trigger
   procedure Auto_Scale (Scope : in out Oscilloscope);

   --  :CLEar - clear all waveforms from screen
   procedure Clear (Scope : in out Oscilloscope);

   --  :TFORce - force a trigger immediately
   procedure Force_Trigger (Scope : in out Oscilloscope);

   -- -------------------------------------------------------------------------
   --  SCPI argument formatting
   -- -------------------------------------------------------------------------

   --  'Image renders non-negative numbers with a leading space, which would
   --  otherwise land in the middle of a command (":ACQuire:AVERages  16").
   --  These trim it; child packages get them by visibility.

   function Image (Value : Float)   return String;
   function Image (Value : Integer) return String;

   -- -------------------------------------------------------------------------
   --  Raw transport primitives (used by child packages and for custom SCPI)
   -- -------------------------------------------------------------------------

   procedure Send
     (Scope   : in out Oscilloscope;
      Command : in     String);

   function Query
     (Scope   : in out Oscilloscope;
      Command : in     String) return String;

   --  Query a command whose response is an IEEE 488.2 definite-length
   --  block, #<n><length><data> (waveform data, screen images), and return
   --  <data> alone.  Raises Rigol_Transport.Communication_Error if the
   --  response is not a complete block.
   function Query_Block
     (Scope   : in out Oscilloscope;
      Command : in     String) return String;

   --  The <data> part of a definite-length block, as described above
   function Block_Data (Response : String) return String;

private

   --  The discriminant is the whole state; there is nothing else to hold.
   type Oscilloscope
     (Transport : access Rigol_Transport.Handle'Class) is
     tagged limited null record;

end Rigol;
