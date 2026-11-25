class_name BlaziumGames
extends Node

## Auth channel only. The socket closes after the JWT arrives.
## Lobby and ICE use that token on their own connections.

signal login_url_received(url: String)
## A console or TV can show this code and verification_url instead of a link. The player types the code at that address.
signal login_code_received(user_code: String, verification_url: String)
## The player signed in but still has to finish a step on the website (terms, setup, authenticator). The socket stays open and logged_in follows.
signal login_pending(gate: String)
signal session_refreshed(jwt: String)
signal logged_out
signal logged_in(jwt: String)
signal login_failed(message: String)
signal session_expired
signal steam_signed_in(steam_id: String, token: String)
signal steam_sign_in_failed(message: String)
signal bug_reported(bug_uid: String)
signal bug_report_failed(message: String)
signal bug_notices_ready(body: Dictionary)
signal bug_notices_failed(message: String)
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

## Short-lived tokens by audience ("sapi", "lobby"): {"reply": Dictionary, "until": msec}.
var _scoped_tokens := {}

var _socket: WebSocketPeer
var _sent_getid := false
var _play_accum := 0.0
var _reporting := true
## Seconds to wait for the browser sign-in. 0 waits until the socket closes.
var login_timeout := 120.0
var _login_elapsed := 0.0
var _session_expired_sent := false

func _ready() -> void:
	add_to_group("blazium_games")
	game_uid = str(ProjectSettings.get_setting("blazium/game/game_uid", ""))

func start_login() -> void:
	if not _valid_uid(game_uid):
		login_failed.emit("blazium/game/game_uid must be the project UUID")
		return
	jwt = ""
	user_id = ""
	forget_scoped_tokens()
	_reporting = true
	_play_accum = 0.0
	_sent_getid = false
	_login_elapsed = 0.0
	_session_expired_sent = false
	if _socket != null:
		_socket.close()
		_socket = null
	_socket = WebSocketPeer.new()
	_socket.supported_protocols = PackedStringArray(["blazium", game_uid])
	var err := _socket.connect_to_url(_login_url())
	if err != OK:
		login_failed.emit("WebSocket connect failed")
		_socket = null

func cancel_login() -> void:
	_login_elapsed = 0.0
	_sent_getid = false
	if _socket != null:
		_socket.close()
		_socket = null

func _process(delta: float) -> void:
	_tick_playtime(delta)
	_tick_refresh(delta)
	if _socket == null:
		return
	_socket.poll()
	var state := _socket.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED and jwt == "":
		_socket = null
		_login_elapsed = 0.0
		login_failed.emit("Connection closed")
		return
	if jwt == "" and login_timeout > 0.0:
		_login_elapsed += delta
		if _login_elapsed >= login_timeout:
			if _socket != null:
				_socket.close()
			_socket = null
			_sent_getid = false
			_login_elapsed = 0.0
			login_failed.emit("Sign-in timed out")
			return
	if state == WebSocketPeer.STATE_OPEN and not _sent_getid:
		_socket.send_text('{"action":"getid"}')
		_sent_getid = true
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
		var code := str(message.get("user_code", ""))
		if code != "":
			login_code_received.emit(code, str(message.get("verification_url", "")))
	elif action == "login_pending":
		login_pending.emit(str(message.get("gate", "")))
	elif action == "jwt" or action == "login_success":
		var token := str(message.get("jwt", message.get("token", "")))
		if token == "":
			login_failed.emit("Login response had no token")
			return
		jwt = token
		_reporting = true
		_play_accum = 0.0
		_login_elapsed = 0.0
		_session_expired_sent = false
		user_id = str(message.get("uid", message.get("user_id", "")))
		_socket.close()
		_socket = null
		_save_session()
		logged_in.emit(jwt)
	elif action == "error":
		login_failed.emit(str(message.get("message", "Login failed")))

## ---- Session for a player who signed in without the launcher -------------------------------------
##
## The launcher keeps a session fresh for a game it started. A game with no launcher keeps its own:
## it refreshes the login before it expires, can remember it between runs, and signs out.

## Remember the login between runs. Off by default. The file is in the game's own user directory and is
## encrypted with a key made from the game and the device, which keeps a casual copy from working
## elsewhere. It is not a vault: on a platform with a secure store, keep the token there instead and
## call restore_session_from(token).
var persist_session := false
## Refresh when this many seconds are left. The service accepts a refresh at any time while the login is live.
var refresh_margin := 24 * 3600
const SESSION_FILE := "user://blazium_session.dat"
var _refresh_clock := 0.0
var _refreshing := false

