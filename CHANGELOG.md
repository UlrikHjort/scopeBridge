# Changelog

## Unreleased

- make checks what the build needs before building: without GtkAda it
  builds everything but the GUI, without GNATCOLL everything but the
  server and the terminal client, and it says what it left out.
  make deps-check tells what is missing and, on Debian and Ubuntu, the
  apt command to install it; make deps runs that command, after asking.
- The docs say what a point is.

## 1.2.0 - 2026-09-29

- Settings in ~/.scopebridgerc: [server] (the scope's source, port,
  listen address, web port) and [client] (where the server is), for every
  program; command-line options win over it. With [client] host set to a
  Raspberry Pi, a plain scopebridge opens the scope there. An example:
  contrib/scopebridgerc.example.
- scopebridge-server without a source looks for the scope on USB, and the
  service follows ~/.scopebridgerc.
- The web page has an About box too, with the version and the same
  animated scope screen as the GTK GUI's.
- Two more Arduino examples, with bench cases: pwm.c, PWM in hardware and
  in software side by side (jitter, outliers, harmonics), and
  irq_latency.c, the time from a hardware event to the interrupt's first
  line, with the outliers of a critical section.
- Fixed: both GUIs showed the values of a measurement still on its way
  after the measurements had been switched to another channel, or off.
- Fixed, in Python: Scope.single() returns once the scope has left the
  stopped state of an earlier acquisition, so that wait_for_trigger() can
  no longer mistake that for the new one and read an empty memory; an
  empty capture is now a clear error.
- The environment variables are SCOPEBRIDGE_HOST, SCOPEBRIDGE_PORT and
  SCOPEBRIDGE_WEB (before: RIGOL_HOST, RIGOL_PORT, RIGOL_WEB).

## 1.1.0 - 2026-09-28

- An About box in the GUI, with the version and a small animated scope
  screen; every program has --version, and the server's hello tells its
  version (in Python: Scope.server_version).
- Ready-made packages on the GitHub Releases page, for a Raspberry Pi
  (arm64) and for 64-bit PCs (amd64), built by GitHub Actions for every
  release.
- Every pull request and push to main is built and tested on GitHub, on
  Ubuntu 22.04 and 24.04.
- The docs say which addresses in examples are examples, and how to find
  your own, arp-scan included; lan_demo now needs the scope's address.

## 1.0.0 - 2026-09-27

The first release. Developed and tested on a Rigol DS1202Z-E (firmware
00.06.04); see the README's *Compatibility* for other models.

- **An Ada library** for the Rigol DS1000Z-E: strongly typed SCPI for
  channels, timebase, triggers (edge, pulse, slope), acquisition,
  measurements, math, pass/fail, bus decoders, waveform and memory reads
  and screenshots, over USB (USBTMC) or LAN, with a simulated scope and a
  mock transport for tests.
- **scopebridge-server**, which owns the scope and serves it over a
  documented protocol (JSON lines over TCP, and WebSocket for browsers),
  to several clients at once. It adds FFTs of the whole memory, zooming
  through millions of points, UART, I2C and SPI decoding of captures, code
  timing (statistics and histograms of blocks a program marks on a pin),
  and reference waveforms.
- **Clients**: scopebridge-gui (GtkAda), a web interface for any browser,
  scopebridge-term (a terminal client), Python scripting with a runner and
  session replay, and a small tkinter GUI.
- **Raspberry Pi**: the server on a Pi with the scope on its USB; a
  cross-built, ready-to-install package (contrib/cross-build.sh), tried on
  a Pi 4 and a Pi 3 up to 24M-point captures.
- **Arduino Uno examples** in plain C: UART, I2C and SPI test signals,
  code timing with markers for any microcontroller (timing.h), a
  known-delay check, and an automated test bench that flashes the Uno and
  checks it with the scope.
- Installing with make install, a systemd user service, a udev rule for
  USB access without root, man pages, a user manual and the protocol
  specification.
