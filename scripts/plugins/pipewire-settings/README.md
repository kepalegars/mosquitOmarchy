# PipeWire Settings

Sample rate and buffer size for the PipeWire graph, with a *force* switch and a
*remember on restart* switch.

The Omarchy counterpart of [gaheldev/pipewire-settings][upstream], a GNOME Shell
extension — which cannot run here, but does something worth having: a small panel
that sets the graph's rate and quantum, forces them, and persists them.

[upstream]: https://github.com/gaheldev/pipewire-settings

Omarchy's own audio panel covers sinks, sources and volumes. It does **not** touch
the sample rate or the buffer size, so this fills a real gap rather than
duplicating one.

## Install

```bash
./setup-pipewire-settings.sh            # install (idempotent)
./setup-pipewire-settings.sh --remove   # remove the plugin + menu entry
```

Installs three things and nothing else: the backend script, the shell plugin, and
a menu entry. **No package, daemon or service is installed** — this configures the
audio graph you already have. PipeWire itself is required and expected to be
there.

Then reload the shell (`omarchy-restart-shell`) and open it from the bar, next to
the audio icon, or from **Omarchy menu → Trigger → PipeWire Settings**.

## What the two switches actually do

**Live, through `pw-metadata`.** Every change applies to the running graph
immediately — no restart. `clock.force-rate` / `clock.force-quantum` exist *only*
as runtime metadata, so forcing is only possible this way.

**Persisted, through a config file.** `~/.config/pipewire/pipewire.conf.d/90-mosquitomarchy-pipewire.conf`.

The persisted file pins **min = default = max**, which looks redundant and is not:

- `force-quantum` is **not supported** in a PipeWire config file, so a persisted
  choice cannot be forced the way the live one can;
- setting only the default is not enough either — an application asking for a
  different quantum gets it, and the setting silently does not apply.

Pinning the range is what actually holds the value. The upstream extension
discovered the same thing and says so in its own comments.

## The backend, on its own

`pipewire-settings` works from a terminal, and is the only thing that talks to
PipeWire. The panel is just a front for it.

```bash
./pipewire-settings show          # one JSON line: effective + configured values
./pipewire-settings set-rate 48000
./pipewire-settings set-quantum 256
./pipewire-settings set-force rate 1     # force the rate at its current value
./pipewire-settings persist 1            # write the config file
./pipewire-settings reset                # back to PipeWire's defaults
./pipewire-settings --remove             # (via setup-pipewire-settings.sh)
```

`set-rate` / `set-quantum` take `0` to mean **dynamic**: the pins are dropped and
the value is unforced, which is not the same thing as picking a number.

Rate and quantum are validated against the upstream's lists. They are the values
worth *offering*, not every value the hardware accepts — inventing a longer list
would put choices in the menu that nothing here can run.

## Two things worth knowing

**Absent is not zero.** An untouched graph reports only `clock.rate`,
`clock.quantum` and the two force keys; the min/max keys do not exist until
something sets them. `show` reports them as `null` rather than guessing.

**Force is one switch over both keys.** The rate and the quantum travel together
here. A forced rate with a dynamic buffer (or the reverse) is a state this panel
cannot produce, so it does not offer one.

## Removing it

`--remove` takes back the plugin, the backend and the menu entry. It leaves
`~/.config/pipewire/pipewire.conf.d/90-mosquitomarchy-pipewire.conf` **in place**
on purpose: that file is your audio setting, not ours, and uninstalling a panel
should not silently reconfigure PipeWire. It says where the file is; deleting it
is your call.

## Status

The backend is complete and tested against the running graph (read, write, force,
persist, remove, argument rejection, and the install/remove round trip leaving
the menu file byte-identical).

The panel is written against Omarchy's own components — `qs.Ui.Panel`,
`KeyboardPanel`, `PanelKeyCatcher` — and loads with no QML error. **It has not
been seen on screen yet**: `KeyboardPanel` anchors its card to the bar, and the
bar was not rendering on the machine this was built on, so there was no geometry
to check against. An earlier hand-rolled `PanelWindow` version compiled cleanly
too and showed nothing, which is why this one uses the shell's components instead
of reimplementing anchoring and focus. Visual validation is still owed.
