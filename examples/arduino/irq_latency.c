/* ***************************************************************************
 *             ScopeBridge Examples - Arduino Interrupt Latency
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
 * Interrupt latency: how long from an event to the first line of the code
 * that answers it, and how much that varies.
 *
 * D11 (CH2): Timer 2 toggles it in hardware every 1 ms, at exact moments.
 * The same compare match raises an interrupt, whose routine sets D13 (CH1)
 * as the first thing it does. The time from each rising edge on CH2 to
 * the next on CH1 is the latency: the CPU finishes the instruction it is
 * in, saves the registers the routine needs, and jumps there.
 *
 * The main program has a critical section: every 1.84 ms it turns the
 * interrupts off for 300 us (as code does around data it shares with an
 * interrupt). 1.84 ms is no multiple of the timer's 1 ms, so the section
 * drifts across the events; at 2 ms it would always fall between two of
 * them, and hide. An event that comes then waits until they are on again, and
 * its latency is up to 300 us long: the outliers of the histogram.
 *
 * On the scope: CH1 on D13, CH2 on D11, timebase 2 ms/div, trigger CH2
 * rising, capture both; time CH2 with latency to CH1. Longest zooms to an
 * event that waited; at 1 us/div around an edge, the usual latency.
 *
 * Build options (make DEFS="..."):
 *     -DCRITICAL_US=300  the critical section's length; 0 for none, and
 *                        the latency is then the same, give or take a
 *                        cycle or two, every time
 */

#include <avr/interrupt.h>
#include <avr/io.h>
#include <util/delay.h>

#include "timing.h"

#ifndef CRITICAL_US
#define CRITICAL_US 300
#endif

/* The answer to the timer: marker A first, then 5 us of work */
ISR (TIMER2_COMPA_vect) {
  TIMING_A_ON ();
  _delay_us (5);
  TIMING_A_OFF ();
}

int main (void) {
  TIMING_INIT ();

  /* Timer 2 in CTC mode at F_CPU / 64: a compare match every 250 counts,
     1 ms, which toggles OC2A (D11) in hardware and raises the interrupt */
  OCR2A = 249;
  TCCR2A = _BV (COM2A0) | _BV (WGM21);
  TCCR2B = _BV (CS22);
  TIMSK2 = _BV (OCIE2A);
  sei ();

  for (;;) {
#if CRITICAL_US > 0
    cli ();
    _delay_us (CRITICAL_US); /* the critical section: no interrupts */
    sei ();
#endif
    _delay_us (1537); /* other work, with interrupts on */
  }
}
