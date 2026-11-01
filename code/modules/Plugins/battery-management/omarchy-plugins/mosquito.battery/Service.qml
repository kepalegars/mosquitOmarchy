import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "BatteryModel.js" as BatteryModel

// Mosquito battery service — a clone of Omarchy's battery service whose ONLY
// behavioural change is how it decides "AC or battery" before switching the
// power profile.
//
// Upstream uses UPower.onBattery. UPower treats every online power supply as
// external power, including a bus-powered USB-C disk/hub: plugging an external
// HDD could flip onBattery to false for a moment and switch the machine to the
// AC power profile even though the battery was still discharging.
//
// battery-status is our corrected detector: a USB supply only counts when the
// battery is actually charging (or holding a threshold). The service asks it
// with --external (exit 0 = real external power) and switches on that answer.
Item {
  id: root

  property var shell: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property string batteryStatusBin: Quickshell.env("HOME") + "/.local/bin/battery-status"

  readonly property int batteryThreshold: 10
  property string pendingPowerSource: ""

  PersistentProperties {
    id: persisted
    reloadableId: "mosquito-battery"
    property bool notifiedLowBattery: false
  }

  function batteryPercentage() {
    return BatteryModel.batteryPercentage(UPower.displayDevice)
  }

  function isDischarging() {
    return BatteryModel.isDischarging(UPower.displayDevice, UPower.onBattery, UPowerDeviceState.Discharging)
  }

  function checkBattery() {
    var state = BatteryModel.shouldWarnLowBattery(UPower.displayDevice, UPower.onBattery, UPowerDeviceState.Discharging, batteryThreshold, persisted.notifiedLowBattery)
    persisted.notifiedLowBattery = state.notifiedLowBattery
    if (state.notify) sendLowBatteryWarning(state.level)
  }

  function sendLowBatteryWarning(level) {
    if (warningProcess.running) return
    warningProcess.command = [
      "omarchy-battery-low",
      String(level)
    ]
    warningProcess.running = true
  }

  // Ask the corrected detector, never UPower.onBattery. A false AC event (an
  // external disk, a USB-C hub) then leaves the profile alone.
  function applyPowerProfile() {
    if (externalPowerProcess.running) return
    externalPowerProcess.running = true
  }

  function runPendingPowerProfile() {
    powerProfileProcess.command = ["omarchy-powerprofiles-set", pendingPowerSource]
    pendingPowerSource = ""
    powerProfileProcess.running = true
  }

  Process { id: warningProcess }

  Process {
    id: externalPowerProcess
    command: [root.batteryStatusBin, "--external"]
    onExited: function(exitCode) {
      root.pendingPowerSource = exitCode === 0 ? "ac" : "battery"
      if (!powerProfileProcess.running) root.runPendingPowerProfile()
    }
  }

  Process {
    id: powerProfileProcess
    onExited: if (root.pendingPowerSource !== "") root.runPendingPowerProfile()
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkBattery()
  }

  Connections {
    target: UPower
    function onOnBatteryChanged() {
      root.checkBattery()
      root.applyPowerProfile()
    }
  }
}
