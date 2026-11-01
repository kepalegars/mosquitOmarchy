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

- [ ] **Mixbay — fork the whole interface and embed as much of douze/Omarchy360
      as possible**, then decline it across the maximum number of interfaces and
      extend compatibility as far as possible. The concrete first step is the
      compatibility/onboarding layer (below), not a copy of the SSL 12 UI:
      keep the driver registry as the only device boundary, add a per-interface
      "needs setup" descriptor, and let the UI render whatever the descriptor
      advertises. Long-term: a shared control abstraction (direct USB ioctl /
      ALSA / vendor HTTP daemon) so the same strips, meters and monitor section
      work for EVO, SSL 12, RME, PreSonus, ESI and future boxes.
- [ ] **Mixbay — first-connection onboarding prompt** (started: `compat/
      interface-onboarding.sh`, the EVO check in the `mosquito-mixbay`
      dispatcher, and the `foundation/audio-foundation.sh` pack). The goal:
      when a compatible interface is opened in its panel for the first time,
      show a prompt (until the user accepts it) that adds what the interface
      needs:
      - udev rule if the control endpoint is vendor-specific (TAG+="uaccess"
        must be numbered **below 73**; a 99-* rule is silently ignored),
      - `evo_raw` kernel module + EVO 8 capture rule for EVO,
      - PipeWire split of the Pro Audio 8-channel sink into stereo loopbacks
        (`ssl12.pb12` … `pb78`), with `node.passive`, `dont-reconnect` and
        `target.object` pointing at the card's serial-bearing node name,
      - WirePlumber `session.suspend-timeout-seconds = 0` for passive loopbacks,
      - service/daemon install, state and profile directory.
      Still to do: move the prompt from the dispatcher (launch) into the TUI's
      device-selection path, persist acceptance per interface, and make the
      Apply action stream progress instead of blocking on the full installer.
- [ ] **Mixbay — audio foundation pack** (implemented, needs hardware
      validation): `foundation/audio-foundation.sh` is applied by default by
      the installer and by the onboarding prompt. It owns seat udev access,
      WirePlumber anti-suspend/no-upmix, the EVO 8 stereo split, default
      sink/source, clock defaults when `pipewire-settings` does not own them,
      and a rate/mismatch health report. Settings → Audio foundation now lists
      cards and supports per-card **install/remove with confirmation** and a
      **default/priority card** (first card set up wins). Remaining:
      - validate the EVO 8 split and the EVO 4 Levels page on real hardware;
      - extend the per-card split/profile logic to RME, ESI, SSL 12 and beta
        cards (the generic anti-suspend/no-upmix rule already covers them);
      - decide whether `--force-evo4-split` should become the default on
        systems whose UCM is older than 1.2.16.
- [ ] **Audio foundation — full test plan** (do after the next hardware
      session):
      1. Fresh HOME, no card: `--status --json` valid; `--apply --device
         evo8` writes udev/WirePlumber/defaults, skips the split with a clear
         message, records `installed`, sets `default=evo8`.
      2. EVO 8 in Pro Audio: split file generated from the live node; six
         virtual nodes appear; `evo8_output_3_4` audio reaches output 3+4;
         `evo8_mic_1_2` captures; default sink/source set by the service.
      3. EVO 4: Levels 4 bars (IN1/2 + LP3/4, PC1/2 + LP3/4); meters move;
         no EVO 8-only path; UCM split-mono case recorded.
      4. Per-card remove: EVO 8 split/default mapping removed, shared
         WirePlumber rule kept while SSL 12/another card is installed; udev
         seat rule removed only when no EVO remains; re-install restores it.
      5. Default card: first setup becomes default; Settings → Default audio
         interface changes it; service applies the chosen sink/source at login
         and after hot-plug (manual `mixbay-audio-defaults` after connect).
      6. Rate: 48 kHz graph/device match; 96 kHz allowed does not false-flag;
         a real mismatch is flagged; `pipewire-settings` owns the clock and
         the foundation writes no `50-mixbay-audio.conf`.
      7. SSL 12: setup from Mixbay (douze/udev/service/split/plugin), native
         row online, mixer/volume/mute mapping, Open Omarchy360, remove leaves
         `~/.config/sslctl` intact.
      8. Beta: Add an audio interface scans USB, adds Quantum ES 4 as
         `demo-beta`/`online-beta`, ALSA level 1 works, Restart reverse
         engineering asks for confirmation, removal removes the beta entry.
      9. Uninstall Mixbay: foundation files/udev/default service removed,
         capture helper removed, `pipewire-settings` config untouched.
