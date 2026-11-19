# Mixbay — revue d'architecture complète

Date : 2026-11-19. Périmètre : tout le module
`code/modules/mosquito/audio-stack/mixbay` — 15 749 lignes de Go (5 paquets),
~3 000 lignes de shell, 1 000 lignes de Python (harness), plus la documentation
et le schéma de cartes.

Méthode : lecture du code source, pas d'exécution d'install/désinstall (donc
aucune affirmation matérielle). Les points marqués **vérifié** ont été relus
ligne à ligne après le premier passage.

---

## 1. Verdict

L'architecture est **saine sur le cœur** et **en désordre sur les bords**.

Le cœur — schéma de cartes déclaratif, `Driver`/`Spec`/`Caps`, politique
demo/live, pause du moteur de rendu en blocs — est cohérent, testé et
correctement orienté (aucun cycle de dépendance). C'est de la bonne
architecture, et elle absorbe bien la diversité des interfaces.

Les bords — installation, désinstallation, statut, détection de présence,
onboarding, état partagé — sont dupliqués 2 à 6 fois, avec des règles
contradictoires. C'est là que se trouvent les bugs réels, dont deux graves.

Résumé chiffré :

| Constat | Mesure |
|---|---|
| Paquets Go, dépendances acycliques | 5, propres |
| Tests Go | 209 fonctions, 18 fichiers, 5 paquets, tous verts |
| Tests Python (harness) | 11, sans matériel |
| Implémentations distinctes de « l'interface est branchée » | 6 |
| Implémentations distinctes de « le profil est installé » | 2 (Go et shell) |
| Implémentations distinctes du statut de santé Mixbay | 4, dont 3 se contredisent |
| Sources de vérité pour un même fichier d'état | jusqu'à 3 écrivains |
| Bugs bloquants trouvés | 2 |

---

## 2. Carte des couches

```
                    ┌──────────────────────────────┐
   shell / systemd  │ mosquitomixbay (dispatcher)  │
                    │ mosquito-mixbay-actions      │
                    │ startup/mixbay-startup       │
                    │ watcher/{card-watcher,move}  │
                    │ compat/interface-onboarding  │
                    │ foundation/audio-foundation  │
                    └───────────────┬──────────────┘
                                    │ exec CLI (argv, pas de shell)
                    ┌───────────────▼──────────────┐
                    │ tui-go main (9 922 l.)       │  TUI + CLI + politique session
                    └───┬─────────┬────────┬───────┘
                        │         │        │
             ┌──────────▼──┐ ┌────▼────┐ ┌─▼─────────┐
             │ drivers     │ │ meters  │ │ patchbay  │
             │ 2 973 l.    │ │ 370 l.  │ │ 494 l.    │
             └──────┬──────┘ └─────────┘ └───────────┘
                    │
             ┌──────▼──────┐
             │ profiles    │  schéma, validation, store, fetch
             │ 1 990 l.    │
             └─────────────┘

   Python : harness/mixbay-reverse.py (usbmon, capture, replay) — outil à part
```

