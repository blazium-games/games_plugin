@tool
extends EditorPlugin

const SETTING := "blazium/game/game_uid"

func _enter_tree() -> void:
	if not ProjectSettings.has_setting(SETTING):
		ProjectSettings.set_setting(SETTING, "")
	ProjectSettings.set_initial_value(SETTING, "")
	ProjectSettings.add_property_info({
		"name": SETTING,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT,
		"hint_string": "Game uid from blazium.games",
	})

func _exit_tree() -> void:
	pass
