"""Use two independent Android installs to verify Zompa friends and turns."""

import os
import re
import shlex
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

import cv2
import numpy as np

try:
    import zxingcpp
except ModuleNotFoundError:
    zxingcpp = None

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

    def find(self, label, *, checked=None):
        try:
            self.shell("uiautomator", "dump", "/sdcard/zompa-friends.xml")
            layout = self.shell("cat", "/sdcard/zompa-friends.xml")
            editable = []
            send_button = None
            for node in ET.fromstring(layout).iter("node"):
                x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds", "")))
                if x2 <= x1 or y2 <= y1:
                    continue
                center = ((x1 + x2) // 2, (y1 + y2) // 2)
                labels = (node.get("text", "") + "\n" + node.get("content-desc", "")).splitlines()
                if label in labels and (checked is None or node.get("checked") == str(checked).lower()):
                    return center
                if "Send message" in labels:
                    send_button = center
                if node.get("class") == "android.widget.EditText":
                    editable.append(center)
            if label == "<input>" and editable:
                if len(editable) == 1:
                    return editable[0]
                if send_button is not None:
                    # The message composer shares a row with Send, below search.
                    return min(editable, key=lambda point: abs(point[1] - send_button[1]))
        except (RuntimeError, ET.ParseError):
            return None
        return None

    def labels(self):
        self.shell("uiautomator", "dump", "/sdcard/zompa-friends.xml")
        layout = self.shell("cat", "/sdcard/zompa-friends.xml")
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
            raise RuntimeError(f"{self.name}: could not launch Zompa: {result}")

    def stop_background_process(self):
        self.shell("input", "keyevent", 3)
        def process():
            return self.shell(f"pidof {APP} || true").decode().split()
        previous = process()
        for pid in previous:
            if pid.isdecimal():
                # Run under the debug app's UID so this also works if LMK considers it active.
                self.shell("run-as", APP, "kill", "-9", pid)
        wait(f"{self.name}'s process to stop without force-stop",
             lambda: not set(previous).intersection(process()))

    def install_game(self):
        self.press("Get Games")
        self.see("Cats vs Dogs", 100)
        self.press("Install", 100)
        self.see("Play", 100)

    def profile(self):
        self.shell("pm", "grant", APP, "android.permission.POST_NOTIFICATIONS")
        self.shell("pm", "grant", APP, "android.permission.RECORD_AUDIO")
        self.start()
        self.see("Welcome to Zompa", 85)
        for _ in range(4):
            if self.find("Finish setup"):
                break
            self.shell("input", "swipe", 350, 1100, 350, 370, 400)
        self.press("Finish setup")
        self.see("Create chat profile")
        self.type(self.name)
        self.back()
        self.press("Create chat profile")
        self.see("Inbox", 120)

    def invite(self):
        self.press("Contacts")
        self.press("Share my invite")
        self.see("Share my invite")
        detector = cv2.QRCodeDetector()
        def decode_invite():
            image = self.image()
            if image is None:
                return None
            if zxingcpp is not None:
                code = zxingcpp.read_barcode(image, formats=zxingcpp.BarcodeFormat.QRCode)
                if code:
                    return code.text
            return detector.detectAndDecode(image)[0]

        link = wait("a decodable invite QR", decode_invite, 45)
        self.press("Done")
        self.back()
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


def active_alerts(phone, tag):
    dump = phone.shell("dumpsys", "notification").decode()
    active = re.search(r"(?m)^  Notification List:\s*\n((?: {4}[^\n]*\n)*)", dump)
    if active is None:
        return []
    record = re.compile(rf"^    NotificationRecord\(.*\bpkg={re.escape(APP)} .*\btag={re.escape(tag)} ")
    return [line for line in active[1].splitlines() if record.match(line)]


def alert_posted(phone, tag, *, ringing=False):
    for line in active_alerts(phone, tag):
        if not ringing:
            return True
        # Android 15 prints flag names, while older versions print a bitmask.
        flags = re.search(r"\bflags=(\S+)", line)
        if "channel=incoming_calls_ringtone " not in line or flags is None:
            continue
        value = flags[1]
        if "INSISTENT" in value.split("|") or (
            re.fullmatch(r"0x[0-9a-fA-F]+", value) and int(value, 16) & 0x4
        ):
            return True
    return False


def sleep_phone(phone):
    phone.shell("input", "keyevent", "KEYCODE_SLEEP")
    wait(f"{phone.name}’s screen to go to sleep", lambda:
         re.search(rb"mWakefulness=(Asleep|Dozing)", phone.shell("dumpsys", "power")), 10)


def wake_phone(phone):
    phone.shell("input", "keyevent", "KEYCODE_WAKEUP")
    phone.shell("wm", "dismiss-keyguard")


def check_locked_call(alice, bob):
    # Verify a sticky native listener can receive an alert without reopening the app.
    bob.shell("cmd", "deviceidle", "whitelist", f"+{APP}")
    bob.stop_background_process()
    sleep_phone(bob)
    try:
        alice.type("Background delivery check")
        alice.back()
        alice.press("Send message")
        wait("a message alert while Bob’s screen is off",
             lambda: alert_posted(bob, "friend-activity-messages"), 75)
        alice.press("Voice call")
        alice.press("Call")
        wait("an incoming-call notification while Bob’s screen is off",
             lambda: alert_posted(bob, "voice", ringing=True), 75)
        wake_phone(bob)
        bob.shell("cmd", "statusbar", "expand-notifications")
        bob.press("Incoming Zompa call")
        bob.see("Incoming call from Alice")
        bob.press("Decline")
    except RuntimeError:
        print(f"Bob’s active call notifications: {active_alerts(bob, 'voice')}", flush=True)
        for phone in (alice, bob):
            app_log = phone.shell("run-as", APP, "cat", "files/app-log.txt").decode(errors="replace")
            for line in app_log.splitlines()[-20:]:
                print(f"{phone.name} App Log: {line}", flush=True)
        raise
    finally:
        if point := alice.find("End call"):
            alice.shell("input", "tap", *point)
        wake_phone(bob)
        bob.shell("cmd", "deviceidle", "whitelist", f"-{APP}")
        bob.start()
        if point := bob.find("Decline"):
            bob.shell("input", "tap", *point)
        bob.press("Alice")
    wait("the incoming-call notification to clear", lambda: not alert_posted(bob, "voice"))
    print("PASS: the restarted listener posted screen-off message and ringtone alerts, "
          "and the call alert reopened the right incoming call.", flush=True)


def check_voice(alice, bob):
    bob.press("<input>")
    alice.press("Voice call")
    alice.see("Call")
    alice.back()
    alice.see("Voice call")
    if bob.find("Incoming call from Alice"):
        raise RuntimeError("Opening the dialer started a call before confirmation")
    alice.press("Voice call")
    alice.press("Call")
    bob.see("Incoming call from Alice", 75)
    alice.see("Calling Bob…", 20)
    bob.press("Answer")
    alice.see("Voice call with Bob", 75)
    bob.see("Voice call with Alice", 75)
    bob.press("Mute microphone")
    bob.press("Unmute microphone")
    bob.press("Turn on speaker")
    bob.press("Turn off speaker")
    bob.press("Switch to video")
    bob.see("Video call with Alice", 30)
    alice.see("Video call with Bob", 30)
    wait("Alice to render Bob’s camera", lambda:
         b"Remote camera frame rendered" in alice.adb("logcat", "-d", "-s", "ZompaCall:I"), 30)
    bob.press("Hide preview")
    alice.see("Video call with Bob")
    bob.press("Show preview")
    alice.press("Switch to audio")
    alice.see("Voice call with Bob", 30)
    bob.see("Video call with Alice")
    alice.press("Switch to video")
    alice.see("Video call with Bob", 30)
    bob.press("Switch to audio")
    alice.see("Voice call with Bob", 30)
    bob.press("End call")
    wait("remote call closure", lambda: not alice.find("End call"))
    print("PASS: two Android WebRTC endpoints connected, received video from an enabled camera, toggled mute and speaker, and cleared remote hangup.", flush=True)


def check_message_tools(alice, bob):
    alice.type("Saved chat check")
    alice.back()
    alice.press("Send message")
    bob.see("Saved chat check", 100)
    bob.press("Save message")
    bob.see("Unsave message")
    bob.press("Saved")
    bob.see("Photos")
    bob.see("Saved chat check")
    bob.back()
    bob.press("React to message")
    bob.press("grinning face happy smile grin")
    bob.press("Done")
    alice.see("😀", 100)
    bob.press("Settings")
    bob.press("Notifications")
    mute = "Mute all notifications"
    bob.press(mute)
    wait("global notifications to be muted", lambda: bob.find(mute, checked=True))
    bob.press(mute)
    wait("global notifications to be unmuted", lambda: bob.find(mute, checked=False))
    bob.back()
    bob.back()
    bob.see("Voice call")
    print("PASS: saved an incoming message, opened Saved, reacted across devices, and toggled global mute in Settings.", flush=True)


def check_match(alice, bob, *, game_release=False):
    alice.press("Invite to play a game")
    alice.see("Choose a game")
    alice.see("Play with Bob")
    alice.press("Cats vs Dogs")
    bob.shell("cmd", "deviceidle", "whitelist", f"+{APP}")
    sleep_phone(bob)
    try:
        alice.press("Invite")
        wait("a game invitation alert while Bob’s screen is off",
             lambda: alert_posted(bob, "friend-activity-invites"), 75)
    finally:
        wake_phone(bob)
        bob.shell("cmd", "deviceidle", "whitelist", f"-{APP}")
    alice.see("Waiting for your friend to accept.", 100)
    alice.back()
    alice.back()
    alice.press("Games")
    alice.press("Play")
    alice.press("Resume an Active Game")
    alice.see("Cats vs Dogs with Bob")
    alice.press("Resume Game")
    alice.see("Waiting for your friend to accept.", 100)

    bob.press("Accept", 100)
    bob.see("Waiting for Alice to start the game.", 100)
    alice.press("Play Now", 100)
    bob.see("Alice’s turn", 100)
    alice.see("Your turn", 100)
    # This match must include the score fields that follow the move flag.
    if not (game_release and os.environ.get("ZOMPA_GENERIC_TURNS") == "1"):
        alice.see("ROUND 1")
        bob.see("ROUND 1")
    alice.back()
    alice.press("Resume Game")
    alice.see("Your turn", 100)
    print("PASS: Resume Game opened the board directly.", flush=True)
    if game_release:
        alice.turn()
        alice.see("Bob’s turn", 100)
        bob.see("Your turn", 100)
        bob.turn()
        bob.see("Alice’s turn", 100)
        alice.see("Your turn", 100)
        bob.press("Pause")
        bob.press("Quit match")
        bob.press("Quit match")
        alice.see("Match ended.", 100)
        print("PASS: Online 2 Player used two Android installs and exchanged Chatmail moves.", flush=True)
        return
    bob.press("Open match chat")
    bob.type("Game chat check")
    bob.back()
    bob.press("Send message")
    alice.see("New message in match chat", 90)
    assert not alice.find("Game chat check"), "Message text appeared over the board"
    alice.press("New message in match chat")
    alice.see("Game chat check")
    alice.press("Close chat panel")
    alice.see("Open match chat")
    bob.press("Close chat panel")
    print("PASS: the match chat indicator opened the message and cleared after reading.", flush=True)
    alice.press("Pause")
    bob.see("Alice paused the game.", 100)
    alice.press("Resume")
    bob.see("Alice’s turn", 100)
    bob.turn()
    bob.see("Alice’s turn")
    alice.see("Your turn", 100)
    bob.stop_background_process()
    alice.turn()
    alice.see("Bob’s turn")
    wait("a game activity alert from the restarted listener",
         lambda: alert_posted(bob, "friend-activity-gameActivity"), 75)
    bob.shell("cmd", "statusbar", "expand-notifications")
    bob.press("New game activity", 75)
    bob.see("Your turn", 75)
    bob.turn()
    bob.see("Alice’s turn")
    alice.see("Your turn", 100)
    bob.press("Pause")
    bob.press("Quit match")
    bob.press("Quit match")
    alice.see("Match ended.", 100)
    print("PASS: the online board opened on both phones after acceptance. The inviter took the first turn and the friend replied.", flush=True)
    print("PASS: the live Android listener recovered a move, its alert opened the exact board, and the reply returned.", flush=True)


def check_app_log(phone):
    prior = phone.shell("run-as", APP, "cat", "files/app-log.txt")
    startup = next((line for line in prior.splitlines() if b"App process started" in line), None)
    if startup is None:
        raise RuntimeError("App Log did not record startup")
    phone.shell("am", "force-stop", APP)
    wait("the app process to exit", lambda: not phone.shell(f"pidof {APP} || true").strip())
    phone.start()
    phone.press("Settings")
    for _ in range(3):
        if phone.find("App Log"):
            break
        phone.shell("input", "swipe", 350, 1060, 350, 380, 350)
    phone.press("App Log")
    phone.see("Copy Log")
    log = phone.shell("run-as", APP, "cat", "files/app-log.txt")
    if startup not in log or log.count(b"App process started") < 2:
        raise RuntimeError("App Log did not keep the first startup after reopening Zompa")
    phone.press("Clear Log")
    wait("App Log to clear", lambda: startup not in phone.shell(
        f"run-as {APP} cat files/app-log.txt 2>/dev/null || true"
    ))
    phone.press("Copy Log")
    # Android shows a clipboard overlay above the bottom of the app.
    time.sleep(8)
    phone.back()
    phone.back()
    phone.press("Chats")
    print("PASS: App Log kept activity across a restart and its Copy Log and Clear Log controls opened and ran.", flush=True)


def main():
    game_release = "--game-release" in sys.argv[2:]
    alice, bob = Phone(5554, "Alice"), Phone(5556, "Bob")
    alice.profile()
    if not game_release:
        check_app_log(alice)
    bob.profile()
    bob.press("Contacts")
    bob.press("Accept an invite")
    if not game_release:
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

        bob.type("https://example.org/not-an-invite")
        bob.back()
        bob.press("Accept")
        bob.see("Use a link from your friend’s Share my invite screen.")
        bob.press("Cancel")
        bob.press("Accept an invite")

    link = alice.invite()
    bob.type(link)
    bob.back()
    bob.press("Accept")
    alice.press("Bob", 120)
    bob.see("Alice", 120)
    print("PASS: paired two independent Android installs using the app’s friend invite.", flush=True)

    if game_release:
        alice.back()
        alice.press("Games")
        alice.install_game()
        alice.press("Chats")
        alice.press("Bob")
        check_match(alice, bob, game_release=True)
        return

    check_message_tools(alice, bob)

    # Run the two independent checks even if voice media fails on the emulators.
    voice_error = None
    try:
        check_locked_call(alice, bob)
    except RuntimeError as error:
        voice_error = error
        print(f"Locked call check failed: {error}", flush=True)
    try:
        check_voice(alice, bob)
    except RuntimeError as error:
        voice_error = voice_error or error
        for phone in (alice, bob):
            print(f"{phone.name} while waiting for the call:", phone.labels(), flush=True)
            logs = phone.adb("logcat", "-d", "-t", "800", "-s", "flutter:E", "ZompaCall:I").decode(errors="replace")
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
    log = alice.shell("run-as", APP, "cat", "files/app-log.txt")
    if b"Outgoing phone button pressed" not in log or b"WebRTC native initialization finished" not in log:
        raise RuntimeError("App Log did not record the call startup")
    print("PASS: App Log captured the outgoing tap and native WebRTC startup.", flush=True)


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
