# ScopeBridge protocol, version 1

Developed and tested with a Rigol DS1202Z-E (firmware 00.06.04); see the
README for other models.

`scopebridge-server` owns the connection to the oscilloscope and serves it over
TCP to any number of clients at once: a GUI and scripts can work side by
side. Any program that speaks this protocol can drive the scope; the GtkAda
GUI is one such client.

```
scopebridge-server --usb /dev/usbtmc4        # or --usb auto, --lan 192.168.1.50, --sim
             [--port 5026] [--listen 127.0.0.1] [--log FILE]
             [--web PORT [--web-root DIR]]
```

`--log` writes a command log: a JSON line with a timestamp for every
connection, request and reply, of every client (replies without their
binary payload, whose size `bytes` gives). Its requests can be replayed.

`--sim` runs against a built-in simulated scope (a 1 kHz square wave on CH1,
a sine on CH2), for developing and testing clients without hardware. For
testing bus decoding, the SCPI command `:SIMulator:SIGNal UART` (or `IIC`,
`SPI`, `NORMal`), sent with `scpi`, puts serial traffic on its channels
instead, and `TIMing` markers for `timing`; see
`src/rigol_transport-simulator.ads` for what they carry.

The server listens on 127.0.0.1 unless `--listen` says otherwise. The
protocol has no authentication; only expose it on a network you trust.

`--web PORT` also serves browsers, on that port at the same address: the
files of the browser client (`web/`, or `--web-root DIR`) over HTTP, and
this protocol over WebSocket at `/ws` (see *Browsers* below).

## Framing

Every message in either direction is one JSON object on one line, ended by
`\n`. A message from the server that carries binary data has a `"bytes": N`
member; exactly N raw bytes follow its newline, then the next message
starts.

Client messages are requests. Server messages are either replies or events.

```
client -> server   {"id": 7, "cmd": "set_channel", "ch": 1, "scale": 0.5}
server -> client   {"id": 7, "ok": true}
server -> client   {"id": 8, "ok": false, "error": "ch must be 1 or 2"}
server -> client   {"event": "frame", "ch": 1, ..., "bytes": 1200}<1200 bytes>
```

- `id` is chosen by the client (an integer) and copied into the reply.
- Requests are executed one at a time, in the order received from all
  clients together. Every request gets exactly one reply, sent to the
  client that made it.
- Events have no `id` and may arrive between replies at any time.
- A value the scope cannot measure is sent as `null`.
- Unknown members in a request are ignored; unknown `cmd` values get an
  error reply. Clients must ignore unknown members and events, so the
  protocol can grow.

## Browsers

Over the WebSocket at `ws://HOST:PORT/ws` the messages are the same, one
per WebSocket message: a request or a reply or event is a text message
holding the JSON object (without the line end), and a message with
`"bytes": N` is followed by a binary message holding the N bytes. Requests
must be text messages; the server ignores binary ones. A browser client is
a client like the others: it gets the `hello` event, may subscribe to live
mode, and shows in the command log.

```js
const ws = new WebSocket("ws://raspberrypi.local:8080/ws");
ws.binaryType = "arraybuffer";
ws.onopen = () => ws.send(JSON.stringify({id: 1, cmd: "status"}));
ws.onmessage = (m) => console.log(m.data);   // text, or an ArrayBuffer
```

## Waveform data

Samples always travel as the scope's raw 8-bit values, with the scaling
needed to turn them into volts and seconds. A block of waveform data is
described by these members:

| member     | meaning                                     |
|------------|---------------------------------------------|
| `points`   | number of samples                           |
| `x_inc`    | seconds between samples                     |
| `x_origin` | time of the first sample, s                 |
| `y_inc`    | volts per count                             |
| `y_origin` | count offset                                |
| `y_ref`    | count at the vertical reference             |

```
volts(raw)  = (raw - y_ref - y_origin) * y_inc
time(i)     = x_origin + i * x_inc          (i = 0 for the first sample)
```

## Math and spectrum data

