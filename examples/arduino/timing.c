/* ***************************************************************************
 *                ScopeBridge Examples - Arduino Code Timing
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
 * Timing code with the scope: a CRC-16 over messages of 16, 24 and 32
 * bytes, in turn, with marker A (D13) high for each call and marker B
 * (D11) high while each byte is worked on.  Probe D13 with CH1 and D11
 * with CH2 (the bench's wiring), capture at 1 ms/div, and time CH1 with
 * latency to CH2 and a burst gap of 50 us:
 *
 *     block          the CRC's run time: three lengths, one per message size,
 *                    and now and then a longer one
 *     latency        from the call to the first byte: the set-up cost
 *     burst          on CH2: the byte loop's length, and its pulses: the
 *                    bytes (16, 24 or 32)
 *
 * The longer ones are real: a timer interrupt every 2 ms, like the
 * housekeeping of a real program, takes about 25 us, and when it comes
 * while the CRC runs, that run is longer by as much.  Zoom to the longest
 * block and the byte where it happened has the long B pulse.  Try the
 * pulse-width trigger on CH1 at "> the usual longest" to catch them.
 *
 * Build options (make DEFS="..."):
 *     -DNO_INTERRUPT     without the timer interrupt: every run of the
 *                        same size then takes the same time, to the cycle
 *     -DTABLE_CRC        a table-driven CRC instead of bit by bit: compare
 *                        the run times
 */

#include <avr/interrupt.h>
#include <avr/io.h>
#include <avr/pgmspace.h>
#include <stdint.h>
#include <util/delay.h>

#include "timing.h"

static uint8_t message[32];
static volatile uint16_t result; /* so the CRC is not optimised away */

#ifdef TABLE_CRC
/* CRC-16/CCITT of each byte value, built at start */
static uint16_t table[256];

static void make_table (void) {
  for (uint16_t v = 0; v < 256; v++) {
    uint16_t crc = v << 8;
    for (uint8_t bit = 0; bit < 8; bit++) {
      crc = crc & 0x8000 ? (crc << 1) ^ 0x1021 : crc << 1;
    }
    table[v] = crc;
  }
}
#endif

/* CRC-16/CCITT (polynomial 1021h, start FFFFh), with B high per byte */
static uint16_t crc16 (const uint8_t *data, uint8_t length) {
  uint16_t crc = 0xFFFF;
  for (uint8_t k = 0; k < length; k++) {
    TIMING_B_ON ();
#ifdef TABLE_CRC
    crc = (crc << 8) ^ table[(uint8_t) (crc >> 8) ^ data[k]];
#else
    crc ^= (uint16_t) data[k] << 8;
    for (uint8_t bit = 0; bit < 8; bit++) {
      crc = crc & 0x8000 ? (crc << 1) ^ 0x1021 : crc << 1;
    }
#endif
    TIMING_B_OFF ();
  }
  return crc;
}

#ifndef NO_INTERRUPT
/* Housekeeping every 2 ms: about 25 us of work */
ISR (TIMER2_COMPA_vect) {
  _delay_us (25);
}
#endif

int main (void) {
  TIMING_INIT ();
#ifdef TABLE_CRC
  make_table ();
#endif
#ifndef NO_INTERRUPT
  /* Timer 2 in CTC mode at F_CPU / 1024: 32 counts are 2.05 ms */
  TCCR2A = _BV (WGM21);
  TCCR2B = _BV (CS22) | _BV (CS21) | _BV (CS20);
  OCR2A = 31;
  TIMSK2 = _BV (OCIE2A);
  sei ();
#endif

  for (uint8_t pass = 0;; pass++) {
    const uint8_t length = 16 + 8 * (pass % 3);
    for (uint8_t k = 0; k < length; k++) {
      message[k] = pass + k;
    }
    TIMING_A_ON ();
    result = crc16 (message, length);
    TIMING_A_OFF ();
    _delay_us (500);
  }
}
