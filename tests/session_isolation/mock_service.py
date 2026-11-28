"""Local stand-in for the lobby admit HTTP call, the lobby socket, and logout.

The product builds those requests itself. This process only answers the
shapes that product code parses. It listens on 127.0.0.1 and does not open
any connection of its own.
"""

from __future__ import annotations

import base64
import hashlib
import json
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

WS_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
ADMIT_TICKET = "admit-placeholder"
PEER_BEFORE = "seen-before"
PEER_AFTER = "seen-after"


class ServiceState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.release = threading.Event()
        self.hold_admit = False
        self.hold_logout = False
        self.hold_handshake = False
        self.admit_started = 0
        self.admit_finished = 0
        self.logout_started = 0
        self.logout_finished = 0
        self.handshake_waiting = 0
        self.auth_count = 0
        self.auth_placeholder = 0
        self.leave_count = 0
        self.action_count = 0
        self.create_count = 0
        self.join_count = 0
        self.ops: list[str] = []
        self.clients: list[socket.socket] = []
        self.unexpected: list[str] = []
        self.write_lock = threading.Lock()

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "hold_admit": self.hold_admit,
                "hold_logout": self.hold_logout,
                "hold_handshake": self.hold_handshake,
                "admit_started": self.admit_started,
                "admit_finished": self.admit_finished,
                "logout_started": self.logout_started,
                "logout_finished": self.logout_finished,
                "handshake_waiting": self.handshake_waiting,
                "auth_count": self.auth_count,
                "auth_placeholder": self.auth_placeholder,
                "leave_count": self.leave_count,
                "action_count": self.action_count,
                "create_count": self.create_count,
                "join_count": self.join_count,
                "open_sockets": len(self.clients),
                "ops": list(self.ops),
                "unexpected": list(self.unexpected),
            }

    def configure(self, body: dict) -> None:
        with self.lock:
            self.hold_admit = bool(body.get("hold_admit", False))
            self.hold_logout = bool(body.get("hold_logout", False))
            self.hold_handshake = bool(body.get("hold_handshake", False))
            self.release.clear()

    def unblock(self) -> None:
        self.release.set()

    def reset(self) -> None:
        self.release.set()
        time.sleep(0.05)
        with self.lock:
            self.hold_admit = False
            self.hold_logout = False
            self.hold_handshake = False
            clients = list(self.clients)
            self.clients.clear()
            self.admit_started = 0
            self.admit_finished = 0
            self.logout_started = 0
            self.logout_finished = 0
            self.handshake_waiting = 0
            self.auth_count = 0
            self.auth_placeholder = 0
            self.leave_count = 0
            self.action_count = 0
            self.create_count = 0
            self.join_count = 0
            self.ops.clear()
            self.unexpected.clear()
        for conn in clients:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                conn.close()
            except OSError:
                pass
        time.sleep(0.05)
        self.release.clear()

    def send_bytes(self, conn: socket.socket, frame: bytes) -> None:
        with self.write_lock:
            conn.sendall(frame)

    def add_client(self, conn: socket.socket) -> None:
        with self.lock:
            self.clients.append(conn)

    def drop_client(self, conn: socket.socket) -> None:
        with self.lock:
            self.clients = [item for item in self.clients if item is not conn]

    def send_peer(self, peer_id: str) -> int:
        payload = json.dumps({"op": "peer_joined", "payload": {"peer_id": peer_id}}).encode()
        frame = _text_frame(payload)
        with self.lock:
            clients = list(self.clients)
        sent = 0
        for conn in clients:
            try:
                self.send_bytes(conn, frame)
                sent += 1
            except OSError:
                self.drop_client(conn)
        return sent

    def note_message(self, message: dict) -> None:
        op = str(message.get("op", ""))
        payload = message.get("payload", {})
        if not isinstance(payload, dict):
            payload = {}
        reply = None
        with self.lock:
            if op:
                self.ops.append(op)
                print("ws", op, file=sys.stderr, flush=True)
            if op == "auth":
                self.auth_count += 1
                if payload.get("ticket") == ADMIT_TICKET:
                    self.auth_placeholder += 1
                reply = {"ok": True, "id": message.get("id", ""), "payload": {}}
            elif op == "create_lobby":
                self.create_count += 1
                reply = {
                    "ok": True,
                    "id": message.get("id", ""),
                    "payload": {"lobby_id": "lobby-placeholder", "peers": []},
                }
            elif op == "join_lobby":
                self.join_count += 1
                reply = {
                    "ok": True,
                    "id": message.get("id", ""),
                    "payload": {"lobby_id": str(payload.get("lobby_id", "lobby-placeholder")), "peers": []},
                }
            elif op == "leave_lobby":
                self.leave_count += 1
            elif op == "lobby_action":
                self.action_count += 1
            elif op:
                self.unexpected.append(op)
        return reply