## Seconds since 1970 when the current login token expires, or 0 when there is none.
func session_expiry() -> int:
	if jwt == "":
		return 0
	var parts := jwt.split(".")
	if parts.size() != 3:
		return 0
	var raw := parts[1].replace("-", "+").replace("_", "/")
	while raw.length() % 4 != 0:
		raw += "="
	var parsed = JSON.parse_string(Marshalls.base64_to_raw(raw).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return 0
	return int(parsed.get("exp", 0))

func is_signed_in() -> bool:
	var exp := session_expiry()
	return jwt != "" and exp > int(Time.get_unix_time_from_system())

func _tick_refresh(delta: float) -> void:
	if jwt == "" or _refreshing:
		return
	_refresh_clock += delta
	if _refresh_clock < 300.0:
		return
	_refresh_clock = 0.0
	var left := session_expiry() - int(Time.get_unix_time_from_system())
	if left > 0 and left <= refresh_margin:
		refresh_session()

## Asks for a new login token before the current one expires. Returns true when it worked. A refusal
## because the login is over emits session_expired. Use it with await, or watch session_refreshed.
func refresh_session() -> bool:
	if jwt == "" or _refreshing or not is_inside_tree():
		return false
	_refreshing = true
	var http := HTTPRequest.new()
	http.timeout = 15.0
	add_child(http)
	var err := http.request(_api() + "/public/token/refresh", ["Authorization: Bearer " + jwt], HTTPClient.METHOD_POST)
	if err != OK:
		http.queue_free()
		_refreshing = false
		return false
	var result: Array = await http.request_completed
	http.queue_free()
	_refreshing = false
	if result.size() < 4 or int(result[0]) != HTTPRequest.RESULT_SUCCESS:
		return false
	var code: int = result[1]
	_note_http(code)
	var body = _data(result[3])
	if code < 200 or code >= 300 or typeof(body) != TYPE_DICTIONARY or str(body.get("token", "")) == "":
		return false
	jwt = str(body["token"])
	# The old login id is gone, so tokens made from it are too.
	forget_scoped_tokens()
	_save_session()
	session_refreshed.emit(jwt)
	return true

## Uses a login token the game kept elsewhere (a platform secure store, for example). If it is
## close to expiry it is refreshed first. Emits logged_in on success, login_failed otherwise.
func restore_session_from(token: String) -> void:
	jwt = token.strip_edges()
	_session_expired_sent = false
	var left := session_expiry() - int(Time.get_unix_time_from_system())
	if jwt == "" or left <= 0:
		jwt = ""
		login_failed.emit("The saved sign-in has expired")
		return
	var ok := true
	if left <= refresh_margin:
		ok = await refresh_session()
	if not ok and session_expiry() <= int(Time.get_unix_time_from_system()):
		jwt = ""
		login_failed.emit("The saved sign-in could not be renewed")
		return
	_reporting = true
	logged_in.emit(jwt)

## Reads the login saved by an earlier run when persist_session is on. Emits logged_in or login_failed.
func restore_session() -> void:
	if not persist_session:
		login_failed.emit("Saved sign-ins are off")
		return
	var token := _load_session()
	if token == "":
		login_failed.emit("No saved sign-in")
		return
	await restore_session_from(token)

## Signs out: the service ends this login, and the saved copy and cached tokens are dropped.
func logout() -> void:
	var token := jwt
	jwt = ""
	user_id = ""
	steam_token = ""
	forget_scoped_tokens()
	_forget_saved_session()
	_reporting = false
	if token != "" and is_inside_tree():
		var http := HTTPRequest.new()
		http.timeout = 10.0
		add_child(http)
		if http.request(_api() + "/private/logout", ["Authorization: Bearer " + token], HTTPClient.METHOD_POST) == OK:
			await http.request_completed
		http.queue_free()
	logged_out.emit()

func _session_key() -> String:
	var device := OS.get_unique_id() if OS.get_name() != "Web" else ""
	return ("blazium-session|" + game_uid + "|" + device).sha256_text()

func _save_session() -> void:
	if not persist_session or jwt == "":
		return
	var file := FileAccess.open_encrypted_with_pass(SESSION_FILE, FileAccess.WRITE, _session_key())
	if file == null:
		return
	file.store_string(jwt)
	file.close()

func _load_session() -> String:
	if not FileAccess.file_exists(SESSION_FILE):
		return ""
	var file := FileAccess.open_encrypted_with_pass(SESSION_FILE, FileAccess.READ, _session_key())
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text.strip_edges()

func _forget_saved_session() -> void:
	if FileAccess.file_exists(SESSION_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SESSION_FILE))

