/* ***************************************************************************
 *              ScopeBridge Examples - Timing Markers for Code
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
 * Timing code with the scope: set a pin when a block of code starts and
 * clear it when it ends, and the scope sees every run of the block as a
 * pulse.  scopebridge-server's "timing" (the GUI's and the web page's Timing
 * panel, scopebridge-term's timing command, Python's scope.timing) measures
 * them all: the shortest, longest, mean and spread, a histogram, the time
 * between runs, and where the longest one is, to zoom in on it.
 *
 * Two markers, A and B, for the scope's two channels:
 *
 *     TIMING_INIT ();              once, at start: the marker pins as outputs
 *     TIMING_A_ON (); ...code... TIMING_A_OFF ();
 *     TIMING_B_TOGGLE ();          a pulse edge per event, e.g. per pass of a loop
 *
 * A usual use: A around a whole function, B around its inner loop's body.
 * With A on CH1 and B on CH2, "timing" gives the function's run time, the
 * latency from its start to the loop, and with a burst gap one burst of B
 * pulses per call: its length, and the pulses in it (the loop's passes).
 *
 * The markers must cost next to nothing, so they write the port registers
 * directly: one instruction on most microcontrollers.  What they cost is
 * in the measurement too; time an empty block (TIMING_A_ON ();
 * TIMING_A_OFF ();) to see how much.
 *
 *     AVR (Arduino Uno, Nano, Mega, ...)   PORTx bit set/clear: sbi/cbi, 2
 *         cycles (125 ns at 16 MHz).  A is D13 (PB5, the LED), B is D11
 *         (PB3) unless TIMING_A_PORT, _DDR, _BIT (and B's) say otherwise.
 *     STM32 (TIMING_STM32, with the CMSIS device header included first)
 *         GPIOx->BSRR: one store.  Define TIMING_A_GPIO (e.g. GPIOA) and
 *         TIMING_A_PIN (0 .. 15), and B's; enable the port's clock and set
 *         the pin as an output yourself, as that differs between families.
 *     RP2040 / RP2350 (the Pico SDK: PICO_SDK_VERSION_MAJOR)  sio_hw
 *         gpio_set/gpio_clr: one store.  TIMING_A_PIN, TIMING_B_PIN
 *         (default GPIO 2 and 3).
 *     ESP32 family (ESP-IDF: ESP_PLATFORM)  GPIO_OUT_W1TS/W1TC: one store,
 *         for GPIO 0 .. 31.  TIMING_A_PIN, TIMING_B_PIN (default 18, 19).
 *     Other Arduino boards (ARDUINO)  digitalWrite: portable but slow,
 *         a microsecond or more; fine for blocks much longer than that.
 *     Anything else  define TIMING_A_ON (), TIMING_A_OFF (),
 *         TIMING_B_ON (), TIMING_B_OFF () and TIMING_INIT () yourself
 *         before including this.
 *
 * Only the AVR markers have been tried on hardware (an Arduino Uno); the
 * others follow the vendors' register descriptions.
 *
 * TIMING_BLOCK (A) { ...code... } marks a block without a separate on and
 * off, but a return, break or goto out of it skips the OFF.
 *
 * Catching a rare slow run: set the scope's pulse-width trigger to a width
 * longer than the usual block (e.g. ">250 us" for blocks of 200 us) and a
 * single acquisition; the scope then stops on the first slow one.
 */

#ifndef TIMING_H
#define TIMING_H

#if defined(TIMING_A_ON)
/* The markers are the program's own */

#elif defined(__AVR__)
#include <avr/io.h>

#ifndef TIMING_A_PORT
#define TIMING_A_PORT PORTB
#define TIMING_A_DDR DDRB
#define TIMING_A_PIN_REG PINB
#define TIMING_A_BIT PB5 /* D13 */
#endif
#ifndef TIMING_B_PORT
#define TIMING_B_PORT PORTB
#define TIMING_B_DDR DDRB
#define TIMING_B_PIN_REG PINB
#define TIMING_B_BIT PB3 /* D11 */
#endif

#define TIMING_A_ON() (TIMING_A_PORT |= _BV (TIMING_A_BIT))
#define TIMING_A_OFF() (TIMING_A_PORT &= ~_BV (TIMING_A_BIT))
#define TIMING_B_ON() (TIMING_B_PORT |= _BV (TIMING_B_BIT))
#define TIMING_B_OFF() (TIMING_B_PORT &= ~_BV (TIMING_B_BIT))
/* Writing a 1 to PINx toggles the pin (ATmega48/88/168/328 and later) */
#define TIMING_A_TOGGLE() (TIMING_A_PIN_REG = _BV (TIMING_A_BIT))
#define TIMING_B_TOGGLE() (TIMING_B_PIN_REG = _BV (TIMING_B_BIT))
#define TIMING_INIT()                                                                    \
  do {                                                                                   \
    TIMING_A_OFF ();                                                                     \
    TIMING_B_OFF ();                                                                     \
    TIMING_A_DDR |= _BV (TIMING_A_BIT);                                                  \
    TIMING_B_DDR |= _BV (TIMING_B_BIT);                                                  \
  } while (0)

