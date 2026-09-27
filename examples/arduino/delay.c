/* ***************************************************************************
 *          ScopeBridge Examples - Arduino Timing of a Known Delay
 *
 *           Copyright (C) 2026 By Ulrik Hørlyk Hjort
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
 * LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
 * OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
 * WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 * ***************************************************************************
 */

/*
 * Checking the timing against a known delay: marker A (D13) high around
 * _delay_us (100), and marker B (D11) around nothing at all.  Probe D13
 * with CH1 and D11 with CH2 (the bench's wiring), capture at 200 us/div,
 * and time both channels.
 *
 * What to expect, to the cycle: _delay_us counts exact cycles and nothing
 * interrupts, so every block is the same length:
 *
 *     CH1   100 us + 2 cycles (the sbi that sets the pin) = 1602 cycles
 *           = 100.125 us at 16 MHz, with no spread at all
 *     CH2   2 cycles = 125 ns: what a marker costs
 *
 * What is left over is the Uno's clock.  The Uno runs on a ceramic
 * resonator, good to about 0.5 %, not a crystal: a CH1 block of
 * 100.23 us means it runs 0.1 % slow, at 15.984 MHz.  The spread (the
 * standard deviation) is the scope's: a sample or two at most.
 *
 * Build options (make DEFS="..."):
 *     -DDELAY_US=100     the delay timed, in us
 */

#include <avr/io.h>
#include <util/delay.h>

#include "timing.h"

#ifndef DELAY_US
#define DELAY_US 100
#endif

int main (void) {
  TIMING_INIT ();
  for (;;) {
    TIMING_A_ON ();
    _delay_us (DELAY_US);
    TIMING_A_OFF ();
    _delay_us (DELAY_US / 2);
    TIMING_B_ON (); /* the markers' own cost: nothing between them */
    TIMING_B_OFF ();
    _delay_us (DELAY_US / 2);
  }
}
