extends SceneTree

## Session isolation. These checks fail while logout, device-code sign-in
## (start_login), and session restore leave the lobby socket, admit ticket,
## and relay list in place. They pass once those session calls drop that state
## before anything else runs, including an admit that is still in flight.
##
## Not covered, because those calls are not account switches in this plugin:
## refresh_session, cancel_login, sign_in_with_steam_ticket, and the 401
## session_expired path.

const GAME_UID := "11111111-1111-4111-8111-111111111111"

var http_port := 0
var lobby_port := 0
var login_port := 0
var jwt_a := ""
var jwt_b := ""
var http: HTTPRequest
var setup_failures := 0
var security_failures := 0
var peer_seq := 0

class LocalGames extends BlaziumGames:
	var local_api := ""
	var local_login := ""

	func _api() -> String:
		if not local_api.begins_with("http://127.0.0.1:"):
			return "http://127.0.0.1:9/refused"
		return local_api

	func _login_url() -> String:
		if not local_login.begins_with("ws://127.0.0.1:"):
			return "ws://127.0.0.1:9/"
		return local_login

class LocalLobby extends BlaziumLobby:
	var local_api := ""
	var local_lobby := ""

	func _api() -> String:
		if not local_api.begins_with("http://127.0.0.1:"):
			return "http://127.0.0.1:9/refused"
		return local_api

	func _lobby_url() -> String:
		if not local_lobby.begins_with("ws://127.0.0.1:"):
			return "ws://127.0.0.1:9/"
		return local_lobby

class BackgroundLogout extends Node:
	var target: LocalGames
	var done := false

	func _ready() -> void:
		await target.logout()
		done = true

## The product hold_ice() calls fetch_ice() once the hold drops. The real
## fetch opens https://stun.blazium.online. This stand-in keeps the held path
## (super) and counts the un-held call instead of opening that connection.
class LocalIce extends BlaziumIce:
	var fetch_calls := 0

	func fetch_ice(jwt: String, _session_id: String) -> void:
		if _hold:
			super.fetch_ice(jwt, _session_id)
			return
		fetch_calls += 1

func _initialize() -> void:
	call_deferred("_go")

func _go() -> void:
	var code := await _main()
	print("setup_failures=%d security_failures=%d" % [setup_failures, security_failures])
	quit(code)

func _main() -> int:
	http_port = int(OS.get_environment("SESSION_TEST_HTTP"))
	lobby_port = int(OS.get_environment("SESSION_TEST_LOBBY"))
	login_port = int(OS.get_environment("SESSION_TEST_LOGIN"))
	if http_port <= 0 or lobby_port <= 0 or login_port <= 0:
		setup_fail("session test ports were not set")
		return 2
	ProjectSettings.set_setting("blazium/game/game_uid", GAME_UID)
	jwt_a = _jwt("player-a")
	jwt_b = _jwt("player-b")
	if BlaziumIce.user_from_jwt(jwt_a) != "player-a" or BlaziumIce.user_from_jwt(jwt_b) != "player-b":
		setup_fail("placeholder login could not be read back")
		return 2
	var probe := LocalGames.new()
	root.add_child(probe)
	probe.jwt = jwt_a
	var left := probe.session_expiry() - int(Time.get_unix_time_from_system())
	if left <= probe.refresh_margin:
		setup_fail("placeholder login is inside the refresh window")
		probe.queue_free()
		return 2
	probe.queue_free()
	await frames(1)
	http = HTTPRequest.new()
	root.add_child(http)
	if not await _voice_dispatch_is_local():
		return 2
	var styles := ["seated", "handshake", "inflight"]
	var entries := ["create", "join"]
	var ops := ["logout", "start_login", "restore_session_from", "restore_session"]
	for entry in entries:
		for style in styles:
			for op in ops:
				await run_case(str(entry), str(style), str(op))
	if security_failures > 0:
		return 1
	if setup_failures > 0:
		return 2
	return 0

