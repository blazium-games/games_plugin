#!/usr/bin/env bash
# Runs the session-takeover tests. They exercise the real sign-in client and
# fail while a late refresh, scoped-token, or Steam response can still commit.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
port="${PORT:-8765}"
godot_bin="${GODOT:-godot}"
python3 tests/session_takeover/hold_server.py "$port" &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
ready=0
for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:${port}/control/state" >/dev/null; then
    ready=1
    break
  fi
  sleep 0.05
done
if [[ "$ready" != 1 ]]; then
  echo "local hold server did not start" >&2
  exit 2
fi
"$godot_bin" --headless --path tests/session_takeover --import --quit >/dev/null
SESSION_TAKEOVER_PORT="$port" "$godot_bin" --headless --path tests/session_takeover -s res://run.gd
