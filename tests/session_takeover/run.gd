extends SceneTree

const _RegisterIce := preload("res://addons/blazium_games/blazium_ice.gd")
const _RegisterLobby := preload("res://addons/blazium_games/blazium_lobby.gd")
const _RegisterSapi := preload("res://addons/blazium_games/blazium_sapi.gd")

## Spec for the stale sign-in commit. Each case starts a real client call, changes the
## session while that call is held, then lets the response arrive. The assertions
## describe the fixed behavior: a response from an earlier session must not write
## the login, the scoped-token cache, the Steam token, or the session file, and
## later play / lobby / Scripted API calls must not send that credential.
##
## request_chat_token is not covered. It returns a chat password to the caller and
## does not store a session credential.

const GAME_UID := "11111111-1111-1111-1111-111111111111"
const REFRESHED_LOGIN := "placeholder-refreshed-previous-login"
const SCOPED_PREVIOUS := "placeholder-scoped-previous"
const SCOPED_NEXT := "placeholder-scoped-next"
const SCOPED_STEAM := "placeholder-scoped-from-steam"
const STEAM_PREVIOUS := "placeholder-steam-previous"
const STEAM_NEXT := "placeholder-steam-next"
const STEAM_SESSION := "placeholder-steam-session"
const TICKET_PREVIOUS := "placeholder-ticket-previous"
const TICKET_NEXT := "placeholder-ticket-next"
const PREVIOUS_LOGIN := "placeholder-previous-login"

var api := ""
var sapi_base := ""
var failures: Array[String] = []
var games: Node
var refreshed_labels: Array[String] = []
var steam_labels: Array[String] = []

func _init() -> void:
	call_deferred("_main")

func _main() -> void:
	var port := OS.get_environment("SESSION_TAKEOVER_PORT")
	if port == "":
		port = "8765"
	api = "http://127.0.0.1:%s" % port
	sapi_base = api + "/sapi"
	ProjectSettings.set_setting("blazium/game/game_uid", GAME_UID)
	var code := await run_all()
	quit(code)

func run_all() -> int:
	await case_session_file_roundtrip()
	await case_short_tick_does_not_refresh()
	await case_refresh_after_logout()
	await case_refresh_after_newer_login()
	await case_refresh_after_restore()
	await case_scoped_lobby_after_logout()
	await case_scoped_sapi_after_logout()
	await case_scoped_steam_after_logout()
	await case_scoped_after_newer_login()
	await case_steam_after_logout()
	await case_steam_late_first_before_second_completes()
	await case_steam_late_first_after_second_completes()
	print("RESULT fail=%d" % failures.size())
	if failures.is_empty():
		return 0
	return 1

func check(ok: bool, name: String) -> void:
	if ok:
		print("PASS ", name)
	else:
		print("FAIL ", name)
		failures.append(name)

func login_label(token: String) -> String:
	if token == "":
		return "empty"
	if token == REFRESHED_LOGIN:
		return "refreshed-previous-login"
	if token == PREVIOUS_LOGIN:
		return "previous-login"
	return "other"

func scoped_label(token: String) -> String:
	if token == "":
		return "empty"
	if token == SCOPED_PREVIOUS:
		return "scoped-previous"
	if token == SCOPED_NEXT:
		return "scoped-next"
	if token == SCOPED_STEAM:
		return "scoped-steam"
	return "other"

func steam_label(token: String) -> String:
	if token == "":
		return "empty"
	if token == STEAM_PREVIOUS:
		return "steam-previous"
	if token == STEAM_NEXT:
		return "steam-next"
	if token == STEAM_SESSION:
		return "steam-session"
	return "other"

func placeholder_login(exp: int, who: String) -> String:
	var header := _b64('{"alg":"none","typ":"JWT"}')
	var payload := _b64('{"exp":%d,"sub":"%s"}' % [exp, who])
	return "%s.%s.placeholder-signature" % [header, payload]

func _b64(text: String) -> String:
	var raw := Marshalls.raw_to_base64(text.to_utf8_buffer())
	return raw.replace("+", "-").replace("/", "_").replace("=", "")

