extends SceneTree

const GAME_UID := "11111111-2222-3333-4444-555555555555"
const TICKET := "placeholder-steam-ticket"
const LOGIN := "placeholder-login-session"

var _api_origin := ""
var _sapi_origin := ""
var _result_path := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var arg := str(args[i])
		if arg == "--api-origin" and i + 1 < args.size():
			i += 1
			_api_origin = str(args[i])
		elif arg == "--sapi-origin" and i + 1 < args.size():
			i += 1
			_sapi_origin = str(args[i])
		elif arg == "--result" and i + 1 < args.size():
			i += 1
			_result_path = str(args[i])
		i += 1
	_run()


func _run() -> void:
	var err := ""
	if _api_origin == "" or _sapi_origin == "" or _result_path == "":
		err = "missing --api-origin, --sapi-origin, or --result"
	else:
		await process_frame
		ProjectSettings.set_setting("blazium/game/game_uid", GAME_UID)
		err = await _phase("a", false)
		if err == "":
			err = await _phase("b", true)
	_finish(err)


func _phase(prefix: String, with_login: bool) -> String:
	var games: Node = load("res://local_games.gd").new()
	games.api_override = _api_origin
	var sapi: Node = load("res://local_sapi.gd").new()
	sapi.base_override = _sapi_origin
	sapi.timeout = 5.0
	get_root().add_child(games)
	get_root().add_child(sapi)
	await process_frame
	games.sign_in_with_steam_ticket(TICKET)
	var signed := await _await_steam(games)
	if signed != "":
		_drop(games, sapi)
		return signed
	if with_login:
		games.jwt = LOGIN
	var sent := await _signed_calls(sapi, prefix)
	if sent != "":
		_drop(games, sapi)
		return sent
	if not with_login:
		var lobby: Dictionary = await games.request_scoped_token("lobby")
		if not bool(lobby.get("ok", false)):
			_drop(games, sapi)
			return "lobby exchange failed"
		var server: Dictionary = await games.request_scoped_token("server")
		if not bool(server.get("ok", false)):
			_drop(games, sapi)
			return "server exchange failed"
	_drop(games, sapi)
	await process_frame
	return ""


func _signed_calls(sapi: Node, prefix: String) -> String:
	var methods: Array[String] = ["POST", "GET", "PUT", "PATCH", "DELETE"]
	for method in methods:
		var logic := prefix + "_" + method.to_lower()
		sapi.invoke(logic, {"score": 10}, {"method": method})
		var err := await _await_call(sapi, logic)
		if err != "":
			return err
	var alias := prefix + "_alias"
	sapi.call_logic(alias, {"score": 10}, {"method": "POST"})
	var alias_err := await _await_call(sapi, alias)
	if alias_err != "":
		return alias_err
	var retry := prefix + "_retry"
	sapi.invoke(retry, {"score": 10}, {"method": "POST"})
	var retry_err := await _await_call(sapi, retry)
	if retry_err != "":
		return retry_err
	var anon := prefix + "_anon"
	sapi.invoke(anon, {"score": 10}, {"anonymous": true, "method": "POST"})
	var anon_err := await _await_call(sapi, anon)
	if anon_err != "":
		return anon_err
	sapi.get_public_config()
	return await _await_call(sapi, "_config")


func _await_steam(games: Node) -> String:
	var state := {"done": false, "bad": false}
	var on_ok := func(_steam_id: String, _token: String) -> void:
		state["done"] = true
	var on_bad := func(_message: String) -> void:
		state["done"] = true
		state["bad"] = true
	games.steam_signed_in.connect(on_ok)
	games.steam_sign_in_failed.connect(on_bad)
	var frames := 0
	while not bool(state["done"]) and frames < 900:
		await process_frame
		frames += 1
	if games.steam_signed_in.is_connected(on_ok):
		games.steam_signed_in.disconnect(on_ok)
	if games.steam_sign_in_failed.is_connected(on_bad):
		games.steam_sign_in_failed.disconnect(on_bad)
	if not bool(state["done"]):
		return "timed out waiting for steam sign-in"
	if bool(state["bad"]):
		return "steam sign-in failed"
	return ""


func _await_call(sapi: Node, logic: String) -> String:
	var state := {"done": false, "bad": false}
	var on_ok := func(got: String, _status: int, _body: Variant, _request_id: String) -> void:
		if got == logic:
			state["done"] = true
	var on_bad := func(got: String, _status: int, _key: String, _message: String, _request_id: String) -> void:
		if got == logic:
			state["done"] = true
			state["bad"] = true
	sapi.call_completed.connect(on_ok)
	sapi.call_failed.connect(on_bad)
	var frames := 0
	while not bool(state["done"]) and frames < 900:
		await process_frame
		frames += 1
	if sapi.call_completed.is_connected(on_ok):
		sapi.call_completed.disconnect(on_ok)
	if sapi.call_failed.is_connected(on_bad):
		sapi.call_failed.disconnect(on_bad)
	if not bool(state["done"]):
		return "timed out waiting for " + logic
	if bool(state["bad"]):
		return "scripted call failed for " + logic
	return ""


func _drop(games: Node, sapi: Node) -> void:
	if is_instance_valid(games):
		games.free()
	if is_instance_valid(sapi):
		sapi.free()


func _finish(err: String) -> void:
	var plain_games: Node = load("res://addons/blazium_games/blazium_games.gd").new()
	var plain_sapi: Node = load("res://addons/blazium_games/blazium_sapi.gd").new()
	var payload := {
		"ok": err == "",
		"error": err,
		"api_host": str(plain_games._api()),
		"sapi_host": str(plain_sapi._base()),
	}
	plain_games.free()
	plain_sapi.free()
	var file := FileAccess.open(_result_path, FileAccess.WRITE)
	if file == null:
		push_error("could not write the result file")
		quit(1)
		return
	file.store_string(JSON.stringify(payload))
	file.close()
	quit(0 if err == "" else 1)
