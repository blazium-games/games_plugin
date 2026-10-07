class_name BlaziumLobby
extends Node

## Scripted lobby socket. Uses the JWT from BlaziumGames. Never downloads the pack.

signal lobby_created(lobby_id: String)
signal lobby_loading
signal seated(peers: Array)
signal lobby_failed(message: String)

const LOBBY_URL := "wss://lobby.blazium.online/"
const API := "https://api.blazium.online/api/v1"

var _socket: WebSocketPeer
var _jwt := ""
var _next_id := 1
var _authed := false
var _pending_join := ""
var _game_uid := ""

func create_lobby(jwt: String, lobby_type: String) -> void:
	var game_uid := str(ProjectSettings.get_setting("blazium/game/game_uid", ""))
	if not _valid_uid(game_uid):
		lobby_failed.emit("blazium/game/game_uid must be the project UUID")
		return
	_pending_join = ""
	_queue_after_auth("create_lobby", {"lobby_type": lobby_type, "game_uid": game_uid})
	_ask_service(jwt, "/private/lobbies", {"game_uid": game_uid, "lobby_type": lobby_type})

func join_lobby(jwt: String, lobby_id: String) -> void:
	var game_uid := str(ProjectSettings.get_setting("blazium/game/game_uid", ""))
	if not _valid_uid(game_uid):
		lobby_failed.emit("blazium/game/game_uid must be the project UUID")
		return
	_pending_join = lobby_id
	_queue_after_auth("join_lobby", {"lobby_id": lobby_id, "game_uid": game_uid})
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
	_socket = WebSocketPeer.new()
	var err := _socket.connect_to_url(LOBBY_URL)
	if err != OK:
		lobby_failed.emit("Lobby connect failed")
		_socket = null

func _process(_delta: float) -> void:
	if _socket == null:
		return
	_socket.poll()
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN and not _authed and _jwt != "":
		if _game_uid == "":
			lobby_failed.emit("blazium/game/game_uid must be the project UUID")
			return
		_send("auth", {"token": _jwt, "user_id": BlaziumIce.player_id(_jwt, get_tree()), "game_uid": _game_uid})
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
		if typeof(parsed) == TYPE_DICTIONARY:
			_note_ice(parsed)
		_hold_ice(false)
		_connect(jwt)
		http.queue_free()
	)
	var err := http.request(API + path, ["Authorization: Bearer " + jwt, "Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))
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
	var payload: Dictionary = message.get("payload", {})
	if payload.has("ice_enabled"):
		_note_ice(payload)
	if op == "lobby_loading" or str(payload.get("state", "")) == "lobby_loading":
		lobby_loading.emit()
		return
	if message.has("ok") and message.get("ok") == true:
		if _queued_op != "":
			var op_name := _queued_op
			var body: Dictionary = _queued_payload
			_queued_op = ""
			_send(op_name, body)
			return
		if payload.has("lobby_id"):
			lobby_created.emit(str(payload["lobby_id"]))
		if payload.has("peers"):
			seated.emit(payload["peers"])
	elif op == "seated" or payload.has("peers"):
		seated.emit(payload.get("peers", []))
	elif message.has("ok") and message.get("ok") == false:
		var err: Dictionary = message.get("err", {})
		lobby_failed.emit(str(err.get("message", "Lobby request failed")))

func _send(op: String, payload: Dictionary) -> void:
	if _socket == null:
		return
	var envelope := {
		"v": 1,
		"id": str(_next_id),
		"ts": Time.get_unix_time_from_system() * 1000,
		"layer": "data",
		"op": op,
		"lobby": "",
		"payload": payload,
	}
	_next_id += 1
	_socket.send_text(JSON.stringify(envelope))

func _valid_uid(uid: String) -> bool:
	var re := RegEx.new()
	re.compile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
	return re.search(uid) != null