Computed values (math results and spectra) travel as float32 values,
least significant byte first, 4 bytes each.

A spectrum is described by these members:

| member      | meaning                                              |
|-------------|------------------------------------------------------|
| `points`    | number of values                                     |
| `f0`        | frequency of the first value, Hz                     |
| `df`        | Hz between values                                    |
| `bin_width` | frequency resolution of the transform (RBW), Hz      |
| `unit`      | `"dBV"` (dB relative to 1 V RMS) or `"Vrms"`         |
| `window`    | window function: `"rect"`, `"hann"`, `"hamming"`, `"blackman"`, `"flattop"` (and `"triangle"` for the scope's FFT) |

```
f(i) = f0 + i * df          (i = 0 for the first value)
```
A sine of amplitude 1 V shows as -3.0 dBV at its frequency. The level of a
frequency between two bins drops by up to 1.4 dB with `hann` (3.9 dB with
`rect`); `flattop` reads levels within 0.1 dB at a coarser resolution.

Math and spectra come from one of two places, given by `"source"`:
`"scope"`, the scope's math channel (see `set_math`), which is either an
algebraic result or an FFT; or `"server"`, computed by the server from the
data it reads. The server's FFT works on captures too, where it resolves
about 1 / duration of the capture (see `spectrum`).

## Events

### `hello`
Sent once when a client connects. `client` numbers the connection, as in
the command log.
```
{"event": "hello", "protocol": 1, "idn": "RIGOL TECHNOLOGIES,DS1202Z-E,...",
 "source": "usb:/dev/usbtmc4", "client": 1}
```

### `frame`
In live mode, one per displayed channel per update: the waveform currently
on screen (normally 1200 points). An update may skip a channel for which
the scope has no screen data at that moment. Carries the waveform members above and
`"bytes": points`, followed by the samples.
```
{"event": "frame", "ch": 1, "points": 1200, "x_inc": 1e-05, "x_origin": -0.006,
 "y_inc": 0.04, "y_origin": 0, "y_ref": 127, "bytes": 1200}
```

### `measure`
In live mode, once per update, for one channel and the chosen items (see
`live`).
```
{"event": "measure", "ch": 1, "freq": 1000.0, "vpp": 3.12, "vrms": 2.08}
```
Item names and units:

| item     | meaning               | unit |
|----------|-----------------------|------|
| `freq`   | frequency             | Hz   |
| `period` | period                | s    |
| `vpp`    | peak to peak          | V    |
| `vmax`   | maximum               | V    |
| `vmin`   | minimum               | V    |
| `vtop`   | top (flat high level) | V    |
| `vbase`  | base (flat low level) | V    |
| `vamp`   | amplitude, top - base | V    |
| `vavg`   | average               | V    |
| `vrms`   | RMS                   | V    |
| `rise`   | rise time, 10 - 90 %  | s    |
| `fall`   | fall time, 90 - 10 %  | s    |
| `pwidth` | positive pulse width  | s    |
| `nwidth` | negative pulse width  | s    |
| `pduty`  | positive duty cycle   | fraction, 0.5 = 50 % |
| `nduty`  | negative duty cycle   | fraction |

`null` when the scope cannot measure the item, e.g. a rise time too short
for the timebase.

### `math`
In live mode with `scope_math` or `math` (see `live`): the math result for
this update, as float32 values in `unit` (`"V"`, or `"V^2"` for `mul`).
Carries `points`, `x_inc` and `x_origin` like a frame.
```
{"event": "math", "source": "server", "operator": "add", "points": 1200,
 "x_inc": 1e-05, "x_origin": -0.006, "unit": "V", "bytes": 4800}
```
`operator` is `add`, `sub`, `mul`, or for the scope's math also `div` (and
`other` for operations this protocol does not set). The scope's math
channel reads as empty for one to three seconds after its operator
changes; no `math` events are sent meanwhile.

