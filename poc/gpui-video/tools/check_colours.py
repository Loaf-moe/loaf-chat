#!/usr/bin/env python3
"""End-to-end colour check for the video surface patch.

Starts the PoC, screenshots the screen with grim (needs a compositor with
wlr-screencopy), finds the tiles by their yellow bar, and checks that every
colour bar came out at the RGB its BT.709 limited-range YUV encodes, within
a few levels. This exercises the upload, the padded strides, the shader and
the colour matrix together. Exits non-zero on a mismatch.

    tools/check_colours.py target/release/gpui-video-poc [out.png] [wait seconds]
"""

import subprocess
import sys
import time
from io import BytesIO

from PIL import Image

# The PoC's 100% bars, left to right, as RGB.
BARS = [
    ("white", (255, 255, 255)),
    ("yellow", (255, 255, 0)),
    ("cyan", (0, 255, 255)),
    ("green", (0, 255, 0)),
    ("magenta", (255, 0, 255)),
    ("red", (255, 0, 0)),
    ("blue", (0, 0, 255)),
    ("black", (0, 0, 0)),
]
TOLERANCE = 4


def near(a, b, tol=TOLERANCE):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def main():
    binary = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    wait = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0
    app = subprocess.Popen([binary, "--tiles", "4", "--fps", "30"], stderr=subprocess.DEVNULL)
    try:
        time.sleep(wait)
        shot = subprocess.run(["grim", "-t", "ppm", "-"], check=True, capture_output=True).stdout
    finally:
        app.terminate()
        app.wait(timeout=5)

    img = Image.open(BytesIO(shot)).convert("RGB")
    w, h = img.size
    px = img.load()

    # Rows that hold a long run of yellow are bar rows of some tile.
    yellow = BARS[1][1]
    best = None
    for y in range(0, h, 2):
        run = start = 0
        for x in range(w):
            if near(px[x, y], yellow):
                if run == 0:
                    start = x
                run += 1
                if best is None or run > best[2]:
                    best = (start, y, run)
            else:
                run = 0
    if best is None or best[2] < 20:
        print("FAIL: no yellow bar on screen; is the PoC window visible?")
        return 1

    # Walk that row from the white bar to the black bar, sampling each bar's
    # middle. A bar is as wide as the yellow run.
    x0, y, bar = best
    x_white = x0 - bar
    failures = 0
    for i, (name, want) in enumerate(BARS):
        x = x_white + i * bar + bar // 2
        got = px[x, y] if 0 <= x < w else None
        ok = got is not None and near(got, want)
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name:8} want {want} got {got} at ({x},{y})")

    if out:
        crop = img.crop((max(0, x_white - 40), max(0, y - bar * 2), min(w, x_white + bar * 9), min(h, y + bar * 3)))
        crop.save(out)
        print(f"saved {out}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
