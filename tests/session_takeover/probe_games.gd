extends "res://addons/blazium_games/blazium_games.gd"

## Test double: points HTTP and the login socket at the local harness and records session-file writes.
## The credential commits under test stay in the parent script.

var api_override := ""
var save_log: Array[String] = []

func _api() -> String:
	return api_override

func _login_url() -> String:
	return "ws://127.0.0.1:9/session-takeover-test"

func _save_session() -> void:
	save_log.append(jwt)
	super._save_session()
