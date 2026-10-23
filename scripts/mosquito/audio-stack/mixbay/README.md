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
  indépendants) ;
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
- indicateurs `[m]` (minuscule) et `[48V]`, l'état ne changeant que la
  couleur (rouge allumé, jaune 48V actif, blanc atténué éteint) ;
- **mètres USB** : chaque carte de contrôle (IN, OUT, sources du mixer) porte
  une fine barre de niveau et un repère de crête. Le signal lu est le monitor
  USB de la carte, jamais le niveau analogique OUT (l'EVO n'en expose pas) ;
- écran **Levels** (`v`) : les 6 canaux de capture (IN 1-4, LOOP 5\|6) et les
  6 canaux de lecture (PC 1\|2, PC 3\|4, LOOP) avec dBFS, crête, `Space` pour
  remettre les crêtes à zéro et `p` pour figer le peak-hold ;
- les valeurs reçues du matériel (gain, volume, monitor) glissent sur ~220 ms
  après chaque poll de 500 ms ; une écriture locale (Molette/clavier/TUI)
  s'affiche immédiatement, sans animation ;
- le champ de nom du picker de sauvegarde a un **caret clignotant mobile**
  (`←/→`, `Home/End`, `Suppr`), y compris pendant un renommage.

Le trait vertical en début de ligne de bus (`╘`) n'est pas un séparateur :
il marque le départ du bus lorsque l'entrée 1 y est routée. La ligne de bus
commence à la même colonne que le trait sous les onglets et reste toujours
accent. Les petits traits verticaux de la ligne (`╦` vers le bas, `╧` vers le
haut) viennent d'evotui : chacun marque une tranche dont le volume alimente
réellement le bus. Une tranche à `VolMin` reste un simple `═` ; ces traits ne
sont donc pas décoratifs. Les deux titres `MIX 1|2` et `MIX 3|4` sont toujours
visibles et commencent à la même colonne : le titre non sélectionné réserve la
cellule du `▶`, même sans triangle. Avec **Artist Mix** actif, le bus
sélectionné est en **accent gras** et précédé de `▶` : `MIX 1|2` est un trait
horizontal continu, sans fourche ; `MIX 3|4` s'arrête pile sur la fourche `╗`,
puis descend vers `╚` et son libellé. L'autre titre reste en **blanc**, sans
triangle. Artist Mix inactif (bus liés) affiche les deux branches, la fourche
`╦` et les deux libellés accent avec `▶`, alignés. La légende des raccourcis
suit l'état : `artist mix: on` / `off`.

Les cartes touchent le séparateur **du haut** ; sous la dernière carte, une
ligne reste libre avant le séparateur des raccourcis pour les notifications
(`artist mix: on/off`, sauvegarde, erreur), qui ne peuvent plus écraser les
bordures.

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

Les écritures (`set`, `mixer`, `save`, `load`) sont **strictes** : carte
absente, elles échouent au lieu d'écrire le shadow DEMO. `--demo` est
l'opt-out explicite. `status-json` reste en lecture ; sur EVO, `--live` ne
renvoie que la lecture matérielle et échoue si la carte est absente.

Dans foot, le zoom se règle au terminal, pas dans la TUI :
`Ctrl++` / `Ctrl+=` agrandit, `Ctrl+-` réduit, `Ctrl+0` remet à zéro.

TUI : appareils → écran EVO (CONTROLS / MIXER). Raccourcis EVO — les flèches
seules déplacent, les modificateurs règlent la valeur sélectionnée :

- `←` / `→` ou `h` / `l` : changer de colonne (CONTROLS) ou de source (MIXER) ;
  `↑` / `↓` ou `j` / `k` : changer de ligne. Le passage d'une colonne à
  l'autre conserve l'indice de ligne ;
- `Ctrl` + `←` / `→` (ou `Ctrl+h` / `Ctrl+l`) : volume, gain et monitor **±5**,
  pans **±25** ;
- `Ctrl+Shift` + `←` / `→` : volume, gain et monitor **±1**, pans **±5** ;
- chiffres puis `Enter` pour saisir une valeur ;
- `m` mute (controls) ou choisit le bus (mixer), `P` 48V, `Space` paramètre
  suivant dans le mixer ;
- `r` remet le paramètre au défaut, `R` (reset all) vide tout le mixer après
  confirmation, `A` Artist Mix ;
- `v` ouvre **Levels** (mètres USB) : `Space` remet les crêtes à zéro, `p`
  fige le peak-hold, `Esc`/`v` retour ;
- `s` sauve (`+ new preset` pour un nouveau nom, `r` pour renommer), `o` charge
  (même picker : `r` renomme, `d` supprime après confirmation ; `default` est
  protégé), `Esc` retour, `q` quitte.