## Asks for the chat sign-in details (host, port, nick and a ten minute password) for the Blazium IRC
## server. Use it with await. It needs a login. The reply is the service's fields, or {"ok": false, "error"}.
func request_chat_token() -> Dictionary:
	if jwt == "" or not is_inside_tree():
		return {"ok": false, "error": "sign in before asking for chat access"}
	var http := HTTPRequest.new()
	http.timeout = 15.0
	add_child(http)
	if http.request(_api() + "/private/irc/token", ["Authorization: Bearer " + jwt, "Content-Type: application/json"], HTTPClient.METHOD_POST, "{}") != OK:
		http.queue_free()
		return {"ok": false, "error": "the chat request could not be sent"}
	var result: Array = await http.request_completed
	http.queue_free()
	if result.size() < 4 or int(result[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "the chat service could not be reached"}
	var code: int = result[1]
	_note_http(code)
	var body = _data(result[3])
	if code < 200 or code >= 300 or typeof(body) != TYPE_DICTIONARY:
		return {"ok": false, "error": _error_text(body, "chat access was refused")}
	return body

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
		_note_http(code)
		var parsed = JSON.parse_string(raw.get_string_from_utf8())
		var body = parsed
		if typeof(parsed) == TYPE_DICTIONARY and typeof(parsed.get("data", null)) == TYPE_DICTIONARY:
			body = parsed["data"]
		if code == 401 or (typeof(body) == TYPE_DICTIONARY and str(body.get("logged_on", "")) == "false"):
			_reporting = false
		http.queue_free()
	)
	var err := http.request(_api() + "/private/library/" + game_uid.uri_encode() + "/playtime", ["Authorization: Bearer " + jwt, "Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify({"seconds": seconds}))
	if err != OK:
		http.queue_free()

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
		_note_http(code)
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
func report_bug(message: String, client_version: String = "", os_name: String = "", arch: String = "", log_text: String = "", screenshot_path: String = "", build_id: String = "") -> void:
	var token := steam_token if steam_token != "" else jwt
	if token == "" or not _valid_uid(game_uid):
		bug_report_failed.emit("Sign in before reporting a bug")
		return
	var boundary := "blazium-%08x%08x" % [randi(), randi()]
	var body := PackedByteArray()
	_part(body, boundary, "message", message)
	if client_version != "":
		_part(body, boundary, "client_version", client_version)
	if os_name != "":
		_part(body, boundary, "os", os_name)
	if arch != "":
		_part(body, boundary, "arch", arch)
	if build_id != "":
		_part(body, boundary, "build_id", build_id)
	if log_text != "":
		_part(body, boundary, "log", _redact_log(log_text))
	if screenshot_path != "":
		var shot_error := _append_screenshot(body, boundary, screenshot_path)
		if shot_error != "":
			bug_report_failed.emit(shot_error)
			return
	body.append_array(("--%s--\r\n" % boundary).to_utf8_buffer())
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		_note_http(code)
		var parsed := _data(raw)
		if code < 200 or code >= 300 or typeof(parsed) != TYPE_DICTIONARY:
			bug_report_failed.emit(_error_text(parsed, "Bug report failed"))
		else:
			bug_reported.emit(str(parsed.get("bug_uid", "")))
		http.queue_free()
	)
	var headers := PackedStringArray([
		"Authorization: Bearer " + token,
		"Content-Type: multipart/form-data; boundary=" + boundary,
		"X-App-Id: " + game_uid,
	])
	if build_id != "":
		headers.append("X-Build-Id: " + build_id)
	http.request_raw(_api() + "/games/" + game_uid.uri_encode() + "/bugs", headers, HTTPClient.METHOD_POST, body)

func bug_notices() -> void:
	_bug_notice("GET", "")

func ack_bug_notices(uids: Array) -> void:
	_bug_notice("POST", JSON.stringify({"uids": uids}))

func _bug_notice(method: String, raw_body: String) -> void:
	var token := steam_token if steam_token != "" else jwt
	if token == "" or not _valid_uid(game_uid):
		bug_notices_failed.emit("Sign in before reading bug notices")
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		_note_http(code)
		var body := _data(raw)
		if code < 200 or code >= 300 or typeof(body) != TYPE_DICTIONARY:
			bug_notices_failed.emit(_error_text(body, "Bug notices were refused"))
		else:
			bug_notices_ready.emit(body)
		http.queue_free()
	)
	var verb := HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST
	var path := "/bugs/notices" if method == "GET" else "/bugs/notices/ack"
	var headers := PackedStringArray(["Authorization: Bearer " + token, "Content-Type: application/json", "X-App-Id: " + game_uid])
	http.request(_api() + "/games/" + game_uid.uri_encode() + path, headers, verb, raw_body)

