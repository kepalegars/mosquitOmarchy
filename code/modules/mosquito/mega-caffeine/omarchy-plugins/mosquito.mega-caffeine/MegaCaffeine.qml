import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The coffee mug, loaded by omarchy.indicators as one of its own indicators.
// The installer names this file (by its path) in the widget's items list in
// place of StayAwake, so it keeps Omarchy's glyph, i18n, reveal and active
// block behaviour and only adds the Mega caffeine / Live Mode state on top.
BarIndicator {
  id: root

  readonly property var idleService: bar?.shell?.firstPartyServiceFor("omarchy.idle")

  property bool megaEnabled: false
  property bool liveMode: false
  property bool blinkOn: false
  property int remainingMinutes: 0
  property bool unlimited: false
  property string megaTooltip: ""

  active: idleService ? idleService.stayAwake : false
  // A mug without a saucer, which drew a line under the cup.
  activeText: "\uef59"
  inactiveText: "\uef59"
  // Live Mode blinks red/white; a plain caffeine session is red; otherwise the
  // native tooltip stays untouched.
  useActiveColor: root.liveMode ? root.blinkOn : root.megaEnabled
  activeTooltipText: root.megaEnabled || root.liveMode ? root.megaTooltip : I18n.t("bar.allowIdleLock")
  inactiveTooltipText: root.megaEnabled || root.liveMode ? root.megaTooltip : I18n.t("bar.stayAwake")

  function toggle() {
    if (root.idleService) root.idleService.setIdleEnabled(root.active)
  }

  function refresh() {
    statusProc.running = true
  }

  function update(raw) {
    var data = extractData(raw)
    root.megaEnabled = !!data.enabled
    root.liveMode = !!data.liveMode
    root.remainingMinutes = Number(data.remainingMinutes || 0)
    root.unlimited = !!data.unlimited
    root.megaTooltip = root.liveMode
      ? "Live Mode ON"
      : (root.unlimited
          ? "Mega caffeine: unlimited"
          : "Mega caffeine: " + root.remainingMinutes + " min remaining")
  }

  Timer {
    interval: 600
    running: root.liveMode
    repeat: true
    onTriggered: root.blinkOn = !root.blinkOn
  }

  // Keep the remaining-time tooltip fresh while a mode runs, and poll while the
  // bare stay-awake is active: when Mega caffeine takes over an already-active
  // stay-awake the file never changes, so no signal fires.
  Timer {
    interval: 10000
    running: root.megaEnabled || root.liveMode || root.active
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()

  // Mega caffeine activates/deactivates by writing the same stay-awake file the
  // idle service watches, so this fires the instant the mode changes.
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
    // Live mode is tint-free and runs no caffeine session: report it directly
    // so the icon shows red with the "Live Mode ON" tooltip.
    command: ["bash", "-lc",
      "if [ -f \"$HOME/.local/state/live-mode/active\" ]; then " +
      "echo '{\"enabled\":true,\"liveMode\":true,\"unlimited\":true}'; " +
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
    // Live mode locks mega caffeine (click only refreshes); a running caffeine
    // session stops on click; otherwise toggle stay-awake like native does.
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
