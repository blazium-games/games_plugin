#!/usr/bin/env python3
"""Run the lobby session-isolation checks.

Requires Godot 4 on PATH or in the GODOT environment variable. The checks
fail until logout, device-code sign-in, and session restore drop the lobby
socket, the admit ticket, and the stored relay list.

    GODOT=/path/to/godot python3 tests/session_isolation/run_tests.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def godot_bin() -> str:
    env = os.environ.get("GODOT", "")
    if env:
        return env
    found = shutil.which("godot") or shutil.which("godot4")
    if not found:
        sys.stderr.write("Godot 4 is required. Set GODOT to the editor binary.\n")
        sys.exit(2)
    return found


def main() -> int:
    mock = subprocess.Popen(
        [sys.executable, str(HERE / "mock_service.py")],
        stdout=subprocess.PIPE,
        text=True,
    )
    assert mock.stdout is not None
    line = mock.stdout.readline()
    if not line:
        mock.kill()
        sys.stderr.write("the local stand-in exited before it bound a port\n")
        return 2
    ports = json.loads(line)
    env = os.environ.copy()
    env["SESSION_TEST_HTTP"] = str(ports["http"])
    env["SESSION_TEST_LOBBY"] = str(ports["lobby"])
    env["SESSION_TEST_LOGIN"] = str(ports["login"])
    binary = godot_bin()
    try:
        imported = subprocess.run(
            [binary, "--headless", "--path", str(HERE), "--import", "--quit"],
            cwd=ROOT,
            env=env,
            timeout=60,
        )
        if imported.returncode != 0:
            sys.stderr.write("Godot could not import the test project\n")
            return imported.returncode or 2
        result = subprocess.run(
            [binary, "--headless", "--path", str(HERE), "-s", "res://run_tests.gd"],
            cwd=ROOT,
            env=env,
            timeout=180,
        )
        return result.returncode
    except subprocess.TimeoutExpired:
        sys.stderr.write("session isolation checks timed out\n")
        return 2
    finally:
        mock.kill()
        mock.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())
