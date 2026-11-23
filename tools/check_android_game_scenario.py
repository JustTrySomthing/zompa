"""Run a submitted game's declarative three-mode Android checks."""

import json
from pathlib import Path
import sys
import time

import numpy as np

from check_android_friends import Phone, wait


def point(values):
    if (not isinstance(values, list) or len(values) != 2
            or any(type(value) not in (float, int) or not 0 < value < 1 for value in values)):
        raise ValueError("A tap must be two normalized screen coordinates.")
    return values


def board_region(image, values):
    height, width = image.shape[:2]
    left, top, right, bottom = values
    return image[round(top * height):round(bottom * height),
                 round(left * width):round(right * width)].astype(np.int16)


def tap(phone, location):
    height, width = phone.image().shape[:2]
    x, y = point(location)
    phone.shell("input", "tap", round(width * x), round(height * y))


def snapshot(phone, region):
    time.sleep(0.5)
    return board_region(phone.image(), region)


def changed(phone, region, old, description):
    def compare():
        image = board_region(phone.image(), region)
        return image if np.mean(np.max(np.abs(image - old), axis=2) > 24) >= 0.003 else None

    # NumPy arrays have no scalar truth value.
    def observed():
        current = compare()
        return (current,) if current is not None else None

    return wait(description, observed, 35)[0]


def still_changes(phone, region, old, description):
    time.sleep(0.8)
    return changed(phone, region, old, description)


def play_local(phone, region, spec, mode):
    phone.press("Play")
    phone.press(mode)
    phone.see("How to play")
    for location in spec.get("start", []):
        tap(phone, location)
        time.sleep(0.6)
    time.sleep(1.5)
    previous = snapshot(phone, region)
    for index, move in enumerate(spec["moves"]):
        tap(phone, move)
        previous = still_changes(phone, region, previous, f"{mode} move {index + 1}")
    if mode == "Single Player":
        still_changes(phone, region, previous, "computer reply")
    phone.back()
    phone.see("Play")
    print(f"PASS: {mode} changed the game board as expected.", flush=True)


def main():
    spec = json.loads(Path(sys.argv[2]).read_text())
    title = json.loads(Path(sys.argv[3]).read_text())["games"][0]["title"]
    if spec.get("schema") != 1:
        raise ValueError("Game scenarios need schema 1.")
    region = spec["board"]
    if (len(region) != 4 or not all(type(n) in (int, float) for n in region)
            or not (0 < region[0] < region[2] < 1 and 0 < region[1] < region[3] < 1)):
        raise ValueError("The board needs left, top, right and bottom screen fractions.")
    for name, count in (("solo", 1), ("local", 2), ("online", 2)):
        scenario = spec[name]
        if len(scenario["moves"]) != count or len(scenario.get("start", [])) > 8:
            raise ValueError(f"{name} needs {count} test moves and at most eight setup taps.")
        for location in scenario.get("start", []) + scenario["moves"]:
            point(location)
    alice, bob = Phone(5554, "Alice"), Phone(5556, "Bob")
    alice.profile()
    bob.profile()
    bob.press("Contacts")
    bob.press("Accept an invite")
    bob.type(alice.invite())
    bob.back()
    bob.press("Accept")
    alice.see("Bob", 120)
    bob.see("Alice", 120)
    alice.press("Games")
    alice.press("Get Games")
    alice.see(title)
    alice.press("Install")
    alice.see("Play", 100)
    play_local(alice, region, spec["solo"], "Single Player")
    play_local(alice, region, spec["local"], "Pass & Play")
    alice.press("Chats")
    alice.press("Bob")
    alice.press("Invite to play a game")
    alice.press(title)
    alice.press("Invite")
    bob.press("Accept", 120)
    alice.press("Play Now", 120)
    alice.see("Your turn", 120)
    bob.see_friend_turn("Alice", 120)
    for phone in (alice, bob):
        phone.see("How to play")
        for location in spec["online"].get("start", []):
            tap(phone, location)
            time.sleep(0.6)
    for sender, receiver, name, move in (
        (alice, bob, "Bob", spec["online"]["moves"][0]),
        (bob, alice, "Alice", spec["online"]["moves"][1]),
    ):
        old = snapshot(receiver, region)
        tap(sender, move)
        receiver.see("Your turn", 100)
        sender.see_friend_turn(name)
        still_changes(receiver, region, old, f"delivered move to {name}")
    print("PASS: both Android players rendered a delivered online turn.", flush=True)


if __name__ == "__main__":
    main()
