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

## Interface : ce qui vient d'evotui, ce que mixbay ajoute

L'écran EVO 4/8 est un port fidèle d'`evotui.py` : mêmes cadres, glyphes,
sliders, ligne de bus et raccourcis. Ce qui est **partagé avec upstream** :

- le chemin `~/.config/audient-evo-py/<evo4|evo8>/` — le nom vient du projet
  amont, écrit en Python. mixbay le réutilise tel quel pour que `evoctl` et le
  bay lisent/écrivent le même état (poids historique, pas une dépendance) ;
- `.mixer-state.json` : shadow du MU60 (write-only), clés `inputN` /
  `outputX_Y`, suffixe `@bus` pour MIX 3|4 ;
- les cibles de contrôle (FU10/FU11/EU56/EU58/EU59/MU60) et les quirks USB.

Ce que **mixbay ajoute** :

- transferts groupés sur un seul fd par lot : un `SET_CUR` isolé par transfert
  provoquait des STALL USB (« broken pipe ») lors des rafales ;
- **mute de sortie EVO 8 émulé** : le firmware *rejette* le sélecteur EU58
  CS=2 documenté (`SET_CUR wValue=0x0204 wIndex=0x3a00` → « broken pipe »).
  mixbay baisse alors la sortie à `VolMin` via FU10 (qui répond toujours) et
  mémorise le niveau précédent dans `.output-mute.json` pour le restaurer au
  dé-mute. L'EVO 4 garde son vrai mute matériel (EU59) ;
- snapshots nommés complets (contrôles **et** mixer, tous les bus) ;
- picker de sauvegarde : entrée `+ new preset…` toujours en dernier (le curseur
  devient `+`) et `r` renomme le fichier sélectionné (`Enter` valide, `Esc`
  annule) ;
- preset `default.json` en lecture seule, toujours en tête du picker : sauver
  sous ce nom est refusé et force un nouveau nom ;
- `A` Artist Mix : OFF lie OUT 1|2 et OUT 3|4 (même mix, volumes de sortie
  restant séparés) ;
- `r` remet le paramètre sélectionné au défaut, `R` (rename « reset all ») vide
  tout le mixer après confirmation ;
- défauts neutres : gains d'entrée 0 dB, **volume de sortie au minimum**
  (`VolMin` : charger `default` ne peut pas envoyer un niveau fort aux
  monitors), pans d'entrée centrés, sources stéréo -100/+100, aucun
  crosspoint ouvert ;
- chrome en **texte blanc** : cadres arrondis, libellés PAN / VOL / gains et
  ligne de bus utilisent le `bright_foreground` du thème, plus jamais `muted`
  (vert sur achraff-67) ni `dark_foreground` (gris chaud) ;
- onglets CONTROLS / MIXER : texte blanc dans les deux états, l'actif sur un
  bloc accent (comme les boutons Close) ; les deux lignes de cadre
  (sous les onglets, au-dessus des raccourcis) sont accent ; devant
  `Audient EVO 8/4`, un point plein clignote entre accent et blanc quand
  l'interface est connectée, et un point creux accent reste fixe quand elle
  est absente ;
- indicateurs toujours en majuscules (`[M]`, `[48V]`), l'état ne changeant que
  la couleur (rouge allumé, jaune 48V actif, blanc atténué éteint).

Le trait vertical en début de ligne de bus (`╘`) n'est pas un séparateur :
il marque le départ du bus lorsque l'entrée 1 y est routée. La ligne de bus
commence à la même colonne que le trait sous les onglets et reste toujours
accent. Les deux titres `MIX 1|2` et `MIX 3|4` sont toujours visibles. Avec
**Artist Mix** actif, le bus sélectionné est blanc et précédé de `▶` :
`MIX 1|2` est un trait horizontal continu, sans fourche ; `MIX 3|4` s'arrête
pile sur la fourche `╗`, puis descend vers `╚` et son libellé. L'autre titre
reste affiché en accent, sans triangle. Artist Mix inactif (bus liés) affiche
les deux branches, la fourche `╦` et les deux libellés blancs avec `▶`,
alignés. La légende des raccourcis suit l'état : `artist mix: on` / `off`.

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

TUI : appareils → écran EVO (CONTROLS / MIXER). Raccourcis EVO :

- `Tab` bascule CONTROLS ↔ MIXER ; `hjkl` navigue (le passage d'une colonne à
  l'autre conserve l'indice de ligne) ;
- `[` / `]` ±1, `{` / `}` ±5, chiffres puis `Enter` pour saisir une valeur ;
- `m` mute (controls) ou choisit le bus (mixer), `P` 48V, `Space` paramètre
  suivant dans le mixer ;
- `r` remet le paramètre au défaut, `R` (reset all) vide tout le mixer après
  confirmation, `A` Artist Mix ;
- `s` sauve (`+ new preset` pour un nouveau nom, `r` pour renommer), `o` charge,
  `Esc` retour, `q` quitte.

Le 48V bascule immédiatement (comme evotui). Sur EVO 4 le bus loopback est
unique (`MIX 3|4`, capture USB CH3/4) ; sur EVO 8 les deux bus sont nommés
`MIX 1|2` et `MIX 3|4`. L'écran Settings (avant Close) filtre les interfaces
non connectées ; la version du script est épinglée en haut à gauche.

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

État disque : `~/.config/audient-evo-py/<dev>/` (shadow `.mixer-state.json`
partagé avec evoctl, `config.json`, les snapshots nommés et `.output-mute.json`
pour le mute de sortie émulé — le preset `default` n'existe pas sur disque, il
est fourni par le binaire et protégé) et
`~/.config/mosquitomixbay/<dev>/demo.json` (DEMO).
