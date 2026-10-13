# mosquitomixbay

USB-audio control bay for mosquitOmarchy — one TUI for the interfaces:

| Interface | Backend | État |
|---|---|---|
| Audient EVO 8 | `evo_raw` kmod (`/dev/evo8` ioctl) | **plein contrôle** : volumes, gains 0…58 dB, mutes, 48V, loopback mixer 10×4 |
| Audient EVO 4 | même protocole | plein contrôle + monitor blend |
| RME Fireface UCX II | ALSA niveau 1 | volumes/mutes ; matrice TotalMix en attente support kernel UCX II USB |
| ESI UGM192 | ALSA | volumes (pas de DSP) |
| PreSonus Quantum ES 4 | ALSA | volumes (pas de DSP) |

Sans hardware (ou sans kmod), chaque driver sert un **état DEMO persistant**
(même JSON) : la TUI, le CLI et les répètes live-mode marchent débranché.

## Protocole EVO

Port Go de [vanzaho/audient-evo-py](https://github.com/vanzaho/audient-evo-py)
(domaine public, référence principale — interface à répliquer) :
FU10 volume, FU11 gains, EU56 monitor (EVO 4), EU58 mutes/48V, EU59 mute
(EVO 4), MU60 loopback **write-only** (shadow logiciel, compatible
`~/.config/audient-evo-py/<dev>/`). Quirks respectés : 4 octets pleins sur
EU58/59, jamais de GET sur MU60, EU56 seulement CS=0 CN=0.

Autres inspirations : `soerenbnoergaard/evoctl` (matrice EVO8),
`vijay-prema/audient-evo-linux-tools`, `subsubl/Evo4mixer`,
`hoskere/audient-evo8-rp2350-arduino`, `michaelforney/oscmix` et
`ismail-bahloul/TuxMix` (idiomes), `oudeis01/linux-fireface-mixer`
(Fireface 400 FireWire — **pas** l'UCX II USB, d'où ALSA niveau 1 ici).

## Usage

```bash
./setup-mosquitomixbay.sh            # installe (TUI + dispatchers + kmod)
./setup-mosquitomixbay.sh --status   # missing | partial:… | ok
mosquito-mixbay                      # la TUI (seule interface)
mosquito-mixbay-actions devices-json
mosquito-mixbay-actions status-json --device evo8
mosquito-mixbay-actions set volume -20 --device evo8
mosquito-mixbay-actions set gain 30 -t input3
mosquito-mixbay-actions set mute 1 -t output1
mosquito-mixbay-actions set phantom 0 -t input1
mosquito-mixbay-actions mixer input1 --volume -6 --pan -20
mosquito-mixbay-actions save | load --device evo8
```

TUI : `↑/↓` choisir · `←/→` ±1 dB (`Shift` ±5) · `Enter` mute/48V ·
`m` mixer · `,`/`.` pan · `s` save · `r` refresh · `?` aide.
Le 48V demande confirmation (condensateurs uniquement, retours baissés).

## Fichiers

```
mosquitomixbay/
  mosquito-mixbay            dispatcher (TUI si tty, foot sinon)
  mosquito-mixbay-actions    backend non-interactif (scripts, live-mode)
  setup-mosquitomixbay.sh    installateur (Go build + règle Hyprland + kmod)
  kmod/install-evo-raw.sh    clone upstream + install.sh (DKMS/udev)
  tui-go/                    binaire unique (TUI + CLI) sur tui-kit
    drivers/                 Driver iface : evo.go, alsa.go (+ tests)
    cli.go model.go view.go main.go
  README.md  INTEGRATION.md
```

État disque : `~/.config/audient-evo-py/<dev>/` (config + shadow mixer,
compatible evoctl) et `~/.config/mosquitomixbay/<dev>/demo.json` (DEMO).
