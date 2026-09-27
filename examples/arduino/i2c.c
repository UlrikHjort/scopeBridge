/* ***************************************************************************
 *              ScopeBridge Examples - Arduino I2C Test Signal
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
 * A known I2C signal for trying the scope's and the server's decoding:
 * the same traffic as scopebridge-server's simulated scope sends.
 *
 * Every 2 ms, at about 75 kHz (10 us of delays per bit, the wait for SCL
 * to rise, and a little code), on A5 (SCL) and A4 (SDA):
 *
 *     S 50h+W  00 10  P                      a write of 00 10 to 50h
 *     S 50h+W  00  Sr 50h+R  A5 3C  P        a read from it, with a
 *                                            repeated start; the last
 *                                            byte not acknowledged
 *
 * Probe SCL with CH1 and SDA with CH2.  The lines are driven as I2C
 * drives them: pulled low, or let go and pulled up (by the Uno's own
 * pull-ups, ~35 kOhm; 4.7 kOhm resistors to 5 V give sharper edges).
 *
 * With nothing on the bus the Uno plays the device's part as well: it
 * pulls SDA low for the device's acknowledges, and sends the bytes read
 * (A5 3C).  Build with DEFS="-DSIMULATE_DEVICE=0" to talk to a real chip
 * at address 50h, such as a 24C02 EEPROM: then the acknowledges and the
 * data read are the device's own, and the write stores 10 at address 00.
 * Without a device the address is then not acknowledged, which the
 * decoders show in red.
 *
 * The protocol is done in software (bit by bit), so every step is plain
 * to see; the ATmega328P's TWI hardware would do the same.
 */

#include <avr/io.h>
#include <stdbool.h>
#include <stdint.h>
#include <util/delay.h>

#ifndef SIMULATE_DEVICE
#define SIMULATE_DEVICE 1
#endif

#define SDA PC4 /* A4 */
#define SCL PC5 /* A5 */

#define QUARTER 2.5 /* us: a quarter of a 10 us (100 kHz) bit */

/* Open drain: low is driven, high is let go and pulled up.  Always
   inline, so that with the pin known each change is one sbi or cbi: as a
   called function with the pin a variable, each call took about 45
   cycles, and the clock ran at 45 kHz instead of 100 */
static inline __attribute__ ((always_inline)) void line (uint8_t bit, bool high) {
  if (high) {
    DDRC &= ~_BV (bit);
    PORTC |= _BV (bit); /* the pull-up */
  } else {
    PORTC &= ~_BV (bit);
    DDRC |= _BV (bit);
  }
}

/* Let SCL go, and wait until it is high: it rises slowly through the
   pull-up, and SDA may only change for a start or stop once SCL has
   risen.  Masters do this anyway, as a device may hold SCL low to make
   them wait (clock stretching). */
static inline __attribute__ ((always_inline)) void release_scl (void) {
  line (SCL, true);
  loop_until_bit_is_set (PINC, SCL);
}

static bool sda_is_high (void) {
  return bit_is_set (PINC, SDA);
}

/* Each bit: SDA set while SCL is low, SCL high for half the bit */
static inline __attribute__ ((always_inline)) bool clock_bit (bool bit) {
  bool read;

  line (SDA, bit);
  _delay_us (QUARTER);
  release_scl ();
  _delay_us (QUARTER);
  read = sda_is_high ();
  _delay_us (QUARTER);
  line (SCL, false);
  _delay_us (QUARTER);
  return read;
}

static void start (void) {
  /* From idle, or after a byte (SCL low): SDA high, SCL high, then SDA
     falls while SCL is high */
  line (SDA, true);
  _delay_us (QUARTER);
  release_scl ();
  _delay_us (QUARTER);
  line (SDA, false);
  _delay_us (QUARTER);
  line (SCL, false);
  _delay_us (QUARTER);
}

static void stop (void) {
  /* SDA rises while SCL is high */
  line (SDA, false);
  _delay_us (QUARTER);
  release_scl ();
  _delay_us (QUARTER);
  line (SDA, true);
  _delay_us (2 * QUARTER);
}

/* Send a byte, most significant bit first; true if acknowledged (the
   device pulls SDA low for the ninth bit) */
static bool write_byte (uint8_t byte) {
  for (uint8_t k = 0; k < 8; k++, byte <<= 1)
    clock_bit (byte & 0x80);
  /* The acknowledge: let SDA go, the device pulls it low */
  return !clock_bit (!SIMULATE_DEVICE);
}

/* Receive a byte and acknowledge it (ack) or not (the last one) */
static uint8_t read_byte (uint8_t simulated, bool ack) {
  uint8_t byte = 0;

  for (uint8_t k = 0; k < 8; k++, simulated <<= 1) {
    /* A real device drives the bits; we let SDA go and read them */
    bool bit = clock_bit (SIMULATE_DEVICE ? simulated & 0x80 : true);
    byte = byte << 1 | bit;
  }
  clock_bit (!ack);
  return byte;
}

#define ADDRESS 0x50

int main (void) {
  release_scl ();
  line (SDA, true);
  for (;;) {
    /* Write 10 to register (or EEPROM address) 00 */
    start ();
    if (write_byte (ADDRESS << 1 | 0)) {
      write_byte (0x00);
      write_byte (0x10);
    }
    stop ();
    _delay_us (50); /* an EEPROM would need ~5 ms to store it */

    /* Read two bytes from 00: set the address, repeated start, read */
    start ();
    if (write_byte (ADDRESS << 1 | 0)) {
      write_byte (0x00);
      start ();
      write_byte (ADDRESS << 1 | 1);
      read_byte (0xA5, true);
      read_byte (0x3C, false);
    }
    stop ();
    _delay_ms (2);
  }
}