const MAX_SCREENSHOT_BYTES := 32 * 1024 * 1024

func _append_screenshot(body: PackedByteArray, boundary: String, path: String) -> String:
	var absolute := path
	if path.begins_with("user://"):
		absolute = ProjectSettings.globalize_path(path)
	elif not path.is_absolute_path():
		return "Screenshot must be inside the game user directory"
	var root := OS.get_user_data_dir().simplify_path().trim_suffix("/").trim_suffix("\\")
	absolute = absolute.simplify_path()
	var root_cmp := root.to_lower()
	var abs_cmp := absolute.to_lower()
	if not abs_cmp.begins_with(root_cmp + "/") and not abs_cmp.begins_with(root_cmp + "\\") and abs_cmp != root_cmp:
		return "Screenshot must be inside the game user directory"
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	if file.get_length() > MAX_SCREENSHOT_BYTES:
		file.close()
		return "Screenshot is larger than 32 MiB"
	var bytes := file.get_buffer(file.get_length())
	file.close()
	var name := path.get_file().replace("\"", "").replace("\r", "").replace("\n", "")
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"screenshot\"; filename=\"%s\"\r\nContent-Type: application/octet-stream\r\n\r\n" % [boundary, name]).to_utf8_buffer())
	body.append_array(bytes)
	body.append_array("\r\n".to_utf8_buffer())
	return ""

func _redact_log(text: String) -> String:
	var steam := RegEx.new()
	if steam.compile("\\b7656119\\d{10}\\b") == OK:
		text = steam.sub(text, "<steam_id>", true)
	var discord := RegEx.new()
	if discord.compile("(\"discord_id\"\\s*:\\s*\")[^\"]*\"") == OK:
		text = discord.sub(text, "$1<redacted>\"", true)
	return text

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
		_note_http(code)
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
		_note_http(code)
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
		_note_http(code)
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
		_note_http(code)
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
		_note_http(code)
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

## Sends one named launch event. A crash is not part of a launch.
func record_standard_events(build_id: String, device_uid: String = "plugin", event_name: String = "session_start") -> void:
	if not _valid_uid(game_uid) or build_id == "" or event_name == "" or event_name == "crash":
		progress_failed.emit("Name the launch event. A crash is not a launch event")
		return
	var events: Array = [{"event": event_name, "device_uid": device_uid}]
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray) -> void:
		_note_http(code)
		if code < 200 or code >= 300:
			progress_failed.emit(_error_text(_data(raw), "Launch events were refused"))
		else:
			progress_recorded.emit({"standard": true, "count": 1, "event": event_name})
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
		_note_http(code)
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
	if not OS.has_feature("dedicated_server"):
		return
	_server_progress(server_key, {"user_uid": user_uid, "kind": "achievement", "slug": slug, "event": ""})

func server_set_stat(server_key: String, user_uid: String, slug: String, value: int) -> void:
	if not OS.has_feature("dedicated_server"):
		return
	_server_progress(server_key, {"user_uid": user_uid, "kind": "stat", "slug": slug, "event": "", "value": value})

func server_record_event(server_key: String, user_uid: String, event_name: String) -> void:
	if not OS.has_feature("dedicated_server"):
		return
	_server_progress(server_key, {"user_uid": user_uid, "kind": "event", "slug": "", "event": event_name})

## Reads one owner's unlocks and stats with a game or private server key.
func server_progress(server_key: String, user_uid: String) -> Dictionary:
	if not OS.has_feature("dedicated_server"):
		return {"ok": false, "error": "Server progress is only available on a dedicated server"}
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
	_note_http(code)
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
		_note_http(code)
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
		_note_http(code)
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