- [ ] **Mixbay — architecture review** (whole feature, after the test plan):
      map every boundary (`drivers.Driver`, `Spec`, `Caps`, beta specs, douze
      HTTP driver, foundation shell, TUI screens, state files), look for
      duplication between the foundation and the module installers, verify
      the "one source of truth" rule for udev/PipeWire/defaults, check
      idempotence and rollback, and decide whether the reverse-engineering
      harness belongs in Go, Python or the shell.
- [ ] **Mixbay — pro-audio protocol reference** (delivered 2026-10-31:
      `scripts/mosquito/audio-stack/mixbay/docs/AUDIO-PROTOCOLS-LINUX.md`).
      It covers Dante, ADAT, MADI, AES3/S/PDIF, AES67/RAVENNA, AVB/MILAN,
      AES50/SuperMAC, Waves SoundGrid, EtherSound/CobraNet, Livewire/Q-LAN,
      SDI embedded, USB/Thunderbolt/FireWire/PCIe, macOS aggregate devices and
      drift correction, plus the native-Linux support tiers. Remaining: keep it
      current when a card is promoted to native, add the hardware-validation
      column after each test session, and link every new backend to its
      upstream project and licence.
- [ ] **Mixbay — aggregate devices + drift correction** (design in
      `docs/AUDIO-PROTOCOLS-LINUX.md` §6, implementation NOT started). Model a
      clock domain per card (internal / word clock / ADAT / MADI / AES3 /
      Dante PTP / USB feedback) and add a Settings → Aggregate screen:
      member cards, sync source, sample rate, per-member drift correction,
      latency, channel map, saved profiles, health (ppm, xruns, estimated
      added latency). Implement with PipeWire `libpipewire-module-combine-stream`,
      `libpipewire-module-loopback`, `priority.driver`, `clock.name` and the
      adaptive resampler — do **not** write an audio server. Default drift
      correction ON for members with no shared hardware clock; OFF when
      `clock.name` matches. Never claim bit-perfect when resampling. Test with
      two unsynchronised USB cards, then with a word-clocked pair.
- [ ] **Mixbay — Dante protocol in the audio foundation** (design in
      `docs/AUDIO-PROTOCOLS-LINUX.md` §8, implementation NOT started).
      Explicit upstream: `inferno` <https://github.com/teodly/inferno>
      (GPL-3.0-or-later / AGPL-3.0, unofficial, user-space) and
      `network-audio-controller` <https://github.com/chris-ritsen/network-audio-controller>.
      Put it in `foundation/` (or a sibling `dante/` module), not in the USB
      driver registry:
      - detect Dante devices over mDNS (`_netaudio-arc._udp`,
        `_netaudio-cmc._udp`, `_netaudio-chan._udp`) and the usual UDP ports
        (4455/8700/4400/8800/5353); inspect `ethtool -T` and `/dev/ptp*`;
      - first-connection onboarding: explain that Dante is proprietary and
        that `inferno` is unofficial, then offer Install / Later;
      - install/build `inferno` + the Statime PTPv1 fork, write the network
        profile (interface, `DEVICE_ID`, `NAME`, RX/TX channels, latency),
        open the required ports, create the ALSA `inferno` PCM, split it into
        PipeWire nodes, optionally save a patchbay preset;
      - persist the profile per device and never auto-start during a live show;
      - UI must state the limits: no Dante Domain Manager, no native AES67,
        PTP/NTP conflicts, latency depends on kernel/NIC, unofficial status.
      - A Dante PCIe card (Yamaha AIC128-D, RedNet PCIe, etc.) is treated as a
        network/AES67 device, not as a USB card; do not claim a kernel driver.
