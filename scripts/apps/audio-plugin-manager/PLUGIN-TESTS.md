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

## SmartEQ4 (Sonible / smart chain 1.0.0) — VST2 + VST3 — ✅ RESTORED from quarantine
- Installed 2026-09-24 23:46 into ~/.wine-vst, sharing into
  `vst/Sonible/smartEQ4.dll` and `vst3/Sonible/smartEQ4.vst3` (the installer
  wrote them in a `Sonible/` subfolder with OLD archive mtimes — 2024-04-03).
  Both binaries were real: 77 MB each.
- An uninstall then **moved them to the quarantine** on 2026-09-27 01:17
  (`~/.cache/vst-quarantine/20260927-0117{20,24}-uninstall/Sonible/`). The shared
  folder kept only `sonible_onnxruntime_v1-15-1.dll` and the `.nn` models, which
  is why the manager looked "installed" while the host saw nothing:
  the yabridge entries were dangling symlinks and `yabridgectl status` listed
  0 Sonible entries (it only lists what it can resolve).
- **Restored 2026-09-27** — no installer needed, the quarantined files were
  copied back into the shared folders and `yabridgectl sync` re-linked them:
    - `vst/Sonible/smartEQ4.dll`   → VST2, 64-bit, synced
    - `vst3/Sonible/smartEQ4.vst3` → VST3, legacy, 64-bit, synced
    - `plugin-health smartEQ4` → `payload:1, kind:vst3, healthy:true`
  The quarantine copies were left in place as a fallback.
- Two failure modes seen the first time, both real and both still relevant to a
  future re-install:

  - Pre-install MFC42 (ISSKINU.DLL Inno skin runtime) must be AUTOMATIC on every
    Sonible installer — the TUI's non-interactive runner had been silently
    refusing the old prompt, which is why SmartEQ4 kept failing with
    "Cannot import dll: …ISSKINU.DLL".
  - The plugin imports `sonible_onnxruntime_v1-15-1.dll`, which the installer
    drops in the PREFIX system32 while yabridge loads the plugin from the SHARED
    folder under whatever prefix the DAW owns (`wine prefix: <default>`) →
    import_dll not found → Bitwig/REAPER's plugin host died hard at startup
    (exit 134). Fix: `fix_sonible_runtime_deps()` (post_install) copies every
    `sonible_*.dll` runtime NEXT TO each installed sonible plugin.

## CrispyTuner — ⚠️
- Editor needs an input rule; the entry after an install offers the plugin
  setup fix (fix catalog) automatically.

---
Rule: DON'T list a plugin until you have TESTED it in the DAW (load + render +
UI opens), not only "files exist".

## Wine runtime for wine plugins (the install offer)

Two runtimes — the APM Settings screen offers both (Enter toggles):

| runtime | build | use |
|---|---|---|
| **ableton wine-d2d1-nspa 11.13** *(RECOMMENDED)* | the ableton-linux fork | Complete **DirectComposition** + NSPA patches — wine VST3 GUIs that use DComp (Serum 2!) open fine. The SAME runtime Ableton uses, so plugins behave identically in both hosts. |
| system wine-staging 11.17 | stock Arch wine-staging | DComp is **stubbed** → wine VST3 editors that use DComp crash on open (`c0000409` inside dcomp → libyabridge throws → REAPER SIGABRT). Only OK for plugins with plain Win32 GUIs. |

The APM Install flow runs the chosen runtime's wine (shown in the log), and
`yabridgectl sync` sees the same PATH, so scan/run stay coherent. The DAWs must
be launched with the SAME runtime, or an editor that opened fine during the
install will crash later. **REAPER is launched from the app launcher through
`~/.local/bin/reaper-launch`** (the desktop entry `cockos-reaper.desktop` points
there), so that wrapper is what sets the runtime — it now prepends
`~/.local/opt/wine-d2d1-nspa-11.13/bin` to PATH. It used to exec REAPER with the
system wine, which is why Serum 2's editor died on open even though the right
runtime was installed; the fix had been written into a second, never-launched
wrapper (`~/.local/bin/reaper`). Bitwig launches through its own
`fix-daw-wine-runtime.sh` wrapper.

**Tested and loading on this machine**: Serum 2 ✅ (ableton runtime REQUIRED for
its editor — see the REAPER launcher note below), CrispyTuner ✅, ScaleFinder ✅,
SmartEQ4 ✅ (restored from quarantine — see its section above).
`check-all-plugins` now runs clean on all five.

---

## The known plugin library lives in `known-plugins.tsv`

Everything the manager knows about *individual* products — which Wine prefix
they belong in, which Wine runtime their editor needs, whether they need a
32-bit bridge — is in **`known-plugins.tsv`**, next to this file. It used to be a
heredoc inside `lib-audio-plugin-manager-core.sh`, where it could not be
reviewed on its own, extended without editing a 134 KB shell file, or cited in a
report. The file's own header documents every column.

Adding a product means adding one line:

    myvendor|.wine-vst|ableton|unknown|what the runtime column is based on

Match order matters — matching is first-hit-wins on a lowercased substring of
the installer path, so specific tokens go before catch-alls. `runtime` records
only what has been observed on this machine; `unknown` is a deliberate value
meaning nobody has established it, and the wizard says so rather than inventing
a recommendation.

Two commands report what the library currently says:

    mosquito-audio-plugin-manager-actions recommended-prefix /path/to/installer.exe
    mosquito-audio-plugin-manager-actions known-plugin-record /path/to/installer.exe

And two report whether a plugin is actually working, which is a different
question the table cannot answer:

    mosquito-audio-plugin-manager-actions plugin-health smartEQ4
    mosquito-audio-plugin-manager-actions yabridge-check
