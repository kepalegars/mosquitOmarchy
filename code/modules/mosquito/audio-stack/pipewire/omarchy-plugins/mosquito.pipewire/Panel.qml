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
import QtQuick.Effects

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
    // The same footprint every other bar icon gets: BarIconButton sizes itself to
    // Style.bar.iconSlot (fixedWidth) and Style.space(44) is a good deal wider than
    // the battery/speaker next to it, which is what made this one eat the row.
    implicitWidth: root.vertical ? root.barSize : Style.bar.iconSlot
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

    // ── live mode ───────────────────────────────────────────────────────────
    //
    // Live mode forces the graph's current values and sets the persisted config
    // aside; the widget then locks the two remaining values (they cannot be
    // changed mid-session by accident) and hides the two switches live mode owns.
    // L unlocks the values after a confirmation, for the rest of the session.
    property bool liveActive: false
    property bool unlocked: false
    property bool unlockConfirmOpen: false
    property int unlockSelected: 1

    readonly property bool locked: root.liveActive && !root.unlocked
    readonly property bool autoLock: root.info.autolock !== false
    readonly property var displayRows: {
        if (!root.liveActive) return root.rows
        return root.rows.filter(function (r) {
            return r.kind === "rate" || r.kind === "quantum"
        })
    }

    function setLive(on) {
        var changed = on !== root.liveActive
        root.liveActive = on
        if (!on) {
            root.unlocked = false
            root.unlockConfirmOpen = false
        } else if (changed) {
            // autoLock on: start locked; off: start editable (L locks).
            root.unlocked = !root.autoLock
        }
        if (changed) root.row = 0
    }

    function requestUnlock() {
        if (!root.liveActive || root.unlocked) return
        root.unlockSelected = 1
        root.unlockConfirmOpen = true
    }
    function confirmUnlock() {
        root.unlockConfirmOpen = false
        root.unlocked = true
    }
    function cancelUnlock() { root.unlockConfirmOpen = false }
    function toggleLock() {
        if (!root.liveActive) return
        if (root.unlocked) root.unlocked = false
        else root.requestUnlock()
    }

    // The shell runs with QS_DISABLE_FILE_WATCHER=1, so a FileView watcher on
    // the live-mode flag never fires. `show` reports the flag instead, and the
    // panel re-reads it when it opens and while it stays open.
    onOpenedChanged: if (opened) read()
    Timer {
        interval: 2000
        running: root.opened
        repeat: true
        onTriggered: root.read()
    }

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
                root.setLive(root.info.live === true)
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
        var k = root.displayRows[index].kind
        if (k === "rate") return root.rateLabel()
        if (k === "quantum") return root.quantumLabel()
        if (k === "force") return root.forcing() ? "on" : "off"
        return root.persisting() ? "on" : "off"
    }
    function isSwitch(index) {
        var k = root.displayRows[index].kind
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
        if (root.locked) return
        var n = root.displayRows.length
        root.row = (((root.row + dy) % n) + n) % n
    }

    function adjust(delta) {
        if (root.locked) return
        var kind = root.displayRows[root.row].kind
        if (kind === "rate")
            root.write(["set-rate", root.step(root.rates, root.currentRate(), delta)])
        else if (kind === "quantum")
            root.write(["set-quantum", root.step(root.quantums, root.currentQuantum(), delta)])
        else if (kind === "force")
            root.write(["set-force", "both", root.forcing() ? "0" : "1"])
        else if (kind === "persist")
            root.write(["persist", root.persisting() ? "0" : "1"])
    }

    // A click only SELECTS the row it lands on and never changes it: the
    // mouse picks the option, the keyboard (arrows, enter) changes it. A
    // click that also wrote meant brushing the panel on the way past could
    // flip the sample rate with no visible intent, and there is no undo for
    // a graph change mid-take.
    function selectAt(index) {
        if (root.locked) return
        root.row = index
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

    // The grey for secondary text. This used to be the BAR foreground darkened
    // with Qt.darker(), which collapses to plain black on a light bar — and
    // the popup card stays dark, so the labels vanished exactly when the icon
    // went black. An alpha blend of the CARD's own foreground instead: it
    // stays a readable grey on a dark card and on a light one, because it is
    // derived from the surface the text sits on rather than from the bar icon.
    readonly property color dim: Util.alpha(Color.foreground, 0.55)

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

            // BarIconButton centres a component with an implicit size. Without
            // these two the root was 0x0 and the image anchored to its top-left
            // corner, which is exactly why the mark looked high and left.
            implicitWidth: Style.bar.iconCanvas
            implicitHeight: Style.bar.iconCanvas

            // The upstream mark, shipped as the actual file rather than redrawn in
            // QML. Hand-transcribing the SVG is what produced a starburst nobody could
            // read: at icon size the geometry collapses and there is no way to tell it
            // looks wrong until it is on screen.
            //
            // The filled-dot variant: its solid dots survive downscaling to icon
            // size, where the rings variant's holes close up into a blur.
            readonly property string markFile: "assets/pipewire-condensed-symbolic.png"

            // barForeground is the shell's own contrast decision for this bar, so
            // the glyph is white on a dark bar and black on a light one without
            // this plugin having to know anything about the background.
            readonly property color ink: root.barForeground

            Image {
                id: glyph
                // Centre in the icon canvas, not at the top-left of a 0x0 item.
                anchors.centerIn: parent
                // Slightly under the canvas: the dense 4-dot mark reads heavier
                // than the sparse speaker/battery glyphs at the same size.
                width: parent.width * 0.78
                height: parent.height * 0.78
                source: mark.markFile
                fillMode: Image.PreserveAspectFit
                // The file is white on transparent; MultiEffect below replaces the
                // white and keeps the alpha, so the holes inside the rings stay open.
                sourceSize.width: 128
            }

            MultiEffect {
                anchors.fill: glyph
                source: glyph
                colorization: 1
                colorizationColor: mark.ink
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

        // A plain key catcher rather than PanelKeyCatcher: that component owns
        // lowercase "l" as "move right", and the lock key is L. Handling the
        // arrows here keeps both, and matches how the shell's other panels
        // (clipboard, menu) do their own keys anyway.
        Item {
            id: keyCatcher
            anchors.fill: parent
            focus: true
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function (event) {
                if (root.unlockConfirmOpen) {
                    if (event.key === Qt.Key_Escape) {
                        root.cancelUnlock()
                    } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right ||
                               event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                        root.unlockSelected = root.unlockSelected === 0 ? 1 : 0
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (root.unlockSelected === 1) root.confirmUnlock()
                        else root.cancelUnlock()
                    } else {
                        return
                    }
                    event.accepted = true
                    return
                }
                if (event.key === Qt.Key_Escape) {
                    root.toggle()
                } else if (event.key === Qt.Key_Up) {
                    root.moveCursor(-1)
                } else if (event.key === Qt.Key_Down) {
                    root.moveCursor(1)
                } else if (event.key === Qt.Key_Left) {
                    root.adjust(-1)
                } else if (event.key === Qt.Key_Right) {
                    root.adjust(1)
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    // Enter toggles the two-state rows (force / persist) and
                    // does nothing on sample rate / buffer size: a stray Enter
                    // there changed the graph's rate by one step.
                    if (!root.locked && root.isSwitch(root.row)) root.adjust(1)
                } else if (event.text === "l" || event.text === "L") {
                    // L locks when unlocked, and asks before unlocking.
                    root.toggleLock()
                } else {
                    return
                }
                event.accepted = true
            }


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

                Item {
                    id: body
                    width: parent.width
                    height: normalBody.implicitHeight

                    Column {
                        id: normalBody
                        width: parent.width
                        spacing: Style.spacing.xs

                    Repeater {
                        model: root.displayRows

                        delegate: Rectangle {
                            id: rowItem
                            required property var modelData
                            required property int index
                            readonly property bool active: root.row === index && !root.locked

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
                                // Locked: the value only — no arrows, no [on]/[off],
                                // and muted. There is nothing to select or change.
                                text: root.locked
                                      ? root.rowValue(rowItem.index)
                                      : (root.isSwitch(rowItem.index)
                                         ? (root.rowValue(rowItem.index) === "on" ? "[on]" : "[off]")
                                         : "◂ " + root.rowValue(rowItem.index) + " ▸")
                                // Always the full foreground: this is the value, and a
                                // value that dims when the cursor leaves it is a value
                                // you have to hunt for. Bold still marks the cursor.
                                color: root.locked ? root.dim : Color.foreground
                                font.family: Style.font.family
                                font.pixelSize: Style.font.body
                                font.bold: rowItem.active
                            }

                            MouseArea {
                                anchors.fill: parent
                                // Selection only: clicking a row moves the cursor
                                // there so the keyboard acts on it. No button
                                // ever writes — see selectAt.
                                acceptedButtons: Qt.LeftButton
                                enabled: !root.locked
                                onClicked: function (mouse) {
                                    root.selectAt(rowItem.index)
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
                        // The legend follows the state: L locks while unlocked,
                        // and asks before unlocking while locked.
                        text: root.locked
                              ? "Locked for live mode · L unlock"
                              : root.liveActive
                                ? "Unlocked · ↑↓ choose   ←→ change · L lock"
                                : "↑↓ choose   ←→ change   enter toggles"
                        color: root.dim
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        leftPadding: Style.spacing.md
                        topPadding: Style.spacing.xs
                    }
                }

                    // The unlock confirmation is an overlay on the same body
                    // area: it replaces the interface without resizing the
                    // panel (the underlying rows keep defining the height).
                    Rectangle {
                        anchors.fill: parent
                        visible: root.unlockConfirmOpen
                        color: Color.background
                        radius: Style.cornerRadius
                        z: 5

                        MouseArea { anchors.fill: parent }

                        Column {
                            id: confirmBody
                            width: parent.width
                            spacing: Style.spacing.xs

                    Text {
                        text: "Unlock PipeWire settings?"
                        color: Color.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                        leftPadding: Style.spacing.md
                    }

                    Text {
                        text: "Changing the sample rate or buffer size can cause audio crackles."
                        color: root.dim
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        leftPadding: Style.spacing.md
                        rightPadding: Style.spacing.md
                        wrapMode: Text.WordWrap
                        width: panelColumn.width - Style.spacing.md * 2
                    }

                    Row {
                        x: Style.spacing.md
                        spacing: Style.space(8)

                        Repeater {
                            model: ["Keep locked", "Unlock"]

                            delegate: BorderSurface {
                                required property int index
                                required property string modelData
                                readonly property bool selected: root.unlockSelected === index
                                readonly property bool destructive: index === 1

                                width: Style.space(104)
                                height: Style.space(28)
                                color: selected
                                    ? Util.alpha(destructive ? Color.urgent : Color.foreground, 0.22)
                                    : "transparent"
                                borderSpec: Border.flat(destructive
                                    ? (selected ? Color.urgent : Util.alpha(Color.urgent, 0.56))
                                    : (selected ? Color.accent : Util.alpha(Color.foreground, 0.38)),
                                    Style.normalBorderWidth)
                                radius: Style.cornerRadius

                                Text {
                                    anchors.centerIn: parent
                                    text: modelData
                                    color: destructive
                                        ? (selected ? Color.urgent : Color.foreground)
                                        : (selected ? Color.accent : Color.foreground)
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: index === 0 ? root.cancelUnlock() : root.confirmUnlock()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
}
}
