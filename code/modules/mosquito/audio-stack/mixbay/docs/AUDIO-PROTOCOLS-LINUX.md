# Mixbay — rapport protocoles audio pro & support Linux natif

**Date :** 2026-10-31  
**Périmètre :** tout ce qui a été investigué, reverse-engineered, testé ou
supporté par Mixbay et par l'écosystème Linux, pour préparer un outil
« tout-en-un » qui met à plat les protocoles et les systèmes audio vers Linux.  
**Statut :** document de référence. Les implémentations sont dans les TODO, pas
dans ce fichier.

> **Ceci n'est pas le README de Mixbay.** C'est le rapport de référence
> protocoles / matériel / reverse engineering. Le README décrit l'usage de la
> TUI ; ce fichier décrit les protocoles, les interfaces et les décisions
> d'architecture.

> **Définition utilisée ici — « support complet » :** le flux audio *et* tous les
> contrôles matériels utiles (préamplis, gain, 48 V, mute, routing, mixer DSP,
> monitoring) sont pilotables depuis Linux, de façon stable et documentée. Un
> boîtier « class compliant » qui ne fait que passer l'audio n'est **pas** un
> support complet, même s'il fonctionne parfaitement en lecture/écriture.

---

## 0. Résumé exécutif

1. **Linux sait faire de l'audio avec presque toutes les interfaces USB
   class-compliant.** Le vrai problème n'est pas le flux audio, c'est le
   **plan de contrôle** : mixer interne, préamplis, 48 V, routing, loopback,
   DSP constructeur. Ce plan de contrôle est propriétaire sur la majorité des
   cartes récentes.
2. **Le support complet existe, mais il est rare et souvent le fruit d'un
   reverse engineering communautaire.** Les cas les plus aboutis en 2026 :
   Focusrite Scarlett/Clarett/Vocaster (driver kernel + `alsa-scarlett-gui`),
   Audient EVO 4/8, SSL 12 (`douze`), RME HDSP/HDSPe, RME Digiface USB /
   Fireface 802/800 (`Openface Mixer`), Tascam US-16x08, MOTU PCI-424,
   Echo Audio PCI, M-Audio Delta / cartes ice1712, Universal Audio Apollo
   (`open-apollo`, expérimental), et quelques cartes PCI/PCIe professionnelles
   (Digigram, AudioScience, Merging RAVENNA).
3. **Dante n'a pas de pilote officiel Linux.** Le seul chemin pratique est
   `inferno` (implémentation non officielle en Rust, user-space, avec plugin
   ALSA et PTPv1/PTPv2), plus `network-audio-controller` pour le contrôle.
   Ce n'est **pas** un driver kernel et ce n'est **pas** supporté par Audinate.
4. **ADAT n'est pas un protocole logiciel.** C'est un transport optique
   (8 canaux à 44,1/48 kHz, 4 à 88,2/96, 2 à 176,4/192). Linux le supporte si
   la carte expose les canaux ADAT en ALSA. Il n'y a ni énumération, ni
   contrôle, ni driver ADAT générique.
5. **L'idée « Audio MIDI Setup » est bonne pour Mixbay**, à condition de la
   traduire en concepts Linux : domaine d'horloge, source de sync, correction
   de dérive par resampling adaptatif, agrégat virtuel. Le modèle macOS est
   simple parce qu'il cache le resampling ; Mixbay doit le montrer sans le
   rendre obligatoire.
6. **Recommandation d'architecture :** Mixbay doit séparer explicitement
   *data plane* (ALSA/PipeWire/JACK) et *control plane* (USB vendor, HID,
   bulk, MIDI SysEx, HTTP, OSC, mDNS). C'est ce qui permet d'ajouter Dante,
   Apollo, ADAT et les cartes USB sans réécrire l'UI.

---

## 1. Méthode, niveaux de preuve et avertissements

Ce rapport mélange trois types d'information, volontairement distingués :

| Niveau | Signification |
|---|---|
| **Vérifié matériel** | testé sur une carte réelle, au moins par une source publique ou par le projet Mixbay. |
| **Amont / kernel** | support dans le noyau Linux, ALSA, FFADO ou un driver officiel constructeur. |
| **Communauté** | projet de reverse engineering, souvent expérimental, parfois non testé sur toutes les cartes. |
| **Déclaré** | le constructeur ou le projet annonce le support, sans validation indépendante. |

Avertissements :

- Les protocoles propriétaires sont documentés ici **pour l'interopérabilité**.
  Le reverse engineering peut poser des questions de licence, de brevets et de
  garantie. Les projets cités ont leurs propres licences et disclaimers.
- Une carte peut fonctionner en audio et **perdre ses contrôles** si le
  firmware change. Le support « complet » n'est jamais acquis définitivement.
- Les noms de produits appartiennent à leurs constructeurs. Ce document n'est
  affilié à aucun d'eux.

---

## 2. Modèle en couches : ce que Mixbay doit modéliser

```
┌─────────────────────────────────────────────────────────────┐
│ Applications : DAW, navigateur, OBS, lecteur, live-mode      │
├─────────────────────────────────────────────────────────────┤
│ Serveur audio : PipeWire (graph, clock, resampling) / JACK   │
├─────────────────────────────────────────────────────────────┤
│ ALSA : PCM, ctl, sequencer, UCM, profils                     │
├─────────────────────────────────────────────────────────────┤
│ Drivers : snd-usb-audio, snd-fireface, snd-hdsp, snd-echo,   │
│           snd-ice1712, snd-asihpi, FFADO, user-space, …      │
├─────────────────────────────────────────────────────────────┤
│ Transports : USB, Thunderbolt/PCIe, FireWire, PCI/PCIe,      │
│              Ethernet (Dante/AES67/AVB), ADAT, MADI, AES3    │
├─────────────────────────────────────────────────────────────┤
│ Plan de contrôle : ALSA ctl, USB HID/bulk vendor, MIDI SysEx,│
│                    HTTP/WebSocket, TCP, OSC, mDNS             │
└─────────────────────────────────────────────────────────────┘
```

**Règle d'or :** le flux audio ne doit jamais dépendre du plan de contrôle.
Une carte dont le mixer n'est pas décodé doit continuer à faire de l'audio
(ALSA niveau 1) et l'UI doit l'annoncer honnêtement. C'est déjà la politique
`beta` de Mixbay.

---

## 3. Protocoles et transports

### 3.1 USB Audio Class 1 / 2 (UAC1, UAC2)

- **Ce que c'est :** la classe USB standard pour l'audio. UAC1 est limité
  (souvent 16 bits / 48 kHz, 2 canaux), UAC2 gère le multicanaux, les hautes
  fréquences, le feedback explicite ou implicite, et les horloges multiples.
- **Ce que Linux fait :** `snd-usb-audio` expose les PCM et les contrôles
  standard. Les cartes class-compliant fonctionnent sans driver constructeur.
- **Ce qui manque :** tout ce que le constructeur met derrière une interface
  vendor-specific (HID, bulk, MIDI SysEx). C'est là que se trouvent les gains,
  le 48 V, le mixer, le loopback, le DSP.
- **Pièges connus :** feedback implicite, paquets courts, `bInterval`,
  altsettings, cartes qui changent de configuration USB après un contrôle
  (`device_setup`, Fast Track Pro), interfaces composites (audio + HID +
  MIDI), et cartes qui ont besoin d'une séquence d'init avant que l'audio ne
  sorte (Apollo USB, EVO capture).
- **Conséquence pour Mixbay :** un backend « ALSA niveau 1 » est toujours
  possible ; le support complet se gagne interface par interface.

### 3.2 Thunderbolt (TB2, TB3, TB4)

- **Ce que c'est :** un tunnel PCIe. Les cartes audio Thunderbolt sont vues
  comme des périphériques PCIe, pas comme des cartes USB.
- **Linux :** TB3/TB4 fonctionne sur la plupart des machines récentes. TB2 est
  souvent **non énuméré** (pas de hotplug PCIe), même avec un adaptateur
  TB2→TB3 : c'est la limite constatée par `open-apollo` sur les Apollo TB2.
  Les cartes TB3/4 peuvent nécessiter des réglages de runtime PM / D3cold.
