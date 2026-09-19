import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarIndicator {
  id: root

  readonly property var idleService: bar?.shell?.firstPartyServiceFor("omarchy.idle")

  // Red icon ONLY while Mega caffeine runs. The plain "Allow Idle Lock &
  // Screensaver" stay-awake keeps the normal foreground color instead.
  property bool megaEnabled: false
  property bool liveMode: false
  property bool blinkOn: false
  property int remainingMinutes: 0
  property bool unlimited: false
  property string tooltip: ""

  activeText: "󰅶"
  inactiveText: "󰅶"

  // Live mode (scripts/plugins/live-mode): the icon blinks red/white. Otherwise it's
  // red directly when Mega caffeine runs.
  useActiveColor: root.liveMode ? root.blinkOn : root.megaEnabled

  active: idleService ? idleService.stayAwake : false
  activeTooltipText: tooltip
  inactiveTooltipText: tooltip

  function refresh() {
    statusProc.running = true
  }

  function update(raw) {
    var data = extractData(raw)
    root.megaEnabled = !!data.enabled
    root.liveMode = !!data.liveMode
    root.remainingMinutes = Number(data.remainingMinutes || 0)
    root.unlimited = !!data.unlimited
    root.tooltip = root.liveMode
      ? "Live Mode ON"
      : (root.megaEnabled
          ? (root.unlimited
              ? "Mega caffeine: unlimited"
              : "Mega caffeine: " + root.remainingMinutes + " min remaining")
          : (root.active ? "Allow Idle Lock & Screensaver" : "Stay Awake"))
  }

  // Blink red/white while live mode is active.
  Timer {
    interval: 600
    running: root.liveMode
    repeat: true
    onTriggered: root.blinkOn = !root.blinkOn
  }

  // Keep the remaining-time tooltip fresh while the mode runs. Also poll
  // while the bare stay-awake is active: when Mega caffeine takes over an
  // already-active stay-awake, the file never changes, so no signal fires —
  // this backstop makes sure the red icon still appears promptly.
  Timer {
    interval: 10000
    running: root.megaEnabled || root.active
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()

  // Mega caffeine activates/deactivates by writing the same stay-awake file
  // the idle service watches, so this fires the instant the mode changes.
  Connections {
    target: root.idleService
    ignoreUnknownSignals: true
    function onStayAwakeChanged() { root.refresh() }
  }

  Connections {
    target: root.indicatorHost
    ignoreUnknownSignals: true
    function onRefreshRequested() { root.refresh() }
  }

  Process {
    id: statusProc
    // Live mode (scripts/plugins/live-mode) is tint-free and does not run mega
    // caffeine — when its active flag exists, report it directly so the
    // coffee icon shows red with the "Live Mode ON" tooltip regardless of
    // any caffeine session state.
    command: ["bash", "-lc",
      "if [ -f \"$HOME/.local/state/live-mode/active\" ]; then " +
      "echo '{\"enabled\":true,\"liveMode\":true,\"unlimited\":true,\"stayAwake\":true}'; " +
      "else \"$HOME/.local/bin/mega-caffeine\" --status; fi"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.update(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.megaEnabled = false
    }
  }

  onPressed: function() {
    // While live mode is on, mega caffeine is locked (click does nothing);
    // while a plain caffeine session runs, one click stops it and restores
    // the previous stay-awake state; otherwise it toggles stay-awake directly.
    if (root.liveMode) {
      root.refresh()
    } else if (root.megaEnabled) {
      root.megaEnabled = false
      Quickshell.execDetached(["bash", "-lc", "\"$HOME/.local/bin/mega-caffeine\" off"])
    } else if (root.idleService) {
      root.idleService.setIdleEnabled(root.active)
    }
    root.refresh()
  }
}