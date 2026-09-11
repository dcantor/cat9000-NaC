#!/usr/bin/env python3
"""Download the running (and startup) configuration of every switch into a directory.

Usage: capture_configs.py <output-dir>
"""
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "resources"))
from LabLib import LabLib          # noqa: E402
from lab_vars import SWITCHES      # noqa: E402

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
lib = LabLib()
stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
try:
    for name, sw in SWITCHES.items():
        for cmd, suffix in (("show running-config", "running-config"),
                            ("show startup-config", "startup-config")):
            cfg = lib.run_command(sw["host"], cmd, timeout=120)
            path = out / f"{name}.{suffix}.txt"
            path.write_text(f"! {name} ({sw['host']}) {cmd} captured {stamp}\n{cfg}\n")
            print(f"[{name}] {path} ({len(cfg)} bytes)")
finally:
    lib.close_all_connections()
