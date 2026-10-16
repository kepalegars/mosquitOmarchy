# mosquitomixbay

USB-audio control bay for mosquitOmarchy — one TUI for the interfaces.
EVO 8 first: the interface mirrors evotui (vanzaho/audient-evo-py).

| Interface | Backend | État |
|---|---|---|
| Audient EVO 8 | `evo_raw` kmod (`/dev/evo8` ioctl) | **plein contrôle** : volumes, gains 0…58 dB, mutes, 48V, loopback mixer 10×4 sur 2 bus (MIX 1\|2, MIX 3\|4) |
| Audient EVO 4 | même protocole | plein contrôle + monitor blend |
| RME Fireface UCX II | ALSA niveau 1 | volumes/mutes ; matrice TotalMix en attente support kernel UCX II USB |
| ESI UGM192 | ALSA | volumes/mutes (pas de DSP) |
| PreSonus Quantum ES 4 | ALSA | volumes/mutes (pas de DSP) |

Sans hardware (ou sans kmod), chaque driver sert un **état DEMO persistant**
(même JSON) : la TUI, le CLI et les répètes live-mode marchent débranché.
La démo respecte les capacités du hardware : un boîtier ALSA n'y expose que
volumes et mutes, jamais de gain, 48V ni mixer.

## Protocole EVO

Port Go de [vanzaho/audient-evo-py](https://github.com/vanzaho/audient-evo-py)
(domaine public, référence principale — interface à répliquer) :
FU10 volume, FU11 gains, EU56 monitor (EVO 4), EU58 mutes/48V, EU59 mute
(EVO 4), MU60 loopback **write-only** (shadow logiciel partagé avec evoctl,
compatible `~/.config/audient-evo-py/<dev>/`). Quirks respectés : 4 octets
pleins sur EU58/59, jamais de GET sur MU60, EU56 seulement CS=0 CN=0, paires
de sorties groupées sur des CN impairs, gains en CN 1-based.

Autres inspirations : `soerenbnoergaard/evoctl` (matrice EVO8),
`vijay-prema/audient-evo-linux-tools`, `hoskere/audient-evo8-rp2350-arduino`
(table d'encodage EVO 8), `michaelforney/oscmix` et
`ismail-bahloul/TuxMix` (séparation démon/client, scènes, mock backend),
`oudeis01/linux-fireface-mixer` (sélection de submix — ici le sélecteur
MIX 1|2 / MIX 3|4).

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

TUI : appareils → contrôles (sections INPUTS / OUTPUTS) → mixer loopback.
`↑/↓` choisir · `←/→` ±1 dB (`Shift` ±5) · chiffres puis `Enter` pour taper
une valeur · `Enter` mute/48V · `m` mixer · `s` save · `r` refresh · `?` aide.
Le 48V demande confirmation (condensateurs uniquement, retours baissés).
Sur la page mixer, la première ligne choisit le bus (MIX 1|2 ou MIX 3|4).

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
