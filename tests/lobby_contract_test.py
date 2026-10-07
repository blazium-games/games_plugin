from pathlib import Path

lobby = Path("addons/blazium_games/blazium_lobby.gd").read_text(encoding="utf-8")
ice = Path("addons/blazium_games/blazium_ice.gd").read_text(encoding="utf-8")

assert '"game_uid": _game_uid' in lobby
assert '"game_uid": game_uid' in lobby
assert "join_lobby" in lobby
assert "HashingContext.HASH_SHA256" in ice
assert "set_ice_enabled" in ice
assert "note_lobby" in ice
assert "hold_ice" in ice
assert "_deferred_jwt" in ice
assert "ice_enabled" in lobby
assert "_ask_service" in lobby
ask = lobby.split("func _ask_service", 1)[1]
assert ask.index("hold_ice(true)") < ask.index("http.request")
assert ask.index("_note_ice") < ask.index("hold_ice(false)")
print("lobby contract ok")
