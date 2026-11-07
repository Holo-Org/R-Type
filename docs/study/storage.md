# Storage

R-Type keeps very little on disk, on purpose: no accounts, no scores, no saved games. What it does keep is chosen for the people who read it.

## What is kept

| What | Where | Format | Written by |
|---|---|---|---|
| The Client's settings: bindings, auto-fire, volume | `settings.zon` in the operating system's config folder, or next to the Client | ZON, with comments | the Client, once, with its defaults; then the Player |
| A Server's measurements | the file given to `--stats` | CSV, one row per Connection per report | the Server, appended as it runs |
| The game's sprites and sounds | inside the Client | GIF sheets compiled in; sounds generated in code | the build |

## The settings file

| | ZON (ours) | JSON | TOML | INI |
|---|---|---|---|---|
| Comments, to explain each setting in the file itself | yes | no | yes | yes |
| Read by Zig's standard library | yes, into the `Settings` struct directly | yes | no | no |
| Nested lists, such as several keys per Action | yes | yes | yes | no |

ZON lets the file explain itself: the Client writes its defaults with a comment above each setting, and the Player edits that. A settings file must never stop the game, so:

- a file that cannot be read or parsed is skipped with a warning, and the defaults are used;
- a setting missing from the file takes its default, so an older file still works;
- the Client never overwrites a file that exists, even an invalid one, since it is the Player's;
- a `settings.zon` next to the executable replaces the other entirely, so the game can run from a USB stick without touching the machine.

## The measurements

CSV, because it opens in any spreadsheet and any script, and because appending a line never needs the rest of the file. The Server writes a header, then one line per Connection at every 5-second report and when the Connection ends. If writing fails, the Server says so once and stops writing, but keeps running: a full disk must not end a Match.

## Why no database

| Option | What it would give | Why not |
|---|---|---|
| SQLite | queries, transactions, durability | nothing to query: no accounts, scores or rankings in our scope |
| A key-value file | persistence of Player data | no Player data to keep: a Player is an address for the length of a Connection |
| None (ours) | nothing to back up, migrate or secure | a global scoreboard or accounts would need one of the above |

Accounts, rankings and a scoreboard are multi-instance topics we left out ([networking](networking.md)); they are where storage would start to matter.