func wipe_session() -> void:
	var path := "user://blazium_session.dat"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func new_games(persist: bool) -> void:
	if games != null and is_instance_valid(games):
		games.queue_free()
		await process_frame
	wipe_session()
	refreshed_labels.clear()
	steam_labels.clear()
	games = load("res://probe_games.gd").new()
	games.api_override = api
	games.persist_session = persist
	games.login_timeout = 0.0
	root.add_child(games)
	games.game_uid = GAME_UID
	games.session_refreshed.connect(func(token: String) -> void:
		refreshed_labels.append(login_label(token))
	)
	games.steam_signed_in.connect(func(_steam_id: String, token: String) -> void:
		steam_labels.append(steam_label(token))
	)
	if not str(games._api()).begins_with("http://127.0.0.1:"):
		push_error("API override is not local")
		quit(2)
	if not str(games._login_url()).begins_with("ws://127.0.0.1:"):
		push_error("login URL override is not local")
		quit(2)

func control(method: String, path: String, payload: String = "") -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 5.0
	root.add_child(http)
	var err := OK
	if method == "GET":
		err = http.request(api + path)
	else:
		err = http.request(api + path, PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, payload)
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

func reset_server() -> void:
	await control("POST", "/control/release", "{\"name\":\"*\"}")
	await control("POST", "/control/reset", "{}")

func arm(previous_login: String, next_login: String, hold_next_steam: bool) -> void:
	var body := JSON.stringify({
		"previous_login": previous_login,
		"next_login": next_login,
		"hold_steam_next": hold_next_steam,
	})
	await control("POST", "/control/expect", body)

func pending_has(kind: String) -> bool:
	var state := await control("GET", "/control/state")
	var pending: Array = state.get("pending", [])
	for item in pending:
		if str(item).begins_with(kind):
			return true
	return false

func flag(name: String) -> bool:
	var state := await control("GET", "/control/state")
	var flags = state.get("flags", {})
	if typeof(flags) != TYPE_DICTIONARY:
		return false
	return bool(flags.get(name, false))

func wait_pending(kind: String) -> bool:
	for _i in 80:
		if await pending_has(kind):
			return true
		await create_timer(0.05).timeout
	return false

func wait_flag(name: String) -> bool:
	for _i in 80:
		if await flag(name):
			return true
		await create_timer(0.05).timeout
	return false

func release(kind: String) -> void:
	await control("POST", "/control/release", JSON.stringify({"name": kind}))

func http_children() -> int:
	if games == null or not is_instance_valid(games):
		return 0
	var count := 0
	for child in games.get_children():
		if child is HTTPRequest:
			count += 1
	return count

func settle() -> void:
	for _i in 120:
		var busy: bool = await pending_has("refresh") or await pending_has("scoped") or await pending_has("steam")
		if not busy and http_children() == 0:
			break
		await process_frame
	for _i in 8:
		await process_frame

func cached(audience: String) -> String:
	var held = games._scoped_tokens.get(audience, null)
	if typeof(held) != TYPE_DICTIONARY:
		return ""
	var reply = held.get("reply", {})
	if typeof(reply) != TYPE_DICTIONARY:
		return ""
	return str(reply.get("token", ""))

func fetch_scoped(audience: String, box: Dictionary) -> void:
	box["reply"] = await games.request_scoped_token(audience)
	box["done"] = true

func saved_labels() -> Array[String]:
	var labels: Array[String] = []
	for item in games.save_log:
		labels.append(login_label(str(item)))
	return labels

func case_session_file_roundtrip() -> void:
	await new_games(true)
	var exp := int(Time.get_unix_time_from_system()) + 10 * 24 * 3600
	var token := placeholder_login(exp, "roundtrip")
	games.jwt = token
	check(games.session_expiry() == exp, "session_expiry_reads_placeholder_exp")
	games._save_session()
	check(games._load_session() == token, "session_file_roundtrip")
	games._forget_saved_session()
	check(not FileAccess.file_exists("user://blazium_session.dat"), "session_file_removed")
	games.save_log.clear()

func case_short_tick_does_not_refresh() -> void:
	await reset_server()
	await new_games(false)
	var exp := int(Time.get_unix_time_from_system()) + 3600
	games.jwt = placeholder_login(exp, "previous-player")
	games._tick_refresh(299.0)
	await process_frame
	await process_frame
	check(not await flag("refresh_seen"), "short_tick_does_not_refresh")
	games.queue_free()
	games = null

