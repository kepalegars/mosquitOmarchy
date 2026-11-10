# mosquitOmarchy — Testing

Things still to test. Implementation work is in `TODO.md`; this file is the
checklist. Run each check against the **current** repo state, not a historical
one.

Last reviewed: 2026-10-30.

## What “regression tests” means

Regression tests re-check behavior that already worked, after a change. They
are not a re-investigation of old bugs: they catch breakage caused by
refactors, renames, shared-helper changes, and install/uninstall edits. A
regression test passes only if the current code still does what the old code
did, with the same user-visible result.

## WhatsApp native

- [x] Hidden start + second instance (2026-10-30): log shows
      `WhatsApp: first show after tray start — reloading`; the captured window
      was dark (mean 0.136, not white). Allow a few seconds for the reload to
      paint.
- [ ] Reboot/login: autostart runs `whatsapp --start-in-tray`; open from the
      tray. The first show must reload once and display content, not a white
      window.
- [ ] Hide/show after that first reload: no extra reload; content stays.
- [ ] Suspend/resume: content returns; log shows
      `WhatsApp: resumed from sleep — reloading` (throttled to one reload per 5 s).
- [ ] GPU crash: kill the GPU process; content returns; log shows
      `WhatsApp: GPU process gone (...)`.
- [ ] Tray click and notification click raise the window.
- [ ] Launch from the menu (no `--start-in-tray`): no first-show reload, content
      visible immediately.
- [x] The installed `~/.local/share/whatsapp-native/app/main.js` matches the
      repo copy (verified 2026-10-30: identical SHA-256).

## Reboot into Windows / douze

- [x] `code/modules/Plugins/reboot-into-windows/test-reboot-into-windows.sh`:
      fake `efibootmgr`/`sudo`/`pkexec`; list, dry-run, `--yes` arms BootNext,
      `--clear-next`, and a missing Windows entry is an error (run against the
      current helper).
- [ ] Real machine: click **System → Reboot into Windows**, let the 15 s run,
      answer `y`, confirm the next boot is Windows and the boot after that is
      Omarchy again (BootNext was consumed).
- [ ] Real machine: answer `n`/timeout, confirm `efibootmgr` shows no BootNext.
- [ ] `douze`: `setup-douze.sh --status` reports `ok` (or only the optional
      PipeWire split when the SSL 12 is not connected); `systemctl --user
      status douze` active; Omarchy360 bar icon opens the mixer; `--update`
      pulls and restarts; `--remove` leaves `~/.config/sslctl` intact.
- [ ] SSL 12 Pro Audio: four `ssl12.pb12/pb34/pb56/pb78` sinks appear; after a
      replug, the loopbacks are repaired (or `install-pipewire.sh` re-run);
      no `resync` spam in `journalctl --user -u pipewire`.
- [ ] Mixbay EVO onboarding: with an EVO connected and `/dev/evo8` absent,
      `mosquito-mixbay` shows the setup prompt; "Later" asks again next launch;
      "Set up" installs and records acceptance.

## Wine installer window (APM)

- [ ] **Automated matcher test** — run
      `code/tests/test-wine-installer-bg.sh`. It fakes `hyprctl` and must move
      only the blank English ("Setup") and Italian ("Installazione") background
      windows, never the real wizard nor an unrelated Wine window.
- [ ] **Real APM install** — install an Inno Setup-based plugin through APM
      (e.g. Arturia Tape MELLO-FI). While the wizard is open:
      `hyprctl clients -j | jq -r '.[] | select(.title|test("Setup|Installazione")) | [.title,.workspace.name] | @tsv'`
      The blank window must be on `special:wine-bg`; the real `... - <product>`
      wizard must stay on the current workspace.
- [ ] **Process-risk check** — before and after the install, capture
      `pgrep -af 'wine|wineserver'` and `hyprctl clients -j`. Confirm the helper
      did not terminate a Wine process, did not move a DAW/plugin editor, and
      that an already-running Ableton still tiles and fullscreens (`SUPER+F`)
      after the install. This is the test that catches a helper matching a
      shared Wine class too broadly.
- [ ] Close the wizard normally; APM must exit, the watcher must disappear
      (`pgrep -f mosquito-wine-installer-bg` empty), and no window may remain on
      `special:wine-bg`.

