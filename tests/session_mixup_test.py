#!/usr/bin/env python3
"""Session mixup tests.

Runs the Godot addon against a local peer and checks a Steam sign-in does not
stay attached after a device-code sign-in or a restored Blazium login.

These tests fail while that mixup is present. They pass once sign-in and
restore drop the previous Steam session and cached scoped tokens before any
network wait.

Requires Godot 4.7.x (the engine this harness was run with). Set GODOT to the
binary, or put `godot` on PATH.

    python3 tests/session_mixup_test.py
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

# Placeholder credentials. The addon treats these strings as the session
# material a sign-in response would return. They are not real secrets.
PLAYER_A_STEAM = "player-a-steam-session"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
ROOT = Path(__file__).resolve().parent / "session_mixup"


class State:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.requests: list[dict] = []
        self.player_b_far = ""
        self.player_b_near = ""
        self.player_b_refreshed = ""
        self.login_reached = threading.Event()
        self.login_release = threading.Event()
        self.refresh_reached = threading.Event()
        self.refresh_release = threading.Event()

    def reset(self) -> None:
        with self.lock:
            self.requests.clear()
        self.login_reached.clear()
        self.login_release.clear()
        self.refresh_reached.clear()
        self.refresh_release.clear()

    def label_header(self, header: str) -> str:
        token = ""
        if header.startswith("Bearer "):
            token = header[len("Bearer ") :]
        if token == "":
            return "none"
        if token == PLAYER_A_STEAM:
            return "player-a-steam"
        if token == self.player_b_far:
            return "player-b-login"
        if token == self.player_b_near:
            return "player-b-near-login"
        if token == self.player_b_refreshed:
            return "player-b-refreshed-login"
        if token.startswith("player-b-scoped-"):
            return "player-b-scoped"
        if token.startswith("player-a-scoped-"):
            return "player-a-scoped"
        return "other"

    def record(self, row: dict) -> None:
        with self.lock:
            self.requests.append(row)
        print(
            "peer {method} {path} auth={auth} audience={audience}".format(**row),
            flush=True,
        )

    def snapshot(self) -> dict:
        with self.lock:
            rows = list(self.requests)
        return {
            "ok": True,
            "login_waiting": self.login_reached.is_set() and not self.login_release.is_set(),
            "refresh_waiting": self.refresh_reached.is_set() and not self.refresh_release.is_set(),
            "requests": rows,
        }


STATE = State()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        return

    def do_GET(self) -> None:
        self._dispatch()

    def do_POST(self) -> None:
        self._dispatch()

    def _dispatch(self) -> None:
        path = urlparse(self.path).path
        raw = self._read_body()
        if path.startswith("/__test/"):
            self._control(path, raw)
            return
        body = _json_dict(raw)
        header = self.headers.get("Authorization", "")
        auth = STATE.label_header(header)
        audience = str(body.get("audience", ""))
        if "/steam/" in path and path.endswith("/tokens") and body.get("token") == PLAYER_A_STEAM:
            auth = "player-a-steam-body"
        STATE.record(
            {
                "method": self.command,
                "path": path,
                "auth": auth,
                "audience": audience,
            }
        )
        if path == "/public/token/refresh":
            STATE.refresh_reached.set()
            if not STATE.refresh_release.wait(15):
                self._send(504, {"error": "timed out waiting to finish refresh"})
                return
            self._send(200, {"token": STATE.player_b_refreshed})
            return
        if "/steam/" in path and path.endswith("/auth"):
            self._send(200, {"token": PLAYER_A_STEAM, "steam_id": "player-a"})
            return
        if path.endswith("/tokens"):
            if "/steam/" in path and body.get("token") == PLAYER_A_STEAM:
                issued = "player-a-scoped-" + audience
            elif auth in ("player-b-login", "player-b-near-login", "player-b-refreshed-login"):
                issued = "player-b-scoped-" + audience
            else:
                issued = "player-other-scoped-" + audience
            self._send(
                200,
                {
                    "token": issued,
                    "audience": audience,
                    "expires_in": 600,
                    "expires_at": "2099-01-01T00:00:00Z",
                },
            )
            return
        if path.endswith("/bugs") or "/bugs/" in path or "/patch/" in path or path.startswith("/v1/"):
            self._send(200, {"bug_uid": "bug-test", "notices": [], "notes": []})
            return
        self._send(404, {"error": "unexpected path"})

    def _control(self, path: str, raw: bytes) -> None:
        if path == "/__test/status":
            self._send(200, STATE.snapshot())
            return
        if path == "/__test/reset":
            STATE.reset()
            self._send(200, {"ok": True})
            return
        if path == "/__test/release-login":
            STATE.login_release.set()
            self._send(200, {"ok": True})
            return
        if path == "/__test/release-refresh":
            STATE.refresh_release.set()
            self._send(200, {"ok": True})
            return
        if path == "/__test/config":
            body = _json_dict(raw)
            STATE.player_b_far = str(body.get("player_b_far", ""))
            STATE.player_b_near = str(body.get("player_b_near", ""))
            STATE.player_b_refreshed = str(body.get("player_b_refreshed", ""))
            self._send(200, {"ok": True})
            return
        self._send(404, {"ok": False})

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0:
            return b""
        if length > 2_000_000:
            return self.rfile.read(2_000_000)
        return self.rfile.read(length)

    def _send(self, code: int, payload: dict) -> None:
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)


def _json_dict(raw: bytes) -> dict:
    if not raw:
        return {}
    try:
        parsed = json.loads(raw.decode())
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _recvn(conn: socket.socket, size: int) -> bytes:
    buf = b""
    while len(buf) < size:
        chunk = conn.recv(size - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def _send_text(conn: socket.socket, text: str) -> None:
    data = text.encode()
    size = len(data)
    if size < 126:
        header = bytes([0x81, size])
    elif size < 65536:
        header = bytes([0x81, 126]) + struct.pack("!H", size)
    else:
        header = bytes([0x81, 127]) + struct.pack("!Q", size)
    conn.sendall(header + data)


def _read_frame(conn: socket.socket) -> tuple[int, bytes]:
    first, length = _recvn(conn, 2)
    opcode = first & 0x0F
    masked = (length & 0x80) != 0
    size = length & 0x7F
    if size == 126:
        size = struct.unpack("!H", _recvn(conn, 2))[0]
    elif size == 127:
        size = struct.unpack("!Q", _recvn(conn, 8))[0]
    mask = _recvn(conn, 4) if masked else b""
    payload = _recvn(conn, size) if size else b""
    if masked:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return opcode, payload


def _handshake(conn: socket.socket) -> None:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            raise ConnectionError("closed before handshake")
        data += chunk
        if len(data) > 65536:
            raise ConnectionError("handshake too large")
    header = data.split(b"\r\n\r\n", 1)[0].decode("latin1")
    key = ""
    protocol = ""
    for line in header.split("\r\n"):
        lower = line.lower()
        if lower.startswith("sec-websocket-key:"):
            key = line.split(":", 1)[1].strip()
        elif lower.startswith("sec-websocket-protocol:"):
            protocol = line.split(":", 1)[1].strip().split(",")[0].strip()
    if key == "":
        raise ConnectionError("missing websocket key")
    accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n"
    )
    if protocol:
        response += f"Sec-WebSocket-Protocol: {protocol}\r\n"
    response += "\r\n"
    conn.sendall(response.encode())
    print("ws open", flush=True)


def _handle_ws(conn: socket.socket) -> None:
    conn.settimeout(20)
    _handshake(conn)
    while True:
        opcode, payload = _read_frame(conn)
        if opcode == 0x8:
            return
        if opcode == 0x9:
            # Pong, echoing the ping payload.
            body = payload
            header = bytes([0x8A, len(body)]) if len(body) < 126 else bytes([0x8A, 0])
            conn.sendall(header + body)
            continue
        if opcode != 0x1:
            continue
        try:
            message = json.loads(payload.decode())
        except json.JSONDecodeError:
            continue
        action = str(message.get("action", ""))
        print("ws action", action, flush=True)
        if action == "getid":
            _send_text(conn, '{"action":"conn_id"}')
        elif action == "getlogin":
            _send_text(
                conn,
                json.dumps(
                    {
                        "action": "login_url",
                        "login_url": "http://127.0.0.1/device",
                        "user_code": "TESTCODE",
                        "verification_url": "http://127.0.0.1/verify",
                    }
                ),
            )
            STATE.login_reached.set()
            if not STATE.login_release.wait(15):
                print("ws login wait timed out", flush=True)
                return
            _send_text(
                conn,
                json.dumps(
                    {
                        "action": "jwt",
                        "jwt": STATE.player_b_far,
                        "uid": "player-b",
                        "user_id": "player-b",
                    }
                ),
            )


def _ws_loop(sock: socket.socket) -> None:
    while True:
        conn, _addr = sock.accept()
        try:
            _handle_ws(conn)
        except Exception as exc:
            print("ws closed", type(exc).__name__, flush=True)
        finally:
            conn.close()


def _start_peers() -> tuple[str, str]:
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    httpd.daemon_threads = True
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    host, port = httpd.server_address[:2]
    ws = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ws.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ws.bind(("127.0.0.1", 0))
    ws.listen(5)
    ws_port = ws.getsockname()[1]
    threading.Thread(target=_ws_loop, args=(ws,), daemon=True).start()
    return f"http://{host}:{port}", f"ws://{host}:{ws_port}/api/v1/connect"


def _godot() -> str:
    candidates = [
        os.environ.get("GODOT", ""),
        "godot",
        "/tmp/godot/Godot_v4.7.2-stable_linux.x86_64",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    found = None
    for directory in os.environ.get("PATH", "").split(":"):
        path = Path(directory) / "godot"
        if path.is_file() and os.access(path, os.X_OK):
            found = str(path)
            break
    if found:
        return found
    sys.stderr.write("Godot 4.7.x is required. Set GODOT to the editor binary.\n")
    raise SystemExit(127)


def main() -> int:
    http_base, ws_base = _start_peers()
    env = os.environ.copy()
    for key in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy"):
        env.pop(key, None)
    env["NO_PROXY"] = "127.0.0.1,localhost"
    env["SESSION_MIXUP_HTTP"] = http_base
    env["SESSION_MIXUP_WS"] = ws_base
    binary = _godot()
    print("godot", binary, flush=True)
    print("peer", http_base, flush=True)
    completed = subprocess.run(
        [binary, "--headless", "--path", str(ROOT), "-s", "res://driver.gd"],
        cwd=ROOT,
        env=env,
        timeout=120,
        check=False,
    )
    return completed.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.TimeoutExpired:
        sys.stderr.write("session mixup test timed out\n")
        raise SystemExit(124)