Dépendances : `main → {drivers, meters, patchbay, profiles}`,
`drivers → profiles`, tout le reste → stdlib. **Pas de cycle.** C'est le point
le plus solide du module, et il est documenté (`profiles/spec.go:1-8` interdit
à `profiles` d'importer `drivers`).

### 2.1 Le cœur : ce qui est bien fait et ne doit pas être cassé

- **Une carte est une donnée.** Schéma strict, clés inconnues refusées
  (`profiles/spec.go:404-467`), validation par identifiant, `caps` comme
  contrat de capacités, `hardware.meters` comme liaison déclarative.
- **`Driver` + interfaces optionnelles** (`OutputChannelDriver`,
  `MixerMuteDriver`, `LiveReader`) : chaque interface n'expose que ce qu'elle
  sait faire, et le rendu s'y adapte.
- **La politique demo/live est un vrai invariant** : une charge demo ne peut
  jamais rétrograder une session live, et une interface qui disparaît gèle les
  valeurs (`session.go:30-62`). Rare et précieux.
- **Composition du rendu par `ui.blocks`** : les cartes choisissent leurs
  pages, pas le code.
- **Écritures atomiques** pour les cartes, métadonnées, presets patchbay,
  intégrations (`profiles/store.go:453-479`).
- **Vérification sha256** de chaque fichier téléchargé, liste blanche d'hôtes
  pour les cartes upstream, refus des `..` et des identifiants invalides.

---

## 3. Défauts bloquants

### P0-1 — `--uninstall` est cassé et destructeur **vérifié**

`setup-mosquitomixbay.sh:81` : `local integ=…` est **hors de toute fonction**,
dans un script en `set -euo pipefail` (ligne 30). Bash s'arrête donc là avec
`local: can only be used in a function` et code 1.

Tout ce qui précède a déjà tourné — dont
`foundation/audio-foundation.sh --remove` (ligne 78-79), qui **efface
`foundation.json`, le fichier udev, et `/usr/share/omarchy-platform/audio.json`**.
Tout ce qui suit ne tourne jamais : binaires, unité systemd du watcher, bloc
Hyprland, règle de capture EVO 8.

Résultat net d'une désinstallation : la fondation audio est démontée et
Mixbay est toujours installé. Les appelants masquent l'échec
(`setup-audio-stack.sh:95`, `mosquitomarchy-setup.sh --uninstall`).

### P0-2 — `/usr/share/omarchy-platform/audio.json` est écrasé puis supprimé sans sauvegarde **vérifié**

`foundation/audio-foundation.sh:688` fait `mq_sudo install -D` sur un fichier
de la plateforme Omarchy, et `:1203-1206` le `rm` sans condition. Aucun
`backup_file()` (qui existe et est utilisé pour PipeWire/WirePlumber), aucune
vérification de propriétaire, aucun refus si le fichier ne vient pas de
Mixbay. `remove_all` efface donc un fichier système que Mixbay n'a pas créé.

---

## 4. Défauts de premier rang

### P1-1 — `--needs` retourne le statut inversé **vérifié**

`foundation/audio-foundation.sh:1248` : `return $(( miss == 0 ))` alors que
`miss = 1` signifie « il manque quelque chose ». La commande sort donc **0
quand il manque des étapes** et **1 quand tout est prêt** — l'inverse de
`mosquito-mixbay-compat --needs` (`compat:249`) et de tous les autres modes.

Ça ne casse rien aujourd'hui uniquement parce que le seul appelant ignore le
code de retour (`compat:87`, `|| true`). Le prochain `if ! mixbay-audio-foundation --needs …`
sera faux.

### P1-2 — Trois contrats de santé qui se contredisent **vérifié**

| Source | Règle |
|---|---|
| `setup-mosquitomixbay.sh:49-71` | binaires + règle Hyprland + `50-mixbay-interfaces.conf` |
| `mosquitomarchy-setup.sh:996-1007` | mêmes binaires + règle Hyprland + `50-mixbay-interfaces.conf`, **kmod ignoré** |
| `foundation/audio-foundation.sh:489-596` | état par carte, nœuds PipeWire, services |
| TUI `foundation_ui.go:37-49` | lit le shell précédent |

Or une installation propre **n'applique pas** la fondation
(`setup-mosquitomixbay.sh:295-307`, délibéré). Donc
`mosquitomarchy-setup.sh --status` affiche `partial:missing audio foundation`
sur une installation correcte. Un utilisateur et un script ne peuvent faire
confiance à aucune des réponses.

### P1-3 — `MIXBAY_CONFIG_DIR` n'est honoré qu'à moitié **vérifié**

Seul `profiles.ConfigDir` (`store.go:41-48`) lit la variable. Restent câblés
sur `$HOME` : `drivers/alsa.go:121,346,357`, `drivers/connections.go:23`,
`patchbay/preset.go:27`, `model.go:362-365`, et la désinstallation
`library_ui.go:194` (variable) contre `:197` (`$HOME` en dur) — les deux dans
la même fonction. Toute installation ou tout test non standard écrit dans deux
racines.

### P1-4 — Le harness et la TUI ne parlent pas le même langage

- La TUI passe `--match <alsa.card_name>` (`betaui.go:60-64,277`) ;
  `mixbay-reverse.py:201-208` compare ce motif aux champs **USB**
  (product/manufacturer/serial). Toute carte dont le nom ALSA n'est pas un
  sous-mot du nom USB meurt en `:209-210`.
- Le guidage déduit 1..16 entrées/sorties de `sample_specification`
  (`:243-245,312-319`), tandis que la carte bêta créée déclare 2 entrées /
  1 paire de sorties et `caps {volume,mute}` (`profiles/store.go:388-393`).
  Le wizard propose donc des contrôles que le driver ne saura jamais piloter.
- `propose` (TODO-PROFILES §2) n'existe pas.

### P1-5 — Le déploiement n'est pas autonome

`setup-mosquitomixbay.sh:134,146` cuit le chemin du checkout dans
`mosquito-mixbay-compat` et `mixbay-audio-foundation`. Supprimer ou déplacer
le checkout casse les helpers déployés, l'unité systemd du split
(`foundation:748-749`) et tous les chemins qui rappellent le dépôt
(`compat:162,179`). « Installé » ne veut pas dire « installé ».

### P1-6 — Le bloc Hyprland est écrit avec un `sed` non protégé

`setup-mosquitomixbay.sh:270-279` supprime une plage `sed` puis réajoute.
Or `code/lib/hypr-tui.sh:36-38` existe précisément pour ça et documente que
« ce dépôt a déjà été mordu par des plages sed qui courent jusqu'à EOF ».
Un marqueur de fin malformé efface la fin de `hyprland.lua`.

### P1-7 — La racine de confiance est dégradable en HTTP

`profiles/fetch.go:98-111` (`SetRepoURL`) accepte `http://`, et c'est exposé
en CLI (`profiles_cli.go:209-221`). Les octets sont bien vérifiés en sha256,
mais **contre le même index** : un intermédiaire qui sert index + fichiers de
façon cohérente passe. Ces fichiers sont ensuite des `.sh`/`.py` exécutés
avec les privilèges de l'utilisateur, prompts sudo compris
(`setup_ui.go:38`, `library_ui.go:216`, `:144`). L'intention est déjà là
(`ValidUpstreamURL` épingle l'hôte) ; il manque le `https` obligatoire.

### P1-8 — Les presets EVO s'appliquent avant d'être validés, et ne sont pas atomiques

`drivers/evo.go:1439-1542` : `LoadFrom` applique sorties puis entrées puis
monitor, **puis** valide le bloc mixer (`SetMixerKey` échoue en `:1587-1602`).
Un preset édité à la main laisse donc l'interface à moitié restaurée. Les
écritures de snapshot/shadow (`evo.go:1307-1309,1363-1365`) utilisent
`os.WriteFile`, pas l'helper atomique — c'est le fichier le plus précieux du
chemin EVO qui est le moins protégé.

---

## 5. Duplication : un concept, plusieurs vérités

| Concept | Implémentations | Vérité proposée |
|---|---|---|
| « interface branchée » | foundation `evo_present`/`native_online`/`alsa_card_present` (`361-443`), compat `usb_present` (`45-66`), Go `drivers/evo.go:191-210`, Go `drivers/alsa.go:76-108`, watcher `152-156`, move-audio `59-76` | une seule sonde, exposée par `spec.Probe()` |
| « profil installé » | shell `state_installed`/`native_installed` (`197-200,465-473`), Go `profiles.Effective/Installed` | le store Go ; le shell ne fait que lire |
| nom → identifiant | `foundation:66-75,258-270`, `fetch.go:575-638`, `profiles_cli.go:313-338`, `duplicates.go:19-55`, harness `:526-532` | `profiles.Match()`, 1 fonction |
| statut de santé | 4 surfaces (§P1-2) | `setup-mosquitomixbay.sh --status` seul, délégation depuis les autres |
| « il manque quoi » | `foundation:1213-1249` vs `compat:74-125` — et **contenus différents** (compat ajoute la règle de capture absente côté foundation) | `--needs` unique |
| UI par défaut | `startup:280-306` vs `ui_openers.go:15-19,44-89` — le shell peut ouvrir une UI Qt que la page Controls cache | `ui_openers.go` |
| « Mixbay est ouvert » | dispatcher `pgrep -f` (`:25-37`), watcher `:47-54`, pidfiles Go | un seul pidfile, un seul helper |
| lecture de débit | `move-audio:125-138` vs `foundation:413-423` | une fonction |
| carte par défaut | `startup:311-319`, `foundation:1260-1270`, service généré `:846-901` | `--set-default` |
| noms de nœuds PipeWire | `foundation:846-901` (en dur) vs `profiles/cards/*.json` (`spec.foundation`) | les données |
| liste « cartes natives » | `betaui.go:104-116` (chaînes Go) vs le store de profils | le store |
| règles PipeWire split | `foundation:9-24,744-800`, `README:489-527`, `compat:22-24`, cartes JSON | la carte |

**Conséquence de fond :** `betaui.go:104-116` contredit l'affirmation
« une carte est une donnée » (`profiles/spec.go:1-8`). Ajouter une interface
native demande de modifier du Go, alors que le store de profils est justement
conçu pour l'éviter.

---

## 6. Propriété des fichiers d'état

| Chemin | Écrivains | Lecteurs | Verdict |
|---|---|---|---|
| `~/.config/mosquitomixbay/cards/<id>/…` | `profiles/store.go` | foundation, compat, startup | **conflit** : `library_ui.go:194` `rm -rf` ce que `profiles` possède |
| `connected-interfaces.json` | foundation `:312,342`, `library_ui.go:197-201` (jq) | `drivers/connections.go`, `profiles_cli.go:341` | **3 écrivains** |
| `ui.json` | `model.go:413-421` (non atomique) | startup, watcher, levels-guard | un écrivain, écriture risquée |
| `foundation.json` | foundation | setup, TUI | propre (sauf `state_init:193-195` qui réécrit tout en cas de forme inattendue) |
| `~/.config/audient-evo-py/<id>/…` | `drivers/evo.go` | **et** `evo_tui.go:1387-1409` (scan, delete, rename) | **conflit** |
| `move-audio-state` | `move-audio`, watcher (append) | watcher, move-audio, `store.go:530` (delete) | **3 écrivains, aucun verrou** |
| `90-mosquitomarchy-pipewire.conf` | module pipewire-settings | foundation `:600` (garde « ne pas toucher ») | **règles opposées** : `move-audio:173-178` le déplace |
| `99-evo8-capture.rules` + helper | foundation `:730-733` | compat `:80` | supprimé par `setup:102-106`, **jamais** par `remove_all` |
| `/usr/share/omarchy-platform/audio.json` | foundation `:688` | panneau Omarchy | **P0-2** |
| `mosquito-mixbay.pid` / `mosquito-mixbay-tui.pid` | dispatcher / Go | watcher / startup | deux pidfiles, un seul supprimé à la désinstallation |

Règle manquante, et c'est la plus rentable à poser : **un chemin, un paquet
propriétaire, tous les autres passent par son API.**

---

## 7. Confiance et sécurité

Défenses réelles, à conserver : validation d'index avant usage, sha256 par
fichier, refus `..`/`/` partout (identifiants, presets, intégrations), limite
4 Mio et timeout 15 s, `exec.Command` en argv partout sauf deux `bash -c`
délibérés avec échappement correct (`setup_ui.go:34-37`), export de profil
qui caviarde les métadonnées de capture.

Risques restants, par ordre :

1. **HTTP accepté** (§P1-7).
2. **douze est une surface de contrôle locale non authentifiée**
   (`drivers/douze.go:32,119-168`) : `http://127.0.0.1:1212`, aucun jeton.
   Tout processus local peut changer gain/phantom ; `Probe()` n'est qu'un GET.
3. **Helpers résolus par `PATH`** dont certains avec sudo
   (`mixbay-audio-foundation`, `mixbay-startup`, `pactl`, `amixer`) —
   `foundation_ui.go:39`, `drivers/alsa.go:115`, `betaui.go:85`.
4. **La désinstallation shell est le chemin le moins vérifié** :
   `library_ui.go:183-217` fabrique un script `rm -rf` + `jq`, avec `set +e`
   (toutes les erreurs avalées) et `jq` optionnel.
5. `_meta.json` recalcule le sha256 sur la structure ré-encodée
   (`fetch.go:345-351`) : le champ ne veut plus dire « les octets vérifiés ».
6. Erreurs d'écriture ignorées dans les chemins de persistance
   (`alsa.go:149-156,345-349`, `evo.go:406-408,726-728,789-791,1307-1309`) :
   une sauvegarde ratée est rapportée comme réussie.

---

## 8. Idempotence et retour arrière

| Composant | Réappliquer | Sauvegarde | Suppression symétrique |
|---|---|---|---|
| setup (binaires) | oui, mais `cp` sur des scripts vivants (`:123,156,167,180,230`) et `bash -n` **après** remplacement | non | **non (P0-1)** |
| setup (Hyprland) | oui | n/a | oui, même `sed` fragile (§P1-6) |
| foundation `--apply` | oui (gardes, presets une seule fois) | confs/unités seulement | par carte oui ; `remove_all` oublie la capture (P1-2/P0-2) |
| startup | oui | n/a | oui (`--remove`) |
| compat | oui pour `record` ; `apply` relance **tout l'installeur** (`:179`) depuis le chemin de lancement de la TUI | `onboarding.json` | n/a |
| move-audio | oui (`switched()`) | déplace la conf PW | oui, mais écrase une écriture concurrente |
| watcher | oui | n/a | unité retirée par setup seulement |

Deux affirmations de doc sont fausses et doivent disparaître :
`foundation/README.md:41-43` (« setup applique la fondation, les deux surfaces
sont d'accord ») et `INTEGRATION.md:20-29` (extrait `st_mixbay` obsolète qui
régresse le statut s'il est copié).

---

## 9. Couverture de test

209 tests Go (18 fichiers) + 11 tests Python. Bonne couverture du modèle,
de la géométrie de rendu, du calcul EVO, de la validation de schéma, du store,
des téléchargements vérifiés.

Trous assumés, tous côté matériel/processus :

- transport ioctl EVO, `pactl` sink/trim, `amixer` réel, gestion du processus
  `pw-record`, `pw-dump`/`pw-link` en échec ;
- **zéro test** sur le driver douze ;
- script de désinstallation de la bibliothèque (`library_ui.go:183-217`) ;
- `patchbay.Apply` en échec partiel (aucun rollback : `preset.go:162-203`) ;
- `Engine.Start/Stop` des meters ;
- et les deux invariants qui auraient attrapé §P1-4 : « le motif passé au
  harness résout bien le périphérique » et « les étapes guidées ne dépassent
  jamais le `Spec` de la carte ».

Un seul marqueur de dette dans tout le Go (`profiles/fetch.go:438-439`), aucun
`TODO`/`FIXME` : les manques connus sont **non documentés**, pas absents.

---

## 10. Plan de remise en ordre

Par valeur/effort décroissant. Aucun de ces points ne demande une refonte.

1. **Corriger `--uninstall`** (`setup-mosquitomixbay.sh:81`) — 1 ligne. Faire
   d'abord la désinstallation, ensuite la fondation, ou au minimum déplacer
   `local` dans une fonction. Le reste du bloc est correct.
2. **Sauvegarder `/usr/share/omarchy-platform/audio.json`** avant écriture et
   ne le supprimer que s'il est le nôtre (marqueur). Utiliser `backup_file()`.
3. **Inverser `--needs`** (`foundation:1248`) : `return $(( miss == 0 ))`
   retourne 1 quand tout est prêt. Écrire `(( miss == 0 ))` (statut 0 = prêt)
   ou `return "$miss"`.
4. **Un seul statut** : `mosquitomarchy-setup.sh:st_mixbay` et la TUI délèguent
   à `setup-mosquitomixbay.sh --status` ; ce dernier devient l'unique contrat.
   Corriger `INTEGRATION.md` et `foundation/README.md` dans la foulée.
5. **Un helper de racine d'état** (`profiles.ConfigDir` exporté) utilisé par
   les 6 emplacements de §P1-3.
6. **`https` obligatoire** dans `SetRepoURL`, ou refus explicite avec message.
7. **Retirer le script shell de désinstallation** (`library_ui.go:183-217`) au
   profit de `profiles.Remove` + édition Go du journal de connexions. Supprime
   le `rm -rf`, le `jq`, le `set +e` et deux conflits de propriété d'un coup.
8. **Aligner le harness sur le schéma** : lui passer le nom USB (ou accepter
   les deux), dériver les étapes de `Spec` au lieu de `pactl`, et déplacer
   `propose` dans le validateur Go.
9. **Écritures atomiques EVO** + `LoadFrom` qui valide avant d'appliquer.
10. **Nommer les interfaces de preset** (`PresetDriver`, `ResetDriver`) dans
    `drivers/types.go` au lieu des assertions anonymes (`evo_tui.go:2906,2919,2933`,
    `cli.go:144`).
11. **Rollback de `patchbay.Apply`** : journaliser les liens retirés/ajoutés et
    revenir en arrière sur échec.
12. **Un seul scanner de cartes** : supprimer la liste « native » en dur
    (`betaui.go:104-116`) et lire le store.

Points volontairement hors périmètre : agrégats, Dante, Apollo, SSL 12 natif
complet, téléchargement des captures, signature de `index.json` — ce sont des
fonctionnalités, pas des défauts d'architecture, et ils sont déjà suivis dans
`TODO.md` / `TODO-PROFILES.md`.

---

## 11. Non vérifié

Aucune exécution d'installation, de désinstallation ni d'`--apply` ; aucun
matériel. Les affirmations EVO 8 (canaux 3/4, split), SSL 12 (meters absents),
UCM split-mono et l'ordre des services par défaut restent à valider sur
machine. Le rendu (`evo_tui.go`, `view.go`) n'a été relu que sur ses chemins
d'état et de touches, pas ligne à ligne. `docs/AUDIO-PROTOCOLS-LINUX.md`
(1 000 lignes) n'a été contrôlé que sur sa structure et les sections qui
dupliquent le code.
