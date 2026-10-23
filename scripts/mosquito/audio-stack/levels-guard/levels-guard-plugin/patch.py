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
  readonly property bool levelsGuardManagedOutput: {
    var n = volumeSink && volumeSink.name ? String(volumeSink.name) : ""
    return n.indexOf("alsa_output.usb-Audient_EVO") === 0
  }
  readonly property bool levelsGuardManagedInput: {
    var n = source && source.name ? String(source.name) : ""
    return n.indexOf("alsa_input.usb-Audient_EVO") === 0
  }
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

REPLACEMENTS = [
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
        '''    onWheelMoved: function(delta) {
      if (!root.hasOutput) return
''',
        '''    onWheelMoved: function(delta) {
      if (!root.hasOutput || root.levelsGuardBlockOutput) return
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
    path.write_text(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
