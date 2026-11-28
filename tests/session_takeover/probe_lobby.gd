extends "res://addons/blazium_games/blazium_lobby.gd"

var api_override := ""

func _api() -> String:
	return api_override

func _lobby_url() -> String:
	return "ws://127.0.0.1:9/session-takeover-lobby"
