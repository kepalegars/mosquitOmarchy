# Presets folder

Drop your HandBrake preset **exports** here (GUI → **Presets** panel →
right-click → **Export…** → `*.json`), then run:

```bash
./apps/handbrake/setup-handbrake.sh
```

The install merges the files into `~/.config/ghb/presets.json` under an
**"Omarchy"** category (idempotent: re-running refreshes the category).

## Accepted formats

HandBrake exports are JSON; each file may contain:

- a plain **list of presets/folders** (the Linux `presets.json` format)

```json
[
  {
    "PresetName": "Omarchy H264 1080p",
    "VideoEncoder": "x264",
    "VideoQualitySlider": 20
  }
]
```

- or a version wrapper with a `PresetList` array:

```json
{ "VersionMajor": 1, "VersionMinor": 0, "VersionMicro": 0,
  "PresetList": [ { "PresetName": "Omarchy H265 4K", "VideoEncoder": "x265" } ] }
```

Invalid/corrupt files are skipped with a message — the rest is still imported.
Files are merged in alphabetical order; a duplicate `PresetName` is kept once
(last file wins).

## Notes

- Close HandBrake before re-running the install (it rewrites `presets.json`
  when it exits).
- A backup of the previous `~/.config/ghb/presets.json` is kept as
  `presets.json.bak-<timestamp>`.
- These presets are personal configuration: it's up to you to commit them to
  the repo or not (the scripts work either way).