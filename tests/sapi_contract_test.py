from pathlib import Path

sapi = Path("addons/blazium_games/blazium_sapi.gd").read_text(encoding="utf-8")
plugin = Path("addons/blazium_games/plugin.gd").read_text(encoding="utf-8")

assert "class_name BlaziumSapi" in sapi
assert 'const SAPI := "https://sapi.blazium.online"' in sapi
assert "func call(" not in sapi, "call() is Object.call; the method is call_logic"
assert "func invoke(logic: String" in sapi
assert "func call_logic(logic: String" in sapi, "call_logic stays as an alias of invoke"
alias = sapi.split("func call_logic", 1)[1].split("func _send", 1)[0]
assert "invoke(logic, args, opts)" in alias
assert "signal call_completed" in sapi
assert "signal call_failed" in sapi

# The URL is /v1/{game_uid}/{logic}, through the Discord proxy inside an activity.
call = sapi.split("func invoke", 1)[1].split("func call_logic", 1)[0]
assert '"/v1/" + _game_uid.uri_encode() + "/" + logic' in call
assert ".proxy/blazium/sapi" in sapi
pin = sapi.split("func _discord_application_id", 1)[1].split("func _base", 1)[0]
assert "blazium/discord/application_id" in pin
assert "host_id != configured" in pin

# The token comes from the BlaziumGames node, which requests a short-lived one for this game.
# Neither the login token nor the Steam session is read here; anonymous calls skip it.
token = sapi.split("func _bearer", 1)[1].split("func _forget_tokens", 1)[0]
assert 'get_first_node_in_group("blazium_games")' in token
assert "steam_token" not in sapi, "the Scripted API client must not read the Steam session"
assert '"jwt"' not in token and "games.jwt" not in token, "the Scripted API client must not read the login token"
assert 'request_scoped_token("sapi")' in token
assert '"anonymous"' in call
send = sapi.split("func _send", 1)[1].split("func _retry", 1)[0]
assert '"Authorization: Bearer " + token' in send
assert 'bool(req["anonymous"])' in send
assert "code == 401" in send and 'req["refreshed"]' in send and "_forget_tokens()" in send
assert "_session_token" not in sapi

# Channel and idempotency headers. Retries reuse the same headers, so the key is stable.
assert '"X-Blazium-Channel: "' in call
assert '"Idempotency-Key: "' in call
assert call.index('"Idempotency-Key: "') > call.index('if method != "GET"')
assert "code == 429 or code == 503" in send
assert '"retry-after"' in send
assert "max_retries" in send
assert send.index("http.request(") < send.index("if err != OK")
assert "queue_free" in send[send.index("if err != OK"):]
retry = sapi.split("func _retry", 1)[1].split("static func _header", 1)[0]
assert "minf(wait, 8.0)" in retry
assert "_send(req, attempt + 1)" in retry

# Platform errors are {ok:false, error:{key, message}}.
assert 'parsed["error"].get("key"' in send
assert '"x-request-id"' in send

assert "blazium/sapi/channel" in plugin
assert "blazium/sapi/channel" in sapi

# The scoped token request lives in BlaziumGames: native asks games_service with the login,
# a browser game asks the play origin. Neither mints a token.
games = Path("addons/blazium_games/blazium_games.gd").read_text(encoding="utf-8")
req = games.split("func request_scoped_token", 1)[1].split("func forget_scoped_tokens", 1)[0]
assert '"/private/games/" + game_uid.uri_encode() + "/tokens"' in req
assert '_api() + "/steam/" + game_uid.uri_encode() + "/tokens"' in req
assert '"/blazium/token"' in games and ".proxy/blazium/token" in games
assert 'want != "sapi" and want != "lobby"' in req
assert "_scoped_tokens" in req and "Time.get_ticks_msec()" in req
assert "Crypto" not in req and "HMAC" not in req and "sign(" not in req
assert "func forget_scoped_tokens" in games
start = games.split("func start_login", 1)[1].split("func cancel_login", 1)[0]
assert "forget_scoped_tokens()" in start
note = games.split("func _note_http", 1)[1].split("func _data", 1)[0]
assert "forget_scoped_tokens()" in note
# A multipart body is bytes, so it goes through request_raw (request() takes a String and fails to parse).
assert 'http.request_raw(_api() + "/games/" + game_uid.uri_encode() + "/bugs"' in games
print("sapi contract ok")