- [ ] **Mixbay — Apollo native driver port** (design in
      `docs/AUDIO-PROTOCOLS-LINUX.md` §9, implementation NOT started).
      Explicit upstream: `open-apollo`
      <https://github.com/rolotrealanis98/open-apollo> (GPL-2.0, experimental).
      Do **not** reimplement the kernel module in Go. Port the whole stack as
      an optional backend:
      - vendor/pin the `ua_apollo` DKMS module, udev rules, firmware extraction
        path (`oa-assets`) and the mixer daemon (TCP 4710/4720/4721);
      - add a Mixbay driver that speaks to the daemon, maps `Spec`/`Caps`
        (preamps, 48 V, PAD, low cut, phase, monitor, DSP mixer, meters) and
        falls back to ALSA level 1 when the daemon is absent;
      - model table for every Apollo (x4, x4 Gen 2, x6, x8, x8p, x16, x16D,
        Twin X, Solo, Arrow, USB Solo/Twin) with a verified/untested column;
      - refuse Thunderbolt 2 explicitly and explain why (no PCIe enumeration);
      - handle Secure Boot/MOK, hot-unplug, power-cycle and suspend/resume;
      - "Open uaconsole" for the full console instead of duplicating it;
      - test on x4/x8p/Solo USB before calling it supported, and keep the
        experimental warning in the UI until then.
- [ ] **Mixbay — Add an audio interface / reverse engineering** (menu added,
      real harness landed: `harness/mixbay-reverse.py`, deployed as
      `mixbay-reverse`; Settings → Reverse engineering harness and the beta
      card shortcut both launch it, and **Add an audio interface** launches
      the guided mode right after storing the beta card). The harness captures
      usbmon text, discovers the card channels from PipeWire/pactl, merges
      submission/callback by URB, diffs a quiet baseline against one action per
      control, labels/stores each session, shows a final confirmation, and
      replays only captured bytes with GET/acks, `--dry-run` and an explicit
      `REPLAY` confirmation. Remaining:
      - map the universal EVO 8 model (strips, gains, 48V, mixer, meters)
        onto captured controls, and promote a beta card to native only after
        hardware verification;
      - add HID multi-byte report reconstruction and timing-accurate replay
        for cards that need it;
      - derive the smallest safe write sequence per control from the captured
        window instead of replaying the whole window;
      - persist the captured map into the driver spec and keep the "beta"
        flag until then;
      - test the harness on the Quantum ES 4 and one SSL 12/EVO capture, and
        record the exact commands in `harness/README.md`.
- [ ] **SSL 12 — native Mixbay integration** (first slice landed): native
      entry via douze (volume/mute/mixer, setup from Mixbay, Open Omarchy360).
      Remaining: preamps/48V, bus labels (Monitor/Line 3-4/HP A/HP B instead
      of MIX 1|2), meters from douze, profiles, and the EVO-style full
      surface. Keep Omarchy360 as the complete SSL 360 surface meanwhile.
- [x] EVO 4 Levels: the Levels page is now spec-driven (4 bars: IN1/2 +
      LP3/4, PC1/2 + LP3/4), the USB node is discovered from the live graph,
      and EVO 4 is no longer kicked out of the screen. Needs a real EVO 4
      check (the UCM may expose split mono nodes instead of one 4-channel node).
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
- Historical detail: `scripts/mosquito/move-manager/move-bitwig/HISTORY.md`.

## System modules

- [ ] mx-master: run `./mosquitomarchy-setup.sh` and pick `mx-master` (or
      `sudo bash scripts/Plugins/mx-master/mx-master.sh`), then verify logiops
      and the thumb-gesture button on the real device (pending user sudo/live
      check).

## Project hygiene / regression

- [ ] **Create the remote per-module repos** (monorepo canonical + generated
      mirrors): add `modules.json` (module id → path → remote → tag prefix),
      `scripts/lib/modules-sync.sh` (`git subtree split -P <path> -b
      sync/<id>` then push), and a GitHub Actions workflow on tags. Create the
      `mosquitOmarchy-<module>` repositories with `gh repo create`, push the
      mirrors, and document that the monorepo is the source of truth. Do not
      use submodules for code that also lives in the monorepo.

- [ ] Run regression tests 3.1–3.7 and 3.10 against the current repo state
      (commands and checks in `TESTING.md`).
- [ ] 3.7 Zen config follow-up: live KeePassXC browser integration; optionally
      refresh `seed/extension-settings.json` from the live profile.
- [ ] 3.10 TUI colors auto-adapt to the active Omarchy theme (e.g. lime
      achraf67) instead of hardcoded `tui-kit` constants.
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