### `spectrum`
In live mode with `scope_math` (when the scope's math operator is `fft`) or
`spectrum` (see `live`): a spectrum, with the members listed under *Math
and spectrum data* and `ch`, the channel transformed.
```
{"event": "spectrum", "source": "server", "ch": 1, "points": 513,
 "f0": 0, "df": 97.66, "bin_width": 97.66, "unit": "dBV", "window": "hann",
 "bytes": 2052}
```
The server transforms the channel's screen frame (1200 points, so a
1024-point FFT). The scope's FFT covers the part of its FFT screen at or
above 0 Hz, at its own resolution (see `set_math` for its settings).

### `progress`
During `capture`, after each batch read from the scope; to the client
that asked for the capture.
```
{"event": "progress", "done": 750000, "total": 6000000}
```

### `refs`
The reference waveforms changed (see `ref_save`); sent to every client,
live or not. Fetch them again with `refs` and `ref`.
```
{"event": "refs"}
```

### `error`
Something failed outside a request, typically the live loop losing the
scope. Sent to the clients in live mode, whose live mode is switched off.
```
{"event": "error", "error": "USB-TMC read failed or timed out"}
```

## Requests

Optional members are marked `?`. A setter changes only the members given.

### Acquisition

| cmd      | members | effect                              |
|----------|---------|-------------------------------------|
| `run`    |         | start continuous acquisition        |
| `stop`   |         | stop acquisition                    |
| `single` |         | arm a single acquisition            |
| `auto`   |         | autoscale                           |
| `force`  |         | force a trigger                     |

### `status`
The scope's current settings, for initialising a client's controls.
```
{"id": 1, "ok": true,
 "trigger_status": "td",
 "channels": [
   {"ch": 1, "display": true, "scale": 1.0, "offset": 0.0,
    "coupling": "dc", "probe": 10},
   {"ch": 2, "display": false, ...}],
 "timebase": {"scale": 0.001, "offset": 0.0, "mode": "yt"},
 "trigger": {"source": "ch1", "slope": "rising", "level": 1.5,
             "sweep": "auto", "mode": "edge"},
 "acquire": {"type": "normal", "averages": 2, "memory_depth": 0,
             "sample_rate": 1e9},
 "math": {"display": false, "operator": "add", "source1": "ch1",
          "source2": "ch2", "scale": 1.0, "offset": 0.0,
          "fft_source": "ch1", "fft_window": "rect", "fft_unit": "db",
          "fft_mode": "trace", "fft_hscale": 5000.0, "fft_hcenter": 25000.0},
 "mask": {"enable": true, "running": true, "passed": 151, "failed": 0,
          "total": 151}}
```
`trigger_status` is one of `td`, `wait`, `run`, `auto`, `armed`, `stop`.
`trigger.mode` is `edge`, `pulse`, `slope` (or `other` for modes set on the
scope that this protocol does not cover). `source`, `slope` and `level` are
the edge trigger's; in pulse or slope mode, `trigger` also has a `pulse` or
`slope_trigger` object with that mode's settings (see `set_trigger`).
`math` is the scope's math channel; see `set_math`. `acquire` is the
acquisition, see `set_acquire`; `sample_rate` is in Sa/s. `timebase.mode` is
`yt`, `xy` or `roll`. `mask` is the pass/fail test (see `set_mask`): just
`{"enable": false}` while it is off.

### `set_channel`
`ch`, and any of `display?` (bool), `scale?` (V/div), `offset?` (V),
`coupling?` (`"ac"`, `"dc"`, `"gnd"`), `probe?` (0.01, 0.02, 0.05, 0.1,
0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000). A request with an
invalid member changes nothing.

### `set_timebase`
Any of `scale?` (s/div), `offset?` (s), `mode?` (`"yt"`, `"xy"`, `"roll"`).
In XY mode the scope's screen reads and measurements return nothing
useful (DS1202Z-E): to show CH1 against CH2, keep the scope in YT and plot
the two channels' frames against each other, as the GUI does.

### `set_acquire`
Any of:

| member          | values                                                    |
|-----------------|-----------------------------------------------------------|
| `type?`         | `"normal"`, `"average"` (of `averages` frames), `"peak"` (peak detect: the highest and lowest sample of each interval, so glitches show at slow timebases), `"hires"` (high resolution: averaged samples, less noise) |
| `averages?`     | 2, 4, 8, ... 1024                                           |
| `memory_depth?` | points per acquisition, or 0 for automatic               |

The depths offered depend on the channels on: 12000, 120000, 1200000,
12000000 or 24000000 with one channel, 6000, 60000, 600000, 6000000 or
12000000 with both. The scope ignores any other depth, silently; the
server refuses it and says which are offered. The scope also ignores a
change of depth while it is stopped (as after a `capture`); the server
refuses that too: `run` first. When a channel is switched
on or off the scope moves the depth to the other list's equivalent
(120000 with one channel becomes 60000 with two). A fixed depth decides
the sample rate: depth / (12 * timebase), up to 1 GSa/s with one channel,
500 MSa/s with two. A request with an invalid member changes nothing.

### `set_trigger`
Any of:
- `mode?`: `"edge"`, `"pulse"` or `"slope"`.
- `sweep?`: `"auto"`, `"normal"`, `"single"`.
- For the edge trigger: `source?` (`"ch1"`, `"ch2"`, `"ac"`, `"ext"`),
  `slope?` (`"rising"`, `"falling"`, `"either"`), `level?` (V).
- `pulse?`, an object for the pulse width trigger: `source?` (`"ch1"`,
  `"ch2"`), `when?`, `width?` (s, for the greater and less conditions),
  `lower?`, `upper?` (s, for the range conditions), `level?` (V).
- `slope_trigger?`, an object for the slope trigger, which fires on the
  time the signal takes between two levels: `source?`, `when?`, `time?`,
  `lower?`, `upper?` (s), `window?` (`"a"`, `"b"`, `"both"`: which levels
  follow `level_a`/`level_b`), `level_a?`, `level_b?` (V).

`when` is `"pos_greater"`, `"pos_less"`, `"neg_greater"`, `"neg_less"`
(the positive or negative pulse width, or the rising or falling slope time,
greater or less than `width`/`time`), `"pos_in_range"` or
`"neg_in_range"` (between `lower` and `upper`). The server sets a range in
an order the scope accepts wherever it lies. A request with an invalid
member changes nothing.
```
{"cmd": "set_trigger", "mode": "pulse",
 "pulse": {"source": "ch1", "when": "pos_greater", "width": 3e-4, "level": 1.2}}
```

### `save_setup`
The scope's setup, as `"setup"`: base64 text of an opaque block (about
3 KB). Keep it to restore later.

The block holds the scope's own setup data and, with it, the settings that
`status` reports. The scope's data alone does not restore everything on the
DS1202Z-E: the timebase comes back from it, the channels' scales do not,
and the trigger level is not saved in it at all.

### `load_setup`
`setup`: a `save_setup` result. Restores the scope's setup data, then sets
the settings saved with it (acquisition, channels, timebase, trigger and
math) as the `set_` requests would; takes a few seconds. A setting the
scope refuses is listed in `"warnings"` (texts), and the rest are still
set. A block of the scope's data alone, as saved by earlier versions of
the server, is restored as the scope restores it.

### `set_math`
The scope's math channel. Any of:

| member         | values                                                   |
|----------------|----------------------------------------------------------|
| `display?`     | bool                                                     |
| `operator?`    | `"add"`, `"sub"`, `"mul"`, `"div"`, `"fft"`              |
| `source1?`, `source2?` | `"ch1"`, `"ch2"`: A and B of the algebraic operators |
| `scale?`       | units per division of the result (V, V^2, dB or Vrms)    |
| `offset?`      | vertical offset of the result, same unit                 |
| `fft_source?`  | `"ch1"`, `"ch2"`                                         |
| `fft_window?`  | `"rect"`, `"hann"`, `"hamming"`, `"blackman"`, `"flattop"`, `"triangle"` |
| `fft_unit?`    | `"db"`, `"vrms"`                                         |
| `fft_mode?`    | `"trace"` (FFT of the screen data) or `"memory"` (of the acquisition memory) |
| `fft_hscale?`  | Hz per division of the FFT screen                        |
| `fft_hcenter?` | Hz at the centre of the FFT screen                       |