func case_refresh_after_logout() -> void:
	await reset_server()
	await new_games(true)
	var exp := int(Time.get_unix_time_from_system()) + 3600
	var previous := placeholder_login(exp, "previous-player")
	games.jwt = previous
	await arm(previous, "", false)
	# The product loop is what asks for the refresh: one tick past the five-minute gate.
	games._process(300.0)
	var started := await wait_pending("refresh")
	check(started, "refresh_after_logout_request_started")
	if not started:
		return
	await games.logout()
	check(games.jwt == "", "refresh_after_logout_clears_before_response")
	check(not FileAccess.file_exists("user://blazium_session.dat"), "refresh_after_logout_file_absent_before_response")
	var saves_before: int = int(games.save_log.size())
	await release("refresh")
	await settle()
	check(games.jwt == "", "refresh_after_logout_login_stays_clear")
	check(games.save_log.size() == saves_before, "refresh_after_logout_does_not_write_session_file")
	check(not FileAccess.file_exists("user://blazium_session.dat"), "refresh_after_logout_file_absent_after_response")
	check(not refreshed_labels.has("refreshed-previous-login"), "refresh_after_logout_does_not_emit_session_refreshed")
	var failed := {"progress": false, "item": false}
	games.progress_failed.connect(func(_message: String) -> void:
		failed["progress"] = true
	)
	games.item_failed.connect(func(_message: String) -> void:
		failed["item"] = true
	)
	games.progress()
	games.transfer_item(["placeholder-item"], "to_game", "placeholder-request")
	await wait_flag("progress_used_refreshed_login")
	await process_frame
	await process_frame
	check(not await flag("progress_used_refreshed_login"), "refresh_after_logout_progress_does_not_send_previous_login")
	check(not await flag("transfer_used_refreshed_login"), "refresh_after_logout_transfer_does_not_send_previous_login")
	check(bool(failed["progress"]), "refresh_after_logout_progress_refuses_when_signed_out")
	check(bool(failed["item"]), "refresh_after_logout_transfer_refuses_when_signed_out")

func case_refresh_after_newer_login() -> void:
	await reset_server()
	await new_games(true)
	games.jwt = PREVIOUS_LOGIN
	var exp := int(Time.get_unix_time_from_system()) + 10 * 24 * 3600
	var nxt := placeholder_login(exp, "next-player")
	await arm(PREVIOUS_LOGIN, nxt, false)
	games.refresh_session()
	var started := await wait_pending("refresh")
	check(started, "refresh_after_newer_login_request_started")
	if not started:
		return
	games.start_login()
	games._on_message({"action": "jwt", "jwt": nxt, "uid": "placeholder-next-user"})
	await process_frame
	await process_frame
	check(games.jwt == nxt, "refresh_after_newer_login_second_player_signed_in")
	check(games._load_session() == nxt, "refresh_after_newer_login_file_is_second_player")
	var scoped: Dictionary = await games.request_scoped_token("lobby")
	check(str(scoped.get("token", "")) == SCOPED_NEXT, "refresh_after_newer_login_second_player_scoped_token")
	var saves_before: int = int(games.save_log.size())
	await release("refresh")
	await settle()
	check(games.jwt == nxt, "refresh_after_newer_login_does_not_overwrite_login")
	check(cached("lobby") == SCOPED_NEXT, "refresh_after_newer_login_keeps_second_player_scoped_token")
	check(games.save_log.size() == saves_before, "refresh_after_newer_login_does_not_rewrite_session_file")
	check(games._load_session() == nxt, "refresh_after_newer_login_file_stays_second_player")
	check(not refreshed_labels.has("refreshed-previous-login"), "refresh_after_newer_login_does_not_emit_session_refreshed")

func case_refresh_after_restore() -> void:
	await reset_server()
	await new_games(true)
	games.jwt = PREVIOUS_LOGIN
	var exp := int(Time.get_unix_time_from_system()) + 10 * 24 * 3600
	var nxt := placeholder_login(exp, "restored-player")
	await arm(PREVIOUS_LOGIN, nxt, false)
	games.refresh_session()
	var started := await wait_pending("refresh")
	check(started, "refresh_after_restore_request_started")
	if not started:
		return
	await games.restore_session_from(nxt)
	check(games.jwt == nxt, "refresh_after_restore_second_player_restored")
	var saves_before: int = int(games.save_log.size())
	await release("refresh")
	await settle()
	check(games.jwt == nxt, "refresh_after_restore_does_not_overwrite_login")
	check(games.save_log.size() == saves_before, "refresh_after_restore_does_not_write_session_file")
	check(not FileAccess.file_exists("user://blazium_session.dat") or games._load_session() == nxt, "refresh_after_restore_file_is_not_previous_login")
	check(not refreshed_labels.has("refreshed-previous-login"), "refresh_after_restore_does_not_emit_session_refreshed")

