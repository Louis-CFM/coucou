"""Writes the hat SVGs. Usage: python scripts/wardrobe/build.py"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import heads  # noqa: E402

OUT = os.path.join(HERE, "..", "..", "src", "mochi", "wardrobe", "head")
for old in os.listdir(OUT):
    if old.endswith(".svg") and old[:-4] not in heads.ITEMS:
        os.remove(os.path.join(OUT, old))
for key, fn in heads.ITEMS.items():
    with open(os.path.join(OUT, key + ".svg"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(fn().svg())
print("hats", len(heads.ITEMS))