#elif defined(TIMING_STM32)
/* The upper half of BSRR resets the pin, the lower half sets it */
#define TIMING_A_ON() (TIMING_A_GPIO->BSRR = 1u << TIMING_A_PIN)
#define TIMING_A_OFF() (TIMING_A_GPIO->BSRR = 1u << (TIMING_A_PIN + 16))
#define TIMING_B_ON() (TIMING_B_GPIO->BSRR = 1u << TIMING_B_PIN)
#define TIMING_B_OFF() (TIMING_B_GPIO->BSRR = 1u << (TIMING_B_PIN + 16))
#define TIMING_A_TOGGLE() (TIMING_A_GPIO->ODR ^= 1u << TIMING_A_PIN)
#define TIMING_B_TOGGLE() (TIMING_B_GPIO->ODR ^= 1u << TIMING_B_PIN)
#define TIMING_INIT()                                                                    \
  do {                                                                                   \
    TIMING_A_OFF ();                                                                     \
    TIMING_B_OFF ();                                                                     \
  } while (0)

#elif defined(PICO_SDK_VERSION_MAJOR)
#include "hardware/gpio.h"
#include "hardware/structs/sio.h"

#ifndef TIMING_A_PIN
#define TIMING_A_PIN 2
#endif
#ifndef TIMING_B_PIN
#define TIMING_B_PIN 3
#endif

#define TIMING_A_ON() (sio_hw->gpio_set = 1u << TIMING_A_PIN)
#define TIMING_A_OFF() (sio_hw->gpio_clr = 1u << TIMING_A_PIN)
#define TIMING_B_ON() (sio_hw->gpio_set = 1u << TIMING_B_PIN)
#define TIMING_B_OFF() (sio_hw->gpio_clr = 1u << TIMING_B_PIN)
#define TIMING_A_TOGGLE() (sio_hw->gpio_togl = 1u << TIMING_A_PIN)
#define TIMING_B_TOGGLE() (sio_hw->gpio_togl = 1u << TIMING_B_PIN)
#define TIMING_INIT()                                                                    \
  do {                                                                                   \
    gpio_init (TIMING_A_PIN);                                                            \
    gpio_init (TIMING_B_PIN);                                                            \
    gpio_set_dir (TIMING_A_PIN, GPIO_OUT);                                               \
    gpio_set_dir (TIMING_B_PIN, GPIO_OUT);                                               \
  } while (0)

#elif defined(ESP_PLATFORM)
#include "driver/gpio.h"
#include "soc/gpio_reg.h"

#ifndef TIMING_A_PIN
#define TIMING_A_PIN 18
#endif
#ifndef TIMING_B_PIN
#define TIMING_B_PIN 19
#endif

#define TIMING_A_ON() REG_WRITE (GPIO_OUT_W1TS_REG, 1u << TIMING_A_PIN)
#define TIMING_A_OFF() REG_WRITE (GPIO_OUT_W1TC_REG, 1u << TIMING_A_PIN)
#define TIMING_B_ON() REG_WRITE (GPIO_OUT_W1TS_REG, 1u << TIMING_B_PIN)
#define TIMING_B_OFF() REG_WRITE (GPIO_OUT_W1TC_REG, 1u << TIMING_B_PIN)
#define TIMING_A_TOGGLE()                                                                \
  REG_WRITE (REG_READ (GPIO_OUT_REG) & (1u << TIMING_A_PIN) ? GPIO_OUT_W1TC_REG          \
                                                            : GPIO_OUT_W1TS_REG,         \
             1u << TIMING_A_PIN)
#define TIMING_B_TOGGLE()                                                                \
  REG_WRITE (REG_READ (GPIO_OUT_REG) & (1u << TIMING_B_PIN) ? GPIO_OUT_W1TC_REG          \
                                                            : GPIO_OUT_W1TS_REG,         \
             1u << TIMING_B_PIN)
#define TIMING_INIT()                                                                    \
  do {                                                                                   \
    gpio_reset_pin (TIMING_A_PIN);                                                       \
    gpio_reset_pin (TIMING_B_PIN);                                                       \
    gpio_set_direction (TIMING_A_PIN, GPIO_MODE_OUTPUT);                                 \
    gpio_set_direction (TIMING_B_PIN, GPIO_MODE_OUTPUT);                                 \
  } while (0)

#elif defined(ARDUINO)
#include <Arduino.h>

#ifndef TIMING_A_PIN
#define TIMING_A_PIN 13
#endif
#ifndef TIMING_B_PIN
#define TIMING_B_PIN 11
#endif

#define TIMING_A_ON() digitalWrite (TIMING_A_PIN, HIGH)
#define TIMING_A_OFF() digitalWrite (TIMING_A_PIN, LOW)
#define TIMING_B_ON() digitalWrite (TIMING_B_PIN, HIGH)
#define TIMING_B_OFF() digitalWrite (TIMING_B_PIN, LOW)
#define TIMING_A_TOGGLE() digitalWrite (TIMING_A_PIN, !digitalRead (TIMING_A_PIN))
#define TIMING_B_TOGGLE() digitalWrite (TIMING_B_PIN, !digitalRead (TIMING_B_PIN))
#define TIMING_INIT()                                                                    \
  do {                                                                                   \
    pinMode (TIMING_A_PIN, OUTPUT);                                                      \
    pinMode (TIMING_B_PIN, OUTPUT);                                                      \
  } while (0)

#else
#error "timing.h: no markers for this platform; define TIMING_A_ON () etc. first"
#endif

/* The marker's pin high for the statement or block that follows */
#define TIMING_BLOCK(marker)                                                             \
  for (int timing_once_ = ((void) TIMING_##marker##_ON (), 1); timing_once_;             \
       timing_once_ = 0, TIMING_##marker##_OFF ())

#endif