A request with an invalid member changes nothing. The scope picks a new
`scale` when the operator changes, and accepts only some `fft_hscale`
values (1/1000, 1/400, 1/200, 1/100, 1/40 and 1/20 of the FFT sample
rate), ignoring others. Read it back with `status`.

### `live`
`on` (bool), `interval_ms?` (default 200, minimum 50), `measure_ch?` (1 or
2, or 0 for no measurements; default: the lowest displayed channel),
`measure_items?` (an array of at most 5 item names; default `["freq",
"vpp", "vrms"]`). While on, the server sends a `frame` event for every
displayed channel and a `measure` event for the measured channel, then
waits `interval_ms`. Other requests are served between updates.

Live mode is a subscription: `on` subscribes the client making the
request to the live events, `off` unsubscribes it; the updates run while
any client is subscribed. The options (interval, measurements, math,
spectrum) are shared by all clients; each `live` request sets them. A
client's `capture` ends its own subscription. A client that does not read
its events fast enough misses some: at most 32 wait for it, while replies
are never dropped.

Also, optionally:
- `scope_math?` (bool): read the scope's math channel each update, when it
  is displayed, and send it as a `math` event, or as a `spectrum` event
  when its operator is `fft`. Costs a waveform source switch (~50 ms).
- `math?` (`"add"`, `"sub"`, `"mul"`): the server combines this update's
  frames of both channels and sends a `math` event. Both channels must be
  displayed.
- `spectrum?` (`{"ch": 1, "window": "hann"}`, window optional, default
  `hann`): the server transforms this update's frame of the channel and
  sends a `spectrum` event.

Measurements cover one channel and at most 5 items because that is what
the scope keeps armed: measuring them again costs about a millisecond,
while a sixth item, or another channel, makes it re-arm at about half a
second per query. Showing both channels costs
about 150 ms per update (the scope switches its waveform source), so
expect roughly 5 updates per second with two channels and 15 with one
(DS1202Z-E over USB, interval_ms 50).

### `measure`
`ch`, `items?` (array of item names, default `["freq", "vpp", "vrms"]`).
Replies with the same members as the `measure` event. Items the scope does
not have armed (see `live`) take about half a second each.

### `screen`
`ch`. The waveform on the scope's screen now, as a `frame` event would
carry it: the waveform members, `"bytes": points` and the raw samples. For
scripts that want one screen without live mode. Right after the scope's
settings change it may have no screen data yet (0 points).

### `capture`
`ch`. Stops the scope and reads the channel's whole acquisition memory
(up to 24M points; about 8 s for 6M over USB), sending `progress` events on
the way. The server keeps the samples; the reply describes them:
```
{"id": 5, "ok": true, "ch": 1, "points": 6000000, "x_inc": 2e-09, ...}
```
The scope is left stopped. Each channel keeps its most recent capture until
it is captured again; captures are shared by all clients and kept when a
client disconnects.

### `view`
`ch`, `first`, `last`, `columns`. Reduces captured samples `first` ..
`last` (0-based, inclusive) to `columns` columns and returns, per column,
the lowest and highest raw sample in it: `"bytes": 2 * columns`, laid out
min, max, min, max, ... If there are fewer samples than columns, every
sample gets its own column (min = max) and `columns` in the reply says how
many were sent.
```
{"id": 6, "ok": true, "columns": 800, "bytes": 1600}<1600 bytes>
```
Use this to draw captures: zooming and panning are new `view` requests,
fast at any memory depth, and a short glitch still shows in its column.

