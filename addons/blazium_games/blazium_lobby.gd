class_name BlaziumLobby
extends Node

## Scripted lobby socket. Uses the JWT from BlaziumGames. Never downloads the pack.

signal lobby_created(lobby_id: String)
signal lobby_joined(lobby_id: String)
signal lobby_loading
signal seated(peers: Array)
signal peer_joined(peer_id: String)
signal peer_left(peer_id: String)
signal lobby_failed(message: String)

const LOBBY_URL := "wss://lobby.blazium.online/"
const API := "https://api.blazium.online/api/v1"

func _discord_application_id() -> String:
	if OS.get_name() != "Web":
		return ""
	var bridge = Engine.get_singleton("JavaScriptBridge")
	if bridge == null:
		return ""
	var embedded = bridge.eval("typeof window !== 'undefined' && !!window.DiscordEmbed && window.DiscordEmbed.isDiscordEmbed()", true)
	if embedded != true:
		return ""
	var host := str(bridge.eval("window.location.hostname", true))
	if not host.ends_with(".discordsays.com"):
		return ""
	var id := host.split(".")[0]
	if id.length() < 17 or id.length() > 20:
		return ""
	for i in id.length():
		var c := id.unicode_at(i)
		if c < 48 or c > 57:
			return ""
	var host_id := id
	var configured := str(ProjectSettings.get_setting("blazium/discord/application_id", "")).strip_edges()
	if configured == "" or host_id != configured:
		return ""
	return host_id

func _api() -> String:
	var id := _discord_application_id()
	if id != "":
		return "https://%s.discordsays.com/.proxy/blazium/api/api/v1" % id
	return API

func _lobby_url() -> String:
	var id := _discord_application_id()
	if id != "":
		return "wss://%s.discordsays.com/.proxy/blazium/lobby/" % id
	return LOBBY_URL

var _socket: WebSocketPeer
var _jwt := ""
var _ticket := ""
var _next_id := 1
var _authed := false
var _pending_join := ""
var _game_uid := ""
var _inflight_id := ""
var _inflight_op := ""
var _announced_join := ""

func create_lobby(jwt: String, lobby_type: String, options: Dictionary = {}) -> void:
	var game_uid := str(ProjectSettings.get_setting("blazium/game/game_uid", ""))
	if not _valid_uid(game_uid):
		lobby_failed.emit("blazium/game/game_uid must be the project UUID")
		return
	_pending_join = ""
	var payload := {"lobby_type": lobby_type, "game_uid": game_uid}
	if options.has("name"):
		payload["name"] = options["name"]
	if options.has("max_players"):
		payload["max_players"] = options["max_players"]
	if options.has("password"):
		payload["password"] = options["password"]
	if options.has("tags"):
		payload["tags"] = options["tags"]
	_queue_after_auth("create_lobby", payload)
	_ask_service(jwt, "/private/lobbies", {"game_uid": game_uid, "lobby_type": lobby_type})

func join_lobby(jwt: String, lobby_id: String, options: Dictionary = {}) -> void:
	var game_uid := str(ProjectSettings.get_setting("blazium/game/game_uid", ""))
	if not _valid_uid(game_uid):
		lobby_failed.emit("blazium/game/game_uid must be the project UUID")
		return
	_pending_join = lobby_id
	var payload := {"lobby_id": lobby_id, "game_uid": game_uid}
	if options.has("password"):
		payload["password"] = options["password"]
	if options.has("name"):
		payload["name"] = options["name"]
	if options.has("max_players"):
		payload["max_players"] = options["max_players"]
	_queue_after_auth("join_lobby", payload)
	_ask_service(jwt, "/private/lobbies/" + game_uid.uri_encode() + "/join", {"game_uid": game_uid, "lobby_id": lobby_id})

var _queued_op := ""
var _queued_payload := {}

func _queue_after_auth(op: String, payload: Dictionary) -> void:
	_queued_op = op
	_queued_payload = payload

func _connect(jwt: String) -> void:
	var game_uid := str(ProjectSettings.get_setting("blazium/game/game_uid", ""))
	if not _valid_uid(game_uid):
		lobby_failed.emit("blazium/game/game_uid must be the project UUID")
		return
	_jwt = jwt
	_game_uid = game_uid
	_authed = false
	if _socket != null:
		_socket.close()
		_socket = null
	_socket = WebSocketPeer.new()
	var err := _socket.connect_to_url(_lobby_url())
	if err != OK:
		lobby_failed.emit("Lobby connect failed")
		_socket = null

func _process(_delta: float) -> void:
	if _socket == null:
		return
	_socket.poll()
	if _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_socket = null
		_authed = false
		_inflight_id = ""
		_inflight_op = ""
		lobby_failed.emit("Connection lost")
		return
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN and not _authed and _jwt != "":
		if _game_uid == "":
			lobby_failed.emit("blazium/game/game_uid must be the project UUID")
			return
		_send("auth", {"ticket": _ticket, "user_id": BlaziumIce.player_id(_jwt, get_tree()), "game_uid": _game_uid})
		_authed = true
	while _socket != null and _socket.get_available_packet_count() > 0:
		var parsed = JSON.parse_string(_socket.get_packet().get_string_from_utf8())
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		_on_message(parsed)

