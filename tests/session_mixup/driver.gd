extends SceneTree

## Drives BlaziumGames and BlaziumSapi through a Steam sign-in followed by a
## different player's device-code sign-in or restored login. The local peer
## records which credential each later call sends.
##
## Progress, ownership, items, chat, playtime, presence, and dedicated-server
## calls are not covered: they send the Blazium login or an explicit server
## key, not the stored Steam session. Lobby and ICE send a token the caller
## already obtained; request_scoped_token is what would hand them the previous
## player's cached token, and that is covered for the lobby, sapi, and server
## audiences. call_logic is the invoke alias and is covered beside invoke.

const LocalGames := preload("res://local_games.gd")
const LocalSapi := preload("res://local_sapi.gd")
const GAME_UID := "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

var http_base := ""
var ws_base := ""
var games
var sapi
var failures: Array[String] = []
var far_jwt := ""
var near_jwt := ""
var refreshed_jwt := ""
var login_count := 0
var login_fail_count := 0
var login_fail_message := ""
var steam_fail_message := ""
var bug_events := 0
var notice_events := 0
var patch_events := 0
var sapi_events := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var code := await _main()
	quit(code)


func _main() -> int:
	http_base = OS.get_environment("SESSION_MIXUP_HTTP")
	ws_base = OS.get_environment("SESSION_MIXUP_WS")
	if http_base == "" or ws_base == "":
		print("FAIL harness_peer_address")
		return 1
	ProjectSettings.set_setting("blazium/game/game_uid", GAME_UID)
	games = LocalGames.new()
	games.api_base = http_base
	games.login_base = ws_base
	games.persist_session = false
	root.add_child(games)
	sapi = LocalSapi.new()
	sapi.api_base = http_base
	sapi.max_retries = 0
	sapi.timeout = 5.0
	root.add_child(sapi)
	if games.game_uid != GAME_UID:
		print("FAIL harness_game_uid")
		return 1
	games.logged_in.connect(func(_jwt: String) -> void: login_count += 1)
	games.login_failed.connect(func(message: String) -> void:
		login_fail_count += 1
		login_fail_message = message
	)
	games.steam_sign_in_failed.connect(func(message: String) -> void: steam_fail_message = message)
	games.bug_reported.connect(func(_uid: String) -> void: bug_events += 1)
	games.bug_report_failed.connect(func(_message: String) -> void: bug_events += 1)
	games.bug_notices_ready.connect(func(_body: Dictionary) -> void: notice_events += 1)
	games.bug_notices_failed.connect(func(_message: String) -> void: notice_events += 1)
	games.patch_notices_ready.connect(func(_body: Dictionary) -> void: patch_events += 1)
	games.patch_notices_failed.connect(func(_message: String) -> void: patch_events += 1)
	sapi.call_completed.connect(func(_logic: String, _status: int, _body: Variant, _id: String) -> void: sapi_events += 1)
	sapi.call_failed.connect(func(_logic: String, _status: int, _key: String, _message: String, _id: String) -> void: sapi_events += 1)

	var now := int(Time.get_unix_time_from_system())
	far_jwt = _jwt(now + int(games.refresh_margin) + 7 * 24 * 3600, "player-b")
	near_jwt = _jwt(now + int(games.refresh_margin / 2.0), "player-b")
	refreshed_jwt = _jwt(now + int(games.refresh_margin) + 3 * 24 * 3600, "player-b-refreshed")
	games.jwt = far_jwt
	var far_exp: int = games.session_expiry()
	games.jwt = near_jwt
	var near_exp: int = games.session_expiry()
	var near_left: int = near_exp - now
	games.jwt = ""
	check(far_exp == now + int(games.refresh_margin) + 7 * 24 * 3600, "harness_far_login_parses")
	check(near_left > 0 and near_left <= int(games.refresh_margin), "harness_near_login_is_inside_refresh_margin")
	if failures.size() > 0:
		return 1
	var configured: Dictionary = await _control(HTTPClient.METHOD_POST, "/__test/config", JSON.stringify({
		"player_b_far": far_jwt,
		"player_b_near": near_jwt,
		"player_b_refreshed": refreshed_jwt,
	}))
	if not bool(configured.get("ok", false)):
		print("FAIL harness_config")
		return 1

	await _test_device_code()
	await _test_restore_without_refresh()
	await _test_restore_before_refresh_returns()
	await _test_restore_session_file()

	print("SESSION_MIXUP_FAILURES %d" % failures.size())
	for name in failures:
		print("FAILED ", name)
	return 1 if failures.size() > 0 else 0