func run_case(entry: String, style: String, op: String) -> void:
	var name := "%s / %s / %s" % [op, entry, style]
	print("CASE ", name)
	await rpc(HTTPClient.METHOD_POST, "/test/reset", "{}")
	var games := LocalGames.new()
	games.local_api = "http://127.0.0.1:%d/api/v1" % http_port
	games.local_login = "ws://127.0.0.1:%d/" % login_port
	games.login_timeout = 0.0
	var lobby := LocalLobby.new()
	lobby.local_api = games.local_api
	lobby.local_lobby = "ws://127.0.0.1:%d/" % lobby_port
	var ice := LocalIce.new()
	root.add_child(games)
	root.add_child(lobby)
	root.add_child(ice)
	games.game_uid = GAME_UID
	games.jwt = jwt_a
	games.persist_session = false
	games._forget_saved_session()
	if not _local_targets(games, lobby):
		setup_fail(name + " refused to use a local stand-in")
		await _cleanup(games, lobby, ice)
		return
	_store_relays(ice)
	if ice.ice_servers.is_empty() or ice._http != null:
		setup_fail(name + " relay list was not stored locally")
		await _cleanup(games, lobby, ice)
		return
	await rpc(HTTPClient.METHOD_POST, "/test/config", JSON.stringify({
		"hold_admit": style == "inflight",
		"hold_logout": op == "logout",
		"hold_handshake": style == "handshake",
	}))
	var peers: Array = []
	lobby.peer_joined.connect(func(id: String) -> void: peers.append(id))
	var seated := {"ok": false}
	var failed := {"msg": ""}
	lobby.seated.connect(func(_peers: Array) -> void: seated["ok"] = true)
	lobby.lobby_failed.connect(func(message: String) -> void: failed["msg"] = message)
	if entry == "create":
		lobby.create_lobby(jwt_a, "private")
	else:
		lobby.join_lobby(jwt_a, "lobby-placeholder")
	var ready := false
	if style == "seated":
		ready = await _wait_seated(name, lobby, seated, failed, peers)
	elif style == "handshake":
		ready = await _wait_handshake(name, lobby, failed)
	else:
		ready = await _wait_inflight(name, lobby, failed)
	if not ready or ice._http != null:
		if ice._http != null:
			setup_fail(name + " relay fetch left the local stand-in during setup")
		await _cleanup(games, lobby, ice)
		return
	_arm_deferred(ice)
	if str(ice._deferred_jwt) == "" or ice.fetch_calls != 0 or ice._http != null or ice.ice_servers.is_empty():
		setup_fail(name + " voice login was not deferred locally")
		await _cleanup(games, lobby, ice)
		return
	if op == "restore_session":
		if not _write_saved_login(games):
			setup_fail(name + " saved login could not be written")
			await _cleanup(games, lobby, ice)
			return
		games.jwt = jwt_a
	var before := await status()
	if before.has("_error"):
		setup_fail(name + " status request failed")
		await _cleanup(games, lobby, ice)
		return
	var runner: BackgroundLogout = null
	if op == "logout":
		runner = BackgroundLogout.new()
		runner.target = games
		root.add_child(runner)
		var held := false
		for _i in 90:
			var st := await status()
			if int(st.get("logout_started", 0)) >= 1 and int(st.get("logout_finished", 0)) == 0:
				held = true
				break
			await process_frame
		if not held:
			setup_fail(name + " logout did not wait on the session service")
	elif op == "start_login":
		games.start_login()
	elif op == "restore_session_from":
		await games.restore_session_from(jwt_b)
	else:
		await games.restore_session()
	if op == "logout" or op == "start_login":
		if games.jwt != "":
			setup_fail(name + " the login token was still stored after the session call")
	elif BlaziumIce.user_from_jwt(games.jwt) != "player-b":
		setup_fail(name + " the other account was not restored")
	await frames(8)
	await _expect_isolated(name, "as the session call starts", lobby, ice, peers, style != "inflight")
	if op == "start_login" and games._socket != null:
		games._on_message({
			"action": "login_url",
			"user_code": "device-code-placeholder",
			"verification_url": "https://example.invalid/device",
		})
		games._on_message({"action": "jwt", "jwt": jwt_b, "uid": "player-b"})
		await frames(8)
		await _expect_isolated(name, "after device-code sign-in completes", lobby, ice, peers, true)
	await rpc(HTTPClient.METHOD_POST, "/test/release", "{}")
	if runner != null:
		for _i in 180:
			if runner.done:
				break
			await process_frame
		if not runner.done:
			setup_fail(name + " logout did not finish")
		runner.queue_free()
	await frames(45)
	await _expect_isolated(name, "after the admit or logout reply", lobby, ice, peers, true)
	var after := await status()
	_security(int(after.get("auth_count", 0)) == int(before.get("auth_count", 0)), name + " did not authenticate with the previous admit ticket")
	_security(int(after.get("auth_placeholder", 0)) == int(before.get("auth_placeholder", 0)), name + " did not present the previous admit ticket")
	_security(int(after.get("create_count", 0)) == int(before.get("create_count", 0)), name + " did not create a lobby for the previous account")
	_security(int(after.get("join_count", 0)) == int(before.get("join_count", 0)), name + " did not join a lobby for the previous account")
	if ice._http != null:
		setup_fail(name + " relay fetch left the local stand-in")
	await _cleanup(games, lobby, ice)

