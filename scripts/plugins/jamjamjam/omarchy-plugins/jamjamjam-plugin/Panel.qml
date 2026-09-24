import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "jamjamjam-plugin"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  // Clicking the red ♪ pins the panel: it stays open and only its card keeps
  // receiving pointer input, so clicks fall through and other apps stay usable.
  property bool pinned: false

  readonly property var snapshot: service ? service.snapshot : ({})
  readonly property var analyzer: snapshot.analyzer || ({ key: "", keyConfidence: 0, bpm: 0, currentChord: "", progression: [] })
  readonly property bool keyStable: analyzer.keyStable === true
  readonly property bool songChanged: analyzer.songChanged === true
  readonly property bool analysisLocked: snapshot.locked === true
  readonly property int beatsPerBar: Number(analyzer.beatsPerBar || 4)
  readonly property var midi: snapshot.midi || ({ mode: false, state: "off", message: "", ports: [], currentChord: "", connected: false })
  readonly property var synth: snapshot.synth || ({ enabled: true, waveform: "sine", volume: 0.4, running: false, error: "" })
  readonly property var guitar: snapshot.guitar || ({ strings: [], dots: [], label: "" })
  readonly property string keyName: String(analyzer.key || "")
  readonly property real bpm: Number(analyzer.bpm || 0)
  readonly property string currentAudioChord: String(analyzer.currentChord || "")
  readonly property bool noChordSignal: analyzer.noSignal === true
  readonly property var chordNotes: analyzer.chordNotes || []
  readonly property var mic: snapshot.mic || ({ available: true, muted: false })
  readonly property bool micCut: mic.available === false || mic.muted === true
  readonly property bool paused: snapshot.paused === true
  // Analysis is LIVE: the mic/monitor capture confirms it is on right now
  // (subscriber = hold active, panel opened, or the neck TUI session).
  readonly property bool analyzing: snapshot.recording === true
  // Manual entry (right-click on the KEY/BPM cards): an inline editor. Only
  // a reset returns those cards to their live state.
  property bool manualEditing: false
  property string manualTarget: ""   // "key" | "bpm"
  readonly property string dashGlyph: "—"
  readonly property bool tuiActive: snapshot.tuiActive === true
  readonly property bool needsReset: snapshot.needsReset === true
  readonly property var configState: snapshot.config || ({ noteNaming: "flats" })
  readonly property var metronome: snapshot.metronome || ({ enabled: false, bpm: 120, beats: 4 })
  readonly property bool metronomeEnabled: metronome.enabled === true
  readonly property real metronomeBpm: root.bpm > 0 ? root.bpm : Number(metronome.bpm || 120)
  property bool beatPulse: false
  property bool settingsVisible: false
  // FIXED settings size: the settings pane occupies the layout-cost of the
  // main page it replaces (cards + tuner + chord zone + fretboard + the
  // hidden column gaps minus the visible ones), CONSTANT — it does not
  // follow whatever the main page was rendering at open time.
  function toggleSettings() {
    root.settingsVisible = !root.settingsVisible
  }

  // One white flash per beat while the metronome runs, at the analysed BPM.
  Timer {
    running: root.metronomeEnabled
    interval: Math.max(80, 60000 / Math.max(40, root.metronomeBpm))
    repeat: true
    onTriggered: {
      root.beatPulse = true
      beatOff.restart()
    }
  }
  Timer {
    id: beatOff
    interval: 90
    repeat: false
    onTriggered: root.beatPulse = false
  }
  readonly property var progression: analyzer.progression || []
  readonly property var loop: snapshot.loop || ({ active: false, chords: [], pos: 0 })
  readonly property var tuner: snapshot.tuner || ({ active: false, freq: 0, note: "", octave: 0, cents: 0 })
  readonly property var song: snapshot.song || ({ available: false, match: null, error: "" })
  readonly property bool recording: snapshot.recording === true
  readonly property string inputSource: String(snapshot.inputSource || "pc")
  readonly property bool inputIsMic: inputSource === "mic"
  readonly property bool tunerActive: tuner.active === true
  readonly property string tunerNote: String(tuner.note || "")
  readonly property int tunerOctave: Number(tuner.octave || 0)
  readonly property real tunerFreq: Number(tuner.freq || 0)
  readonly property real cents: tunerActive ? Number(tuner.cents || 0) : 0
  readonly property bool inTune: tunerActive && Math.abs(cents) <= 4
  readonly property bool midiMode: midi.mode === true
  readonly property string midiChord: String(midi.currentChord || "")
  readonly property color foreground: Color.popups.text
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property bool midiSectionVisible: false
  // The fretboard is only drawn once a key is confidently established, and it
  // follows the analysis INPUT (PC audio or microphone) automatically.
  readonly property bool showFretboard: root.keyStable && root.keyName !== ""
    && !root.noChordSignal && (guitar && guitar.dots && guitar.dots.length > 0)

  // Input regions for the popup surface. Unpinned = the whole screen (so an
  // outside click dismisses). Pinned = only the card rect, so the compositor
  // routes clicks elsewhere to the apps below while the panel stays visible.
  property Region fullInputRegion: Region {
    width: popup.screenW
    height: popup.screenH
  }
  property Region pinnedInputRegion: Region {
    x: Math.round(popup.cardOrigin.x - popup.padding)
    y: Math.round(popup.cardOrigin.y - popup.padding)
    width: Math.round(popup.contentWidth + popup.padding * 2)
    height: Math.round(popup.contentHeight + popup.padding * 2)
  }

  readonly property int headerHeight: Style.space(44)
  readonly property int fretboardHeight: showFretboard ? Style.space(180) : 0
  // Chord zone: LAST-DETECTED chord, separate from the fretboard, toggled
  // from settings, ALWAYS its fixed max height (placeholder when empty).
  readonly property bool showChordBox: configState.showChordBox !== false
  readonly property int chordBoxHeight: showChordBox ? Style.space(56) : 0
  readonly property bool aecEnabled: configState.aecEnabled === true
  readonly property int tunerHeight: Style.space(190)

  function open() { controller.show() }
  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }

  // Black or white, whichever reads best on the given fill (BT.601 luminance).
  readonly property int valueRowHeight: Style.space(34)
  // Every settings row's label uses this fixed width so all the buttons /
  // interactive zones start on the SAME vertical line.
  readonly property int settingsLabelWidth: Style.space(120)
  readonly property int cardMetaHeight: Style.space(13)

  // ── Manual entry (right-click on the KEY / BPM cards) ─────────────
  // Pins a value that survives until a reset ('r' / resetAnalysis). The
  // inline editor takes the keyboard (the key catcher is blocked meanwhile).
  function beginManual(target) {
    root.manualTarget = String(target)
    root.manualEditing = true
    manualInput.text = target === "key"
      ? String(root.keyName || "")
      : (root.bpm > 0 ? String(Math.round(root.bpm)) : "")
    manualInput.forceActiveFocus()
    manualInput.selectAll()
  }
  function commitManual() {
    if (root.manualTarget === "key") {
      if (root.service) root.service.setManualKey(manualInput.text)
    } else if (root.manualTarget === "bpm") {
      if (root.service) root.service.setManualBpm(manualInput.text)
    }
    root.manualEditing = false
  }
  function cancelManual() { root.manualEditing = false }

  function contrastText(fill) {
    return (0.299 * fill.r + 0.587 * fill.g + 0.114 * fill.b) < 0.5 ? "#ffffff" : "#000000"
  }

  // AUTO-CONTRAST helper: what color is actually BEHIND a text sitting on an
  // alpha-tinted card? Compose the theme background with the tint first, then
  // pick black/white for that composite (white text can make a card
  // unreadable when its accent tint brightens the panel bg, and vice versa).
  function toneComposite(fill, a) {
    var bgc = Qt.color(Color.background)
    var f = Qt.color(fill)
    return Qt.rgba(
      f.r * a + bgc.r * (1 - a),
      f.g * a + bgc.g * (1 - a),
      f.b * a + bgc.b * (1 - a),
      1)
  }
  function contrastOn(fill, a) {
    return root.contrastText(root.toneComposite(fill, a))
  }

  // KEY→Hz root hint: approximate frequency of the SCALE ROOT note the key
  // implies (A4 = 440 Hz). Parsing handles flats/sharps names (Bb = A#, C#…).
  function keyRootHz(keyLabel) {
    // The lone keyLabel may be "F", "F♯m", "B♭ major" — trim to "m2" and cut
    // at the first which is neither a note letter nor accidental.
    var name = String(keyLabel || "")
    if (name === "") return ""
    var pc = { "C":0, "D":2, "E":4, "F":5, "G":7, "A":9, "B":11 }
    var c = name.charAt(0).toUpperCase()
    if (!(c in pc)) return ""
    var idx = pc[c]
    var rest = name.substring(1)
    if (rest.charAt(0) === "#" || rest.charAt(0) === "♯") idx += 1
    else if (rest.charAt(0) === "b" || rest.charAt(0) === "♭") idx -= 1
    var hz = 440 * Math.pow(2, (idx - 9) / 12)
    return "≈ " + Math.round(hz) + " Hz (root note · A4 = 440 Hz)"
  }

  readonly property real gridRowHeight: Style.space(30)

  onOpenedChanged: {
    // Analysis follows the panel lifecycle: reset + start on open,
    // stop as soon as the panel is not visible.
    if (!opened) root.pinned = false
    if (root.service) root.service.setVisible(opened)
  }

  KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Pinned: shrink the input region to the card so the rest of the screen
    // stays clickable (other apps usable) while the panel remains open.
    mask: root.pinned ? root.pinnedInputRegion : root.fullInputRegion
    contentWidth: popup.fittedContentWidth(Style.space(440), Style.space(560))
    contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the inline manual editor is open, all keys go to the editor.
      blocked: root.manualEditing
      onCloseRequested: root.close()
      onTextKey: function(text) {
        // When the panel is PINNED, only capture keys if the popup actually
        // holds the keyboard focus — otherwise let the key fall through to
        // the app under the (semi-transparent) panel. The old test compared
        // against contentItem, which is wrong the moment ANY inner item
        // (the pin button, a card…) is focused — that is why unpinning with
        // 'p' "never worked". Compare against the keyCatcher's OWN focus
        // state instead: the catcher is the panel's focusTarget, so if the
        // user is typing inside the panel, IT has the focus chain.
        var key = String(text || "").toLowerCase()
        if (root.pinned && !keyCatcher.activeFocus && key !== "p") {
          return
        }
        if (key === " " || key === "space") {
          if (root.service) root.service.resumeAnalysis()
          return
        }
        if (root.settingsVisible && key === "n") {
          if (root.service) root.service.setConfig(String(root.configState.noteNaming || "flats") === "flats" ? "sharps" : "flats")
          return
        }
        if (key === "r" && root.service) root.service.resetAnalysis()
        else if (key === "g" && root.service) root.service.openTui()
        else if (key === "h") root.pinned = !root.pinned
        // 'p' pins AND unpins; ',' pauses (single key — Shift+P was
        // unreliable through the catcher)
        else if (key === "p") root.pinned = !root.pinned
        else if (key === "," && root.service) root.service.togglePaused()
        else if (key === "s") root.toggleSettings()
        // 'm' toggles the METRONOME (a single key for the common case; the
        // MIDI toolbar button owns the MIDI section from here on)
        else if (key === "m" && root.service) root.service.setMetronome(!root.metronomeEnabled)
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.spacing.md

        // ─── Header: title + reset icon ───────────────────────────
        Item {
          id: headerItem
          width: parent.width
          height: root.headerHeight
          implicitHeight: root.headerHeight

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm
            readonly property int pinIconSize: Style.space(24)

            // Red music-note icon: click to pin the panel. Hovering shows the
            // hint. Pinned, the panel stays open and other apps stay usable.
            Button {
              id: pinButton
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(26)
              height: Style.space(26)
              iconText: "♪"
              iconSize: Style.space(18)
              text: ""
              bordered: false
              // `active` paints the selected FILL without the `selected`
              // icon-recolor (Button.qml recolors the glyph only for
              // `selected`), so the ♪ keeps its red identity while pinned.
              active: root.pinned
              foreground: Color.urgent
              accent: root.accent
              horizontalPadding: Style.spacing.xs
              verticalPadding: 0
              tooltipText: root.pinned
                ? "Pinned — click (or press p) to unpin and let it close normally"
                : "Pin the panel (p) — keep it open while you use other apps"
              onClicked: root.pinned = !root.pinned
            }

            Item {
              // The TITLE is enlarged and shifted DOWN so the CENTER of its
              // smallest lowercase letters (the x-height body) is aligned with
              // the center of the ♪ box to its left (a plain verticalCenter
              // leaves the lowercase body sitting too high).
              width: titleText.implicitWidth
              height: titleText.implicitHeight

              FontMetrics {
                id: titleFm
                font: titleText.font
              }

              Text {
                id: titleText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                // Nudge DOWN so the lowercase x-height body's centre lands on
                // the ♪ box's centre (the plain verticalCenter left it high).
                anchors.verticalCenterOffset: Math.round(titleText.font.pixelSize * 0.22)
                text: "jamjamjam"
                // Red while the analyzer is LIVE (mic/monitor capture running)
                color: root.analyzing ? Color.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
                font.letterSpacing: Style.space(1)
              }
            }
          }

          // Header controls: reset · pause · input · settings (gear).
          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Button {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(26)
              height: Style.space(26)
              iconText: "󰑓"
              iconSize: Style.space(15)
              text: ""
              horizontalPadding: 0
              verticalPadding: 0
              bordered: false
              foreground: root.accent
              accent: root.accent
              tooltipText: "Clear the detected key, BPM and chord history (r)"
              onClicked: if (root.service) root.service.resetAnalysis()
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(26)
              height: Style.space(26)
              iconText: root.paused ? "󰐊" : "󰏤"
              iconSize: Style.space(15)
              text: ""
              horizontalPadding: 0
              verticalPadding: 0
              bordered: false
              foreground: root.accent
              accent: root.accent
              tooltipText: root.paused ? "Resume the analysis" : "Pause the analysis"
              onClicked: if (root.service) root.service.togglePaused()
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(26)
              height: Style.space(26)
              iconText: root.inputIsMic ? "󰍬" : "󰍹"
              iconSize: Style.space(15)
              text: ""
              selected: root.inputIsMic
              bordered: false
              // Both the PC-audio and the mic icons are drawn in the theme
              // accent (same treatment as the other header buttons).
              foreground: root.accent
              accent: root.accent
              horizontalPadding: 0
              verticalPadding: 0
              tooltipText: root.inputIsMic
                ? "Analyze the default microphone"
                : "Analyze PC audio (speaker monitor)"
              onClicked: if (root.service) root.service.setSource(root.inputIsMic ? "pc" : "mic")
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(26)
              height: Style.space(26)
              iconText: "󰒓"
              iconSize: Style.space(15)
              text: ""
              horizontalPadding: 0
              verticalPadding: 0
              selected: root.settingsVisible
              bordered: false
              foreground: root.accent
              accent: root.accent
              tooltipText: "Plugin settings (s) — hides the rest of the panel: note naming, chord zone, AEC, metronome click (volume/style/import)"
              onClicked: root.toggleSettings()
            }
          }
        }

        // ─── Key / BPM cards ──────────────────────────────────────
        Item {
          visible: !root.settingsVisible
          width: parent.width
          height: Style.space(110)
          implicitHeight: Style.space(110)

          Row {
            anchors.fill: parent
            spacing: Style.spacing.sm

            // ── KEY card: right-click to pin a manual key (reset clears) ──
            Rectangle {
              id: keyCard
              width: (parent.width - parent.spacing * 2) * 0.42
              height: parent.height
              radius: Style.cornerRadius
              color: root.keyName !== "" ? Util.alpha(root.accent, 0.16) : "transparent"

              Column {
                anchors.centerIn: parent
                spacing: Style.spacing.xs

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "KEY"
                  color: root.keyName !== "" ? root.contrastOn(root.accent, 0.16) : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  height: root.valueRowHeight
                  verticalAlignment: Text.AlignVCenter
                  text: root.keyName !== "" ? root.keyName : root.dashGlyph
                  color: root.keyName !== "" ? root.contrastOn(root.accent, 0.16) : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(32)
                  font.bold: true
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  height: root.cardMetaHeight
                  text: root.keyName !== ""
                    ? "conf " + Math.round(root.analyzer.keyConfidence * 100) + "%"
                    : ""
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
              MouseArea {
                id: keyHzMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) {
                  if (mouse.button === Qt.RightButton) root.beginManual("key")
                }
              }
              PanelToolTip {
                visible: keyHzMouse.containsMouse && !root.manualEditing
                text: (root.keyRootHz(root.keyName) || "hover for the root Hz")
                  + "  ·  right-click to set a manual key"
                fontFamily: root.fontFamily
              }
            }

            // ── BPM card: left-click toggles the metronome, right-click pins
            //    a manual tempo (reset clears) ──
            Rectangle {
              id: bpmCard
              width: (parent.width - parent.spacing * 2) * 0.18
              height: parent.height
              radius: Style.cornerRadius
              color: root.bpm > 0 ? Util.alpha(root.accent, 0.16) : "transparent"
              border.color: root.metronomeEnabled ? Util.alpha(Color.foreground, 0.35 + root.beatPulse * 0.65) : "transparent"
              border.width: root.metronomeEnabled ? 1 : 0

              Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: Color.foreground
                opacity: root.metronomeEnabled ? root.beatPulse * 0.30 : 0
                Behavior on opacity { NumberAnimation { duration: 60 } }
              }

              Column {
                anchors.centerIn: parent
                spacing: Style.spacing.xs

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: (root.metronomeEnabled ? "BPM ♪ " : "BPM ") + root.beatsPerBar + "/4"
                  color: root.bpm > 0 ? root.contrastOn(root.accent, 0.16) : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  height: root.valueRowHeight
                  verticalAlignment: Text.AlignVCenter
                  text: root.bpm > 0 ? Math.round(root.bpm) : root.dashGlyph
                  color: root.bpm > 0 ? root.contrastOn(root.accent, 0.16) : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(32)
                  font.bold: true
                }
                // Same reserved meta row as KEY so the labels line up.
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  height: root.cardMetaHeight
                  text: ""
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                id: bpmMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) {
                  if (mouse.button === Qt.RightButton) root.beginManual("bpm")
                  else if (root.service) root.service.setMetronome(!root.metronomeEnabled)
                }
              }
              PanelToolTip {
                visible: bpmMouse.containsMouse && !root.manualEditing
                text: "Metronome (m)  ·  right-click to set a manual BPM"
                fontFamily: root.fontFamily
              }
            }

            // ── CHORD card: same three-row layout (label / value / meta) and
            //    the SAME dash as the other cards ──
            Rectangle {
              width: (parent.width - parent.spacing * 2) * 0.40
              height: parent.height
              radius: Style.cornerRadius
              color: root.currentAudioChord !== "" ? Util.alpha(Color.urgent, 0.16) : "transparent"

              Column {
                anchors.centerIn: parent
                spacing: Style.spacing.xs

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "CHORD"
                  color: root.currentAudioChord !== "" ? root.contrastOn(Color.urgent, 0.16) : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  height: root.valueRowHeight
                  verticalAlignment: Text.AlignVCenter
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  text: root.currentAudioChord !== "" ? root.currentAudioChord : root.dashGlyph
                  color: root.currentAudioChord !== "" ? root.contrastOn(Color.urgent, 0.16) : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(32)
                  font.bold: true
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  height: root.cardMetaHeight
                  text: ""
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // Inline manual editor overlay (right-click on KEY/BPM).
          Rectangle {
            id: manualEditor
            visible: root.manualEditing
            anchors.fill: parent
            radius: Style.cornerRadius
            color: Util.alpha(Color.background, 0.92)
            border.width: 1
            border.color: root.accent

            Column {
              anchors.centerIn: parent
              spacing: Style.spacing.sm
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.manualTarget === "key"
                  ? "Manual KEY (e.g. F#m, Bb) — Enter to apply, Esc to cancel"
                  : "Manual BPM (40–240) — Enter to apply, Esc to cancel"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Style.space(180)
                height: Style.space(30)
                radius: Style.cornerRadius
                color: Util.alpha(Color.foreground, 0.08)
                border.width: 1
                border.color: root.accent
                TextInput {
                  id: manualInput
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  verticalAlignment: TextInput.AlignVCenter
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  selectByMouse: true
                  focus: root.manualEditing
                  Keys.onEscapePressed: root.cancelManual()
                  onAccepted: root.commitManual()
                }
              }
            }
          }
        }


        // ─── Tuner (input pitch detection) ────────────────────────
        Item {
          visible: !root.settingsVisible
          width: parent.width
          height: root.tunerHeight
          implicitHeight: root.tunerHeight

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: root.tunerActive ? Util.alpha(root.accent, 0.14) : "transparent"
            border.color: root.inTune ? Util.alpha(root.accent, 0.85)
              : (root.tunerActive ? root.accent : "transparent")
            border.width: 1

            Column {
              anchors.centerIn: parent
              spacing: Style.spacing.sm

              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.spacing.sm

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "TUNER"
                  color: root.micCut ? root.contrastOn(Color.urgent, 0.16)
                    : (root.tunerActive ? root.contrastOn(root.accent, 0.14) : root.muted)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: Style.space(1)
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.micCut ? "✕ mic muted" : "● default mic"
                  color: root.micCut ? root.contrastOn(Color.urgent, 0.16) : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.micCut
                  ? "mic muted"
                  : (root.tunerActive
                    ? (root.tunerNote + (root.tunerOctave > 0 ? String(root.tunerOctave) : ""))
                    : "—")
                color: root.micCut ? root.contrastOn(Color.urgent, 0.16)
                  : (root.tunerActive ? root.contrastOn(root.accent, 0.14) : root.muted)
                font.family: root.fontFamily
                font.pixelSize: root.micCut ? Style.space(20) : Style.space(40)
                font.bold: true
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.micCut
                  ? "unmute the default mic"
                  : (root.tunerActive
                    ? (root.tunerFreq > 0 ? "≈ " + root.tunerFreq.toFixed(1) + " Hz"
                      : (root.inTune ? "in tune" : "·"))
                    : "Sing or play a note…")
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // Cents deviation meter (needle over a ±50¢ track)
              Item {
                width: parent.width * 0.82
                height: Style.space(30)
                anchors.horizontalCenter: parent.horizontalCenter

                Rectangle {
                  anchors.centerIn: parent
                  width: parent.width
                  height: 4
                  radius: 2
                  color: Util.alpha(Color.foreground, 0.12)
                }

                Repeater {
                  model: [-50, -25, 0, 25, 50]

                  Rectangle {
                    required property int modelData
                    width: 2
                    height: modelData === 0 ? 14 : 8
                    radius: 1
                    color: modelData === 0 ? Util.alpha(Color.foreground, 0.55) : Util.alpha(Color.foreground, 0.28)
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 2
                    x: (modelData + 50) / 100 * (parent.width - 2)
                  }
                }

                Column {
                  anchors.top: parent.top
                  anchors.left: parent.left
                  Text {
                    text: "♭"
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                Column {
                  anchors.top: parent.top
                  anchors.right: parent.right
                  Text {
                    text: "♯"
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Rectangle {
                  id: tunerNeedle
                  visible: root.tunerActive
                  width: 3
                  height: parent.height
                  radius: 1.5
                  color: root.inTune ? root.accent : Color.urgent
                  x: {
                    var t = Math.max(-1, Math.min(1, root.cents / 50))
                    return (parent.width - width) / 2 + (parent.width - width) / 2 * t
                  }
                }
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.micCut
                  ? "mic muted — unmute it to tune"
                  : (root.tunerActive
                    ? (root.inTune
                      ? "IN TUNE"
                      : ((root.cents < 0 ? "♭" : "♯") + " " + Math.round(Math.abs(root.cents)) + "¢"))
                    : "Sing or play into the mic")
                color: root.inTune ? root.accent : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.inTune
              }
            }
          }
        }

        // ─── Detected-chord naming zone (the RED one) ─────────────
        // Toggleable from settings and ALWAYS at its fixed max size when
        // shown — even with nothing detected (placeholder dots) — and it is
        // a separate block from the fretboard (independent of its height).
        Item {
          id: chordZone
          visible: !root.settingsVisible && root.showChordBox
          width: parent.width
          height: root.chordBoxHeight
          implicitHeight: root.chordBoxHeight

          Column {
            width: parent.width
            height: parent.height
            spacing: 2

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              anchors.verticalCenterOffset: (root.analysisLocked || root.songChanged || (root.song && root.song.match)) ? -Style.space(8) : 0
              text: root.currentAudioChord !== ""
                ? (root.chordNotes.length > 0 ? root.chordNotes.join(" ") : root.currentAudioChord)
                : "—"
              color: root.currentAudioChord !== "" ? root.contrastOn(Color.urgent, 0.16) : root.muted
              font.family: root.fontFamily
              font.pixelSize: root.currentAudioChord !== "" ? Style.space(20) : Style.space(12)
              font.bold: true
            }

            Text {
              visible: root.analysisLocked
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "⏸ key found — analysis stopped · press space to restart"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              visible: root.songChanged
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "⟳ new song detected — press r to reset the analysis"
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              visible: root.song && root.song.match !== null && root.song.match.title !== undefined
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "♪ " + (root.song.match ? String(root.song.match.title || "") : "") + " — " + (root.song.match ? String(root.song.match.artist || "") : "")
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        // ─── Guitar fretboard ─────────────────────────────────────
        Item {
          visible: !root.settingsVisible
          width: parent.width
          height: root.fretboardHeight
          implicitHeight: root.fretboardHeight
          clip: true

          // (grey wrapper removed — show the content directly)
          Column {
            anchors.fill: parent
            anchors.margins: Style.spacing.sm
            spacing: Style.spacing.xs

              Row {
                id: fretLegend
                width: parent.width
                spacing: Style.spacing.sm

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "SCALE: " + String(guitar.label || "—")
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "root"
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Rectangle {
                  width: Style.space(8)
                  height: Style.space(8)
                  radius: width / 2
                  color: Color.urgent
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "3rd/6th"
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Rectangle {
                  width: Style.space(8)
                  height: Style.space(8)
                  radius: width / 2
                  color: root.accent
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "5th"
                  color: Util.alpha(Color.foreground, 0.9)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Item {
                width: parent.width
                height: Math.max(Style.space(90), parent.height - fretLegend.height - Style.spacing.xs)

                // String-note column to the LEFT of the fretboard (high E at
                // the top, low E at the bottom — standard guitar orientation).
                Column {
                  id: stringNoteColumn
                  width: Style.space(14)
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  spacing: 0
                  Repeater {
                    model: 6
                    delegate: Item {
                      width: parent.width
                      height: parent.height / 6
                      // High E (string index 5) at the top, low E at the bottom.
                      property string note: {
                        var arr = root.guitar.strings || []
                        var i = 5 - index
                        return (arr[i] && arr[i].name !== undefined) ? arr[i].name : ""
                      }
                      Text {
                        anchors.centerIn: parent
                        text: parent.note
                        color: Util.alpha(Color.foreground, 0.65)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                  }
                }

                GuitarFretboard {
                  // The 12th-fret case (double-dot octave marker) is hidden
                  // (12-fret boards stop before the standard 12/14 double dot,
                  // so a marker there reads as "12" written on the neck).
                  anchors.left: stringNoteColumn.right
                  anchors.leftMargin: Style.spacing.xs
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  dots: (guitar.dots || []).filter(function(d) { return d.fret < 12 })
                  stringsData: guitar.strings || []
                  keyLabel: String(guitar.label || "")
                  accentColor: root.accent
                  rootColor: Color.urgent
                }
              }
            }
          }

        // ─── MIDI section (compact, no wrapper box) ───────────────
        Column {
          id: midiContent
          visible: root.midiSectionVisible && !root.settingsVisible
          width: parent.width
          spacing: Style.spacing.sm

          Item {
            width: parent.width
            height: Math.max(Style.space(30), midiToggle.implicitHeight)
            implicitHeight: height

            Text {
              id: midiTitle
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "MIDI MODE"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: Style.space(1)
            }

            ToggleSwitch {
              id: midiToggle
              anchors.left: midiTitle.right
              anchors.leftMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              checked: root.midiMode
              foreground: root.foreground
              accent: root.accent
              onToggled: if (root.service) root.service.toggleMidi()
            }

            Text {
              anchors.left: midiToggle.right
              anchors.leftMargin: Style.spacing.sm
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              text: root.midi.state === "connected"
                ? "● " + String(midi.message || "MIDI connected")
                : (root.midiMode
                  ? (root.midi.state === "waiting" ? "○ " + String(midi.message || "No MIDI device found") : String(midi.message || ""))
                  : "off")
              color: root.midi.state === "connected" ? root.accent : root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // Device controls on their own row so the mute button never
          // overlaps the enable toggle.
          Item {
            width: parent.width
            height: Style.space(30)
            implicitHeight: Style.space(30)

            Button {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.synth.enabled ? "SOUND" : "MUTED"
              selected: root.synth.enabled === true
              bordered: true
              foreground: root.synth.enabled ? root.accent : root.muted
              accent: root.accent
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.xs
              verticalPadding: Style.spacing.xs
              tooltipText: root.synth.enabled ? "Mute the synthesizer" : "Unmute the synthesizer"
              onClicked: if (root.service) root.service.toggleSynth()
            }

            Button {
              id: midiRescan
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: " RESCAN "
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.xs
              verticalPadding: Style.spacing.xs
              tooltipText: "Rescan MIDI devices"
              onClicked: if (root.service) root.service.refreshPorts()
            }
          }

          // MIDI chord (single compact line, no box)
          Text {
            visible: root.midiMode
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.midiChord !== "" ? "MIDI CHORD   " + root.midiChord
              : (root.midi.state === "connected" ? "Play a chord…" : "Connect a MIDI device")
            color: root.midiChord !== "" ? Color.urgent : (root.midi.state === "connected" ? root.accent : root.muted)
            font.family: root.fontFamily
            font.pixelSize: root.midiChord !== "" ? Style.space(18) : Style.font.caption
            font.bold: true
          }

          // Synth controls (waveform)
          Row {
            visible: root.midiMode
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "WAVEFORM"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Repeater {
              model: ["sine", "triangle", "sawtooth", "square", "organ"]

              Button {
                required property string modelData
                anchors.verticalCenter: parent.verticalCenter
                text: " " + modelData.toUpperCase() + " "
                selected: String(synth.waveform || "sine") === modelData
                bordered: true
                foreground: String(synth.waveform || "sine") === modelData ? root.accent : root.foreground
                accent: root.accent
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.xs
                verticalPadding: Style.spacing.xs
                onClicked: if (root.service) root.service.setWaveform(modelData)
              }
            }
          }

          // Synth controls (volume + panic)
          Row {
            visible: root.midiMode
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "VOL"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            PanelSlider {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(100)
              minimum: 0
              maximum: 1
              value: root.service ? root.service.synthVolume : 0.4
              onMoved: if (root.service) root.service.setVolume(value)
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰂎"
              iconSize: Style.space(14)
              text: ""
              bordered: true
              foreground: Color.urgent
              accent: Color.urgent
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.xs
              verticalPadding: Style.spacing.xs
              tooltipText: "Cut all held synths notes"
              onClicked: if (root.service) root.service.panicMidi()
            }
          }
        }

        // ─── Plugin settings (gear) — FIXED pane, SCROLLABLE content ──
        // The toggling via 's' / the gear only swaps the CONTENT of the same
        // pane: the panel size never changes, and the content scrolls inside
        // a bounded, wheel/drag-friendly Flickable so the whole set of
        // settings fits whatever the configured panel height is.
        Column {
          id: settingsContent
          visible: root.settingsVisible
          width: parent.width
          spacing: Style.spacing.sm

          Item {
            id: settingsHeaderRow
            width: parent.width
            height: Style.space(30)
            implicitHeight: Style.space(30)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "SETTINGS"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: Style.space(1)
            }
          }

          Flickable {
            id: settingsFlick
            width: parent.width
            // The settings pane sizes to its CONTENT (no big empty area):
            // it shrinks to whatever the settings rows need, capped so a
            // long list still scrolls. The pinned footer (version) sits
            // below, always at the very bottom.
            height: Math.min(settingsRows.implicitHeight, Style.space(360))
            implicitHeight: height
            contentWidth: width
            contentHeight: settingsRows.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick

            Column {
              id: settingsRows
              width: parent.width
              spacing: Style.spacing.sm
              topPadding: Style.space(4)

              // Note naming (flats / sharps)
              Row {
                width: parent.width
                spacing: Style.spacing.sm

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.settingsLabelWidth
                  text: "NOTE NAMING"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: " FLATS "
                  selected: String(root.configState.noteNaming || "flats") === "flats"
                  bordered: true
                  foreground: String(root.configState.noteNaming || "flats") === "flats" ? root.accent : root.foreground
                  accent: root.accent
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.xs
                  verticalPadding: Style.spacing.xs
                  onClicked: if (root.service) root.service.setConfig("flats")
                }
                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: " SHARPS "
                  selected: String(root.configState.noteNaming || "flats") === "sharps"
                  bordered: true
                  foreground: String(root.configState.noteNaming || "flats") === "sharps" ? root.accent : root.foreground
                  accent: root.accent
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.xs
                  verticalPadding: Style.spacing.xs
                  onClicked: if (root.service) root.service.setConfig("sharps")
                }
              }

              // Detected-chord zone toggle (chordZone visibility)
              Row {
                width: parent.width
                spacing: Style.spacing.sm

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.settingsLabelWidth
                  text: "CHORD ZONE"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: " SHOWN "
                  selected: root.showChordBox
                  bordered: true
                  foreground: root.showChordBox ? root.accent : root.foreground
                  accent: root.accent
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.xs
                  verticalPadding: Style.spacing.xs
                  tooltipText: "The fixed-size chord zone above the fretboard"
                  onClicked: if (root.service) root.service.setConfigBool("showChordBox", true)
                }
                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: " HIDDEN "
                  selected: !root.showChordBox
                  bordered: true
                  foreground: !root.showChordBox ? root.accent : root.foreground
                  accent: root.accent
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.xs
                  verticalPadding: Style.spacing.xs
                  onClicked: if (root.service) root.service.setConfigBool("showChordBox", false)
                }
              }

              // AEC (mic↔PC-audio phase subtraction for the tuner).
              // Off by default; the hint is about output audio, NOT
              // "speaker monitor" (the user despised that phrasing).
              Row {
                width: parent.width
                spacing: Style.spacing.sm

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.settingsLabelWidth
                  text: "TUNER AEC"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: " ON "
                  selected: root.aecEnabled
                  bordered: true
                  foreground: root.aecEnabled ? root.accent : root.foreground
                  accent: root.accent
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.xs
                  verticalPadding: Style.spacing.xs
                  tooltipText: "Subtract the PC's own output audio from the mic — only when the output is loud enough to be heard (output audio)"
                  onClicked: if (root.service) root.service.setConfigBool("aecEnabled", true)
                }
                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: " OFF "
                  selected: !root.aecEnabled
                  bordered: true
                  foreground: !root.aecEnabled ? root.accent : root.foreground
                  accent: root.accent
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.xs
                  verticalPadding: Style.spacing.xs
                  tooltipText: "Standard tuner (mic only)"
                  onClicked: if (root.service) root.service.setConfigBool("aecEnabled", false)
                }
              }

              // ─── Metronome sound: volume + preset + custom import ──
              Row {
                width: parent.width
                spacing: Style.spacing.sm

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.settingsLabelWidth
                  text: "CLICK VOL"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                PanelSlider {
                  anchors.verticalCenter: parent.verticalCenter
                  bar: root.bar
                  width: Style.space(160)
                  value: Number(root.metronome.volume !== undefined ? root.metronome.volume : 0.7)
                  minimum: 0
                  maximum: 1
                  step: 0.05
                  onReleased: function(v) { if (root.service) root.service.setMetronomeVolume(v) }
                }
              }

              Row {
                width: parent.width
                spacing: Style.spacing.sm

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.settingsLabelWidth
                  text: "CLICK STYLE"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Repeater {
                  model: (root.metronome.styles || ["classic", "wood", "kick", "beep"])
                  delegate: Button {
                    required property string modelData
                    anchors.verticalCenter: parent.verticalCenter
                    text: " " + modelData.toUpperCase() + " "
                    selected: String(root.metronome.style || "classic") === modelData
                        && !root.metronome.custom
                    bordered: true
                    foreground: (String(root.metronome.style || "classic") === modelData
                                  && !root.metronome.custom) ? root.accent : root.foreground
                    accent: root.accent
                    fontSize: Style.font.caption
                    horizontalPadding: Style.spacing.xs
                    verticalPadding: Style.spacing.xs
                    onClicked: {
                      if (root.service) {
                        root.service.setClickStyle(modelData)
                        root.service.setClickCustom(false)
                      }
                    }
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.spacing.sm

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.settingsLabelWidth
                  text: "CLICK CUSTOM"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: " IMPORT DOWN "
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.xs
                  verticalPadding: Style.spacing.xs
                  tooltipText: "Pick a .wav for the down beat"
                  onClicked: if (root.service) root.service.importClick("down")
                }
                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: " IMPORT UP "
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.xs
                  verticalPadding: Style.spacing.xs
                  tooltipText: "Pick a .wav for the UP beat"
                  onClicked: if (root.service) root.service.importClick("up")
                }
                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.metronome.custom ? " DEFAULT CLICKS " : " USE IMPORTED "
                  selected: root.metronome.custom === true
                  bordered: true
                  foreground: root.metronome.custom === true ? root.accent : root.foreground
                  accent: root.accent
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.xs
                  verticalPadding: Style.spacing.xs
                  tooltipText: root.metronome.custom === true
                    ? "Back to the built-in preset sounds"
                    : "Use the imported .wav files for down/up beats"
                  onClicked: if (root.service) root.service.setClickCustom(!(root.metronome.custom === true))
                }
                Item {
                  // fill so the row below the buttons (custom file names) wraps
                  height: Style.font.caption
                  width: Style.space(4)
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: String(root.metronome.customDown || "") !== "" || String(root.metronome.customUp || "") !== ""
                  width: parent.width
                  text: String(root.metronome.customDown || "") !== ""
                    ? "↓ " + String(root.metronome.customDown || "").split("/").pop()
                      + (String(root.metronome.customUp || "") !== "" ? "   ↑ " + String(root.metronome.customUp || "").split("/").pop() : "")
                    : ""
                  elide: Text.ElideMiddle
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                width: parent.width
                visible: !root.aecEnabled
                color: Util.alpha(Color.foreground, 0.45)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                text: "AEC extracts the PC's own output audio from the tuner's mic (phase subtraction) when the output is loud enough to be picked up."
                wrapMode: Text.WordWrap
              }
            }
          }

          // ─── Pinned footer (always at the very bottom of the pane) ──
          Text {
            width: parent.width
            color: Util.alpha(root.foreground, 0.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            text: "KEYS — space: analyze hold · r: reset · g: open neck TUI · s: settings · m: metronome · ,: pause · p: pin/unpin · n: note naming (in settings)"
          }
          Text {
            width: parent.width
            color: Util.alpha(root.foreground, 0.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            text: "jamjamjam v"
              + (root.manifest && root.manifest.version !== undefined ? String(root.manifest.version) : "1.0.0")
              + " · ultra-alpha (some features are still rough)"
          }
        }

        // ─── Toolbar (pinned to the bottom) ───────────────────────
        // MIDI hugs the left edge, "Open TUI" is flush with the right edge so
        // it lines up with the card row above it.
        Item {
          id: toolbarRow
          width: parent.width
          height: Math.max(midiToolbarButton.implicitHeight, openTuiButton.implicitHeight)
          implicitHeight: height

          Button {
            id: midiToolbarButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "MIDI"
            selected: root.midiSectionVisible
            bordered: true
            foreground: root.midiSectionVisible ? root.accent : root.foreground
            accent: root.accent
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.sm
            verticalPadding: Style.spacing.xs
            tooltipText: "MIDI device detection and synthesizer (m)"
            onClicked: root.midiSectionVisible = !root.midiSectionVisible
          }

          Button {
            id: openTuiButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Open TUI"
            bordered: false
            // Filled with the theme accent; the label picks the contrasting
            // black/white for that fill (hover just brightens it).
            color: openTuiHover.hovered ? Qt.lighter(root.accent, 1.15) : root.accent
            foreground: root.contrastText(openTuiHover.hovered ? Qt.lighter(root.accent, 1.15) : root.accent)
            accent: root.accent
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.sm
            verticalPadding: Style.spacing.xs
            tooltipText: "Open the guitar-neck TUI: scale, live chord, tuner (g)\nKeys: space analyze-hold · , pause · r reset · s settings · m MIDI · g TUI · p pin/unpin"
            onClicked: if (root.service) root.service.openTui()

            HoverHandler { id: openTuiHover }
          }
        }
      }
    }
  }
}