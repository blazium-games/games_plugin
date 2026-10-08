# Local testing

`games_plugin` is GDScript. It has no binary.

Copy `addons/blazium_games` into a Godot project, enable the plugin, and set `blazium/game/game_uid` to the game id. The addon signs in, then uses that session for the lobby and for peer connections.
