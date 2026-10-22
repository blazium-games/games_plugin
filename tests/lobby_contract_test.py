from pathlib import Path

lobby = Path("addons/blazium_games/blazium_lobby.gd").read_text(encoding="utf-8")
ice = Path("addons/blazium_games/blazium_ice.gd").read_text(encoding="utf-8")
games = Path("addons/blazium_games/blazium_games.gd").read_text(encoding="utf-8")

assert '"game_uid": _game_uid' in lobby
assert '"game_uid": game_uid' in lobby
assert "join_lobby" in lobby
assert "HashingContext.HASH_SHA256" not in ice
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
assert 'data.get("ticket"' in ask
assert '"ticket": _ticket' in lobby
assert '"token": _jwt' not in lobby
assert "lobby_failed" in ask
assert ask.index("http.request") < ask.index("if err != OK")
assert "BlaziumIce.player_id" in lobby
claims = ice.split("static func user_from_jwt", 1)[1].split("static func player_id", 1)[0]
assert claims.index('"user_uid"') < claims.index('"uid"')
assert "blazium_games" in ice
assert 'add_to_group("blazium_games")' in games
assert 'message.get("uid"' in games
assert "base64_to_utf8" not in lobby
assert 'replace("-", "+")' in ice
assert 'replace("_", "/")' in ice
assert "ice_session_id" in ice
fetch = ice.split("func fetch_ice", 1)[1].split("func _on_ice", 1)[0]
assert "_ice_session" not in ice
assert "ERR_BUSY" in fetch
assert "STATE_CLOSED" in lobby
play = games.split("func _tick_playtime", 1)[1].split("func sign_in_with_steam_ticket", 1)[0]
assert play.index("http.request") < play.index("if err != OK")
assert "queue_free" in play[play.index("if err != OK"):]
assert "func leave_lobby" in lobby
assert '"leave_lobby"' in lobby
leave = lobby.split("func leave_lobby", 1)[1].split("func _peers", 1)[0]
assert leave.index('"leave_lobby"') < leave.index("_socket.close()")
assert 'op == "lobby_created"' in lobby
assert 'op == "joined_lobby"' in lobby
assert 'err.get("msg"' in lobby
assert "/private/library/" in games
assert "playtime" in games
assert 'body.get("logged_on"' in games
print("lobby contract ok")
