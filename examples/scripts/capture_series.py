# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""Take a series of single-shot captures and save each to disk.

    scopebridge_run.py examples/scripts/capture_series.py [count] [pause_s] [dir]

Defaults: 5 captures, 2 s apart, into ./captures.  Each capture is the
whole acquisition memory of CH1, saved as CSV (time, volts), plus a
summary line per capture in index.csv.
"""

import os
import sys
import time

from scopebridge import Scope

count = int(sys.argv[1]) if len(sys.argv) > 1 else 5
pause = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
folder = sys.argv[3] if len(sys.argv) > 3 else "captures"
os.makedirs(folder, exist_ok=True)

with Scope() as scope, open(os.path.join(folder, "index.csv"), "a") as index:
    index.write("time,file,points,sample_rate,vmin,vmax\n")
    for n in range(count):
        scope.single()
        if not scope.wait_for_trigger(timeout=10):
            print("capture %d: no trigger within 10 s, skipped" % n)
            continue
        cap = scope.capture(1)
        name = os.path.join(folder, "capture_%03d.csv" % n)
        cap.save_csv(name)
        volts = cap.volts()
        index.write("%s,%s,%d,%g,%.4f,%.4f\n" % (
            time.strftime("%Y-%m-%d %H:%M:%S"), name, cap.points,
            cap.sample_rate, min(volts), max(volts)))
        index.flush()
        print("capture %d: %d points at %g Sa/s -> %s"
              % (n, cap.points, cap.sample_rate, name))
        time.sleep(pause)
    scope.run()
