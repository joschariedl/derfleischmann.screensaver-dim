import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Model.js" as Model

// A headless singleton: watches for the Omarchy screensaver window, records the
// current brightness of every enabled monitor, drops them to `dimPercent`, then
// puts the recorded values back when the last screensaver window closes.
//
// The service is constructed with no QML parent (third-party services are
// created with createObject(null)), and omarchy-shell keeps it alive in its
// service map. `keepLoaded` in the manifest stops a plugin hot-reload from
// tearing it down mid-screensaver.
Item {
  id: root

  // Injected by omarchy-shell. Unused today, declared so the shell does not
  // warn, and available if the plugin later needs to surface settings.
  property var shell: null
  property var manifest: null

  readonly property string brightnessBin: "omarchy-brightness-display"
  readonly property int dimPercent: 1
  readonly property bool noOsd: true

  // Outside ~/.config on purpose: writing into the plugins tree would trigger a
  // plugin rescan, which would rebuild this service.
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || root.home + "/.local/state") + "/derfleischmann.screensaver-dim"
  readonly property string statePath: stateDir + "/brightness"
  readonly property string home: Quickshell.env("HOME")
  readonly property string togglesDir: (Quickshell.env("XDG_STATE_HOME") || root.home + "/.local/state") + "/omarchy/toggles"
  readonly property string screensaverDisabledPath: togglesDir + "/screensaver-off"

  // address -> true, mirroring the idle service's bookkeeping so several
  // screensaver windows on different monitors dim once and restore once.
  property var screensaverWindows: ({})
  property int screensaverWindowCount: 0

  // Tracks whether we're currently dimmed (have saved state)
  property bool isDimmed: false

  // Mirrors the screensaver-off toggle file's existence (see FileView below).
  property bool screensaverDisabled: false

  // Serializes dim/restore so a quick open-then-close cannot interleave the two
  // Process runs and restore a stale value over a fresh one.
  property bool busy: false

  function log(message) {
    console.log("screensaver-dim:", message)
  }

  // The shell can start while a screensaver is already up, leaving 1% behind
  // with nothing left to close it. Put the recorded values back on startup.
  Component.onCompleted: {
    root.log("service started, state path " + root.statePath)
    // The stuck-state check runs first so a toggle-while-running situation is
    // logged; the restore itself stays unconditional (it is a no-op without a
    // state file, and it is the only recovery from a restart mid-screensaver).
    root.checkForStuckState()
    root.restoreBrightness("startup")
  }

  function eventParts(event, count) {
    return Model.eventParts(event, count)
  }

  function handleHyprlandEvent(event) {
    var name = String(event && event.name ? event.name : "")

    if (name === "openwindow") {
      // openwindow>>address,workspace,class,title
      var open = root.eventParts(event, 4)
      if (String(open[2] || "") === Model.screensaverClass) {
        root.handleScreensaverWindowOpened(String(open[0] || ""))
      }
    } else if (name === "closewindow") {
      // closewindow>>address
      var close = root.eventParts(event, 1)
      var address = String(close[0] || "")
      if (root.screensaverWindows[address]) root.handleScreensaverWindowClosed(address)
    }
  }

  function handleScreensaverWindowOpened(address) {
    var next = Model.screensaverWindowsAfter(root.screensaverWindows, address, true)
    root.screensaverWindows = next.windows
    root.screensaverWindowCount = next.count

    // Only the 0 -> 1 edge dims, so a second screensaver monitor does not
    // overwrite the saved brightness with the already-dimmed value.
    if (next.count === 1) root.dimBrightness("screensaver-opened")
  }

  function handleScreensaverWindowClosed(address) {
    var next = Model.screensaverWindowsAfter(root.screensaverWindows, address, false)
    root.screensaverWindows = next.windows
    root.screensaverWindowCount = next.count

    if (next.count === 0) root.restoreBrightness("screensaver-closed")
  }

  function dimBrightness(reason) {
    if (root.busy) {
      root.log("skip dim (" + reason + "), busy")
      return
    }
    root.busy = true
    root.log("dimming to " + root.dimPercent + "% (" + reason + ")")
    dimProcess.command = ["bash", "-lc", Model.dimCommand(root.brightnessBin, root.statePath, root.dimPercent, root.noOsd)]
    dimProcess.running = true
  }

  function restoreBrightness(reason) {
    if (root.busy) {
      root.log("skip restore (" + reason + "), busy")
      return
    }
    root.busy = true
    root.log("restoring saved brightness (" + reason + ")")
    restoreProcess.command = ["bash", "-lc", Model.restoreCommand(root.brightnessBin, root.statePath, root.noOsd)]
    restoreProcess.running = true
  }

  function isScreensaverDisabled() {
    // Toggle file exists (screensaver disabled) when it's created
    return root.screensaverDisabled
  }

  function checkForStuckState() {
    // If screensaver is disabled but we still have dimmed state or tracked windows,
    // this is a stuck state from toggling while screensaver was running
    if (root.isScreensaverDisabled() && (root.isDimmed || root.screensaverWindowCount > 0)) {
      root.log("detected stuck state: screensaver disabled but still dimmed/tracked (windows=" + root.screensaverWindowCount + ", dimmed=" + root.isDimmed + ")")
      root.restoreBrightness("screensaver-disabled-while-running")
      root.screensaverWindows = ({})
      root.screensaverWindowCount = 0
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.handleHyprlandEvent(event) }
  }

  Process {
    id: dimProcess
    stdout: StdioCollector {
      onStreamFinished: root.log("dim finished: " + this.text)
    }
    stderr: StdioCollector {
      onStreamFinished: root.log("dim stderr: " + this.text)
    }
    onExited: function(exitCode, exitStatus) {
      root.busy = false
      if (exitCode === 0) {
        root.isDimmed = true
      }
      root.log("dim exitCode=" + exitCode + " status=" + exitStatus)
    }
  }

  Process {
    id: restoreProcess
    stdout: StdioCollector {
      onStreamFinished: root.log("restore finished: " + this.text)
    }
    stderr: StdioCollector {
      onStreamFinished: root.log("restore stderr: " + this.text)
    }
    onExited: function(exitCode, exitStatus) {
      root.busy = false
      root.isDimmed = false
      root.log("restore exitCode=" + exitCode + " status=" + exitStatus)
    }
  }

  FileView {
    id: screensaverToggleFile
    path: root.screensaverDisabledPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.screensaverDisabled = true
      root.checkForStuckState()
    }
    onFileChanged: reload()
    onLoadFailed: {
      root.screensaverDisabled = false
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: root.checkForStuckState()
  }
}