STATE = ServiceState()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        return

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _json(self, code: int, obj: dict) -> None:
        raw = json.dumps(obj).encode()
        status = {200: "OK", 404: "Not Found"}.get(code, "OK")
        head = (
            f"HTTP/1.1 {code} {status}\r\n"
            "Content-Type: application/json\r\n"
            f"Content-Length: {len(raw)}\r\n"
            "Connection: close\r\n"
            "\r\n"
        ).encode()
        self.wfile.write(head + raw)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/test/status":
            self._json(200, STATE.snapshot())
            return
        STATE.unexpected.append("GET " + path)
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        raw = self._read_body()
        if not path.startswith("/test/"):
            print("http", path, file=sys.stderr, flush=True)
        if path == "/test/config":
            body = json.loads(raw.decode() or "{}")
            STATE.configure(body)
            self._json(200, {"ok": True})
            return
        if path == "/test/release":
            STATE.unblock()
            self._json(200, {"ok": True})
            return
        if path == "/test/reset":
            STATE.reset()
            self._json(200, {"ok": True})
            return
        if path == "/test/peer":
            body = json.loads(raw.decode() or "{}")
            sent = STATE.send_peer(str(body.get("peer_id", PEER_AFTER)))
            self._json(200, {"ok": True, "sent": sent})
            return
        if path.endswith("/private/logout"):
            with STATE.lock:
                STATE.logout_started += 1
                hold = STATE.hold_logout
            if hold:
                STATE.release.wait(20)
            with STATE.lock:
                STATE.logout_finished += 1
            self._json(200, {"ok": True})
            return
        if "/private/lobbies" in path:
            with STATE.lock:
                STATE.admit_started += 1
                hold = STATE.hold_admit
            if hold:
                STATE.release.wait(20)
            with STATE.lock:
                STATE.admit_finished += 1
            self._json(
                200,
                {
                    "data": {
                        "ticket": ADMIT_TICKET,
                        "ice_session_id": "ice-session-placeholder",
                        "ice_enabled": True,
                    }
                },
            )
            return
        with STATE.lock:
            STATE.unexpected.append("POST " + path)
        self._json(404, {"error": "not found"})


def _text_frame(payload: bytes) -> bytes:
    length = len(payload)
    if length < 126:
        header = bytes([0x81, length])
    elif length < 65536:
        header = bytes([0x81, 126]) + length.to_bytes(2, "big")
    else:
        header = bytes([0x81, 127]) + length.to_bytes(8, "big")
    return header + payload


def _accept_value(key: str) -> str:
    digest = hashlib.sha1(key.encode("ascii") + WS_GUID).digest()
    return base64.b64encode(digest).decode("ascii")


def _header(head: str, name: str) -> str:
    prefix = name.lower() + ":"
    for line in head.split("\r\n"):
        if line.lower().startswith(prefix):
            return line.split(":", 1)[1].strip()
    return ""


def _read_headers(conn: socket.socket) -> tuple[str, bytes] | None:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return None
        data += chunk
        if len(data) > 65536:
            return None
    head, rest = data.split(b"\r\n\r\n", 1)
    return head.decode("iso-8859-1", "replace"), rest


