@tool
extends EditorPlugin

const SETTING := "blazium/game/game_uid"
const DISCORD_APP_SETTING := "blazium/discord/application_id"

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
	if not ProjectSettings.has_setting(DISCORD_APP_SETTING):
		ProjectSettings.set_setting(DISCORD_APP_SETTING, "")
	ProjectSettings.set_initial_value(DISCORD_APP_SETTING, "")
	ProjectSettings.add_property_info({
		"name": DISCORD_APP_SETTING,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT,
		"hint_string": "Discord application id allowed to proxy this game",
	})

func _exit_tree() -> void:
	pass
