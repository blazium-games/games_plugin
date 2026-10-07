# Local testing

`games_plugin` is GDScript. It has no binary and is not built on Windows or Linux.

Copy `addons/blazium_games` into a Godot project. In project settings set `blazium/game/game_uid` to the game id. The addon signs in through the login websocket, then uses that token for the lobby socket and ICE.

There is no official DLL path. Do not add `games_sdk`, a GDExtension, or the engine `LoginClient` or `ScriptedLobbyClient`.

The CI check fails if those names appear under `addons/`.