func case_scoped_lobby_after_logout() -> void:
	await reset_server()
	await new_games(false)
	games.jwt = PREVIOUS_LOGIN
	await arm(PREVIOUS_LOGIN, "", false)
	var box := {"done": false, "reply": {}}
	fetch_scoped("lobby", box)
	var started := await wait_pending("scoped-previous")
	check(started, "scoped_lobby_after_logout_request_started")
	if not started:
		return
	await games.logout()
	check(games.jwt == "" and cached("lobby") == "", "scoped_lobby_after_logout_clears_before_response")
	await release("scoped-previous")
	for _i in 80:
		if bool(box["done"]):
			break
		await process_frame
	check(cached("lobby") != SCOPED_PREVIOUS, "scoped_lobby_after_logout_does_not_cache")
	var later: Dictionary = await games.request_scoped_token("lobby")
	check(not bool(later.get("ok", false)), "scoped_lobby_after_logout_later_call_refused")
	check(str(later.get("token", "")) != SCOPED_PREVIOUS, "scoped_lobby_after_logout_later_call_is_not_previous")
	if bool(later.get("ok", false)):
		var lobby = load("res://probe_lobby.gd").new()
		lobby.api_override = api
		root.add_child(lobby)
		if not str(lobby._api()).begins_with("http://127.0.0.1:"):
			push_error("lobby API override is not local")
			quit(2)
		lobby.create_lobby(str(later.get("token", "")), "public")
		await wait_flag("lobby_admit_seen")
		lobby.queue_free()
	check(not await flag("lobby_used_scoped_previous"), "scoped_lobby_after_logout_lobby_does_not_send_previous")

func case_scoped_sapi_after_logout() -> void:
	await reset_server()
	await new_games(false)
	games.jwt = PREVIOUS_LOGIN
	await arm(PREVIOUS_LOGIN, "", false)
	var box := {"done": false, "reply": {}}
	fetch_scoped("sapi", box)
	var started := await wait_pending("scoped-previous")
	check(started, "scoped_sapi_after_logout_request_started")
	if not started:
		return
	await games.logout()
	await release("scoped-previous")
	for _i in 80:
		if bool(box["done"]):
			break
		await process_frame
	check(cached("sapi") != SCOPED_PREVIOUS, "scoped_sapi_after_logout_does_not_cache")
	var sapi = load("res://probe_sapi.gd").new()
	sapi.base_override = sapi_base
	root.add_child(sapi)
	if not str(sapi._base()).begins_with("http://127.0.0.1:"):
		push_error("sapi base override is not local")
		quit(2)
	var done := {"v": false}
	sapi.call_completed.connect(func(_logic: String, _status: int, _body: Variant, _request_id: String) -> void:
		done.v = true
	)
	sapi.call_failed.connect(func(_logic: String, _status: int, _key: String, _message: String, _request_id: String) -> void:
		done.v = true
	)
	sapi.invoke("score_submit", {"score": 1})
	for _i in 80:
		if bool(done.v):
			break
		await create_timer(0.05).timeout
	check(bool(done.v), "scoped_sapi_after_logout_invoke_finished")
	check(not await flag("sapi_used_scoped_previous"), "scoped_sapi_after_logout_invoke_does_not_send_previous")
	sapi.queue_free()

func case_scoped_steam_after_logout() -> void:
	await reset_server()
	await new_games(false)
	games.jwt = ""
	games.steam_token = STEAM_SESSION
	await arm("", "", false)
	var box := {"done": false, "reply": {}}
	fetch_scoped("server", box)
	var started := await wait_pending("scoped-steam")
	check(started, "scoped_steam_after_logout_request_started")
	if not started:
		return
	await games.logout()
	check(games.steam_token == "" and cached("server") == "", "scoped_steam_after_logout_clears_before_response")
	await release("scoped-steam")
	for _i in 80:
		if bool(box["done"]):
			break
		await process_frame
	check(cached("server") != SCOPED_STEAM, "scoped_steam_after_logout_does_not_cache")
	var later: Dictionary = await games.request_scoped_token("server")
	check(not bool(later.get("ok", false)), "scoped_steam_after_logout_later_call_refused")
	check(str(later.get("token", "")) != SCOPED_STEAM, "scoped_steam_after_logout_later_call_is_not_previous")