- **Exemples :** Universal Audio Apollo x4/x8p (open-apollo), Apogee
  Symphony/Ensemble (pas de support Linux officiel), Focusrite Clarett
  Thunderbolt (pas de support Linux).
- **Conséquence :** ne jamais promettre « Thunderbolt = supporté ». Il faut
  tester l'énumération PCIe, le bridge TB et le runtime suspend.

### 3.3 FireWire (IEEE 1394)

- **Deux mondes :**
  1. les drivers kernel `snd-firewire` / `snd-fireface` pour certains RME ;
  2. **FFADO**, la stack user-space pour les interfaces FireWire
     (DICE, BeBoB, MOTU, Echo AudioFire, Focusrite Saffire, M-Audio
     ProFire, PreSonus FireStudio, etc.).
- **Ce que FFADO fait :** streaming audio et, selon le modèle, une partie du
  mixer. La couverture des contrôles est très inégale.
- **Pièges :** puces FireWire TI recommandées, alim, firmware, hotplug,
  latence, et le fait que FFADO est un serveur audio à part (à relier à
  PipeWire/JACK).
- **Exemples vérifiés :** MOTU 828/828mkII/828mkIII, Traveler, Focusrite
  Saffire Pro 40, M-Audio ProFire 2626, PreSonus FireStudio 26×26, Echo
  AudioFire 8, Tascam FireOne, Apogee Duet (2007), Behringer FCA1616/FCA202.
- **Conséquence :** FireWire est un monde séparé. Mixbay doit détecter FFADO et
  ne pas le confondre avec ALSA.

### 3.4 PCI / PCIe

- **Ce que c'est :** accès direct aux registres de la carte. C'est le meilleur
  terrain pour le support complet : pas de firmware USB, pas de latence de
  contrôle, matrices DSP accessibles.
- **Drivers kernel utiles :**
  - `snd-hdsp`, `snd-hdspm`, `snd-hdspe` (RME HDSP/HDSPe) ;
  - `snd-ice1712`, `snd-ice1724` (M-Audio Delta, ESI, Terratec) ;
  - `snd-echo` (Echo Audio PCI) ;
  - `snd-pcxhr`, `snd-mixart` (Digigram) ;
  - `snd-asihpi` (AudioScience).
- **Outils :** `hdspmixer`, `envy24control`, `echomixer`, `alsamixer`,
  `hdspeconf`, `Openface Mixer` (RayDAT).
- **Conséquence :** les cartes PCI/PCIe sont les meilleures candidates pour un
  support « complet » stable, mais elles sont de moins en moins courantes.

### 3.5 ADAT Lightpipe

- **Ce que c'est :** un transport optique (Toslink) pour 8 canaux numériques,
  avec l'horloge intégrée au flux. Ce n'est **pas** un protocole de contrôle.
- **Capacités :**
  - 44,1 / 48 kHz : 8 canaux ;
  - 88,2 / 96 kHz : 4 canaux (S/MUX) ;
  - 176,4 / 192 kHz : 2 canaux (S/MUX II).
- **Linux :** la carte expose les canaux ADAT comme des canaux PCM ALSA. Le
  nom du port contient souvent `ADAT`. Aucun driver ADAT générique n'existe.
- **Horloge :** l'ADAT peut être maître ou esclave. Un mauvais choix de clock
  produit des clics, des drops ou un signal qui se verrouille mal.
- **Exemples de matériel :** RME Digiface USB / RayDAT / Fireface, Ferrofish
  A32 / Pulse16, Behringer ADA8200, Focusrite OctoPre, Audient ASP800/880,
  MOTU 8pre, PreSonus DP88, SSL Alpha Link, convertisseurs divers.
- **Conséquence pour Mixbay :** ADAT doit être modélisé comme **ports/clock
  domains**, pas comme une carte. L'UI doit afficher le nombre de canaux
  réel selon la fréquence et signaler un S/MUX mal configuré.

### 3.6 S/PDIF et AES3

- **S/PDIF :** 2 canaux, consumer, coaxial ou optique, horloge intégrée,
  `iec958` dans ALSA.
- **AES3 / AES/EBU :** 2 canaux, professionnel, XLR, niveaux et channel status
  différents, souvent avec word clock séparé.
- **Linux :** exposé comme canaux PCM + contrôles `IEC958`. Pas de plan de
  contrôle.
- **Pièges :** sample rate, emphasis, copy flag, câbles 75 Ω vs 110 Ω,
  conversion S/PDIF↔AES3, et le fait qu'un canal AES peut transporter deux
  canaux sur un seul XLR.

### 3.7 MADI

- **Ce que c'est :** transport numérique multicanaux, optique ou coaxial,
  avec horloge intégrée. Capacités typiques :
  - 64 canaux à 48 kHz ;
  - 32 canaux à 96 kHz ;
  - 16 canaux à 192 kHz.
- **Linux :** la carte expose les canaux MADI en PCM. Pas de driver MADI
  générique, pas d'énumération.
- **Exemples :** RME MADIface / RayDAT / Digiface, Ferrofish A32 / A16,
  SSL Alpha Link, DirectOut, Merging, convertisseurs broadcast.
- **Conséquence :** même traitement qu'ADAT : ports, clock, channel count.

### 3.8 Word clock

- **Ce que c'est :** un signal d'horloge carré sur BNC, distribué à toutes les
  cartes d'un studio. C'est la façon *propre* de synchroniser plusieurs
  convertisseurs sans resampling.
- **Linux / PipeWire :** `clock.name` permet de dire que deux nœuds partagent
  la même horloge ; dans ce cas PipeWire ne resample pas entre eux. C'est
  l'équivalent logiciel du word clock.
- **Pièges :** termination 75 Ω, longueur des câbles, distribution en étoile,
  une seule horloge maître, et le fait qu'un mauvais word clock est souvent
  pire que pas de word clock.
- **Conséquence :** Mixbay doit distinguer « synchronisé par matériel »
  (word clock / ADAT / MADI / AES3) de « synchronisé par resampling ». C'est
  exactement la distinction que fait Audio MIDI Setup avec la case
  *Drift Correction*.

### 3.9 Dante (Audinate)

- **Ce que c'est :** audio sur IP propriétaire, très répandu en live, install,
  broadcast et studios. Le contrôle (routing, noms, latence) passe par Dante
  Controller / Dante Domain Manager ; l'audio passe par des flux UDP ; le
  clock passe par PTP.
- **Plan de contrôle :** mDNS (`5353`), services `_netaudio-arc._udp`,
  `_netaudio-cmc._udp`, `_netaudio-chan._udp` selon les générations.
  Ports UDP typiques observés : `4455`, `8700`, `4400`, `8800` (et des ports
  média alloués dynamiquement).
- **Clock :** PTPv1 en mode Dante natif ; PTPv2 quand le mode AES67 est
  activé. Les conflits avec NTP/chrony sont un problème connu.
- **Latence :** classes configurables selon les appareils (0,25 / 0,5 / 1 / 2 /
  5 / 10 / 20 / 40 ms ; 1 ms est la valeur courante par défaut). Dante Virtual
  Soundcard est annoncée à 4 ms.
- **Linux officiel :** **il n'y a pas de Dante Virtual Soundcard Linux**, et
  Dante Via n'existe pas sur Linux. Audinate ne fournit pas de driver Linux.
- **Linux non officiel :** `inferno` (Rust, user-space) fournit :
  - `inferno_aoip` (bibliothèque) ;
  - `alsa_pcm_inferno` (plugin PCM ALSA, donc visible par PipeWire/JACK) ;
  - `inferno2pipe` (capture vers pipe/fichier) ;
  - réception et émission, multicast, PTPv1 via un fork de Statime, PTPv2 via
    Statime/linuxptp, latence réglable, noms de canaux.
- **Ce qu'`inferno` ne fait pas :** Dante Domain Manager, une partie du
  contrôle Dante Controller, l'AES67 natif (TODO amont), le dual-NIC
  primary/secondary, et il reste « alpha » selon son auteur.