## Asks for a short-lived token for this game only. audience is "sapi" (Scripted API), "lobby"
## (create, join and read a lobby) or "server" (proof of who the player is, handed to the game's own
## server, which checks it once with its server key). A game never mints a token: it asks, and the service signs one
## for the signed-in player. The reply is {"ok": true, "token", "audience", "game_uid", "expires_at",
## "expires_in"} or {"ok": false, "code", "error"}. Use it with await. A token is cached until a
## minute before it expires. Treat it as a secret: do not log it or save it.
##
## A native game asks games_service with its login. A browser game has no login: it asks the play
## origin that served it (POST /blazium/token), which proves the play session with its own cookie.
func request_scoped_token(audience: String) -> Dictionary:
	var want := audience.strip_edges().to_lower()
	if want != "sapi" and want != "lobby" and want != "server":
		return _token_failure("bad_audience", "audience must be sapi, lobby or server")
	var held = _scoped_tokens.get(want, null)
	if typeof(held) == TYPE_DICTIONARY and Time.get_ticks_msec() < int(held.get("until", 0)):
		return held["reply"].duplicate()
	var url := ""
	var headers := PackedStringArray(["Content-Type: application/json"])
	var body := ""
	if jwt != "":
		if not _valid_uid(game_uid):
			return _token_failure("bad_request", "blazium/game/game_uid must be the project UUID")
		url = _api() + "/private/games/" + game_uid.uri_encode() + "/tokens"
		headers.append("Authorization: Bearer " + jwt)
		body = JSON.stringify({"audience": want})
	elif steam_token != "" and _valid_uid(game_uid):
		# A Steam-only player has no Blazium login. The Steam session asks for the same short-lived token
		# once the Steam account is linked to a Blazium account (the service says so if it is not).
		url = _api() + "/steam/" + game_uid.uri_encode() + "/tokens"
		body = JSON.stringify({"token": steam_token, "audience": want})
	elif OS.get_name() == "Web":
		url = _web_token_url()
		if url == "":
			return _token_failure("no_host", "this page cannot ask for a token")
		body = JSON.stringify({"audience": want})
	else:
		return _token_failure("not_logged_on", "sign in before asking for a token")
	if not is_inside_tree():
		return _token_failure("no_host", "the Blazium node is not in the scene tree")
	var http := HTTPRequest.new()
	http.timeout = 15.0
	add_child(http)
	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return _token_failure("service_unavailable", "the token request could not be sent")
	var result: Array = await http.request_completed
	http.queue_free()
	if result.size() < 4 or int(result[0]) != HTTPRequest.RESULT_SUCCESS:
		return _token_failure("service_unavailable", "the token service could not be reached")
	var code: int = result[1]
	var parsed = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	if code == 401:
		_note_http(code)
	if code < 200 or code >= 300 or typeof(parsed) != TYPE_DICTIONARY or str(parsed.get("token", "")) == "":
		var key := "http_%d" % code
		if typeof(parsed) == TYPE_DICTIONARY and str(parsed.get("code", "")) != "":
			key = str(parsed["code"])
		return _token_failure(key, _error_text(parsed, "the token was refused"))
	var seconds := int(parsed.get("expires_in", 0))
	var reply := {
		"ok": true,
		"token": str(parsed["token"]),
		"audience": want,
		"game_uid": str(parsed.get("game_uid", game_uid)),
		"expires_at": str(parsed.get("expires_at", "")),
		"expires_in": seconds,
	}
	var margin := 60 if seconds > 120 else int(seconds / 2.0)
	_scoped_tokens[want] = {"reply": reply, "until": Time.get_ticks_msec() + maxi(0, seconds - margin) * 1000}
	return reply.duplicate()

## Drops every cached token, so the next request asks again. Done on sign-in and after a 401.
func forget_scoped_tokens() -> void:
	_scoped_tokens.clear()

func _token_failure(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}

func _web_token_url() -> String:
	var bridge = Engine.get_singleton("JavaScriptBridge")
	if bridge == null:
		return ""
	var id := _discord_application_id()
	if id != "":
		return "https://%s.discordsays.com/.proxy/blazium/token" % id
	var origin := str(bridge.eval("window.location.origin", true))
	if not origin.begins_with("https://"):
		return ""
	return origin + "/blazium/token"

func _note_http(code: int) -> void:
	if code != 401:
		return
	forget_scoped_tokens()
	_reporting = false
	if _session_expired_sent:
		return
	_session_expired_sent = true
	session_expired.emit()

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