func case_scoped_after_newer_login() -> void:
	await reset_server()
	await new_games(false)
	games.jwt = PREVIOUS_LOGIN
	var exp := int(Time.get_unix_time_from_system()) + 10 * 24 * 3600
	var nxt := placeholder_login(exp, "next-player")
	await arm(PREVIOUS_LOGIN, nxt, false)
	var box := {"done": false, "reply": {}}
	fetch_scoped("lobby", box)
	var started := await wait_pending("scoped-previous")
	check(started, "scoped_after_newer_login_request_started")
	if not started:
		return
	games.start_login()
	games._on_message({"action": "jwt", "jwt": nxt, "uid": "placeholder-next-user"})
	var nxt_reply: Dictionary = await games.request_scoped_token("lobby")
	check(str(nxt_reply.get("token", "")) == SCOPED_NEXT, "scoped_after_newer_login_second_token_cached")
	await release("scoped-previous")
	for _i in 80:
		if bool(box["done"]):
			break
		await process_frame
	check(cached("lobby") == SCOPED_NEXT, "scoped_after_newer_login_does_not_replace_cache")
	var later: Dictionary = await games.request_scoped_token("lobby")
	check(str(later.get("token", "")) == SCOPED_NEXT, "scoped_after_newer_login_later_call_is_second_player")

func case_steam_after_logout() -> void:
	await reset_server()
	await new_games(false)
	games.game_uid = GAME_UID
	games.sign_in_with_steam_ticket(TICKET_PREVIOUS)
	var started := await wait_pending("steam-previous")
	check(started, "steam_after_logout_request_started")
	if not started:
		return
	await games.logout()
	check(games.steam_token == "", "steam_after_logout_clears_before_response")
	await release("steam-previous")
	await settle()
	check(games.steam_token == "", "steam_after_logout_token_stays_clear")
	check(not steam_labels.has("steam-previous"), "steam_after_logout_does_not_emit_steam_signed_in")
	var sapi = load("res://probe_sapi.gd").new()
	sapi.base_override = sapi_base
	root.add_child(sapi)
	var done := {"v": false}
	sapi.call_completed.connect(func(_logic: String, _status: int, _body: Variant, _request_id: String) -> void:
		done.v = true
	)
	sapi.call_failed.connect(func(_logic: String, _status: int, _key: String, _message: String, _request_id: String) -> void:
		done.v = true
	)
	sapi.invoke("score_submit", {"score": 1})
	var bug_failed := {"v": false}
	games.bug_report_failed.connect(func(_message: String) -> void:
		bug_failed.v = true
	)
	games.report_bug("placeholder")
	for _i in 80:
		if bool(done.v) and (bool(bug_failed.v) or await flag("bug_seen")):
			break
		await create_timer(0.05).timeout
	check(not await flag("sapi_used_steam_previous"), "steam_after_logout_sapi_does_not_send_previous")
	check(not await flag("bug_used_steam_previous"), "steam_after_logout_bug_report_does_not_send_previous")
	sapi.queue_free()

func case_steam_late_first_before_second_completes() -> void:
	await reset_server()
	await new_games(false)
	await arm("", "", true)
	games.sign_in_with_steam_ticket(TICKET_PREVIOUS)
	var first := await wait_pending("steam-previous")
	check(first, "steam_overlap_first_started")
	if not first:
		return
	games.sign_in_with_steam_ticket(TICKET_NEXT)
	var second := await wait_pending("steam-next")
	check(second, "steam_overlap_second_started")
	if not second:
		return
	await release("steam-previous")
	await settle()
	check(games.steam_token == "", "steam_overlap_early_response_does_not_commit")
	check(not steam_labels.has("steam-previous"), "steam_overlap_early_response_does_not_emit")
	await release("steam-next")
	await settle()
	check(steam_label(games.steam_token) == "steam-next", "steam_overlap_current_sign_in_still_commits")
	check(steam_labels.has("steam-next"), "steam_overlap_current_sign_in_emits")

func case_steam_late_first_after_second_completes() -> void:
	await reset_server()
	await new_games(false)
	await arm("", "", false)
	games.sign_in_with_steam_ticket(TICKET_PREVIOUS)
	var first := await wait_pending("steam-previous")
	check(first, "steam_overwrite_first_started")
	if not first:
		return
	games.sign_in_with_steam_ticket(TICKET_NEXT)
	for _i in 80:
		if steam_label(games.steam_token) == "steam-next":
			break
		await process_frame
	check(steam_label(games.steam_token) == "steam-next", "steam_overwrite_second_committed_first")
	await release("steam-previous")
	await settle()
	check(steam_label(games.steam_token) == "steam-next", "steam_overwrite_late_first_does_not_replace_second")
	check(not steam_labels.has("steam-previous"), "steam_overwrite_late_first_does_not_emit")
