extends "res://addons/blazium_games/blazium_sapi.gd"

## Test stand-in for the Scripted API origin only. Token selection stays in the addon script.
var base_override := ""

func _base() -> String:
	return base_override
