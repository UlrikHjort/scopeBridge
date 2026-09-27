# Copyright (C) 2026 By Ulrik Hørlyk Hjort; MIT licence, see LICENSE.
"""Step through timebases, measuring and taking a screenshot at each.

    scopebridge_run.py examples/scripts/timebase_sweep.py [dir]

Restores the original timebase afterwards.
"""

import os
import sys

from scopebridge import Scope

folder = sys.argv[1] if len(sys.argv) > 1 else "sweep"
os.makedirs(folder, exist_ok=True)

with Scope() as scope:
    original = scope.status()["timebase"]["scale"]
    try:
        for scale in (100e-6, 200e-6, 500e-6, 1e-3, 2e-3):
            scope.timebase(scale=scale)
            scope.sleep(0.5)                   # let the scope settle
            m = scope.measure(1, "freq", "vpp")
            shot = os.path.join(folder, "tb_%gs.bmp" % scale)
            scope.screenshot(shot)
            print("%8g s/div: %s -> %s" % (scale, m, shot))
    finally:
        scope.timebase(scale=original)
