class_name BlaziumLobby
extends Node

## Scripted lobby socket. Uses the JWT from BlaziumGames. Never downloads the pack.

signal lobby_created(lobby_id: String)
signal lobby_loading
signal seated(peers: Array)
signal lobby_failed(message: String)

const LOBBY_URL := "wss://slobby.blazium.online/"

var _socket: WebSocketPeer
var _jwt := ""
var _next_id := 1
var _authed := false
var _pending_join := ""

func create_lobby(jwt: String, lobby_type: String) -> void:
	_connect(jwt)
	_pending_join = ""
	_queue_after_auth("create_lobby", {"lobby_type": lobby_type})

func join_lobby(jwt: String, lobby_id: String) -> void:
	_connect(jwt)
	_pending_join = lobby_id
	_queue_after_auth("join_lobby", {"lobby_id": lobby_id})

var _queued_op := ""
var _queued_payload := {}

func _queue_after_auth(op: String, payload: Dictionary) -> void:
	_queued_op = op
	_queued_payload = payload

func _connect(jwt: String) -> void:
	_jwt = jwt
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
		_send("auth", {"token": _jwt, "user_id": _user_from_jwt(_jwt)})
		_authed = true
	while _socket != null and _socket.get_available_packet_count() > 0:
		var parsed = JSON.parse_string(_socket.get_packet().get_string_from_utf8())
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		_on_message(parsed)

func _on_message(message: Dictionary) -> void:
	var op := str(message.get("op", ""))
	var payload: Dictionary = message.get("payload", {})
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

func _user_from_jwt(token: String) -> String:
	var parts := token.split(".")
	if parts.size() < 2:
		return ""
	var body := Marshalls.base64_to_utf8(parts[1])
	var parsed = JSON.parse_string(body)
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	return str(parsed.get("uid", parsed.get("user_id", "")))
