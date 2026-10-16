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
signal ownership_ready(body: Dictionary)
signal ownership_failed(message: String)
signal progress_recorded(body: Dictionary)
signal progress_ready(body: Dictionary)
signal progress_failed(message: String)
signal patch_notices_ready(body: Dictionary)
signal patch_notices_failed(message: String)
signal item_completed(body: Dictionary)
signal item_failed(message: String)

const LOGIN_URL := "wss://login.blazium.online/api/v1/connect"
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
	return id

func _api() -> String:
	var id := _discord_application_id()
	if id != "":
		return "https://%s.discordsays.com/.proxy/blazium/api/api/v1" % id
	return API

func _login_url() -> String:
	var id := _discord_application_id()
	if id != "":
		return "wss://%s.discordsays.com/.proxy/blazium/login/api/v1/connect" % id
	return LOGIN_URL

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
	var err := _socket.connect_to_url(_login_url())
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
	http.request(_api() + "/private/library/" + game_uid.uri_encode() + "/playtime", ["Authorization: Bearer " + jwt, "Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify({"seconds": seconds}))

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
	http.request(_api() + "/steam/" + game_uid.uri_encode() + "/auth", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify({"ticket": hex}))

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
	http.request(_api() + "/games/" + game_uid.uri_encode() + "/bugs", ["Authorization: Bearer " + token, "Content-Type: multipart/form-data; boundary=" + boundary], HTTPClient.METHOD_POST, body)

## Answers whether this session owns an edition (sku slug or kind) and, optionally, a second listing used as DLC.
func ownership(edition: String = "", listing_uid: String = "") -> void:
	if jwt == "" or not _valid_uid(game_uid):
		ownership_failed.emit("Sign in before asking about ownership")
		return
	var query := ""
	if edition != "":
		query += "?edition=" + edition.uri_encode()
	if listing_uid != "":
		query += ("&" if query != "" else "?") + "listing=" + listing_uid.uri_encode()
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		var body := _data(raw)
		if code < 200 or code >= 300 or typeof(body) != TYPE_DICTIONARY:
			ownership_failed.emit(_error_text(body, "Ownership check failed"))
		else:
			ownership_ready.emit(body)
		http.queue_free()
	)
	http.request(_api() + "/private/games/" + game_uid.uri_encode() + "/ownership" + query, ["Authorization: Bearer " + jwt], HTTPClient.METHOD_GET)

## Reads this player's unlocked achievements and stat values.
func progress() -> void:
	if jwt == "" or not _valid_uid(game_uid):
		progress_failed.emit("Sign in before reading progress")
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		var body := _data(raw)
		if code < 200 or code >= 300 or typeof(body) != TYPE_DICTIONARY:
			progress_failed.emit(_error_text(body, "Progress read failed"))
		else:
			progress_ready.emit(body)
		http.queue_free()
	)
	http.request(_api() + "/private/player/progress?game_id=" + game_uid.uri_encode(), ["Authorization: Bearer " + jwt], HTTPClient.METHOD_GET)

## Sets this player's status when presence_writers includes client. A lobby signature is not sent.
func set_presence(status: String) -> void:
	if jwt == "" or not _valid_uid(game_uid):
		progress_failed.emit("Sign in before setting presence")
		return
	if status.length() > 40:
		progress_failed.emit("status is too long")
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		var body := _data(raw)
		http.queue_free()
		if code < 200 or code >= 300 or typeof(body) != TYPE_DICTIONARY:
			progress_failed.emit(_error_text(body, "Presence was refused"))
			return
		var writers: Array = body.get("presence_writers", [])
		if not writers.has("client"):
			progress_failed.emit("This game does not let the client set presence")
			return
		_progress({"game_id": game_uid, "kind": "presence", "status": status})
	)
	http.request(_api() + "/private/games/" + game_uid.uri_encode() + "/ownership", ["Authorization: Bearer " + jwt], HTTPClient.METHOD_GET)

## Reads the newest stable patch note this player has not acknowledged.
func patch_notices() -> void:
	_patch("GET", "")

## Acknowledges patch note uids returned by patch_notices.
func ack_patch_notices(uids: Array) -> void:
	_patch("POST", JSON.stringify({"uids": uids}))

func _patch(method: String, raw_body: String) -> void:
	var token := steam_token if steam_token != "" else jwt
	if token == "" or not _valid_uid(game_uid):
		patch_notices_failed.emit("Sign in before reading patch notes")
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		var body := _data(raw)
		if code < 200 or code >= 300 or typeof(body) != TYPE_DICTIONARY:
			patch_notices_failed.emit(_error_text(body, "Patch notes were refused"))
		else:
			patch_notices_ready.emit(body)
		http.queue_free()
	)
	var verb := HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST
	var path := "/patch/notices" if method == "GET" else "/patch/notices/ack"
	http.request(_api() + "/games/" + game_uid.uri_encode() + path, ["Authorization: Bearer " + token, "Content-Type: application/json"], verb, raw_body)

func transfer_item(item_ids: Array, direction: String, request_id: String, itemdef_id: int = 0, count: int = 0) -> void:
	_item("/private/items/transfer", {"game_id": game_uid, "item_ids": item_ids, "itemdef_id": itemdef_id, "count": count, "direction": direction, "request_id": request_id})

func socket_item(_parent_id: String, _child_id: String, _index: int, _request_id: String) -> void:
	item_failed.emit("Only the game owner, an accepted admin, or a mint key can socket items")

func unsocket_item(_child_id: String, _request_id: String) -> void:
	item_failed.emit("Only the game owner, an accepted admin, or a mint key can unsocket items")

