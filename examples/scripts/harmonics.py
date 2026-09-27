# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""List the harmonics of the signal on CH1, from a full-memory capture.

    scopebridge_run.py examples/scripts/harmonics.py [count]

Captures CH1, takes the server's spectrum of the whole memory (flat-top
window, for accurate levels) and prints the fundamental and the first
harmonics with their level relative to it.
"""

import sys

from scopebridge import Scope

count = int(sys.argv[1]) if len(sys.argv) > 1 else 7

with Scope() as scope:
    freq = scope.measure(1, "freq")["freq"]
    if freq is None:
        sys.exit("No periodic signal on CH1")
    cap = scope.capture(1)
    spectrum = cap.spectrum(window="flattop")
    if spectrum.dc_limit() > 0.5 * freq:
        # The flat-top window's wide main lobe would mix DC into the
        # fundamental: the capture is too short for this signal
        print("Capture of %.3g s gives %.0f Hz resolution, too coarse for "
              "flat-top levels at %.0f Hz;\nusing the Hann window (levels "
              "within 1.4 dB). A longer timebase gives accurate levels."
              % (cap.duration, spectrum.bin_width, freq))
        spectrum = cap.spectrum(window="hann")
    if spectrum.dc_limit() > 0.7 * freq:
        sys.exit("The capture is too short to resolve %.0f Hz from DC; "
                 "use a longer timebase" % freq)

    # The scope's frequency measurement is far finer than the spectrum's
    # resolution, so it places the harmonics
    f1, level1 = spectrum.peak(f_min=0.7 * freq, f_max=1.3 * freq)
    print("Fundamental %.2f Hz (measured) at %.2f dBV, %s window, "
          "resolution %.1f Hz" % (freq, level1, spectrum.window,
                                  spectrum.bin_width))
    for n in range(2, count + 1):
        found = spectrum.peak(f_min=(n - 0.3) * freq, f_max=(n + 0.3) * freq)
        if found:
            f, level = found
            print("  harmonic %d: %9.2f Hz  %7.2f dBV  %7.2f dBc"
                  % (n, f, level, level - level1))
    scope.run()
