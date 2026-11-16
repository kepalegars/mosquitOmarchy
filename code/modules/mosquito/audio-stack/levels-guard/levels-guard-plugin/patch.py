#!/usr/bin/env python3
"""Patch Omarchy's audio Panel.qml with the Levels Guard.

The installer refuses to refresh once the upstream audio plugin changes, so
these exact snippets are pinned to the Omarchy release this repo targets. A
missing snippet is a hard error, never a silently half-patched panel.
"""

from pathlib import Path
import sys

GUARD = '''  readonly property bool inputMuted: inputViaWpctl ? UntypedInput.muted : (source && source.audio ? source.audio.muted : false)

  // levels-guard guard: USB hardware volume belongs to mosquitomixbay.
  // It only ignores the native surfaces; direct pactl/wpctl stays untouched.
  property bool levelsGuardAllowNative: false
  function levelsGuardManagedInterface(name, prefix) {
    var n = String(name || "").toLowerCase()
    // Mixbay split sinks (evo8_main_output, evo8_mic_1_2, …) carry the level
    // Mixbay owns too, even though they are not raw USB devices.
    var split = /^evo[0-9]_/.test(n)
    if (!split && n.indexOf(prefix) !== 0) return false
    return split
        || n.indexOf("audient_evo") >= 0
        || n.indexOf("fireface") >= 0
        || n.indexOf("ugm192") >= 0
        || n.indexOf("quantum_es") >= 0
  }
  readonly property bool levelsGuardManagedOutput: levelsGuardManagedInterface(volumeSink && volumeSink.name, "alsa_output.usb-")
  readonly property bool levelsGuardManagedInput: levelsGuardManagedInterface(source && source.name, "alsa_input.usb-")
  readonly property bool levelsGuardBlockOutput: levelsGuardManagedOutput && !levelsGuardAllowNative
  readonly property bool levelsGuardBlockInput: levelsGuardManagedInput && !levelsGuardAllowNative

  // levels-guard live lock: Live Mode's LOCK_OUTPUT_VOLUME (on unless "no")
  // reserves the output volume for hardware & UI while a session is active,
  // overriding Mixbay's own free/exclusive preference.
  property bool levelsGuardPrefsAllow: true
  property bool levelsGuardLiveActive: false
  property bool levelsGuardLiveLock: true
  function levelsGuardRefreshAllow() {
    root.levelsGuardAllowNative = root.levelsGuardPrefsAllow
      && !(root.levelsGuardLiveActive && root.levelsGuardLiveLock)
  }

  // levels-guard hero subtitle: the live PipeWire clock (sample rate / quantum)
  // tells more about the graph than a mood name. force-* wins when set.
  property int levelsGuardRate: 0
  property int levelsGuardQuantum: 0
  property int levelsGuardForceRate: 0
  property int levelsGuardForceQuantum: 0
  readonly property string levelsGuardClock: {
    var rate = levelsGuardForceRate > 0 ? levelsGuardForceRate : levelsGuardRate
    var frames = levelsGuardForceQuantum > 0 ? levelsGuardForceQuantum : levelsGuardQuantum
    if (rate <= 0 || frames <= 0) return "—"
    var khz = rate % 1000 === 0 ? String(rate / 1000) : String(Math.round(rate / 100) / 10)
    return khz + "kHz / " + frames + "spls"
  }
  Process {
    id: levelsGuardClockProbe
    running: false
    command: ["pw-metadata", "-n", "settings", "0"]
    stdout: SplitParser {
      onRead: function(line) {
        var m = /key:'([^']+)' value:'([^']*)'/.exec(String(line))
        if (!m) return
        var value = parseInt(m[2], 10) || 0
        if (m[1] === "clock.rate") root.levelsGuardRate = value
        else if (m[1] === "clock.quantum") root.levelsGuardQuantum = value
        else if (m[1] === "clock.force-rate") root.levelsGuardForceRate = value
        else if (m[1] === "clock.force-quantum") root.levelsGuardForceQuantum = value
      }
    }
  }
  Timer {
    interval: 5000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: if (!levelsGuardClockProbe.running) levelsGuardClockProbe.running = true
  }

  FileView {
    id: levelsGuardPrefs
    path: Quickshell.env("HOME") + "/.config/mosquitomixbay/ui.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      var allow = true
      try {
        var o = JSON.parse(text())
        if (o && o.allow_native_volume === false) allow = false
      } catch (e) {}
      root.levelsGuardPrefsAllow = allow
      root.levelsGuardRefreshAllow()
    }
    onLoadFailed: {
      root.levelsGuardPrefsAllow = true
      root.levelsGuardRefreshAllow()
    }
    onFileChanged: reload()
  }
  FileView {
    id: levelsGuardLiveState
    path: Quickshell.env("HOME") + "/.local/state/live-mode/active"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.levelsGuardLiveActive = String(text()).trim() !== ""
      root.levelsGuardRefreshAllow()
    }
    onLoadFailed: {
      root.levelsGuardLiveActive = false
      root.levelsGuardRefreshAllow()
    }
    onFileChanged: reload()
  }
  FileView {
    id: levelsGuardLivePrefs
    path: Quickshell.env("HOME") + "/.config/live-mode/settings"
    watchChanges: true
    printErrors: false
    onLoaded: {
      var lock = true
      var lines = String(text()).split(String.fromCharCode(10))
      for (var i = 0; i < lines.length; i++) {
        var eq = lines[i].indexOf("=")
        if (eq <= 0 || lines[i].slice(0, eq).trim() !== "LOCK_OUTPUT_VOLUME") continue
        lock = lines[i].slice(eq + 1).trim().replace(/^["']|["']$/g, "") !== "no"
        break
      }
      root.levelsGuardLiveLock = lock
      root.levelsGuardRefreshAllow()
    }
    onLoadFailed: {
      root.levelsGuardLiveLock = true
      root.levelsGuardRefreshAllow()
    }
    onFileChanged: reload()
  }
'''

