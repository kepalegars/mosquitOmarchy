# mosquitOmarchy — TODO

Single source of truth for open work. Historical detail stays in `JOURNAL.md`
and module docs; tests still owed are in `TESTING.md`.

Last reviewed: 2026-10-30.

## Now

- [ ] Verify the WhatsApp first-show reload on a real reboot: autostart with
      `whatsapp --start-in-tray`, open from the tray, content must appear after
      one reload. The fix is installed (repo and installed `main.js` hashes
      match) and the hidden-start reload was verified by opening a second
      instance on 2026-10-30; the reboot/tray click is still owed. See
      `TESTING.md`.

## Backup / restore

- [ ] **Review VST backup/restore so it covers all plugin-adjacent data**, not
      only the plugin binaries. Today `backup_plugins_archive()` in
      `mosquitomarchy-setup.sh` archives only `VST_DIRS` under the APM plugin
      root (`vst`, `vst3`, `clap`, `clap-native`, `vst3-native`, `lv2`).
      It misses:
      - user presets and plugin settings outside the plugin folder (native
        Linux `~/.config/<vendor>`, `~/.local/share/<vendor>`; Wine prefixes
        `drive_c/users/*/AppData/Roaming`, `Documents`, `ProgramData`,
        `Common Files`);
      - license and activation files (`.lic`, `.dat`, iLok/plugin-manager data);
      - sample libraries and content packs (Kontakt, Serum, etc.), often in
        `~/Music`, `~/Documents`, or external drives;
      - per-DAW preset/cache folders not already in `config-backup.tar.gz`
        (REAPER, Bitwig, Ableton, etc.);
      - plugins installed outside the APM root (`~/.vst`, `~/.vst3`, `~/.clap`,
        `~/.lv2`, yabridge prefixes).
      Deliverable: discover known data roots (ask the APM, then scan),
      inventory them with sizes, archive small config/preset/license data by
      default, offer large sample libraries separately (opt-in), restore to the
      original paths, warn on missing drives/conflicts, and keep secrets out of
      the repo. Update `RESTORE.md` and `TESTING.md`.
- [ ] Test the new backup/restore in a temp HOME: plugin binaries + presets +
      settings + licenses, changed plugin root, `yabridgectl sync`, large-library
      opt-in, encrypted archive.

## Audio stack

- [ ] MixBay EVO 8: handle inputs 3/4 (USB capture CH3/4 + loopback CH5/6).
      The channels stay at zero on this firmware; the vendor init
      (EU51/EU58) still has to be decoded from a USB capture of the Audient app.
- [ ] APM: re-verify the normal single-file install success path after removing
      the abandoned batch work.
- [ ] 1j2: re-verify `setup-audio-stack.sh` `step_vst_menu` against the current
      repo state (entry name now matches; read-through left for a later pass).
- [ ] `ScaleFinder.vst3`: decide whether to restore it from
      `~/.cache/vst-quarantine/` or remove it (lost via the old CrispyTuner
      uninstaller; awaiting the user's word).

## Live mode

Implementation is landed; only user/hardware verification remains. See
`TESTING.md` for the manager row, the real `live-mode on` with the fence ON,
and the activation-prompt cases.

## Ableton Move / Bitwig

- [ ] Ableton Move audio-interface compatibility with Bitwig (Move ↔ Bitwig).
- [ ] **I5** — shared hardware constants used by both `src/ui.js` and
      `Controller Scripts/MoveHardware.js`, so CC numbers cannot drift.
- [ ] **I6** — logging and test setup: document `debug_log_on` + `debug.log`,
      and evaluate schwung's `tools/pytest-schwung` for scripted MIDI injection.
- [ ] **I7 (catalog)** — consider a schwung catalog PR once stable.
- [ ] **Sequencer rework (post-v0.6 priority)** — scope page-follow while
      playing, page indicator, per-step velocity/length view, note-length
      painting, swing/repeat integration, and clips shorter than a page.
- [ ] **Global Key & Scale sync** — blocked by the controller API (checked
      through API 21 / Bitwig 5.3); re-check on new releases.
- [ ] **F25 note repeat** (Shift+Step 11) with a rate menu; needs a hardware
      feel-test for timing jitter.
- [ ] Overview polish: green pulse on blocks containing playing clips.
- [ ] Drum pad sequencer: per-lane view, showing only the selected lane's notes.
- [ ] `suspend_keeps_js` + Back handling: return to the Move browser while the
      Bitwig link persists, resume on re-entry.
- [ ] Aftertouch → channel pressure to Bitwig NoteInput.
- [ ] Java port of the controller script only if JS API 18 becomes a limiter.
- [ ] v0.6 hardware feedback: decide/fix the icon LED row (user reports dim-only,
      not RGB), the Shift+Capture conflict with Schwung Skipback, and the dim
      notes in the per-pad sequencer (user wants them hidden, and nudging should
      address only the selected note).
- Historical detail: `scripts/apps/ableton-move-manager/move-bitwig/HISTORY.md`.

## System modules

- [ ] mx-master: run `./mosquitomarchy-setup.sh` and pick `mx-master` (or
      `sudo bash scripts/plugins/mx-master/mx-master.sh`), then verify logiops
      and the thumb-gesture button on the real device (pending user sudo/live
      check).

## Project hygiene / regression

- [ ] Run regression tests 3.1–3.7 and 3.10 against the current repo state
      (commands and checks in `TESTING.md`).
- [ ] 3.7 Zen config follow-up: live KeePassXC browser integration; optionally
      refresh `seed/extension-settings.json` from the live profile.
- [ ] 3.10 TUI colors auto-adapt to the active Omarchy theme (e.g. lime
      achraff-67) instead of hardcoded `tui-kit` constants.
- [ ] End-of-session review: list commit candidates, ask before any `git push`,
      tidy the README, confirm remaining `sudo` steps (udev rule + Chromium
      policy for the Move module).
- [ ] FINAL full project clean & coherence pass (do last): naming coherence,
      docs-vs-code accuracy, dead code, conventions, `bash -n`/`shellcheck`,
      `.gitignore`, and the deferred `Omarchy_Custom_Scripts_*` →
      `mosquitOmarchy_*` marker rename with a live migration. Produce a short
      report and get sign-off before pushing.

## Dropped / not planned

- `install-many` — abandoned (2026-10-28). The parked action and its README
  section were removed; do not revive it.