func _test_device_code() -> void:
	print("TEST device_code_switch")
	if not await _reset():
		return
	var seeded := await _cache_audiences(["lobby"])
	if not bool(seeded.get("ok", false)):
		return
	var logins := login_count
	var fails := login_fail_count
	games.login_timeout = 0.0
	games.start_login()
	if not await _wait_status("login_waiting", 8.0):
		check(false, "device_code_login_reached_server", login_fail_message)
		return
	# The switch has started and the new login has not arrived. The previous
	# Steam session must already be gone, before the login socket finishes.
	check(games.steam_token == "", "device_code_clears_steam_before_login_completes")
	check(games._scoped_tokens.is_empty(), "device_code_drops_cached_tokens_at_start")
	var window_bug: Array = await _after_bug(func() -> void: games.report_bug("during switch"))
	check(not _auth_is(window_bug, "player-a-steam"), "device_code_window_bug_report_does_not_use_previous_steam_session", window_bug)
	var window_mark := await _mark()
	var window_reply: Dictionary = await games.request_scoped_token("server")
	var window_rows := await _since(window_mark)
	check(
		not _auth_is(window_rows, "player-a-steam") and not _auth_is(window_rows, "player-a-steam-body") and not bool(window_reply.get("ok", false)),
		"device_code_window_scoped_server_token_does_not_use_previous_steam_session",
		window_rows
	)
	await _control(HTTPClient.METHOD_POST, "/__test/release-login", "{}")
	if not await _wait_until(func() -> bool: return login_count > logins or login_fail_count > fails, 8.0):
		check(false, "device_code_login_completed")
		return
	if login_count <= logins:
		check(false, "device_code_login_completed", login_fail_message)
		return
	check(games.jwt == far_jwt, "device_code_login_is_player_b")
	check(games.steam_token == "", "device_code_steam_still_clear_after_player_b_login")
	await _expect_player_b_calls("device_code", "player-b-login")


func _test_restore_without_refresh() -> void:
	print("TEST restore_without_refresh")
	if not await _reset():
		return
	var seeded := await _cache_audiences(["sapi", "lobby", "server"])
	if not bool(seeded.get("ok", false)):
		return
	var previous: Dictionary = seeded["tokens"]
	var logins := login_count
	var fails := login_fail_count
	await games.restore_session_from(far_jwt)
	if login_count <= logins:
		check(false, "restore_far_completed", login_fail_message if login_fail_count > fails else "no logged_in")
		return
	check(games.jwt == far_jwt, "restore_far_login_is_player_b")
	check(games.steam_token == "", "restore_far_clears_steam")
	check(games._scoped_tokens.is_empty(), "restore_far_drops_cached_tokens")
	await _expect_fresh_scoped("restore_far", "lobby", str(previous["lobby"]), "player-b-login")
	await _expect_fresh_scoped("restore_far", "server", str(previous["server"]), "player-b-login")
	await _expect_player_b_calls("restore_far", "player-b-login")


func _test_restore_before_refresh_returns() -> void:
	print("TEST restore_before_refresh_returns")
	if not await _reset():
		return
	var seeded := await _cache_audiences(["sapi", "lobby", "server"])
	if not bool(seeded.get("ok", false)):
		return
	var previous_lobby := str(seeded["tokens"]["lobby"])
	var logins := login_count
	var fails := login_fail_count
	# Start the coroutine and observe it while the refresh request is outstanding.
	games.restore_session_from(near_jwt)
	if not await _wait_status("refresh_waiting", 8.0):
		check(false, "restore_near_refresh_started", login_fail_message if login_fail_count > fails else "")
		return
	var inflight := await _since(0)
	check(_has(inflight, "/public/token/refresh", "player-b-near-login"), "restore_near_refresh_uses_player_b_login", inflight)
	check(games.steam_token == "", "restore_near_clears_steam_before_refresh_returns")
	check(games._scoped_tokens.is_empty(), "restore_near_drops_cached_tokens_before_refresh_returns")
	var mark := await _mark()
	var reply: Dictionary = await games.request_scoped_token("lobby")
	var rows := await _since(mark)
	var reused := str(reply.get("token", "")) == previous_lobby
	check(
		not reused and _has(rows, "/private/games/", "player-b-near-login") and str(_row_audience(rows, "/tokens")) == "lobby",
		"restore_near_lobby_token_is_not_previous_player_while_refresh_is_outstanding",
		{"reused_previous": reused, "requests": rows}
	)
	await _control(HTTPClient.METHOD_POST, "/__test/release-refresh", "{}")
	if not await _wait_until(func() -> bool: return login_count > logins or login_fail_count > fails, 8.0):
		check(false, "restore_near_completed")
		return
	if login_count <= logins:
		check(false, "restore_near_completed", login_fail_message)
		return
	check(games.jwt == refreshed_jwt, "restore_near_login_is_refreshed_player_b")
	check(games.steam_token == "", "restore_near_steam_still_clear_after_refresh")
	await _expect_player_b_calls("restore_near", "player-b-refreshed-login")


