# Changelog

## Unreleased

- An About box in the GUI, with the version and a small animated scope
  screen; every program has --version, and the server's hello tells its
  version (in Python: Scope.server_version).
- Ready-made packages on the GitHub Releases page, for a Raspberry Pi
  (arm64) and for 64-bit PCs (amd64), built by GitHub Actions for every
  release.
- Every pull request and push to main is built and tested on GitHub.
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
