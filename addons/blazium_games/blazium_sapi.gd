class_name BlaziumSapi
extends Node

## Calls this game's Scripted API logic at https://sapi.blazium.online/v1/{game_uid}/{logic}.
## Signed-in calls send a short-lived token for this game, requested from BlaziumGames.request_scoped_token
## (a native game asks with its login, a browser game asks the play origin). The login token is never sent.
## Logic marked auth = anonymous works without one.

signal call_completed(logic: String, status: int, body: Variant, request_id: String)
signal call_failed(logic: String, status: int, error_key: String, message: String, request_id: String)

const SAPI := "https://sapi.blazium.online"
const MAX_BODY_BYTES := 64 * 1024

## Release channel sent as X-Blazium-Channel. Empty uses blazium/sapi/channel, then stable.
var channel := ""
## Tries after a 429 or 503 before call_failed is emitted.
var max_retries := 3
## Seconds per request.
var timeout := 15.0

var _game_uid := ""

func _ready() -> void:
	_game_uid = str(ProjectSettings.get_setting("blazium/game/game_uid", ""))

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

func _base() -> String:
	var id := _discord_application_id()
	if id != "":
		return "https://%s.discordsays.com/.proxy/blazium/sapi" % id
	return SAPI

## The Authorization token for one attempt, or "" when there is none. The BlaziumGames node asks for a
## short-lived token for this game (a Steam-only player asks with the Steam session): this class never
## reads or sends the login token or the Steam session.
func _bearer(req: Dictionary) -> String:
	req["scoped"] = false
	if not is_inside_tree():
		return ""
	var games := get_tree().get_first_node_in_group("blazium_games")
	if games == null:
		return ""
	if not games.has_method("request_scoped_token"):
		return ""
	var reply: Dictionary = await games.request_scoped_token("sapi")
	if not bool(reply.get("ok", false)):
		return ""
	req["scoped"] = true
	return str(reply.get("token", ""))

func _forget_tokens() -> void:
	if not is_inside_tree():
		return
	var games := get_tree().get_first_node_in_group("blazium_games")
	if games != null and games.has_method("forget_scoped_tokens"):
		games.forget_scoped_tokens()
func _channel() -> String:
	var ch := channel.strip_edges().to_lower()
	if ch == "":
		ch = str(ProjectSettings.get_setting("blazium/sapi/channel", "stable")).strip_edges().to_lower()
	return "stable" if ch == "" else ch

