# Test signals for the scope's protocol decoding and code timing, on an Arduino Uno
# (ATmega328P, 16 MHz), in plain C with avr-gcc.  See README.md.
#
#   make                          build uart.hex, i2c.hex, spi.hex, timing.hex
#   make flash-uart               build and upload one (also flash-i2c, flash-spi,
#                                 flash-timing)
#   make flash-uart PORT=/dev/ttyACM1 DEFS="-DBAUD=9600 -DPARITY=2"
#   make format                   the sources in the style of .clang-format
#
# Needs avr-gcc, avr-libc and avrdude (apt install gcc-avr avr-libc avrdude).

MCU      := atmega328p
F_CPU    := 16000000UL
PORT     ?= /dev/ttyACM0
DEFS     ?=

CC       := avr-gcc
CFLAGS   := -mmcu=$(MCU) -DF_CPU=$(F_CPU) -Os -std=gnu99 -Wall -Wextra $(DEFS)

PROGRAMS := uart i2c spi timing delay pwm irq_latency

.PHONY: all clean format $(addprefix flash-,$(PROGRAMS))

all: $(PROGRAMS:%=%.hex)

#  Options change the program, so rebuild when they do
.defs: FORCE
	@echo '$(DEFS)' | cmp -s - $@ || echo '$(DEFS)' > $@
FORCE:

%.elf: %.c timing.h .defs
	$(CC) $(CFLAGS) -o $@ $<
	avr-size $@

%.hex: %.elf
	avr-objcopy -O ihex -R .eeprom $< $@

$(addprefix flash-,$(PROGRAMS)): flash-%: %.hex
	avrdude -p m328p -c arduino -P $(PORT) -b 115200 -U flash:w:$<:i

format:
	clang-format -i $(PROGRAMS:%=%.c) timing.h

clean:
	rm -f *.elf *.hex .defs
