-- ***************************************************************************
--                      Rigol - Math Commands Specification
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

--  :MATH command group: the scope's math channel, which shows either an
--  algebraic combination of the channels or the FFT of one of them.
--
--  Read the result like a channel's screen waveform, with
--  Rigol.Waveform.Prepare_Math_Read.  After the operator changes the scope
--  needs one to three seconds before the math waveform can be read; until
--  then it reports 0 points.
--
--  For FFT the waveform is a spectrum: its preamble's X_Increment is Hz
--  per point, and the first point is at max (0, X_Origin) Hz (the scope
--  sends only the part of the screen at or above 0 Hz); the values are
--  dBV or Vrms (see FFT_Unit).

package Rigol.Math is

   --  Other: a logic, functional or compound operation, which this
   --  package reports but does not set
   type Operator is (Add, Subtract, Multiply, Divide, FFT, Other);
   subtype Settable_Operator is Operator range Add .. FFT;

   --  Other: FX, the inner result of a compound operation
   type Source is (CH1, CH2, Other);
   subtype Channel_Source is Source range CH1 .. CH2;

   type FFT_Window is (Rectangle, Hanning, Hamming, Blackman, Flattop, Triangle);
   type FFT_Unit   is (dB, Vrms);
   type FFT_Mode   is (Trace, Memory);   --  screen data, or acquisition memory

   procedure Set_Display  (Scope : in out Oscilloscope; On : Boolean);
   function  Get_Display  (Scope : in out Oscilloscope) return Boolean;

   procedure Set_Operator (Scope : in out Oscilloscope; Op : Settable_Operator);
   function  Get_Operator (Scope : in out Oscilloscope) return Operator;

   --  Sources A and B of the algebraic operations
   procedure Set_Source1  (Scope : in out Oscilloscope; Src : Channel_Source);
   function  Get_Source1  (Scope : in out Oscilloscope) return Source;
   procedure Set_Source2  (Scope : in out Oscilloscope; Src : Channel_Source);
   function  Get_Source2  (Scope : in out Oscilloscope) return Source;

   --  Vertical scale (unit/div) and offset of the result: volts for the
   --  algebraic operations (V^2 for Multiply), dB or Vrms for FFT
   procedure Set_Scale    (Scope : in out Oscilloscope; Scale : Float);
   function  Get_Scale    (Scope : in out Oscilloscope) return Float;
   procedure Set_Offset   (Scope : in out Oscilloscope; Offset : Float);
   function  Get_Offset   (Scope : in out Oscilloscope) return Float;

   procedure Set_FFT_Source (Scope : in out Oscilloscope; Src : Channel_Source);
   function  Get_FFT_Source (Scope : in out Oscilloscope) return Source;
   procedure Set_FFT_Window (Scope : in out Oscilloscope; Window : FFT_Window);
   function  Get_FFT_Window (Scope : in out Oscilloscope) return FFT_Window;
   procedure Set_FFT_Unit   (Scope : in out Oscilloscope; Unit : FFT_Unit);
   function  Get_FFT_Unit   (Scope : in out Oscilloscope) return FFT_Unit;
   procedure Set_FFT_Mode   (Scope : in out Oscilloscope; Mode : FFT_Mode);
   function  Get_FFT_Mode   (Scope : in out Oscilloscope) return FFT_Mode;

   --  Hz per division, and the frequency at the screen's centre.  The
   --  scope accepts only some scales (1/1000, 1/400, 1/200, 1/100, 1/40
   --  and 1/20 of the FFT sample rate) and ignores others.
   procedure Set_FFT_HScale  (Scope : in out Oscilloscope; Hz : Float);
   function  Get_FFT_HScale  (Scope : in out Oscilloscope) return Float;
   procedure Set_FFT_HCenter (Scope : in out Oscilloscope; Hz : Float);
   function  Get_FFT_HCenter (Scope : in out Oscilloscope) return Float;

end Rigol.Math;