func _expect_isolated(name: String, when: String, lobby: LocalLobby, ice: LocalIce, peers: Array, require_lobby: bool) -> void:
	_security(ice.ice_servers.is_empty(), "%s %s clears the relay list" % [name, when])
	_security(str(ice._deferred_jwt) == "", "%s %s drops the deferred voice login" % [name, when])
	if str(ice._deferred_jwt) != "":
		var calls := ice.fetch_calls
		ice.hold_ice(false)
		_security(ice.fetch_calls == calls, "%s %s does not fetch relays with the previous login" % [name, when])
	if require_lobby:
		_security(str(lobby._ticket) == "", "%s %s drops the admit ticket" % [name, when])
		_security(str(lobby._jwt) == "", "%s %s drops the lobby login" % [name, when])
		_security(lobby._socket == null and not lobby._authed, "%s %s closes the lobby socket" % [name, when])
		peer_seq += 1
		var peer_id := "seen-after-%d" % peer_seq
		await rpc(HTTPClient.METHOD_POST, "/test/peer", JSON.stringify({"peer_id": peer_id}))
		await frames(20)
		_security(not peers.has(peer_id), "%s %s does not deliver a peer event" % [name, when])
		var open := lobby._socket != null and lobby._socket.get_ready_state() == WebSocketPeer.STATE_OPEN
		if lobby._socket == null or open:
			var prior := await status()
			var actions := int(prior.get("action_count", 0))
			lobby._send("lobby_action", {"text": "placeholder"})
			await frames(15)
			var now := await status()
			_security(int(now.get("action_count", 0)) == actions, "%s %s does not send a lobby action" % [name, when])

func _wait_seated(name: String, lobby: LocalLobby, seated: Dictionary, failed: Dictionary, peers: Array) -> bool:
	for _i in 240:
		if bool(seated["ok"]):
			break
		await process_frame
	if not bool(seated["ok"]):
		var st := await status()
		setup_fail("%s did not seat (%s) %s" % [name, str(failed["msg"]), _brief(st)])
		return false
	if str(lobby._ticket) == "" or lobby._socket == null or not lobby._authed:
		setup_fail(name + " seated without a live admit")
		return false
	await rpc(HTTPClient.METHOD_POST, "/test/peer", JSON.stringify({"peer_id": "seen-before"}))
	for _i in 60:
		if peers.has("seen-before"):
			return true
		await process_frame
	setup_fail(name + " seated lobby did not deliver a peer event")
	return false

func _wait_handshake(name: String, lobby: LocalLobby, failed: Dictionary) -> bool:
	for _i in 240:
		var st := await status()
		if str(lobby._ticket) != "" and lobby._socket != null and not lobby._authed and int(st.get("handshake_waiting", 0)) >= 1:
			return true
		await process_frame
	var st_end := await status()
	setup_fail("%s did not hold the lobby handshake (%s) %s" % [name, str(failed["msg"]), _brief(st_end)])
	return false

func _wait_inflight(name: String, lobby: LocalLobby, failed: Dictionary) -> bool:
	for _i in 240:
		var st := await status()
		if int(st.get("admit_started", 0)) >= 1 and int(st.get("admit_finished", 0)) == 0 and str(lobby._ticket) == "" and lobby._socket == null:
			return true
		await process_frame
	var st_end := await status()
	setup_fail("%s did not hold the admit (%s) %s" % [name, str(failed["msg"]), _brief(st_end)])
	return false

