"""Verify bidirectional direct messages and audio calls with stock Delta Chat."""

import shlex

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


class DeltaPhone(Phone):
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
        zompado.see("Incoming call from " + delta.name, 80)
        zompado.press("Answer")
        zompado.see("Voice call with " + delta.name, 65)
        delta.see("Connected", 65)
        zompado.press("End call")
        wait("Delta Chat to close the remote call", lambda: not delta.find("End Call"))
        print("PASS: Delta Chat called Zompado and both clients connected.", flush=True)

        delta_chat_with(delta, zompado.name)
        zompado.press("Voice call")
        delta.press("Answer", 85)
        zompado.see("Voice call with " + delta.name, 65)
        delta.see("Connected", 65)
        delta.press("End Call")
        wait("Zompado to close the remote call", lambda: not zompado.find("End call"))
        print("PASS: Zompado called Delta Chat and both clients connected.", flush=True)
    except Exception:
        for phone in (zompado, delta):
            try:
                print(f"{phone.name} screen:", phone.labels(), flush=True)
            except Exception:
                pass
        raise


if __name__ == "__main__":
    main()
