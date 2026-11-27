extends "res://addons/blazium_games/blazium_sapi.gd"

## Test peer only. _bearer still decides the credential; this replaces the service host.
var api_base := ""

func _base() -> String:
	return api_base
