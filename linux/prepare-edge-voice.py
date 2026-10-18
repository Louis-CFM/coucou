#!/usr/bin/env python3
"""Create Coucou's private Read Aloud environment and print its Python path."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=root / ".build/edge-voice-env")
    args = parser.parse_args()
    uv = shutil.which("uv")
    if not uv:
        parser.error("uv is required; this script does not install global tools")
    destination = args.output.expanduser().resolve()
    environment = {**os.environ, "UV_CACHE_DIR": str(root / ".build/uv-cache")}
    python = destination / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    if not python.is_file():
        subprocess.run([uv, "venv", "--python", "3.11", str(destination)], env=environment, check=True)
    subprocess.run([
        uv, "pip", "sync", "--python", str(python), "--require-hashes",
        str(root / "linux/requirements-edge-voice.txt"),
    ], env=environment, check=True)
    print(python)


if __name__ == "__main__":
    main()
