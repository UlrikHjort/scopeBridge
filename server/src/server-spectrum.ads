-- ***************************************************************************
--               ScopeBridge Server - Spectrum Specification
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

--  Amplitude spectra of sampled signals, for the server's own FFT.
--
--  A spectrum gives, per frequency bin, the RMS amplitude of the sine at
--  that frequency, in dBV (dB relative to 1 V RMS): a 1 V amplitude sine
--  shows as -3.0 dBV at its frequency, whatever the window.  Signals
--  longer than one FFT are cut into segments whose spectra are averaged
--  (Welch's method), which lowers the noise floor.

package Server.Spectrum is

   type Window_Kind is (Rectangle, Hann, Hamming, Blackman, Flattop);

   type Real_Array is array (Natural range <>) of Long_Float;

   --  Longest FFT used; longer signals are averaged in segments this long
   Max_Segment : constant := 2 ** 20;

   --  Shortest signal worth transforming
   Min_Length  : constant := 16;

   --  The spectrum of Samples (volts), taken Sample_Interval seconds
   --  apart.  Bin K is at K * Bin_Width Hz, for K in 0 .. N/2 where N is
   --  the segment length: the largest power of two up to Samples'Length
   --  and Max_Segment.  Values in dBV.
   --  Raises Constraint_Error if there are fewer than Min_Length samples.
   function Compute
     (Samples         : Real_Array;
      Sample_Interval : Long_Float;
      Window          : Window_Kind;
      Bin_Width       : out Long_Float) return Real_Array;

   --  The same, for Length samples read through Sample (I in 0 .. Length
   --  - 1), so a capture of millions of samples need not be copied into
   --  a Real_Array first.
   --
   --  With Whole, all Length samples go into one transform instead:
   --  windowed as they are and padded with zeros to the next power of
   --  two, so the resolution is about 1 / (Length * Sample_Interval)
   --  rather than that of one segment.  Length must be at most
   --  Max_Segment then.
   function Compute
     (Length          : Natural;
      Sample          : not null access function (I : Natural) return Long_Float;
      Sample_Interval : Long_Float;
      Window          : Window_Kind;
      Bin_Width       : out Long_Float;
      Whole           : Boolean := False) return Real_Array;

   --  Floor for bins with no energy
   Min_dBV : constant := -200.0;

end Server.Spectrum;
