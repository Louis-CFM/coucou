#!/usr/bin/env python3
"""Prepare pinned pt-PT voices as Coucou project data; no global installs."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

VOICES = {
    "miro": ("6a917dc1f1d2f6a4a0a12742478483ccce3f52b6", "pt_PT-miro-high"),
    "dii": ("27cf37a700e91003217a567e12761e6497fe9b0b", "pt_PT-dii-high"),
}
PHONEMIZER = [
    "espeak-ng-data/phondata", "espeak-ng-data/phonindex",
    "espeak-ng-data/phontab", "espeak-ng-data/intonations",
    "espeak-ng-data/pt_dict", "espeak-ng-data/lang/roa/pt",
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / ".build/local-voices")
    parser.add_argument("--voice", choices=[*VOICES, "both"], default="both")
    args = parser.parse_args()
    hf = shutil.which("hf")
    if not hf:
        parser.error("hf CLI is required; this script does not install global tools")
    for voice in VOICES if args.voice == "both" else [args.voice]:
        revision, model = VOICES[voice]
        destination = args.output.expanduser().resolve() / model
        subprocess.run([
            hf, "download", f"csukuangfj/vits-piper-{model}",
            f"{model}.onnx", f"{model}.onnx.json", "tokens.txt", "README.md",
            *PHONEMIZER, "--revision", revision, "--local-dir", str(destination),
        ], env={**os.environ, "HF_HUB_DISABLE_XET": "1"}, check=True)
        print(f"{voice}: {destination}")


if __name__ == "__main__":
    main()