### `spectrum`
`ch`, `first?`, `last?` (default: the whole capture), `window?` (default
`hann`), `resolution?`, `f_min?`, `f_max?` (Hz, default 0 to the highest
frequency), `columns?`. The server's spectrum of a capture.

`resolution` chooses how a long capture is transformed:
- `"fine"` (default): the whole range in one transform, for a resolution
  of about 1 / duration (83 Hz for 12 ms). Ranges longer than 2^20
  samples are first averaged in blocks of `decimation` samples, which
  lowers the highest frequency to half the reduced sample rate (41 MHz
  for 6M samples at 500 MSa/s); the transform is padded with zeros to a
  power of two, so the points (`df`) are finer than the resolution
  (`bin_width`).
- `"wide"`: up to the full sample rate's half, in 2^20-sample segments
  whose spectra are averaged: a lower noise floor, but the resolution of
  one segment (477 Hz at 500 MSa/s).

Without `columns`, every point from `f_min` to `f_max` is returned; with
it, the points are reduced to that many columns, keeping each column's
highest, so that no line is lost. The reply has the members under *Math
and spectrum data*, `resolution`, `decimation`, and the values as
float32:
```
{"id": 7, "ok": true, "ch": 1, "points": 800, "f0": 0, "df": 25.0,
 "bin_width": 83.3, "unit": "dBV", "window": "hann",
 "resolution": "fine", "decimation": 6, "bytes": 3200}
```
The transform is cached per channel, so requests for other frequency
ranges of the same capture, range, window and resolution are quick. A
6M-sample capture takes under a second to transform.

### `math_view`
`operator` (`"add"`, `"sub"`, `"mul"`), `first`, `last`, `columns`. Like
`view`, for the server's combination of the captures of both channels
(which must be of the same length): per column the lowest and highest
value, as float32 pairs in `unit` (`"V"` or `"V^2"`):
```
{"id": 8, "ok": true, "columns": 800, "unit": "V", "bytes": 6400}
```

### `samples`
`ch`, `first`, `last` (0-based, inclusive, at most 1 000 000 samples).
Returns the captured raw samples, `"bytes": last - first + 1`. For export.

### `screenshot`
Returns the screen image as a BMP file (800 x 480, 24 bit):
`{"id": 9, "ok": true, "format": "bmp", "bytes": 1152054}` and the file.

### `set_mask`
The scope's pass/fail test, which counts the frames whose waveform stays
inside a mask (passed) or leaves it (failed). Any of:

| member          | meaning                                                   |
|-----------------|-----------------------------------------------------------|
| `enable?`       | bool: the test on or off                                  |
| `source?`       | `"ch1"`, `"ch2"`: the channel tested (must be displayed)  |
| `x?`, `y?`      | the mask's margins around the waveform, in divisions: x 0.02 .. 4, y 0.04 .. 5.12 |
| `stop_on_fail?` | bool: stop acquiring at the first failed frame            |
| `beep?`         | bool: beep on a failed frame                              |
| `show_stats?`   | bool: show the counts on the scope's screen               |
| `create?`       | `true`: a new mask around the waveform now (stops the test first) |
| `reset?`        | `true`: the counts back to 0                              |
| `run?`          | bool: start or stop the test                              |

They are applied in that order, so one request can set up, create and
start a test:
```
{"cmd": "set_mask", "enable": true, "source": "ch1", "x": 0.2, "y": 0.48,
 "create": true, "reset": true, "run": true}
```
The test needs the scope acquiring (`run`); it does not work in XY or roll
mode, or at 200 ms/div and slower. It keeps counting while the server
reads the screen in live mode.

### `mask`
The pass/fail test's settings and counts:
```
{"id": 3, "ok": true, "enable": true, "source": "ch1", "running": true,
 "x": 0.2, "y": 0.48, "stop_on_fail": false, "beep": false,
 "show_stats": true, "passed": 151, "failed": 0, "total": 151}
```