- **AES67 :** Dante peut exposer de l'AES67 sur certains appareils, en
  multicast, 48 kHz, avec PTPv2. Ce n'est pas équivalent à Dante natif :
  pas de DVS/Via, pas de contrôle Dante, et certains vieux appareils ne l'ont
  pas.
- **Conséquence pour Mixbay :** Dante n'est pas une carte USB. C'est un
  **système réseau** à intégrer dans l'audio foundation, avec détection mDNS,
  PTP, plugin ALSA, et une UI de flux. Il faut être honnête sur le statut non
  officiel et sur la licence.

### 3.10 AES67 / RAVENNA

- **AES67 :** standard d'interopérabilité audio sur IP (RTP, PTPv2, multicast,
  SAP, NMOS pour le contrôle). 48 kHz est le mode de base.
- **RAVENNA :** implémentation AES67 utilisée par Merging, Neumann,
  DirectOut, etc. Merging fournit un driver ALSA Linux officiel / VAD.
- **Linux :** `aes67-linux-daemon`, PipeWire AES67, `aes67-recorder`,
  `ffmpeg`/`gstreamer` pour le RTP brut.
- **Dante ↔ AES67 :** possible seulement si l'appareil Dante active AES67,
  en multicast, 48 kHz, avec PTPv2. Pas de contrôle Dante, pas de DVS.
- **Conséquence :** AES67 est la voie « standard ouvert » pour le réseau.
  Mixbay devrait le supporter avant/à côté de Dante natif.

### 3.11 AVB / MILAN

- **AVB :** famille IEEE 802.1 (802.1AS pour le temps, SRP/MVRP pour la
  réservation, AAF/IEC 61883 pour le transport). **MILAN** est le profil
  d'interopérabilité pro.
- **Linux :** support partiel via `libavtp`, `avb-utils`, `pipewire` et des
  drivers spécifiques. Ce n'est pas Plug & Play.
- **Exemples :** MOTU AVB (les modèles AVB sont aussi class-compliant USB,
  donc l'audio USB marche sans AVB), PreSonus AVB, convertisseurs AVB.
- **Conséquence :** à traiter plus tard ; le class-compliant USB couvre déjà
  beaucoup d'usages.

### 3.12 Plans de contrôle propriétaires (le vrai sujet)

| Transport | Exemples | Ce qu'on y trouve |
|---|---|---|
| USB HID | Audient EVO/iD, certains Focusrite | boutons, gains, mutes, 48 V |
| USB bulk vendor | SSL 12, RME UCX II, Apollo USB | mixer, routing, DSP, firmware |
| MIDI SysEx | RME Fireface en CC, MOTU, surfaces | mixer, presets, monitoring |
| HTTP / WebSocket | `douze` (SSL 12) | mixer, meters, profils |
| TCP | `open-apollo` (4710/4720/4721) | console, mixer, meters |
| OSC | `fireface-control`, `oscmix` | mixer, monitoring |
| mDNS | Dante, AES67 | découverte, routage |
| ALSA ctl | drivers kernel | volumes, mutes, clock, matrix |

**Conséquence :** Mixbay doit avoir un **adaptateur par famille de contrôle**,
pas un driver monolithique par carte. Le `drivers.Driver` actuel est déjà ce
point d'entrée ; il faut lui ajouter des backends réseau et des backends
« daemon externe ».

### 3.13 MIDI

- **USB MIDI class** : standard, `snd-usb-audio` + `snd-usbmidi`.
- **ALSA sequencer** : la couche de routage MIDI de Linux.
- **MIDI 2.0 / UMP** : support progressif dans ALSA/PipeWire.
- **Utilité pour Mixbay :** surfaces de contrôle, recall de scènes, sync
  d'appareils, et certains plans de contrôle constructeur (SysEx).
- **À ne pas confondre :** MIDI n'est pas de l'audio ; il ne faut pas le
  mettre dans le graphe audio, mais dans un graphe MIDI séparé.

### 3.14 Bluetooth, LE Audio, AirPlay

- **Bluetooth A2DP / HFP** : supporté par PipeWire, mais codecs lossy,
  latence et clock indépendants.
- **LE Audio / LC3** : supporté par PipeWire récent, encore jeune.
- **AirPlay / RAOP** : récepteurs et émetteurs via `shairport-sync`, `raop`,
  etc.
- **Conséquence :** ce sont des **sources/sinks supplémentaires** pour
  l'agrégat, pas des interfaces pro. Il faut les afficher avec leurs limites
  (latence, codec, pas de word clock).

### 3.15 Agrégats et dérive d'horloge (cross-cutting)

Voir la section 6 pour l'analyse complète d'Audio MIDI Setup et la
recommandation Mixbay.

---

## 4. Interfaces nativement supportées sur Linux

### 4.1 Niveau A — support complet (audio + contrôle/DSP)

> « Complet » signifie ici que le projet ou le driver expose la matrice, les
> préamps, le monitoring ou le DSP, pas seulement le volume système.

| Interface | Transport | Ce qui est contrôlé | Driver / outil | Statut | Notes |
|---|---|---|---|---|---|
| **Focusrite Scarlett 1st Gen** 6i6, 8i6, 18i6, 18i8, 18i20 | USB | mixer, routing, gains, 48 V, mute, firmware | kernel `snd-usb-audio` (scarlett2) + `alsa-scarlett-gui` | vérifié / amont | certains modèles 1st Gen ont des limites |
| **Focusrite Scarlett 2nd Gen** 6i6, 18i8, 18i20 | USB | idem | idem | vérifié / amont | |
| **Focusrite Scarlett 3rd Gen** Solo, 2i2, 4i4, 8i6, 18i8, 18i20 | USB | mixer, routing, gains, 48 V, mute | idem | vérifié / amont | |
| **Focusrite Scarlett 4th Gen** Solo, 2i2, 4i4, 16i16, 18i16, 18i20 | USB | mixer, routing, DSP, monitor groups, firmware | kernel ≥ 6.8 + `alsa-scarlett-gui` | vérifié / amont | les gros modèles 4th Gen ont un driver hybride `linux-fcp` |
| **Focusrite Clarett USB** 2Pre, 4Pre, 8Pre | USB | mixer, routing, gains, 48 V | idem | vérifié / amont | |
| **Focusrite Clarett+** 2Pre, 4Pre, 8Pre | USB | idem | idem | vérifié / amont | |
| **Focusrite Vocaster One / Two** | USB | mixer, EQ/compresseur DSP, routing | idem | vérifié / amont | |
| **Audient EVO 4** | USB | volumes, gains, 48 V, mute, monitor blend, loopback | `evo_raw` kmod + driver Mixbay | **vérifié Mixbay** | protocole FU10/FU11/EU51/EU56/EU58/EU59/MU60 |
| **Audient EVO 8** | USB | volumes, gains, 48 V, mutes, matrice 10×4 sur 2 bus | `evo_raw` kmod + driver Mixbay | **vérifié Mixbay** | mute de sortie émulé (firmware) |
| **Audient iD** (iD4, iD14, iD22, iD24, iD44, iD14 MKII, …) | USB | gains, 48 V, mute, monitoring, une partie du routing | `MixiD` (libusb/ImGui) | **partiel** | lecture retour en cours ; « tous les iD connus fonctionnent à un degré divers » |
| **SSL 12** | USB UAC2 + vendor | matrice, monitoring, préamps, 48 V, loopback, routing | `douze` / `sslctl` | **protocole cartographié** | quelques réglages clock non décodés ; code AGPL, protocole CC0 |
| **RME HDSP / HDSPe** (9632, 9652, AIO, RayDAT, MADIface, …) | PCI/PCIe | TotalMix complet (matrix, gains, monitoring) | `snd-hdsp` / `snd-hdspm` / `snd-hdspe` + `hdspmixer` | **vérifié / amont** | RayDAT ≥ 2022 : `snd-hdspe` DKMS |
| **RME Digiface USB** | USB | mixer TotalMix-like, ADAT/SPDIF, clock | kernel ≥ 6.12 + `Openface Mixer` | **vérifié (48 kHz)** | 4× ADAT/SPDIF |
| **RME Fireface 802** | FireWire / USB CC | mixer, routing, clock, gains, 48 V | `snd-fireface` + `Openface Mixer` | **communauté, non testé sur unité** | USB via MIDI SysEx |
| **RME Fireface 800** | FireWire | mixer, routing, clock, gains, 48 V | `snd-fireface` + `Openface Mixer` | **communauté, non testé sur unité** | |
| **RME Fireface UCX II** | USB vendor | audio 20 in / 24 out, registres, une partie du mixer | `oscmix` / `rme-ucx2-linux` | **expérimental** | PoC user-space, GUI mixer TODO |
| **RME Fireface UC / UCX / 400** | USB / FireWire | audio + une partie du mixer | `snd-fireface`, `oscmix`, `fireface-control`, `Openface Mixer` | **partiel** | couverture variable selon modèle |
| **Tascam US-16x08** | USB | mixer DSP (EQ, comp), routing, gains | kernel ≥ 4.11 + `tascam-gtk` | **vérifié** | un des rares USB avec DSP contrôlable |
| **MOTU PCI-424** (2408mk3, 24I/O, HD192) | PCIe | CueMix DSP, routing, gains | `motu-pci-424` / `motu424-ctl` | **expérimental** | reverse engineering récent |
| **MOTU AVB** (828es, 1248, 16A, …) | USB CC / AVB | audio ; CueMix 5 build Linux non officiel | `snd-usb-audio` + CueMix 5 Linux | **vendor-limited** | CueMix 5 Linux contrôle local et réseau, non supporté officiellement |
| **MOTU FireWire** (828, 828mkII/III, Traveler, 896, …) | FireWire | audio + partie CueMix | FFADO | **partiel** | matrice selon modèle |
| **Echo Audio PCI** (Darla, Gina, Layla, Mia, Mona) | PCI | matrix, monitoring, gains | `snd-echo` + `echomixer` | **vérifié / amont** | legacy, excellent support |
| **Echo AudioFire** | FireWire | audio + partie mixer | FFADO | **partiel** | |
| **M-Audio Delta / ESI / Terratec** (ice1712/ice1724) | PCI | matrix, monitoring, gains | `snd-ice1712` / `snd-ice1724` + `envy24control` | **vérifié / amont** | Delta 1010, 2496, etc. |
| **Digigram VX222e / PCXHR / Mixart** | PCI/PCIe | audio + mixer | `snd-pcxhr` / `snd-mixart` | **vendor / amont** | support officiel Digigram |
| **AudioScience ASI5x00 / 6x00 / 8800** | PCI/PCIe | audio + mixer, contrôles broadcast | `snd-asihpi` + driver AudioScience | **vendor** | driver constructeur, ALSA |
| **Universal Audio Apollo x4** | Thunderbolt 3/4 | audio, préamps, monitor, DSP mixer, meters | `open-apollo` (`ua_apollo` + daemon) | **expérimental, vérifié x4** | 22 canaux ALSA ; S/PDIF/ADAT non testés |
| **Universal Audio Apollo x8p** | Thunderbolt 3/4 | audio, 8 préamps, channel identity | `open-apollo` | **vérifié par owners** | autres modèles à tester |
| **Universal Audio Apollo Solo USB** | USB | audio, préamps, monitor | `open-apollo` stack USB | **vérifié v1.3** | init USB fragile selon firmware |
| **Antelope Zen Go / Orion Studio Synergy Core** | USB | une partie des contrôles | `Antelope-Ctl`, `zen-go-tui` | **early / expérimental** | reverse engineering 2026, pas production |
| **Merging Hapi / Horus / Anubis** | Ethernet RAVENNA/AES67 | audio, routing, clock | driver ALSA Merging officiel / VAD | **vendor** | PTPv2, pas Dante |

**Conclusion du niveau A :** une vingtaine de familles, pas des centaines de
modèles. Le reste du marché est soit class-compliant sans DSP, soit
propriétaire non décodé.

### 4.2 Niveau B — audio seul, class-compliant (pas de contrôle DSP)

Ces interfaces fonctionnent généralement **plug and play** pour le flux audio,
mais leur mixer/préamps constructeur n'est pas pilotable sur Linux (ou seulement
via des contournements). C'est le plus gros du marché.

