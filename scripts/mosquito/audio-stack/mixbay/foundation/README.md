# Mixbay audio foundation

**Yes, a complete default pack is feasible — as a conservative foundation, not
as one config forced on every card.** The interfaces Mixbay supports do not
share a channel layout:

| Interface | USB channels | What the card needs |
|---|---|---|
| Audient EVO 8 | 6 playback / 6 capture | no ALSA UCM → split into stereo nodes |
| Audient EVO 4 | 4 / 4 | ALSA UCM ≥ 1.2.16 already exposes the right graph |
| RME Fireface UCX II | multichannel | class-compliant; TotalMix not in this pack |
| ESI UGM192 | stereo | class-compliant |
| PreSonus Quantum ES 4 | beta | base de test reverse engineering (pas native) |
| SSL 12 (douze) | 8 / 8 in Pro Audio | split already owned by the douze module |

So the pack has **one shared floor** and **per-card extensions**:

```
shared floor (all supported interfaces)
  udev seat access (uaccess, no dialout re-login)
  WirePlumber: no idle suspend, no upmix
  clock policy + rate/mismatch health

per card
  EVO 8  : 6→3 stereo playback sinks + 3 stereo capture sources
  EVO 4  : UCM (opt-in 4-channel split only when UCM is absent)
  SSL 12 : douze's own split + WirePlumber rule (not duplicated here)
  others : floor only, until their control protocol is integrated
```

## What is applied by default

`setup-mosquitomixbay.sh` runs `audio-foundation.sh --apply` after the EVO
capture helper. The onboarding prompt (`mosquito-mixbay-compat`) also reports
the same missing steps, so both surfaces agree.

1. **udev** — `/etc/udev/rules.d/70-mixbay-evo.rules`:
   `TAG+="uaccess"` for `KERNEL=="evo4"` and `KERNEL=="evo8"`. The kmod's own
   rule grants `GROUP="dialout"`; this adds the logged-in seat user without a
   re-login. The EVO 8 capture helper/rule is installed too.
2. **WirePlumber** — `50-mixbay-interfaces.conf`: matches Audient, RME, ESI,
   PreSonus and SSL 12 USB nodes and sets
   `session.suspend-timeout-seconds = 0`, `node.pause-on-idle = false`,
   `channelmix.upmix = false`. This is the fix for passive loopbacks going
   idle and PipeWire resyncing forever (crackles, chopped voice).
   `api.alsa.soft-mixer` is **not** set: Mixbay owns the hardware volume.
3. **EVO 8 split** — generated from the live `pw-link` graph, never a hardcoded
   machine name:
   - `evo8_main_output` → playback CH1/2
   - `evo8_output_3_4` → CH3/4
   - `evo8_loopback_output` → CH5/6
   - `evo8_mic_1_2` → capture CH1/2
   - `evo8_mic_3_4` → CH3/4
   - `evo8_loopback_capture` → CH5/6
   Passive loopback is used on the **source** side only; putting it on the
   playback side silences the output.
4. **Defaults** — `mixbay-audio-defaults.service` (user, graphical session)
   sets `evo8_main_output` and `evo8_mic_1_2` as default sink/source when they
   appear.
5. **Clock** — if `pipewire-settings` already owns the clock
   (`90-mosquitomarchy-pipewire.conf`), the pack writes nothing. Otherwise
   `50-mixbay-audio.conf`: 48 kHz default, 44.1–192 kHz allowed, quantum 1024,
   min/max 64/2048.

## Rate / mismatch policy

- **Do not force a rate the card is not running at.** The pack reads the graph
  rate (`pw-metadata -n settings 0`) and the device rate
  (`/proc/asound/card*/pcm*/sub*/hw_params`) and reports a mismatch.
- `allowed-rates` lets a 96/192 kHz stream switch only when every node agrees;
  a stereo app stays at 48 kHz.
- `pipewire-settings` remains the place to pin/force a rate and buffer. The
  foundation never fights it.

## Per-card install and default card

The foundation is applied **per card**, with one shared floor:

- `mixbay-audio-foundation --apply --device evo8` sets up that card and
  records it in `~/.config/mosquitomixbay/foundation.json`.
- Every USB audio interface ever seen is tracked separately in
  `~/.config/mosquitomixbay/connected-interfaces.json` (native, beta or
  unsupported). The CARDS and default lists only show interfaces in that log;
  a card never connected never appears.
- The **first card you set up becomes the default/priority card**. Change it
  in Mixbay → Settings → Audio foundation → Default audio interface, or with
  `--set-default <id>`. Any card in the connection log can be chosen, whatever
  its category.
- The default picker marks the selected card with a filled `●`; other rows have
  no marker.
- `--remove --device <id>` removes that card's split/mapping. The shared
  WirePlumber rule stays while another card still uses it.
- **Reset connection history** (in the foundation menu, after Refresh) clears
  the log after confirmation; installed splits/udev rules are kept.
- The TUI shows the same list with **Install/Remove + confirmation** and the
  restart warning. It is not a read-only text page.

`mixbay-audio-defaults.service` reads the chosen default card and sets its
sink/source (`evo8_main_output` / `evo8_mic_1_2`, `ssl12.pb12` / SSL 12
capture, or the ALSA card/connection-log match for any other interface).

## Adding an unsupported interface (beta)

Mixbay → Settings → **Add an audio interface** scans connected USB cards and
lists those that are not native. Adding one writes it to
`~/.config/mosquitomixbay/beta-devices.json`; it appears in the device list as
`demo-beta` / `online-beta`, runs ALSA level 1 (volume/mute), and carries a
**Restart reverse engineering** action in its controls with a confirmation.

The guided reverse-engineering harness (usbmon/libusb/hidraw → labelled
tuple → replay with GET/acks) is the next slice. Until a control is mapped and
verified, a beta card stays beta and never pretends to have the EVO 8 model.

## Why this order (stability first)

1. Access before control: without the udev rule the daemon/CLI cannot open the
   card.
2. Never suspend before splitting: passive loopbacks + idle suspend = resync.
3. Split after the profile is right: a split written for a node that does not
   expose 8/6 channels connects to nothing.
4. Do not touch a user-pinned clock: that is how a "default pack" breaks a
   working 96 kHz setup.
5. Apply at install and at first connection, not silently at every boot.

## Extending to another card

Add one branch in `audio-foundation.sh`:

- `discover_node <id> output|input` — find the ALSA node and channel count.
- `write_<id>_split` — generate `libpipewire-module-loopback` blocks with
  `target.object` set to the discovered node name.
- `needs <id>` — list what is missing, so the onboarding prompt can show it.
- Add the card's vendor string to the WirePlumber match only if it is not
  already covered.

Do not add a card to the split until its channel layout is verified on
hardware. The shared floor is safe for every class-compliant interface; a
wrong split is not.

## Validation still owed

- EVO 8: split nodes appear, app audio on `evo8_output_3_4` reaches output 3+4,
  default sink/source set.
- EVO 4: Levels page moves (4 bars); if the UCM exposes split mono nodes, the
  meter discovery must be adapted.
- Rate: 48 kHz match, 96 kHz allowed, real mismatch flagged.
- `--remove` restores the previous graph (files removed, PipeWire restart
  optional).
