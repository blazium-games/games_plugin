#!/usr/bin/env python3
"""Local stand-in for the HTTP calls the sign-in client makes.

Responses that commit a credential are held until the test releases them, so
logout or a newer sign-in can finish while the original call is still waiting.
Nothing here is a real credential; the bodies are fixed placeholders.
"""

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REFRESHED_LOGIN = "placeholder-refreshed-previous-login"
SCOPED_PREVIOUS = "placeholder-scoped-previous"
SCOPED_NEXT = "placeholder-scoped-next"
SCOPED_STEAM = "placeholder-scoped-from-steam"
STEAM_PREVIOUS = "placeholder-steam-previous"
STEAM_NEXT = "placeholder-steam-next"
STEAM_SESSION = "placeholder-steam-session"
TICKET_PREVIOUS = "placeholder-ticket-previous"
TICKET_NEXT = "placeholder-ticket-next"

lock = threading.Lock()
held = {}
seq = 0
expect = {"previous_login": "", "next_login": ""}
hold_steam_next = False
flags = {
    "refresh_seen": False,
    "refresh_responded": False,
    "progress_used_refreshed_login": False,
    "transfer_used_refreshed_login": False,
    "lobby_admit_seen": False,
    "lobby_used_scoped_previous": False,
    "sapi_seen": False,
    "sapi_used_scoped_previous": False,
    "sapi_used_steam_previous": False,
    "bug_seen": False,
    "bug_used_steam_previous": False,
    "playtime_seen": False,
}


def _reset_flags():
    for key in flags:
        flags[key] = False


def _bearer(header):
    prefix = "Bearer "
    if header.startswith(prefix):
        return header[len(prefix):]
    return ""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _send(self, code, payload):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)

    def _hold(self, kind):
        global seq
        with lock:
            seq += 1
            key = "%s-%d" % (kind, seq)
            event = threading.Event()
            held[key] = event
        event.wait(30)
        with lock:
            held.pop(key, None)

    def _pending(self):
        with lock:
            return sorted(held.keys())

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        auth = self.headers.get("Authorization", "")
        if path == "/control/state":
            with lock:
                self._send(200, {"pending": sorted(held.keys()), "flags": dict(flags)})
            return
        if path.startswith("/private/player/progress"):
            with lock:
                if _bearer(auth) == REFRESHED_LOGIN:
                    flags["progress_used_refreshed_login"] = True
            self._send(200, {"achievements": []})
            return
        self._send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        raw = self._read_body()
        auth = self.headers.get("Authorization", "")
        if path == "/control/state":
            with lock:
                self._send(200, {"pending": sorted(held.keys()), "flags": dict(flags)})
            return
        if path == "/control/reset":
            with lock:
                _reset_flags()
            self._send(200, {"ok": True})
            return
        if path == "/control/expect":
            body = json.loads(raw.decode("utf-8") or "{}")
            with lock:
                expect["previous_login"] = str(body.get("previous_login", ""))
                expect["next_login"] = str(body.get("next_login", ""))
                global hold_steam_next
                hold_steam_next = bool(body.get("hold_steam_next", False))
            self._send(200, {"ok": True})
            return
        if path == "/control/release":
            body = json.loads(raw.decode("utf-8") or "{}")
            name = str(body.get("name", ""))
            with lock:
                keys = [key for key in held if name == "" or name == "*" or key.startswith(name)]
                events = [held[key] for key in keys]
            for event in events:
                event.set()
            self._send(200, {"released": len(events)})
            return
        self._route(path, auth, raw)

    def _route(self, path, auth, raw):
        bearer = _bearer(auth)
        if path == "/public/token/refresh":
            with lock:
                flags["refresh_seen"] = True
            self._hold("refresh")
            with lock:
                flags["refresh_responded"] = True
            self._send(200, {"token": REFRESHED_LOGIN})
            return
        if path == "/private/logout":
            self._send(200, {"ok": True})
            return
        if path.endswith("/playtime"):
            with lock:
                flags["playtime_seen"] = True
            self._send(200, {"ok": True})
            return
        if "/tokens" in path and "/steam/" in path:
            self._hold("scoped-steam")
            self._send(200, {"token": SCOPED_STEAM, "expires_in": 600, "audience": "server"})
            return
        if path.endswith("/tokens"):
            with lock:
                previous = expect["previous_login"]
                nxt = expect["next_login"]
            if bearer == previous:
                self._hold("scoped-previous")
                self._send(200, {"token": SCOPED_PREVIOUS, "expires_in": 600})
                return
            if nxt != "" and bearer == nxt:
                self._send(200, {"token": SCOPED_NEXT, "expires_in": 600})
                return
            self._send(200, {"token": SCOPED_PREVIOUS, "expires_in": 600})
            return
        if "/steam/" in path and path.endswith("/auth"):
            ticket = ""
            try:
                ticket = str(json.loads(raw.decode("utf-8") or "{}").get("ticket", ""))
            except json.JSONDecodeError:
                ticket = ""
            if ticket == TICKET_NEXT:
                with lock:
                    should_hold = hold_steam_next
                if should_hold:
                    self._hold("steam-next")
                self._send(200, {"token": STEAM_NEXT, "steam_id": "placeholder-steam-id-next"})
                return
            self._hold("steam-previous")
            self._send(200, {"token": STEAM_PREVIOUS, "steam_id": "placeholder-steam-id-previous"})
            return
        if path.endswith("/items/transfer"):
            with lock:
                if bearer == REFRESHED_LOGIN:
                    flags["transfer_used_refreshed_login"] = True
            self._send(200, {"ok": True})
            return
        if "/private/lobbies" in path:
            with lock:
                flags["lobby_admit_seen"] = True
                if bearer == SCOPED_PREVIOUS:
                    flags["lobby_used_scoped_previous"] = True
            self._send(200, {"ticket": "placeholder-lobby-ticket"})
            return
        if path.startswith("/sapi/"):
            with lock:
                flags["sapi_seen"] = True
                if bearer == SCOPED_PREVIOUS:
                    flags["sapi_used_scoped_previous"] = True
                if bearer == STEAM_PREVIOUS:
                    flags["sapi_used_steam_previous"] = True
            self._send(200, {})
            return
        if path.endswith("/bugs"):
            with lock:
                flags["bug_seen"] = True
                if bearer == STEAM_PREVIOUS:
                    flags["bug_used_steam_previous"] = True
            self._send(200, {"bug_uid": "placeholder-bug"})
            return
        self._send(200, {"ok": True})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
