extends "res://addons/blazium_games/blazium_games.gd"

## Test peer only. Token selection stays in BlaziumGames; this replaces the service host
## so requests stay on the local recorder instead of the public API.
var api_base := ""
var login_base := ""

func _api() -> String:
	return api_base

func _login_url() -> String:
	return login_base
