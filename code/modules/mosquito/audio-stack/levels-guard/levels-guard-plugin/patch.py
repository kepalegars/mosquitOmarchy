#!/usr/bin/env python3
"""Patch Omarchy's audio Panel.qml with the Levels Guard.

The installer refuses to refresh once the upstream audio plugin changes, so
these exact snippets are pinned to the Omarchy release this repo targets. A
missing snippet is a hard error, never a silently half-patched panel.
"""

from pathlib import Path
import sys

GUARD = '''  readonly property bool inputMuted: source && source.audio ? source.audio.muted : false

  // levels-guard guard: USB hardware volume belongs to mosquitomixbay.
  // It only ignores the native surfaces; direct pactl/wpctl stays untouched.
  property bool levelsGuardAllowNative: false
  function levelsGuardManagedInterface(name, prefix) {
    var n = String(name || "").toLowerCase()
    if (n.indexOf(prefix) !== 0) return false
    return n.indexOf("audient_evo") >= 0
        || n.indexOf("fireface") >= 0
        || n.indexOf("ugm192") >= 0
        || n.indexOf("quantum_es") >= 0
  }
  readonly property bool levelsGuardManagedOutput: levelsGuardManagedInterface(volumeSink && volumeSink.name, "alsa_output.usb-")
  readonly property bool levelsGuardManagedInput: levelsGuardManagedInterface(source && source.name, "alsa_input.usb-")
  readonly property bool levelsGuardBlockOutput: levelsGuardManagedOutput && !levelsGuardAllowNative
  readonly property bool levelsGuardBlockInput: levelsGuardManagedInput && !levelsGuardAllowNative
  FileView {
    id: levelsGuardPrefs
    path: Quickshell.env("HOME") + "/.config/mosquitomixbay/ui.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      var allow = false
      try {
        var o = JSON.parse(text())
        allow = !!(o && o.allow_native_volume)
      } catch (e) {}
      root.levelsGuardAllowNative = allow
    }
    onLoadFailed: root.levelsGuardAllowNative = false
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
        '''  function outputIcon(volume) {
    // Match the old Waybar pulseaudio glyph set. The Material Design speaker
    // icons render visually smaller in JetBrainsMono Nerd Font.
    if (!sink || !sink.audio) return ""
    if (isHeadphones(sink)) return "󰋋"
    if (outputMuted) return ""
''',
        '''  function outputIcon(volume) {
    // Match the old Waybar pulseaudio glyph set. The Material Design speaker
    // icons render visually smaller in JetBrainsMono Nerd Font.
    if (!sink || !sink.audio) return ""
    if (isHeadphones(sink)) return "󰋋"
    if (levelsGuardBlockOutput) return ""
    if (outputMuted) return ""
''',
    ),
    (
        '''  function inputIcon() {
    if (!source || !source.audio) return "󰍭"
    return inputMuted ? "󰍭" : "󰍬"
  }
''',
        '''  function inputIcon() {
    if (!source || !source.audio) return "󰍭"
    if (levelsGuardBlockInput) return "󰍬"
    return inputMuted ? "󰍭" : "󰍬"
  }
''',
    ),
    (
        '''  function outputVolumeName(volume, muted) {
    return Model.outputVolumeName(volume, muted)
  }
''',
        '''  function outputVolumeName(volume, muted) {
    if (levelsGuardBlockOutput) return Model.outputVolumeName(1, false)
    return Model.outputVolumeName(volume, muted)
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
    if (!source || !source.audio) return
''',
        '''  function setInputVolume(v) {
    if (!source || !source.audio || levelsGuardBlockInput) return
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
    if (source && source.audio) source.audio.muted = !source.audio.muted
  }''',
        '''  function toggleInputMute() {
    if (levelsGuardBlockInput) return
    if (source && source.audio) source.audio.muted = !source.audio.muted
  }''',
    ),
    (
        '''  function toggleAllMuted() {
    var mute = anyAudible
    if (hasOutput) volumeSink.audio.muted = mute
    if (hasInput) source.audio.muted = mute
  }''',
        '''  function toggleAllMuted() {
    var mute = anyAudible
    if (hasOutput && !levelsGuardBlockOutput) volumeSink.audio.muted = mute
    if (hasInput && !levelsGuardBlockInput) source.audio.muted = mute
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
        '''              opacity: root.outputMuted ? 0.5 : 1.0
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
''',
        '''              opacity: root.outputMuted && !root.levelsGuardBlockOutput ? 0.5 : 1.0
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
''',
    ),
    (
        '''                text: Math.round((outputSlider.dragging ? outputSlider.liveValue : root.outputVolume) * 100) + "%"
''',
        '''                text: root.levelsGuardBlockOutput ? "100%" : Math.round((outputSlider.dragging ? outputSlider.liveValue : root.outputVolume) * 100) + "%"
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
        '''                text: Math.round((inputSlider.dragging ? inputSlider.liveValue : root.inputVolume) * 100) + "%"
''',
        '''                text: root.levelsGuardBlockInput ? "100%" : Math.round((inputSlider.dragging ? inputSlider.liveValue : root.inputVolume) * 100) + "%"
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

NEEDLE = '''  readonly property bool inputMuted: source && source.audio ? source.audio.muted : false
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
