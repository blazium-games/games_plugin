extends Node

## Drives the addon's saved sign-in and copies out the file bytes.
## Decryption is done by tests/session_disclosure_test.py, outside this process.

const PLACEHOLDER := "placeholder-login-token"
const CONTROL_PASS := "placeholder-control-passphrase"
const LISTEN_PORT := 8765

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var lines: Array = []
	lines.append("OS_NAME\t" + OS.get_name())
	var games_script = load("res://addons/blazium_games/blazium_games.gd")
	var games = games_script.new()
	add_child(games)
	lines.append("GAME_UID\t" + str(games.game_uid))
	if OS.get_name() == "Linux":
		var disk := _linux_machine_id()
		var matched := disk != "" and disk == OS.get_unique_id()
		lines.append("DEVICE_MATCH\t%s" % int(matched))
	games.persist_session = true
	_drop(games)
	_sign_in(games, lines, "jwt", {"action": "jwt", "jwt": PLACEHOLDER, "uid": "player-placeholder"})
	_drop(games)
	_sign_in(games, lines, "login_success", {"action": "login_success", "token": PLACEHOLDER, "user_id": "player-placeholder"})
	_drop(games)
	games.jwt = PLACEHOLDER
	games.persist_session = true
	games._save_session()
	lines.append("CASE\t_save_session\t" + _b64("user://blazium_session.dat"))
	var control := "user://control_not_session.dat"
	var file := FileAccess.open_encrypted_with_pass(control, FileAccess.WRITE, CONTROL_PASS)
	if file == null:
		lines.append("CONTROL\t")
	else:
		file.store_string(PLACEHOLDER)
		file.close()
		lines.append("CONTROL\t" + _b64(control))
	for line in lines:
		_emit(line)
	_emit("PROBE_DONE")
	if OS.get_name() == "Web":
		_post(lines)
	else:
		get_tree().quit(0)

func _sign_in(games, lines: Array, name: String, message: Dictionary) -> void:
	games.persist_session = true
	games.jwt = ""
	games._socket = WebSocketPeer.new()
	games._on_message(message)
	lines.append("CASE\t%s\t%s" % [name, _b64("user://blazium_session.dat")])

func _drop(games) -> void:
	games._forget_saved_session()

func _b64(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return Marshalls.raw_to_base64(FileAccess.get_file_as_bytes(path))

func _linux_machine_id() -> String:
	var file := FileAccess.open("/etc/machine-id", FileAccess.READ)
	if file == null:
		return ""
	var machine_id := ""
	while machine_id == "" and not file.eof_reached():
		machine_id = file.get_line().strip_edges()
	file.close()
	return machine_id

func _emit(line: String) -> void:
	print(line)
	if OS.get_name() != "Web":
		return
	var bridge = Engine.get_singleton("JavaScriptBridge")
	if bridge == null:
		return
	bridge.eval("console.log(%s)" % JSON.stringify(line), true)

func _post(lines: Array) -> void:
	var http := HTTPRequest.new()
	add_child(http)
	var body := "\n".join(lines) + "\nPROBE_DONE\n"
	var err := http.request(
		"http://127.0.0.1:%d/result" % LISTEN_PORT,
		["Content-Type: text/plain"],
		HTTPClient.METHOD_POST,
		body
	)
	if err != OK:
		get_tree().quit(1)
		return
	var result: Array = await http.request_completed
	var code := int(result[1]) if result.size() > 1 else 0
	get_tree().quit(0 if code >= 200 and code < 300 else 1)
