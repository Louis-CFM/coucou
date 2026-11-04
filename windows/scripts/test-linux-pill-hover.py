#!/usr/bin/env python3
"""Check native toolbar collapse when WebKitGTK misses pointerleave.

Uses a virtual X display and temporary preferences. Requires Xvfb, xdotool,
xwd, dbus-run-session, cc and GTK3 development headers. Captures remain under
--output so a failing interaction can be inspected.
"""

import argparse
import json
import os
import pathlib
import shlex
import shutil
import signal
import struct
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", type=pathlib.Path)
parser.add_argument("--tools", type=pathlib.Path, help="directory with Xvfb, xdotool and xwd")
parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("target/pill-hover-test"))
parser.add_argument("--display", type=int, default=97)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
output = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=args.output)).resolve()
# Keep Unix socket paths short even when --output is deep in a checkout.
runtime = tempfile.TemporaryDirectory(prefix="coucou-hover-")


def tool(name):
    path = str(args.tools.resolve() / name) if args.tools else shutil.which(name)
    if not path or not pathlib.Path(path).is_file():
        raise RuntimeError(f"{name} is required")
    return path


if pathlib.Path(f"/tmp/.X11-unix/X{args.display}").exists():
    raise RuntimeError("The test display is in use; choose another --display")

shim = output / "drop-leave.so"
cflags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "gtk+-3.0"], text=True))
subprocess.run(
    ["cc", "-shared", "-fPIC", "-o", str(shim),
     str(pathlib.Path(__file__).with_suffix(".c")), *cflags, "-ldl"],
    check=True,
)

env = os.environ.copy()
env.update(
    DISPLAY=f":{args.display}",
    XDG_SESSION_TYPE="x11",
    XDG_CURRENT_DESKTOP="TEST",
    XDG_CONFIG_HOME=str(output / "config"),
    XDG_DATA_HOME=str(output / "data"),
    XDG_RUNTIME_DIR=runtime.name,
    LD_PRELOAD=str(shim),
)
for directory in [output / "data/coucou/Flow", output / "config"]:
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
(output / "data/coucou/Flow/prefs.json").write_text(
    json.dumps({"enabled": True, "openAtLaunch": False})
)


def command(name, *arguments):
    return subprocess.check_output(
        [tool(name), *map(str, arguments)], env=env,
        stderr=subprocess.DEVNULL, text=True, timeout=5,
    ).strip()


def capture(window, name, offset=20):
    path = output / (name + ".xwd")
    command("xwd", "-silent", "-id", window, "-out", path)
    raw = path.read_bytes()
    header = struct.unpack(">25I", raw[:100])
    header_size, width, height = header[0], header[4], header[5]
    byte_order, bits_per_pixel, stride = header[7], header[11], header[12]
    red_mask, green_mask, blue_mask, colors = header[14], header[15], header[16], header[19]
    start = header_size + colors * 12
    row = raw[start + (height - offset) * stride : start + (height - offset + 1) * stride]
    pixel_size = bits_per_pixel // 8
    # Twenty pixels above the bottom intersects an open toolbar, but not the
    # resting 8px capsule. The virtual display's background is black.
    pixels = [
        int.from_bytes(row[x * pixel_size : (x + 1) * pixel_size],
                       "little" if byte_order == 0 else "big")
        for x in range(width // 2 - 80, width // 2 + 80)
    ]
    lit = sum(bool(pixel & (red_mask | green_mask | blue_mask)) for pixel in pixels)
    print(f"{name}: {lit} visible pixels at toolbar height", flush=True)
    return lit


xvfb_env = os.environ.copy()
xvfb_env.pop("LD_PRELOAD", None)
xvfb = subprocess.Popen(
    [tool("Xvfb"), f":{args.display}", "-screen", "0", "1280x720x24", "-ac", "-nolisten", "tcp"],
    env=xvfb_env, stdout=(output / "xvfb.log").open("w"), stderr=subprocess.STDOUT,
)
app = None
try:
    for attempt in range(50):
        try:
            command("xdotool", "getdisplaygeometry")
            break
        except subprocess.CalledProcessError:
            if xvfb.poll() is not None or attempt == 49:
                raise RuntimeError(f"Virtual display failed; see {output / 'xvfb.log'}")
            time.sleep(0.1)

    app = subprocess.Popen(
        ["dbus-run-session", "--", str(args.binary.resolve())],
        env=env, stdout=(output / "app.log").open("w"),
        stderr=subprocess.STDOUT, start_new_session=True,
    )
    pill = None
    for _ in range(60):
        time.sleep(0.25)
        if app.poll() is not None:
            break
        try:
            windows = command("xdotool", "search", "--onlyvisible", "--name", "^Coucou$").splitlines()
        except subprocess.CalledProcessError:
            continue
        for window in windows:
            geometry = dict(
                line.split("=", 1)
                for line in command("xdotool", "getwindowgeometry", "--shell", window).splitlines()
            )
            if int(geometry["WIDTH"]) == 520 and int(geometry["HEIGHT"]) == 170:
                pill = window
                break
        if pill:
            break
    if not pill:
        raise RuntimeError(f"Pill window not found; see {output / 'app.log'}")

    x, y, width, height = (int(geometry[key]) for key in ["X", "Y", "WIDTH", "HEIGHT"])
    command("xdotool", "mousemove", 30, 30)
    for attempt in range(100):
        # Mapping the GTK window precedes the async webview boot. Wait for the
        # resting capsule itself instead of assuming a fixed startup time.
        if capture(pill, "ready", offset=5) > 0:
            break
        if attempt == 99:
            raise RuntimeError(f"The pill did not finish loading; see {output / 'app.log'}")
        time.sleep(0.1)
    time.sleep(0.6)
    assert capture(pill, "resting") == 0, "Toolbar should start collapsed"
    for attempt in range(5):
        command("xdotool", "mousemove", x + width // 2, y + height - 5)
        time.sleep(0.6)
        assert capture(pill, f"open-{attempt}") > 0, "Toolbar did not open"
        command("xdotool", "mousemove", 30, 30)
        time.sleep(0.9)
        assert capture(pill, f"closed-{attempt}") == 0, (
            "Toolbar stayed expanded after mouse exit with leave event suppressed"
        )
    print(f"Captures: {output}", flush=True)
    print("PASS: five mouse exits collapsed the toolbar despite lost leave events", flush=True)
finally:
    if app and app.poll() is None:
        os.killpg(app.pid, signal.SIGTERM)
        try:
            app.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(app.pid, signal.SIGKILL)
            app.wait(timeout=5)
    xvfb.terminate()
    xvfb.wait(timeout=5)
    runtime.cleanup()
