extends "res://addons/blazium_games/blazium_games.gd"

## Test stand-in for the API origin only. Every other method is the addon script.
var api_override := ""

func _api() -> String:
	return api_override
