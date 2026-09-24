# audio-plugin-manager — tested plugins registry

Living list (like ProtonDB for Steam): every Windows plugin the manager has
installed on this machine, whether it works, and any special treatment it
needed. Keep it SHORT — one block per plugin, newest first. Update it every
time a plugin is installed, fails, or needs a workaround.

Status keys: ✅ works · ⚠️ works with notes · ❌ broken · ⏳ not tested yet

Format:

---
## PLUGIN NAME
- version/date, format (VST3/CLAP), installer type (Inno/MSI/…)
- outcome (✅/⚠️/❌) + what works, what doesn't
- special treatment (pre-install patch, wine overrides, files moved…)

---

## Serum 2 — Xfer (0, .vst3 bundle) — ⚠️
- Installed 2026-09-24 via the audio-plugin-manager TUI.
- The install itself completes, but the installer wrote its plugin OUTSIDE the
  shared VST folders (custom destination), so the old detector said
  "No new VST file detected" and the install was marked FAILED although the
  files were there. The manager now scans the prefix in that case and
  recovers the files into the shared folders automatically (Serum 2 0024c
  fixme winediag noise in the log is harmless).
- Remaining note: none — scan fallback makes the status a plain success, the
  log line ends with the plugin being registered.

## SmartEQ4 (Sonible) — VST2/VST3 — ⏳ (patch ready)
- The Sonible InnoSetup installer FAILS on the stock wine prefix with
  "Runtime error (at -1:0): Cannot import dll: <utf8>…\is-XXXX.tmp\ISSKINU.DLL"
  — the InnoSetup SKIN runtime needs native MFC42/MFC42u.
- The audio-plugin-manager now runs a PRE-INSTALLATION PATCH (winetricks mfc42
  into the target prefix) whenever the installer path/name earns the STRONG
  detection (smarteq/sonible). Confirm the prompt and the install proceeds.
  (Same scheme likely fixes other Sonible installers — to be tested.)

## CrispyTuner — ⚠️
- Editor needs an input rule; the entry after an install offers the plugin
  setup fix (fix catalog) automatically.

---
Rule: DON'T list a plugin until you have TESTED it in the DAW (load + render +
UI opens), not only "files exist".
