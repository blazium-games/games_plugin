"""Saved sign-in must not be readable with a passphrase made from public data.

The addon writes the login token with FileAccess.open_encrypted_with_pass. The
passphrase is the SHA-256 hex of "blazium-session|<game id>|<device id>". On a
web export the device id is empty. On Linux it is the text of /etc/machine-id.
Both are available to someone who has the shipped client and a copy of the
saved file. This test fails while that copy still opens.

refresh_session() posts to the Blazium API and then calls _save_session(). This
test does not call that API. The write refresh_session shares is _save_session(),
which is one of the cases below.

Run:
    GODOT=/path/to/godot python3 tests/session_disclosure_test.py

Godot 4.7 export templates must be installed for the web case
(export_templates/<version>.stable, including web_nothreads_release.zip).
The Python package "cryptography" is required.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "tests" / "session_disclosure"
ADDON = ROOT / "addons" / "blazium_games"
PLACEHOLDER = b"placeholder-login-token"
CONTROL_PASS = "placeholder-control-passphrase"
# Godot 4.7.2 core/io/file_access_encrypted.h ENCRYPTED_HEADER_MAGIC.
MAGIC = 0x43454447
WEB_PORT = 8765
CASES = ("jwt", "login_success", "_save_session")


def godot_bin() -> str:
    env = os.environ.get("GODOT", "")
    if env:
        return env
    found = shutil.which("godot")
    if found:
        return found
    sys.exit("Set GODOT to a Godot 4 binary, or put godot on PATH")


def game_uid_from_project() -> str:
    text = (PROJECT / "project.godot").read_text(encoding="utf-8")
    match = re.search(r'^game/game_uid="([^"]+)"', text, re.M)
    if not match:
        sys.exit("project.godot is missing blazium/game/game_uid")
    return match.group(1)


def linux_machine_id() -> str:
    """Same read as Godot 4.7.2 OS_LinuxBSD::get_unique_id: first non-empty line."""
    raw = Path("/etc/machine-id").read_text(encoding="utf-8", errors="replace")
    for line in raw.splitlines():
        machine_id = line.strip()
        if machine_id:
            return machine_id
    sys.exit("/etc/machine-id had no id")


def session_passphrase(game_uid: str, device: str) -> str:
    material = f"blazium-session|{game_uid}|{device}"
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def godot_password_key(password: str) -> bytes:
    """FileAccessEncrypted::open_and_parse_password: AES key is the ASCII hex MD5."""
    digest = hashlib.md5(password.encode("utf-8")).hexdigest()
    if len(digest) != 32:
        raise RuntimeError("md5 hex length")
    return digest.encode("ascii")


def decrypt_godot_pass(blob: bytes, password: str) -> bytes | None:
    """Decrypt a Godot 4.7.2 open_encrypted_with_pass file. None if the password is wrong."""
    if len(blob) < 4 + 16 + 8 + 16:
        return None
    magic = int.from_bytes(blob[0:4], "little")
    if magic != MAGIC:
        return None
    md5_stored = blob[4:20]
    length = int.from_bytes(blob[20:28], "little")
    iv = bytearray(blob[28:44])
    if length < 0 or length > len(blob):
        return None
    padded = length
    if padded % 16:
        padded += 16 - (padded % 16)
    ciphertext = blob[44:]
    if len(ciphertext) < padded:
        return None
    ciphertext = ciphertext[:padded]
    key = godot_password_key(password)
    decryptor = Cipher(algorithms.AES(key), modes.CFB(iv)).decryptor()
    try:
        plain = decryptor.update(ciphertext) + decryptor.finalize()
    except ValueError:
        return None
    data = plain[:length]
    if hashlib.md5(data).digest() != md5_stored:
        return None
    return data


def parse_report(text: str) -> dict:
    report = {"cases": {}, "os_name": "", "game_uid": "", "device_match": None, "control": b""}
    for line in text.splitlines():
        parts = line.split("\t")
        if not parts:
            continue
        if parts[0] == "OS_NAME" and len(parts) == 2:
            report["os_name"] = parts[1]
        elif parts[0] == "GAME_UID" and len(parts) == 2:
            report["game_uid"] = parts[1]
        elif parts[0] == "DEVICE_MATCH" and len(parts) == 2:
            report["device_match"] = parts[1] == "1"
        elif parts[0] == "CASE" and len(parts) == 3:
            report["cases"][parts[1]] = _b64decode(parts[2])
        elif parts[0] == "CONTROL" and len(parts) == 2:
            report["control"] = _b64decode(parts[1])
    return report


def _b64decode(text: str) -> bytes:
    if text == "":
        return b""
    import base64

    return base64.b64decode(text)


def run_desktop(godot: str) -> str:
    proc = subprocess.run(
        [godot, "--headless", "--path", str(PROJECT)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if "PROBE_DONE" not in proc.stdout:
        sys.exit(f"desktop probe did not finish (exit {proc.returncode}):\n{proc.stdout}")
    return proc.stdout


class _ReuseServer(ThreadingHTTPServer):
    allow_reuse_address = True


class _ResultHandler(BaseHTTPRequestHandler):
    body = ""

    def do_GET(self):
        path = PROJECT_WEB / self.path.split("?", 1)[0].lstrip("/")
        if self.path in ("/", "/index.html"):
            path = PROJECT_WEB / "index.html"
        if not path.is_file():
            self.send_error(404)
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Type", _mime(path.suffix))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/result":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        type(self).body = self.rfile.read(length).decode("utf-8", errors="replace")
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, fmt, *args):
        return


def _mime(suffix: str) -> str:
    return {
        ".html": "text/html",
        ".js": "text/javascript",
        ".wasm": "application/wasm",
        ".pck": "application/octet-stream",
        ".png": "image/png",
        ".svg": "image/svg+xml",
        ".json": "application/json",
        ".webmanifest": "application/manifest+json",
    }.get(suffix, "application/octet-stream")


PROJECT_WEB = Path("/tmp/session-disclosure-web")


def export_web(godot: str) -> None:
    if PROJECT_WEB.exists():
        shutil.rmtree(PROJECT_WEB)
    PROJECT_WEB.mkdir(parents=True)
    proc = subprocess.run(
        [godot, "--headless", "--path", str(PROJECT), "--export-release", "Web", str(PROJECT_WEB / "index.html")],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if not (PROJECT_WEB / "index.html").is_file():
        sys.exit(f"web export failed (exit {proc.returncode}):\n{proc.stdout}")


def run_web() -> str:
    _ResultHandler.body = ""
    server = _ReuseServer(("127.0.0.1", WEB_PORT), _ResultHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    chrome = shutil.which("google-chrome") or shutil.which("google-chrome-stable")
    if not chrome:
        server.shutdown()
        sys.exit("google-chrome is required to run the web export")
    profile = Path("/tmp/session-disclosure-chrome")
    if profile.exists():
        shutil.rmtree(profile, ignore_errors=True)
    proc = subprocess.Popen(
        [
            chrome,
            "--headless=new",
            "--no-sandbox",
            "--disable-gpu",
            "--use-angle=swiftshader",
            "--enable-unsafe-swiftshader",
            f"--user-data-dir={profile}",
            f"http://127.0.0.1:{WEB_PORT}/index.html",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        deadline = time.time() + 30
        while time.time() < deadline:
            if "PROBE_DONE" in _ResultHandler.body:
                break
            if proc.poll() is not None:
                break
            time.sleep(0.1)
    finally:
        server.shutdown()
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, 15)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, 9)
                except ProcessLookupError:
                    pass
    if "PROBE_DONE" not in _ResultHandler.body:
        sys.exit("web probe did not post its result")
    return _ResultHandler.body


def public_passphrases(shipped_uid: str) -> list[tuple[str, str]]:
    """Passphrases an attacker can build without a secret.

    Web exports force the device id to an empty string. On Linux, Godot's
    device id is the first line of /etc/machine-id, which is world-readable
    and on the same disk as the saved file.
    """
    found = [("web", session_passphrase(shipped_uid, ""))]
    if Path("/etc/machine-id").is_file():
        found.append(("linux-machine-id", session_passphrase(shipped_uid, linux_machine_id())))
    return found


def check_report(label: str, text: str, shipped_uid: str) -> list[str]:
    report = parse_report(text)
    if report["os_name"] == "":
        sys.exit(f"{label}: probe did not report an OS name")
    if report["game_uid"] != shipped_uid:
        sys.exit(f"{label}: saved file was not keyed from the project game id")
    if report["os_name"] == "Linux" and report["device_match"] is not True:
        sys.exit(f"{label}: OS.get_unique_id() did not match /etc/machine-id")
    control = decrypt_godot_pass(report["control"], CONTROL_PASS)
    if control != PLACEHOLDER:
        sys.exit(f"{label}: control file did not decrypt with the engine format")
    failures = []
    passes = public_passphrases(shipped_uid)
    for case in CASES:
        blob = report["cases"].get(case, b"")
        if blob == b"":
            # A fix may stop writing the file. Nothing was copied.
            continue
        if PLACEHOLDER in blob:
            failures.append(f"{label}/{case}: login token stored in plaintext")
            continue
        for kind, passphrase in passes:
            recovered = decrypt_godot_pass(blob, passphrase)
            if recovered == PLACEHOLDER:
                failures.append(f"{label}/{case}: {kind} passphrase recovered the login token")
        wrong = decrypt_godot_pass(blob, CONTROL_PASS)
        if wrong == PLACEHOLDER:
            sys.exit(f"{label}/{case}: control passphrase opened the session file")
    return failures


def main() -> None:
    link = PROJECT / "addons"
    if not link.exists():
        link.symlink_to(ADDON, target_is_directory=True)
    godot = godot_bin()
    shipped_uid = game_uid_from_project()
    failures = []
    desktop = run_desktop(godot)
    failures.extend(check_report("desktop", desktop, shipped_uid))
    export_web(godot)
    exported = b"".join(path.read_bytes() for path in PROJECT_WEB.iterdir() if path.is_file())
    if shipped_uid.encode("utf-8") not in exported:
        sys.exit("web export did not contain the project game id")
    if b"blazium-session|" not in exported:
        sys.exit("web export did not contain the session passphrase label")
    web = run_web()
    failures.extend(check_report("web", web, shipped_uid))
    if failures:
        print("\n".join(failures))
        sys.exit(1)
    print("saved sign-in was not recoverable from the public passphrase")


if __name__ == "__main__":
    main()