func _ask_service(jwt: String, path: String, body: Dictionary) -> void:
	_hold_ice(true)
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		var parsed = JSON.parse_string(raw.get_string_from_utf8())
		if result != HTTPRequest.RESULT_SUCCESS or (code != 200 and code != 202):
			_queued_op = ""
			_queued_payload = {}
			_cancel_ice_hold()
			lobby_failed.emit(_lobby_error(parsed, code))
			http.queue_free()
			return
		var data = parsed
		if typeof(parsed) == TYPE_DICTIONARY and typeof(parsed.get("data", null)) == TYPE_DICTIONARY:
			data = parsed["data"]
		var ticket := ""
		if typeof(data) == TYPE_DICTIONARY:
			ticket = str(data.get("ticket", ""))
			_note_ice(data)
		if ticket == "":
			_queued_op = ""
			_queued_payload = {}
			_cancel_ice_hold()
			lobby_failed.emit("Lobby admit did not return a ticket")
			http.queue_free()
			return
		_ticket = ticket
		_hold_ice(false)
		_connect(jwt)
		http.queue_free()
	)
	var err := http.request(_api() + path, ["Authorization: Bearer " + jwt, "Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_queued_op = ""
		_queued_payload = {}
		_cancel_ice_hold()
		lobby_failed.emit("Lobby request failed")
		http.queue_free()

func _lobby_error(parsed, code: int) -> String:
	if typeof(parsed) == TYPE_DICTIONARY:
		var err = parsed.get("error", {})
		if typeof(err) == TYPE_DICTIONARY and str(err.get("message", "")) != "":
			return str(err.get("message", ""))
	if code == 0:
		return "Lobby request failed"
	return "Lobby request failed (%d)" % code

func _cancel_ice_hold() -> void:
	var tree := get_tree()
	if tree == null:
		return
	tree.call_group("blazium_ice", "cancel_ice_hold")

func _hold_ice(on: bool) -> void:
	var tree := get_tree()
	if tree == null:
		return
	tree.call_group("blazium_ice", "hold_ice", on)

func _note_ice(result: Dictionary) -> void:
	var tree := get_tree()
	if tree == null:
		return
	tree.call_group("blazium_ice", "note_lobby", result)

func _on_message(message: Dictionary) -> void:
	var op := str(message.get("op", ""))
	var raw_payload = message.get("payload", {})
	var payload: Dictionary = raw_payload if typeof(raw_payload) == TYPE_DICTIONARY else {}
	if op == "presence":
		var tree := get_tree()
		if tree != null:
			for node in tree.get_nodes_in_group("blazium_games"):
				node.apply_lobby_presence(str(payload.get("status", "")), str(payload.get("lobby_id", "")), int(payload.get("notice_exp", 0)), str(payload.get("notice_sig", "")))
		if payload.has("ice_enabled"):
			_note_ice(payload)
		return
	if payload.has("ice_enabled"):
		_note_ice(payload)
	if op == "lobby_loading" or str(payload.get("state", "")) == "lobby_loading":
		lobby_loading.emit()
		return
	if op == "peer_joined":
		peer_joined.emit(str(payload.get("peer_id", "")))
		return
	if op == "peer_left":
		peer_left.emit(str(payload.get("peer_id", "")))
		return
	if message.has("ok") and message.get("ok") == true:
		if _queued_op != "":
			var op_name := _queued_op
			var body: Dictionary = _queued_payload
			_queued_op = ""
			_send(op_name, body)
			return
		var reply_id := str(message.get("id", ""))
		if reply_id != "" and reply_id == _inflight_id and _inflight_op == "join_lobby":
			_inflight_id = ""
			_inflight_op = ""
			var joined_id := str(payload.get("lobby_id", _pending_join))
			_announced_join = joined_id
			lobby_joined.emit(joined_id)
			seated.emit(_peers(payload))
			return
		if reply_id != "" and reply_id == _inflight_id and _inflight_op == "create_lobby":
			_inflight_id = ""
			_inflight_op = ""
			if payload.has("lobby_id"):
				lobby_created.emit(str(payload["lobby_id"]))
			seated.emit(_peers(payload))
			return
		if payload.has("peers"):
			seated.emit(_peers(payload))
	elif op == "joined_lobby":
		var joined_id := str(payload.get("lobby_id", ""))
		if joined_id != _announced_join:
			_announced_join = joined_id
			lobby_joined.emit(joined_id)
		seated.emit(_peers(payload))
	elif op == "seated" or op == "lobby_created" or payload.has("peers"):
		if op == "lobby_created" and payload.has("lobby_id"):
			lobby_created.emit(str(payload["lobby_id"]))
		seated.emit(_peers(payload))
	elif message.has("ok") and message.get("ok") == false:
		var raw_err = message.get("err", {})
		var err: Dictionary = raw_err if typeof(raw_err) == TYPE_DICTIONARY else {}
		var reason := str(err.get("msg", err.get("message", "")))
		if reason == "":
			reason = "Lobby request failed"
		lobby_failed.emit(reason)

func leave_lobby() -> void:
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send("leave_lobby", {})
		_socket.close()
	_socket = null
	_authed = false
	_queued_op = ""
	_queued_payload = {}
	_inflight_id = ""
	_inflight_op = ""
	_announced_join = ""

func _peers(payload: Dictionary) -> Array:
	var peers = payload.get("peers", [])
	return peers if typeof(peers) == TYPE_ARRAY else []

func _send(op: String, payload: Dictionary) -> void:
	if _socket == null:
		return
	var request_id := str(_next_id)
	var envelope := {
		"v": 1,
		"id": request_id,
		"ts": Time.get_unix_time_from_system() * 1000,
		"layer": "data",
		"op": op,
		"lobby": "",
		"payload": payload,
	}
	_next_id += 1
	if op == "create_lobby" or op == "join_lobby":
		_inflight_id = request_id
		_inflight_op = op
	_socket.send_text(JSON.stringify(envelope))

func _valid_uid(uid: String) -> bool:
	var re := RegEx.new()
	re.compile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
	return re.search(uid) != null
