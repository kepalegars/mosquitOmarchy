# mosquito audio stack

One Setup row, five components. Enter on the `audio-stack` folder installs all
of them; use the component rows to install one at a time, or
`--skip=live-mode,pipewire` from the CLI.

| Component | What it is |
|---|---|
| [`apm/`](apm/README.md) | Wine/yabridge foundation (`setup-yabridge.sh`) + mosquito Audio Plugin Manager |
| [`mixbay/`](mixbay/README.md) | USB audio bay for EVO and other interfaces |
| [`levels-guard/`](levels-guard/) | Omarchy audio panel clone + media-key guard (default on) |
| [`live-mode/`](live-mode/README.md) | Performance session mode |
| [`pipewire/`](pipewire/) | PipeWire sample-rate/buffer panel |

```bash
./setup-audio-stack.sh                 # all five
./setup-audio-stack.sh -y              # unattended
./setup-audio-stack.sh --skip=live-mode,pipewire
./setup-audio-stack.sh --status
./setup-audio-stack.sh --uninstall
./setup-audio-stack.sh --tweaks        # forwarded to setup-yabridge.sh
```

`mixbay` installs standalone without the guard. `levels-guard` owns the cloned
`mosquito.levels-guard` panel and the `levels-guard` block in
`~/.config/hypr/bindings.lua`; Mixbay's **Allow native volume controls** toggle
only works while that plugin is enabled.