func _store_relays(ice: LocalIce) -> void:
	var body := JSON.stringify({
		"ice_servers": [{
			"urls": ["turn:127.0.0.1:9"],
			"username": "relay-user-placeholder",
			"credential": "relay-credential-placeholder",
		}],
	})
	ice._on_ice(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), body.to_utf8_buffer())

func _arm_deferred(ice: LocalIce) -> void:
	ice.fetch_calls = 0
	ice.hold_ice(true)
	ice.fetch_ice(jwt_a, "")

func _write_saved_login(games: LocalGames) -> bool:
	games.persist_session = true
	games.jwt = jwt_b
	games._save_session()
	return BlaziumIce.user_from_jwt(games._load_session()) == "player-b"

func _voice_dispatch_is_local() -> bool:
	var ice := LocalIce.new()
	root.add_child(ice)
	ice.hold_ice(true)
	ice.fetch_ice(jwt_a, "")
	var held: bool = str(ice._deferred_jwt) != "" and ice._http == null and ice.fetch_calls == 0
	ice.hold_ice(false)
	var local: bool = held and ice.fetch_calls == 1 and ice._http == null and str(ice._deferred_jwt) == ""
	ice.queue_free()
	await frames(1)
	if not local:
		setup_fail("voice double did not keep the relay fetch on this machine")
		return false
	return true

func _local_targets(games: LocalGames, lobby: LocalLobby) -> bool:
	return games._api().begins_with("http://127.0.0.1:") \
		and games._login_url().begins_with("ws://127.0.0.1:") \
		and lobby._api().begins_with("http://127.0.0.1:") \
		and lobby._lobby_url().begins_with("ws://127.0.0.1:")

func _cleanup(games: LocalGames, lobby: LocalLobby, ice: LocalIce, runner: BackgroundLogout = null) -> void:
	await rpc(HTTPClient.METHOD_POST, "/test/release", "{}")
	await frames(2)
	if is_instance_valid(games):
		games._forget_saved_session()
		games.queue_free()
	if is_instance_valid(lobby):
		lobby.queue_free()
	if is_instance_valid(ice):
		ice.queue_free()
	await frames(2)

func _jwt(user: String) -> String:
	var exp := int(Time.get_unix_time_from_system()) + 10 * 24 * 3600
	var header := _b64url('{"alg":"none","typ":"JWT"}')
	var payload := _b64url(JSON.stringify({"exp": exp, "user_uid": user}))
	return header + "." + payload + ".placeholder"

func _b64url(text: String) -> String:
	var encoded := Marshalls.raw_to_base64(text.to_utf8_buffer())
	return encoded.replace("+", "-").replace("/", "_").replace("=", "")

func rpc(method: int, path: String, body := "") -> Dictionary:
	var err := http.request("http://127.0.0.1:%d%s" % [http_port, path], PackedStringArray(["Content-Type: application/json"]), method, body)
	if err != OK:
		return {"_error": err}
	var result: Array = await http.request_completed
	if result.size() < 4 or int(result[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"_error": int(result[0]) if result.size() > 0 else -1}
	var parsed = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"_error": "not-json"}
	return parsed

func status() -> Dictionary:
	return await rpc(HTTPClient.METHOD_GET, "/test/status")

func frames(count: int) -> void:
	for _i in count:
		await process_frame

func _brief(st: Dictionary) -> String:
	return "admit=%s/%s handshake=%s auth=%s ops=%s unexpected=%s" % [
		str(st.get("admit_started", "?")),
		str(st.get("admit_finished", "?")),
		str(st.get("handshake_waiting", "?")),
		str(st.get("auth_count", "?")),
		str(st.get("ops", [])),
		str(st.get("unexpected", [])),
	]

func setup_fail(message: String) -> void:
	setup_failures += 1
	print("SETUP ", message)

func _security(ok: bool, message: String) -> void:
	if ok:
		return
	security_failures += 1
	print("FAIL ", message)