## Addons / Hyprland autofocus

- [ ] **Extras → Addons**: `emoticon` is listed under `Themes`, with no empty
      categories and no `user/` subcategory. Its circle is empty (not installed).
      Tab toggles it to `●`, then **Enter** shows a Yes/No confirmation listing
      `+ emoticon`. Yes runs `install.sh`; the tree comes back with it installed.
      Untick, Enter, confirm `- emoticon` and `remove.sh` runs. Right/Left fold
      the category; Shift+F searches (hyphen and space are equivalent).
- [ ] Add a temporary addon folder in `code/main tui/addons/` with
      `addon.conf` + `install.sh` and no `remove.sh`; it appears under its
      category, installs, and unticking it reports “kept installed” instead of
      pretending it was removed.
- [ ] Run an update after installing an addon; it must be re-applied at the end
      (`addons-reinstall`), and a removed addon folder must be dropped from
      `~/.local/state/mosquitomarchy/addons-installed`.
- [ ] `fix-hyprland-autofocus.sh --status` reports the block absent. Apply it,
      reload Hyprland, and check that moving the pointer over another window
      does not focus it; `SUPER+F` and `hyprctl getoption input:follow_mouse`
      show `0`. `--remove` restores the old behaviour.

## Mixbay audio foundation / EVO 4

- [x] `mixbay-audio-foundation --status --json` returns valid JSON with
      `default` + `devices[]`; `--needs evo8` exits 0 while udev/WirePlumber/
      defaults are missing (compat helper consumes it).
- [x] `mixbay-audio-foundation --apply --device evo8` without a card writes
      `50-mixbay-interfaces.conf`, `70-mixbay-evo.rules`, the capture helper
      and `mixbay-audio-defaults.service`; records `installed`, sets
      `default=evo8`, and skips the split with a clear message.
- [x] `go test ./...` in `tui-go`: `TestEVOMeterBarsFollowSpec`,
      `TestBetaDeviceRoundTrip`, `TestIsNativeCard` pass.
- [ ] Settings → Audio foundation: list shows every native card with version/
      installed/online; Install/Remove asks for confirmation + audio restart
      warning; the row refreshes after the action; the shared floor survives a
      single-card remove.
- [ ] Settings → Audio foundation → Default: first card set up is selected;
      choosing another card updates `foundation.json` and the defaults service
      sets the right sink/source at next login.
- [ ] Settings → Add an audio interface: with a Quantum ES 4 (or another USB
      card) connected, it appears in the scan (not the EVO/SSL/RME/ESI ones);
      adding it shows `demo-beta`/`online-beta`, opens the reverse-engineering
      plan, and persists in `beta-devices.json`.
- [ ] Beta controls: Restart reverse engineering asks for confirmation and
      shows the capture-harness plan; ALSA level 1 volume/mute works.
- [ ] SSL 12: native row; "Set up / repair SSL 12" runs the douze installer
      from the TUI and refreshes the Omarchy360 plugin; after setup the row is
      online; "Open Omarchy360 mixer" opens the Quickshell overlay;
      volume/mute/mixer map through douze.
- [ ] Settings → Listed interfaces: Only connected / All supported / Only used.
      Check the connection log (`connected-interfaces.json`) filters "Only
      used" and that a never-connected card is absent from the foundation
      CARDS and default lists.
- [ ] Settings → Audio foundation → Default: selected card has a filled ●,
      others no marker; any ever-connected card is selectable; default line
      has no "enter to change".
- [ ] Settings → Audio foundation → Reset connection history: confirmation,
      log cleared, installed configs kept, currently connected cards
      repopulate after the next scan.
- [ ] Settings → Launch Mixbay at startup / Launch in scratchpad: both on by
      default; toggling startup adds/removes the `o.launch_on_start` line;
      scratchpad parks the TUI in `special:scratchpad` at login.
- [ ] PipeWire settings bar icon: centred, slightly smaller, aligned with the
      other bar icons (shell restart may be needed to reload the QML).
- [ ] EVO header: `Audient EVO 8 - v1.0.0`; offline blinks only the hollow
      connection dot, not the name/version; no duplicate card version on the
      card screen. RME/ESI show v0.0.1; beta shows `beta`.
