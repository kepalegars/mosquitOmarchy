# MX Master — thumb gesture button → SUPER (logiops)

Maps the big gesture button under the thumb of a **Logitech MX Master** (any
model: Master, 2S, 3, 3S, For Mac) to the **SUPER (Meta)** key, **momentarily**:
while the button is held, SUPER is held too.

Works over USB receiver **or** Bluetooth — it uses logiops (HID++) and does not
need the Logitech Options Plus app (Windows/macOS only).

On **Bluetooth**, logiops does not touch the radio. If the pointer micro-freezes
every second or so, that is a BLE connection-parameter / USB-autosuspend issue
handled by [`code/modules/Fixes/fix-bluetooth.sh`](../../Fixes/fix-bluetooth.sh).
Running this module while the MX Master is connected over Bluetooth applies that
fix automatically (`-y`).

## How it works

- **logiops** (`logid`, AUR package `logiops`) reads `/etc/logid.cfg` and
  applies the device block whose `name` matches the connected device's HID++
  name. Every known MX Master model name is configured, so whatever model you
  plug in, its thumb button is remapped.
- `cid 0xc3` is the gesture button; the `Keypress` action makes it momentary
  (press = `KEY_LEFTMETA` down, release = up).
- No other button is touched. The wheel is pinned to ratchet + low-resolution
  mode (see **Wheel** below) because free-spin/hi-res is what makes Wine, X11
  apps and Hyprland emit irregular, delayed scroll events.

## Install / usage

```
./mx-master.sh            # install + configure (idempotent)
./mx-master.sh --status   # package / config / service status
./mx-master.sh --remove   # disable service + restore previous config
./mx-master.sh -y         # non-interactive
```

Root parts (`/etc/logid.cfg`, `logid.service`) use `sudo` internally.

Overrides (environment variables):

| Variable         | Default          | Meaning                          |
|------------------|------------------|----------------------------------|
| `MX_MASTER_BUTTON` | `0xc3`         | CID of the button to remap       |
| `MX_MASTER_KEY`    | `KEY_LEFTMETA` | key sent (SUPER)                 |
| `MX_MASTER_NAME`   | (auto)          | exact logid device name          |
| `MX_MASTER_SCROLL_FACTOR` | (inherit `input:scroll_factor`) | per-device wheel factor; keep it an integer for Wine |

## Files

```
/etc/logid.cfg      generated config (marker "mosquitOmarchy-mx-master")
/etc/logid.cfg.bak  previous config, kept on first run, restored by --remove
logid.service       AUR-provided systemd unit (root), enabled + started
```

## Revert

```
sudo bash mx-master.sh --remove
```

or, manually: `sudo systemctl disable --now logid` and restore `/etc/logid.cfg`.
## Wheel

The wheel is configured in `/etc/logid.cfg` as:

- **ratchet** (`smartshift.on = false`) — no accidental free-spin / mode flips;
- **low-resolution** (`hiresscroll.hires = false`) — one detent = one 120-unit
  event, instead of a stream of sub-notch hi-res events.

That matters most under XWayland: Wine/Ableton only understands discrete wheel
clicks. Hi-res events arrive faster than Wine can coalesce them, which is the
"vertical scroll has a delay" behaviour; the free-spin/hi-res stream is also
what Hyprland's `emulate_discrete_scroll` accumulator turns into irregular
jumps in native apps.

The Hyprland device block deliberately does **not** set `scroll_factor`: the
mouse inherits `input:scroll_factor` (and the per-window `scroll_mouse` rules)
like every other pointer. A fractional per-device factor (the old 1.35) makes
XWayland accumulate `120 * factor` units per notch, emitting irregular 0/1/2
click bursts. Keep the global factor an integer if you rely on Wine.
`MX_MASTER_SCROLL_FACTOR` is only an opt-in per-device override.

## Mouse pointer block (combinable with the touchpad module)

Besides the gesture button, applying this module also writes a per-device
pointer block for the MX Master itself in `~/.config/hypr/mx-master.lua`
(`accel_profile = "flat"`, `sensitivity = -0.05` — a very slight trim below the
stock value), registered via its own marked
`require("hypr.mx-master")` block in `hyprland.lua`. Settings are RESERVED to
the mouse device: the touchpad module's block (`touchpad.lua`) and the global
`input.lua` block are never touched, and the two modules can be applied or
removed in ANY order. `--remove` also removes this pointer block.


## Together: touchpad + MX Master (or any mouse)

Both modules compose without conflict — each writes its OWN marker block in
`hyprland.lua` and its OWN device file, applied in any order:

- the **touchpad** module writes `~/.config/hypr/touchpad.lua` with
  `hl.device({ name = <touchpad>, … })` (adaptive / 0.0 / 1.8, kinetic decel 0.96),
- the **MX Master** module (or any mouse that picks its own settings) writes
  `~/.config/hypr/mx-master.lua` with `hl.device({ name = <mouse>, … })`
  (flat / -0.05 / scroll inherited from `input.lua`).

Device blocks are the most specific Hyprland match, so the touchpad always
gets its settings and the mouse always gets its own — apply either, both, or
remove either in any order; the live config always reflects it.

The same pattern applies to any pair of pointer devices: write one
`hl.device` block per device, named after its `hyprctl devices` name. Add
your own module by copying `code/modules/Plugins/touchpad/touchpad.sh` (or `mx-master.sh`),
swapping the device name and the values you want. The marker blocks and the
`require()` line in `hyprland.lua` are independent.
