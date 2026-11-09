import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar's stay-awake icon. The installer removes StayAwake from
// omarchy.indicators so this is the only coffee mug on the bar; it shows only
// while stay-awake is on, like the native indicator it replaces.
//
// State comes from the same files Omarchy and live-mode write, so it works
// even when the mega-caffeine binary is not installed (live-mode-only setup).
BarIndicator {
  id: root
  moduleName: "mosquito.mega-caffeine"

  readonly property string stateHome: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
  readonly property string stayAwakePath: stateHome + "/omarchy/indicators/stay-awake"
  readonly property string liveModePath: stateHome + "/live-mode/active"
  readonly property string caffeineStatePath: stateHome + "/caffeine/state"

  property bool stayAwake: false
  property bool liveMode: false
  property bool megaOn: false
  property bool blinkOn: true

  visible: root.stayAwake
  active: root.stayAwake
  activeText: "\uef59"
  inactiveText: "\uef59"
  activeTooltipText: I18n.t("bar.allowIdleLock")
  inactiveTooltipText: I18n.t("bar.stayAwake")
  // Plain stay-awake keeps the normal foreground; coffee mode is red, and live
  // mode blinks red/white like the session frame.
  useActiveColor: root.liveMode ? root.blinkOn : root.megaOn

  function reloadAll() {
    stayAwakeView.reload()
    liveModeView.reload()
    caffeineStateView.reload()
  }

  FileView {
    id: stayAwakeView
    path: root.stayAwakePath
    watchChanges: true
    printErrors: false
    onLoaded: root.stayAwake = true
    onLoadFailed: root.stayAwake = false
    onFileChanged: reload()
  }

  FileView {
    id: liveModeView
    path: root.liveModePath
    watchChanges: true
    printErrors: false
    onLoaded: root.liveMode = true
    onLoadFailed: root.liveMode = false
    onFileChanged: reload()
  }

  FileView {
    id: caffeineStateView
    path: root.caffeineStatePath
    watchChanges: true
    printErrors: false
    onLoaded: root.megaOn = text().trim() === "on"
    onLoadFailed: root.megaOn = false
    onFileChanged: reload()
  }

  // The state file is a claim, not proof: a reboot leaves "on" behind with no
  // inhibitor running. Any mega-caffeine status call clears that, so ask now
  // and then and let the file watchers pick up the correction.
  Process {
    id: staleProbe
    command: ["bash", "-c", "command -v mega-caffeine >/dev/null 2>&1 && mega-caffeine --status >/dev/null 2>&1"]
    onExited: root.reloadAll()
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: if (!staleProbe.running) staleProbe.running = true
  }

  Timer {
    interval: 600
    running: root.liveMode
    repeat: true
    onTriggered: root.blinkOn = !root.blinkOn
  }

  ShellIpc {
    target: "mosquito.mega-caffeine"

    function refresh(): void {
      root.reloadAll()
    }
  }

  onPressed: function() {
    if (root.bar) root.bar.run("omarchy-shell -q idle toggle")
  }
}
