/* ***************************************************************************
 *              ScopeBridge Examples - Arduino SPI Test Signal
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
 * A known SPI signal for trying the scope's and the server's decoding.
 *
 * Every 100 us the Uno's SPI hardware sends the bytes 9F EF 40 18 at
 * 1 MHz: SCK on D13, MOSI on D11 (and a chip select, active low, on D10,
 * for a scope with a third channel).  Probe SCK with CH1 and MOSI with
 * CH2.  The pause between bursts is what the decoders' timeout uses to
 * find where a word starts.
 *
 * Build options (make DEFS="..."):
 *     -DSPI_MODE=0       0 .. 3: clock idle low (0, 1) or high (2, 3), data
 *                        valid on the first (0, 2) or second (1, 3) edge
 *     -DLSB_FIRST=0      1: least significant bit first
 *
 * Decode with the edge the data is valid on: rising for modes 0 and 3,
 * falling for 1 and 2.
 */

#include <avr/io.h>
#include <stdint.h>
#include <util/delay.h>

#ifndef SPI_MODE
#define SPI_MODE 0
#endif
#ifndef LSB_FIRST
#define LSB_FIRST 0
#endif

static const uint8_t message[] = {0x9F, 0xEF, 0x40, 0x18};

int main (void) {
  /* SCK, MOSI and SS as outputs: SS must be, for the Uno to stay master */
  DDRB = _BV (PB5) | _BV (PB3) | _BV (PB2);
  PORTB |= _BV (PB2);
  SPCR = _BV (SPE) | _BV (MSTR) | _BV (SPR0) /* master, F_CPU / 16 = 1 MHz */
         | (SPI_MODE & 2 ? _BV (CPOL) : 0)   /* clock idle high */
         | (SPI_MODE & 1 ? _BV (CPHA) : 0)   /* data valid on the second edge */
         | (LSB_FIRST ? _BV (DORD) : 0);     /* least significant bit first */

  for (;;) {
    PORTB &= ~_BV (PB2); /* select */
    for (uint8_t k = 0; k < sizeof message; k++) {
      SPDR = message[k];
      loop_until_bit_is_set (SPSR, SPIF);
    }
    PORTB |= _BV (PB2);
    _delay_us (100);
  }
}
