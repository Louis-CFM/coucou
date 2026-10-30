#!/usr/bin/env python3
"""Optimize docs/media: add WebP siblings and re-encode the demo GIF.

Originals stay in place (README.md and the Casks reference them by name), so the
site can use <picture> with a WebP source and the PNG/JPEG as the fallback.
"""
import sys
from pathlib import Path

from PIL import Image

MEDIA = Path(__file__).resolve().parent / "media"


def kb(n):
    return f"{n/1024:.0f} KB"


def webp_for(path: Path, quality: int) -> Path:
    out = path.with_suffix(".webp")
    with Image.open(path) as im:
        im.load()
        if im.mode in ("P", "LA"):
            im = im.convert("RGBA")
        im.save(out, "WEBP", quality=quality, method=6)
    return out


def animated_webp(src: Path, quality: int) -> Path:
    out = src.with_suffix(".webp")
    with Image.open(src) as im:
        frames, durations = [], []
        try:
            while True:
                durations.append(im.info.get("duration", 70))
                frames.append(im.convert("RGBA").copy())
                im.seek(im.tell() + 1)
        except EOFError:
            pass
    frames[0].save(out, "WEBP", save_all=True, append_images=frames[1:],
                   duration=durations, loop=0, quality=quality, method=4)
    return out


def main():
    report = []
    stills = sorted(p for p in MEDIA.iterdir()
                    if p.suffix.lower() in (".png", ".jpg", ".jpeg"))
    for p in stills:
        # Photos (iPhone/Android captures) compress harder than flat UI shots.
        photo = p.suffix.lower() in (".jpg", ".jpeg") or p.name.startswith(("iphone", "android"))
        w = webp_for(p, quality=74 if photo else 86)
        report.append((p.name, p.stat().st_size, w.stat().st_size))

    gif = MEDIA / "demo.gif"
    if gif.exists():
        w = animated_webp(gif, quality=72)
        report.append((gif.name + " (animated)", gif.stat().st_size, w.stat().st_size))

    print(f"{'file':34s} {'before':>9s} {'webp':>9s}  {'saved':>7s}")
    tb = tw = 0
    for name, b, a in report:
        tb += b
        tw += a
        print(f"{name:34s} {kb(b):>9s} {kb(a):>9s}  {100*(1-a/b):>6.1f}%")
    print(f"{'TOTAL':34s} {kb(tb):>9s} {kb(tw):>9s}  {100*(1-tw/tb):>6.1f}%")


if __name__ == "__main__":
    sys.exit(main())