| Famille | Modèles représentatifs | Notes |
|---|---|---|
| **Behringer** | UMC22, UM2, UMC202HD, UMC204HD, UMC404HD, UMC1820, UMC1204USB, XR18, X32 USB | class-compliant ; pas de DSP constructeur ; X32 a son propre protocole de mixer (réseau/MIDI), pas un DSP de carte |
| **Steinberg** | UR12, UR22, UR22C, UR44, UR44C, UR816C | class-compliant ; `dspMixFx` n'existe pas sur Linux |
| **Yamaha** | AG03, AG06, AG06MK2, MG-XU | class-compliant ; DSP interne non contrôlable |
| **Roland** | Rubix 22/24/44, Octa-Capture, Tri-Capture, UA-25EX | class-compliant selon modèles ; certains nécessitent des quirks |
| **Zoom** | U-22, U-44, UAC-2, UAC-8, L-8, LiveTrak L-12 | class-compliant ; pas de contrôle du DSP |
| **Tascam** | US-2x2, US-4x4, US-122L, US-144, US-42B, Model 12/16/24 | class-compliant ; US-16x08 est l'exception complète |
| **PreSonus** | AudioBox USB 96, Studio 24c, Studio 68c, Quantum ES 4, ioStation 24C | class-compliant ; Universal Control n'est pas disponible ; Quantum ES 4 est la base beta Mixbay |
| **MOTU** | M2, M4, M6 | class-compliant ; pas de CueMix |
| **Native Instruments** | Komplete Audio 1/2/6 | class-compliant |
| **Arturia** | MiniFuse 1/2/4 | class-compliant ; loopback matériel |
| **SSL** | SSL 2, SSL 2+ | class-compliant ; pas de matrice DSP (le SSL 12 est le cas complet) |
| **Audient** | iD en mode class-compliant | audio seul sans MixiD |
| **RME** | Babyface / Babyface Pro / UCX en mode CC | audio seul ; TotalMix non exposé |
| **Apogee** | Duet (selon génération), ONE (ancien) | support variable ; souvent macOS-first |
| **Prism Sound** | Titan, Atlas, Lyra | class-compliant pour l'audio ; contrôles limités |
| **Ferrofish** | A32, Pulse16, A16 | ADAT/MADI, pas de contrôle DSP depuis Linux |
| **Cranborne Audio** | 500R8, 500ADAT | class-compliant ; monitoring matériel |
| **SPL** | Crimson, Marc One | class-compliant |
| **M-Audio** | M-Track Solo/Duo/2x2, AIR 192 | class-compliant |
| **iConnectivity** | iConnectAudio4+, PlayAUDIO | class-compliant |
| **Rode** | Rodecaster, AI-1 | class-compliant |
| **Mackie** | Onyx, ProFX | class-compliant selon modèles |
| **Alesis** | iO2, MultiMix | class-compliant |
| **Pioneer DJ / Reloop / Hercules** | contrôleurs et cartes DJ | audio souvent class-compliant, contrôle MIDI/HID séparé |
| **Micros USB, webcams, casques, HDMI/DisplayPort** | — | UAC standard ; pas de DSP |

**Important :** « class-compliant » ne garantit pas 100 % de stabilité. Les
quirks kernel sont nombreux : feedback implicite, cartes qui ne se réveillent
pas après suspend, fréquence verrouillée, channels mapping incorrect, etc.

### 4.3 Niveau C — partiel, expérimental, ou dépendant d'un daemon

| Cas | Pourquoi |
|---|---|
| **RME Fireface UCX II** | PoC user-space récent ; audio et registres, mixer GUI encore TODO |
| **RME Fireface 802/800 via Openface** | protocole documenté, pas encore validé sur toutes les unités |
| **MOTU PCI-424** | reverse engineering récent, `motu424-ctl` |
| **UA Apollo (modèles non x4/x8p/Solo)** | même registre annoncé, mais non testé ; TB2 non supporté |
| **Antelope** | contrôle partiel, pas de DSP complet |
| **SSL 12** | quelques réglages clock/settings non décodés |
| **Audient iD** | lecture retour et certains switches/meters en cours |
| **Focusrite Clarett Thunderbolt** | pas de support Linux (TB) |
| **Lynx AES16/AES16e** | ALSA absent ; OSS4 historique pour certains |
| **Metric Halo 3d** | support Linux annoncé/limité, à vérifier |
| **Avid / Digidesign** | Mbox 2 / Digi 003 via FFADO/quirks, support obsolète |
| **Pro Tools HD / HDX** | pas de support Linux natif |
| **UAD-2 DSP cards** | ce ne sont pas des interfaces audio ; pas de driver Linux |

