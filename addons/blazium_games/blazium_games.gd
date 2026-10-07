class_name BlaziumGames
extends Node

## Auth channel only. The socket closes after the JWT arrives.
## Lobby and ICE use that token on their own connections.

signal login_url_received(url: String)
signal logged_in(jwt: String)
signal login_failed(message: String)

const LOGIN_URL := "wss://login.blazium.online/api/v1/connect"

var jwt: String = ""
var user_id: String = ""
var game_uid: String = ""

var _socket: WebSocketPeer
var _sent_getid := false

func _ready() -> void:
	add_to_group("blazium_games")
	game_uid = str(ProjectSettings.get_setting("blazium/game/game_uid", ""))

func start_login() -> void:
	if not _valid_uid(game_uid):
		login_failed.emit("blazium/game/game_uid must be the project UUID")
		return
	jwt = ""
	user_id = ""
	_sent_getid = false
	_socket = WebSocketPeer.new()
	_socket.supported_protocols = PackedStringArray(["blazium", game_uid])
	var err := _socket.connect_to_url(LOGIN_URL)
	if err != OK:
		login_failed.emit("WebSocket connect failed")
		_socket = null

func _process(_delta: float) -> void:
	if _socket == null:
		return
	_socket.poll()
	var state := _socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN and not _sent_getid:
		_socket.send_text('{"action":"getid"}')
		_sent_getid = true
	if state == WebSocketPeer.STATE_CLOSED and jwt == "":
		login_failed.emit("Connection closed")
		_socket = null
		return
	while _socket != null and _socket.get_available_packet_count() > 0:
		var text := _socket.get_packet().get_string_from_utf8()
		var parsed = JSON.parse_string(text)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		_on_message(parsed)

func _on_message(message: Dictionary) -> void:
	var action := str(message.get("action", ""))
	if action == "conn_id" or action == "id":
		_socket.send_text('{"action":"getlogin"}')
	elif action == "login_url" or action == "getlogin":
		var url := str(message.get("login_url", message.get("url", "")))
		if url != "":
			login_url_received.emit(url)
	elif action == "jwt" or action == "login_success":
		var token := str(message.get("jwt", message.get("token", "")))
		if token == "":
			login_failed.emit("Login response had no token")
			return
		jwt = token
		user_id = str(message.get("uid", message.get("user_id", "")))
		_socket.close()
		_socket = null
		logged_in.emit(jwt)
	elif action == "error":
		login_failed.emit(str(message.get("message", "Login failed")))

func _valid_uid(uid: String) -> bool:
	var re := RegEx.new()
	re.compile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
	return re.search(uid) != null
