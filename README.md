# model-usage — live omp usage in Tern's status line

A Tern window plugin that adds one status-line segment showing omp's
coding-plan quota for every authenticated account:

```
usage codex 5h 30% · opencode 7d 30% · cc 5h 8%
```

Each provider shows the window it is closest to exhausting — `5h`, `7d` or
`monthly`, whatever `omp usage --json` reports — with the id in front so the
number is never ambiguous.

Clicking the segment (or `Model Usage: Details`) opens a **Model Usage** canvas
pane: one card per provider, one line per quota window — name, percent, a
ten-block bar, reset countdown and status — kept in sync on each poll. The same
pane is reused instead of opening a new one.

The lines are plain `ui.text` nodes on purpose. As `ui.table` rows inside
`ui.card`, every card after the first laid out its frame but painted nothing —
no header row, no cells — while the view handed to the canvas still carried
every row. Text lines sidestep that node entirely.

The pane opens on the click, before any numbers exist: it shows "reading quota
windows from omp…" until the poll lands and then redraws itself in place, so
the detail never needs a second click. A poll that fails leaves the reason in
the pane.

Every good poll is cached as a trimmed report (provider, windows, amounts — no
report metadata, so no account ids or email on disk). A new window or a plugin
reload paints from that cache, so the segment and the pane fill in immediately
instead of going blank until omp answers again.

It polls `omp usage --json` on load and every 3 minutes (omp itself caches
provider reports for ~5 minutes), writes the result into the segment, and tints
it `warn` at 75% and `error` at 90% of the most constrained window.

## Commands (palette, group "Model Usage")

| Command                       | Does                                                            |
| ----------------------------- | --------------------------------------------------------------- |
| `Model Usage: Refresh`        | Poll now (ignores the 30s poll gap).                              |
| `Model Usage: Details`        | Open (or refresh) the **Model Usage** canvas pane with every window per provider — instantly, even before the first poll finishes. The segment itself is clickable and runs this. Falls back to a one-line toast when the host has no canvas. |
| `Model Usage: Toggle`         | Hide/show the segment (remembered in the plugin's `kv.json`).   |
| `Model Usage: Show Status Line` | Turn `status_bar` on if it is off (the segment needs it).     |

Actions are bindable: `plugin.model-usage.refresh`, `.details`, `.toggle`,
`.status-line`.

## How it finds omp

In order, stopping at the first that works:

1. `bun` + `<npm prefix>/@oh-my-pi/pi-coding-agent/dist/cli.js` (survives an
   omp shim whose `#!/usr/bin/env bun` has no `bun` on the daemon's PATH),
2. `~/.bun/bin/omp`, `~/.local/bin/omp`,
3. `omp` on PATH,
4. `sh -lc "omp usage --json"` (a login shell's PATH).

Parse failures and provider errors are logged at `warn` on target
`tern::plugin`; they never replace the last good numbers.

## Files

- `plugin.toml` — manifest (`schema = 1`, `id`, `name`, `version`, `description`, `window`).
- `window.luau` — the whole plugin; `host.luau` is not needed.
- `<TERN_CONFIG_DIR>/plugin-data/model-usage/kv.json` — the toggle state.
- `<TERN_CONFIG_DIR>/plugin-data/model-usage/usage.json` — the last good report, trimmed to the fields the plugin draws.

Install/update in place, then `tern plugin reload` (Tern also reloads the
directory on change). `tern plugin remove model-usage` uninstalls it; remove
`"status_bar": true` from Tern's `settings.json` to hide the status line again.
