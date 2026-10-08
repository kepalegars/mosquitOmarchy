import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root

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
    fixedWidth: root.vertical ? root.barSize : Style.space(44)
    tooltipText: !root.service ? "jamjamjam is starting"
      : (root.analyzing ? "jamjamjam · analyzing… (hold released to stop)"
        : (root.service.recording ? (root.midiMode ? "jamjamjam · recording · MIDI on" : "jamjamjam · recording")
          : "jamjamjam · tap to analyze audio"))

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && root.service) root.service.toggleRecording()
      else root.toggle()
    }

    // The box is SMALLER than the icon it holds, on purpose.
    //
    // The fork is a wide, top-heavy shape: at box size it filled its 20px square
    // edge to edge, and the square itself was taller than the row, so the mark
    // read as sitting too high next to the icons on its right. Shrinking the box
    // and keeping the drawing at its own size centres it without making it
    // smaller — the two were tied together before, so one could not move without
    // the other.
    Item {
      anchors.centerIn: parent
      width: Style.space(14)
      height: Style.space(14)

      // NO backing disc. There used to be one — a `radius: width/2` disc in
      // Util.alpha(Color.background, 0.72) — put there because the bar has no
      // background of its own: it is transparent over the wallpaper, and this
      // theme's red was sampled from that wallpaper, so an unoutlined red note
      // measured ~1:1 against a red patch and disappeared into it.
      //
      // NoteGlyph draws its own black outline now, which is the cheaper answer:
      // no slab of grey behind a 20px mark, and the note keeps the plain red
      // silhouette it had before the disc was introduced. The outline is what
      // separates it from a red background; the red itself carries it on dark
      // ones.
      NoteGlyph {
        // Deliberately LARGER than its parent box, and centred: this is the
        // "shrink the box, not the icon" half. overflow is not set, so the
        // drawing is not clipped.
        anchors.centerIn: parent
        width: Style.space(20)
        height: Style.space(20)
        // The theme's red. Color.urgent IS the theme's `red` key (Color.qml maps
        // red -> urgent), so this follows the theme rather than hardcoding a
        // colour that would look foreign on the next one.
        color: Color.urgent
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