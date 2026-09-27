/* ***************************************************************************
 *             ScopeBridge Examples - Arduino UART Test Signal
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
 * A known UART signal for trying the scope's and the server's decoding.
 *
 * Every 10 ms the Uno sends "Hello, Rigol! <n>" and CR LF on D1 (TX),
 * <n> counting up so each message differs.  Whatever arrives on D0 (RX)
 * is sent back in upper case, so typing in a serial terminal
 *
 *     screen /dev/ttyACM0 115200
 *
 * gives traffic in both directions: probe D1 with CH1 (the Uno's TX) and
 * D0 with CH2 (what the computer sends, through the Uno's USB chip).
 *
 * Build options (make DEFS="..."):
 *     -DBAUD=115200      the baud rate
 *     -DPARITY=0         0 none, 1 odd, 2 even
 *     -DSTOP_BITS=1      1 or 2
 *
 * At 16 MHz some rates are not exact: 115200 comes out as 117647 baud
 * (2.1 % fast), which receivers, and the decoders, tolerate.  250000,
 * 500000 and 1000000 are exact.
 */

#include <avr/io.h>
#include <stdint.h>
#include <util/delay.h>

#ifndef BAUD
#define BAUD 115200
#endif
#ifndef PARITY
#define PARITY 0
#endif
#ifndef STOP_BITS
#define STOP_BITS 1
#endif

/* Double speed (U2X) halves the rounding error at high rates */
#define UBRR_VALUE ((F_CPU + 4UL * BAUD) / (8UL * BAUD) - 1)

static void uart_init (void) {
  UBRR0 = UBRR_VALUE;
  UCSR0A = _BV (U2X0);
  UCSR0B = _BV (TXEN0) | _BV (RXEN0);
  UCSR0C = _BV (UCSZ01) | _BV (UCSZ00)                     /* 8 data bits */
           | (PARITY == 1 ? _BV (UPM01) | _BV (UPM00) : 0) /* odd */
           | (PARITY == 2 ? _BV (UPM01) : 0)               /* even */
           | (STOP_BITS == 2 ? _BV (USBS0) : 0);
}

/* Characters received, until echo () sends them back.  The receiver holds
   only two, and at 115200 baud one may come every 87 us, also while a
   message is being sent: so they are taken as they come, also while
   put () waits to send, or pasted text loses all but a few */
static char received[32];
static uint8_t head, tail;

static void receive (void) {
  if (bit_is_set (UCSR0A, RXC0)) {
    char c = UDR0;
    uint8_t next = (head + 1) % sizeof received;
    if (next != tail) {
      received[head] = c;
      head = next;
    }
  }
}

static void put (char c) {
  while (bit_is_clear (UCSR0A, UDRE0))
    receive ();
  UDR0 = c;
}

static void put_string (const char *s) {
  while (*s)
    put (*s++);
}

static void put_number (uint16_t n) {
  char digits[6];
  uint8_t k = 0;

  do {
    digits[k++] = '0' + n % 10;
    n /= 10;
  } while (n > 0);
  while (k > 0)
    put (digits[--k]);
}

/* Echo received characters, upper case */
static void echo (void) {
  receive ();
  while (tail != head) {
    char c = received[tail];
    tail = (tail + 1) % sizeof received;
    put (c >= 'a' && c <= 'z' ? c - 'a' + 'A' : c);
  }
}

int main (void) {
  uint16_t n = 0;

  uart_init ();
  for (;;) {
    put_string ("Hello, Rigol! ");
    put_number (n++);
    put_string ("\r\n");
    /* 10 ms of idle line between messages, echoing meanwhile, and often
       enough for characters coming back to back (see receive ()) */
    for (uint16_t us = 0; us < 10000; us += 10) {
      echo ();
      _delay_us (10);
    }
  }
}
