# Blazium Games for Godot

Godot addon for [Blazium Games](https://blazium.games), a game publishing platform operated by Divine Games, Inc. It signs in, then uses that session for lobbies and peer connections. It also covers Steam sign-in, bug reports, ownership, achievements, stats, events, presence, patch notices, item transfer, and server progress. It does not ship the native library.

## Install

Download `blazium_games-<version>.zip` from [Releases](https://github.com/blazium-games/games_plugin/releases), or copy `addons/blazium_games` from this repository. Enable the plugin and set the project setting `blazium/game/game_uid` to the project id.

`server_progress` is the only call that uses `await`. Every other call returns through a signal. `record_standard_events` posts six launch events in one request with zero times. It is not a hook for each of those moments. `socket_item`, `unsocket_item`, `set_item_stats`, and `use_item` fail on a player session.

The long guide is [Engines](https://docs.blazium.games/docs/engines).

## Platform

- Docs: [docs.blazium.games](https://docs.blazium.games) and the map [llms.txt](https://docs.blazium.games/llms.txt)
- Support: [blazium-games/support](https://github.com/blazium-games/support/issues). Status: [status.blazium.games](https://status.blazium.games)

## This repo

A push to `master` publishes `blazium_games-<version>.zip` containing `addons/blazium_games` and `LICENSE`. The addon talks to Blazium over HTTP. It does not load `blazium_api64.dll` or `libblazium_api.so`.

## License

Licensed under the MIT License — see [LICENSE](LICENSE).
