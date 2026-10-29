# Cursor report: Dock names (Steam as “Steam”)

**Worktree:** `~/Cosmopolitan-cursor`  
**Branch:** `dock-names` (from `main` @ `131c114`)  
**Not pushed.** Never touched `~/Cosmopolitan`.

## Cause

`loaderNamed(_:)` copied `bin/wine` under `appName(exe)`. For a Steam library game that is the Steam title (e.g. `The Witcher 3: Wild Hunt — Remastered`). Cosmopolitan then starts Wine as `steam.exe -applaunch <id>` while the **loader file** still carried the game name. macOS names the Dock after that executable; Wine children inherit it for the whole Steam session.

The odd label `The Witcher 3- Wild Hunt — Remastered` came from sanitizing `:` → `-` (`3: Wild` → `3- Wild`). Leftover exact copies of `bin/wine` under old titles stayed in the engine’s `bin/` (including that Witcher name on the everyday engine).

## What changed

| Path | Role |
|------|------|
| `Sources/Model/Launch.swift` | `loaderProcessName`: Steam games / `steam.exe` → `"Steam"`; Epic / GOG Galaxy / Battle.net / EA app / Ubisoft Connect fixed names; other exes keep a sanitized display name. `sanitizeLoaderFileName`: `:` `/` `\` → spaces (not `-`). `pruneWineLoaderCopies`: delete **only** byte-identical copies of `bin/wine`, keeping store host names + the loader in use. |
| `Sources/App/App.swift` | `--loader-name <bottle> <exe>` for tests |
| `tests/safety/dock_names.sh` | Naming rules, prune safety, live `-applaunch` process must be `Steam` |

## Game window / process name through Steam

Steam starts the game via its own `CreateProcess`. Under Wine those children keep the parent loader name (`Steam`). There is no clean hook in Cosmopolitan to rename only the game process without fighting Steam/Wine. **Games launched through Steam stay “Steam” in the Dock**; games started directly (not via a store host) still get their own loader name.

## Test output

```
PASS dock_names
  ok: Steam game → loader-name Steam; pruned 'The Witcher 3- Wild Hunt — Remastered'; left keep-me-not-wine
  ok: store hosts and direct game naming
  ok: live -applaunch process is Steam (… exe=Steam); no game-titled loader

PASS launchers
PASS steam_restart
PASS steam_launch_options
PASS log_start
```

## Could not verify

- Live Dock icon appearance in Finder/Dock UI (process executable path verified instead).
- Steam self-update re-exec keeping “Steam” on a real client (inherits whatever loader the session already has; after this fix that is Steam).
- Everyday engine’s leftover Witcher loader is removed on the user’s machine only after the next Cosmo-started Wine launch (prune runs from `loaderNamed`).