- [ ] PreSonus Quantum ES 4 is absent from the native device list and present
      in the Add-interface scan.
- [ ] Real EVO 8: `--apply` with the card in Pro Audio writes
      `50-mixbay-evo.conf`; `evo8_main_output` / `evo8_mic_1_2` exist; default
      sink/source are set; app audio on `evo8_output_3_4` reaches output 3+4.
- [ ] Real EVO 4: open LEVELS, bars move (4 channels); if the UCM exposes split
      mono nodes, record the actual node layout and adjust
      `discoverEvoNode`/the bar mapping.
- [ ] Rate: graph and device rate match at 48 kHz; a 96 kHz stream with
      `allowed-rates` including 96000 does not report a false mismatch; a real
      mismatch is flagged.
- [ ] `pipewire-settings` owns the clock: the foundation does not write
      `50-mixbay-audio.conf` and reports "managed by pipewire-settings".

## Regression suite (3.x)

- [ ] **3.1 Orchestrator** — `./mosquitomarchy-setup.sh --status`; per-module
      `st_`/`un_` (including the 4 move bins); update/exclude/uninstall roles;
      `MODULES` descriptions.
- [ ] **3.2 Backup/restore** — `./mosquitomarchy-setup.sh --backup` to `/tmp`,
      then `--restore`; verify config, package lists, apps selection, and the
      VST archive/restore.
- [ ] **3.3 Bootstrap** — `./bootstrap.sh` against a real GitHub
      connection (`curl … | bash -s -- --status`) without triggering a full
      install at `$HOME`; check `--zips` demo/status-only.
- [ ] **3.4 Keybindings** — the TUI Keybindings screen (the old standalone
      script is gone): managed list, add a binding, remove one, reset, and
      confirm `bindings.lua` keeps the marker block valid and Hyprland reloads.
- [ ] **3.5 Update watchdog** —
      `code/main tui/update/setup-mosquitomarchy-update.sh` plus
      `./mosquitomarchy-setup.sh --update-repo`: detects an update without
      pushing and notifies; never pushes without explicit authorization.
- [ ] **3.6 Archive** — `./archive-mosquitomarchy.sh --list` and
      `--type=source`; `tar tzf` the result; confirm large installers
      (Ableton/DaVinci/Guitar Pro) are filtered and nothing large is committed.
- [ ] **3.7 Zen / KeePassXC** — `code/modules/Apps/zen/setup-zen.sh` seeds the active
      profile (plugins/settings/chrome); live KeePassXC browser integration via
      `code/modules/Apps/keepassxc/setup-keepassxc-integration.sh`; optionally
      refresh `seed/extension-settings.json` from the live profile. Verify the
      module scripts install their own missing runtime packages; the backup
      excludes external tools that have no module folder.
- [ ] **3.10 TUI colors** — switch Omarchy themes (including the lime
      achraf67 reference); every TUI (mosquitomarchy, APM, live-mode, move,
      mixbay, jamjamjam) must follow the active palette, with no hardcoded
      colors.
- [ ] **General** — `bash -n` (and `shellcheck` if available) on changed
      scripts; `hyprctl configerrors` empty; `go test ./...` in the TUI modules.
      Known: the full `code/main tui/go` suite exceeds 120 s,
      so use the targeted package tests rather than assuming a failure.

## VST backup / restore (new coverage)

- [ ] Backup includes plugin binaries + user presets + plugin settings +
      license/activation files.
- [ ] Large sample libraries are inventoried and opt-in, not silently archived.
- [ ] Restore into a temp HOME: every file lands at its original path.
- [ ] Change the APM plugin root between backup and restore: restore uses the
      current root and warns on a mismatch.
- [ ] `yabridgectl sync` after restore; plugins are visible in a DAW.
- [ ] Encrypted archive: passphrase prompt, wrong passphrase, and
      `OMARCHY_BACKUP_PASSPHRASE` non-interactive.
- [ ] No secrets, passwords, or large installers in the repo; the backup store
      stays in `mosquitomarchy-backups/`.

## Live mode

- [ ] Manager row: ←/→ and Tab on the package-fence row; persisted
      `FENCE_PACKAGES`.
