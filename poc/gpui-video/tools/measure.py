#!/usr/bin/env python3
"""Measures the PoC's CPU and GPU cost per scenario.

CPU is the process's user+system time over the window, as % of one core.
GPU is the process's own graphics-engine time from its DRM fdinfo
(`drm-engine-gfx`, which amdgpu and i915/xe report), as % of wall time, so
other GPU users on the machine don't count. A warm-up is discarded first.

    tools/measure.py target/release/gpui-video-poc [seconds]
"""

import os
import subprocess
import sys
import time

SCENARIOS = [
    ("idle, 4 tiles, no frames", ["--idle", "--tiles", "4"]),
    ("4 x 720p30", ["--tiles", "4", "--res", "1280x720", "--fps", "30"]),
    ("9 x 720p30", ["--tiles", "9", "--res", "1280x720", "--fps", "30"]),
    ("4 x 1080p30", ["--tiles", "4", "--res", "1920x1080", "--fps", "30"]),
    ("1 x 1080p60", ["--tiles", "1", "--res", "1920x1080", "--fps", "60"]),
]
WARMUP = 5.0
CLK_TCK = os.sysconf("SC_CLK_TCK")


def cpu_seconds(pid):
    with open(f"/proc/{pid}/stat") as f:
        fields = f.read().rsplit(")", 1)[1].split()
    # utime and stime are fields 14 and 15; after the comm they are 11 and 12.
    return (int(fields[11]) + int(fields[12])) / CLK_TCK


def gpu_seconds(pid):
    """Sum of drm-engine-gfx over the process's DRM clients, counted once each."""
    seen, total = set(), 0
    fdinfo = f"/proc/{pid}/fdinfo"
    for fd in os.listdir(fdinfo):
        try:
            with open(f"{fdinfo}/{fd}") as f:
                info = dict(
                    line.split(":", 1) for line in f.read().splitlines() if ":" in line
                )
        except OSError:
            continue
        client = info.get("drm-client-id")
        engine = info.get("drm-engine-gfx")
        if client is None or engine is None or client in seen:
            continue
        seen.add(client)
        total += int(engine.strip().split()[0])
    return total / 1e9


def rss_mib(pid):
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) / 1024
    return 0.0


def run(binary, args, seconds):
    app = subprocess.Popen(
        [binary, *args], stderr=subprocess.PIPE, text=True, bufsize=1
    )
    try:
        time.sleep(WARMUP)
        c0, g0, t0 = cpu_seconds(app.pid), gpu_seconds(app.pid), time.monotonic()
        time.sleep(seconds)
        c1, g1, t1 = cpu_seconds(app.pid), gpu_seconds(app.pid), time.monotonic()
        rss = rss_mib(app.pid)
    finally:
        app.terminate()
        _, err = app.communicate(timeout=10)
    wall = t1 - t0
    rates = [line for line in err.splitlines() if "delivered" in line]
    return {
        "cpu": 100 * (c1 - c0) / wall,
        "gpu": 100 * (g1 - g0) / wall,
        "rss": rss,
        "rates": rates[-1].split("s ", 1)[1].strip() if rates else "-",
    }


def main():
    binary = sys.argv[1]
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0
    print(f"{'scenario':26} {'CPU % core':>10} {'GPU %':>7} {'RSS MiB':>8}  app counters")
    for name, args in SCENARIOS:
        r = run(binary, args, seconds)
        print(f"{name:26} {r['cpu']:10.1f} {r['gpu']:7.2f} {r['rss']:8.0f}  {r['rates']}")


if __name__ == "__main__":
    main()
