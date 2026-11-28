"""Check the app's library and embedded game view on a fresh Android emulator."""

import io
import os
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
    serial = os.environ.get("ANDROID_SERIAL")
    device = ["-s", serial] if serial else []
    return subprocess.check_output([ADB, *device, *map(str, args)], timeout=25)


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
        adb("shell", "uiautomator", "dump", "/sdcard/zompa.xml")
        data = adb("shell", "cat", "/sdcard/zompa.xml")
        (DIAGNOSTICS / "window.xml").write_bytes(data)
        for node in ET.fromstring(data).iter("node"):
            candidates = [node.get("text", ""), node.get("content-desc", "")]
            if not any(label in candidate.splitlines() for candidate in candidates):
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


def board():
    image = screenshot()
    # Center-line crossings locate the solid blue board around the center column.
    x = image.width // 2
    blue = (38, 69, 125)
    ys = [
        y for y in range(image.height * 2 // 9, image.height * 8 // 9)
        if all(abs(a - b) <= 3 for a, b in zip(image.getpixel((x, y)), blue))
    ]
    if len(ys) < 30 or ys[-1] - ys[0] < image.width // 2:
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
    radius = max(4, image.width // 70)
    patch = image.crop((x - radius, bottom_piece - radius, x + radius, bottom_piece + radius))
    warm_pixels = sum(
        (r > 110 and r > g * 1.2 and r > b * 1.35)
        or (r > 220 and g > 175 and 60 < b < 145)
        for r, g, b in patch.getdata()
    )
    return warm_pixels > patch.width * patch.height // 8


def setup_visible():
    # A cold CI emulator can put a launcher ANR in front of the app.
    if find("Pixel Launcher isn't responding"):
        if close := find("Close app"):
            tap(*close)
        return None
    return find("Setup")


def solo_start_button():
    image = screenshot()
    # The centered Play button on the default Cats side has a solid pink fill.
    x1, x2 = image.width * 29 // 100, image.width * 71 // 100
    rows = []
    for y in range(image.height // 2, image.height * 9 // 10):
        matches = sum(
            all(abs(a - b) <= 6 for a, b in zip(image.getpixel((x, y)), (255, 173, 199)))
            for x in range(x1, x2, 4)
        )
        if matches > (x2 - x1) // 8:
            rows.append(y)
    if len(rows) >= 12:
        return image.width // 2, rows[len(rows) // 2]


def check_second_piece(empty, played, x, y, bottom, error):
    cell = round((bottom - y) / 2.5)
    radius = max(4, cell // 6)
    points = [(x + col * cell, bottom) for col in (-3, -2, -1, 1, 2, 3)]
    points.append((x, bottom - cell))
    for px, py in points:
        rect = (px - radius, py - radius, px + radius, py + radius)
        before = empty.crop(rect)
        after = played.crop(rect)
        changed = sum(
            max(abs(a - b) for a, b in zip(first, second)) > 36
            for first, second in zip(before.getdata(), after.getdata())
        )
        if changed > before.width * before.height // 3:
            return
    raise RuntimeError(error)


def check_single_player():
    press("Play")
    press("Single Player")
    tap(*wait("Cats vs Dogs Single Player start button", solo_start_button, seconds=60))
    empty, x, y, bottom = wait("the Single Player board", board, seconds=50)
    tap(x, y)
    wait("the player’s Single Player move", has_center_token)
    time.sleep(3)
    played, _, _, _ = wait("the Single Player board after the computer's turn", board)
    check_second_piece(empty, played, x, y, bottom, "No computer reply appeared in Single Player")
    press("Pause")
    press("New Game")
    press("Start new game")
    tap(*wait("the new Single Player start button", solo_start_button, seconds=60))
    wait("an empty new Single Player board", lambda: board() and not has_center_token())
    press("Pause")
    press("Quit match")
    press("Quit match")
    print("PASS: Single Player opened in Android and the computer replied.", flush=True)


def main():
    adb("shell", "am", "start", "-n", ACTIVITY)
    wait("Setup", setup_visible, seconds=75)
    for _ in range(4):
        if find("Allow camera"):
            break
        adb("shell", "input", "swipe", 350, 1000, 350, 500, 350)
    press("Allow camera")
    press("While using the app")
    wait("camera permission to be granted", lambda: b"android.permission.CAMERA: granted=true"
         in adb("shell", "dumpsys", "package", APP))
    for _ in range(4):
        if find("Finish setup"):
            break
        adb("shell", "input", "swipe", 350, 1100, 350, 400, 350)
    press("Finish setup")
    press("Games")
    wait("an empty game library", lambda: find("Your library is empty"))
    press("Get Games")
    press("Install")
    wait("the downloaded game", lambda: find("Cats vs Dogs"), seconds=50)
    check_single_player()
    # Enter the game's own LÖVE scene and place a center token.
    press("Play")
    press("Pass & Play")
    empty, x, y, bottom = wait("a rendered LÖVE board", board, seconds=50)
    tap(x, y)
    time.sleep(0.45)
    tap(x, y)
    wait("the placed token", has_center_token)
    if os.environ.get("ZOMPA_GAME_RELEASE_CHECK") == "1":
        time.sleep(0.9)
        tap(x, y)
        time.sleep(1)
        played, _, _, _ = wait("the Pass & Play board after the second turn", board)
        check_second_piece(empty, played, x, y, bottom, "No second move appeared in Pass & Play")
        press("How to play")
        wait("the package's mode instructions", lambda: find(
            "Pass & Play: take turns on the same device."
        ))
        press("Back to game")
        print("PASS: Pass & Play accepted turns from both players and opened packaged help.", flush=True)
    time.sleep(3)
    adb("shell", "am", "force-stop", APP)
    adb("shell", "am", "start", "-n", ACTIVITY)
    press("Games")
    press("Active Games")
    press("Resume Game")
    wait("the restored token", has_center_token, seconds=50)
    screenshot().save(DIAGNOSTICS / "restored-board.png")
    press("Pause")
    press("New Game")
    press("Cancel")
    press("Resume")
    wait("the same placed token after cancelling New Game", has_center_token)
    press("Pause")
    press("New Game")
    press("Start new game")
    wait("an empty Pass & Play board after New Game", lambda: board() and not has_center_token(), seconds=50)
    _, x, y, _ = wait("the new Pass & Play board", board)
    tap(x, y)
    time.sleep(0.45)
    tap(x, y)
    wait("a placed token in the new Pass & Play round", has_center_token)
    adb("shell", "input", "keyevent", 4)
    press("Close active games")
    press("Play")
    press("Pass & Play")
    wait("a fresh board", lambda: board() and not has_center_token())
    press("Pause")
    press("Quit match")
    press("Quit match")
    press("Active Games")
    wait("the cleared active games list", lambda: find("No active games"))
    press("Close active games")
    press("Play")
    press("Pass & Play")
    wait("a fresh board after quitting", lambda: board() and not has_center_token())
    adb("shell", "input", "keyevent", 4)
    press("Active Games")
    press("End Game")
    press("End Game")
    wait("the saved game to disappear from Active Games", lambda: find("No active games"))
    press("Close active games")
    press("Game options")
    press("Remove")
    press("Remove")
    wait("the empty library after removal", lambda: find("Your library is empty"))
    print("PASS: fresh empty library, catalog download, native LÖVE view, touch input, explicit save restore after restart, confirmed and cancelled pause-menu restarts, fresh rounds, quit cleanup from the board and Active Games, and removal.")


try:
    main()
finally:
    try:
        screenshot().save(DIAGNOSTICS / "last-screen.png")
        (DIAGNOSTICS / "logcat.txt").write_bytes(adb("logcat", "-d", "-t", "1400"))
    except (OSError, subprocess.SubprocessError):
        pass
