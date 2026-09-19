import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.power"
  ipcTarget: "omarchy.power"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false
  readonly property bool showPercentage: setting("showPercentage", false) === true
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0
  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // ---- custom.power state (polled via power-helper) ---------------------
  property bool ultraSaveOn: false
  property bool conservationOn: false
  property int chargeLimitEnd: 100
  property string liveProfile: ""
  property bool chargeLimitNotified: false

  // Bar icon color, by power profile:
  //   eco (power-saver) = green · performance = blue · ultra-save = orange ·
  //   balanced = the normal icon color (white on dark / adaptive).
  // Ultra-save forces the power-saver profile, so its orange must win over the
  // green. The neutral fallback uses bar.barForeground (NOT bar.foreground):
  // with a transparent bar that is the wallpaper-adaptive contrast color that
  // all the other Omarchy icons inherit — the fixed theme color would stay
  // light on a light wallpaper (invisible battery icon).
  readonly property color batteryGlyphColor: {
    if (root.ultraSaveOn) return Qt.rgba(0.95, 0.55, 0.15, 1)
    if (root.liveProfile === "performance") return Qt.rgba(0.30, 0.60, 0.95, 1)
    if (root.liveProfile === "power-saver") return Qt.rgba(0.35, 0.85, 0.42, 1)
    return root.bar ? root.bar.barForeground : Color.foreground
  }

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  // Plugging a charger must clear the stock "Time to recharge!" critical toast
  // (omarchy-battery-low). UPower.onBattery's change signal is not always
  // delivered, so ALSO react to our own `charging` becoming true, and dismiss
  // the toast a couple of times because the plugin may send it right around the
  // plug event.
  onChargingChanged: {
    if (charging) root.onAcPlugged()
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.barForeground : Color.foreground
  }

  // Cute agent-flavored phrases shown in the hero status line, rotated on a
  // timer so the panel feels alive when current is flowing (either direction).
  readonly property var chargingPhrases: [
    "Pumping power",
    "Injecting electrons",
    "Pouring juice",
    "Amassing watts",
    "Hoarding joules",
    "Sucking volts",
    "Topping reserves",
    "Soaking amps",
    "Inhaling kilowatts"
  ]
  readonly property var onBatteryPhrases: [
    "Slurping power",
    "Spending joules",
    "Draining watts",
    "Burning electrons",
    "Sipping juice",
    "Spending coulombs",
    "Bleeding amps",
    "Guzzling volts",
    "Munching reserves"
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current power state.
  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  readonly property string heroStatusText: {
    if (fullyCharged) return "Fully charged"
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return modeLabel()
  }

  function refresh() {
    if (!batteryPresent) return

    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (!systemProc.running) systemProc.running = true
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    if (Object.keys(next).length === 0) return
    if (targetName === "battery") batteryInfo = next
    else systemInfo = next
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    // A manually activated power plan wins over ultra-save: disable ultra-save
    // first (it forces the power-saver profile and CPU caps), then apply the
    // chosen plan. power-helper uses the NOPASSWD sudoers entry for ultra-save.
    if (root.ultraSaveOn && profile !== "power-saver") {
      actionProc.command = [
        "bash", "-c",
        "power-helper ultrasave off; omarchy-powerprofiles-set " + (root.discharging ? "battery" : "ac") + " " + profile
      ]
    } else {
      actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    }
    actionProc.running = true
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  // ---- custom.power: ultra-save + charge conservation state ------------

  function refreshPowerStatus() {
    if (!ultraStatusProc.running) ultraStatusProc.running = true
    if (!chargeStatusProc.running) chargeStatusProc.running = true
    checkChargeLimitReached()
  }

  function updateUltraStatus(raw) {
    var next = Model.parseKeyValue(raw)
    if (Object.keys(next).length === 0) return
    root.ultraSaveOn = next.state === "on"
    if (next.profile) root.liveProfile = next.profile
  }

  function updateChargeStatus(raw) {
    var next = Model.parseKeyValue(raw)
    if (Object.keys(next).length === 0) return
    root.conservationOn = next.state === "on"
    var end = parseInt(next.end, 10)
    if (!isNaN(end) && end > 0 && end < 100) root.chargeLimitEnd = end
    else root.chargeLimitEnd = 100
  }

  function toggleConservation() {
    if (conservationActionProc.running) return
    var next = !root.conservationOn
    conservationActionProc.command = ["power-helper", "charging", "conservation", next ? "on" : "off"]
    conservationActionProc.running = true
  }

  function toggleUltraSave() {
    if (ultraActionProc.running) return
    ultraActionProc.command = ["power-helper", "ultrasave", "toggle"]
    ultraActionProc.running = true
  }

  // The single manual notification: fire once when the battery reaches the
  // firmware charge ceiling (80% with conservation on). The flag resets ONLY
  // on raw AC plug-in (UPower.onBatteryChanged → plugged) or when conservation
  // turns off — NOT when the held charge dips a fraction under the ceiling,
  // which would re-fire the toast on 80% overshoot/undershoot oscillation.
  function checkChargeLimitReached() {
    if (!root.conservationOn || root.chargeLimitEnd >= 100) {
      root.chargeLimitNotified = false
      return
    }
    var pct = root.batteryFraction * 100
    if (pct >= root.chargeLimitEnd && !root.chargeLimitNotified && !root.discharging) {
      root.chargeLimitNotified = true
      notifyChargeLimitReached(root.chargeLimitEnd)
    }
  }

  // One notification per charger plug-in: a fresh plug (AC) opens the window
  // again, regardless of the current level.
  //
  // While on wall power ultra-save (dimmed screen + CPU caps + power-saver) is
  // pointless, so drop it automatically on plug-in. The stock battery service
  // also leaves its critical "Time to recharge!" toast on screen because
  // critical popups never auto-expire — dismiss it too, so the plug clears the
  // alert instead of leaving it stuck.
  Connections {
    target: UPower
    function onOnBatteryChanged() {
      if (!UPower.onBattery) root.onAcPlugged()
    }
  }

  function onAcPlugged() {
    root.chargeLimitNotified = false
    if (acPowersaveProc.running) return
    acPowersaveProc.command = [
      "bash", "-c",
      "if power-helper ultrasave status 2>/dev/null | grep -q '^state\ton$'; then power-helper ultrasave off; fi; " +
      // Dismiss now and once more shortly after: the stock service may emit the
      // critical toast a beat after the AC event, and a critical toast ignores
      // its own timeout.
      "omarchy-notification-dismiss 'Time to recharge!'; " +
      "( sleep 2; omarchy-notification-dismiss 'Time to recharge!' ) &"
    ]
    acPowersaveProc.running = true
  }

  Process {
    id: acPowersaveProc
    onExited: root.refreshPowerStatus()
  }

  function notifyChargeLimitReached(limit) {
    if (chargeNotifyProc.running) return
    var glyph = root.batteryIcon() || "󰂁"
    chargeNotifyProc.command = [
      "omarchy-notification-send",
      "Charge limit reached",
      "Battery held at " + limit + "%",
      "-g", glyph, "-u", "low", "-t", "0"
    ]
    chargeNotifyProc.running = true
  }

  IpcHandler {
    target: "omarchy.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }

      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  // custom.power status: ultra-save + charge conservation. Runs persistently
  // (even when the panel is closed) so the bar icon color stays correct and
  // the "charge limit reached" notification can fire while charging.
  Process {
    id: ultraStatusProc
    command: ["power-helper", "ultrasave", "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateUltraStatus(text) }
  }

  Process {
    id: chargeStatusProc
    command: ["power-helper", "charging", "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateChargeStatus(text) }
  }

  Process {
    id: conservationActionProc
    onExited: root.refreshPowerStatus()
  }

  Process {
    id: ultraActionProc
    onExited: root.refreshPowerStatus()
  }

  Process {
    id: chargeNotifyProc
  }

  Timer {
    id: powerStatusTimer
    interval: 4000
    running: batteryPresent
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshPowerStatus()
  }

  // Rotate the status phrase while the panel is open and we're in a
  // rotating state (charging or on battery). The text swap is wrapped in a
  // fade so the changeover reads as one organism rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  // If we leave a rotating state mid-swap, halt the animation and snap back
  // to full opacity so "FULLY CHARGED" is legible immediately rather than
  // appearing dimmed.
  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    foreground: root.batteryGlyphColor
    text: root.showPercentage && !vertical
      ? Math.round(root.batteryFraction * 100) + "% " + root.batteryIcon()
      : root.batteryIcon()
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    tooltipText: ""
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Battery"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.batteryInfo.percentage || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Battery progress bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Stats ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the section never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Battery size"; value: root.batteryInfo.size || "" }
            InfoPair { label: "Charge cycles"; value: root.batteryInfo.cycles || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? "Charge limit" : (root.discharging ? "Time left" : "Time to full")
              value: root.chargeThresholdActive ? (root.batteryInfo.threshold || "-") : (root.batteryFlowIdle ? "-" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              label: root.chargeThresholdActive ? "Battery state" : (root.discharging ? "Discharging" : "Charging")
              value: root.chargeThresholdActive ? "Holding" : (root.batteryFull ? "-" : (root.batteryInfo.rate || ""))
            }
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                // Ultra-save forces the power-saver profile internally, but it
                // is its OWN mode: while it is active, no standard power plan is
                // shown as selected (only the Ultra-save toggle is checked).
                active: !root.ultraSaveOn && root.activeProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  } else {
                    // Leaving with the mouse must drop the highlight: otherwise
                    // the last hovered box keeps a fake "selected" look — very
                    // visible when ultra-save is on and no plan is actually
                    // selected. Keyboard navigation re-arms the cursor on move.
                    root.cursorActive = false
                  }
                }
              }
            }
          }
        }

        // ---------- Battery conservation + Ultra-save toggles ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "BATTERY & POWER"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Toggle {
            width: parent.width
            label: "Battery conservation"
            description: root.conservationOn
              ? "Hold at " + root.chargeLimitEnd + "% to protect battery health"
              : "Limit charging to 80% to protect battery health"
            checked: root.conservationOn
            foreground: root.bar.foreground
            accent: Color.accent
            fontFamily: root.bar.fontFamily
            onClicked: root.toggleConservation()
          }

          Toggle {
            width: parent.width
            label: "Ultra-save"
            description: root.ultraSaveOn
              ? "Low-power mode active (~6-8W)"
              : "Extreme battery saving, ~6-8W"
            checked: root.ultraSaveOn
            foreground: root.bar.foreground
            accent: Color.accent
            fontFamily: root.bar.fontFamily
            onClicked: root.toggleUltraSave()
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
