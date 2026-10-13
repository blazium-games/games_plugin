class_name BlaziumGames
extends Node

## Auth channel only. The socket closes after the JWT arrives.
## Lobby and ICE use that token on their own connections.

signal login_url_received(url: String)
signal logged_in(jwt: String)
signal login_failed(message: String)
signal steam_signed_in(steam_id: String, token: String)
signal steam_sign_in_failed(message: String)
signal bug_reported(bug_uid: String)
signal bug_report_failed(message: String)

const LOGIN_URL := "wss://login.blazium.online/api/v1/connect"
const API := "https://api.blazium.online/api/v1"

var jwt: String = ""
var user_id: String = ""
var game_uid: String = ""
var steam_token: String = ""
var steam_id: String = ""

var _socket: WebSocketPeer
var _sent_getid := false
var _play_accum := 0.0
var _reporting := true

func _ready() -> void:
	add_to_group("blazium_games")
	game_uid = str(ProjectSettings.get_setting("blazium/game/game_uid", ""))

func start_login() -> void:
	if not _valid_uid(game_uid):
		login_failed.emit("blazium/game/game_uid must be the project UUID")
		return
	jwt = ""
	user_id = ""
	_reporting = true
	_play_accum = 0.0
	_sent_getid = false
	_socket = WebSocketPeer.new()
	_socket.supported_protocols = PackedStringArray(["blazium", game_uid])
	var err := _socket.connect_to_url(LOGIN_URL)
	if err != OK:
		login_failed.emit("WebSocket connect failed")
		_socket = null

func _process(delta: float) -> void:
	_tick_playtime(delta)
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
		_reporting = true
		_play_accum = 0.0
		user_id = str(message.get("uid", message.get("user_id", "")))
		_socket.close()
		_socket = null
		logged_in.emit(jwt)
	elif action == "error":
		login_failed.emit(str(message.get("message", "Login failed")))

func _tick_playtime(delta: float) -> void:
	if jwt == "" or not _reporting or not _valid_uid(game_uid):
		return
	_play_accum += delta
	if _play_accum < 60.0:
		return
	var seconds := int(_play_accum)
	if seconds > 300:
		seconds = 300
	_play_accum = 0.0
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		var parsed = JSON.parse_string(raw.get_string_from_utf8())
		var body = parsed
		if typeof(parsed) == TYPE_DICTIONARY and typeof(parsed.get("data", null)) == TYPE_DICTIONARY:
			body = parsed["data"]
		if code == 401 or (typeof(body) == TYPE_DICTIONARY and str(body.get("logged_on", "")) == "false"):
			_reporting = false
		http.queue_free()
	)
	http.request(API + "/private/library/" + game_uid.uri_encode() + "/playtime", ["Authorization: Bearer " + jwt, "Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify({"seconds": seconds}))

## ticket is the hex string from Steamworks GetAuthTicketForWebApi. The identity
## must be the ticket secret configured on the listing. This does not link Steamworks.
func sign_in_with_steam_ticket(ticket: String) -> void:
	if not _valid_uid(game_uid):
		steam_sign_in_failed.emit("blazium/game/game_uid must be the project UUID")
		return
	var hex := ticket.strip_edges()
	if hex == "":
		steam_sign_in_failed.emit("ticket is empty")
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		var body := _data(raw)
		if code < 200 or code >= 300 or typeof(body) != TYPE_DICTIONARY:
			steam_sign_in_failed.emit(_error_text(body, "Steam sign-in failed"))
		else:
			steam_token = str(body.get("token", ""))
			steam_id = str(body.get("steam_id", ""))
			if steam_token == "":
				steam_sign_in_failed.emit("Steam sign-in had no token")
			else:
				steam_signed_in.emit(steam_id, steam_token)
		http.queue_free()
	)
	http.request(API + "/steam/" + game_uid.uri_encode() + "/auth", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify({"ticket": hex}))

## Files an in-game bug. Uses the Steam session when one is stored, otherwise the Blazium login.
func report_bug(message: String, client_version: String = "", os_name: String = "", arch: String = "", log_text: String = "", screenshot_path: String = "") -> void:
	var token := steam_token if steam_token != "" else jwt
	if token == "" or not _valid_uid(game_uid):
		bug_report_failed.emit("Sign in before reporting a bug")
		return
	var boundary := "blazium-%s" % str(Time.get_unix_time_from_system())
	var body := PackedByteArray()
	_part(body, boundary, "message", message)
	if client_version != "":
		_part(body, boundary, "client_version", client_version)
	if os_name != "":
		_part(body, boundary, "os", os_name)
	if arch != "":
		_part(body, boundary, "arch", arch)
	if log_text != "":
		_part(body, boundary, "log", log_text)
	if screenshot_path != "" and FileAccess.file_exists(screenshot_path):
		var file := FileAccess.get_file_as_bytes(screenshot_path)
		var name := screenshot_path.get_file()
		body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"screenshot\"; filename=\"%s\"\r\nContent-Type: application/octet-stream\r\n\r\n" % [boundary, name]).to_utf8_buffer())
		body.append_array(file)
		body.append_array("\r\n".to_utf8_buffer())
	body.append_array(("--%s--\r\n" % boundary).to_utf8_buffer())
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		var parsed := _data(raw)
		if code < 200 or code >= 300 or typeof(parsed) != TYPE_DICTIONARY:
			bug_report_failed.emit(_error_text(parsed, "Bug report failed"))
		else:
			bug_reported.emit(str(parsed.get("bug_uid", "")))
		http.queue_free()
	)
	http.request(API + "/games/" + game_uid.uri_encode() + "/bugs", ["Authorization: Bearer " + token, "Content-Type: multipart/form-data; boundary=" + boundary], HTTPClient.METHOD_POST, body)

func _part(body: PackedByteArray, boundary: String, name: String, value: String) -> void:
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % [boundary, name, value]).to_utf8_buffer())

func _data(raw: PackedByteArray) -> Variant:
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY and typeof(parsed.get("data", null)) == TYPE_DICTIONARY:
		return parsed["data"]
	return parsed

func _error_text(body: Variant, fallback: String) -> String:
	if typeof(body) == TYPE_DICTIONARY:
		var err = body.get("error", body.get("message", ""))
		if typeof(err) == TYPE_DICTIONARY:
			return str(err.get("message", fallback))
		if str(err) != "":
			return str(err)
	return fallback

func _valid_uid(uid: String) -> bool:
	var re := RegEx.new()
	re.compile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
	return re.search(uid) != null