func _test_restore_session_file() -> void:
	print("TEST restore_session_file")
	if not await _reset():
		return
	games.persist_session = true
	games.jwt = far_jwt
	games._save_session()
	games.jwt = ""
	var seeded := await _cache_audiences(["lobby"])
	if not bool(seeded.get("ok", false)):
		games.persist_session = false
		return
	var previous_lobby := str(seeded["tokens"]["lobby"])
	var logins := login_count
	var fails := login_fail_count
	await games.restore_session()
	games.persist_session = false
	if login_count <= logins:
		check(false, "restore_file_completed", login_fail_message if login_fail_count > fails else "no logged_in")
		return
	check(games.jwt == far_jwt, "restore_file_login_is_player_b")
	check(games.steam_token == "", "restore_file_clears_steam")
	check(games._scoped_tokens.is_empty(), "restore_file_drops_cached_tokens")
	await _expect_fresh_scoped("restore_file", "lobby", previous_lobby, "player-b-login")
	var bug_rows: Array = await _after_bug(func() -> void: games.report_bug("restored file"))
	check(_has(bug_rows, "/bugs", "player-b-login") and not _auth_is(bug_rows, "player-a-steam"), "restore_file_bug_report_uses_player_b", bug_rows)


func _expect_player_b_calls(prefix: String, login_auth: String) -> void:
	var bug_rows: Array = await _after_bug(func() -> void: games.report_bug("after switch"))
	check(_ended(bug_rows, "/bugs", login_auth) and not _auth_is(bug_rows, "player-a-steam"), prefix + "_bug_report_uses_player_b", bug_rows)
	var notice_rows: Array = await _after_notice(func() -> void: games.bug_notices())
	check(_ended(notice_rows, "/bugs/notices", login_auth) and not _auth_is(notice_rows, "player-a-steam"), prefix + "_bug_notices_use_player_b", notice_rows)
	var ack_rows: Array = await _after_notice(func() -> void: games.ack_bug_notices(["notice-test"]))
	check(_ended(ack_rows, "/bugs/notices/ack", login_auth) and not _auth_is(ack_rows, "player-a-steam"), prefix + "_ack_bug_notices_use_player_b", ack_rows)
	var patch_rows: Array = await _after_patch(func() -> void: games.patch_notices())
	check(_ended(patch_rows, "/patch/notices", login_auth) and not _auth_is(patch_rows, "player-a-steam"), prefix + "_patch_notices_use_player_b", patch_rows)
	var patch_ack_rows: Array = await _after_patch(func() -> void: games.ack_patch_notices(["note-test"]))
	check(_ended(patch_ack_rows, "/patch/notices/ack", login_auth) and not _auth_is(patch_ack_rows, "player-a-steam"), prefix + "_ack_patch_notices_use_player_b", patch_ack_rows)
	var script_rows: Array = await _after_sapi(func() -> void: sapi.invoke("score_submit", {"score": 1}))
	check(
		_has_audience(script_rows, "/private/games/", login_auth, "sapi") and _has(script_rows, "/score_submit", "player-b-scoped") and not _auth_is(script_rows, "player-a-steam"),
		prefix + "_scripted_invoke_uses_player_b",
		script_rows
	)
	var alias_rows: Array = await _after_sapi(func() -> void: sapi.call_logic("score_ack", {"score": 1}))
	check(_has(alias_rows, "/score_ack", "player-b-scoped") and not _auth_is(alias_rows, "player-a-steam"), prefix + "_scripted_call_logic_uses_player_b", alias_rows)


func _expect_fresh_scoped(prefix: String, audience: String, previous: String, login_auth: String) -> void:
	var mark := await _mark()
	var reply: Dictionary = await games.request_scoped_token(audience)
	var rows := await _since(mark)
	var reused := str(reply.get("token", "")) == previous
	check(
		not reused and bool(reply.get("ok", false)) and _has_audience(rows, "/private/games/", login_auth, audience),
		prefix + "_" + audience + "_token_is_not_previous_player",
		{"reused_previous": reused, "requests": rows}
	)


func _reset() -> bool:
	games.steam_token = ""
	games.steam_id = ""
	games.jwt = ""
	games.user_id = ""
	games.forget_scoped_tokens()
	games.persist_session = false
	games.cancel_login()
	steam_fail_message = ""
	var response := await _control(HTTPClient.METHOD_POST, "/__test/reset", "{}")
	if not bool(response.get("ok", false)):
		check(false, "harness_reset")
		return false
	return true