### `ref_save`
`slot` (1 .. 4), `ch`, `label?`. Keeps the channel's screen waveform now as
reference `slot`, in the server, for every client to compare with. The
label defaults to the channel and the time (`"CH1 14:03:44"`). Replies
with the reference's members, as `refs` lists them. References last as
long as the server runs; every change sends the `refs` event to all
clients.

### `ref_load`
`slot`, `data` (the samples, base64 of 8-bit raw values), `x_inc`,
`x_origin`, `y_inc`, `y_origin`, `y_ref` (as under *Waveform data*),
`label?`, `ch?` (0, 1 or 2: the channel it belongs with, 0 = none). Stores
waveform data from a client, e.g. read from a file, as a reference: 2 to
1 000 000 samples.

### `refs`
The references kept, without their samples:
```
{"id": 4, "ok": true, "refs": [
  {"slot": 1, "ch": 1, "label": "CH1 14:03:44", "points": 1200,
   "x_inc": 1e-05, "x_origin": -0.006, "y_inc": 0.04, "y_origin": -25.0,
   "y_ref": 127.0}]}
```

### `ref`
`slot`. That reference: the members of `refs` and its samples, `"bytes":
points`. A client can draw it like a frame; the GUI places it at its own
times and in volts like channel `ch`.

### `ref_clear`
`slot?`. Forgets that reference, or all of them.

### `decode`
Decodes captured memory as a serial bus. Capture the channels the bus
uses first (with the scope stopped, so both captures hold the same
acquisition). Members:

- `protocol`: `"uart"`, `"i2c"` or `"spi"`.
- UART: `tx` (channel), `rx?` (the other channel, for both directions),
  `baud`, `bits?` (5 .. 9, default 8), `parity?` (`"none"`, `"even"`,
  `"odd"`), `stop?` (1, 1.5, 2), `inverted?` (bool: idle low, as on RS232
  levels), `msb_first?` (default false).
- I2C: `scl?` (default 1), `sda?` (default the other channel).
- SPI: `clk?` (default 1), `data?` (default the other channel), `edge?`
  (`"rising"`, `"falling"`: the edge the data is valid on, default
  rising), `width?` (4 .. 32 bits, default 8), `msb_first?` (default
  true), `inverted?` (data active low), `timeout?` (s: a pause in the
  clock longer than this ends a word; default three times the usual time
  between clock edges).
- All: `threshold1?`, `threshold2?` (V; default halfway between each
  channel's lowest and highest sample), `first?`, `last?` (a sample range,
  default the whole capture), `max_items?` (default 100 000, at most
  1 000 000).

With two channels, SPI has no chip select: words are framed by the
timeout, like the scope's own timeout mode. Decoding starts where the bus
is idle, so a capture that begins in the middle of a frame does not give a
wrong first item: a UART line must be idle for a whole frame, an SPI clock
quiet for longer than the timeout. I2C starts at the first start
condition.

The reply lists the items in time order:
```
{"id": 5, "ok": true, "protocol": "i2c", "count": 120, "truncated": false,
 "thresholds": {"ch1": 1.68, "ch2": 1.68},
 "items": [
   {"ch": 2, "type": "start", "first": 2501, "last": 2501, "t": -0.005975},
   {"ch": 2, "type": "address", "first": 3251, "last": 11751, "t": -0.005967,
    "value": 80, "ack": true, "read": false},
   {"ch": 2, "type": "data", "first": 12250, "last": 20750, "t": -0.005878,
    "value": 0, "ack": true}, ...]}
```

| member  | meaning                                                    |
|---------|------------------------------------------------------------|
| `ch`    | the channel carrying the data (UART: TX or RX; I2C: SDA; SPI: data) |
| `type`  | `"data"`, and for I2C `"address"`, `"start"`, `"stop"`     |
| `first`, `last` | the capture samples the item covers                 |
| `t`     | time of its first sample, s                                |
| `value` | the byte or word; for an I2C address, the 7-bit address    |
| `read`  | I2C address: the R/W bit is set                            |
| `ack`   | I2C: the byte was acknowledged                             |
| `error` | UART: `"parity"` or `"framing"` (a stop bit that is low)   |