### 4.4 Niveau D — non supporté (à documenter comme tel)

- Apollo Thunderbolt 2 (Apollo Twin/8/16/Quad/Duo) : Linux n'énumère pas le
  PCIe TB2 dans la plupart des configurations.
- Apogee Symphony / Ensemble Thunderbolt : pas de driver Linux.
- Focusrite Clarett Thunderbolt : pas de driver Linux.
- Lynx Aurora(n) / Hilo : pas de driver ALSA (sauf class-compliant à vérifier).
- La plupart des DSP constructeur « cloud » ou « FPGA » sans protocole public.
- Les cartes dont le firmware exige une activation en ligne ou un compte
  constructeur.

---

## 5. Catalogue des projets de reverse engineering / support

### 5.1 Universal Audio Apollo — `open-apollo`

- **Source :** <https://github.com/rolotrealanis98/open-apollo> (GPL-2.0)
- **Ce que c'est :** driver kernel Linux `ua_apollo` pour Apollo Thunderbolt,
  plus une stack user-space pour Apollo USB, un daemon mixer, et une console
  native `uaconsole`.
- **Architecture :**
  - `driver/` : module PCIe, DMA, ALSA, DSP ring buffer, préamps ;
  - `mixer-engine/` : daemon Python, TCP 4710 (console), 4720 (mixer),
    4721 (WebSocket optionnel) ;
  - `console-rs/` : `uaconsole`, reconstruction de UAD Console ;
  - `oa-assets` : extrait firmware/DSP/art depuis **votre** installation UAD ;
  - `tools/uausb/` : init USB pour Apollo Solo.
- **Modèles vérifiés :** Apollo x4 (TB3), Apollo x8p (par owners), Apollo Solo
  USB (v1.3). Les autres x6/x8/x16/Twin/Solo TB/Arrow sont « needs testing ».
- **Ce qui marche :** audio duplex, tous les sample rates, préamps (gain,
  48 V, PAD, low cut, phase, mic/line), monitor (volume, mute, dim, mono,
  headphones, talkback), meters, DSP mixer (faders, pan, sends, solo, mute),
  I/O virtuels PipeWire.
- **Ce qui manque :** talkback routing, virtual/monitor loopback, parties de
  la console, multi-device, I/O numériques (S/PDIF/ADAT) et clock externe non
  testés, suspend/resume non testé, hosting de plugins expérimental.
- **Contraintes :** Secure Boot (signature DKMS), firmware extrait d'une
  installation UAD, hot-unplug, carte TB2 non supportée, le Snap Firefox peut
  crasher avec WebRTC.
- **Pour Mixbay :** ne pas réimplémenter le driver. Intégrer `open-apollo`
  comme backend externe (daemon TCP) + onboarding d'installation. Voir TODO.

### 5.2 Dante — `inferno`

- **Source :** <https://github.com/teodly/inferno> (miroir de
  <https://gitlab.com/lumifaza/inferno>), GPL-3.0-or-later ou AGPL-3.0.
- **Ce que c'est :** implémentation non officielle de Dante en Rust,
  entièrement user-space.
- **Composants :**
  - `inferno_aoip` : bibliothèque ;
  - `alsa_pcm_inferno` : plugin PCM ALSA (le « Dante Virtual Soundcard »
    Linux) ;
  - `inferno2pipe` : capture vers pipe/fichier ;
  - `searchfire` : mDNS compatible Dante ;
  - `usrvclock` : réception d'horloge.
- **Clock :** PTPv1 via un fork de Statime (nécessaire pour Dante natif),
  PTPv2 via Statime/linuxptp. Conflits NTP connus ; `CLOCK_PATH` peut pointer
  sur `/dev/ptp0` pour le hardware timestamping.
- **Testé avec :** Audinate AVIO (AES3, DAI2, DIOUSBC), Klark Teknik DN32-DANTE
  (X32), Behringer Aoip-Dante (Wing Rack), Soundcraft Vi2000/Vi3000, Allen &
  Heath SQ-5/SQ-6/Qu-5D, Yamaha Dante-MY16-AUD, RIVAGE PM3, DSP-RX, ESI
  planet 22c, Dante Via (macOS/Windows), DVS (Windows).
- **Ce qui manque :** DDM, contrôle complet type Dante Controller, AES67,
  dual-NIC primary/secondary, API de changement de canaux à chaud.
- **Latence :** réglable via `RX_LATENCY_NS` / `TX_LATENCY_NS`, dépend du
  kernel et du NIC ; hardware timestamping recommandé.
- **Ports :** 4455, 8700, 4400, 8800, 5353 (plus ports média dynamiques).
- **Pour Mixbay :** c'est la brique Dante de l'audio foundation. Voir TODO.

### 5.3 SSL 12 — `douze`

- **Source :** <https://github.com/xenicle/douze> (code AGPL-3.0, protocole
  CC0-1.0).
- **Ce que c'est :** reverse engineering complet du protocole SSL 12, CLI
  `sslctl`, GUI web `http://localhost:1212`, hôte VST3 `Douze FX`.
- **Contrôlé :** matrice de gain, monitoring (dim/cut/mono/alt/talk), préamps
  (48 V, HPF, inst, polarité), loopback, clock readback, boutons frontaux
  assignables, faders/pans/mutes/solos/profils (émulés côté logiciel).
- **Non décodé :** quelques contrôles SETTINGS/clock.
- **Intégration PipeWire :** split du sink 8 canaux en 4 paires stéréo
  (`ssl12.pb12`…), anti-suspend WirePlumber, noms de nœuds basés sur le
  numéro de série.
- **Pour Mixbay :** déjà intégré via le backend douze ; le rapport propose
  d'aligner le modèle de capabilities sur le protocole complet (préamps, 48 V,
  monitoring) plutôt que de garder ces contrôles dans Omarchy360.

### 5.4 Audient iD — `MixiD`

- **Source :** <https://github.com/TheOnlyJoey/MixiD> (MIT)
- **Ce que c'est :** panneau de contrôle Linux pour les iD, libusb + GLFW +
  ImGui.
- **Statut :** tous les iD USB connus sont reconnus ; le protocole est
  « majoritairement compris » ; lecture retour, VU meters et certains
  switches/modes encore en cours.
- **Contrainte :** udev rule sur le vendor `2708` (groupe `audio`/`plugdev`),
  l'app doit prendre le périphérique en exclusif.
- **Pour Mixbay :** backend « Audient iD » distinct de l'EVO ; ne pas mélanger
  les protocoles. MixiD est une bonne référence de mapping.

### 5.5 Focusrite — `alsa-scarlett-gui`

- **Source :** <https://github.com/geoffreybennett/alsa-scarlett-gui>
  (GPL-3.0)
- **Ce que c'est :** GUI GTK4 pour les contrôles ALSA exposés par le driver
  kernel Focusrite. C'est l'équivalent de Focusrite Control / Scarlett
  MixControl / Vocaster Hub.
- **Couverture :** Scarlett 1st/2nd/3rd/4th Gen, Clarett USB/Clarett+,
  Vocaster One/Two ; routing drag & drop, matrix mixer, EQ/compresseur
  (Vocaster), monitor groups, presets, meters, firmware.
- **Kernel :** `sound/usb/mixer_scarlett2.c` (et `linux-fcp` pour les gros
  4th Gen).
- **Pour Mixbay :** c'est le modèle « driver kernel + GUI » à imiter. Mixbay
  peut piloter les contrôles ALSA directement (pas besoin de réimplémenter le
  driver) et offrir une vue unifiée.

### 5.6 RME — `Openface Mixer`, `oscmix`, `rme-ucx2-linux`

