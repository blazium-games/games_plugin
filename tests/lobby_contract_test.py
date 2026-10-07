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
assert ask.index("http.request") < ask.index("if err != OK")
assert "BlaziumIce.user_from_jwt" in lobby
assert "base64_to_utf8" not in lobby
assert 'replace("-", "+")' in ice
assert 'replace("_", "/")' in ice
assert "ice_session_id" in ice
fetch = ice.split("func fetch_ice", 1)[1].split("func _on_ice", 1)[0]
assert fetch.index("ice_session_id") < fetch.index("_ice_session")
print("lobby contract ok")
