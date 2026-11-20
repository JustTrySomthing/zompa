"""Verify bidirectional direct messages and audio calls with stock Delta Chat."""

import re
import shlex
from xml.etree import ElementTree

from check_android_friends import Phone, wait

DELTA = "chat.delta"
DELTA_ACTIVITY = DELTA + "/org.thoughtcrime.securesms.RoutingActivity"


def send(phone, message, button):
    phone.type(message)
    phone.press(button)


def delta_chat_with(phone, contact):
    phone.start()
    if not phone.find("Call"):
        phone.press(contact, 80)
    phone.see("Call")


def answer_zompado(phone, caller):
    # Reuse the independent-peer test's direct accessibility tap and wait for
    # the incoming controls to disappear before checking the media connection.
    phone.see("Incoming call from " + caller, 80)
    for _ in range(3):
        phone.press("Answer")
        if not phone.find("Answer"):
            return
    raise RuntimeError("Zompado remained on the incoming call screen after tapping Answer")


class DeltaPhone(Phone):
    def find(self, label):
        if label in {"Create New Profile", "Agree & Create Profile", "OK", "Answer", "End Call"}:
            return super().find(label.upper()) or super().find(label)
        return super().find(label)

    def call_cards(self):
        self.shell("uiautomator", "dump", "/sdcard/zompado-friends.xml")
        layout = self.shell("cat", "/sdcard/zompado-friends.xml")
        cards = []
        for node in ElementTree.fromstring(layout).iter("node"):
            labels = node.get("text", "") + "\n" + node.get("content-desc", "")
            if "Audio call" not in labels.splitlines():
                continue
            x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds", "")))
            if x1 < x2 and y1 < y2:
                cards.append(((x1 + x2) // 2, (y1 + y2) // 2))
        return sorted(set(cards), key=lambda point: point[1])

    def answer_incoming(self, previous_cards):
        def route():
            if answer := self.find("Answer"):
                return "answer", answer
            cards = self.call_cards()
            if len(cards) > previous_cards:
                return "card", cards[-1]
            return None

        kind, coordinates = wait("Delta Chat to show the new incoming call", route, 80)
        self.shell("input", "tap", *coordinates)
        if kind == "card":
            self.press("Answer", 15)
            print("Opened the incoming call from Delta Chat’s conversation card.", flush=True)

    def start(self):
        self.shell("am", "start", "-W", "-n", DELTA_ACTIVITY)

    def profile(self):
        for permission in ("POST_NOTIFICATIONS", "RECORD_AUDIO", "CAMERA"):
            self.shell("pm", "grant", DELTA, "android.permission." + permission)
        self.start()
        self.press("Create New Profile", 85)
        self.type(self.name)
        self.back()
        self.press("Agree & Create Profile")

    def accept_invite(self, link):
        self.shell("am start -W -a android.intent.action.VIEW -d "
                   + shlex.quote(link) + " -p " + DELTA)
        self.press("OK", 100)
        self.see("Call", 100)


def main():
    zompado = Phone(5554, "Zompado Alice")
    delta = DeltaPhone(5556, "Delta Bob")
    try:
        zompado.profile()
        delta.profile()
        delta.see("New Chat", 150)
        delta.accept_invite(zompado.invite())
        zompado.press(delta.name, 140)

        send(zompado, "Test from Zompado", "Send message")
        delta.see("Test from Zompado", 100)
        send(delta, "Reply from Delta Chat", "Send")
        zompado.see("Reply from Delta Chat", 100)
        print("PASS: stock Delta Chat and Zompado exchanged messages in both directions.", flush=True)

        # Delta Chat is the caller first, exercising its larger audio-call offer.
        delta.press("Call")
        delta.press("Audio Call")
        answer_zompado(zompado, delta.name)
        zompado.see("Voice call with " + delta.name, 65)
        delta.see("Connected", 65)
        delta.press("Camera")
        zompado.see("Video call with " + delta.name, 35)
        wait("Zompado to render Delta Chat camera frames", lambda:
             b"Remote camera frame rendered" in zompado.adb("logcat", "-d", "-s", "ZompadoCall:I"), 30)
        zompado.press("End call")
        wait("Delta Chat to close the remote call", lambda: not delta.find("End Call"))
        print("PASS: Delta Chat called Zompado, both clients connected, and Zompado rendered Delta Chat’s camera.", flush=True)

        delta_chat_with(delta, zompado.name)
        previous_cards = len(delta.call_cards())
        zompado.press("Voice call")
        delta.answer_incoming(previous_cards)
        zompado.see("Voice call with " + delta.name, 65)
        delta.see("Connected", 65)
        delta.press("End Call")
        wait("Zompado to close the remote call", lambda: not zompado.find("End call"))
        print("PASS: Zompado called Delta Chat and both clients connected.", flush=True)
    except Exception:
        for phone in (zompado, delta):
            try:
                print(f"{phone.name} screen:", phone.labels(), flush=True)
                phone.shell("uiautomator", "dump", "/sdcard/zompado-friends.xml")
                layout = phone.shell("cat", "/sdcard/zompado-friends.xml")
                keyboard = phone.shell("dumpsys input_method | grep -E 'mInputShown|mShowRequested' || true")
                print("Keyboard state:", keyboard.decode(errors="replace").strip(), flush=True)
                for node in ElementTree.fromstring(layout).iter("node"):
                    if any(key in (node.get("content-desc"), node.get("text")) for key in ("Answer", "Decline")):
                        print("Visible call control:", node.get("bounds"), "clickable:", node.get("clickable"), flush=True)
            except Exception:
                pass
            try:
                crash = phone.adb("logcat", "-b", "crash", "-d", "-t", "120")
                if crash.strip():
                    print(f"{phone.name} Android crash log:\n{crash.decode(errors='replace')}", flush=True)
                media = phone.adb("logcat", "-d", "-s", "ZompadoCall:I").decode(errors="replace")
                if media.strip():
                    print(media, flush=True)
            except Exception:
                pass
        raise


if __name__ == "__main__":
    main()
