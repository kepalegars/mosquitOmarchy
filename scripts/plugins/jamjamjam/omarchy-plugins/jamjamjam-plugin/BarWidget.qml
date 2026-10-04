import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root

  // The icon takes the theme's foreground rather than a fixed colour, so it is
  // legible on any theme and does not read as an error state. Pitchfork does
  // the same and only switches to the accent when its reading is in tune.
  readonly property color iconColor: Color.foreground
  moduleName: "jamjamjam-plugin"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool midiMode: service ? service.midiMode : false
  readonly property bool midiConnected: service ? service.midiConnected : false
  readonly property bool analyzing: service ? service.hold === true : false

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

  implicitWidth: root.vertical ? root.barSize : Style.space(44)
  implicitHeight: button.implicitHeight

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
    fixedWidth: root.vertical ? root.barSize : Style.space(44)
    tooltipText: !root.service ? "jamjamjam is starting"
      : (root.analyzing ? "jamjamjam · analyzing… (hold released to stop)"
        : (root.service.recording ? (root.midiMode ? "jamjamjam · recording · MIDI on" : "jamjamjam · recording")
          : "jamjamjam · tap to analyze audio"))

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && root.service) root.service.toggleRecording()
      else root.toggle()
    }

    Item {
      anchors.centerIn: parent
      width: Style.space(20)
      height: Style.space(20)

      // A quaver, DRAWN rather than borrowed from a font.
      //
      // It was the ♪ glyph in Color.urgent, which ties the icon to a font
      // revision carrying that codepoint at a readable weight and to the theme
      // being red. Every dimension here is a fraction of the icon slot, so it
      // stays proportional at any bar size.
      //
      // The head is an ellipse and the stem and flag are rounded bars, so the
      // whole mark reads as one shape rather than three strokes. The theme
      // colour is inherited rather than hard-coded: the icon says "music", not
      // "an error", and the pulsing ring beside it is what signals analysis.
      Item {
        id: quaver
        anchors.fill: parent

        readonly property real unit: Math.min(width, height)
        readonly property real stemW: Math.max(1, unit * 0.085)
        readonly property real headW: unit * 0.34
        readonly property real headH: unit * 0.255
        readonly property real stemX: quaver.width / 2 + quaver.unit * 0.085
        // The flag sweeps from the top of the stem and stops a third of the way
        // down, which is what makes it read as a flag rather than a second stem.
        readonly property real flagW: unit * 0.3
        readonly property real flagH: Math.max(1, unit * 0.075)

        // Stem. Drawn first so the head overlaps it cleanly at the join.
        Rectangle {
          x: quaver.stemX - quaver.stemW / 2
          y: quaver.unit * 0.12
          width: quaver.stemW
          height: quaver.unit * 0.6
          radius: quaver.stemW / 2
          color: root.iconColor
        }

        // Flag: a bar off the top of the stem, leaning down and to the right.
        Rectangle {
          x: quaver.stemX - quaver.stemW / 2
          y: quaver.unit * 0.12
          width: quaver.flagW
          height: quaver.flagH
          radius: quaver.flagH / 2
          color: root.iconColor
          rotation: 28
        }

        // Head: an ellipse at the foot of the stem, the way a notehead sits —
        // tilted, not upright.
        Rectangle {
          x: quaver.stemX - quaver.headW - quaver.unit * 0.02
          y: quaver.unit * 0.72 - quaver.headH / 2
          width: quaver.headW
          height: quaver.headH
          radius: quaver.headH / 2
          color: root.iconColor
          rotation: -20
        }
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
        visible: root.analyzing
        // Pulses by thickness, never by opacity, so the ring always reads as
        // the solid theme red instead of fading to a pale wash.
        SequentialAnimation on border.width {
          running: analyzeRing.visible
          loops: Animation.Infinite
          NumberAnimation { to: 3; duration: 320 }
          NumberAnimation { to: 1; duration: 320 }
        }
      }

      // Small pulsing dot when recording
      Rectangle {
        id: recDot
        width: Style.space(5)
        height: Style.space(5)
        radius: width / 2
        anchors.top: parent.top
        anchors.right: parent.right
        visible: root.service ? root.service.recording : false
        color: Color.urgent

        SequentialAnimation on opacity {
          running: recDot.visible
          loops: Animation.Infinite
          NumberAnimation { to: 0.2; duration: 500 }
          NumberAnimation { to: 1.0; duration: 500 }
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