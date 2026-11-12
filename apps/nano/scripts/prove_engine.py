"""Drive an isolated harness-engine through its own RPC (scripts/prove-zig.sh).

Usage: python3 -I prove_engine.py PORT REPO_DIR

On a running engine at 127.0.0.1:PORT: create a project for REPO_DIR (a
synthetic git repository), a chat on the `mock` harness, run a turn and
read the reply back; open a terminal, run `echo` and read its output; edit
a file and ask for the checkout's git status and diff. Prints one JSON
summary line and exits non-zero on any failure. Every wait is bounded.
Standard library only.
"""

import base64
import json
import os
import socket
import struct
import sys
import time


class Engine:
    def __init__(self, port, timeout=10.0):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            "GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (port, key)
        )
        self.sock.sendall(req.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                raise RuntimeError("engine closed the handshake")
            head += chunk
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise RuntimeError("websocket upgrade refused: %r" % head[:80])
        self.next_id = 1
        self.pending = []

    def _send(self, text):
        data = text.encode()
        mask = os.urandom(4)
        n = len(data)
        if n < 126:
            hdr = struct.pack("!BB", 0x81, 0x80 | n)
        elif n < 65536:
            hdr = struct.pack("!BBH", 0x81, 0x80 | 126, n)
        else:
            hdr = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(hdr + mask + masked)

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("engine closed the socket")
            buf += chunk
        return buf

    def _recv(self):
        while True:
            b0, b1 = self._recv_exact(2)
            op = b0 & 0x0F
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._recv_exact(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._recv_exact(8))[0]
            payload = self._recv_exact(n)
            if op == 0x9:  # ping: answer
                self.sock.sendall(struct.pack("!BB", 0x8A, 0x80 | len(payload)) + b"\0\0\0\0" + payload)
                continue
            if op in (0x1, 0x2):
                return json.loads(payload.decode())
            if op == 0x8:
                raise RuntimeError("engine closed the socket")

    def call(self, method, params):
        """The first reply for a fresh id: {"ok": ...}, {"err": ...} or a stream's first {"item": ...}."""
        rid = self.next_id
        self.next_id += 1
        self._send(json.dumps({"id": rid, "method": method, "params": params}))
        while True:
            msg = self._recv()
            if msg.get("id") == rid:
                if "err" in msg:
                    raise RuntimeError("%s failed: %s" % (method, msg["err"]))
                return msg.get("ok", msg.get("item"))


def wait_for(what, fn, seconds):
    deadline = time.monotonic() + seconds
    while True:
        got = fn()
        if got:
            return got
        if time.monotonic() > deadline:
            raise RuntimeError("timed out after %ds waiting for %s" % (seconds, what))
        time.sleep(0.2)


def main():
    port = int(sys.argv[1])
    repo = os.path.realpath(sys.argv[2])
    summary = {}
    started = time.monotonic()
    e = Engine(port)

    # A project and a chat on the mock harness.
    e.call("Mutate", {"op": "createSpace", "spaceId": "space-proof", "path": repo, "name": "proof-project", "gitDetected": True})
    e.call("Mutate", {"op": "createChat", "chatId": "chat-proof", "spaceId": "space-proof", "title": "Proof chat",
                      "cwd": repo, "config": {"harness": "mock"}})
    # A turn, through the engine's command path.
    queued = e.call("QueueCommand", {"chatId": "chat-proof", "command": {"kind": "run", "messageId": "m-proof-1",
                                     "request": {"prompt": "Say hello for the proof", "cwd": repo, "harness": "mock"}}})
    summary["commandId"] = queued.get("commandId")

    def turn_done():
        rows = e.call("WatchSessions", {})
        for row in rows or []:
            if row.get("chatId") == "chat-proof" and row.get("lastCompletedTurn") and row.get("status") == "idle":
                return row
        return None

    row = wait_for("the mock turn to complete", turn_done, 30)
    summary["turn"] = {"status": row["status"], "device": row.get("deviceId") == e.call("LocalDevice", {}).get("deviceId")}

    doc = e.call("WatchDocMessages", {"chatId": "chat-proof"})
    entries = doc.get("reset") or []
    reply = " ".join(p.get("text", "") for m in entries if m.get("role") == "assistant" for p in m.get("parts", []))
    if "Mock harness reporting in" not in reply:
        raise RuntimeError("the transcript has no mock reply: %r" % reply[:200])
    users = [p.get("text") for m in entries if m.get("role") == "user" for p in m.get("parts", [])]
    summary["transcript"] = {"messages": len(entries), "prompt": users[:1], "replyHasMockText": True}

    # A terminal: run echo and read its output.
    term = e.call("OpenTerminal", {"chatId": "chat-proof", "cwd": repo, "cols": 80, "rows": 24})
    tid = term["id"]
    e.call("WriteTerminal", {"terminalId": tid, "data": base64.b64encode(b"echo proof-$((40 + 2))\n").decode()})

    def terminal_output():
        rid = e.next_id
        e.next_id += 1
        e._send(json.dumps({"id": rid, "method": "SubscribeTerminal", "params": {"terminalId": tid}}))
        text = ""
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                e.sock.settimeout(0.3)
                msg = e._recv()
            except socket.timeout:
                break
            finally:
                e.sock.settimeout(10)
            if msg.get("id") == rid and "item" in msg:
                item = msg["item"]
                if item.get("type") == "data":
                    text += base64.b64decode(item["data"]).decode(errors="replace")
        e._send(json.dumps({"id": rid, "cancel": True}))
        return "proof-42" in text and text

    wait_for("the terminal's echo", terminal_output, 20)
    e.call("CloseTerminal", {"terminalId": tid})
    summary["terminal"] = {"echo": "proof-42"}

    # Git: edit a tracked file, then the checkout's status and diff.
    with open(os.path.join(repo, "README.md"), "a") as f:
        f.write("edited during the proof\n")

    def git_status():
        st = e.call("WatchWorkspaceGitStatus", {"spaceId": "space-proof"})
        return st.get("status") if st else None

    status = wait_for("the checkout's git status", git_status, 20)
    diff = e.call("GetCheckoutDiff", {"cwd": repo, "mode": "workingTree"})
    files = [f.get("path") for f in diff.get("files", [])]
    if "README.md" not in files:
        raise RuntimeError("the diff does not show README.md: %r" % files)
    summary["git"] = {"statusKeys": sorted(status.keys()) if isinstance(status, dict) else str(type(status)),
                      "diffFiles": files, "additions": diff.get("additions")}
    summary["seconds"] = round(time.monotonic() - started, 2)
    print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception as err:  # one line for the report, then fail
        print(json.dumps({"error": str(err)}))
        sys.exit(1)