func _sign_in_steam() -> bool:
	var mark := await _mark()
	steam_fail_message = ""
	games.sign_in_with_steam_ticket("test-steam-web-ticket")
	var deadline := Time.get_ticks_msec() + 8000
	var rows: Array = []
	while Time.get_ticks_msec() < deadline:
		if steam_fail_message != "":
			break
		rows = await _since(mark)
		if games.steam_token != "" and _ended(rows, "/auth", "none"):
			return true
		await process_frame
	check(false, "setup_steam_sign_in", steam_fail_message if steam_fail_message != "" else rows)
	return false


func _cache_audiences(audiences: Array) -> Dictionary:
	if not await _sign_in_steam():
		return {"ok": false}
	var tokens := {}
	for audience in audiences:
		var mark := await _mark()
		var reply: Dictionary = await games.request_scoped_token(str(audience))
		var rows := await _since(mark)
		var from_steam := _has_audience(rows, "/steam/", "player-a-steam-body", str(audience))
		if not bool(reply.get("ok", false)) or not from_steam:
			check(false, "setup_cached_" + str(audience), rows)
			return {"ok": false}
		tokens[str(audience)] = str(reply.get("token", ""))
	return {"ok": true, "tokens": tokens}


func _after_bug(action: Callable) -> Array:
	return await _after(action, func() -> int: return bug_events)


func _after_notice(action: Callable) -> Array:
	return await _after(action, func() -> int: return notice_events)


func _after_patch(action: Callable) -> Array:
	return await _after(action, func() -> int: return patch_events)


func _after_sapi(action: Callable) -> Array:
	return await _after(action, func() -> int: return sapi_events)


func _after(action: Callable, counter: Callable) -> Array:
	var start := int(counter.call())
	var mark := await _mark()
	action.call()
	await _wait_until(func() -> bool: return int(counter.call()) > start, 8.0)
	return await _since(mark)


func _mark() -> int:
	var status := await _control(HTTPClient.METHOD_GET, "/__test/status", "")
	return (status.get("requests", []) as Array).size()


func _since(mark: int) -> Array:
	var status := await _control(HTTPClient.METHOD_GET, "/__test/status", "")
	var all: Array = status.get("requests", [])
	if mark < 0:
		mark = 0
	if mark >= all.size():
		return []
	return all.slice(mark, all.size())


func _wait_status(field: String, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var status := await _control(HTTPClient.METHOD_GET, "/__test/status", "")
		if bool(status.get(field, false)):
			return true
		await process_frame
	return false


func _wait_until(pred: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(pred.call()):
			return true
		await process_frame
	return bool(pred.call())


func _control(method: int, path: String, body: String) -> Dictionary:
	var http := HTTPRequest.new()
	root.add_child(http)
	var err := http.request(http_base + path, PackedStringArray(["Content-Type: application/json", "Accept: application/json"]), method, body)
	if err != OK:
		http.queue_free()
		return {}
	var result: Array = await http.request_completed
	http.queue_free()
	if result.size() < 4 or int(result[0]) != HTTPRequest.RESULT_SUCCESS:
		return {}
	var parsed = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


func _jwt(exp: int, sub: String) -> String:
	var payload := '{"exp":%d,"sub":"%s"}' % [exp, sub]
	return "test-header." + Marshalls.raw_to_base64(payload.to_utf8_buffer()) + ".test-signature"


func _ended(rows: Array, suffix: String, auth: String) -> bool:
	for row in rows:
		var path := str(row.get("path", ""))
		if path.ends_with(suffix) and str(row.get("auth", "")) == auth:
			return true
	return false


func _has(rows: Array, fragment: String, auth: String) -> bool:
	for row in rows:
		if str(row.get("path", "")).find(fragment) >= 0 and str(row.get("auth", "")) == auth:
			return true
	return false


func _has_audience(rows: Array, fragment: String, auth: String, audience: String) -> bool:
	for row in rows:
		if str(row.get("path", "")).find(fragment) >= 0 and str(row.get("path", "")).ends_with("/tokens") and str(row.get("auth", "")) == auth and str(row.get("audience", "")) == audience:
			return true
	return false


func _row_audience(rows: Array, fragment: String) -> String:
	for row in rows:
		if str(row.get("path", "")).find(fragment) >= 0:
			return str(row.get("audience", ""))
	return ""


func _auth_is(rows: Array, auth: String) -> bool:
	for row in rows:
		if str(row.get("auth", "")) == auth:
			return true
	return false


func check(ok: bool, name: String, detail: Variant = null) -> void:
	if ok:
		print("PASS ", name)
		return
	failures.append(name)
	if detail == null:
		print("FAIL ", name)
	else:
		print("FAIL ", name, " ", detail)
