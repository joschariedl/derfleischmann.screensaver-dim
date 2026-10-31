# AGENTS.md — derfleischmann.screensaver-dim

Guidance for agents and humans editing this plugin. Read before touching
`Service.qml` or `Model.js`. `README.md` has the user-facing description.

## What this is

A `service`-only Omarchy shell plugin (no bar widget, no panel). It watches for
Hyprland windows of class `org.omarchy.screensaver`, saves each enabled
monitor's brightness, sets them to 1%, and restores on the last close.

Three files, ~200 lines total. The whole thing is small; the risk is not
complexity, it is leaving a display stuck at 1% or restoring a stale value.

## Layout

- `manifest.json` — `schemaVersion: 1`, `kinds: ["service"]`,
  `entryPoints.service: "Service.qml"`, `keepLoaded: true`.
- `Service.qml` — the event handler, the refcount, and the two `Process` runs.
- `Model.js` — pure functions only, no QML types. Node-testable.

## Invariants — breaking any of these can strand the user at 1%

1. **Save before dim, and save every monitor in the same shell run.**
   `Model.dimCommand` truncates the state file, reads each monitor, appends
   `monitor=value`, then sets 1% — all inside one `bash -lc`. Do not split this
   into several QML `Process` round-trips: a failure between "read" and "write"
   is exactly how a dim with no recorded value gets committed, which is
   unrecoverable by the plugin.
2. **Restore is idempotent and always ends by deleting the state file.** If the
   file is missing or empty, `restoreCommand` exits 0 without touching anything.
   Startup restore and screensaver-close restore both rely on this.
3. **Startup restore is mandatory, not a nicety.** `Component.onCompleted`
   calls `restoreBrightness("startup")`. That is the only thing that recovers
   from a shell or compositor restart during a screensaver. Keep it.
4. **Only the 0→1 edge dims.** `handleScreensaverWindowOpened` checks
   `next.count === 1`. Dimming again on the second monitor would save the
   already-dimmed 1% and lose the real value.
5. **`busy` guards both Process runs.** Two `Process` items, one `busy` flag.
   Do not add a third Process without extending the guard.
6. **Never write state inside `~/.config`.** The state path is
   `$XDG_STATE_HOME/derfleischmann.screensaver-dim/brightness`. Anything written
   under `~/.config/omarchy/plugins/` triggers a plugin rescan, which would
   rebuild this service mid-screensaver.
7. **`FileView` has no `exists` property.** Track toggle-file existence through
   `onLoaded` (present) / `onLoadFailed` (absent), and call `reload()` in
   `onFileChanged` — `text()` is stale in the change signal itself. This is the
   same pattern `Commons/Color.qml` uses for `~/.config/omarchy/shell.toml`.
8. **The toggle-file watch guards the one path `closewindow` never covers.**
   `omarchy-toggle-screensaver` only flips a flag file; a screensaver window
   that is already running keeps running, so no `closewindow` event fires and
   the normal restore never triggers. The `FileView` on
   `~/.local/state/omarchy/toggles/screensaver-off` (backed by a slow poll, in
   case `watchChanges` misses a same-second create) is what restores in that
   case. Do not remove it — the failure it guards (display stuck at 1% with no
   close event coming) is exactly invariant 1's risk.

## Omarchy shell facts this plugin depends on

Established by reading the shell source; re-verify if the shell is upgraded.

- **Third-party services get no QML parent.** `shell.qml` `ensureService` calls
  `comp.createObject(..., null)` for third-party plugins, so the instance is
  rooted only by the shell's service map. Nothing to parent to; a plain `Item`
  root is correct.
- **Enabling is `plugins[]` in shell.json.** `PluginRegistry.isEnabled` returns
  `findEntryLocation(...).found` for third-party, which matches
  `{"id": "<plugin-id>"}` in the `plugins` array. There is no separate enabled
  flag, and `disabledPlugins` takes precedence.
