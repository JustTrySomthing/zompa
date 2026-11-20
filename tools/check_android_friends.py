"""Use two independent Android installs to verify Zompado friends and turns."""

import re
import shlex
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

import cv2
import numpy as np

APP = "io.tablecircle.prototype"
ACTIVITY = APP + "/.MainActivity"


def wait(label, predicate, seconds=55):
    expires = time.monotonic() + seconds
    while time.monotonic() < expires:
        result = predicate()
        if result:
            return result
        time.sleep(1)
    raise RuntimeError(f"Timed out waiting for {label}")


class Phone:
    def __init__(self, port, name):
        self.serial = f"emulator-{port}"
        self.name = name

    def adb(self, *args):
        result = subprocess.run(
            [sys.argv[1], "-s", self.serial, *map(str, args)],
            capture_output=True, timeout=25,
        )
        if result.returncode:
            raise RuntimeError(f"{self.name}: adb {args[0]} failed")
        return result.stdout

    def shell(self, *args):
        return self.adb("shell", *args)

    def image(self):
        data = self.adb("exec-out", "screencap", "-p")
        return cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)

    def find(self, label):
        try:
            self.shell("uiautomator", "dump", "/sdcard/zompado-friends.xml")
            layout = self.shell("cat", "/sdcard/zompado-friends.xml")
            editable = []
            for node in ET.fromstring(layout).iter("node"):
                x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds", "")))
                if x2 <= x1 or y2 <= y1:
                    continue
                center = ((x1 + x2) // 2, (y1 + y2) // 2)
                if label in (node.get("text", "") + "\n" + node.get("content-desc", "")).splitlines():
                    return center
                if node.get("class") == "android.widget.EditText":
                    editable.append(center)
            if label == "<input>" and len(editable) == 1:
                return editable[0]
        except (RuntimeError, ET.ParseError):
            return None
        return None

    def labels(self):
        self.shell("uiautomator", "dump", "/sdcard/zompado-friends.xml")
        layout = self.shell("cat", "/sdcard/zompado-friends.xml")
        values = [node.get("content-desc") or node.get("text") for node in ET.fromstring(layout).iter("node")]
        return [label for label in values if label and len(label) <= 60]

    def see(self, label, seconds=55):
        return wait(f"{self.name} to show {label}", lambda: self.find(label), seconds)

    def press(self, label, seconds=55):
        self.shell("input", "tap", *self.see(label, seconds))

    def type(self, text):
        self.press("<input>")
        self.shell("input text " + shlex.quote(text.replace(" ", "%s")))

    def back(self):
        self.shell("input", "keyevent", 4)

    def start(self):
        result = self.shell("am", "start", "-W", "-n", ACTIVITY).decode()
        if "Error" in result or "Exception" in result:
            raise RuntimeError(f"{self.name}: could not launch Zompado: {result}")

    def stop_background_process(self):
        self.shell("input", "keyevent", 3)
        def process():
            return self.shell(f"pidof {APP} || true").decode().split()
        for pid in process():
            if pid.isdecimal():
                # Run under the debug app's UID so this also works if LMK considers it active.
                self.shell("run-as", APP, "kill", "-9", pid)
        wait(f"{self.name}'s process to stop without force-stop", lambda: not process())

    def install_game(self):
        self.press("Get Games")
        self.see("Cats vs Dogs", 100)
        self.press("Install", 100)
        self.see("Play", 100)

    def profile(self):
        self.shell("pm", "grant", APP, "android.permission.POST_NOTIFICATIONS")
        self.shell("pm", "grant", APP, "android.permission.RECORD_AUDIO")
        self.start()
        self.see("Welcome to Zompado", 85)
        if not self.find("Finish setup"):
            self.shell("input", "swipe", 350, 1100, 350, 370, 400)
        self.press("Finish setup")
        self.press("Chats")
        self.type(self.name)
        self.back()
        self.press("Create chat profile")
        self.see("Invite friend", 120)

    def invite(self):
        self.press("Invite friend")
        self.see("Invite a friend")
        detector = cv2.QRCodeDetector()
        link = wait("a decodable invite QR", lambda: detector.detectAndDecode(self.image())[0], 30)
        self.press("Done")
        return link

    def turn(self):
        def board_center():
            image = self.image()
            if image is None:
                return None
            height, width = image.shape[:2]
            x = width // 2
            blue = np.array([125, 69, 38])
            rows = np.where(np.max(np.abs(image[:, x].astype(int) - blue), axis=1) <= 3)[0]
            if len(rows) > 30 and rows[-1] - rows[0] > width // 2:
                return x, int(rows[len(rows) // 2])
            return None
        self.shell("input", "tap", *wait(f"{self.name} online board", board_center, 75))


def check_voice(alice, bob):
    alice.press("Voice call")
    bob.see("Incoming call from Alice", 75)
    alice.see("Calling Bob…", 20)
    bob.press("Answer")
    alice.see("Voice call with Bob", 65)
    bob.see("Voice call with Alice", 65)
    bob.press("Mute microphone")
    bob.press("Unmute microphone")
    bob.press("Turn on speaker")
    bob.press("Turn off speaker")
    bob.press("End call")
    wait("remote call closure", lambda: not alice.find("End call"))
    print("PASS: two Android WebRTC endpoints connected, mute and speaker controls responded, and remote hangup cleared.", flush=True)


def check_match(alice, bob):
    alice.press("Invite to a Cats vs Dogs match")
    alice.press("Send match invite")
    bob.press("Open Cats vs Dogs match", 100)
    bob.press("Install if needed and accept", 100)
    bob.see("Your friend’s turn", 100)
    alice.press("Open Cats vs Dogs match")
    alice.see("Your turn", 100)
    alice.press("Install if needed and open board")
    bob.stop_background_process()
    alice.turn()
    alice.see("Your friend’s turn")
    bob.shell("cmd", "jobscheduler", "run", "-f", APP, 291)
    bob.shell("cmd", "statusbar", "expand-notifications")
    bob.press("New friend activity", 75)
    bob.see("Your turn", 75)
    bob.turn()
    bob.see("Your friend’s turn")
    alice.see("Your turn", 100)
    print("PASS: an Android background job recovered a move, its alert opened the exact board, and the reply returned.", flush=True)


def main():
    alice, bob = Phone(5554, "Alice"), Phone(5556, "Bob")
    alice.profile()
    bob.profile()
    bob.press("Accept invite")
    bob.press("Scan QR code")
    bob.shell("input", "tap", *wait("the camera permission denial button",
        lambda: bob.find("Don’t allow") or bob.find("Don't allow")))
    bob.see("Open camera settings")
    bob.press("Scan QR code")
    bob.press("While using the app")
    bob.see("Point the camera at your friend’s invite QR code", 40)
    bob.back()
    bob.see("Scan QR code")
    print("PASS: Android requested camera access, handled denial, and opened the built-in QR scanner.", flush=True)

    link = alice.invite()
    bob.type(link)
    bob.back()
    bob.press("Accept")
    alice.press("Bob", 120)
    bob.see("Alice", 120)
    print("PASS: paired two independent Android installs using the app’s friend invite.", flush=True)

    # Run the two independent checks even if voice media fails on the emulators.
    voice_error = None
    try:
        check_voice(alice, bob)
    except RuntimeError as error:
        voice_error = error
        for phone in (alice, bob):
            print(f"{phone.name} while waiting for the call:", phone.labels(), flush=True)
            logs = phone.adb("logcat", "-d", "-t", "800", "-s", "flutter:E").decode(errors="replace")
            if logs.strip():
                print(logs, flush=True)
            for action in ("End call", "Decline", "Dismiss call message"):
                if point := phone.find(action):
                    phone.shell("input", "tap", *point)
        print(f"Voice check failed: {error}", flush=True)

    alice.back()
    alice.press("Games")
    alice.install_game()
    alice.press("Chats")
    alice.press("Bob")
    check_match(alice, bob)
    if voice_error:
        raise voice_error


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.SubprocessError):
        for port in (5554, 5556):
            phone = Phone(port, f"emulator-{port}")
            try:
                print(f"{phone.name} focus:", flush=True)
                print(phone.shell("dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' || true").decode())
                print(phone.adb("logcat", "-b", "crash", "-d", "-t", "120").decode())
                print("Visible labels:", phone.labels())
            except (RuntimeError, subprocess.SubprocessError, ET.ParseError):
                pass
        raise
