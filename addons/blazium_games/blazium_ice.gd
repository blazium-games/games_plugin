class_name BlaziumIce
extends Node

## ICE uses the same JWT. stun and turn are two hostnames on one service.

signal ice_servers_received(servers: Array)
signal ice_denied

const STUN_ICE := "https://stun.blazium.online/v1/ice"
const TURN_SIGNAL := "wss://turn.blazium.online/v1/signal"

var ice_servers: Array = []
var ice_enabled := true
var _http: HTTPRequest
var _hold := false
var _deferred_jwt := ""

func _ready() -> void:
	add_to_group("blazium_ice")

func set_ice_enabled(on: bool) -> void:
	ice_enabled = on

func cancel_ice_hold() -> void:
	_hold = false
	_deferred_jwt = ""

func hold_ice(on: bool) -> void:
	_hold = on
	if on or _deferred_jwt == "":
		return
	var jwt := _deferred_jwt
	_deferred_jwt = ""
	fetch_ice(jwt, "")

func note_lobby(result: Dictionary) -> void:
	var body: Dictionary = result
	if body.has("data") and typeof(body["data"]) == TYPE_DICTIONARY:
		body = body["data"]
	if body.has("ice_enabled"):
		set_ice_enabled(bool(body["ice_enabled"]))

func fetch_ice(jwt: String, _session_id: String) -> void:
	if _hold:
		_deferred_jwt = jwt
		return
	var game_uid := str(ProjectSettings.get_setting("blazium/game/game_uid", ""))
	var user_id := _user_from_jwt(jwt)
	if not ice_enabled or jwt == "" or user_id == "" or not _valid_uid(game_uid):
		ice_servers = []
		ice_denied.emit()
		return
	if _http == null:
		_http = HTTPRequest.new()
		add_child(_http)
		_http.request_completed.connect(_on_ice)
	var session_id := _ice_session(user_id, game_uid)
	var url := STUN_ICE + "?game_uid=" + game_uid.uri_encode() + "&session_id=" + session_id.uri_encode()
	var err := _http.request(url, ["Authorization: Bearer " + jwt])
	if err != OK:
		ice_servers = []
		ice_denied.emit()

func _on_ice(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		ice_servers = []
		ice_denied.emit()
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("ice_servers"):
		ice_servers = []
		ice_denied.emit()
		return
	ice_servers = parsed["ice_servers"]
	ice_servers_received.emit(ice_servers)

func signal_url() -> String:
	return TURN_SIGNAL

func _ice_session(user_id: String, game_uid: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update((user_id.to_lower() + ":" + game_uid.to_lower()).to_utf8_buffer())
	return ctx.finish().hex_encode()

func _user_from_jwt(token: String) -> String:
	var parts := token.split(".")
	if parts.size() < 2:
		return ""
	var body := Marshalls.base64_to_utf8(parts[1])
	var parsed = JSON.parse_string(body)
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	return str(parsed.get("uid", parsed.get("user_id", "")))

func _valid_uid(uid: String) -> bool:
	var re := RegEx.new()
	re.compile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
	return re.search(uid) != null
