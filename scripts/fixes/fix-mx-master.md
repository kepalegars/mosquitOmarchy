# MX Master — thumb gesture button → SUPER (logiops)

Maps the big gesture button under the thumb of a **Logitech MX Master** (any
model: Master, 2S, 3, 3S, For Mac) to the **SUPER (Meta)** key, **momentarily**:
while the button is held, SUPER is held too.

Works over USB receiver **or** Bluetooth — it uses logiops (HID++) and does not
need the Logitech Options Plus app (Windows/macOS only).

## How it works

- **logiops** (`logid`, AUR package `logiops`) reads `/etc/logid.cfg` and
  applies the device block whose `name` matches the connected device's HID++
  name. Every known MX Master model name is configured, so whatever model you
  plug in, its thumb button is remapped.
- `cid 0xc3` is the gesture button; the `Keypress` action makes it momentary
  (press = `KEY_LEFTMETA` down, release = up).
- No other button/scroll setting is touched: pointing and scrolling keep their
  defaults.

## Install / usage

```
./fix-mx-master.sh            # install + configure (idempotent)
./fix-mx-master.sh --status   # package / config / service status
./fix-mx-master.sh --remove   # disable service + restore previous config
./fix-mx-master.sh -y         # non-interactive
```

Root parts (`/etc/logid.cfg`, `logid.service`) use `sudo` internally.

Overrides (environment variables):

| Variable         | Default          | Meaning                          |
|------------------|------------------|----------------------------------|
| `MX_MASTER_BUTTON` | `0xc3`         | CID of the button to remap       |
| `MX_MASTER_KEY`    | `KEY_LEFTMETA` | key sent (SUPER)                 |
| `MX_MASTER_NAME`   | (auto)          | exact device name → single block |

## Files

```
/etc/logid.cfg      generated config (marker "mosquitOmarchy-mx-master")
/etc/logid.cfg.bak  previous config, kept on first run, restored by --remove
logid.service       AUR-provided systemd unit (root), enabled + started
```

## Revert

```
sudo bash fix-mx-master.sh --remove
```

or, manually: `sudo systemctl disable --now logid` and restore `/etc/logid.cfg`.