func set_item_stats(_item_id: String, _stats: Dictionary, _request_id: String) -> void:
	item_failed.emit("Only the game owner, an accepted admin, or a mint key can set item stats")

func use_item(_item_id: String, _request_id: String) -> void:
	item_failed.emit("Only the game owner, an accepted admin, or a mint key can use items")

func _item(path: String, body: Dictionary) -> void:
	if jwt == "" or not _valid_uid(game_uid):
		item_failed.emit("Sign in before changing items")
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		var parsed := _data(raw)
		if code < 200 or code >= 300 or typeof(parsed) != TYPE_DICTIONARY:
			item_failed.emit(_error_text(parsed, "The item action was refused"))
		else:
			item_completed.emit(parsed)
		http.queue_free()
	)
	http.request(_api() + path, ["Authorization: Bearer " + jwt, "Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))

func unlock_achievement(slug: String) -> void:
	_progress({"game_id": game_uid, "kind": "achievement", "slug": slug})

func set_stat(slug: String, value: int) -> void:
	_progress({"game_id": game_uid, "kind": "stat", "slug": slug, "value": value})

func record_event(event_name: String) -> void:
	_progress({"game_id": game_uid, "kind": "event", "event": event_name})

## Sends session_start, session_end, boot_ok, first_input, quit, and crash on the public launch route.
func record_standard_events(build_id: String, device_uid: String = "plugin") -> void:
	if not _valid_uid(game_uid) or build_id == "":
		progress_failed.emit("A game uid and build id are required")
		return
	var events: Array = []
	for event_name in ["session_start", "session_end", "boot_ok", "first_input", "quit", "crash"]:
		var ev := {"event": event_name, "device_uid": device_uid}
		if event_name == "session_end":
			ev["seconds"] = 0
		if event_name == "boot_ok" or event_name == "first_input":
			ev["ms"] = 0
		events.append(ev)
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		if code < 200 or code >= 300:
			progress_failed.emit(_error_text(_data(raw), "Launch events were refused"))
		else:
			progress_recorded.emit({"standard": true, "count": 6})
		http.queue_free()
	)
	http.request(_api() + "/public/events", ["Content-Type: application/json", "X-App-Id: " + game_uid, "X-Build-Id: " + build_id], HTTPClient.METHOD_POST, JSON.stringify({"events": events}))

## Applies a scripted-lobby presence notification. Ignored unless presence_writers includes scripted_lobby.
## The lobby host signs the notice. A caller cannot claim the scripted_lobby writer without that signature.
func apply_lobby_presence(status: String, lobby_id: String, notice_exp: int = 0, notice_sig: String = "") -> void:
	if jwt == "" or not _valid_uid(game_uid) or notice_sig == "":
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		var body := _data(raw)
		http.queue_free()
		if code < 200 or code >= 300 or typeof(body) != TYPE_DICTIONARY:
			return
		var writers: Array = body.get("presence_writers", [])
		if not writers.has("scripted_lobby"):
			return
		_progress({
			"game_id": game_uid,
			"kind": "presence",
			"status": status,
			"lobby_id": lobby_id,
			"notice_exp": notice_exp,
			"notice_sig": notice_sig,
		})
	)
	http.request(_api() + "/private/games/" + game_uid.uri_encode() + "/ownership", ["Authorization: Bearer " + jwt], HTTPClient.METHOD_GET)

func server_unlock_achievement(server_key: String, user_uid: String, slug: String) -> void:
	_server_progress(server_key, {"user_uid": user_uid, "kind": "achievement", "slug": slug, "event": ""})

func server_set_stat(server_key: String, user_uid: String, slug: String, value: int) -> void:
	_server_progress(server_key, {"user_uid": user_uid, "kind": "stat", "slug": slug, "event": "", "value": value})

func server_record_event(server_key: String, user_uid: String, event_name: String) -> void:
	_server_progress(server_key, {"user_uid": user_uid, "kind": "event", "slug": "", "event": event_name})

## Reads one owner's unlocks and stats with a game or private server key.
func server_progress(server_key: String, user_uid: String) -> Dictionary:
	if server_key == "" or not _valid_uid(user_uid):
		return {"ok": false, "error": "A server key and player uid are required"}
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(_api() + "/server/progress?user_uid=" + user_uid.uri_encode(), ["Authorization: Bearer " + server_key], HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "Progress read failed"}
	var result: Array = await http.request_completed
	http.queue_free()
	if result.size() < 4:
		return {"ok": false, "error": "Progress read failed"}
	var code: int = result[1]
	var parsed = _data(result[3])
	if code < 200 or code >= 300 or typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": _error_text(parsed, "Progress read failed")}
	return parsed

func _server_progress(server_key: String, body: Dictionary) -> void:
	if server_key == "" or not _valid_uid(str(body.get("user_uid", ""))):
		progress_failed.emit("A server key and player uid are required")
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		var parsed := _data(raw)
		if code < 200 or code >= 300 or typeof(parsed) != TYPE_DICTIONARY:
			progress_failed.emit(_error_text(parsed, "Progress write failed"))
		else:
			progress_recorded.emit(parsed)
		http.queue_free()
	)
	http.request(_api() + "/server/progress", ["Authorization: Bearer " + server_key, "Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))

func _progress(body: Dictionary) -> void:
	if jwt == "" or not _valid_uid(game_uid):
		progress_failed.emit("Sign in before writing progress")
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		var parsed := _data(raw)
		if code < 200 or code >= 300 or typeof(parsed) != TYPE_DICTIONARY:
			progress_failed.emit(_error_text(parsed, "Progress write failed"))
		else:
			progress_recorded.emit(parsed)
		http.queue_free()
	)
	http.request(_api() + "/private/player/progress", ["Authorization: Bearer " + jwt, "Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))

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