- **Openface Mixer :** <https://github.com/thomas-nelson23/Openface-Mixer>
  (MIT). TotalMix-like pour Digiface USB, Fireface 802 (FireWire/USB CC),
  Fireface 800 (FireWire), HDSPe RayDAT. Moteur qui restaure le mix au login.
  Certains modèles ne sont pas encore validés sur unité.
- **oscmix :** <https://github.com/michaelforney/oscmix> (ISC). Mixer/contrôle
  pour Fireface UCX II (et UC), registre + SysEx. Référence de protocole.
- **rme-ucx2-linux :** <https://github.com/yonie/rme-ucx2-linux> (MIT).
  Driver user-space pour UCX II en mode vendor-specific : 20 in / 24 out,
  float32, 44,1–192 kHz, bridge PipeWire stéréo, registres et meters.
  PoC, pas production.
- **fireface-control / linux-fireface-mixer :** alternatives OSC/GUI pour
  Fireface.
- **Pour Mixbay :** le backend RME actuel est ALSA niveau 1. Le rapport
  recommande d'ajouter un backend « RME mixer » qui parle aux daemons/protocoles
  existants plutôt que de dupliquer TotalMix.

### 5.7 MOTU — `motu-pci-424`, CueMix 5 Linux, FFADO

- **motu-pci-424 :** <https://github.com/devfrp/Linux-motu-pci-424>.
  `motu424-ctl`, équivalent CueMix FX pour les cartes PCI-424.
- **CueMix 5 Linux :** build non officiel fourni par MOTU, contrôle les
  appareils locaux et réseau ; non supporté officiellement.
- **FFADO :** <https://ffado.org/> pour les MOTU FireWire.
- **Pour Mixbay :** détecter le transport (PCI vs FireWire vs USB) et choisir
  le backend ; ne pas supposer que « MOTU » implique un seul protocole.

### 5.8 Tascam — `tascam-gtk`

- **Source :** <https://github.com/onkelDead/tascam-gtk> (GPL).
- **Ce que c'est :** contrôle du mixer DSP du US-16x08 via les contrôles ALSA
  du kernel (support depuis Linux 4.11).
- **Pour Mixbay :** excellent candidat pour un backend « Tascam DSP » ; le
  US-16x08 est l'un des rares USB avec DSP complet contrôlable.

### 5.9 Autres briques utiles

| Projet | Rôle | Lien |
|---|---|---|
| `snd-firewire-ctl-services` | contrôle FireWire (Fireface 802/800) | <https://github.com/alsa-project/snd-firewire-ctl-services> |
| FFADO | stack FireWire | <https://ffado.org/> |
| `network-audio-controller` | contrôle Dante en CLI | <https://github.com/chris-ritsen/network-audio-controller> |
| `aes67-linux-daemon` | AES67 | <https://github.com/bondagit/aes67-linux-daemon> |
| PipeWire AES67 | AES67 natif PipeWire | <https://gitlab.freedesktop.org/pipewire/pipewire/-/wikis/AES67> |
| Statime | PTPv1/v2 | <https://github.com/pendulum-project/statime> |
| `searchlight` / `searchfire` | mDNS | <https://github.com/WilliamVenner/searchlight> |
| `wycliffe` | première réception Dante documentée | <https://github.com/jsharkey/wycliffe> |
| `audient-evo-py` | protocole EVO de référence | <https://github.com/vanzaho/audient-evo-py> |
| `evoctl` | matrice EVO 8 | <https://github.com/soerenbnoergaard/evoctl> |
| `audient-evo-linux-tools` | outils EVO | <https://github.com/vijay-prema/audient-evo-linux-tools> |
| `evo8-rp2350-arduino` | table d'encodage EVO 8 | <https://github.com/hoskere/audient-evo8-rp2350-arduino> |
| `TuxMix` / `oscmix` | séparation daemon/client, scènes | <https://github.com/ismail-bahloul/TuxMix> |
| `Antelope-Ctl` | contrôle Antelope | <https://github.com/diafebus/Antelope-Ctl> |
| `zen-go-tui` | contrôle Zen Go | <https://github.com/ryodeushii/zen-go-tui> |
| `linux-fcp` | driver Focusrite 4th Gen big | <https://github.com/geoffreybennett/linux-fcp> |

---

## 6. Audio MIDI Setup (macOS) : agrégats et correction de dérive

### 6.1 Ce que fait Audio MIDI Setup

- Liste les périphériques audio et MIDI.
- Permet de créer un **Aggregate Device** : plusieurs interfaces vues comme
  une seule carte multicanale.
- Choisit une **Sync Source** (l'horloge maître de l'agrégat).
- Affiche un sample rate commun et une case **Drift Correction** par membre.
- Permet de jouer sur plusieurs sorties à la fois (Multi-Output).

### 6.2 Ce qu'est réellement la drift correction

Chaque interface a son propre quartz. Même à 48 000 Hz nominal, deux cartes
tournent à des vitesses légèrement différentes (quelques ppm à quelques
dizaines de ppm). Sans synchronisation :

- une carte produit plus d'échantillons que l'autre ;
- les buffers se vident ou débordent ;
- on entend des clics, des sauts, une dérive de phase ;
- sur une longue session, l'alignement temporel se perd.

La **drift correction** (ou *resampling*) insère un convertisseur de
fréquence adaptatif sur chaque membre non synchronisé, pour que son flux
corresponde à l'horloge maître. macOS le fait automatiquement, avec une
qualité et une latence choisies par le système.

### 6.3 Avantages

- **Utiliser des interfaces hétérogènes** sans word clock.
- **Ajouter des I/O progressivement** (une carte 2 canaux + une 8 canaux = 10).
- **Réutiliser du matériel existant**, y compris des cartes sans entrée clock.
- **Modèle mental simple** : une source de sync, des cases à cocher.
- **Pas de câblage word clock**, donc moins de problèmes de termination.

### 6.4 Limites et coûts

- **Ce n'est pas bit-perfect** : resampling = traitement numérique.
- **Latence et CPU** supplémentaires, surtout à haute qualité.
- **Qualité dépendante du resampler** (PipeWire : sinc adaptatif, qualité 0–14,
  défaut 4).
- **Un agrégat mal configuré est instable** : mauvais maître, sample rates
  différents, périphériques qui dorment, hotplug.
- **Ne remplace pas le word clock** quand la précision et la phase comptent
  (multipiste critique, broadcast, mesures).
- **Ajoute de la complexité de debug** : il faut voir les ppm, les xruns, les
  taux réels.

### 6.5 Équivalents Linux

| Concept macOS | Équivalent Linux |
|---|---|
| Aggregate Device | `libpipewire-module-combine-stream` (sink/source virtuel) + loopbacks, ou un profil JACK avec `alsa_in`/`alsa_out` |
| Sync Source | nœud « driver » PipeWire (`priority.driver`) / `clock.name` |
| Drift Correction | resampler adaptatif PipeWire (activé par défaut quand les clocks diffèrent) ; `resample.disable` pour l'interdire ; `clock.name` pour dire « même horloge, pas de resampling » |
| Sample Rate | `default.clock.rate`, `node.force-rate`, `audio.allowed-rates` |
| Multi-Output | `combine-stream` en mode sink, ou plusieurs loopbacks |
| Channel map | `audio.position`, `combine.audio.position`, `stream.dont-remix` |
| Latency | `node.latency`, `combine.latency-compensate`, `target.delay.sec` |

**Détail PipeWire important :** `priority.driver` choisit le nœud qui pilote
le graphe. Le resampler adaptatif est appliqué aux autres nœuds. `clock.name`
permet de déclarer que deux nœuds partagent la même horloge (word clock) et
qu'il ne faut **pas** resampler entre eux. C'est exactement la distinction
« Sync hardware » vs « Drift Correction » de macOS.

### 6.6 Faut-il l'intégrer à Mixbay ?

**Oui, mais pas comme une copie de l'UI macOS.** Recommandation :

1. **Créer un concept de « Clock domain »** dans Mixbay : chaque carte a une
   horloge, un taux réel, une source (interne, word clock, ADAT, MADI, AES3,
   Dante PTP, USB feedback). L'UI montre qui est maître et qui est resamplé.
