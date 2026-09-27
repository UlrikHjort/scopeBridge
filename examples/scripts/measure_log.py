# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""Log measurements to a CSV file at a fixed interval.

    scopebridge_run.py examples/scripts/measure_log.py [file.csv] [seconds] [interval]

Defaults: measurements.csv, until Ctrl-C, every second.  Good for watching
a signal drift over hours.
"""

import sys

from scopebridge import Scope

path = sys.argv[1] if len(sys.argv) > 1 else "measurements.csv"
duration = float(sys.argv[2]) if len(sys.argv) > 2 else None
interval = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0

with Scope() as scope:
    print("Logging CH1 frequency, Vpp and Vrms to", path,
          "(Ctrl-C stops)" if duration is None else "for %g s" % duration)
    rows = scope.record(path, ch=1, items=("freq", "vpp", "vrms"),
                        interval=interval, duration=duration,
                        on_row=lambda row: print("  ", *row))
    print(rows, "rows written")
