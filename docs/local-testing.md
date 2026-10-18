# Local testing

`games_plugin` is GDScript. It has no binary and it does not load the native library.

Copy `addons/blazium_games` into a Godot project, enable the plugin, and set `blazium/game/game_uid` to the game id. The addon signs in, then uses that session for the lobby and for peer connections. The same node covers Steam sign-in, bug reports, ownership, achievements, stats, events, presence, patch notices, item transfer, and server progress.

`server_progress` is the only call that uses `await`. Every other call returns through a signal.
