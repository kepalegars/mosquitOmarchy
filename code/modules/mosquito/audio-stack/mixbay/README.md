# mosquitomixbay

USB-audio control bay for mosquitOmarchy — one TUI for the interfaces.
EVO 8 first: the interface mirrors evotui (vanzaho/audient-evo-py).

## Documentation de référence

Le rapport complet protocoles / matériel / reverse engineering est dans
[`docs/AUDIO-PROTOCOLS-LINUX.md`](docs/AUDIO-PROTOCOLS-LINUX.md) : Dante,
ADAT, MADI, AES3/S/PDIF, AES67/RAVENNA, AVB, AES50/SuperMAC, SoundGrid,
EtherSound/CobraNet, Livewire/Q-LAN, SDI, USB/Thunderbolt/FireWire/PCIe,
la liste des interfaces nativement supportées (support complet vs audio seul),
et l'étude « Audio MIDI Setup » (aggregate devices + drift correction).

Projets amont explicitement suivis (sourcés, pas copiés) :

- [`rolotrealanis98/open-apollo`](https://github.com/rolotrealanis98/open-apollo)
  — driver Apollo Thunderbolt/USB, daemon mixer, console (GPL-2.0,
  expérimental). Port complet en TODO.
- [`teodly/inferno`](https://github.com/teodly/inferno) — implémentation Dante
  non officielle, plugin ALSA + PTP (GPL-3.0/AGPL-3.0). À intégrer dans
  l'audio foundation, pas dans le driver registry USB.
- [`xenicle/douze`](https://github.com/xenicle/douze) — SSL 12 (déjà utilisé).
- [`TheOnlyJoey/MixiD`](https://github.com/TheOnlyJoey/MixiD) — Audient iD.
- [`geoffreybennett/alsa-scarlett-gui`](https://github.com/geoffreybennett/alsa-scarlett-gui)
  — Focusrite Scarlett/Clarett/Vocaster.
- [`thomas-nelson23/Openface-Mixer`](https://github.com/thomas-nelson23/Openface-Mixer)
  — RME Digiface USB / Fireface 802/800 / RayDAT.
- [`michaelforney/oscmix`](https://github.com/michaelforney/oscmix) — RME
  Fireface UCX II / UC.

| Interface | Backend | État |
|---|---|---|
| Audient EVO 8 | `evo_raw` kmod (`/dev/evo8` ioctl) | **plein contrôle** : volumes, gains 0…58 dB (échelle carte ; FU11/ALSA -8…50), mutes, 48V, loopback mixer 10×4 sur 2 bus (MIX 1\|2, MIX 3\|4) — **v1.0.0** |
| Audient EVO 4 | même protocole | plein contrôle + monitor blend, Levels 4 canaux — **v1.0.0** |
| Solid State Logic SSL 12 | douze (HTTP local) | volumes masters, mutes, mixer/sends, setup complet depuis Mixbay ; préamps/48V et surface SSL 360 complète via Omarchy360 — **v0.1.0** |
| RME Fireface UCX II | ALSA niveau 1 | volumes/mutes ; matrice TotalMix via oscmix/Openface à intégrer — **v0.0.1** |
| ESI UGM192 | ALSA | volumes/mutes (pas de DSP) — **v0.0.1** |
| PreSonus Quantum ES 4 | ALSA (beta) | **base de test reverse engineering**, pas natif : ajout via Settings → Add an audio interface, flag `beta`, volume/mute seulement |
| Autres interfaces USB | ALSA niveau 1 (beta) | ajout via Settings → Add an audio interface ; flag `demo-beta`/`online-beta` tant que non supportées nativement |

Sans hardware (ou sans kmod), chaque driver sert un **état DEMO persistant**
(même JSON) : la TUI, le CLI et les répètes live-mode marchent débranché.
La démo respecte les capacités du hardware : un boîtier ALSA n'y expose que
volumes et mutes, jamais de gain, 48V ni mixer.

## Protocole EVO

Port Go de [vanzaho/audient-evo-py](https://github.com/vanzaho/audient-evo-py)
(domaine public, référence principale — interface à répliquer) :
FU10 volume, FU11 gains, EU51 capture 6 canaux (EVO 8), EU56 monitor (EVO 4),
EU58 mutes/48V, EU59 mute (EVO 4), MU60 loopback **write-only** (shadow
logiciel partagé avec evoctl, compatible `~/.config/audient-evo-py/<dev>/`).
Quirks respectés : 4 octets
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
- `O` bascule mono/stéréo sur la paire sous le curseur : les entrées se lient
  seulement 1|2 et 3|4 (un seul gain/mute, **deux mètres séparés**), les
  sorties se séparent en un bloc par canal avec volume et mute indépendants.
  FU10 ne sait pas bouger une moitié de paire sans l'autre : le volume par
  canal passe donc par le gain du sink PipeWire, sur la base FU10 du canal le
  plus fort. Chaque disposition garde ses propres valeurs : repasser en
  mono/stéréo restaure les réglages de cette disposition ;
- `r` remet le paramètre sous le curseur au défaut (gain d'entrée **0 dB**,
  volume de sortie au **minimum**, monitor 50) ; `R` remet la page active au
  défaut après confirmation : CONTROLS remet les gains à **0 dB**, les
  volumes de sortie au **minimum** (`VolMin`) et les sorties **en stéréo**
  (les trims mono sont effacés) sans jamais toucher au mixer ; MIXER remet
  le bus Artist Mix sélectionné (les deux bus liés quand Artist Mix est OFF).
  Seul MIX 1|2 rouvre `PC 1|2 → OUT 1|2` à **0 dB** ; MIX 3|4 revient au
  **silence (-128 dB)** pour ne pas recopier le programme dans OUT 3|4 ;
- défauts neutres : gains d'entrée 0 dB, **volume de sortie au minimum**
  (`VolMin` : un reset ne peut pas envoyer un niveau fort aux monitors), pans
  d'entrée centrés, sources stéréo -100/+100, et la route d'usine
  `PC 1|2 → OUT 1|2` ouverte à **0 dB** ; les autres crosspoints sont
  fermés ;
- chrome en **texte blanc** : cadres arrondis, libellés PAN / VOL / gains et
  ligne de bus utilisent le `bright_foreground` du thème, plus jamais `muted`
  (vert sur achraf67) ni `dark_foreground` (gris chaud) ;
- onglets CONTROLS / MIXER / LEVELS (EVO 8) : texte blanc dans les deux états,
  l'actif sur un bloc accent (comme les boutons Close) ; les deux lignes de cadre
  (sous les onglets, au-dessus des raccourcis) sont accent ; devant
  `Audient EVO 8/4`, un point plein clignote entre accent et blanc quand
  l'interface est connectée, et un point creux accent reste fixe quand elle
  est absente ;
- indicateurs `[m]` (minuscule) et `[48V]`, l'état ne changeant que la
  couleur (rouge allumé, jaune 48V actif, blanc atténué éteint) ;
- **mètres USB** : chaque carte de contrôle (IN, OUT, sources du mixer) porte
  une fine barre de niveau et un repère de crête. Le signal lu est le monitor
  USB de la carte, jamais le niveau analogique OUT (l'EVO n'en expose pas) ;
- onglet **LEVELS** (`Tab` depuis MIXER) : 12 mètres verticaux dBFS, les 6
  canaux de capture (IN1-4, LP5/6) et les 6 canaux de lecture (PC1-4, LP5/6),
  avec repère de crête, `Space` pour remettre les crêtes à zéro et `p` pour
  figer l'affichage ; `Tab`/`Esc` reviennent à CONTROLS ;
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
./setup-mosquitomixbay.sh            # installe (TUI + dispatchers + kmod + capture EU51)
./setup-mosquitomixbay.sh --status   # missing | partial:… | ok
mosquito-mixbay                      # la TUI (seule interface)
mosquito-mixbay-actions devices-json
mosquito-mixbay-actions status-json --device evo8
mosquito-mixbay-actions set volume -20 --device evo8
mosquito-mixbay-actions set gain 30 -t input3
mosquito-mixbay-actions set mute 1 -t output1
mosquito-mixbay-actions set phantom 0 -t input1
mosquito-mixbay-actions mixer input1 --volume -6 --pan -20
mosquito-mixbay-actions reset-defaults --device evo8
mosquito-mixbay-actions save | load --device evo8
```

Le premier setup d'une carte applique son preset par défaut (contrôles + matrice
usine) puis ne réécrit plus jamais les niveaux de l'utilisateur. Le widget audio
d'Omarchy n'affiche qu'**une entrée par interface** (`EVO 8`) : les nœuds du
split restent internes à Mixbay et sont masqués via
`/usr/share/omarchy-platform/audio.json`.

Settings → Audio foundation : `s` sur une interface EVO bascule son split
(`split on/off` est affiché après les Hz). Split ON = une entrée stéréo par
sens (`EVO 8`) ; split OFF = le nœud Pro Audio brut, également une seule
entrée. Après la bascule, Mixbay propose de redémarrer le shell Omarchy pour
rafraîchir le panneau audio.

L'installateur pose aussi `/etc/udev/rules.d/99-evo8-capture.rules` et
`/usr/local/lib/mosquitomixbay/evo8-capture-enable.py` : à chaque connexion,
EU51 est demandé (best-effort, Enable write-only) pour que le DAW voie les 6
canaux de capture. Le driver Go le retente une fois par processus.

Les écritures (`set`, `mixer`, `save`, `load`) sont **strictes** : carte
absente, elles échouent au lieu d'écrire le shadow DEMO. `--demo` est
l'opt-out explicite. `status-json` reste en lecture ; sur EVO, `--live` ne
renvoie que la lecture matérielle et échoue si la carte est absente.

Dans foot, le zoom se règle au terminal, pas dans la TUI :
`Ctrl++` / `Ctrl+=` agrandit, `Ctrl+-` réduit, `Ctrl+0` remet à zéro.

TUI : appareils → écran EVO (CONTROLS / MIXER / LEVELS sur EVO 8). Raccourcis EVO — les flèches
seules déplacent, les modificateurs règlent la valeur sélectionnée :

- `←` / `→` ou `h` / `l` : changer de colonne (CONTROLS) ou de source (MIXER) ;
  `↑` / `↓` ou `j` / `k` : changer de ligne. Le passage d'une colonne à
  l'autre conserve l'indice de ligne ;
- `Ctrl` + `←` / `→` (ou `Ctrl+h` / `Ctrl+l`) : volume, gain et monitor **±5**,
  pans **±25** ;
- `Ctrl+Shift` + `←` / `→` : volume, gain et monitor **±1**, pans **±5** ;
- chiffres puis `Enter` pour saisir une valeur ;
- `m` mute (controls) ou choisit le bus (mixer), `P` 48V, `O` mono/stéréo,
  `Space` paramètre suivant dans le mixer ;
- `r` remet le paramètre au défaut, `R` remet la page active au défaut
  (CONTROLS : contrôles seuls ; MIXER : bus Artist Mix actif, ou les deux bus
  liés quand Artist Mix est OFF), `A` Artist Mix ;
- `Tab` cycle CONTROLS → MIXER → LEVELS (EVO 8) → CONTROLS ; sur LEVELS,
  `Space` remet les crêtes à zéro, `p` fige l'affichage, `Esc`/`Tab` retour ;
- `s` sauve (`+ new preset` pour un nouveau nom, `r` pour renommer), `o` charge
  (même picker : `r` renomme, `d` supprime après confirmation ; `default` est
  protégé), `Esc` retour, `q` quitte.

Les valeurs sont relues sur la carte toutes les **500 ms** tant que la fenêtre
est focused (rapport de focus terminal, DECSET 1004, compatible foot/kitty/
wezterm/alacritty/VTE/xterm). Un changement fait sur l'EVO 8 apparaît donc
dans la TUI sans touche, avec un court ramp à l'affichage. Le mixer MU60 étant
*write-only*, seuls les gains, volumes, mutes et 48V viennent du matériel ; la
matrice reste le shadow disque partagé (les changements d'evoctl sont relus).
Les mètres sont capturés tant qu'un onglet EVO 8 (CONTROLS, MIXER ou LEVELS)
est visible, même si la fenêtre perd le focus ; la capture s'arrête en
quittant l'onglet ou l'application. EVO 4 et DEMO n'ont pas de mètres. Si une session réelle perd la
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

## Accueil « première connexion » (compat)

Une interface qui a besoin d'une étape système unique (EVO : module `evo_raw`
et règle udev de capture) est proposée au lancement de `mosquito-mixbay`, pas
laissée silencieusement en DEMO :

```bash
mosquito-mixbay-compat --status evo8   # ok | offline | missing: …
mosquito-mixbay-compat --needs evo8    # exit 0 + la liste des étapes manquantes
mosquito-mixbay-compat --prompt evo8   # Set up / Later (gum)
mosquito-mixbay-compat --apply evo8    # réutilise setup-mosquitomixbay.sh -y
mosquito-mixbay-compat --accept evo8   # ne plus demander pour cette interface
```

« Later » n'est **pas** enregistré : le prompt revient au prochain lancement
jusqu'à acceptation (`~/.config/mosquitomixbay/onboarding.json`). Le prompt
n'apparaît que si l'interface est réellement branchée.

## Reverse engineering harness (usbmon)

Le harnais réel est `mixbay-reverse` (déployé par l'installateur) :

```bash
mixbay-reverse list
mixbay-reverse capture --guided --name "PreSonus Quantum ES 4" --match "Quantum ES"
mixbay-reverse sessions
mixbay-reverse show gain:input1
mixbay-reverse replay --label gain:input1 --dry-run
mixbay-reverse replay --label gain:input1 --yes
```

Il capture `usbmon`, découvre les canaux de la carte (PipeWire/pactl), puis
avance contrôle par contrôle : baseline silencieuse, **une** action, diff,
sauvegarde. Un résumé final demande confirmation et ramène au menu principal.
Le replay ne renvoie **que** les octets capturés, dans l'ordre, avec les
GET/acks intermédiaires ; `--dry-run` et une confirmation `REPLAY` sont
obligatoires. Voir [`harness/README.md`](harness/README.md).

TUI : **Settings → Reverse engineering harness (usbmon)**, et sur une carte
beta **Restart reverse engineering**. Surtout, **Add an audio interface** lance
le mode guidé juste après l'ajout de la carte : découverte des canaux, steps,
confirmation finale, retour à l'accueil. La capture demande sudo (usbmon) ; le
replay utilise `pyusb` et les droits udev. Une carte beta reste beta tant que
le mapping n'a pas été validé sur matériel.

Le module `compat/interface-onboarding.sh` documente aussi les recettes
réutilisables pour les futures interfaces : règle udev `TAG+="uaccess"`
**numérotée sous 73**, découpage PipeWire d'un sink Pro Audio en paires
stéréo, règle WirePlumber anti-suspend, service utilisateur. La SSL 12
(douze) est le cas pilote ; voir `code/modules/Apps/douze/STUDY.md`.

## Le split, c'est quoi ?

Un boîtier multicanaux (EVO 8 : 6 canaux USB, SSL 12 : 8 en Pro Audio) apparaît
dans PipeWire comme **un seul périphérique** avec 6/8 canaux. Une application
stéréo qui joue dessus se retrouve souvent étalée sur les canaux surround, et
il est impossible de dire « Spotify sur la sortie 3-4, le DAW sur 1-2, le
click sur le casque A ».

Le **split** découpe ce flux unique en plusieurs **périphériques stéréo
virtuels** :

- `evo8_main_output` → canaux 1/2
- `evo8_output_3_4` → canaux 3/4
- `evo8_loopback_output` → canaux 5/6 (loopback)
- `evo8_mic_1_2`, `evo8_mic_3_4`, `evo8_loopback_capture` côté capture

D'après le manuel Audient EVO 8 :

> Pressing the Volume Control 1 button will adjust the volume of the 1+2 speaker
> outputs or the first headphone output and pressing the Volume Control 2 will
> allow you to separately adjust the volume for Speaker Outputs 3+4 or the
> second headphone output.

> Artist Mix — EVO 8 allows you to have a different mix being sent to Outputs 3+4
> … using the main speakers (Outputs 1 + 2) and having an artist using headphones
> (Outputs 3+4) with both listening to separate mixes.

Chaque application cible alors la paire qu'elle doit entendre, et le mixer
matériel de la carte fait le routage final. Sans split, on ne peut pas router
proprement par application ; avec, on garde le routage dans la carte (pas de
latence logicielle ajoutée).

Le split n'est **pas** un changement de qualité audio : c'est uniquement une
vue stéréo des canaux USB. Il ne remplace pas le mixer, il l'alimente.

## Limites

- **Les cartes beta ne sont pas nativement supportées.** Elles tournent en
  ALSA niveau 1 (volume/mute), avec le flag `demo-beta`/`online-beta`. Le
  modèle universel EVO 8 (strips, gains, 48V, mixer) n'est appliqué qu'après
  le reverse engineering et la validation de chaque contrôle. Rien n'est
  promis tant que la carte n'est pas passée native.
- **Pas de DSP embarqué / hébergement de plugins dans l'interface.** Mixbay
  contrôle le routage, les volumes et le mixer côté hôte ; il ne charge pas de
  VST dans une carte et ne pilote pas les DSP constructeur (type UAD Apollo,
  Antelope, etc.). Les plugins restent côté DAW/hôte.
- **Pas de mise à jour firmware, pas d'application constructeur.** Le
  reverse engineering s'appuie sur ce que la carte expose en USB ; les
  fonctions purement firmware restent hors de portée jusqu'à preuve du
  contraire.
- **SSL 12** : Mixbay expose volumes masters, mutes et mixer via douze. Les
  préamps, le 48V, le monitoring complet et les boutons USER restent dans
  Omarchy360 (douze) ; le bouton « Open Omarchy360 mixer » y mène. Le setup
  complet (udev, service, split, plugin) se fait depuis Mixbay.
- **Pas de profil/rate forcé.** Le pack audio respecte `pipewire-settings` et
  signale un mismatch plutôt que de changer une fréquence sous une session
  live.
- **ADAT / talkback trim / fonctions non décodées** : expérimental ou absent
  selon la carte ; voir les notes de protocole de douze pour la SSL 12.
- **Reverse engineering** : le harnais réel est `mixbay-reverse` (usbmon,
  diff baseline/action, replay avec GET/acks, `--dry-run`). Les pièges connus
  restent les séquences read-modify-write, le timing et les rapports HID
  multi-octets ; une carte beta peut rester beta indéfiniment jusqu'à
  validation matérielle.

## Audio foundation (pack par défaut)

Mixbay installe un socle audio conservateur pour **toutes les interfaces
supportées**, en commençant par l'EVO 8. Il ne remplace pas le mixeur : il
rend le graphe PipeWire prévisible en dessous.

```bash
mixbay-audio-foundation --status          # état lisible
mixbay-audio-foundation --status --json   # pour la TUI / scripts
mixbay-audio-foundation --needs evo8      # ce qui manque pour cette carte
mixbay-audio-foundation --apply [--restart]
mixbay-audio-foundation --remove
```

Ce qu'il pose :

- **udev** : `70-mixbay-evo.rules` avec `TAG+="uaccess"` pour `/dev/evo4` et
  `/dev/evo8` — accès sans groupe `dialout` ni re-login — plus le helper de
  capture EVO 8 (EU51) ;
- **WirePlumber** : `50-mixbay-interfaces.conf`, anti-suspend
  (`session.suspend-timeout-seconds = 0`), `node.pause-on-idle = false`,
  `channelmix.upmix = false` pour Audient / RME / ESI / PreSonus / SSL 12 ;
- **EVO 8** : découpage du nœud USB 6 canaux en stéréo — `evo8_main_output`,
  `evo8_output_3_4`, `evo8_loopback_output`, `evo8_mic_1_2`,
  `evo8_mic_3_4`, `evo8_loopback_capture` — construit à partir du nom de nœud
  réel (série carte), pas d'un nom codé en dur ;
- **EVO 4** : laissé à l'UCM ALSA ≥ 1.2.16 (sortie stéréo + captures split
  déjà correctes). Un split 4 canaux existe en opt-in
  (`--force-evo4-split`) pour les systèmes sans UCM ;
- **défauts** : sink `evo8_main_output` + source `evo8_mic_1_2` au login via
  `mixbay-audio-defaults.service` ;
- **kHz** : si `pipewire-settings` gère déjà l'horloge
  (`90-mosquitomarchy-pipewire.conf`), le pack ne la touche pas. Sinon il écrit
  `50-mixbay-audio.conf` (48 kHz par défaut, 44,1–192 kHz autorisés,
  quantum 1024). `--status` compare la fréquence du graphe à celle du device
  et signale un **mismatch**.

La TUI expose le même état dans **Settings → Audio foundation** : liste des
cartes déjà connectées, install/remove par carte avec confirmation, choix de la
carte par défaut/prioritaire, et reset du journal de connexion. Appliquer ou
retirer redémarre PipeWire brièvement (avertissement dans la confirmation).

L'EVO 4 et l'EVO 8 partagent désormais le même écran **LEVELS** : les barres
sont générées depuis le `Spec` (IN1-4 + LP5/6 et PC1-4 + LP5/6 sur EVO 8 ;
IN1/2 + LP3/4 et PC1/2 + LP3/4 sur EVO 4), et les nœuds USB sont découverts
dans le graphe vivant.

### Settings

- **Listed interfaces** : `Only connected`, `All supported`, `Only used`
  (les cartes déjà vues dans le journal de connexion).
- **Launch Mixbay at startup** et **Launch in scratchpad** : actifs par défaut
  à l'install. Le premier ajoute la ligne `o.launch_on_start` dans
  `~/.config/hypr/autostart.lua` ; le second parque la TUI dans
  `special:scratchpad` (bascule Omarchy habituelle) **immédiatement** :
  `mixbay-startup --place` déplace la fenêtre déjà ouverte, sans attendre le
  prochain login. `--run` réutilise aussi une instance existante au lieu d'en
  lancer une seconde.
- **Audio foundation** : liste des cartes déjà connectées, install/remove par
  carte avec confirmation, choix de la carte par défaut/prioritaire, et
  **Reset connection history** (le journal séparé
  `~/.config/mosquitomixbay/connected-interfaces.json`).
- **Add an audio interface** : scan des cartes USB non natives, ajout beta,
  et harnais `mixbay-reverse` (usbmon) pour capturer/labelliser/rejouer.

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

Dans la TUI : Devices → **PipeWire patchbay** (lecture à la demande, `r` pour
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
  défaut n'est plus gérée par Mixbay.

Sur une interface gérée, le panneau remplace le slider par une barre pleine
non ajustable (100 %), sans bouton ; le mètre de crête d'entrée reste réel.

Le réglage **Allow native volume controls** (Settings) écrit
`allow_native_volume` dans `ui.json` ; le panneau le relit à chaud. Il est
grisé tant que `mosquito.levels-guard` n'est pas actif. La garde ne bloque que
ces surfaces : `pactl`/`wpctl` directs et les applications ne sont jamais
interceptés. Une touche bloquée affiche quand même l'OSD avec son icône et
100 %, mais la barre de niveau vide (0 %). Si le panneau upstream change,
la mise à jour refuse de rafraîchir le clone (supprimer le dossier, ou
réinstaller Levels Guard, pour repartir de l'upstream).

## Fichiers

```
mosquitomixbay/
  mosquito-mixbay            dispatcher (TUI si tty, foot sinon)
  mosquito-mixbay-actions    backend non-interactif (scripts, live-mode)
  setup-mosquitomixbay.sh    installateur (Go build + Hyprland + kmod)
  compat/                    accueil première connexion (udev/kmod/split)
  foundation/                pack audio par défaut (udev, WP, split, kHz)
  harness/                   mixbay-reverse (usbmon capture/diff/replay) + tests
  docs/                      AUDIO-PROTOCOLS-LINUX.md (rapport de référence)
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