UART replies also have `samples_per_bit` (at least 4 are needed: capture
at a faster timebase otherwise), SPI replies `timeout` (s), the one used.
`truncated` is true when `max_items` cut the list short. A channel with no
logic swing in the range is an error unless its threshold is given.

### `set_decoder`
Sets up one of the scope's own bus decoders, which draw a decoded bus on
its screen (the scope cannot send its decoded data; use `decode` for
that). `bus?` (1 or 2, default 1), `display?` (default true), `format?`
(`"hex"`, `"ascii"`, `"dec"`, `"bin"`), and the members of `decode` for
the protocol and thresholds. The scope decodes 5 .. 8 UART bits and SPI
words of 8 .. 32 bits; its SPI decoding is set to timeout mode, with MOSI
the data channel and MISO off. Without thresholds it uses automatic ones.
```
{"cmd": "set_decoder", "protocol": "uart", "tx": 1, "baud": 115200,
 "format": "ascii"}
```

### `timing`
Times code: a program marks a block on a pin (high while it runs, say),
and `timing` measures every marked block in captured memory. Capture the
marker channel first, and the other one too for `to`. Members:

- `ch`: the marker channel.
- `polarity?`: `"high"` (default: a block is a high pulse) or `"low"`.
- `to?`: the other channel: also measure the latency from each block's
  start on `ch` to the next start on `to` (from an event to its
  response, say).
- `burst_gap?` (s): also group the pulses into bursts, where a pause
  longer than this ends a burst: for a marker toggled in a loop, one
  burst per loop run.
- `bins?`: histogram bins, 1 .. 200, default 40.
- `threshold?` (V; default halfway between the channel's lowest and
  highest sample, as for `decode`), `first?`, `last?` (a sample range).

Only whole blocks count: a block cut by the capture's start or end is left
out, and so is a burst that may go on outside the capture.
```
{"id": 7, "ok": true, "ch": 1, "polarity": "high", "to": 2,
 "resolution": 1e-08, "span": 0.012, "duty": 0.229,
 "thresholds": {"ch1": 1.66, "ch2": 1.66},
 "block": {"count": 12, "min": 0.0002, "max": 0.000356, "mean": 0.000229,
           "std_dev": 5.6e-05, "median": 0.000205,
           "shortest": {"first": 110000, "last": 129999, "t": -0.0049},
           "longest": {"first": 910000, "last": 945599, "t": 0.0031},
           "histogram": {"from": 0.0002, "to": 0.000356,
                         "counts": [4, 3, 3, 0, ...]}},
 "idle": {...}, "period": {...}, "latency": {...}}
```

| member   | what it holds                                              |
|----------|------------------------------------------------------------|
| `block`  | the blocks: each marked pulse, s                           |
| `idle`   | the time between blocks, s                                 |
| `period` | block start to the next block start, s                     |
| `duty`   | mean block over mean period: the share of time spent in the block |
| `latency`| with `to`: block start on `ch` to the next start on `to`, s |
| `burst`, `burst_pulses` | with `burst_gap`: each burst's length (s) and its number of pulses |
| `resolution` | the sample interval: the timing is exact to this, s    |
| `span`   | the time analysed, s                                       |

Each set of values has `count`, and when it is not 0 `min`, `max`,
`mean`, `std_dev`, `median`, `shortest` and `longest` (where the shortest
and longest one is: its samples and time, for zooming the capture to it),
and `histogram`: `counts` in equal bins from `from` to `to`. A channel
with no logic swing in the range is an error unless `threshold` is given.

### `scpi`
`text`, `query?` (bool, default false). Sends a raw SCPI command; with
`query`, replies with `"response"`: the scope's text answer. An escape
hatch for features the protocol does not cover.

## Errors

A failed request gets `"ok": false` and an `"error"` text; the connection
stays usable. If the scope stops responding, the error says so and the
client may retry.
