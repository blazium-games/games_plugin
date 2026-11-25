from pathlib import Path

sapi = Path("addons/blazium_games/blazium_sapi.gd").read_text(encoding="utf-8")
plugin = Path("addons/blazium_games/plugin.gd").read_text(encoding="utf-8")

assert "class_name BlaziumSapi" in sapi
assert 'const SAPI := "https://sapi.blazium.online"' in sapi
assert "func call(" not in sapi, "call() is Object.call; the method is call_logic"
assert "func call_logic(logic: String" in sapi
assert "signal call_completed" in sapi
assert "signal call_failed" in sapi

# The URL is /v1/{game_uid}/{logic}, through the Discord proxy inside an activity.
call = sapi.split("func call_logic", 1)[1].split("func _send", 1)[0]
assert '"/v1/" + _game_uid.uri_encode() + "/" + logic' in call
assert ".proxy/blazium/sapi" in sapi
pin = sapi.split("func _discord_application_id", 1)[1].split("func _base", 1)[0]
assert "blazium/discord/application_id" in pin
assert "host_id != configured" in pin

# The session comes from the BlaziumGames node; anonymous calls skip it.
token = sapi.split("func _session_token", 1)[1].split("func _channel", 1)[0]
assert 'get_first_node_in_group("blazium_games")' in token
assert '"steam_token"' in token and '"jwt"' in token
assert '"anonymous"' in call
assert '"Authorization: Bearer " + token' in call

# Channel and idempotency headers. Retries reuse the same headers, so the key is stable.
assert '"X-Blazium-Channel: "' in call
assert '"Idempotency-Key: "' in call
assert call.index('"Idempotency-Key: "') > call.index('if method != "GET"')
send = sapi.split("func _send", 1)[1].split("func _retry", 1)[0]
assert "code == 429 or code == 503" in send
assert '"retry-after"' in send
assert "max_retries" in send
assert send.index("http.request(") < send.index("if err != OK")
assert "queue_free" in send[send.index("if err != OK"):]
retry = sapi.split("func _retry", 1)[1].split("static func _header", 1)[0]
assert "minf(wait, 8.0)" in retry
assert "_send(logic, url, headers, verb, body, attempt + 1)" in retry

# Platform errors are {ok:false, error:{key, message}}.
assert 'parsed["error"].get("key"' in send
assert '"x-request-id"' in send

assert "blazium/sapi/channel" in plugin
assert "blazium/sapi/channel" in sapi
print("sapi contract ok")
