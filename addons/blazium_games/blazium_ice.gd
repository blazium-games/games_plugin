class_name BlaziumIce
extends Node

## ICE uses the same JWT. stun and turn are two hostnames on one service.

signal ice_servers_received(servers: Array)
signal ice_denied

const STUN_ICE := "https://stun.blazium.online/v1/ice"
const TURN_SIGNAL := "wss://turn.blazium.online/v1/signal"

var ice_servers: Array = []
var _http: HTTPRequest

func fetch_ice(jwt: String, session_id: String) -> void:
	if jwt == "":
		ice_servers = []
		ice_denied.emit()
		return
	if _http == null:
		_http = HTTPRequest.new()
		add_child(_http)
		_http.request_completed.connect(_on_ice)
	var url := STUN_ICE
	if session_id != "":
		url += "?session_id=" + session_id.uri_encode()
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
