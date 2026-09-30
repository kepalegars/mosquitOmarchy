import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Native confirmation dialog styled like Omarchy's "sudo"/update flow:
// a square card with the message and two buttons (Yes / No), no auto "…"
// appended (unlike the dmenu input/select header which always adds one).
// Invoked by mega-caffeine via:
//   omarchy-shell shell summon mosquito.confirm '{"message":"...","selectionFile":"...","doneFile":"..."}'
// The answer (or empty on cancel) is written to selectionFile, then doneFile
// is touched so the caller stops waiting.
//
// Info mode: when the payload carries "okOnly": true (and optional "okLabel"),
// the card shows a single OK button; Enter, Escape or a click act as OK and
// write "ok". Used for non-question notices (Readme, empty states, launch
// reconciliation) where a Yes/No pair would be noise.
//
// The two-button mode's labels default to "No"/"Yes" but can be overridden
// with optional "noLabel"/"yesLabel" payload fields — the written answer
// ("no"/"yes") and button position (left/right) stay the same either way,
// only the displayed text changes, so existing callers are unaffected.

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string message: ""
  property string selectionFile: ""
  property string doneFile: ""
  property bool okOnly: false
  property string okLabel: "OK"
  property string noLabel: "No"
  property string yesLabel: "Yes"
  property string fontFamily: Style.font.menuFamily

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int cardWidth: Math.max(Math.min(Style.space(460), panel.width - Style.gapsOut * 2), Style.space(120))

  property int selectedIndex: 0

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.fontFamily) root.fontFamily = payload.fontFamily
    root.message = String(payload.message || "Confirm?")
    root.selectionFile = String(payload.selectionFile || "")
    root.doneFile = String(payload.doneFile || "")
    root.okOnly = payload.okOnly === true
    root.okLabel = String(payload.okLabel || "OK")
    root.noLabel = String(payload.noLabel || "No")
    root.yesLabel = String(payload.yesLabel || "Yes")
    root.selectedIndex = 0
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "mosquito.confirm")
  }

  function finish(pick) {
    var answer = root.okOnly ? "ok" : (pick === "yes" ? "yes" : "")
    var cmd = (answer && root.selectionFile)
      ? ["bash", "-c", "printf '" + answer + "\\n' > \"" + root.selectionFile + "\"; : > \"" + root.doneFile + "\""]
      : ["bash", "-c", ": > \"" + root.doneFile + "\""]
    try { Quickshell.execDetached(cmd) } catch (e) {}
    root.dismiss()
  }

  function handleKey(event) {
    if (!root.opened) return false
    if (root.okOnly) {
      if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        root.finish("ok")
        return true
      }
      return false
    }
    if (event.key === Qt.Key_Escape) { root.finish("no"); return true }
    if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      root.selectedIndex = root.selectedIndex === 0 ? 1 : 0
      return true
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.finish(root.selectedIndex === 0 ? "no" : "yes")
      return true
    }
    return false
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "mosquito-confirm"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.finish("no")
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(card.heightForMessage, card.maxCardHeight)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      property int heightForMessage: card.contentTopInset + card.contentBottomInset +
        messageText.implicitHeight + Style.space(20) + Style.space(34)
      property int maxCardHeight: Math.max(Style.space(90), panel.height - Style.gapsOut * 2)

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.handleKey(event)) event.accepted = true
        }
      }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        Flickable {
          id: textFlickable
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: buttonRow.top
          anchors.bottomMargin: Style.space(20)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: messageText.implicitHeight > textFlickable.height
          contentWidth: width
          contentHeight: messageText.implicitHeight
          ScrollBar.vertical: ScrollBar { policy: messageText.implicitHeight > textFlickable.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }

          Text {
            id: messageText
            textFormat: Text.PlainText
            width: textFlickable.width
            text: root.message
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            wrapMode: Text.WordWrap
          }
        }

        Row {
          id: buttonRow
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          spacing: Style.space(10)
          rightPadding: 0
          padding: 0

          Repeater {
            model: root.okOnly ? [root.okLabel] : [root.noLabel, root.yesLabel]

            BorderSurface {
              required property int index
              required property string modelData

              readonly property bool selected: root.selectedIndex === index

              // Size the button to its own label instead of a fixed 92-unit
              // width: a longer custom label (noLabel/yesLabel) used to be
              // clipped/overflow the button. The width is measured with a
              // TextMetrics (independent of any assigned width, so there is
              // no button-width <-> label-width binding loop) and the 92-unit
              // minimum keeps the default No/Yes buttons the original size;
              // the two-button row still fits the card because cardWidth is
              // ~460 units.
              readonly property int hGutter: Style.space(12)
              width: Math.max(Style.space(92), buttonMetrics.width + hGutter * 2)
              height: Style.space(34)
              color: selected ? Util.alpha(Color.foreground, 0.08) : "transparent"
              borderSpec: Border.flat(selected ? Color.accent : Util.alpha(Color.foreground, 0.38), Style.normalBorderWidth)
              radius: 0

              TextMetrics {
                id: buttonMetrics
                text: modelData
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: buttonLabel
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: modelData
                color: selected ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectedIndex = index
                onClicked: root.finish(root.okOnly ? "ok" : (index === 0 ? "no" : "yes"))
              }
            }
          }
        }
      }
    }
  }
}