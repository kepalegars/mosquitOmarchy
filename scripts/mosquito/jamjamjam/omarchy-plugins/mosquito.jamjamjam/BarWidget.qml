import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root

  moduleName: "mosquito.jamjamjam"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool midiMode: service ? service.midiMode : false
  readonly property bool midiConnected: service ? service.midiConnected : false
  readonly property bool holdAnalyzing: service ? service.hold === true : false
  // Capture runs while the panel is open, the hold is active, or the TUI is
  // analyzing. Any of those means the plugin is listening, so the fork blinks.
  readonly property bool listening: service ? (service.hold === true || (service.recording === true && service.paused !== true)) : false
  property bool blinkOn: false

  // While jamjamjam listens, the fork alternates white/red. Reset when it stops
  // so it always comes back to a steady white mark.
  Timer {
    interval: 420
    repeat: true
    running: root.listening
    onRunningChanged: if (!running) root.blinkOn = false
    onTriggered: root.blinkOn = !root.blinkOn
  }

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }
  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }
  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
    target.service = root.service
  }

  // Same square slot as the other bar icons, in either orientation.
  implicitWidth: root.barSize
  // The BAR's height, not the button's implicit height. The button sizes itself
  // around its 20px icon box, so taking the widget's height from it made this one
  // taller than its neighbours in the same row and the fork sat high.
  implicitHeight: root.barSize

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onServiceChanged: injectPanel()

  IpcHandler {
    target: root.moduleName + ".panel"
    function open(): string { root.open(); return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string { root.toggle(); return "ok" }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.barSize
    tooltipText: !root.service ? "jamjamjam is starting"
      : (root.holdAnalyzing ? "jamjamjam · analyzing… (hold released to stop)"
        : (root.service.recording ? (root.service.paused ? "jamjamjam · paused" : (root.midiMode ? "jamjamjam · analyzing · MIDI on" : "jamjamjam · analyzing"))
          : "jamjamjam · tap to analyze audio"))

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && root.service) root.service.toggleRecording()
      else root.toggle()
    }

    // The 14px box is only the centring/ring anchor; the 16px fork overflows
    // it slightly, which keeps the mark optically centred in the bar slot.
    Item {
      anchors.centerIn: parent
      width: Style.space(14)
      height: Style.space(14)

      // White at rest, so the fork matches the other monochrome bar icons.
      NoteGlyph {
        id: noteGlyph
        anchors.centerIn: parent
        // 16px matches the other bar icons. The old 20px fork filled the row
        // and read as a larger, unrelated mark.
        width: Style.space(16)
        height: Style.space(16)
        // White at rest; white/red blink while the plugin is listening.
        color: root.listening && root.blinkOn ? Color.urgent : "#ffffff"
      }

// Analysis indicator: a pulsing ring while the analyze hold is active (the
// global Right Ctrl hold), so the hold is visible from the bar even when the
// TUI window is not focused.
      Rectangle {
        id: analyzeRing
        anchors.fill: parent
        anchors.margins: -Style.space(2)
        radius: Style.cornerRadius
        color: "transparent"
        border.color: Color.urgent
        border.width: 1
        visible: root.holdAnalyzing
        // Pulses by thickness, never by opacity, so the ring always reads as
        // the solid theme red instead of fading to a pale wash.
        SequentialAnimation on border.width {
          running: analyzeRing.visible
          loops: Animation.Infinite
          NumberAnimation { to: 3; duration: 320 }
          NumberAnimation { to: 1; duration: 320 }
        }
      }

      // Small badge when MIDI device connected
      Rectangle {
        width: Style.space(6)
        height: Style.space(6)
        radius: width / 2
        anchors.top: parent.top
        anchors.left: parent.left
        visible: root.midiConnected
        color: Color.accent
      }
    }
  }
}