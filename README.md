# derfleischmann.screensaver-dim

A headless Omarchy shell plugin that dims your displays to 1% while the Omarchy
screensaver is running, then puts the previous brightness back when it closes.

The screensaver is a terminal window rendering a live clock. An OLED at full
brightness next to a big clock wastes power and glows through the night; at 1%
the clock is still readable and the panel is effectively off.

## Files

| File | Purpose |
|---|---|
| `manifest.json` | Omarchy plugin manifest, `service`-only entry point, `keepLoaded: true` |
| `Service.qml` | The whole service: Hyprland window watcher, dim/restore orchestration, `Process` runs |
| `Model.js` | Pure logic: event parsing, screensaver-window refcounting, bash command builders, shell quoting |

## Behavior

- **Trigger**: any Hyprland window with class `org.omarchy.screensaver`. That
  is the class `omarchy-launch-screensaver` gives the terminal it opens, so this
  covers the idle screensaver, `omarchy-launch-screensaver` run by hand, and
  `omarchy-toggle-screensaver`.
- **On the first screensaver window**: record the current brightness of every
  enabled monitor, then set each to 1%. Recorded values are `monitor=value`
  lines in the state file.
- **On the last screensaver window closing**: replay the recorded values and
  delete the state file. Restoring with no state file is a no-op, so a double
  restore cannot do harm.
- **Multi-monitor**: windows are reference-counted by address. A screensaver on
  two monitors dims once and restores once, when the second one closes. Only the
  0→1 edge dims, so a second window cannot overwrite the saved values with the
  already-dimmed ones.
- **Startup recovery**: if the shell starts while a screensaver is up, the
  brightness would stay at 1% with nothing left to close it. The service
  restores the saved values in `Component.onCompleted`, which covers a shell or
  compositor restart with no extra hook.
- **Disabled-while-running safety net**: `omarchy-toggle-screensaver` only
  flips a flag; it does not close a running screensaver window, so a toggle
  while the screensaver is up used to leave the display stuck at 1% (the
  `closewindow` restore never fires). The service watches the `screensaver-off`
  toggle file (`~/.local/state/omarchy/toggles/screensaver-off`) with a
  `FileView` plus a slow poll; if the toggle flips while the service is dimmed
  or still tracking windows, it restores immediately instead of waiting for a
  close that never comes.
- **No OSD**: `--no-osd` is passed so no brightness popup appears behind the
  screensaver or on wake.

## Settings

Edit the properties at the top of `Service.qml`:

```qml
readonly property int  dimPercent: 1
readonly property bool noOsd: true
```

`dimPercent` is passed straight through to `omarchy-brightness-display`, so any
value it accepts works. `noOsd: false` restores the on-screen indicator.

## Install

The plugin is installed by hand, not from git, so `omarchy plugin add/update`
(which need a remote) do not apply. To install elsewhere:

1. Copy this directory to `~/.config/omarchy/plugins/derfleischmann.screensaver-dim/`.
2. Add the enablement entry to `~/.config/omarchy/shell.json`:

```json
"plugins": [
  { "id": "derfleischmann.screensaver-dim" }
]
```

3. Validate and load:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/derfleischmann.screensaver-dim
omarchy-restart-shell
```

To remove, drop the directory and the `plugins[]` entry, then restart the shell.

## Verify

```bash
# before
ddcutil --bus 6 --skip-ddc-checks getvcp 10 --brief     # VCP 10 C 80 100

omarchy-launch-screensaver
ddcutil --bus 6 --skip-ddc-checks getvcp 10 --brief     # VCP 10 C 1 100
cat ~/.local/state/derfleischmann.screensaver-dim/brightness

# dismiss the screensaver (mouse, keypress, or: wtype -k Escape)
ddcutil --bus 6 --skip-ddc-checks getvcp 10 --brief     # back to 80

journalctl --user --since "5 min ago" | grep screensaver-dim
```

Logs read `dimming to 1% (screensaver-opened)` and
`restoring saved brightness (screensaver-closed)`.

## Hardware note

Brightness goes through `omarchy-brightness-display`, which routes internal
panels to `brightnessctl` and external DDC/CI monitors to `ddcutil`. This was
developed against a single external LG ULTRAGEAR over HDMI
(`ddcutil --bus 6 --skip-ddc-checks getvcp 10 --brief`). On a laptop panel the
same code applies, but the internal backlight clamps differently and DDC is not
involved.

Keyboard backlight is deliberately untouched: locking the screen already drives
it via `omarchy-brightness-keyboard`, and fighting that would leave the keyboard
dark after a lock.