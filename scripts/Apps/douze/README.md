# douze + Omarchy360 (SSL 12)

Installs the reverse-engineered SSL 12 control stack on Linux:

- **douze** — USB control daemon + CLI, local web GUI, and the
  Protocol notes in `STUDY.md`.
- **Omarchy360** — native Omarchy overlay mixer for douze. The setup keeps the
  overlay but removes its Quickshell bar icon.
- **PipeWire split** — four stereo sinks (`ssl12.pb12` … `pb78`) from the
  card's Pro Audio 8-channel sink, plus the WirePlumber no-suspend rule.

## Install

```bash
./setup-douze.sh          # interactive
./setup-douze.sh -y       # non-interactive
```

The module is also in `mosquitOmarchy` under **Setup → Apps → douze**.

What it does, in order:

1. installs `python-pyusb`,
2. clones `FenrirRhogar/douze` branch `omarchy360` into
   `~/.local/share/douze` (the fork exposes the extensions Omarchy360 uses;
   `--upstream` tracks `xenicle/douze` instead),
3. writes `/etc/udev/rules.d/70-douze.rules` with `TAG+="uaccess"`
   (70 is before `73-seat-late.rules`; a 99 rule would be ignored),
4. writes and enables the `douze` user service
   (`graphical-session.target`),
5. when the card is connected and in **Pro Audio**, runs douze's
   `install-pipewire.sh` (four stereo loopbacks + WirePlumber rule),
6. installs/enables the Omarchy360 plugin and removes its Quickshell bar
   icon (the overlay stays available).

## Update

```bash
./setup-douze.sh --update
```

The main **mosquitomarchy update** flow also offers `douze` when the checkout
or the plugin has new upstream commits.

## Remove

```bash
./setup-douze.sh --remove    # keeps ~/.config/sslctl and the checkout
./setup-douze.sh --purge     # also deletes the checkout and mixer state
```

## Requirements

- Omarchy with the Quickshell shell (for Omarchy360).
- An SSL 12 in the **Pro Audio** profile.
- `python-pyusb`, `git`, `curl`, `pactl`, `pw-link`, `pw-dump`, `pw-record`.

## Notes

- douze owns the `31e9:0024` control interface; `sslctl` cannot talk to the
  card while the daemon runs.
- The PipeWire split only works in Pro Audio; without it the four sinks load
  but connect to nothing.
- The card forgets its mixer at power-off; douze restores the saved state on
  every start.
- License: douze is **AGPLv3**, Omarchy360 is **MIT**. This module only
  clones/installs them; see `STUDY.md` before copying code into
  mosquitOmarchy (MIT).
