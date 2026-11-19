#!/usr/bin/env python3
"""Exercise the preview's RPC sequence using two disposable relay profiles."""
import json
import os
import select
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from pathlib import Path

RELAY = "DCACCOUNT:https://nine.testrun.org/new"


class Core:
    def __init__(self, executable, folder):
        self.pipe = subprocess.Popen(
            [executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0,
            env={**os.environ, "DC_ACCOUNTS_PATH": str(folder), "RUST_LOG": "off"},
        )
        self.sequence = 0

    def close(self):
        if self.pipe.stdin.closed:
            return
        self.pipe.stdin.close()
        try:
            self.pipe.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.pipe.kill()
            self.pipe.wait(timeout=5)
        finally:
            self.pipe.stdout.close()

    def rpc(self, method, *args):
        self.sequence += 1
        request = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": args}
        self.pipe.stdin.write((json.dumps(request) + "\n").encode())
        if not select.select([self.pipe.stdout], [], [], 110)[0]:
            raise RuntimeError(f"{method} timed out")
        line = self.pipe.stdout.readline()
        if not line:
            raise RuntimeError(f"Core stopped during {method}")
        result = json.loads(line)
        if result.get("id") != self.sequence or "error" in result:
            raise RuntimeError(f"{method} did not succeed")
        return result["result"]

    def setup(self, name):
        self.account = self.rpc("add_account")
        self.rpc("set_config", self.account, "displayname", name)
        self.rpc("init_transports", self.account, RELAY)
        if not self.rpc("is_configured", self.account):
            raise RuntimeError("The relay profile did not configure")
        self.rpc("start_io", self.account)

    def encrypted_chat(self, chat):
        full = self.rpc("get_full_chat_by_id", self.account, chat)
        return full["isEncrypted"] and full["canSend"] and full["chatType"] == "Single"

    def friend_chat(self):
        for chat in self.rpc("get_chatlist_entries", self.account, 2, None, None):
            full = self.rpc("get_full_chat_by_id", self.account, chat)
            if not full["isSelfTalk"] and not full["isDeviceChat"] and self.encrypted_chat(chat):
                return chat
        return None

    def has_message(self, chat, text):
        ids = self.rpc("get_message_ids", self.account, chat, False, False)
        messages = self.rpc("get_messages", self.account, ids)
        return any(row.get("text") == text and row.get("showPadlock") is True
                   for row in messages.values())


def wait_for(label, predicate):
    deadline = time.monotonic() + 100
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(3)
    raise RuntimeError(f"Timed out waiting for {label}")


def main():
    executable = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="zompado-relay-check-") as root, ExitStack() as cleanup:
        alice = Core(executable, Path(root) / "alice")
        cleanup.callback(alice.close)
        bob = Core(executable, Path(root) / "bob")
        cleanup.callback(bob.close)
        with ThreadPoolExecutor(max_workers=2) as workers:
            profiles = (workers.submit(core.setup, name) for core, name in (
                (alice, "Zompado verification A"), (bob, "Zompado verification B")))
            for profile in list(profiles):
                profile.result()
        print("Configured two disposable Chatmail profiles.", flush=True)

        invite = alice.rpc("get_chat_securejoin_qr_code", alice.account, None)
        if bob.rpc("check_qr", bob.account, invite)["kind"] != "askVerifyContact":
            raise RuntimeError("Core did not recognize the friend invitation")
        bob_chat = bob.rpc("secure_join", bob.account, invite)
        alice_chat = wait_for("the inviter's encrypted conversation", alice.friend_chat)
        wait_for("the accepting device's encrypted conversation", lambda: bob.encrypted_chat(bob_chat))
        print("SecureJoin created matching encrypted conversations.", flush=True)

        bob_text = "Zompado relay smoke check B to A"
        bob.rpc("misc_send_text_message", bob.account, bob_chat, bob_text)
        wait_for("the first encrypted message", lambda: alice.has_message(alice_chat, bob_text))
        alice_text = "Zompado relay smoke check A to B"
        alice.rpc("misc_send_text_message", alice.account, alice_chat, alice_text)
        wait_for("the encrypted reply", lambda: bob.has_message(bob_chat, alice_text))
        print("Both profiles exchanged and verified encrypted messages.", flush=True)

        match_id = "085806e1e43b4bbc9e7f0c2a2027b001"
        marker = "ZOMPADO_MATCH_V1 "
        def turn(kind, **fields):
            return marker + json.dumps({"id": match_id, "type": kind, **fields}, separators=(",", ":"))

        invite = turn("invite", game="https://justtrysomthing.github.io/zompado/game/"
                      "?id=drop-four&build=2&sha=8cf42ab96bec8bf1075e9e744a2dfb475f9147edbd51fd54c7b0b220727186a3")
        accept = turn("accept")
        move = turn("move", previous="", column=3)
        reply = turn("move", previous="3", column=4)
        for sender, sender_chat, receiver, receiver_chat, record in (
            (alice, alice_chat, bob, bob_chat, invite),
            (bob, bob_chat, alice, alice_chat, accept),
            (alice, alice_chat, bob, bob_chat, move),
            (bob, bob_chat, alice, alice_chat, reply),
        ):
            sender.rpc("misc_send_text_message", sender.account, sender_chat, record)
            wait_for("an encrypted match update", lambda: receiver.has_message(receiver_chat, record))
        for core, chat in ((alice, alice_chat), (bob, bob_chat)):
            ids = core.rpc("search_messages", core.account, match_id, chat)
            messages = core.rpc("get_messages", core.account, ids)
            records = {m.get("text") for m in messages.values()}
            if not {invite, accept, move, reply}.issubset(records):
                raise RuntimeError("Match history is incomplete")
        print("Both profiles exchanged match invites and turns and recovered the full history.", flush=True)

        def voice_message(core, chat):
            ids = core.rpc("get_message_ids", core.account, chat, False, False)
            rows = core.rpc("get_messages", core.account, ids)
            for msg in rows.values():
                if (
                    msg.get("viewType") == "Call"
                    and msg.get("fromId") != 1
                    and msg.get("showPadlock") is True
                    and msg.get("chatId") == chat
                ):
                    return msg["id"]
            return None

        def voice_state(core, message, state):
            return core.rpc("call_info", core.account, message)["state"]["kind"] == state

        def event(core, kind, message):
            # The caller already waited for the state produced in the same RPC event.
            for _ in range(8):
                batch = core.rpc("get_next_event_batch")
                for entry in batch:
                    record = entry["event"]
                    if record["kind"] == kind and record.get("msg_id") == message:
                        return record
            raise RuntimeError(f"Missing {kind} event")

        offer = "v=0\r\ns=Preview offer\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
        answer = "v=0\r\ns=Preview answer\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
        placed = alice.rpc("place_outgoing_call", alice.account, alice_chat, offer, False)
        incoming = wait_for("an encrypted voice invitation", lambda: voice_message(bob, bob_chat))
        offered = event(bob, "IncomingCall", incoming)
        if offered["chat_id"] != bob_chat or offered["place_call_info"] != offer or offered["has_video"]:
            raise RuntimeError("Incoming call event did not preserve the offer")
        bob.rpc("accept_incoming_call", bob.account, incoming, answer)
        wait_for("a voice answer", lambda: voice_state(alice, placed, "Active"))
        accepted = event(alice, "OutgoingCallAccepted", placed)
        if accepted["chat_id"] != alice_chat or accepted["accept_call_info"] != answer:
            raise RuntimeError("Call acceptance event did not preserve the answer")
        bob.rpc("end_call", bob.account, incoming)
        wait_for("remote call closure", lambda: voice_state(alice, placed, "Completed"))
        event(alice, "CallEnded", placed)
        print("Verified encrypted voice signaling, acceptance, and remote hangup.", flush=True)

        bob_account = bob.account
        bob.rpc("stop_io", bob_account)
        bob.close()
        offline_text = "Zompado relay smoke check while receiver is stopped"
        sent = alice.rpc("misc_send_text_message", alice.account, alice_chat, offline_text)
        wait_for("server acceptance while the receiver is stopped", lambda:
                 alice.rpc("get_messages", alice.account, [sent])[str(sent)]["state"] >= 26)
        restarted = Core(executable, Path(root) / "bob")
        cleanup.callback(restarted.close)
        restarted.account = bob_account
        restarted.rpc("start_io", bob_account)

        def fresh_after_restart():
            ids = restarted.rpc("get_fresh_msgs", bob_account)
            rows = restarted.rpc("get_messages", bob_account, ids)
            return any(
                m.get("text") == offline_text and m.get("showPadlock") is True
                for m in rows.values()
            )

        wait_for("fresh messages detected after restarting Chatmail", fresh_after_restart)
        print("A separately restarted Core found encrypted activity that arrived while it was stopped.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        raise SystemExit(str(error)) from None