Les valeurs sont relues sur la carte toutes les **500 ms** tant que la fenêtre
est focused (rapport de focus terminal, DECSET 1004, compatible foot/kitty/
wezterm/alacritty/VTE/xterm). Un changement fait sur l'EVO 8 apparaît donc
dans la TUI sans touche, avec un court ramp à l'affichage. Le mixer MU60 étant
*write-only*, seuls les gains, volumes, mutes et 48V viennent du matériel ; la
matrice reste le shadow disque partagé (les changements d'evoctl sont relus).
Les mètres sont capturés uniquement quand un écran EVO 8 (CONTROLS, MIXER ou
Levels) est visible et que la fenêtre a le focus ; la capture s'arrête en
quittant ou en perdant le focus. EVO 4 et DEMO n'ont pas de mètres. Si une session réelle perd la
carte, les dernières valeurs sont figées, le point passe creux et les écritures
sont refusées jusqu'au retour de l'interface ; le poll suivant réactive les
écritures dès que la carte répond. Un rafraîchissement manuel pendant la
déconnexion ne bascule **jamais** l'écran en DEMO.

Le 48V bascule immédiatement (comme evotui). Sur EVO 4 le bus loopback est
unique (`MIX 3|4`, capture USB CH3/4) ; sur EVO 8 les deux bus sont nommés
`MIX 1|2` et `MIX 3|4`. L'écran Settings filtre les interfaces non connectées
et propose **Allow native volume controls** (défaut : off), actif seulement
quand le plugin `mosquito.levels-guard` est installé et activé. La version du
script est épinglée en haut à gauche.

Trois volumes différents ne doivent pas être confondus :

- **CONTROLS** montre les *masters* de sortie, ceux que règlent les gros boutons
  physiques de l'EVO (`FU10`) ;
- **MIXER** montre les *sends* de chaque source vers le bus sélectionné (`m`
  change de bus) : entrées puis lecture. Les libellés de lecture sont ceux du
  mixer Audient, `PC 1|2`, `PC 3|4` et `LOOP 5|6` (sur EVO 4 : `PC 1|2`,
  `LOOP 3|4`) ; ce ne sont pas des masters de sortie ;
- le choix `MIX 1|2` / `MIX 3|4` ne change que le bus cible des sends.

## Patchbay PipeWire

Le mixeur et le patchbay sont deux couches **séparées** : le mixer choisit ce
que chaque canal contient (gains, sends, bus), le patchbay choisit quels nœuds
PipeWire sont reliés entre eux. Changer l'un ne change pas l'autre.

Le patchbay est **explicite** : rien n'est appliqué automatiquement au
branchement ou au démarrage. `qpwgraph` reste l'éditeur de graphe ; mixbay
sait seulement sauver le câblage matériel courant et le restaurer.

```bash
mosquito-mixbay-actions patchbay-status-json        # nœuds, liens, presets
mosquito-mixbay-actions patchbay-save studio        # câblage actuel → preset
mosquito-mixbay-actions patchbay-apply studio       # ajoute les liens manquants
mosquito-mixbay-actions patchbay-apply studio --replace  # retire aussi l'extra
```

Un preset ne contient que les liens touchant une interface audio matérielle et
l'empreinte des interfaces utilisées (nom, classe, canaux). Si l'interface
change, l'apply est refusé plutôt que de câbler à moitié. Par défaut l'apply
**ajoute** sans jamais couper un lien existant ; `--replace` ne retire que les
liens matériels absents du preset, jamais les liens purement logiciels.

Dans la TUI : Devices → **PipeWire patchbay…** (lecture à la demande, `r` pour
rafraîchir ; aucune surveillance en arrière-plan). Le raccourci est grisé si
`pw-dump` ou `pw-link` manque. `Save current wiring…` (`s`) demande un nom et
**crée seulement** : nom vide ou déjà pris est refusé, jamais écrasé. Le CLI
`patchbay-save` garde son écrasement explicite.

## Garde des volumes natifs (module Levels Guard)

La garde vit dans le module frère **Levels Guard**, pas dans Mixbay. Installer
Mixbay seul ne touche ni au panneau audio d'Omarchy ni aux touches média.

- panneau audio Omarchy : clone patché `mosquito.levels-guard`, installé dans
  `~/.config/omarchy/plugins/` à partir du panneau upstream, avec validation
  Omarchy et sauvegarde de `shell.json` (`shell.json.levels-guard.bak`) ;
- touches média : bloc marqué `levels-guard` dans
  `~/.config/hypr/bindings.lua`, qui délègue à Omarchy dès que l'interface par
  défaut n'est plus un EVO.

Le réglage **Allow native volume controls** (Settings) écrit
`allow_native_volume` dans `ui.json` ; le panneau le relit à chaud. Il est
grisé tant que `mosquito.levels-guard` n'est pas actif. La garde ne bloque que
ces surfaces : `pactl`/`wpctl` directs et les applications ne sont jamais
interceptés. Une touche bloquée affiche quand même l'OSD à 0 %. Si le panneau
upstream change, la mise à jour refuse de rafraîchir le clone (supprimer le
dossier, ou réinstaller Levels Guard, pour repartir de l'upstream).

## Fichiers

```
mosquitomixbay/
  mosquito-mixbay            dispatcher (TUI si tty, foot sinon)
  mosquito-mixbay-actions    backend non-interactif (scripts, live-mode)
  setup-mosquitomixbay.sh    installateur (Go build + Hyprland + kmod)
  tui-go/                    binaire unique (TUI + CLI) sur tui-kit
    drivers/                 Driver iface : evo.go, alsa.go (+ tests)
    meters/                  capture pw-record f32 + ballistiques (+ tests)
    patchbay/                graphe pw-dump, presets de liens (+ tests)
    cli.go model.go view.go meters_ui.go patchbay_ui.go main.go
  README.md  INTEGRATION.md
../levels-guard/            module séparé (panneau Omarchy + touches média)
```

État disque : `~/.config/mosquitomixbay/ui.json` (filtre d'affichage +
`allow_native_volume`), `~/.config/audient-evo-py/<dev>/` (shadow `.mixer-state.json`
partagé avec evoctl, `config.json`, les snapshots nommés et `.output-mute.json`
pour le mute de sortie émulé — le preset `default` n'existe pas sur disque, il
est fourni par le binaire et protégé), `~/.config/mosquitomixbay/<dev>/demo.json`
(DEMO) et `~/.config/mosquitomixbay/pipewire/<preset>.json` (patchbay).
