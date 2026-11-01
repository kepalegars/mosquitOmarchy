import Quickshell
import Quickshell.Wayland
import QtQuick

// Live-mode red frame overlay.
// A thin (2px) red line around the whole screen, matching the Hyprland window
// border weight, drawn while live mode is active. The layer is not focusable
// and excludes nothing, so it never intercepts keyboard or pointer input.
// Invoked by live-mode via:
//   omarchy-shell shell summon mosquito.livemode '{"visible":true|false}'

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  readonly property color liveColor: "#ff2d2d"
  readonly property int frameWidth: 2

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root.opened = payload.visible !== false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "mosquito.livemode")
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "mosquito-livemode"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.focusable: false
    exclusionMode: ExclusionMode.Ignore
    // Visual-only surface: keep the layer-shell input region empty so the
    // frame never blocks pointer clicks to the bar or desktop below it.
    mask: Region {}

    Rectangle {
      anchors.fill: parent
      color: "transparent"
      border.color: root.liveColor
      border.width: root.frameWidth
    }
  }
}