- **`keepLoaded: true` is load-bearing for reloads.** Without it, writing any
  file in the plugin dir tears the service down and rebuilds it. With it, the
  instance survives — which also means **code changes need
  `omarchy-restart-shell`, not just a save.** This cost real debugging time: an
  `import Quickshell` fix appeared not to apply until the shell was restarted.
- **No host API is needed.** Detection uses the global `Hyprland` singleton via
  `Connections { target: Hyprland; function onRawEvent(event) }`. The injected
  `shell` and `manifest` properties are declared but unused; keep them declared
  so the shell does not warn.
- **Event shapes**: `openwindow>>address,workspace,class,title` (class is
  index 2 of a 4-field parse) and `closewindow>>address`. `Model.eventParts`
  prefers `event.parse()` and falls back to `event.data.split(",")`; keep both
  paths.

## Bash generation gotcha that already bit once

`Model.dimCommand` / `restoreCommand` build multi-line scripts and MUST join with
`"\n"`, never `"; "`. Joining with `"; "` produces `for ...; do;  cmd; done`,
which is a bash syntax error (`bash: syntax error near unexpected token ';'`).
The failure is silent in the shell log because stderr was empty. If you change
either array, run `bash -n` on the generated string before trusting it.

## Testing `Model.js`

`.pragma library` prevents `import`, so strip it and eval:

```bash
node -e '
const fs = require("fs");
let src = fs.readFileSync("Model.js", "utf8").replace(".pragma library", "");
eval(src + "; /* assertions here */");
'
```

Worth covering: the refcount across add/remove/recount (`screensaverWindowsAfter`),
`eventParts` with both a `parse` object and a plain `data` string,
`shellQuote` on a name containing a single quote, and `bash -n` on both command
builders.

## Manual verification loop

The plugin dimmed and restored real hardware during development; there is no
automated test for the QML side.

```bash
# syntax-check the generated bash before running it
# (generate via the node snippet above, then:)
bash -n dim.sh && bash -n restore.sh

# end to end
ddcutil --bus 6 --skip-ddc-checks getvcp 10 --brief
omarchy-launch-screensaver       # expect 1
wtype -k Escape                  # expect the original value back

# recovery path
omarchy-launch-screensaver
omarchy-restart-shell            # expect the original value back, no dismissal

journalctl --user --since "2 min ago" | grep screensaver-dim
```

**Dismiss the screensaver with `wtype -k Escape`.** That is the verified way to
close it during a test run. Two other approaches that do **not** work on
Hyprland 0.56:

- `pkill -f omarchy-screensaver` — hangs the tool session. It matches the
  killing shell's own command line and deadlocks the call.
- `hyprctl closewindow <addr>` — answers `unknown request`. And
  `hyprctl dispatch closewindow class:...` fails because 0.56 parses dispatch as
  Lua (`hl.dispatch(...)`), so the bare keyword form is a syntax error.

There is no equivalent `hyprctl` invocation for a plain window close on this
version, so use synthetic input.

## House style

- Properties are `readonly` unless something writes them (`screensaverWindows`,
  `screensaverWindowCount`, `busy`).
- Comments explain *why*, not what. The 0→1 edge and the state-path location
  each have a comment because the reasoning is not obvious from the code.
- Monitor names come from the compositor and may contain spaces; every
  interpolation goes through `shellQuote` or explicit quoting. Keep it that way.
- After editing, run `omarchy plugin validate` and restart the shell, then
  confirm in the log rather than assuming.
## Repository workflow

This plugin lives in its own private GitHub repository
(`joschariedl/derfleischmann.screensaver-dim`). Any change made here must be committed, pushed to that
repository, and merged into the default branch (`main`) automatically — do
not leave changes uncommitted or only local. Commit with a clear message, push
the branch, and merge (fast-forward when possible) so the repository stays in
sync with this working copy.
