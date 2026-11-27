# Blazium Games for Godot

Godot addon for [Blazium Games](https://blazium.games), a game publishing platform operated by Divine Games, Inc. It signs in, then uses that session for lobbies and peer connections. It also covers Steam sign-in, bug reports, ownership, achievements, stats, events, presence, patch notices, item transfer, and server progress. It does not ship the native library.

## Install

Download `blazium_games-<version>.zip` from [Releases](https://github.com/blazium-games/games_plugin/releases), or copy `addons/blazium_games` from this repository. Enable the plugin and set the project setting `blazium/game/game_uid` to the project id.

`server_progress` is the only call that uses `await`. Every other call returns through a signal. `record_standard_events` posts six launch events in one request with zero times. It is not a hook for each of those moments. `socket_item`, `unsocket_item`, `set_item_stats`, and `use_item` fail on a player session.

The long guide is [Engines](https://docs.blazium.games/docs/engines).

## Scripted API

`BlaziumSapi.invoke(logic, args, opts)` calls `https://sapi.blazium.online/v1/{game_uid}/{logic}` (`call_logic` is kept as an alias). Results come on `call_completed` and `call_failed`. A signed-in call sends a short-lived token for this game that `BlaziumGames.request_scoped_token("sapi")` asked for; the login token and the Steam session are never sent. A native game asks games_service with its login, or with the Steam session for a Steam-only player. A browser game has no login, so it asks the play origin that served it with `POST /blazium/token`. A 429 or 503 is retried with the same `Idempotency-Key`, and a 401 asks for a fresh token once. Pass `{"anonymous": true}` for logic marked `auth = anonymous`.

```gdscript
var reply: Dictionary = await $BlaziumGames.request_scoped_token("lobby")
if reply.ok:
    lobby.create_lobby(reply.token, "public")  # a lobby token works for create, join and read only
$BlaziumSapi.invoke("score_submit", {"score": 10})
```

A token lasts minutes, is cached until a minute before it ends, and is dropped on sign-in and on a 401. Never log or save one.

## Player sign-in outside the launcher

`BlaziumGames.start_login()` works in a game that is not started by the launcher: it asks `login.blazium.online` for a link and a short code, and emits `login_url_received(url)` and `login_code_received(user_code, verification_url)` (show the code on a console or TV, or the link as a QR code). `login_pending(gate)` means the website still has a step for the player; `login_failed(message)` and `session_expired` report the rest. `cancel_login()` stops waiting.

The addon renews the session before it ends (`refresh_session()`, signal `session_refreshed(jwt)`), saves it so `restore_session()` signs a returning player in again (`restore_session_from(token)` if your game keeps the token itself), and `logout()` forgets it. With `persist_session` on, the token is kept only in the operating system's credential store (Secret Service through `secret-tool` on Linux and BSD, the login keychain on macOS, DPAPI for the current user on Windows). Web, Android, iOS, consoles, and desktops without such a store save nothing: keep the token in the platform's protected storage and use `restore_session_from`. A `user://blazium_session.dat` left by an earlier version is deleted, not read. `request_chat_token()` returns the host, port and a short-lived password for the Blazium IRC server. Scoped tokens from `request_scoped_token` are dropped whenever the session changes, and `start_login()` and `restore_session_from()` also forget a stored Steam session before they wait on the network. `logout()`, `start_login()`, a completed sign-in and both restore calls also close every `BlaziumLobby` socket and drop its admit ticket, and clear the relay servers, ICE session and deferred login on every `BlaziumIce` node, so the next player cannot carry on in the previous player's lobby or voice session. The repo's `tests/*_contract_test.py` check the call shapes; the sign-in flow has not been run in a Godot editor or on a console from this repo.

## Platform

- Docs: [docs.blazium.games](https://docs.blazium.games) and the map [llms.txt](https://docs.blazium.games/llms.txt)
- Support: [blazium-games/support](https://github.com/blazium-games/support/issues). Status: [status.blazium.games](https://status.blazium.games)

## This repo

A push to `master` publishes `blazium_games-<version>.zip` containing `addons/blazium_games` and `LICENSE`. The addon talks to Blazium over HTTP. It does not load `blazium_api64.dll` or `libblazium_api.so`.

## License

Licensed under the MIT License — see [LICENSE](LICENSE).
