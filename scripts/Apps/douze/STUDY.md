# douze + Omarchy360 — étude complète et plan d'intégration Mixbay

> Sources étudiées (clones du 31/10/2026) :
> - `xenicle/douze` — daemon/CLI de contrôle SSL 12, protocole USB rétro-ingénierié.
> - `FenrirRhogar/omarchy360` — plugin Omarchy (barre + overlay) pour ce daemon.
> - `07dcolem/omarchy-target-boot` — plugin « reboot into » (utilisé comme
>   référence pour le module `reboot-into-windows`, pas pour l'audio).
>
> Ce rapport est un document de travail : il décrit ce que font les projets,
> ce qui est réutilisable dans Mixbay, et ce qui ne l'est pas (licences,
> dépendances, limites matérielles).

---

## 1. Résumé exécutif

**douze** fait pour la SSL 12 ce que Mixbay fait pour l'EVO : il rend contrôlable
en logiciel ce que le boîtier n'expose pas en standard. La différence est que
l'EVO passe par un petit module noyau (`evo_raw`, ioctl USB), alors que la
SSL 12 a un **second périphérique USB vendor-specific** (`31e9:0024`) dont le
protocole a été capturé et décodé. douze est donc à la fois :

- un **driver userspace** (pyusb/libusb) qui possède l'interface de contrôle,
- un **daemon HTTP local** (`127.0.0.1:1212`) qui garde l'état, le pousse à la
  carte et sert des événements (mètres, boutons façade, horloge),
- une **GUI web** et un **hôte VST3** (`Douze FX`) qui insère des plugins dans
  le graphe PipeWire.

**Omarchy360** est une façade native Omarchy (QML/Quickshell) de ce daemon :
strips, bus de cue, monitoring, boutons USER, profils, page « apps » avec
routage par application et mètres. Il ne touche jamais l'USB lui-même : il
consomme l'API HTTP de douze et PipeWire pour le reste.

Pour Mixbay, les points les plus réutilisables sont :

1. **La couche d'accueil « première connexion »** : prompt unique par interface
   (udev, kmod, split PipeWire, règle WirePlumber), accepté une fois.
2. **Les recettes PipeWire « Pro Audio »** : découpage d'un sink 8 canaux en
   quatre stéréos, `node.passive`, `dont-reconnect`, `target.object`, et la
   règle anti-suspend WirePlumber.
3. **La politique udev** : `TAG+="uaccess"` **numéroté sous 73**, sinon la règle
   est silencieusement ignorée.
4. **Le modèle de mixer** d'Omarchy360 (strips, bus, DIR, FOLLOW, liens stéréo,
   routage par app) : c'est de la logique pure, portable en Go.
5. **La méthode de reverse engineering** : captures USB, fixtures, écritures
   seulement observées, shadow des contrôles write-only.

Ce qui n'est **pas** réutilisable tel quel : le code de douze est **AGPLv3**.
MosquitOmarchy est MIT. On peut reprendre les **faits de protocole** (CC0) et
réimplémenter, ou garder douze comme **daemon externe** et parler à son API
HTTP — c'est la voie recommandée pour Mixbay. Omarchy360 est MIT : sa logique
UI peut être reprise avec attribution.

---

## 2. douze — architecture réelle

### 2.1 Fichiers et responsabilités