static func _valid_logic(logic: String) -> bool:
	if logic.length() < 1 or logic.length() > 64:
		return false
	for i in logic.length():
		var c := logic.unicode_at(i)
		var ok := (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45
		if not ok:
			return false
	return true

static func _new_key() -> String:
	var crypto := Crypto.new()
	return crypto.generate_random_bytes(16).hex_encode()

## Runs one logic. args is sent as the JSON body (or the query string for GET).
## opts: method ("POST" default, "GET", "PUT", "PATCH", "DELETE"), anonymous (bool, send no token),
## idempotency_key (String; a non-GET call gets one so retries apply once), channel (String).
func invoke(logic: String, args: Dictionary = {}, opts: Dictionary = {}) -> void:
	if not _valid_logic(logic):
		call_failed.emit(logic, 0, "bad_request", "logic names are lowercase letters, digits, _ and -", "")
		return
	if _game_uid == "":
		_game_uid = str(ProjectSettings.get_setting("blazium/game/game_uid", ""))
	if _game_uid == "":
		call_failed.emit(logic, 0, "bad_request", "blazium/game/game_uid is not set", "")
		return
	var method := str(opts.get("method", "POST")).to_upper()
	var verbs := {"GET": HTTPClient.METHOD_GET, "POST": HTTPClient.METHOD_POST, "PUT": HTTPClient.METHOD_PUT, "PATCH": HTTPClient.METHOD_PATCH, "DELETE": HTTPClient.METHOD_DELETE}
	if not verbs.has(method):
		call_failed.emit(logic, 0, "bad_request", "method must be GET, POST, PUT, PATCH or DELETE", "")
		return
	var url := _base() + "/v1/" + _game_uid.uri_encode() + "/" + logic
	var body := ""
	if method == "GET":
		var query := PackedStringArray()
		for k in args.keys():
			query.append(str(k).uri_encode() + "=" + str(args[k]).uri_encode())
		if not query.is_empty():
			url += "?" + "&".join(query)
	else:
		body = JSON.stringify(args)
		if body.to_utf8_buffer().size() > MAX_BODY_BYTES:
			call_failed.emit(logic, 0, "body_too_large", "the request body is larger than 64 KiB", "")
			return
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	headers.append("X-Blazium-Channel: " + str(opts.get("channel", _channel())))
	if method != "GET":
		var key := str(opts.get("idempotency_key", ""))
		headers.append("Idempotency-Key: " + (key if key != "" else _new_key()))
	# The token is added per attempt in _send, so a retry gets a fresh one and keeps the other headers.
	var req := {"logic": logic, "url": url, "headers": headers, "verb": verbs[method], "body": body, "anonymous": bool(opts.get("anonymous", false)), "scoped": false, "refreshed": false}
	_send(req, 0)

## Same as invoke. Kept for projects written against the first release.
func call_logic(logic: String, args: Dictionary = {}, opts: Dictionary = {}) -> void:
	invoke(logic, args, opts)

func _send(req: Dictionary, attempt: int) -> void:
	var logic: String = req["logic"]
	var headers: PackedStringArray = (req["headers"] as PackedStringArray).duplicate()
	if not bool(req["anonymous"]):
		var token := await _bearer(req)
		if token != "":
			headers.append("Authorization: Bearer " + token)
	var http := HTTPRequest.new()
	http.timeout = timeout
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, reply_headers: PackedStringArray, raw: PackedByteArray) -> void:
		http.queue_free()
		var request_id := _header(reply_headers, "x-request-id")
		if result != HTTPRequest.RESULT_SUCCESS:
			if attempt < max_retries:
				_retry(req, attempt, 0.0)

			else:
				call_failed.emit(logic, 0, "service_unavailable", "the Scripted API could not be reached", request_id)
			return
		if code == 401 and bool(req["scoped"]) and not bool(req["refreshed"]):
			# The token may have been revoked or aged out early. Ask once more.
			req["refreshed"] = true
			_forget_tokens()
			_send(req, attempt)
			return
		if (code == 429 or code == 503) and attempt < max_retries:
			_retry(req, attempt, _header(reply_headers, "retry-after").to_float())
			return
		var text := raw.get_string_from_utf8()
		var parsed = JSON.parse_string(text) if text != "" else null
		if code >= 200 and code < 300:
			call_completed.emit(logic, code, parsed if parsed != null else text, request_id)
			return
		var key := "http_%d" % code
		var message := "the call was refused"
		if typeof(parsed) == TYPE_DICTIONARY and typeof(parsed.get("error")) == TYPE_DICTIONARY:
			key = str(parsed["error"].get("key", key))
			message = str(parsed["error"].get("message", message))
		call_failed.emit(logic, code, key, message, request_id)
	)
	var err := http.request(str(req["url"]), headers, int(req["verb"]), str(req["body"]))
	if err != OK:
		http.queue_free()
		call_failed.emit(logic, 0, "bad_request", "the request could not be sent", "")

func _retry(req: Dictionary, attempt: int, retry_after: float) -> void:
	var wait := retry_after if retry_after > 0.0 else 0.5 * pow(2.0, attempt)
	await get_tree().create_timer(minf(wait, 8.0)).timeout
	_send(req, attempt + 1)

static func _header(headers: PackedStringArray, name: String) -> String:
	for h in headers:
		var i := h.find(":")
		if i > 0 and h.substr(0, i).strip_edges().to_lower() == name:
			return h.substr(i + 1).strip_edges()
	return ""

## Reads the public remote config values for the channel. Emits call_completed with logic "_config".
func get_public_config() -> void:
	if _game_uid == "":
		_game_uid = str(ProjectSettings.get_setting("blazium/game/game_uid", ""))
	if _game_uid == "":
		call_failed.emit("_config", 0, "bad_request", "blazium/game/game_uid is not set", "")
		return
	var url := _base() + "/v1/" + _game_uid.uri_encode() + "/_config?channel=" + _channel().uri_encode()
	_send({"logic": "_config", "url": url, "headers": PackedStringArray(["Accept: application/json"]), "verb": HTTPClient.METHOD_GET, "body": "", "anonymous": true, "scoped": false, "refreshed": false}, 0)
