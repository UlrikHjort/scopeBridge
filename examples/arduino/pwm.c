/* ***************************************************************************
 *        ScopeBridge Examples - Arduino PWM, Hardware and Software
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
 * PWM, twice: in hardware and in software, side by side.
 *
 * D11 (CH2): Timer 2's fast PWM, 16 MHz / 64 / 256 = 976.5625 Hz, made
 * entirely by the timer: every period and every pulse the same length.
 * D13 (CH1): the same PWM made by a program, marker A high for the high
 * time, with _delay_us between. A timer interrupt every 4.5 ms, about
 * every fourth or fifth period, does 20 us of "housekeeping", as a real
 * program's would; the high or low time it lands in is 20 us too long.
 *
 * On the scope: CH1 on D13, CH2 on D11, timebase 1 ms/div, trigger CH2
 * rising. Measure the frequency and duty of both; in the Timing panel,
 * time CH2 (the hardware: no spread at all) and CH1 (the software: the
 * interrupt's outliers in the histogram). The FFT of CH2 shows PWM's
 * harmonics: at 50 % duty the even ones vanish, at 25 % every fourth.
 *
 * Build options (make DEFS="..."):
 *     -DDUTY=50          the duty cycle, in percent (1 .. 99)
 *     -DNO_INTERRUPT     no housekeeping interrupt: the software PWM steady too
 */

#include <avr/interrupt.h>
#include <avr/io.h>
#include <stdint.h>
#include <util/delay.h>

#include "timing.h"

#ifndef DUTY
#define DUTY 50
#endif
#if DUTY < 1 || DUTY > 99
#error "DUTY is a percentage, 1 .. 99"
#endif

/* The software PWM's high and low times, for the hardware's period of
   64 * 256 cycles, 1024 us */
#define PERIOD_US 1024.0
#define HIGH_US (PERIOD_US * DUTY / 100.0)
#define LOW_US (PERIOD_US - HIGH_US)

#ifndef NO_INTERRUPT
/* Housekeeping, every 4.5 ms: a rate that drifts through the PWM's
   periods, so that it lands in high and low times alike, and leaves
   most periods alone */
ISR (TIMER0_COMPA_vect) {
  _delay_us (20);
}
#endif

int main (void) {
  TIMING_INIT ();

  /* Timer 2: fast PWM on OC2A (D11), set at the start of each period and
     cleared at the compare match: (OCR2A + 1) / 256 of the period high */
  OCR2A = (uint8_t) (256L * DUTY / 100 - 1);
  TCCR2A = _BV (COM2A1) | _BV (WGM21) | _BV (WGM20);
  TCCR2B = _BV (CS22); /* F_CPU / 64 */

#ifndef NO_INTERRUPT
  /* Timer 0: a compare interrupt every 71 * 1024 cycles, 4.544 ms */
  OCR0A = 70;
  TCCR0A = _BV (WGM01);             /* CTC */
  TCCR0B = _BV (CS02) | _BV (CS00); /* F_CPU / 1024 */
  TIMSK0 = _BV (OCIE0A);
  sei ();
#endif

  for (;;) {
    TIMING_A_ON ();
    _delay_us (HIGH_US);
    TIMING_A_OFF ();
    _delay_us (LOW_US);
  }
}