INSERTIONS = [
    (
        '''  // Output device row — cursor target inside the "output" section. Mouse''',
        '''  component LevelsGuardBar: Item {
    id: levelsGuardBar
    property QtObject bar: null
    property real trackHeight: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
    implicitHeight: Math.max(Style.space(22), Math.max(14, Math.round(Style.spacing.controlHeight * 0.38)) + Style.spacing.md)
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.right: parent.right
      height: levelsGuardBar.trackHeight
      radius: height / 2
      color: levelsGuardBar.bar ? Style.selectedFillFor(levelsGuardBar.bar.foreground, Color.accent) : "#333"
    }
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      width: parent.width
      height: levelsGuardBar.trackHeight
      radius: height / 2
      color: levelsGuardBar.bar ? levelsGuardBar.bar.foreground : Color.foreground
    }
  }

''',
    ),
]

REPLACEMENTS = [
    (
        '''  onOpenedChanged: {
    if (opened) {
      refreshDisplayAudioModels()
''',
        '''  onOpenedChanged: {
    if (opened) {
      // levels-guard: ui.json and live-mode state may have changed while the
      // panel was closed, and their watchers do not fire for every case.
      levelsGuardPrefs.reload()
      levelsGuardLiveState.reload()
      levelsGuardLivePrefs.reload()
      refreshDisplayAudioModels()
''',
    ),
    (
        '''    // A hardware output is its own volume sink, as omarchy-audio-output-sink
    // reports without looking further, so only a DSP sink needs the script.
    if (sink && String(sink.name).indexOf("alsa_output.") === 0) {
''',
        '''    // A hardware output is its own volume sink, as omarchy-audio-output-sink
    // reports without looking further, so only a DSP sink needs the script.
    // Mixbay split sinks are stereo loopbacks with their own PipeWire volume;
    // resolving them to the raw Pro Audio node loses that volume (pro-audio
    // reports 0), so they stay their own volume sink.
    if (sink && (String(sink.name).indexOf("alsa_output.") === 0
        || /^evo[0-9]_/.test(String(sink.name)))) {
''',
    ),
    (
        '''  function outputIcon(volume) {
    // Match the old Waybar pulseaudio glyph set. The Material Design speaker
    // icons render visually smaller in JetBrainsMono Nerd Font.
    if (!sink || !sink.audio) return ""
    if (isHeadphones(sink)) return "󰋋"
    if (outputMuted) return ""
    var v = volume === undefined ? outputVolume : volume
''',
        '''  function outputIcon(volume) {
    // Match the old Waybar pulseaudio glyph set. The Material Design speaker
    // icons render visually smaller in JetBrainsMono Nerd Font.
    // A Mixbay-managed interface always shows the maximum-volume glyph: its
    // level belongs to Mixbay, and a PipeWire volume of 0 there is not a mute.
    if (levelsGuardManagedOutput) return ""
    // A Mixbay split sink is a loopback node: Quickshell does not expose it as
    // an audio node, so "no audio" on `sink` alone is not a mute. Show the
    // resolved sink's state (or a normal speaker when that is unknown too)
    // instead of a false muted glyph.
    if (!sink) return ""
    if (isHeadphones(sink)) return "󰋋"
    if (outputMuted) return ""
    var v = volume === undefined ? (hasOutput ? outputVolume : 1) : volume
    // Mixbay split sinks and Pro Audio nodes expose no usable PipeWire
    // volume (Quickshell reads 0): the hardware level belongs to Mixbay.
    // Showing the "silenced" glyph there is a false mute.
    var levelUnknown = /^evo[0-9]_/.test(String(sink.name || ""))
        || String(sink.name || "").indexOf(".pro-output-") >= 0
    if (v <= 0 && levelUnknown) return ""
''',
    ),
    (
        '''  function outputVolumeName(volume, muted) {
    return Model.outputVolumeName(volume, muted, Commons.I18n.t)
  }
''',
        '''  function outputVolumeName(volume, muted) {
    // The hero subtitle under the Audio title: PipeWire's current rate and
    // quantum, refreshed by levelsGuardClockProbe while the panel is open.
    return root.levelsGuardClock
  }
''',
    ),
    (
        '''  function setOutputVolume(v) {
    if (!volumeSink || !volumeSink.audio) return outputVolume
''',
        '''  function setOutputVolume(v) {
    if (!volumeSink || !volumeSink.audio || levelsGuardBlockOutput) return outputVolume
''',
    ),
    (
        '''  function setInputVolume(v) {
    if (inputViaWpctl) {
''',
        '''  function setInputVolume(v) {
    if (levelsGuardBlockInput) return
    if (inputViaWpctl) {
''',
    ),
    (
        '''  function toggleOutputMute() {
    if (volumeSink && volumeSink.audio) volumeSink.audio.muted = !volumeSink.audio.muted
  }''',
        '''  function toggleOutputMute() {
    if (levelsGuardBlockOutput) return
    if (volumeSink && volumeSink.audio) volumeSink.audio.muted = !volumeSink.audio.muted
  }''',
    ),
    (
        '''  function toggleInputMute() {
    if (inputViaWpctl) {
''',
        '''  function toggleInputMute() {
    if (levelsGuardBlockInput) return
    if (inputViaWpctl) {
''',
    ),
    (
        '''  function toggleAllMuted() {
    var mute = anyAudible
    if (hasOutput) volumeSink.audio.muted = mute
    if (hasInput && inputViaWpctl) UntypedInput.setMuted(mute)
    else if (hasInput) source.audio.muted = mute
  }''',
        '''  function toggleAllMuted() {
    var mute = anyAudible
    if (hasOutput && !levelsGuardBlockOutput) volumeSink.audio.muted = mute
    if (!levelsGuardBlockInput) {
      if (hasInput && inputViaWpctl) UntypedInput.setMuted(mute)
      else if (hasInput) source.audio.muted = mute
    }
  }''',
    ),
    (
        '''  readonly property bool anyAudible: (hasOutput && !outputMuted) || (hasInput && !inputMuted)
''',
        '''  readonly property bool anyAudible: (hasOutput && (levelsGuardBlockOutput || !outputMuted)) || (hasInput && (levelsGuardBlockInput || !inputMuted))
''',
    ),
    (
        '''    onWheelMoved: function(delta) {
      if (!root.hasOutput) return
''',
        '''    onWheelMoved: function(delta) {
      if (!root.hasOutput || root.levelsGuardBlockOutput) return
''',
    ),
    (
        '''                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                opacity: root.outputMuted ? 0.5 : 1.0
''',
        '''                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                opacity: root.outputMuted && !root.levelsGuardBlockOutput ? 0.5 : 1.0
''',
    ),
    (
        '''                text: Commons.I18n.formatNumber(Math.round((outputSlider.dragging ? outputSlider.liveValue : root.outputVolume) * 100)) + "%"
''',
        '''                text: root.levelsGuardBlockOutput ? "100%" : Commons.I18n.formatNumber(Math.round((outputSlider.dragging ? outputSlider.liveValue : root.outputVolume) * 100)) + "%"
''',
    ),
    (
        '''              hasCursor: root.cursorActive && root.focusSection === "output" && root.selectedIndex === -1
''',
        '''              hasCursor: root.cursorActive && root.focusSection === "output" && root.selectedIndex === -1 && !root.levelsGuardBlockOutput
''',
    ),
    (
        '''              PanelSlider {
                id: outputSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: 1
                step: 0.05
                value: root.outputVolume
                opacity: root.outputMuted ? 0.5 : 1.0
                enabled: !!root.sink

                onMoved: function(v) { root.setOutputVolume(v) }
                onRightClicked: root.toggleOutputMute()
              }
''',
        '''              PanelSlider {
                id: outputSlider
                visible: !root.levelsGuardBlockOutput
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: 1
                step: 0.05
                value: root.levelsGuardBlockOutput ? 1 : root.outputVolume
                opacity: root.outputMuted && !root.levelsGuardBlockOutput ? 0.5 : 1.0
                enabled: !!root.sink && !root.levelsGuardBlockOutput

                onMoved: function(v) { root.setOutputVolume(v) }
                onRightClicked: root.toggleOutputMute()
              }

              LevelsGuardBar {
                visible: root.levelsGuardBlockOutput
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                bar: root.bar
              }
''',
    ),
    (
        '''              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "output"
                  root.selectedIndex = -1
                }
              }
''',
        '''              HoverHandler {
                onHoveredChanged: if (hovered && !root.levelsGuardBlockOutput) {
                  root.cursorActive = true
                  root.focusSection = "output"
                  root.selectedIndex = -1
                }
              }
''',
    ),
    (
        '''                text: root.inputLevelKnown ? Commons.I18n.formatNumber(Math.round((inputSlider.dragging ? inputSlider.liveValue : root.inputVolume) * 100)) + "%" : "–"
''',
        '''                text: root.levelsGuardBlockInput ? "100%" : root.inputLevelKnown ? Commons.I18n.formatNumber(Math.round((inputSlider.dragging ? inputSlider.liveValue : root.inputVolume) * 100)) + "%" : "–"
''',
    ),
    (
        '''                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                opacity: root.inputMuted ? 0.5 : 1.0
''',
        '''                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                opacity: root.inputMuted && !root.levelsGuardBlockInput ? 0.5 : 1.0
''',
    ),
    (
        '''              hasCursor: root.cursorActive && root.focusSection === "input" && root.selectedIndex === -1
''',
        '''              hasCursor: root.cursorActive && root.focusSection === "input" && root.selectedIndex === -1 && !root.levelsGuardBlockInput
''',
    ),
    (
        '''                PanelSlider {
                  id: inputSlider
                  bar: root.bar
                  width: parent.width
                  minimum: 0
                  maximum: 1
                  step: 0.05
                  value: root.inputVolume
                  opacity: root.inputMuted ? 0.5 : 1.0
                  enabled: !!root.source

                  onMoved: function(v) { root.setInputVolume(v) }
                  onRightClicked: root.toggleInputMute()
                }
''',
        '''                PanelSlider {
                  id: inputSlider
                  visible: !root.levelsGuardBlockInput
                  bar: root.bar
                  width: parent.width
                  minimum: 0
                  maximum: 1
                  step: 0.05
                  value: root.levelsGuardBlockInput ? 1 : root.inputVolume
                  opacity: root.inputMuted && !root.levelsGuardBlockInput ? 0.5 : 1.0
                  enabled: !!root.source && !root.levelsGuardBlockInput

                  onMoved: function(v) { root.setInputVolume(v) }
                  onRightClicked: root.toggleInputMute()
                }

                LevelsGuardBar {
                  visible: root.levelsGuardBlockInput
                  width: parent.width
                  bar: root.bar
                }
''',
    ),
    (
        '''              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "input"
                  root.selectedIndex = -1
                }
              }
''',
        '''              HoverHandler {
                onHoveredChanged: if (hovered && !root.levelsGuardBlockInput) {
                  root.cursorActive = true
                  root.focusSection = "input"
                  root.selectedIndex = -1
                }
              }
''',
    ),
]

NEEDLE = '''  readonly property bool inputMuted: inputViaWpctl ? UntypedInput.muted : (source && source.audio ? source.audio.muted : false)
'''


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch.py <Panel.qml>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    text = path.read_text()
    if "levels-guard guard" in text:
        print("patch.py: already patched", file=sys.stderr)
        return 1
    if text.count(NEEDLE) != 1:
        print("patch.py: anchor block not found exactly once", file=sys.stderr)
        return 1
    text = text.replace(NEEDLE, GUARD, 1)
    for old, new in REPLACEMENTS:
        if text.count(old) != 1:
            print(f"patch.py: snippet not found exactly once: {old.splitlines()[0]}", file=sys.stderr)
            return 1
        text = text.replace(old, new, 1)
    for anchor, insert in INSERTIONS:
        if text.count(anchor) != 1:
            print(f"patch.py: insertion anchor not found exactly once: {anchor.strip()}", file=sys.stderr)
            return 1
        text = text.replace(anchor, insert + anchor, 1)
    path.write_text(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