2. **Écran « Aggregate »** : sélection de cartes, source de sync, sample rate,
   correction de dérive par membre (on/off), latence cible, mapping des
   canaux, nom du device virtuel, profil sauvegardable.
3. **Par défaut, correction activée** pour les membres non synchronisés par
   matériel ; désactivée si `clock.name` identique ou word clock détecté.
4. **Afficher la santé** : ppm estimé, xruns, taux réel, latence ajoutée,
   qualité du resampler. Ne pas cacher le resampling.
5. **Laisser le graphe avancé à qpwgraph** : Mixbay propose l'agrégat
   « simple » ; qpwgraph reste l'éditeur de routing fin.
6. **Ne pas écrire de serveur audio** : utiliser PipeWire
   (`combine-stream`, `loopback`, `clock.name`, `priority.driver`). C'est la
   seule façon de rester maintenable et de profiter des correctifs.
7. **Tester avec deux cartes USB de clocks différentes**, puis avec deux
   cartes word-clockées : le comportement doit être différent et visible.

**Avantages pour Mixbay :** c'est la fonctionnalité qui transforme « un
contrôleur de cartes » en « bay audio tout-en-un ». **Risque :** promettre du
bit-perfect alors qu'on resample ; il faut être explicite.

**Verdict :** à intégrer, en priorité après la fondation et avant Dante/Apollo,
car c'est transverse et utile à tous les utilisateurs.

---

## 7. État actuel de Mixbay (vérifié dans le repo)

### 7.0 Identifiants matériels suivis

| Carte | USB VID:PID | Backend |
|---|---|---|
| Audient EVO 8 | `2708:0007` | `evo_raw` kmod (`/dev/evo8`, ioctl) |
| Audient EVO 4 | `2708:0006` | `evo_raw` kmod (`/dev/evo4`, ioctl) |
| Solid State Logic SSL 12 | `31e9:0005` (audio) / `31e9:0024` (contrôle) | `douze` HTTP 1212 |
| RME Fireface UCX II | `2a39:3xxx` | ALSA niveau 1 (TotalMix via oscmix/Openface à intégrer) |
| ESI UGM192 | `0a51:0019` | ALSA niveau 1 |
| PreSonus Quantum ES 4 | `194f:010d` | ALSA niveau 1 (beta) |

### 7.1 EVO 4 / EVO 8

- **Protocole :** port Go de `vanzaho/audient-evo-py` (domaine public).
- **Cibles :** FU10 volume, FU11 gains, EU51 capture 6 canaux (EVO 8), EU56
  monitor (EVO 4), EU58 mutes/48 V, EU59 mute (EVO 4), MU60 loopback
  write-only.
- **Quirks respectés :** 4 octets pleins sur EU58/59, jamais de GET sur MU60,
  EU56 seulement CS=0 CN=0, paires de sorties groupées sur des CN impairs,
  gains en CN 1-based.
- **Mute de sortie EVO 8 émulé :** le firmware rejette le sélecteur EU58 CS=2 ;
  Mixbay baisse la sortie à `VolMin` via FU10 et mémorise le niveau précédent.
- **DEMO persistant :** sans hardware, l'état est simulé et persistant ; les
  écritures strictes échouent au lieu d'écrire le shadow.
- **Split PipeWire :** 6 canaux USB → 3 sinks stéréo + 3 sources stéréo.
- **Meters :** capture USB, pas le niveau analogique de sortie.
- **Statut :** support complet EVO 4/8, validé sur EVO 8 (et EVO 4 selon les
  tests disponibles).

### 7.2 SSL 12

- **Backend :** `douze` (HTTP local 1212).
- **Contrôlé :** volumes masters, mutes, mixer/sends, setup complet depuis
  Mixbay.
- **Reste dans Omarchy360 :** préamps, 48 V, monitoring complet, boutons USER.
- **Statut :** natif partiel (v0.1.0), le protocole complet est documenté par
  `douze`.

### 7.3 RME Fireface UCX II / ESI UGM192

- **Niveau 1 ALSA** : volumes/mutes, pas de DSP.
- **Statut :** v0.0.1 ; la matrice TotalMix est en attente. Le rapport note que
  `oscmix`, `Openface Mixer` et `rme-ucx2-linux` peuvent accélérer ce support.

### 7.4 PreSonus Quantum ES 4

- **Statut :** beta, base de test reverse engineering ; ALSA niveau 1
  (volume/mute), pas de gain/48 V/mixer.
- **But :** promouvoir en natif après capture et validation.

### 7.5 Audio foundation

- **udev** : `TAG+="uaccess"` pour EVO, règle de capture EU51.
- **WirePlumber** : anti-suspend, `node.pause-on-idle=false`,
  `channelmix.upmix=false` pour Audient/RME/ESI/PreSonus/SSL.
- **Split EVO 8** : nodes stéréo générés depuis le graphe réel, pas de nom
  codé en dur.
- **Défauts** : sink/source au login.
- **Clock** : 48 kHz par défaut, 44,1–192 autorisés, quantum 1024, sauf si
  `pipewire-settings` gère déjà l'horloge. Mismatch signalé, jamais forcé.

### 7.6 Patchbay

- **Explicite** : rien n'est appliqué automatiquement au branchement.
- **Presets** : liens matériels + empreinte des interfaces ; apply refuse si
  l'empreinte a changé.
- **UI** : Devices → PipeWire patchbay, sauvegarde/application manuelles.

### 7.7 Harness de reverse engineering (implémenté)

`harness/mixbay-reverse.py`, déployé en `~/.local/bin/mixbay-reverse` :

- capture l'API texte usbmon (`/sys/kernel/debug/usb/usbmon/<bus>u`) ;
- découvre les canaux de la carte (PipeWire/pactl) puis avance contrôle par
  contrôle en mode `--guided` ;
- fusionne submission/callback par URB ID ;
- capture une baseline silencieuse puis une action ;
- diff : nouveau transfert, ou même requête avec payload différente ; le
  polling identique est ignoré ;
- stocke `meta.json`, `baseline.jsonl`, `action.jsonl`, `candidates.jsonl`,
  `capture.txt`, `map.json` sous `~/.config/mosquitomixbay/reverse/` ;
- replay contrôle/bulk/interrupt, uniquement les octets capturés, dans l'ordre,
  avec GET/acks, `--dry-run`, confirmation `REPLAY`, `--verify` ;
- intégré à la TUI : Settings → Reverse engineering harness, et carte beta →
  Restart reverse engineering.

Limites actuelles : pas de reconstruction HID multi-octets, pas de timing
sub-milliseconde, pas de promotion automatique beta → native, pas de PCIe
Thunderbolt (usbmon ne le voit pas). Voir `harness/README.md`.

### 7.8 Ce qui n'est pas encore fait

- Validation EVO 8/EVO 4 sur toutes les combinaisons UCM/kernel.
- Extension des splits/profils aux RME, ESI, SSL 12, beta.
- Mapping automatique des contrôles capturés vers le modèle EVO 8, et
  promotion beta → native après validation.
- Support complet Apollo, Dante, aggregate/drift.
- Tests de non-régression sur matériel réel.

---

## 8. Intégration Dante dans Mixbay — design (sans implémentation)

### 8.1 Pourquoi dans l'audio foundation, pas dans le driver registry

Dante n'est pas une carte USB : c'est un système réseau. Il doit vivre dans
`foundation/` (ou un module frère `dante/`) car il touche :

- l'interface réseau et le PTP ;
- les ports UDP / le firewall ;
- un daemon user-space et un plugin ALSA ;
- le split PipeWire et les profils ;
- l'onboarding « première connexion ».

Le `drivers.Driver` peut exposer un backend `dante` pour l'UI, mais
l'installation et le clocking appartiennent à la fondation.

### 8.2 Détection

- mDNS : `avahi-browse -rt _netaudio-arc._udp`,
  `_netaudio-cmc._udp`, `_netaudio-chan._udp`.
- Cartes réseau : `ethtool -T <iface>` pour le hardware timestamping ;
  vérifier la présence de `/dev/ptp*`.