- [ ] Manager row: ←/→ and Enter on `Relaunch closed apps on deactivation`;
      `RELAUNCH_APPS=yes` starts the closed app(s) at `off`, default off.
- [ ] Activation prompt: names only the background apps actually running.
- [ ] `off`: `quiet.json` is back to its pre-session DND value (off stays off).
- [ ] During a session the four default theme/background chords are absent from
      `hyprctl binds`; a custom chord bound to the theme menu still opens it;
      `off` restores the defaults.
- [ ] `omarchy theme list` never contains "Live" (off, and during a session).
- [ ] The Live theme shows the branded red "LIVE MODE" wallpaper, not plain
      black.
- [ ] Scratchpad: mixbay AND qpwgraph are both `floating=false` on
      `special:scratchpad`; same after refusing the watchdog's close prompt.
- [ ] Activation card on a laptop says "Always awake (even with the lid
      closed)"; on a desktop (no `/proc/acpi/button/lid`) the parenthesis is
      absent.
- [ ] `on` never asks the power-profile question; the profile is already
      `performance` when the watchdog starts.
- [ ] Manager hint bar: "enter toggle / select" and "←/→ change value".
- [ ] Manager rows: `Disable passwordless sudo on activation` and `Lock
      PipeWire settings during live mode`, both On by default.
- [ ] PipeWire Settings during live mode: Force/Remember hidden, values greyed
      with no arrows, no selection when autolock is on; `l` opens the inline
      confirmation (same panel size); Enter on "Unlock" restores arrows/editing;
      `l` locks again immediately with the legend switching to "L unlock";
      with `PIPEWIRE_AUTOLOCK=no` the panel starts unlocked.
- [ ] `DISABLE_PASSWORDLESS_SUDO=yes`: after `on`, broad `NOPASSWD: ALL`
      drop-ins are gone, the scoped live-mode-root rule is present, and
      `off`/the thermal guard still work. Nothing restores the broad grants.
- [ ] Real `live-mode on` with the fence ON: pacman is refused; `live-mode off`
      releases the lock.
- [ ] A lock held by a running pacman is never deleted by restore.
- [ ] Activation prompt: everything on, everything off, fence only, empty app
      list, one-key settings file; only enabled lines are announced.
- [ ] Restore with no pre-state and a free lock: lock cleaned.

## Touchpad / browser

- [ ] In Zen, touchpad scrolling has **no kinetic momentum** and keeps the
      stock speed (`scroll_touchpad = 0.5`), while another app still gets the
      kinetic glide and the `1.8` factor. `hyprctl configerrors` stays empty.
- [ ] After a Zen restart, `about:config` shows
      `apz.gtk.kinetic_scroll.enabled = false` and
      `general.smoothScroll = false` (from `user.js`).

## Health check

- [ ] With a deliberate Hyprland config error (e.g. an invalid window-rule
      value), Health check shows the error text as a manual row (badge `!`);
      Enter never sends it to heal.
- [ ] With `hyprpm` missing (or hidden from `PATH`), Health check lists
      `hyprpm` and the kinetic-scroll plugin; ticking them installs the
      package and reloads the plugin.
- [x] Manual findings are not ticked by default and are excluded from
      `healthKeys` (Go test `TestHealthManualFindingCannotBeTicked`).

## MixBay / audio hardware

- [ ] EVO 8 inputs 3/4: USB capture CH3/4 and loopback CH5/6; decode vendor init
      EU51/EU58 with a USB capture of the Audient app.
- [ ] Re-check mixbay status/live behavior on the EVO 8 after any driver change.

## Ableton Move / Bitwig hardware

- Status: v0.6 hardware pass is done; retest only after the sequencer rework.
- [ ] v0.6 user feedback: icon LED row may be dim-only (not RGB); Shift+Capture
      conflicts with Schwung Skipback; dim notes in the per-pad sequencer are
      unintuitive (user wants them hidden, and nudging should address only the
      selected note).
- [ ] Sequencer rework: page-follow, page indicator, per-step velocity/length,
      note-length painting, short clips, swing/repeat.
- [ ] I5/I6: shared hardware constants; `debug_log_on` + `debug.log`; scripted
      MIDI injection against real hardware.
- [ ] Suspend/Back handling; aftertouch → channel pressure.
