"""Check the app's library and embedded game view on a fresh Android emulator."""

import io
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image

ADB, TEMP = sys.argv[1:3]
APP = "io.tablecircle.prototype"
ACTIVITY = APP + "/.MainActivity"
DIAGNOSTICS = Path(TEMP) / "game-flow"
DIAGNOSTICS.mkdir(exist_ok=True)


def adb(*args):
    return subprocess.check_output([ADB, *map(str, args)], timeout=25)


def tap(x, y):
    adb("shell", "input", "tap", x, y)


def wait(label, check, seconds=35):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(1)
    raise RuntimeError(f"Timed out waiting for {label}")


def find(label):
    try:
        adb("shell", "uiautomator", "dump", "/sdcard/zompado.xml")
        data = adb("shell", "cat", "/sdcard/zompado.xml")
        (DIAGNOSTICS / "window.xml").write_bytes(data)
        for node in ET.fromstring(data).iter("node"):
            candidates = [node.get("text", ""), node.get("content-desc", "")]
            if not any(label in candidate.splitlines() for candidate in candidates):
                if label != "<input>" or node.get("class") != "android.widget.EditText":
                    continue
            x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds", "")))
            if x2 > x1 and y2 > y1:
                return (x1 + x2) // 2, (y1 + y2) // 2
    except (subprocess.SubprocessError, ET.ParseError):
        return None


def press(label):
    tap(*wait(label, lambda: find(label)))


def screenshot():
    return Image.open(io.BytesIO(adb("exec-out", "screencap", "-p"))).convert("RGB")


def is_landscape():
    image = screenshot()
    return image.width > image.height


def set_orientation(rotation):
    adb("shell", "settings", "put", "system", "accelerometer_rotation", 0)
    adb("shell", "settings", "put", "system", "user_rotation", rotation)
    wait("landscape" if rotation else "portrait",
         lambda: is_landscape() == bool(rotation))


def check_keyboard_rotation():
    adb("shell", "wm", "size", "480x900")
    adb("shell", "settings", "put", "system", "font_scale", "2.0")
    adb("shell", "settings", "put", "secure", "show_ime_with_hard_keyboard", 1)
    press("Import or open link")
    press("Open Game Link")
    press("<input>")
    ime_shown = lambda: b"mInputShown=true" in adb("shell", "dumpsys", "input_method")
    wait("the Android keyboard", ime_shown)
    adb("shell", "input", "text", "layout-resize-test")
    set_orientation(1)
    wait("the draft after rotation", lambda: find("layout-resize-test"))
    if not ime_shown():
        press("<input>")
        wait("the keyboard in landscape", ime_shown)
    screenshot().save(DIAGNOSTICS / "landscape-keyboard.png")
    for _ in range(3):
        if find("Open") is not None:
            break
        image = screenshot()
        x = image.width // 2
        adb("shell", "input", "swipe", x, image.height * 3 // 8,
            x, image.height // 7, 400)
    press("Open")
    if ime_shown():
        adb("shell", "input", "keyevent", 4)
    wait("game link validation", lambda: find("Use a game link shared from Zompado."))
    press("Cancel")
    set_orientation(0)
    adb("shell", "settings", "put", "system", "font_scale", "1.0")
    adb("shell", "wm", "size", "720x1280")
    print("PASS: the game link dialog kept its draft and validation across rotation with the Android keyboard.", flush=True)


def board():
    image = screenshot()
    # Center-line crossings locate the solid blue board around the center column.
    x = image.width // 2
    blue = (38, 69, 125)
    ys = [
        y for y in range(image.height // 5, image.height * 19 // 20)
        if all(abs(a - b) <= 3 for a, b in zip(image.getpixel((x, y)), blue))
    ]
    if len(ys) < 30 or ys[-1] - ys[0] < min(image.width, image.height) // 3:
        return None
    top, bottom = ys[0], ys[-1]
    return image, x, (top + bottom) // 2, bottom - round((bottom - top) / 12)


def has_center_token():
    result = board()
    if result is None:
        return False
    image, x, _, bottom_piece = result
    # Sample the center of the cell. Cats vs Dogs uses a portrait, while
    # archived Drop Four builds draw a flat gold token.
    radius = max(4, min(image.width, image.height) // 70)
    patch = image.crop((x - radius, bottom_piece - radius, x + radius, bottom_piece + radius))
    warm_pixels = sum(
        (r > 110 and r > g * 1.2 and r > b * 1.35)
        or (r > 220 and g > 175 and 60 < b < 145)
        for r, g, b in patch.getdata()
    )
    return warm_pixels > patch.width * patch.height // 8


def launch_setup():
    adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
    adb("shell", "wm", "dismiss-keyguard")
    adb("shell", "am", "start", "-W", "-n", ACTIVITY)
    for _ in range(3):
        if find("Welcome to Zompado"):
            return
        if find("Pixel Launcher isn't responding") and (close := find("Close app")):
            tap(*close)
            adb("shell", "am", "start", "-W", "-n", ACTIVITY)
    wait("first-run Setup", lambda: find("Welcome to Zompado"), seconds=65)


def main():
    launch_setup()
    if find("Allow camera") is None:
        adb("shell", "input", "swipe", 350, 1000, 350, 500, 350)
    press("Allow camera")
    press("While using the app")
    wait("camera permission to be granted", lambda: b"android.permission.CAMERA: granted=true"
         in adb("shell", "dumpsys", "package", APP))
    if find("Finish setup") is None:
        adb("shell", "input", "swipe", 350, 1100, 350, 400, 350)
    press("Finish setup")
    wait("an empty game library", lambda: find("Your library is empty"))
    check_keyboard_rotation()
    press("Get Games")
    press("Install")
    wait("the downloaded game", lambda: find("Cats vs Dogs"), seconds=50)
    # Enter the game's own LÖVE scene and place a center token.
    press("Play")
    press("Pass & Play")
    wait("a rendered LÖVE board", board, seconds=50)
    set_orientation(1)
    _, x, y, _ = wait("a rendered board in landscape", board)
    tap(x, y)
    time.sleep(0.45)
    tap(x, y)
    wait("the token placed in landscape", has_center_token)
    screenshot().save(DIAGNOSTICS / "landscape-board.png")
    set_orientation(0)
    wait("the same token after rotating back to portrait", has_center_token)
    time.sleep(3)
    adb("shell", "am", "force-stop", APP)
    adb("shell", "am", "start", "-n", ACTIVITY)
    press("Play")
    press("Pass & Play")
    wait("the restored token", has_center_token, seconds=50)
    screenshot().save(DIAGNOSTICS / "restored-board.png")
    adb("shell", "input", "keyevent", 4)
    press("Game options")
    press("Remove")
    press("Remove")
    wait("the empty library after removal", lambda: find("Your library is empty"))
    print("PASS: fresh empty library, catalog download, native LÖVE view, touch input, save restore after restart, and removal.")


try:
    main()
finally:
    try:
        screenshot().save(DIAGNOSTICS / "last-screen.png")
        (DIAGNOSTICS / "logcat.txt").write_bytes(adb("logcat", "-d", "-t", "1400"))
    except (OSError, subprocess.SubprocessError):
        pass
