@tool
extends EditorPlugin

const SETTING := "blazium/game/game_uid"
const DISCORD_APP_SETTING := "blazium/discord/application_id"
const SAPI_CHANNEL_SETTING := "blazium/sapi/channel"

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
	if not ProjectSettings.has_setting(SAPI_CHANNEL_SETTING):
		ProjectSettings.set_setting(SAPI_CHANNEL_SETTING, "stable")
	ProjectSettings.set_initial_value(SAPI_CHANNEL_SETTING, "stable")
	ProjectSettings.add_property_info({
		"name": SAPI_CHANNEL_SETTING,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT,
		"hint_string": "Release channel for Scripted API calls",
	})

func _exit_tree() -> void:
	pass
