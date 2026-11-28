"""Steam session tokens must not be sent to the Scripted API.

These tests fail while a Steam sign-in session is copied into the Authorization
header of Scripted API calls. They pass once those calls send only the
short-lived token from the scoped exchange (audience sapi) and the Steam
session stays on the Blazium API token exchange.

Run from the repository root:

    python3 tests/steam_session_sapi_test.py

The runner downloads Godot 4.7.2 (the engine that executes the addon) into
/tmp when GODOT is unset. It does not contact api.blazium.online or
sapi.blazium.online. Origins are local stand-ins; the addon scripts build the
request paths and headers.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import threading
import urllib.parse
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "tests" / "steam_session_sapi"
GODOT_VERSION = "4.7.2-stable"
GODOT_ZIP_SHA256 = "cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4"
GODOT_URL = (
    "https://github.com/godotengine/godot/releases/download/"
    f"{GODOT_VERSION}/Godot_v{GODOT_VERSION}_linux.x86_64.zip"
)
GAME_UID = "11111111-2222-3333-4444-555555555555"
TICKET = "placeholder-steam-ticket"
STEAM_SESSION = "placeholder-steam-session"
LOGIN_SESSION = "placeholder-login-session"
SCOPED = {
    "sapi": "placeholder-scoped-sapi",
    "lobby": "placeholder-scoped-lobby",
    "server": "placeholder-scoped-server",
}
API_HOST = "https://api.blazium.online/api/v1"
SAPI_HOST = "https://sapi.blazium.online"
SIGNED_SUFFIXES = ("_post", "_get", "_put", "_patch", "_delete", "_alias", "_retry")


def _godot_binary() -> Path:
    override = os.environ.get("GODOT", "")
    if override:
        return Path(override)
    cached = Path(f"/tmp/godot-{GODOT_VERSION}/Godot_v{GODOT_VERSION}_linux.x86_64")
    if cached.is_file():
        return cached
    archive = cached.parent / "godot.zip"
    cached.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(GODOT_URL) as response, archive.open("wb") as handle:
        shutil.copyfileobj(response, handle)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != GODOT_ZIP_SHA256:
        raise RuntimeError("Godot archive hash did not match the pinned release")
    with zipfile.ZipFile(archive) as bundle:
        bundle.extractall(cached.parent)
    cached.chmod(0o755)
    return cached


class _Recorder:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.requests = []
        self.retries = {}

    def __enter__(self):
        self._lock.acquire()
        return self

    def __exit__(self, *_args) -> None:
        self._lock.release()


def _handler(service: str, recorder: _Recorder):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt: str, *args) -> None:
            return

        def do_GET(self) -> None:
            self._handle()

        def do_POST(self) -> None:
            self._handle()

        def do_PUT(self) -> None:
            self._handle()

        def do_PATCH(self) -> None:
            self._handle()

        def do_DELETE(self) -> None:
            self._handle()

        def _handle(self) -> None:
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length else b""
            parsed = urllib.parse.urlsplit(self.path)
            entry = {
                "service": service,
                "method": self.command,
                "path": parsed.path,
                "query": parsed.query,
                "authorization": self.headers.get("Authorization"),
                "headers": {key.lower(): value for key, value in self.headers.items()},
                "body": raw.decode("utf-8", "replace"),
            }
            with recorder:
                recorder.requests.append(entry)
                status, payload, extra = _reply(service, entry, recorder.retries)
            data = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            for key, value in extra:
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(data)

    return Handler


def _reply(service: str, entry: dict, retries: dict) -> tuple[int, dict, list]:
    path = entry["path"]
    if service == "api" and path == f"/steam/{GAME_UID}/auth" and entry["method"] == "POST":
        return 200, {"token": STEAM_SESSION, "steam_id": "placeholder-steam-id"}, []
    if service == "api" and entry["method"] == "POST" and path in {
        f"/steam/{GAME_UID}/tokens",
        f"/private/games/{GAME_UID}/tokens",
    }:
        audience = ""
        try:
            body = json.loads(entry["body"] or "{}")
        except json.JSONDecodeError:
            body = {}
        if isinstance(body, dict):
            audience = str(body.get("audience", ""))
        token = SCOPED.get(audience, "")
        if token == "":
            return 400, {"code": "bad_audience", "error": "audience was refused"}, []
        return 200, {
            "token": token,
            "audience": audience,
            "game_uid": GAME_UID,
            "expires_at": "2099-01-01T00:00:00Z",
            "expires_in": 300,
        }, []
    if service == "sapi" and path.startswith(f"/v1/{GAME_UID}/"):
        logic = path.rsplit("/", 1)[-1]
        if logic.endswith("_retry"):
            seen = retries.get(logic, 0)
            retries[logic] = seen + 1
            if seen == 0:
                return 503, {"error": {"key": "unavailable", "message": "retry"}}, [("Retry-After", "0.1")]
        return 200, {"ok": True}, []
    return 404, {"error": {"key": "not_found", "message": "no stand-in for this path"}}, []


def _serve(service: str, recorder: _Recorder) -> ThreadingHTTPServer:
    class Server(ThreadingHTTPServer):
        allow_reuse_address = True
        daemon_threads = True

    server = Server(("127.0.0.1", 0), _handler(service, recorder))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def _kind(authorization: str | None) -> str:
    if authorization is None:
        return "absent"
    if authorization == f"Bearer {STEAM_SESSION}":
        return "steam_session"
    if authorization == f"Bearer {LOGIN_SESSION}":
        return "login_session"
    for audience, token in SCOPED.items():
        if authorization == f"Bearer {token}":
            return f"scoped_{audience}"
    return "other"


def _session_locations(entry: dict, session: str) -> list[str]:
    found = []
    if session in entry["path"]:
        found.append("path")
    if session in entry["query"]:
        found.append("query")
    if session in entry["body"]:
        found.append("body")
    for name, value in entry["headers"].items():
        if session in value:
            found.append(name)
    return found


def _phases(requests: list) -> tuple[list, list]:
    auth_at = [
        index
        for index, entry in enumerate(requests)
        if entry["service"] == "api" and entry["path"] == f"/steam/{GAME_UID}/auth"
    ]
    if len(auth_at) != 2:
        raise AssertionError(f"expected two steam sign-ins, saw {len(auth_at)}")
    return requests[auth_at[0]:auth_at[1]], requests[auth_at[1]:]


def _signed_sapi(records: list) -> list:
    found = []
    for entry in records:
        if entry["service"] != "sapi" or entry["method"] not in {"GET", "POST", "PUT", "PATCH", "DELETE"}:
            continue
        logic = entry["path"].rsplit("/", 1)[-1]
        if logic.endswith(SIGNED_SUFFIXES):
            found.append(entry)
    return found


def _exchange_before(records: list, first_signed_index: int) -> list:
    issued = []
    for entry in records[:first_signed_index]:
        if entry["service"] != "api" or entry["method"] != "POST":
            continue
        if entry["path"] not in {f"/steam/{GAME_UID}/tokens", f"/private/games/{GAME_UID}/tokens"}:
            continue
        try:
            body = json.loads(entry["body"] or "{}")
        except json.JSONDecodeError:
            continue
        if isinstance(body, dict) and str(body.get("audience", "")) == "sapi":
            issued.append(entry)
    return issued


def _run_driver() -> tuple[dict, list]:
    recorder = _Recorder()
    api = _serve("api", recorder)
    sapi = _serve("sapi", recorder)
    result_path = Path("/tmp/steam_session_sapi_result.json")
    if result_path.exists():
        result_path.unlink()
    api_origin = f"http://127.0.0.1:{api.server_address[1]}"
    sapi_origin = f"http://127.0.0.1:{sapi.server_address[1]}"
    binary = _godot_binary()
    try:
        completed = subprocess.run(
            [
                str(binary),
                "--headless",
                "--path",
                str(PROJECT),
                "-s",
                "res://driver.gd",
                "--",
                "--api-origin",
                api_origin,
                "--sapi-origin",
                sapi_origin,
                "--result",
                str(result_path),
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
        )
    finally:
        api.shutdown()
        sapi.shutdown()
    if not result_path.is_file():
        raise AssertionError(
            "driver wrote no result "
            f"(exit {completed.returncode})\n{completed.stdout}\n{completed.stderr}"
        )
    result = json.loads(result_path.read_text(encoding="utf-8"))
    if completed.returncode != 0 or not result.get("ok"):
        raise AssertionError(
            "driver failed: "
            + str(result.get("error", ""))
            + f"\nexit {completed.returncode}\n{completed.stdout}\n{completed.stderr}"
        )
    with recorder:
        captured = list(recorder.requests)
    return result, captured


class SteamSessionSapiTests:
    def __init__(self) -> None:
        self.result, self.requests = _run_driver()
        self.phase_a, self.phase_b = _phases(self.requests)

    def test_runtime_hosts_are_the_addon_constants(self) -> None:
        assert self.result["api_host"] == API_HOST, self.result["api_host"]
        assert self.result["sapi_host"] == SAPI_HOST, self.result["sapi_host"]

    def test_signed_in_scripted_calls_send_scoped_sapi_token(self) -> None:
        problems = []
        for label, records in ("steam-only", self.phase_a), ("steam-and-login", self.phase_b):
            signed = _signed_sapi(records)
            names = [entry["path"].rsplit("/", 1)[-1] for entry in signed]
            for suffix in SIGNED_SUFFIXES:
                matches = [name for name in names if name.endswith(suffix)]
                if suffix == "_retry":
                    if len(matches) < 2 or names.count(matches[0]) < 2:
                        # Both the refused attempt and the retry must be present.
                        retry_names = [name for name in names if name.endswith("_retry")]
                        if len(retry_names) != 2:
                            problems.append(f"{label} retry attempts: {len(retry_names)}")
                elif len(matches) != 1:
                    problems.append(f"{label} missing signed call {suffix}")
            if not signed:
                problems.append(f"{label} made no signed Scripted API calls")
                continue
            first = records.index(signed[0])
            if not _exchange_before(records, first):
                problems.append(f"{label} sent a Scripted API call before the sapi scoped exchange")
            for entry in signed:
                kind = _kind(entry["authorization"])
                if kind != "scoped_sapi":
                    problems.append(
                        f"{label} {entry['method']} {entry['path']} authorization was {kind}"
                    )
            for entry in records:
                if entry["service"] != "sapi":
                    continue
                for session_name, session in ("steam session", STEAM_SESSION), ("login session", LOGIN_SESSION):
                    places = _session_locations(entry, session)
                    if places:
                        problems.append(
                            f"{label} sapi {entry['method']} {entry['path']} carried the {session_name} in {', '.join(places)}"
                        )
                logic = entry["path"].rsplit("/", 1)[-1]
                if logic.endswith("_anon") or logic == "_config":
                    if entry["authorization"] is not None:
                        problems.append(f"{label} {logic} sent an Authorization header")
        if problems:
            raise AssertionError("\n".join(problems))

    def test_steam_session_exchanges_for_lobby_and_server(self) -> None:
        found = {"lobby": False, "server": False}
        for entry in self.phase_a:
            if entry["service"] != "api" or entry["method"] != "POST":
                continue
            if entry["path"] != f"/steam/{GAME_UID}/tokens":
                continue
            body = json.loads(entry["body"] or "{}")
            audience = str(body.get("audience", ""))
            if audience in found and body.get("token") == STEAM_SESSION:
                found[audience] = True
                if _session_locations(entry, LOGIN_SESSION):
                    raise AssertionError("login session was posted on the steam token exchange")
        missing = [audience for audience, ok in found.items() if not ok]
        if missing:
            raise AssertionError(
                "steam session was not posted to the token exchange for " + ", ".join(missing)
            )
        auth = [
            entry
            for entry in self.phase_a
            if entry["path"] == f"/steam/{GAME_UID}/auth" and entry["service"] == "api"
        ]
        if len(auth) != 1:
            raise AssertionError("steam sign-in did not reach the auth path")
        auth_body = json.loads(auth[0]["body"] or "{}")
        if auth_body.get("ticket") != TICKET:
            raise AssertionError("steam sign-in did not send the auth ticket")


def main() -> None:
    tests = SteamSessionSapiTests()
    tests.test_runtime_hosts_are_the_addon_constants()
    tests.test_steam_session_exchanges_for_lobby_and_server()
    tests.test_signed_in_scripted_calls_send_scoped_sapi_token()
    print("steam session sapi tests ok")


if __name__ == "__main__":
    main()
