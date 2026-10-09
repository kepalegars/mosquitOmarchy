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

    // ── bar geometry ──────────────────────────────────────────────────────────
    //
    // These four are what the bar host needs from a `bar-widget` entry point, and
    // this root was missing all of them — which is why NOTHING appeared in the bar.
    //
    // Ui/Panel (the base) extends Item directly and supplies the IPC lifecycle, but
    // NOT vertical/barSize, and widgets are expected to declare their own implicit
    // size. With no implicitWidth the bar allocated the slot ZERO pixels wide; the
    // BarIconButton below is anchors.fill, so the whole widget collapsed to 0x0 and
    // drew nothing — silently, with no QML error and nothing in the log to notice.
    // vertical/barSize mirror what Ui/BarWidget provides, so the same widget body
    // works whichever base it is instantiated from.
    readonly property bool vertical: bar ? bar.vertical : false
    readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
    implicitWidth: root.vertical ? root.barSize : Style.space(44)
    implicitHeight: root.barSize

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
            root.write(["set-force", "both", root.forcing() ? "0" : "1"])
        else if (kind === "persist")
            root.write(["persist", root.persisting() ? "0" : "1"])
    }

    // A click always CHANGES the row it lands on, and moves the cursor there
    // first. The previous version selected on the first click and changed on the
    // next, which read as a dead button: one click did nothing visible, and a
    // second one changed the value of a row the cursor had silently jumped to.
    // delta is never 0 — there is no "select without acting" click any more.
    function adjustAt(index, delta) {
        root.row = index
        root.adjust(delta >= 0 ? 1 : -1)
    }

    // ── bar button ──────────────────────────────────────────────────────────
    //
    // The GNOME extension's own icon, redrawn rather than shipped as an asset:
    // icons/pipewire-condensed-symbolic.svg is four 4-unit dots and five 2-unit
    // strokes on a 16x16 grid, which is a handful of rectangles, and a bar that
    // has to recolour itself per widget cannot use a fixed SVG anyway.
    //
    // Colour comes from bar.barForeground, which is the bar's own contrast
    // decision for this slot — white or black depending on what is behind it.
    // That is the same source Pitchfork uses, and the reason this icon stays
    // legible over any wallpaper without this file knowing anything about one.
    readonly property color iconColor: root.bar ? root.bar.barForeground : Color.foreground

    // The grey the rest of the shell dims to. Not Color.muted, and deliberately
    // not an accent: the network and bluetooth panels derive their secondary
    // text from the BAR's own foreground with Qt.darker(), so it already follows
    // both the theme and the bar's per-widget contrast. Reusing that is what
    // makes this panel's secondary text look like every other panel's rather than
    // like a different application — and it is the grey that was asked for,
    // instead of an accent colour that reads as a status.
    readonly property color dim: Qt.darker(iconColor, 1.5)

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        iconComponent: pipewireMark
        tooltipText: root.info.rate
            ? "PipeWire · " + root.rateLabel() + " · " + root.quantumLabel()
            : "PipeWire settings"
        onPressed: function (b) { root.toggle() }
    }

    Component {
        id: pipewireMark

        Item {
            id: mark

            // Color.accent is the theme's second colour, read live from the theme,
            // so the frame follows whatever the current theme makes it — and falls
            // back to the theme red (the same key jamjamjam's fork uses) if a theme
            // ever stops defining it.
            readonly property color frameInk: Color.accent
            readonly property color artInk: Color.accent

            // The frame. A hairline rounded rectangle around the mark: it gives the
            // glyph an edge to sit against, which is what the bare waveform lacked.
            Rectangle {
                anchors.fill: parent
                anchors.margins: Style.space(1)
                radius: Style.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: mark.frameInk
            }

            Item {
                id: art
                anchors.centerIn: parent
                width: parent.width * 0.56
                height: parent.height * 0.56

                // Upstream gaheldev/pipewire-settings, icons/
                // pipewire-condensed-rings-symbolic.svg, on its 16-unit grid.
                readonly property real u: Math.min(width, height) / 16

                component Stroke: Rectangle {
                    property real x1; property real y1; property real x2; property real y2
                    property bool round
                    readonly property real len: Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1))
                    x: ((x1 + x2) / 2) * art.u - width / 2
                    y: ((y1 + y2) / 2) * art.u - height / 2
                    width: art.u * 2
                    height: len * art.u
                    color: art.artInk
                    radius: round ? width / 2 : 0
                    rotation: Math.atan2(y2 - y1, x2 - x1) * 180 / Math.PI
                    transformOrigin: Item.Center
                }

                // A ring is outer radius 2 with a radius-1 hole, i.e. a 4x4 rounded
                // square with a 1u border — cheaper than two nested circles and it
                // cannot antialias into a blob at icon size.
                component Ring: Rectangle {
                    property real cx; property real cy
                    width: art.u * 4
                    height: width
                    radius: width / 2
                    color: "transparent"
                    border.width: art.u
                    border.color: art.artInk
                    x: cx * art.u - width / 2
                    y: cy * art.u - height / 2
                }

                Stroke { x1: 8;  y1: 10.5; x2: 8;  y2: 3.5 }
                Stroke { x1: 14; y1: 7.5;  x2: 14; y2: 3.5 }
                Stroke { x1: 8;  y1: 10.5; x2: 14; y2: 7.5; round: true }
                Stroke { x1: 2;  y1: 10.5; x2: 8;  y2: 7.5 }
                Stroke { x1: 2;  y1: 12.5; x2: 2; y2: 3.5 }

                Ring { cx: 2;  cy: 2 }
                Ring { cx: 8;  cy: 2 }
                Ring { cx: 14; cy: 2 }
                Ring { cx: 2;  cy: 14 }
            }
        }
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
            // BOTH axes matter, and discarding one of them is what made ←/→
            // do nothing at all: PanelKeyCatcher reports an arrow key as
            // moveRequested with one non-zero component, so a handler that only
            // reads dy silently ignores every horizontal press.
            //
            // Vertical moves the cursor between the four settings; horizontal
            // changes the one under it. Doing both on the same signal is what
            // makes this feel like the rest of the shell's panels.
            onMoveRequested: function (dx, dy) {
                if (dy !== 0) root.moveCursor(dy)
                else if (dx !== 0) root.adjust(dx > 0 ? 1 : -1)
            }
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
                            // Always muted, active row included: the label is the
                            // category NAME, not the value. Highlighting it on the
                            // cursor row made the name compete with the number it
                            // describes, which is the only part of the row that
                            // changes.
                            color: root.dim
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
                            // Always the full foreground: this is the value, and a
                            // value that dims when the cursor leaves it is a value
                            // you have to hunt for. Bold still marks the cursor.
                            color: Color.foreground
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            font.bold: rowItem.active
                        }

                        MouseArea {
                            anchors.fill: parent
                            // Right-click walks the values backwards: a rate list
                            // runs to eight entries and nobody wants to press → eight
                            // times to undo one mistake.
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: function (mouse) {
                                root.adjustAt(rowItem.index, mouse.button === Qt.RightButton ? -1 : 1)
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
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    leftPadding: Style.spacing.md
                    topPadding: Style.spacing.xs
                }
            }
        }
    }
}