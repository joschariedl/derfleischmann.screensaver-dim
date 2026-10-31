.pragma library

// Pure helpers for the screensaver dim service. Everything here is a function of
// its arguments so the QML layer only has to orchestrate calls.

var screensaverClass = "org.omarchy.screensaver"

// Hyprland delivers window events both as a typed object (with parse()) and, on
// some builds, as a plain string. Mirror the idle service and prefer parse().
function eventParts(event, count) {
  try {
    if (event && event.parse) return event.parse(count)
  } catch (error) {
  }
  return String(event && event.data ? event.data : "").split(",")
}

// Reference-counted set of screensaver window addresses. `visible` adds or
// removes one address; an empty address just recounts, which is what startup
// uses to find out whether the service came up while a screensaver was running.
function screensaverWindowsAfter(windows, address, visible) {
  var key = String(address || "")
  var next = {}
  var count = 0

  for (var existing in windows || {}) {
    if (existing !== key && windows[existing]) {
      next[existing] = true
      count++
    }
  }

  if (visible) {
    if (!key) return { windows: next, count: count }
    next[key] = true
    count++
  }

  return { windows: next, count: count }
}

// A bash body that records every enabled monitor's current brightness into the
// state file and then sets it to `percent`. Quoting is defensive: monitor names
// come from the compositor and may contain spaces.
function dimCommand(brightnessBin, statePath, percent, noOsd) {
  var osd = noOsd ? "--no-osd " : ""
  return [
    "mkdir -p " + shellQuote(dirname(statePath)),
    ": > " + shellQuote(statePath),
    "for m in $(hyprctl monitors -j | jq -r '.[] | select(.disabled != true) | .name'); do",
    "  v=$(" + brightnessBin + " --monitor \"$m\" 2>/dev/null) || continue",
    "  case \"$v\" in (*[!0-9]*|'') continue ;; esac",
    "  printf '%s=%s\\n' \"$m\" \"$v\" >> " + shellQuote(statePath),
    "  " + brightnessBin + " " + osd + "--monitor \"$m\" " + percent + "% >/dev/null 2>&1",
    "done",
  ].join("\n")
}

// A bash body that replays the state file back onto each monitor and removes
// it. Nothing is written when no state exists, so restoring twice is a no-op.
function restoreCommand(brightnessBin, statePath, noOsd) {
  var osd = noOsd ? "--no-osd " : ""
  return [
    "[ -s " + shellQuote(statePath) + " ] || exit 0",
    "while IFS='=' read -r m v; do",
    "  [ -n \"$m\" ] || continue",
    "  " + brightnessBin + " " + osd + "--monitor \"$m\" \"$v%\" >/dev/null 2>&1",
    "done < " + shellQuote(statePath),
    "rm -f " + shellQuote(statePath),
  ].join("\n")
}

function dirname(path) {
  var text = String(path || "")
  var slash = text.lastIndexOf("/")
  if (slash <= 0) return "/"
  return text.slice(0, slash)
}

// Single-quote for bash. Embedded quotes are closed, escaped, reopened.
function shellQuote(value) {
  return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
}