// mosquito.pipewire — sample rate and buffer size for the PipeWire graph.
//
// The Omarchy counterpart of gaheldev/pipewire-settings (a GNOME Shell
// extension, so it cannot run here). Everything it does goes through the
// `pipewire-settings` backend script; this file only draws it and turns key
// presses into backend calls.
//
// Built on qs.Ui's Panel + KeyboardPanel rather than on a hand-rolled
// PanelWindow. The hand-rolled version compiled without a single QML error and
// still showed nothing: a bare PanelWindow anchored with `top/right` mapped its
// layer-shell surface somewhere the card was not, and the shell has no way to
// prime keyboard focus into a surface it did not create. KeyboardPanel is
// Omarchy's own component for exactly this — it anchors the card to the bar,
// primes the focus so arrows actually arrive, dims the rest of the screen, and
// dismisses on an outside click. All of that is load-bearing and none of it was
// going to be reproduced correctly by guessing at property names.
//
// All state lives in the graph, not here: every change re-reads it with `show`,
// so what the panel says is what PipeWire reports rather than what this file
// believes it asked for. The graph can refuse or clamp a value, and a panel
// showing its own optimistic copy would quietly lie.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
    id: root

    moduleName: "mosquito.pipewire"
    // Panel owns the IPC and exposes open/close/toggle through it, which is what
    // makes the menu entry work as well as the bar button.
    ipcTarget: "mosquito.pipewire"

    property string backendPath: Quickshell.env("MOSQUITOMARCHY_PIPEWIRE") ||
        (Quickshell.env("HOME") + "/.local/bin/mosquitomarchy-pipewire-settings")

    property bool busy: false
    property string error: ""
    property var info: ({})
    property int row: 0

    // The upstream's lists, unchanged. These are the values worth OFFERING, not
    // every value the hardware would accept, so inventing a longer list would put
    // choices in the menu that nothing here can run.
    readonly property var rates: ["0", "44100", "48000", "88200", "96000", "176000", "192000", "352800", "384000"]
    readonly property var quantums: ["0", "32", "48", "64", "96", "128", "256", "512", "1024", "2048"]

    readonly property var rows: [
        { label: "Sample rate", kind: "rate" },
        { label: "Buffer size", kind: "quantum" },
        { label: "Force these values", kind: "force" },
        { label: "Remember on restart", kind: "persist" }
    ]

    Component.onCompleted: read()

    // ── backend ─────────────────────────────────────────────────────────────
    //
    // One Process, reused. `running` is what starts it, so the command is
    // assigned before the flag — and it cannot be assigned while a run is in
    // flight, which is why everything goes through here and is guarded by busy.
    // Two concurrent runs would leave the first one's output attributed to the
    // second.
    property string outBuf: ""
    property var onDone: null

    function run(args, done) {
        if (root.busy) return
        root.busy = true
        root.outBuf = ""
        root.onDone = done || null
        backend.command = [root.backendPath].concat(args)
        backend.running = true
    }

    function finish() {
        root.busy = false
        var cb = root.onDone
        root.onDone = null
        if (cb) cb()
    }

    function read() {
        root.run(["show"], function () {
            var raw = String(root.outBuf).trim()
            if (!raw) { root.error = "no answer from PipeWire"; return }
            try {
                root.info = JSON.parse(raw)
                root.error = ""
            } catch (e) {
                root.error = "cannot read: " + e
            }
        })
    }

    // A write, then a read: the read is what makes the panel tell the truth.
    function write(args) {
        root.run(args, function () { root.read() })
    }

    Process {
        id: backend
        stdout: SplitParser { onRead: function (line) { root.outBuf += line + "\n" } }
        stderr: SplitParser {
            onRead: function (line) {
                var t = String(line || "").trim()
                if (t) root.error = t
            }
        }
        onExited: root.finish()
    }

    // ── values ──────────────────────────────────────────────────────────────
    function currentRate() { return root.info.configured_rate || "0" }
    function currentQuantum() { return root.info.quantum || "0" }

    function forcing() {
        // One switch over BOTH force keys: the two travel together, and a forced
        // rate with a dynamic buffer (or the reverse) is a state the user cannot
        // ask for from this panel.
        return String(root.info.force_rate || "0") !== "0" ||
               String(root.info.force_quantum || "0") !== "0";
    }
    function persisting() { return root.info.persist === true }

    function label(value) {
        if (value === undefined || value === null || value === "0") return "dynamic"
        return String(value)
    }
    function rateLabel() {
        var s = root.label(root.info.rate)
        return s === "dynamic" ? s : s + " Hz"
    }
    function quantumLabel() {
        var s = root.label(root.info.quantum)
        return s === "dynamic" ? s : s + " frames"
    }
    function rowValue(index) {
        var k = root.rows[index].kind
        if (k === "rate") return root.rateLabel()
        if (k === "quantum") return root.quantumLabel()
        if (k === "force") return root.forcing() ? "on" : "off"
        return root.persisting() ? "on" : "off"
    }
    function isSwitch(index) {
        var k = root.rows[index].kind
        return k === "force" || k === "persist"
    }

    function step(list, current, delta) {
        var i = list.indexOf(String(current))
        // A value this build does not know (set elsewhere) gives -1 and would
        // jump to the end of the list; start from "dynamic" instead.
        if (i < 0) i = 0
        var n = list.length
        return list[(((i + delta) % n) + n) % n]
    }

    function moveCursor(dy) {
        var n = root.rows.length
        root.row = (((root.row + dy) % n) + n) % n
    }

    function adjust(delta) {
        var kind = root.rows[root.row].kind
        if (kind === "rate")
            root.write(["set-rate", root.step(root.rates, root.currentRate(), delta)])
        else if (kind === "quantum")
            root.write(["set-quantum", root.step(root.quantums, root.currentQuantum(), delta)])
        else if (kind === "force")
            root.write(["set-force", "rate", root.forcing() ? "0" : "1"])
        else if (kind === "persist")
            root.write(["persist", root.persisting() ? "0" : "1"])
    }

    function adjustAt(index, delta) {
        if (root.row !== index) { root.row = index; return }
        root.adjust(delta)
    }

    // ── bar button ──────────────────────────────────────────────────────────
    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "♪"
        onPressed: function (b) { root.toggle() }
    }

    // ── the panel ───────────────────────────────────────────────────────────
    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(340), Style.space(340))
        contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(420))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onMoveRequested: function (dx, dy) { root.moveCursor(dy) }
            onActivateRequested: root.adjust(1)
            onCloseRequested: function () { root.toggle() }

            Column {
                id: panelColumn
                width: parent.width
                spacing: Style.spacing.xs

                Text {
                    text: "PipeWire"
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                    leftPadding: Style.spacing.md
                    bottomPadding: Style.spacing.xs
                }

                Repeater {
                    model: root.rows

                    delegate: Rectangle {
                        id: rowItem
                        required property var modelData
                        required property int index
                        readonly property bool active: root.row === index

                        width: panelColumn.width
                        height: Style.spacing.popupRowHeight
                        color: active ? Util.alpha(Color.foreground, 0.08) : "transparent"
                        radius: Style.cornerRadius

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: Style.spacing.md
                            anchors.verticalCenter: parent.verticalCenter
                            text: rowItem.modelData.label
                            color: rowItem.active ? Color.foreground : Color.muted
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                        }

                        Text {
                            anchors.right: parent.right
                            anchors.rightMargin: Style.spacing.md
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.isSwitch(rowItem.index)
                                  ? (root.rowValue(rowItem.index) === "on" ? "[on]" : "[off]")
                                  : "◂ " + root.rowValue(rowItem.index) + " ▸"
                            color: rowItem.active ? Color.foreground : Color.muted
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            font.bold: rowItem.active
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            // Left selects, right changes — and selecting first is
                            // what keeps a stray click from changing the row the
                            // cursor was not on, same rule as the keyboard.
                            onClicked: function (mouse) {
                                root.adjustAt(rowItem.index, mouse.button === Qt.RightButton ? 1 : 0)
                            }
                        }
                    }
                }

                Text {
                    visible: root.error !== ""
                    text: root.error
                    color: Color.urgent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    leftPadding: Style.spacing.md
                    rightPadding: Style.spacing.md
                    wrapMode: Text.WordWrap
                    width: panelColumn.width - Style.spacing.md * 2
                }

                Text {
                    text: "↑↓ choose   ←→ change   enter toggles"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    leftPadding: Style.spacing.md
                    topPadding: Style.spacing.xs
                }
            }
        }
    }
}