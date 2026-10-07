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
create = lobby.split("func create_lobby", 1)[1].split("func join_lobby", 1)[0]
join = lobby.split("func join_lobby", 1)[1].split("var _queued_op", 1)[0]
assert "_connect(" not in create
assert "_connect(" not in join
ask = lobby.split("func _ask_service", 1)[1].split("func _lobby_error", 1)[0]
assert ask.index("hold_ice(true)") < ask.index("http.request")
assert ask.index("code != 200") < ask.index("_note_ice")
assert ask.index("_note_ice") < ask.index("_connect(")
assert "lobby_failed" in ask
print("lobby contract ok")
