# ScopeBridge

Remote control of oscilloscopes from Linux, in Ada: at present the Rigol
DS1000Z-E, over USB or the network. **Developed and tested on a Rigol DS1202Z-E (firmware
00.06.04) only**; see [Compatibility](#compatibility) for other models.

![The GtkAda GUI with a live 1 kHz square wave](docs/images/overview.png)

The [user manual](docs/MANUAL.md) walks through every function with
examples and screenshots.

- **An Ada library** (`src/`) with strongly typed SCPI commands:
  channels, timebase, trigger, acquisition, measurements, the math
  channel, the pass/fail test, the bus decoders, waveform and memory
  reads, screenshots.
- **`scopebridge-server`**, which owns the scope connection and serves
  it over a documented protocol ([docs/PROTOCOL.md](docs/PROTOCOL.md)):
  JSON lines over TCP, with binary payloads for waveform data. It adds
  what the scope cannot do on its own: FFTs of the whole acquisition
  memory, zooming through millions of points, decoding UART, I2C and SPI
  traffic from the whole capture, timing code (every run of a block a
  program marks on a pin: statistics, histogram, the slowest run), and
  reference waveforms shared by all clients.
- **`scopebridge-gui`**, a GtkAda front end: live view, all common controls
  (edge, pulse and slope triggers), measurements (recordable to CSV),
  cursors, math and FFT, an XY display, pass/fail testing, reference
  waveforms, bus decoding with a list of the decoded bytes, code timing
  with a histogram, full-memory capture with zoom and pan, setups saved to
  files, screenshots and CSV export.
- **Python scripting** (`clients/python/scopebridge.py`): a small API for
  automating measurements, captures and logging, alongside the GUI.
- **`scopebridge-term`**, a terminal client in Ada: an interactive command line
  with a live waveform drawn in characters; commands can also be piped in.
- **A web interface**: `scopebridge-server --web 8080` serves a page that any
  browser, on any computer, tablet or phone, can use as its GUI, with what
  `scopebridge-gui` has: live view and captures, math, FFT, cursors, bus
  decoding, code timing, references, pass/fail, setups and files.
- **A second, small GUI in Python/tkinter** (`clients/python/scopebridge_tk.py`),
  showing that any front end can use the server, even next to the first.
- **On a Raspberry Pi**: the server can run on a small computer the scope
  hangs off, with the GUIs, scripts and browsers anywhere on the network;
  `contrib/cross-build.sh` makes a ready-to-install package for it.
- **Microcontroller examples** (`examples/arduino/`): UART, I2C and SPI
  test signals and code timing on an Arduino Uno in plain C, markers for
  timing code on any microcontroller (`timing.h`), and an automated test
  bench that flashes the Uno and checks it with the scope.

```
 scopebridge-gui  --+                                      +-- USB (/dev/usbtmcN)
 Python     --+-- TCP 127.0.0.1:5026 -- scopebridge-server --+
 scripts    --+   docs/PROTOCOL.md                     +-- LAN (port 5555)
```

## Requirements

- GNAT (tested with GNAT 10) and gprbuild
- GNATCOLL, for the server: `libgnatcoll19-dev` on Ubuntu 22.04 (the
  number varies with the release: `apt search libgnatcoll`)
- GtkAda, for the GUI: `sudo apt install libgtkada20-dev`
- Python 3, for the protocol tests and scripts

## Building

```
make                  # everything, into bin/
make check            # library tests against a mock transport
make check-server     # FFT, decoding and timing tests, then the protocol,
                      # scripting, terminal and web tests on the simulated scope
make check-web        # the web page in headless Firefox (needs Firefox)
```

None of the checks needs an instrument.

### Installing

```
make                              # as yourself
sudo make install                 # into /usr/local; or PREFIX=...
```

This installs `scopebridge-server`, `scopebridge-gui`, `scopebridge-term`, `scopebridge` (the
start script), `scopebridge-run` (the Python runner) and `scopebridge-tk`, man pages
for them, the Python module (in `share/scopebridge/python`), this README, the
manual and the protocol (in `share/doc/scopebridge`), and a systemd user unit
that keeps a server running:

```
mkdir -p ~/.config/scopebridge
echo 'SCOPEBRIDGE_SERVER_ARGS=--lan 192.168.0.83' > ~/.config/scopebridge/server.conf
systemctl --user enable --now scopebridge-server    # default: --usb auto
```

**The addresses in the examples are examples**, from one network:
`192.168.0.83` is the scope, `192.168.0.19` a Raspberry Pi. Use your own:
the scope shows its address under Utility -> IO Setting -> LAN Conf, and
`hostname -I` shows a Linux computer's, a Pi's for instance. Or find them
from any computer on the network: `sudo arp-scan --localnet` (`sudo apt
install arp-scan`) lists every device with its maker, a Rigol scope as
"Rigol Technologies, Inc." and a Pi as "Raspberry Pi Trading Ltd" or
"Raspberry Pi Foundation":

```
$ sudo arp-scan --localnet
192.168.0.83    00:19:af:xx:xx:xx    Rigol Technologies, Inc.
```

With the service running, `scopebridge`, `scopebridge-term` and scripts connect to it
straight away. For a `PREFIX` in your home directory, add
`SYSTEMD_USER_DIR=~/.config/systemd/user`. `make uninstall` (with the same
`PREFIX`) removes it all again; `DESTDIR` is honoured for packaging.

## Running

```
./scopebridge.sh                     # finds the scope on USB, starts server and GUI
./scopebridge.sh --lan 192.168.0.83  # over the network
./scopebridge.sh --sim               # a simulated scope, no hardware
```

`scopebridge.sh` stops the server when the GUI closes. If a server is already
running on the port, the GUI connects to it and leaves it running. The
parts can also be started separately:

```
./bin/scopebridge-server --usb auto             # or --usb /dev/usbtmcN, --lan HOST[:PORT], --sim
./bin/scopebridge-gui                            # connects to 127.0.0.1:5026
```

Any number of clients can use one server at once, for example the GUI and
a script, or both GUIs (`clients/python/scopebridge_tk.py` is the small one).

### The web interface

```
./bin/scopebridge-server --usb auto --web 8080       # then open http://localhost:8080/
./scopebridge.sh --web 8080                           # the same, with the GUI
```

The page is a GUI for any browser, laid out for a desktop or a phone, with
the desktop GUI's functions: live view and captures with zoom and pan,
triggers, measurements and recording, math and FFT, cursors, XY, bus
decoding, references, pass/fail, setups, screenshots and CSV export
(files go to and from the browser's computer). With `--listen 0.0.0.0`
other computers can open it at `http://this-computer:8080/`. Several
browsers and the other clients can use the server at the same time. It
has the same lack of security as the protocol: on a network you do not
trust, use an SSH tunnel (see the Raspberry Pi section).
The server listens on 127.0.0.1 unless given `--listen ADDRESS`. The
protocol has no authentication, so only expose it on a network you trust.

### The terminal client

```
./bin/scopebridge-term                  # with a server running
scopebridge> ch 1 scale 500m coupling dc
scopebridge> measure 1 freq vpp vrms
  freq 1.00 kHz   vpp 3.10 V   vrms 2.09 V
scopebridge> watch 1                    # live, in characters; Enter stops
scopebridge> capture 1
scopebridge> save capture.csv
scopebridge> spectrum 1 flattop         # the strongest lines
scopebridge> help
```

Numbers take SI suffixes (`500m`, `2u`, `1k`). Piped commands run as a
script (`scopebridge-term < commands.txt`); the exit status is 1 if any failed.

### USB access

The scope appears as `/dev/usbtmcN`, readable by root only. A udev rule
(`contrib/70-rigol.rules.in`) gives the `plugdev` group access, and the
user logged in at the computer:

```
sudo make install-udev
```

This installs `/etc/udev/rules.d/70-rigol.rules`, makes the group if the
system has none (Fedora, Arch), and applies the rule to a scope that is
already connected. It also says whether you are in the group; if not:

```
sudo usermod -aG plugdev $USER    # then log out and in again
```

Check with the scope connected and on:

```
$ ls -l /dev/usbtmc*
crw-rw----+ 1 root plugdev 180, 176 ... /dev/usbtmc0
$ groups                          # should list plugdev
```

If the device is still `root root`, unplug the scope's USB cable and
plug it in again. `UDEV_GROUP=dialout` (or any group) uses another group;
`sudo make uninstall-udev` removes the rule. A rule written by hand
earlier as `99-rigol.rules` is replaced.

### LAN

The scope listens for SCPI on TCP port 5555; its address is shown under
Utility -> IO Setting -> LAN Conf.

If the connection breaks (the scope switched off and on, the network gone
for a moment), the request it happens in fails and the next one connects
again.

### The server on another computer (a Raspberry Pi)

The scope can hang off a small computer, such as a Raspberry Pi 3 or 4,
that runs only the server; the GUI, the terminal client, scripts and
browsers then run on any computer on the network, several at once.
Running everything on one computer stays exactly as it is.

#### Installing from a package, with no compiler on the Pi

**1. Build the package, on this computer.** Which one the Pi needs,
`dpkg --print-architecture` on the Pi tells: `arm64` (64-bit) or `armhf`
(32-bit).

```
contrib/cross-build.sh                  # arm64: 64-bit Raspberry Pi OS, 64-bit Ubuntu
contrib/cross-build.sh --arch armhf     # armhf: 32-bit Raspberry Pi OS (Pi 2, 3, 4)
```

This makes `dist/scopebridge-VERSION-arm64.tar.gz` (or `-armhf`), about 3 MB,
in a few minutes. The programs in it need nothing on the Pi but its C
library (glibc 2.17 or later), so one arm64 package serves several
systems: it has run on Raspberry Pi OS 11 and Ubuntu 22.04 (see *Tried
on*), and should on Raspberry Pi OS 12 too. The first run fetches the build system,
about 80 MB, into `~/.cache/scopebridge-cross`.

**2. Copy it over**, to your home folder on the Pi, with your user name
and the Pi's address there (`hostname -I` on the Pi shows it; here and
below it is `192.168.0.19`). The `:` at the end is what makes it the Pi's;
without it scp copies to a local file named `user@...`:

```
scp dist/scopebridge-*-arm64.tar.gz user@192.168.0.19:
```

**3. Install it, on the Pi:**

```
tar -xzf scopebridge-*-arm64.tar.gz
cd scopebridge-*-arm64
sudo ./install.sh
```

This installs under `/usr/local`: `scopebridge-server`, `scopebridge-term`, the web
interface, the Python client (`scopebridge-run`), man pages, a systemd user
service, and the udev rule that lets the scope on USB be used without
root. If it says you are not in the `plugdev` group yet: `sudo usermod
-aG plugdev $USER`, and log in again.

**4. Start the server as a service**, as yourself (not root), with the
scope on USB and the web interface on port 8080:

```
mkdir -p ~/.config/scopebridge
echo 'SCOPEBRIDGE_SERVER_ARGS=--usb auto --listen 0.0.0.0 --web 8080' > ~/.config/scopebridge/server.conf
systemctl --user daemon-reload
systemctl --user enable --now scopebridge-server
sudo loginctl enable-linger $USER       # start it at boot, without a login
```

**5. Check it**, on the Pi and from another computer:

```
systemctl --user status scopebridge-server    # on the Pi: active (running)
journalctl --user -u scopebridge-server       # its messages, if not
scopebridge-term --host 192.168.0.19          # elsewhere: then scpi *IDN? or status
```

and `http://192.168.0.19:8080/` in a browser. A reboot of the Pi is a good
last test: the service should come back by itself.

**Updating** to a newer package: `sudo ./uninstall.sh` in the old
package's folder, then steps 2 and 3 with the new one, and `systemctl
--user restart scopebridge-server`; the settings in `~/.config/scopebridge` stay.
**Removing**: `systemctl --user disable --now scopebridge-server`, then `sudo
./uninstall.sh`.

How the package is made: `contrib/cross-build.sh` builds in a small root
of the Pi system's own Debian packages (GNAT, gprbuild, GNATCOLL), checked
against Debian's archive keys, run under qemu in a bubblewrap sandbox;
no root is needed. It needs a Debian or Ubuntu computer with `sudo apt
install qemu-user-static binfmt-support bubblewrap`, and builds the
committed sources (`git archive HEAD`). `make package` packs a build the
same way for the computer it runs on.

#### Or build on the Pi

With a compiler on the Pi (Raspberry Pi OS or Ubuntu, 32 or 64 bit), steps
1 to 3 become:

```
sudo apt install gnat gprbuild libgnatcoll19-dev   # the number varies:
                                                    # apt search libgnatcoll
make server term                  # the server and terminal client; no GtkAda
sudo make install
sudo make install-udev            # USB access for the plugdev group
```

and step 4 is the same.

#### Using it from other computers

```
scopebridge --host 192.168.0.19                # the GUI
scopebridge-term --host 192.168.0.19
scopebridge-run --host 192.168.0.19 script.py
# or a browser, also on a phone or tablet: http://192.168.0.19:8080/
```

A name such as `raspberrypi.local` works as well as the address, where
the network resolves it.

The protocol has no password or encryption: anyone who can reach the port
can use the scope. On your own network that is usually fine; otherwise
keep the server on 127.0.0.1 (leave out `--listen`) and reach it through
SSH, which also works from outside:

```
ssh -N -L 5026:127.0.0.1:5026 user@192.168.0.19 &
scopebridge-gui                                      # through the tunnel
```

#### Tried on

Both from the same arm64 package, the DS1202Z-E on the Pi's USB, the
clients on a PC on the network, and each through a reboot:

- **Raspberry Pi 4**, 64-bit Raspberry Pi OS 11: a 2.4M-point memory
  capture in 3.7 s (654 kpoints/s, close to what the scope's USB gives a
  PC directly), the spectrum of all of it, computed on the Pi, in 0.8 s,
  a screenshot in 1.3 s.
- **Raspberry Pi 3** (1 GB), 64-bit Ubuntu MATE 22.04, up to the scope's
  largest memory:

  | Capture     | Reading it from the scope | Its spectrum, on the Pi 3 |
  |-------------|---------------------------|---------------------------|
  | 1.2M points | 1.9 s                     | 1.3 s                     |
  | 12M points  | 16.5 s                    | 1.6 s                     |
  | 24M points  | 32.8 s (733 kpoints/s)    | 1.9 s                     |

The scope's USB sets the pace, the same as on a PC. Not tried: 32-bit
Raspberry Pi OS (`--arch armhf`; the USB transport adapts to 32-bit
systems), and building for Raspberry Pi OS 12 (`--suite bookworm`), which
also needs a build computer whose `debian-archive-keyring` knows
bookworm's keys (Debian 12, Ubuntu 24.04 or later); the bullseye
package should run on it as it is.

## Scripting

Scripts are Python, using the `scopebridge` module. Several scripts and the GUI
can use the server at the same time.

```python
from scopebridge import Scope

with Scope() as scope:
    scope.channel(1, scale=0.5, coupling="dc")
    for n in range(10):
        scope.single()
        scope.wait_for_trigger()
        cap = scope.capture(1)                 # the whole acquisition memory
        cap.save_csv(f"run_{n}.csv")
        print(scope.measure(1, "freq", "vpp"), cap.spectrum().peak())
    scope.record("log.csv", items=("freq", "vpp"), interval=1, duration=3600)
```

Run a script with `clients/python/scopebridge_run.py`, which can also start an
server for it:

```
clients/python/scopebridge_run.py script.py                  # server already running
clients/python/scopebridge_run.py --lan 192.168.0.83 script.py
clients/python/scopebridge_run.py --sim script.py
```

`Scope` offers `run`, `stop`, `single`, `wait_for_trigger`, `channel`,
`timebase`, `trigger` (and `pulse_trigger`, `slope_trigger`,
`edge_trigger`), `math`, `acquire`, `save_setup`, `load_setup`, `status`, `measure`, `screen`, `capture`
(with `volts`, `times`, `save_csv`, `spectrum`), `screenshot`, `record`
(measurements to CSV at an interval), `mask` (pass/fail), `ref_save`,
`ref`, `refs`, `ref_load`, `ref_clear` (references), `decode` and `text`
(bus decoding of captures), `bus` (the scope's own decoder), `timing` and
`timing_report` (code timing) and `scpi`;
`request` sends any request of the protocol. Examples in `examples/scripts/`:

| Script              | Does                                                  |
|---------------------|-------------------------------------------------------|
| `measure_log.py`    | measurements to CSV at an interval, until stopped     |
| `capture_series.py` | a series of single-shot captures saved to disk        |
| `harmonics.py`      | harmonic levels from a full-memory spectrum           |
| `timebase_sweep.py` | measurements and a screenshot at several timebases    |

`examples/arduino/` has test programs for an Arduino Uno (UART, I2C, SPI)
and `bench.py`, an automated test bench: it flashes each program, has the
scope capture and decode it, checks the bytes and measures the timing,
and writes a report with the scope's screenshots. It also has
`timing.h`, markers for timing code with the scope on AVR, STM32,
RP2040, ESP32 or any Arduino board, `timing.c`, an example of it, and
`delay.c`, which checks the timing against a known delay.

### Session log and replay

`scopebridge-server --log session.jsonl` records every request and reply of
every client, with timestamps. A log can be replayed, which repeats what
was done in the GUI or by a script:

```
clients/python/scopebridge_run.py --replay session.jsonl [--client N] [--timing]
```

## The library

```ada
with Ada.Text_IO;  use Ada.Text_IO;
with Rigol, Rigol.Channel, Rigol.Measure;
with Rigol_Transport.USBTMC;

procedure Example is
   T     : aliased Rigol_Transport.USBTMC.Handle;
   Scope : Rigol.Oscilloscope (T'Access);
begin
   Rigol_Transport.USBTMC.Open (T, "/dev/usbtmc0");
   Rigol.Channel.Set_Scale (Scope, 1, 0.5);
   Put_Line (Float'Image (Rigol.Measure.Frequency (Scope, 1)));
end Example;
```

Transports: `Rigol_Transport.USBTMC`, `Rigol_Transport.LAN`,
`Rigol_Transport.Simulator` (a simulated scope) and `Rigol_Transport.Mock`
(for tests). See `examples/` for complete programs.

## Behaviour of the instrument worth knowing

Found while bringing the library up on real hardware, and handled by it:

- USB transfers longer than 512 bytes come back partly overwritten, so the
  USB transport requests at most 500 bytes per transfer. The kernel's
  plain `read()` also loses everything after the first 52 bytes of a
  reply, so the transport frames USBTMC itself.
- Clearing the USB device (`USBTMC_IOCTL_CLEAR`) right after the scope has
  booted locks up its USB interface until it is power-cycled.
- Every setting command delays the scope's next reply by about 50 ms, and
  it keeps at most 5 measurements armed; a sixth, or another channel, costs
  about half a second per query. The server sends only settings that change.
- Over LAN, a query the scope does not know is answered with
  `Command error` and no line terminator.
- Screenshots: BMP24 and JPEG are valid files; PNG has wrong CRCs on its
  text chunks, BMP8 a wrong size field.
- The scope's own setup block (`:SYSTem:SETup`) restores only part of the
  setup: the timebase, but not the channels' scales, and the trigger level
  is not saved in it at all. The server's setups add the settings it knows
  and set them after the block.
- A setting the scope ignores (such as a memory depth it does not offer
  for the channels on) queues an error whose `:SYSTem:ERRor?` gets no
  reply at all; the query after that works again.
- Changing a channel's V/div scales its trigger level with it: the level
  keeps its place on the screen (1.5 V at 0.5 V/div becomes 3 V at
  1 V/div). Set the level after the scale.
- Memory depths depend on the number of channels on (12k ... 24M points with
  one, 6k ... 12M with two), and the scope converts the depth when that
  number changes. It ignores a change of depth while stopped.

## The programming guide

The implementation follows Rigol's **DS1000Z-E Programming Guide**,
publication number PGA27100-1110 (2019, for software version 00.06.01).
It is RIGOL's copyrighted document and is not included here; the current
edition is available from Rigol:

<https://rigoltechnologies.com/wp-content/uploads/2026/07/DS1000ZE_ProgrammingGuide_EN.pdf>

(publication number PGA27101-1110, software version 00.06.02, at the time
of writing). A local copy may be kept in `docs/vendor/`, which Git ignores.

## Compatibility

Everything here was developed and tested against one instrument: a
**Rigol DS1202Z-E**, firmware 00.06.04, over USB and LAN, on Linux
(GNAT 10). Several of the instrument's behaviours the code works around
(listed above) were found by testing on it and are not in the
programming guide, so other models may behave differently.

| Model | Expectation |
|-------|-------------|
| DS1202Z-E | Tested. |
| DS1102Z-E | Should work: same series, firmware and commands. Untested. |
| DS1000Z (DS1054Z, DS1074Z, DS1104Z, Plus models) | Largely the same commands, but 4 channels: the library, protocol and GUIs handle channels 1 and 2 only. The USB quirks are likely shared but unverified. Expect partial use without changes. |
| MSO1000Z | As DS1000Z for the analog channels; digital channels are not supported. |
| Other Rigol families (DS2000, DS4000, MSO5000, DHO, ...) | Not expected to work: their commands, data formats and quirks differ in many places. |

Verified on the DS1202Z-E, each over USB or LAN or both (both transports
are verified in full; above them, the code is the same either way):

- the library: settings, measurements, screen and memory reads (up to
  24M points), screenshots, error recovery;
- the server and all its clients (both GUIs, the terminal client, Python
  scripting, the web page, several at once): live view, captures, math and
  FFT (the scope's and the server's), cursors, XY, edge, pulse and slope
  triggers, acquisition modes and memory depths, setups (with the restore
  over USB), pass/fail, references;
- bus decoding and the scope's own bus decoders, on real UART, I2C and SPI
  signals, and code timing, checked against a delay of known length, all
  with the Arduino test bench (over USB);
- the server on a Raspberry Pi 4 and a Pi 3, with the scope on their USB.

The simulator (`--sim`) imitates the DS1202Z-E as found, and is what
the automated tests run against.

Reports from other models are welcome; the simulator and the tests make
it easy to see what differs.

## Layout

| Path              | What                                                   |
|-------------------|--------------------------------------------------------|
| `src/`            | the library                                            |
| `examples/`       | `basic_demo`, `lan_demo`, `capture_demo`; `scripts/` (Python); `arduino/` (test signals, code timing, the test bench) |
| `server/`         | `scopebridge-server`, its FFT, bus decoding and code timing, their tests |
| `gui/`            | `scopebridge-gui`                                            |
| `term/`           | `scopebridge-term`, the terminal client                      |
| `web/`            | the web interface (HTML, CSS, JavaScript)              |
| `clients/python/` | `scopebridge.py` (scripting), `scopebridge_client.py` (protocol), `scopebridge_run.py`, `scopebridge_tk.py` (tkinter GUI) |
| `docs/`           | the protocol, the manual and its images, man pages     |
| `contrib/`        | the systemd user unit, the udev rule, the Raspberry Pi cross build and packaging |
| `tests/`          | library tests (Ada); protocol, scripting, terminal and web tests (Python) |

## License

MIT; see [LICENSE](LICENSE). Copyright (C) 2026 Ulrik Hørlyk Hjort.
