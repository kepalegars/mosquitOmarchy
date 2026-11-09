import Quickshell
import QtQuick

// The live-mode plugin hosts two overlays: the red session frame and the
// module's own Yes/No card. A plugin has one overlay entry point, so this
// thin dispatcher routes the payload to the right child. Both files stay
// separate; nothing else is shared with another module.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property bool opened: frame.opened || confirm.opened

  // A confirm payload always carries a message; the frame only carries
  // {"visible": true|false}.
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.message !== undefined || payload.selectionFile !== undefined || payload.okOnly !== undefined)
      confirm.open(payloadJson)
    else
      frame.open(payloadJson)
  }

  function close() {
    confirm.close()
    frame.opened = false
  }

  function dismiss() {
    confirm.dismiss()
    frame.opened = false
  }

  Frame {
    id: frame
    omarchyPath: root.omarchyPath
    shell: root.shell
    manifest: root.manifest
  }

  Confirm {
    id: confirm
    omarchyPath: root.omarchyPath
    shell: root.shell
    manifest: root.manifest
  }
}
