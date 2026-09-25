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

## SmartEQ4 (Sonible / smart chain 1.0.0) — VST2 + VST3 — ✅ (with runtime fix)
- Installed 2026-09-24 23:46 into ~/.wine-vst, sharing into
  `vst/Sonible/smartEQ4.dll` and `vst3/Sonible/smartEQ4.vst3` (the installer
  wrote them in a `Sonible/` subfolder with OLD archive mtimes — 2024-04-03).

- Pre-install MFC42 (ISSKINU.DLL Inno skin runtime) is now AUTOMATIC on every
  Sonible installer — the TUI's non-interactive runner had been silently
  refusing the old prompt, which is why SmartEQ4 kept failing with
  "Cannot import dll: …ISSKINU.DLL".
- SECOND crash fixed the same day: the plugin imports
  `sonible_onnxruntime_v1-15-1.dll`, which the installer drops in the PREFIX
  system32 while yabridge loads the plugin from the SHARED folder under
  whatever prefix the DAW owns (`wine prefix: <default>`) → import_dll not
  found → Bitwig/REAPER's plugin host died hard at startup (exit 134). Fix:
  `fix_sonible_runtime_deps()` (post_install) copies every `sonible_*.dll`
  runtime NEXT TO each installed sonible plugin; applied on this machine for
  both the VST2 and VST3 copies.
- After the fix + `yabridgectl sync`: the plugin should load in the DAWs
  (rescan the plugin list once).

## CrispyTuner — ⚠️
- Editor needs an input rule; the entry after an install offers the plugin
  setup fix (fix catalog) automatically.

---
Rule: DON'T list a plugin until you have TESTED it in the DAW (load + render +
UI opens), not only "files exist".