| Fichier | Rôle |
|---|---|
| `tools/sslctl.py` | CLI de contrôle : `status`, `show`, `master`, `channel`, `fader`, `route`, `48v`, `hpf`, `inst`, `phase`, `dim`, `cut`, `mono`, `alt`, `talk`, `altspk`, `loopback`, `bus`, `user`, `sync`. Maintient l'état logique dans `~/.config/sslctl/state.json` et le compile vers la matrice de gains. |
| `tools/douze.py` | Daemon : handshake USB, keepalive 150 ms, lecture des mètres, restauration de l'état au branchement, API HTTP `GET /state`, `POST /api`, `GET /events` (SSE), GUI web. |
| `tools/douze.html` | GUI web locale (http://localhost:1212) : mixer, monitoring, profils, FX. |
| `tools/douzefx.py` + `fx/` | Hôte VST3 : un process par strip, chaîne de plugins, micro/sink virtuel, scan un process jetable par fichier. |
| `tools/install-pipewire.sh` | Trouve le nom du nœud ALSA de la carte (contient le numéro de série), remplit le template et installe la règle WirePlumber. |
| `tools/sslctl.py` / `ssldecode.py` / `usbdump.py` | Outils de capture/décodage du protocole. |
| `PROTOCOL.md` | Notes de rétro-ingénierie, domaine public CC0. |
| `captures/` | Captures `.pcapng` + journal des expériences. |
| `systemd/douze.service` | Service utilisateur, `WantedBy=graphical-session.target`. |

### 2.2 Le modèle central : une matrice de gains, pas un mixer

Le boîtier n'a **ni faders, ni pans, ni mutes, ni solos**. Il expose une
**matrice de gains crosspoint** source → bus. SSL 360 (et douze) émule le reste
côté hôte :

```
instance = 30 × couche + slot_source
couches : 0/1 = Mix 1-2 L/R
          2/3 = Line 3-4 L/R
          4/5 = HP A L/R
          6/7 = HP B L/R
slots   : 0/1 = Playback 1-2 L/R, 2/3 = Pb 3-4, 4/5 = Pb 5-6, 6/7 = Pb 7-8,
          8–11 = Analogiques 1–4, 24–28 = retours de bus
valeur  : gain linéaire u32 LE, 0 dB = 2^25, 0 = -∞
```

- **Fader mono** : même valeur dans les deux couches L/R du bus.
- **Fader stéréo** : slot L → couche L, slot R → couche R.
- **Pan** : loi à puissance constante, **−3 dB au centre** ; cellule =
  niveau + pan.
- **Cut** : écrit 0 dans les cellules du canal, puis restaure.
- **Solo** : écrit 0 dans les cellules de tous les autres canaux, toutes
  couches, puis restaure.
- **DIR** : source à 0 dB dans le bus cible + sends à -∞ ; OFF restaure.
- **FOLLOW MIX 1-2** : booléen device (sub 07, contrôle 7) ; un bus qui suit
  ignore ses propres sends **et DIR** — d'où le correctif Omarchy360 qui
  coupe FOLLOW quand DIR s'active.
- **AFL** : mix principal à -∞ + retour bus (slots 26/27) à 0 dB, puis
  restauration.

Conséquence pour Mixbay : le même découpage « état logique → compilation vers
les contrôles matériels » est déjà celui de l'EVO (shadow MU60, snapshots). Un
driver SSL 12 dans Mixbay devrait garder un état logique identique et écrire
la matrice, pas exposer des « faders » inexistants.

### 2.3 Le protocole USB en une page

Topologie : la SSL 12 est un hub Microchip interne `0424:2422` avec deux
périphériques :

| Port | VID:PID | Rôle |
|---|---|---|
| 1 | `31e9:0024` | « SSL Control I/F », vendor-specific, bulk EP `0x81` IN / `0x02` OUT, 64 octets |
| 2 | `31e9:0005` | « SSL 12 », audio UAC2, `snd-usb-audio` |

- **Aucun driver noyau** ne s'attache au contrôle : accès libusb direct.
- Trame : `ff | opcode | len | payload | checksum`, checksum =
  `(opcode + len + somme(payload)) & 0xff`.
- IN : chaque paquet USB de 64 octets commence par `31 xx`, puis un flux
  d'octets continu ; il faut retirer l'en-tête de chaque tranche et
  réassembler.
- Handshake : `ff 01`, `ff 02`, `ff 05`, `ff 4b`, `ff 4e`, puis 36 × `ff 13`
  (groupes/LED), puis des `0x6b` (get/set paramètre).
- Keepalive `0x1b` toutes les 150 ms ; mètres `0x6c sub 09` ~20–25 trames/s.
- Les réponses `0x6b` reviennent en `0x6c` (opcode+1).
- Les sets continus (sub 06) n'ont pas d'ACK ; les booléens (sub 04) ont un
  écho sub 05.
- `MU60` (mixer EVO) n'existe pas ici : sur SSL 12, la matrice est lisible et
  écrivable, mais les **faders/pan/mute/solo restent côté hôte**.
- **Horloge** : notification `0x11`, premier u32 = fréquence réelle du device
  (44100, 48000, 192000 observés). douze la relit toutes les 20 s, car la
  carte peut changer de fréquence sans notifier (rebranchement).
- **Mètres** : `0x6c sub 09`, indices calibrés (0–3 Analogiques, 12/13 Pb 1-2,
  14/15 Line 3-4, 16/17 HP A, 18/19 HP B, 20/21 Monitor, 22–27 Pb 3-8).
- **LEDs** : `0x13` groupes indexés par **bouton physique** (0x0c CUT, 0x0d
  ALT, 0x0e TALK), pas par fonction ; nécessaire quand un bouton est réassigné.
- **Pas de séquence de fermeture** : le trafic s'arrête net.

### 2.4 Ce qui est still inconnu / expérimental

- Certains contrôles SETTINGS/clock (`sub 07 : 0x0d, 0x0e, 0x1f`,
  `sub 08 : 0x0a, 0x10, 0x1a`, `sub 06 : 0x08, 0x1c`) identifiés mais non
  décodés.
- ADAT 1–8 : slots et mètres présumés, **jamais testés avec une source
  optique**.
- Talkback trim/routing : fixed firmware, non ajustable.
- Firmware 1.41 vs 1.44 : quelques différences (bouton gui, mètres talkback).

---

## 3. PipeWire, Pro Audio et gestion des kHz

### 3.1 Pourquoi le profil Pro Audio est obligatoire

La carte expose 8 canaux de lecture **seulement** en profil « Pro Audio ».
Dans le profil duplex par défaut, les ports `pro-output-0..7` n'existent pas :
le split PipeWire crée quatre loopbacks qui ne se connectent à rien. C'est la
première cause de « les sinks `ssl12.pbXX` n'apparaissent jamais ».

Vérification :

```bash
pw-link -o | grep -i solid
# doit lister …pro-output-0:playback_AUX0 … AUX7
pactl list cards short
```

### 3.2 Le split en quatre stéréos

`pipewire/99-ssl12-sinks.conf` est un **template** : `@SSL12_NODE@` est
remplacé par le nom du nœud ALSA, qui contient le numéro de série et diffère
donc d'une machine à l'autre.

Chaque paire est un `libpipewire-module-loopback` :

```ini
capture.props = {
  node.name = "ssl12.pb12"
  media.class = Audio/Sink
  audio.position = [ FL FR ]
}
playback.props = {
  node.name = "ssl12.pb12.out"
  audio.position = [ AUX0 AUX1 ]
  target.object = "<alsa_output.usb-...pro-output-0>"
  node.dont-reconnect = true
  stream.dont-remix = true
  node.passive = true
}
```

Points clés :

- **`node.passive = true`** : le loopback ne force pas la carte à rester
  active ; il suit le flux.
- **`node.dont-reconnect = true`** : si le nœud ALSA est recréé (boot,
  hot-plug, reset USB), les loopbacks **ne se reconnectent pas seuls**.
  douze répare au démarrage avec `pw-link` ; sans daemon, il faut le faire à
  la main.
- **`stream.dont-remix = true`** : pas de remix automatique des canaux.
- **`target.object`** : le nom du nœud ALSA, pas un index.
- **`media.class = Audio/Sink`** côté capture : les applis ciblent
  `ssl12.pb12` comme une sortie normale.

### 3.3 WirePlumber : ne jamais suspendre la carte

Les loopbacks sont passifs. Dès que plus rien ne joue, la sortie SSL passe
« idle » et WirePlumber la suspend après 5 s. Au premier son, le flux de
lecture repart alors que la capture (tenue par une bande FX micro) tourne
depuis le boot : PipeWire « resync » à chaque cycle, sans converger →
craquements, voix hachée.

La règle :

```ini
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_(output|input)\\.usb-Solid_State_Logic_SSL_12.*" }
    ]
    actions = {
      update-props = { session.suspend-timeout-seconds = 0 }
    }
  }
]
```

Symptôme dans le journal :

```
spa.alsa: hw:0,0p: follower avail:10 delay:10 target:512 thr:512, resync (64 suppressed)
```

Remède : redémarrer **les trois unités ensemble**
(`pipewire pipewire-pulse wireplumber`), jamais suspendre le nœud à la main
(il revient avec un canal mort).

### 3.4 kHz : trois fréquences à ne pas confondre

1. **Fréquence réelle du device** : lue dans la notification `0x11`
   (`_clock[0]`). C'est la seule qui compte pour détecter un désaccord.
2. **Fréquence du graphe PipeWire** : `default.clock.rate` (souvent 48000),
   `default.clock.quantum`, `api.alsa.period-size`.
3. **Fréquence du flux ALSA** : ce que le client demande ; ALSA peut croire
   44100 alors que la carte est à 48000.

douze compare la fréquence device à la vitesse réelle de l'hôte
(`douzefx.vitesse_hote()`) et expose `_clock_mismatch`. Omarchy360 affiche
`● connected 48 kHz` + `⚠ clock mismatch`. Cas vécu : `[48000, 48000, 44100,
192000]` pendant qu'ALSA croyait à 44100 et que `hw_ptr` avançait à
48001/s ; après réouverture du flux, `[44100, …]` et 44097/s.

Pour Mixbay, la leçon est directe : **lire la fréquence réelle du device**
(quand le protocole l'expose) et la comparer à celle du graphe, au lieu de
supposer que `pactl` dit vrai. Le module `pipewire-settings` existant
(`scripts/mosquito/audio-stack/pipewire/`) est le bon endroit pour exposer
`default.clock.rate` / quantum et un avertissement de mismatch par interface.

### 3.5 Réparation des loopbacks après hot-plug

Sans daemon :

```bash
card=$(pw-link -o | grep -oE 'alsa_output\.usb-Solid_State_Logic_SSL_12_[^:]*\.pro-output-0' | head -1)
for i in 0 1 2 3 4 5 6 7; do
  pair=$(( i / 2 )); names=(pb12 pb34 pb56 pb78)
  pw-link "ssl12.${names[$pair]}.out:output_AUX$i" "$card:playback_AUX$i"
done
```

Piège : `pw-link -d` **par nom** déconnecte tous les flux qui partagent ce nom
de port. Utiliser les IDs de port (`pw-link -lI`).

---

## 4. udev, permissions, pièges

### 4.1 La règle et son numéro

Le dépôt douze fournit `udev/99-douze.rules` :

```udev
SUBSYSTEM=="usb", ATTRS{idVendor}=="31e9", ATTRS{idProduct}=="0024", MODE="0660", GROUP="audio"
```

Omarchy360 recommande plutôt :

```udev
SUBSYSTEM=="usb", ATTRS{idVendor}=="31e9", ATTRS{idProduct}=="0024", TAG+="uaccess"
```

**Piège majeur** : `TAG+="uaccess"` est traité par `73-seat-late.rules`. Une
règle `99-*` avec uaccess **ne fait rien** (elle est appliquée trop tard).
Il faut un numéro **< 73** (`70-douze.rules`) ou utiliser `MODE`/`GROUP`
(mais alors il faut être dans le groupe `audio` et se reconnecter).

Le module `scripts/Apps/douze/setup-douze.sh` installe `70-douze.rules` avec
uaccess : pas de groupe à ajouter, pas de re-login.

### 4.2 Le daemon possède l'interface

`sslctl` et le daemon ne peuvent pas parler à la carte en même temps. Si
`python tools/sslctl.py info` dit « permission denied » :

1. `lsusb | grep 31e9` → doit montrer `31e9:0024 SSL Control I/F` (si seul
   `0005` apparaît, la carte est dans un mode qui cache le contrôle :
   rebrancher).
2. `getfacl /dev/bus/usb/*/*` → l'utilisateur doit avoir l'ACL uaccess.
3. La règle ne s'applique qu'aux **événements** : `udevadm control --reload`
   puis rebrancher.
4. Le daemon tourne ? `systemctl --user stop douze`.

### 4.3 Matrice de troubleshooting (douze + Omarchy360)

| Symptôme | Cause probable | Action |
|---|---|---|
| `douze offline` | daemon arrêté | `systemctl --user status douze` |
| `SSL 12 not connected` | carte absente/hub | vérifier USB, port direct |
| `USBError: Access denied` | règle udev absente/trop tardive | règle 70 + rebrancher |
| Sinks `ssl12.pbXX` absents | profil non-Pro Audio, ou nom de nœud changé | passer en Pro Audio, relancer `install-pipewire.sh` |
| Carte silencieuse, “suspended” | loopbacks déconnectés après hot-plug | réparer avec `pw-link` (IDs) |
| Clics/voix hachée | carte suspendue, resync | règle WirePlumber, restart des 3 unités |
| Une app n'a pas de mètre | positions de canaux inconnues | `omarchy360-peaks` (pw-record + pw-link) |
| App entendue mais pas routée | `target.object`/pair occupée | vérifier les 3 paires libres |
| DIR sans effet | FOLLOW MIX 1-2 actif sur la sortie | couper FOLLOW (Omarchy360 le fait) |
| Bouton ALT mort | ALT SPK désactivé (prérequis firmware) | activer ALT SPK |
| Plugin UI figé | éditeur VST qui ne rend pas la main | redémarrer le strip ; douze mémorise les éditeurs bloquants |
| Micro brut entendu | appli capture le défaut système, pas le micro virtuel | `wpctl set-default <virtual>` + choix explicite dans l'app |
| `LD_LIBRARY_PATH` → plugins Windows morts | yabridge/Wine | ne pas étendre, remplacer ; le lanceur douze le fait |

---

## 5. Omarchy360 — ce que le plugin apporte

### 5.1 Architecture

- `manifest.json` : `bar-widget` + `overlay`, `keepLoaded: true`.
- `Widget.qml` : icône trois faders, toggle de l'overlay.
- `MixerOverlay.qml` : fenêtre plein écran, focus clavier.
- `SslView.qml` : header, onglets, strips, monitoring.
- `Douze.qml` : client HTTP/SSE.
- `Ssl.js` : modèle SSL 12 (canaux, bus, liens, DIR, cibles d'app).
- `Mixer.js` : helpers PipeWire (props, streams, pics).
- `bin/omarchy360-route` : routage par app via `pactl`.
- `bin/omarchy360-peaks` : mètres `pw-record` pour les nœuds que Quickshell
  ne sait pas lire.

### 5.2 Le client HTTP est la partie à copier

`Douze.qml` fait trois choses très propres :

1. **File de commandes sérialisée** : chaque `POST /api` renvoie l'état
   complet ; deux requêtes concurrentes pourraient afficher un état plus
   ancien que la carte. Donc `queue` + `busy` + `next()`.
2. **Throttle 50 ms** sur les contrôles continus : une seule valeur (la
   dernière) par contrôle part par tranche de 50 ms, et on attend que la
   commande en cours soit finie.
3. **SSE** via `curl -sN --no-buffer /events` : mètres ~15/s, échos d'état,
   boutons façade, horloge. Reconnexion toutes les 2 s.

C'est exactement le pattern qu'un driver SSL 12 dans Mixbay devrait utiliser
s'il parle au daemon : un client Go avec une file, un throttle et un flux
d'événements, pas des appels HTTP concurrents.

### 5.3 Le modèle UI (Ssl.js) est portable

- `CHANNELS` : Analog 1–4, ADAT 1–8, Play 1-2…7-8, avec indices de mètres.
- `LINK_PAIRS` : 1-2, 3-4, ADAT par paires ; un lien collapse deux strips en
  un seul, avec pan stéréo.
- `BUSES` : MIX 1-2, HP A, HP B, LINE 3-4 ; `busOutputs()` gère le cas
  Line 3-4 = deux monos (extension `line4`).
- `DIR_BUS` : pb34 → line34, pb56 → hpa, pb78 → hpb ; pb12 n'a pas de DIR.
- `APP_TARGETS` : SPK, HP A, HP B, L 3-4 ; `SPARE_PAIRS` = pb34/pb56/pb78.
- `inMainMix`, `busFollows`, `dirOn` : les règles de routage sont explicites
  et testables.

C'est cette logique, pas le QML, qu'il faut porter en Go dans Mixbay.

### 5.4 La page « apps » : routage par application

- Une app joue dans **une** paire de playback.
- Pour l'entendre sur un bus, on déplace le flux vers une paire libre
  (`pactl move-sink-input`), puis la matrice de la carte copie cette paire
  vers les sorties voulues (hardware, pas de latence ajoutée).
- Trois paires libres = trois apps routées séparément. Une quatrième est
  refusée.
- Si le bus « suit MIX 1-2 », il faut d'abord couper FOLLOW et copier le mix
  principal dans le bus (niveaux, pans, CUT) pour que le reste ne change pas.
- DIR est coupé quand une app prend la paire.
- WirePlumber mémorise la paire par app ; l'état du mixer (douze) mémorise le
  routage.

### 5.5 Mètres : `omarchy360-peaks`

- `pw-record --raw --rate 48000 --format f32 --channels N --channel-map
  AUX0..AUXN-1 --latency 50ms`.
- Pic linéaire par canal, une ligne toutes ~50 ms.
- Pour un **stream** (pas un sink/source), `pw-record` ne peut pas le cibler :
  on crée un nœud `node.autoconnect=false` et on lie les ports du stream avec
  `pw-link` (IDs de port, pas noms), en re-liaison toutes les 3 s.
- `PR_SET_PDEATHSIG` + SIGTERM : pas de `pw-record` orphelin.
- `pw-dump` avec timeout 5 s : un outil bloqué ne fige pas le mètre.

Mixbay a déjà `meters/` (capture `pw-record` f32 + ballistiques) : la
technique « stream mode + re-link périodique » est le complément à ajouter
pour les applis dont les positions de canaux sont inconnues.

### 5.6 Sécurité

- L'API douze n'écoute que `127.0.0.1`.
- La branche `omarchy360` de douze répond **uniquement à l'utilisateur du
  daemon** (vérification de la table des sockets noyau), refuse les requêtes
  avec `Origin`/`Host` d'une page web, et borne les racks FX à
  `~/.config/douze-fx/racks/`.
- Le plugin ne fait jamais `sudo` : les étapes root sont documentées et
  exécutées une fois à la main.

---

## 6. Méthode de reverse engineering (à reproduire pour d'autres interfaces)

1. **Capturer le trafic USB** avec Wireshark + `usbmon` (ou `tshark`), sur le
   périphérique vendor-specific uniquement.
2. **Soustraire le bruit de fond** : keepalive 150 ms, flux de mètres ~20/s.
   Sans ça, les captures sont illisibles.
3. **Faire une action à la fois** dans l'application vendor, nommer la capture
   (`04-volume-monitor`, `12-pan`, `20-bus-modes`…).
4. **Décoder le framing** et vérifier le checksum sur l'ensemble des messages
   (douze : 2 988 messages, 0 erreur). Un framing faux se voit tout de suite.
5. **Identifier les couples (contrôle, instance)** et les sous-opcodes
   (`06` set continu, `04` set booléen, `07` modes, `08` enum).
6. **Calibrer les échelles** : gain linéaire `2^25 × 10^(dB/20)`, pan à
   puissance constante −3 dB au centre, indices de mètres par tonalité.
7. **Écrire seulement des séquences observées**. Pour les contrôles
   write-only (MU60 EVO), garder un **shadow disque** et ne jamais faire de GET.
8. **Tester par fixtures** : listes `efibootmgr`, trames, formules dB,
   conversions. Les captures deviennent des tests de non-régression.
9. **Documenter les faits en CC0** (comme `PROTOCOL.md`) pour que les autres
   projets puissent les réutiliser sans copier le code AGPL.

Pour une nouvelle interface, la première question n'est pas « quel mixer ? »
mais « quel est le plus petit ensemble de trames qui change un paramètre, et
quel est l'état minimal à garder côté hôte ? ».

---

## 7. Ce qu'on peut intégrer dans Mixbay

### 7.1 Accueil « première connexion » (déjà amorcé)

Le module `scripts/mosquito/audio-stack/mixbay/compat/interface-onboarding.sh`
et l'appel dans `mosquito-mixbay` posent la base :

- `--needs <dev>` : liste les étapes manquantes (kmod, udev, split, service).
- `--prompt <dev>` : `gum confirm` « Set up / Later » ; « Later » n'est pas
  enregistré, donc le prompt revient au prochain lancement.
- `--apply <dev>` : réutilise l'installateur complet (source unique de vérité).
- `--accept <dev>` : écrit `~/.config/mosquitomixbay/onboarding.json`.
- `--status <dev>` : `ok | offline | missing: …`.

Prochaine étape : déplacer l'appel du dispatcher vers la **sélection de
l'interface dans la TUI** (écran `scrDevices`), pour que le prompt apparaisse
« en allant dans son panneau » et pas seulement au lancement. Ajouter un
`compat.Step` par `drivers.Spec` et rendre l'application asynchrone avec
progression.

### 7.2 Recettes réutilisables, par interface

| Besoin | Recette douze/Omarchy360 | Adaptation Mixbay |
|---|---|---|
| Accès contrôle vendor | udev `TAG+="uaccess"` en `70-*` | même règle, numéro < 73 |
| Contrôle noyau EVO | `evo_raw` + `/dev/evo8` | déjà en place |
| Split Pro Audio | 4 × `libpipewire-module-loopback` | générique : N paires, template + nom de nœud |
| Anti-suspend | `session.suspend-timeout-seconds = 0` | règle WirePlumber par interface |
| Daemon utilisateur | `graphical-session.target`, `PYTHONUNBUFFERED=1`, `KillMode=mixed` | même unité pour un futur daemon SSL 12 |
| État write-only | shadow JSON + snapshots | déjà le modèle EVO |
| Client HTTP | file + throttle 50 ms + SSE | driver Go `ssl12` si on garde douze |
| Mètres inconnus | `pw-record` + `pw-link` par IDs | ajouter au package `meters` |
| Routage par app | `pactl move-sink-input` + matrice hardware | onglet « Apps » dans Mixbay |

### 7.3 Deux voies pour la SSL 12 dans Mixbay

**Voie A — daemon externe (recommandée tout de suite).**
Mixbay ajoute un `drivers.Spec` `ssl12` dont le backend est `BackendHTTP` :
`Status()` lit `GET /state`, les setters envoient `POST /api`, les mètres
viennent de `/events`. Aucun code AGPL copié. L'utilisateur installe douze
via le module `douze` (déjà ajouté), Mixbay détecte le daemon sur
`127.0.0.1:1212` et bascule en « online » ; sinon il affiche DEMO.

**Voie B — protocole embarqué (plus tard, si nécessaire).**
Réimplémenter le protocole en Go à partir de `PROTOCOL.md` (CC0), sans copier
le code AGPL. C'est un vrai projet (handshake, bulk IN réassemblé, keepalive,
matrice, mètres, horloge). À ne faire que si la dépendance au daemon devient
un problème (déploiement, licence, latence).

**Voie C — fork UI.**
Le « fork de toute l'interface » demandé dans le TODO est plus simple qu'il
n'y paraît : la valeur est dans `Ssl.js` + `Mixer.js` (MIT), pas dans le QML.
Porter ces règles en Go et les rendre génériques (un modèle `MixerModel` avec
strips/bus/DIR/FOLLOW/liens) permet de les réutiliser pour EVO, SSL 12, RME,
etc. Le QML d'Omarchy360 reste une référence visuelle, pas une dépendance.

### 7.4 Plan par étapes

**P0 — déjà fait / cette passe**
- Module `douze` (clone, pyusb, udev 70, service, split PipeWire conditionnel,
  plugin Omarchy360, update/uninstall).
- Module `reboot-into-windows` (entrée System, countdown 15 s, BootNext
  one-shot, vérification, reboot).
- Base d'onboarding Mixbay (EVO) + TODO.

**P1 — rendre l'onboarding générique**
- `Spec.Compat` : liste d'étapes déclaratives par interface.
- Prompt dans la TUI à la sélection, état `onboarding.json`.
- Application asynchrone avec log/progression (pas de blocage du full
  installer).
- Tests : device absent, device présent sans kmod, device présent avec tout,
  « Later » puis relance.

**P2 — SSL 12 via douze**
- `drivers.Spec` `ssl12` + backend HTTP (Voie A).
- `Status()` mappe les strips/bus/monitor ; `Caps` expose mixer, phantom,
  monitor, gains.
- Mètres via `/events` (ou `pw-record` si le daemon ne les fournit pas).
- Tests avec un faux daemon HTTP (fixtures JSON) et sans hardware.

**P3 — UI générique**
- Porter `Ssl.js`/`Mixer.js` en Go : `MixerModel`, `Strip`, `Bus`, `Dir`,
  `Follow`, `LinkPair`, `AppRoute`.
- Un onglet « Apps » avec `pactl`/`pw-dump`/`pw-link`.
- Thème tui-kit, pas de QML.

---

## 8. Risques et limites

- **Firmware** : le protocole est vérifié sur 1.41/1.44 ; une mise à jour SSL
  peut changer des contrôles. Les captures et tests sont la seule protection.
- **Écritures non officielles** : douze n'envoie que des séquences observées,
  mais il n'y a pas d'API vendor. L'état du mixer est volatile (la carte
  oublie tout à l'extinction) ; les profils sont côté hôte.
- **PipeWire** : redémarrer les unités coupe les applis ; les loopbacks ne se
  reconnectent pas seuls après hot-plug ; `pw-link -d` par nom est dangereux.
- **udev** : une règle uaccess en 99 est un piège silencieux.
- **Licence** : douze = AGPLv3, Omarchy360 = MIT, mosquitOmarchy = MIT.
  Réutiliser les faits CC0 ou passer par l'API HTTP ; ne pas copier le code
  AGPL dans Mixbay sans changer la licence du projet.
- **Branche `omarchy360`** : le plugin dépend d'extensions proposées upstream
  (PR #1) mais pas encore mergées. Le module installe la branche du fork par
  défaut ; `--upstream` existe pour tester le dépôt d'origine.
- **ADAT** : expérimental, jamais validé avec une source optique.
- **Mémoire** : le daemon douze peut consommer beaucoup (FX, GUI web) ; ce
  n'est pas un daemon léger comme `evo_raw`.

---

## 9. Références utiles

- `douze/README.md` — installation, usage `sslctl`, troubleshooting.
- `douze/PROTOCOL.md` — protocole complet (CC0).
- `douze/captures/` — captures et journal des expériences.
- `douze/tools/install-pipewire.sh` — template + nom de nœud + WirePlumber.
- `douze/wireplumber/51-ssl12-no-suspend.conf` — règle anti-suspend.
- `douze/systemd/douze.service` — unité utilisateur.
- `omarchy360/README.md` — fonctionnalités, installation, matrice des sorties.
- `omarchy360/Douze.qml` — client HTTP/SSE (file, throttle).
- `omarchy360/Ssl.js` — modèle strips/bus/DIR/FOLLOW.
- `omarchy360/bin/omarchy360-route` — routage par app (`pactl`).
- `omarchy360/bin/omarchy360-peaks` — mètres `pw-record` + `pw-link`.
- `omarchy-target-boot/README.md` + `bin/target-boot` — modèle de sécurité
  BootNext (écriture unique, vérification, reboot).
