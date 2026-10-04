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

      // A note, DRAWN — one filled silhouette rather than a pile of strokes.
      //
      // The previous attempt was three separate rounded rectangles (stem, flag,
      // head) and it read as a lollipop: the head was a visible circle stuck to
      // a bar, and the flag stuck out at an angle like an antenna. One Shape
      // with a filled outline gives a continuous outline — no seams where two
      // shapes meet, one silhouette to read, and the notehead stays solid
      // because it is part of the path rather than a disc laid on top.
      Canvas {
        id: noteGlyph
        anchors.fill: parent

        // Redrawn on size change: the path is built from fractions of the slot,
        // so it has to be rebuilt when the slot is not the one it was drawn at.
        onPaint: {
          var ctx = getContext("2d");
          ctx.reset();
          const unit = Math.min(width, height);
          if (unit <= 0)
            return ;

          // A quaver, drawn as three filled shapes rather than strokes.
          //
          // Strokes were the earlier attempt and they were the reason it looked
          // wrong: a stroked outline of this size is one or two pixels wide, so
          // the joins either vanished (leaving three disconnected marks) or
          // bloomed (leaving a lumpy blob), and at 20px there is no third
          // outcome. Fills have no width to lose — the shape is either there or
          // it is not, which is the only thing that survives being scaled down.
          //
          // Coordinates are fractions of the slot, so the glyph is the same
          // drawing at every bar size, and the notehead sits at the origin so
          // the stem grows upwards out of it rather than being positioned by
          // hand against it.
          ctx.fillStyle = root.iconColor;

          // Centre the drawing on its own extent rather than trusting the
          // numbers below to be symmetric: `unit` is the smaller of the two
          // dimensions, and the glyph is not centred on the origin, so a fixed
          // offset would drift as the slot changes shape.
          const boxMinX = -0.153, boxMaxX = 0.38;
          const boxMinY = -0.68, boxMaxY = 0.135;
          ctx.translate(unit * (0.5 - (boxMinX + boxMaxX) / 2),
                         unit * (0.5 - (boxMinY + boxMaxY) / 2));
          ctx.scale(unit, unit);

          // Head: an ellipse, laid over on its side and tilted, which is what
          // makes a notehead read as a notehead instead of a bead.
          ctx.save();
          ctx.rotate(-0.20);
          ctx.scale(0.155, 0.105);
          ctx.arc(0, 0, 1, 0, Math.PI * 2);
          ctx.restore();
          ctx.fill();

          // Stem: up the right side of the head. Kept thin — a stem as wide as
          // a third of the head is what made the earlier one look like a bead
          // on a stick.
          ctx.fillRect(0.095, -0.66, 0.06, 0.68);

          // Flag: one closed hook off the top of the stem, outer edge out to
          // the right and down, then back along the inner edge to the stem, so
          // it is a single silhouette with no seam at the join.
          ctx.beginPath();
          ctx.moveTo(0.095, -0.66);
          ctx.bezierCurveTo(0.34, -0.61, 0.37, -0.45, 0.29, -0.33);
          ctx.lineTo(0.145, -0.43);
          ctx.bezierCurveTo(0.27, -0.55, 0.135, -0.59, 0.095, -0.605);
          ctx.closePath();
          ctx.fill();
        }

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Component.onCompleted: requestPaint()

        // Canvas has no `color` property: it is an Item, and the stroke/fill
        // colours live on the context. So the paint function takes it from
        // root directly rather than binding a property that does not exist.
        renderTarget: Canvas.Image
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