- Ports : 4455, 8700, 4400, 8800, 5353.
- Ne pas confondre avec un périphérique USB Dante (certaines cartes exposent
  aussi l'audio en USB class-compliant).

### 8.3 Flux de première connexion (proposé)

1. Détecter un appareil Dante et afficher un écran explicite :
   « Dante est un protocole propriétaire ; Linux n'a pas de driver officiel.
   Mixbay utilise `inferno`, une implémentation non officielle. »
2. Proposer **Installer** / **Plus tard** (comme l'onboarding EVO).
3. Si Installer :
   - vérifier Rust/Cargo ou utiliser un binaire packagé ;
   - compiler `inferno` (ou installer le paquet) ;
   - installer le fork Statime pour PTPv1 ;
   - écrire la config réseau (interface, `DEVICE_ID`, `NAME`, canaux,
     latence) ;
   - ouvrir les ports UDP ;
   - créer le PCM ALSA `inferno` ;
   - créer les nœuds PipeWire/split ;
   - proposer un preset patchbay.
4. Persister le profil par appareil (nom, IP, canaux, latence, interface).
5. Ne jamais relancer automatiquement pendant un live sans confirmation.

### 8.4 Limites à afficher dans l'UI

- Non officiel / non supporté par Audinate.
- Pas de DDM.
- Pas d'AES67 natif (sauf via le mode AES67 de l'appareil + PTPv2).
- PTPv1 nécessaire pour Dante natif ; conflits NTP possibles.
- Latence dépendante du kernel/NIC.
- Certains appareils anciens ou DVS/Dante Via peuvent ne pas être compatibles.

---

## 9. Intégration Apollo dans Mixbay — design (sans implémentation)

### 9.1 Principe

Ne pas réécrire `open-apollo` en Go. L'intégrer comme **stack externe
optionnelle** :

- `open-apollo` fournit le module `ua_apollo`, le daemon mixer (TCP 4710/4720)
  et `uaconsole`.
- Mixbay fournit : détection, onboarding, installation guidée, backend
  `Driver` qui parle au daemon, mapping des strips/contrôles, et fallback ALSA
  si le daemon n'est pas là.
- L'UI Mixbay ne doit pas dupliquer la console complète : elle expose les
  contrôles utiles (préamps, monitor, mixer, meters) et un bouton « Open
  uaconsole » pour les fonctions avancées.

### 9.2 Ce qu'il faut porter / brancher

- Table des modèles Apollo (ID USB/PCI, canaux, préamps, particularités).
- Détection du transport (TB3/4 vs USB) et refus explicite du TB2.
- Installation DKMS + Secure Boot (MOK) + firmware extrait de l'installation
  UAD de l'utilisateur.
- udev / permissions.
- Client du daemon (état, writes, meters).
- Mapping vers `Spec`/`Caps` de Mixbay.
- Gestion du hot-unplug et du power cycle.
- Tests par modèle, avec la matrice de statut d'`open-apollo`.

### 9.3 Risques

- Projet expérimental, une seule carte vraiment vérifiée (x4) + x8p/Solo USB.
- Firmware et art extraits d'une installation UAD : dépendance à une
  installation Windows/VM.
- Secure Boot, kernel updates, crash possible.
- Ne pas promettre « Apollo supporté » sans modèle et version de firmware.

---

## 10. Feuille de route recommandée

| Priorité | Chantier | Pourquoi |
|---|---|---|
| P0 | Finitions UI (faite) : pas de note DEMO sur l'accueil, ligne « No interfaces connected », version collée au nom dans Audio foundation | confort immédiat |
| P1 | Ce rapport + TODOs sourcés (`open-apollo`, `inferno`) | base de décision |
| P2 | Aggregate devices + drift correction (design validé ici, implémentation à faire) | fonctionnalité transverse, inspire Audio MIDI Setup |
| P3 | Dante via `inferno` dans l'audio foundation | couvre le live/install |
| P4 | Apollo via `open-apollo` (backend daemon) | couvre le studio UA |
| P5 | Harness de reverse engineering (fait : `mixbay-reverse` usbmon), reste le mapping automatique beta → native | permet d'étendre le support |
| P6 | Support complet RME (oscmix/Openface), MOTU, Tascam, Antelope | élargit le catalogue |

**Definition of done pour « support complet » :**

- audio stable à toutes les fréquences supportées ;
- tous les contrôles matériels utiles exposés et testés ;
- meters et clock readback ;
- hotplug et suspend/resume ;
- état persistant et restauration ;
- tests automatisés + validation sur matériel réel ;
- documentation du protocole et de la licence ;
- fallback ALSA propre si le contrôle échoue.

---

## 11. Sources principales

- ALSA SoundCard Matrix : <https://www.alsa-project.org/main/index.php/Matrix:Main>
- Arch Wiki Professional audio/Hardware :
  <https://wiki.archlinux.org/title/Professional_audio/Hardware>
- PipeWire properties (resampler, clock.name, priority.driver) :
  <https://docs.pipewire.org/page_man_pipewire-props_7.html>
- PipeWire combine-stream :
  <https://docs.pipewire.org/page_module_combine_stream.html>
- PipeWire loopback :
  <https://docs.pipewire.org/page_module_loopback.html>
- Apple Audio MIDI Setup — aggregate device :
  <https://support.apple.com/guide/audio-midi-setup/combine-audio-devices-into-a-single-aggregate-device-ams6e21c3f61/mac>
- Apple Audio MIDI Setup — aggregate settings / drift correction :
  <https://support.apple.com/guide/audio-midi-setup/set-aggregate-device-settings-ams094c7edb4/mac>
- `open-apollo` : <https://github.com/rolotrealanis98/open-apollo>
- `inferno` : <https://github.com/teodly/inferno>
- `douze` : <https://github.com/xenicle/douze>
- `MixiD` : <https://github.com/TheOnlyJoey/MixiD>
- `alsa-scarlett-gui` : <https://github.com/geoffreybennett/alsa-scarlett-gui>
- `Openface Mixer` : <https://github.com/thomas-nelson23/Openface-Mixer>
- `rme-ucx2-linux` : <https://github.com/yonie/rme-ucx2-linux>
- `oscmix` : <https://github.com/michaelforney/oscmix>
- `motu-pci-424` : <https://github.com/devfrp/Linux-motu-pci-424>
- `tascam-gtk` : <https://github.com/onkelDead/tascam-gtk>
- FFADO : <https://ffado.org/>
- `snd-firewire-ctl-services` :
  <https://github.com/alsa-project/snd-firewire-ctl-services>
- `network-audio-controller` :
  <https://github.com/chris-ritsen/network-audio-controller>
- `aes67-linux-daemon` : <https://github.com/bondagit/aes67-linux-daemon>
- Merging RAVENNA / VAD : <https://www.merging.com/support/downloads>
- AudioScience Linux drivers :
  <https://www.audioscience.com/internet/download/linux_drivers.htm>
- Digigram VX222e support : <https://www.digigram.com/support/discontinued-products/discontinued-sound-cards/vx222e-support/>
- Focusrite Linux compatibility (officiel, limité) :
  <https://support.focusrite.com/hc/en-gb/articles/208530735-Is-my-Focusrite-Product-compatible-with-Linux>
- MOTU other platforms / CueMix 5 Linux :
  <https://motu.com/en-us/other-platforms/>

---

## 12. Notes de licence et de prudence

- `open-apollo` : GPL-2.0 ; ne redistribue pas les fichiers Universal Audio ;
  lit l'installation UAD de l'utilisateur.
- `inferno` : GPL-3.0-or-later ou AGPL-3.0 ; Dante utilise des technologies
  brevetées par Audinate ; l'auteur recommande de consulter un avocat pour un
  usage commercial ou une distribution de binaires.
- `douze` : code AGPL-3.0, protocole CC0 ; le protocole est volontairement
  libéré pour finir dans un driver kernel ou un autre outil.
- `MixiD` : MIT.
- `alsa-scarlett-gui` : GPL-3.0.
- `Openface Mixer` : MIT.
- Les captures USB et les protocoles doivent être traités comme des faits
  d'interopérabilité ; ne jamais envoyer de trames inventées à un firmware.