def _parse_frames(buf: bytes) -> tuple[list[tuple[int, bytes]], bytes]:
    frames = []
    index = 0
    while True:
        if len(buf) - index < 2:
            break
        first = buf[index]
        second = buf[index + 1]
        opcode = first & 0x0F
        masked = (second & 0x80) != 0
        length = second & 0x7F
        header = 2
        if length == 126:
            if len(buf) - index < 4:
                break
            length = int.from_bytes(buf[index + 2 : index + 4], "big")
            header = 4
        elif length == 127:
            if len(buf) - index < 10:
                break
            length = int.from_bytes(buf[index + 2 : index + 10], "big")
            header = 10
        mask_len = 4 if masked else 0
        total = header + mask_len + length
        if len(buf) - index < total:
            break
        payload = buf[index + header + mask_len : index + total]
        if masked:
            mask = buf[index + header : index + header + 4]
            payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
        frames.append((opcode, payload))
        index += total
    return frames, buf[index:]


def _handle_frames(conn: socket.socket, buf: bytes) -> bytes:
    frames, buf = _parse_frames(buf)
    for opcode, payload in frames:
        if opcode == 0x8:
            raise ConnectionError("closed")
        if opcode == 0x9:
            STATE.send_bytes(conn, _control_frame(0xA, payload))
            continue
        if opcode != 0x1:
            continue
        try:
            message = json.loads(payload.decode())
        except json.JSONDecodeError:
            continue
        if not isinstance(message, dict):
            continue
        reply = STATE.note_message(message)
        if reply is not None:
            STATE.send_bytes(conn, _text_frame(json.dumps(reply).encode()))
    return buf


def _serve_socket(conn: socket.socket, lobby: bool) -> None:
    try:
        parsed = _read_headers(conn)
        if parsed is None:
            return
        head, rest = parsed
        key = _header(head, "Sec-WebSocket-Key")
        if key == "":
            return
        with STATE.lock:
            hold = STATE.hold_handshake and lobby
        if hold:
            with STATE.lock:
                STATE.handshake_waiting += 1
            STATE.release.wait(20)
            with STATE.lock:
                STATE.handshake_waiting -= 1
        lines = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: " + _accept_value(key),
        ]
        requested = _header(head, "Sec-WebSocket-Protocol")
        if requested:
            lines.append("Sec-WebSocket-Protocol: " + requested.split(",")[0].strip())
        STATE.send_bytes(conn, ("\r\n".join(lines) + "\r\n\r\n").encode())
        conn.settimeout(None)
        if lobby:
            STATE.add_client(conn)
        buf = rest
        while True:
            if lobby and buf:
                buf = _handle_frames(conn, buf)
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
            if lobby:
                buf = _handle_frames(conn, buf)
    except (ConnectionError, OSError):
        pass
    finally:
        STATE.drop_client(conn)
        try:
            conn.close()
        except OSError:
            pass


def _ws_loop(bound: socket.socket, lobby: bool) -> None:
    while True:
        try:
            conn, _addr = bound.accept()
        except OSError:
            return
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        conn.settimeout(20)
        thread = threading.Thread(target=_serve_socket, args=(conn, lobby), daemon=True)
        thread.start()


def _bind(port: int) -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
    sock.listen(32)
    return sock


def _control_frame(opcode: int, payload: bytes) -> bytes:
    length = len(payload)
    if length < 126:
        header = bytes([0x80 | opcode, length])
    else:
        header = bytes([0x80 | opcode, 126]) + length.to_bytes(2, "big")
    return header + payload


def main() -> None:
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    httpd.daemon_threads = True
    lobby = _bind(0)
    login = _bind(0)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    threading.Thread(target=_ws_loop, args=(lobby, True), daemon=True).start()
    threading.Thread(target=_ws_loop, args=(login, False), daemon=True).start()
    print(
        json.dumps(
            {
                "http": httpd.server_address[1],
                "lobby": lobby.getsockname()[1],
                "login": login.getsockname()[1],
            }
        ),
        flush=True,
    )
    threading.Event().wait()


if __name__ == "__main__":
    main()
