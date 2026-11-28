# Test plan — Aggregate devices, drift correction & live-fence chain

**Objet précis :** valider la fonctionnalité « Aggregate devices » de Mixbay
(agrégation de cartes + correction de dérive), **et ses interactions** avec
Live Mode, `pipewire-settings`, Levels Guard, le patchbay Mixbay/qpwgraph, la
fondation audio et le hot-plug USB.

Ce plan complète `TESTING.md` (qui reste la checklist générale). Il concerne
uniquement les fichiers suivants :

- `code/modules/mosquito/audio-stack/mixbay/tui-go/aggregate/`
- `.../mixbay/tui-go/aggregate_ui.go`, `.../cli.go` (`aggregate-*`),
  `.../patchbay/graph.go` (garde `agg_*`)
- `.../mixbay/foundation/{audio-foundation.sh,mixbay-aggregate-guard}`
- `.../mixbay/setup-mosquitomixbay.sh`
- `.../live-mode/{live-mode,tui-go/settings.go,tui-go/model.go}`
- `.../pipewire/{pipewire-settings,omarchy-plugins/mosquito.pipewire/Panel.qml}`

Dernière révision : 2026-11-27. Cases à cocher au fur et à mesure ; noter la
date et la machine dans chaque section qui demande du matériel.

---

## 0. Prérequis, sauvegarde et rollback

Matériel :

- au moins **deux interfaces USB audio** avec des horloges différentes (ex. EVO 8
  + UGM192) ; une **paire word-clockée** si disponible pour le cas « sync
  matérielle » ;
- un micro branché sur chaque carte pour le test d'entrée ;
- `qpwgraph` pour le test de suppression de liens ;
- `pw-cli`, `pw-dump`, `pw-mon`, `pw-metadata`, `jq` présents (`command -v …`).

Avant toute manipulation :

```bash
mkdir -p /tmp/opencode/aggregate-tests
cp -a "${XDG_CONFIG_HOME:-$HOME/.config}/mosquitomixbay" /tmp/opencode/aggregate-tests/mixbay-config.bak
cp -a "${XDG_CONFIG_HOME:-$HOME/.config}/live-mode" /tmp/opencode/aggregate-tests/live-mode.bak
cp -a "${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d" /tmp/opencode/aggregate-tests/pipewire-conf.bak
cp -a "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" /tmp/opencode/aggregate-tests/systemd-user.bak
```

Commandes de sortie de crise (à connaître avant de commencer) :

```bash
mosquito-mixbay-actions aggregate-deactivate
systemctl --user stop mixbay-aggregate-guard.service mixbay-aggregate.service
live-mode off
systemctl --user restart pipewire pipewire-pulse wireplumber
```

Un agrégat **actif** coupe toutes ses cartes membres si on le désactive en
pleine session : ne jamais le faire pendant un test live sans prévenir.

---

## 1. Vérifications statiques (avant de toucher au graphe)

- [ ] `cd code/modules/mosquito/audio-stack/mixbay/tui-go && go test ./...`
      → tous les tests passent, y compris `aggregate/`, `patchbay/` et
      `TestAggregateRowIsProminent`.
- [ ] `cd ../live-mode/tui-go && go test ./...` → `TestAggregateLockRoundTrip`
      et `TestAggregateLockDefaultsOnAndRowNeedsMixbay` passent.
- [ ] `bash tests/mixbay-aggregate-test.sh` → une seule ligne
      `aggregate-repair` dans le log du faux backend (garde `pw-mon`).
- [ ] `bash -n` sur `setup-mosquitomixbay.sh`, `audio-foundation.sh`,
      `mixbay-aggregate-guard`, `live-mode`, `pipewire-settings`.
- [ ] `qmllint .../mosquito.pipewire/Panel.qml` → aucune erreur.
- [ ] `mosquito-mixbay-actions aggregate-status-json` renvoie un JSON valide
      avec `"state": "inactive"` et `"locked": false` sur une machine propre.
- [ ] `mosquito-mixbay-actions aggregate-list` renvoie `[]`.
- [ ] `mosquito-mixbay-actions --help` liste les actions `aggregate-*`.

---

## 2. Installation, services et désinstallation

- [ ] Lancer `./setup-mosquitomixbay.sh` (ou `--update` selon le module).
      Vérifier `~/.local/bin/mixbay-aggregate-guard` exécutable.
- [ ] `systemctl --user status mixbay-aggregate.service
      mixbay-aggregate-guard.service` → tous deux `enabled` ; avec aucun
      `active.json`, ils sont **inertes** (`ConditionPathExists` non rempli),
      et le guard ne consomme pas de CPU.
- [ ] `journalctl --user -u mixbay-aggregate-guard -n 20` → aucune boucle de
      redémarrage (`Restart=on-failure` ne doit pas tourner en continu).
- [ ] `mixbay_status` continue de répondre `ok` et ne signale pas l'agrégat
      comme manquant quand aucun n'est configuré.
- [ ] **Désinstallation** : avec un agrégat actif, lancer
      `./setup-mosquitomixbay.sh --uninstall`. Vérifier : module déchargé
      (`pw-dump | grep agg_` vide), unités supprimées, binaire guard supprimé,
      et **aucune erreur** liée au lock même si un live était actif.
- [ ] Restaurer depuis la sauvegarde de §0 puis relancer le setup avant de
      continuer.

---

## 3. Création et activation (premier cas, sorties seules)

Procédure TUI : `mosquito-mixbay` → **Devices → Aggregate devices**.

- [ ] La ligne s'appelle exactement `Aggregate devices` (pas « PipeWire
      patchbay ») et n'est **pas grisée** quand `pw-cli`/`pw-dump` existent.
- [ ] Simuler l'absence de `pw-cli` (`PATH` sans lui) : la ligne devient
      grisée avec `(needs pw-cli and pw-dump)`, et `n` affiche un toast au lieu
      d'ouvrir le sélecteur. Rétablir le `PATH`.
- [ ] `n` → le sélecteur liste les `Audio/Sink` **et** les sinks virtuels
      Mixbay (`evo8_main_output`, `ssl12.pb12`), mais **aucun** `agg_*` ni
      `:monitor`.
- [ ] Cocher deux cartes avec `space` (`[x]` visible), `n`, saisir
      `Studio Pair`, confirmer. Vérifier
      `~/.config/mosquitomixbay/aggregate/studio-pair.json` :
      - `name: "Studio Pair"`, `display_name`, `schema_version: 1` ;
      - `outputs[].drift == true`, `quality == 4` ;
      - `outputs[].profile`, `card`, `device` renseignés quand le graphe les
        expose (EVO) ;
      - `fingerprint` contient `node|class|canaux` triés.
- [ ] Refus attendus : nom vide, nom avec `/`, nom `agg_...`,
      même nœud coché deux fois, nœud inconnu. Aucun fichier créé.
- [ ] `aggregate-save studio --node <sink1> --node <sink2> --display Studio`
      produit le même résultat ; un second `aggregate-save studio` sans
      `--overwrite` échoue.
- [ ] `a` (ou `aggregate-activate studio`) → toast « choose the new output in
      the audio panel ». Vérifier dans le graphe :

      ```bash
      pw-dump | jq -r '.[] | select(.type=="PipeWire:Interface:Node") | .info.props["node.name"]' | grep '^agg_'
      ```

      → `agg_studio_pair` présent, aucun ID brut stocké dans le preset.
- [ ] `aggregate-status-json` → `"state": "active"`, `"active": "Studio
      Pair"`, `"links_ok": true`, `"members"` non vide, `"rate"` cohérent avec
      `pw-metadata -n settings 0`.
- [ ] Le panneau audio Omarchy liste `Studio` comme sortie. La sélectionner,
      lire un ton test (`pw-play` ou DAW) et confirmer **son sur les deux cartes**.
- [ ] `pw-dump` montre les liens du sink `agg_studio_pair` vers les deux
      sinks matériels ; le preset patchbay n'a pas été modifié.
- [ ] `a` de nouveau (ou `aggregate-deactivate`) → nœud `agg_*` disparu,
      `active.json` supprimé, `aggregate-status-json` repasse `inactive`, et
      le son revient sur la sortie choisie avant l'activation.

---

## 4. Persistance et redémarrage du graphe

- [ ] Réactiver l'agrégat, puis `systemctl --user restart
      mixbay-aggregate.service`. Le sink `agg_*` est recréé une seule fois
      (pas de doublon) et `aggregate-status-json` reste `active`.
- [ ] Redémarrer PipeWire (`systemctl --user restart pipewire
      pipewire-pulse wireplumber`) : le service recharge la recette au
      redémarrage de la session. Si l'ID de module stocké devient invalide,
      `aggregate-status-json` doit passer `degraded`, jamais afficher `active`
      avec un nœud manquant.
- [ ] `pw-dump | grep -c 'agg_studio_pair'` reste stable après deux
      redémarrages successifs (pas de modules empilés).
- [ ] Couper une carte membre, redémarrer le service : la recette est refusée
      proprement (`interfaces changed`) et un message lisible s'affiche ;
      aucun câblage partiel n'est créé.

---

## 5. Agrégation d'entrées et boucles de feedback

- [ ] Créer un agrégat avec `--input-node <source1> --input-node <source2>`.
      Vérifier `agg_<slug>_in` dans `pw-dump`, avec `media.class=Audio/Source`.
- [ ] Enregistrer depuis les deux micros via le panneau audio / `pw-record` :
      les deux voix arrivent dans la source virtuelle.
- [ ] Tenter d'ajouter `agg_studio_pair:monitor` comme membre d'entrée :
      refus immédiat (`an aggregate cannot contain …`). Vérifier qu'aucun
      lien ne crée de feedback visible dans `qpwgraph`.
- [ ] Tenter d'ajouter un autre `agg_*` comme membre : refus idem.
- [ ] Désactiver : sink **et** source `agg_*` disparaissent ensemble.

---

## 6. Patchbay Mixbay : garde `agg_*`

- [ ] Avec l'agrégat actif, sauvegarder un preset de liens bruts
      (`patchbay-save studio-links`) puis l'appliquer avec `--replace`.
- [ ] Vérifier que les liens `agg_studio_pair → <sink matériel>` sont
      **toujours présents** après `--replace`, et que
      `patchbay-status-json` continue de marquer le preset `applies: true`.
- [ ] `patchbay-save` après activation ne doit pas inclure les liens `agg_*`
      dans son `fingerprint`. Comparer le JSON avant/après.
- [ ] Si un lien `agg_*` est supprimé à la main, `patchbay-apply --replace`
      ne doit pas le « réparer » (ce n'est pas son rôle) : c'est le test §7.

---

## 7. qpwgraph, guard `pw-mon` et réparation

- [ ] Ouvrir `qpwgraph`, supprimer **un seul** lien partant de
      `agg_studio_pair`. `aggregate-status-json` doit passer
      `"links_ok": false`, `"state": "degraded"`, raison « a link was removed ».
- [ ] Sans rien faire d'autre, le lien doit revenir en **2–5 s** (guard
      `pw-mon`). Revérifier `links_ok: true` et l'absence de coupure durable
      (le son reprend tout seul).
- [ ] Couper le guard (`systemctl --user stop mixbay-aggregate-guard`),
      supprimer un lien, lancer `mosquito-mixbay-actions aggregate-repair` :
      `{"added":1}` ; le lien revient ; aucun lien non-agrégat n'est touché.
- [ ] `p` dans la TUI ouvre la confirmation et affiche le même résultat.
- [ ] Désactiver l'agrégat, supprimer des liens matériels avec qpwgraph :
      le guard **ne doit rien reconnecter** (pas d'agrégat actif = aucun
      effet, `aggregate-repair` est un no-op).
- [ ] `journalctl --user -u mixbay-aggregate-guard` ne montre pas de boucle
      de réparations infinie quand qpwgraph est ouvert (debounce 2 s).

---

## 8. Live Mode : chaîne de verrouillage

### 8.1 Réglage et activation

- [ ] Live Manager → ligne `Lock aggregate devices during live mode: on`
      par défaut ; `←/→` puis Enregistrer écrit `AGGREGATE_LOCK="no"` dans
      `~/.config/live-mode/settings` ; le redémarrage du manager relit `off`.
- [ ] Simuler Mixbay absent (`PATH` sans `mosquito-mixbay-actions`) : la ligne
      est grisée avec `(needs mixbay)` et reste figée sur sa valeur.
- [ ] Avec `AGGREGATE_LOCK=yes`, la carte d'activation affiche
      `Aggregate devices locked` en plus de `Mixbay output volume locked`.
- [ ] `live-mode on` → `~/.config/mosquitomixbay/aggregate/lock` existe ;
      `aggregate-status-json` montre `"locked": true`.
- [ ] Les actions suivantes sont **refusées** (UI et CLI) avec le message
      « locked by Live Mode » : `aggregate-save`, `aggregate-activate`,
      `aggregate-deactivate`, `aggregate-delete`, `p` (réparation manuelle).
      Aucun fichier ni module n'est modifié.
- [ ] La recette active avant le live est toujours active pendant le live.

### 8.2 Déverrouillage session et sortie

- [ ] `A` dans l'écran Aggregate → confirmation →
      `~/.config/mosquitomixbay/aggregate/unlocked` créé ; la ligne redevient
      sélectionnable, les actions réussissent.
- [ ] `A` de nouveau → re-verrouillage immédiat (le fichier `unlocked`
      disparaît), sans toucher à `lock`.
- [ ] modifier la recette pendant le déverrouillage (ex. activer une autre
      recette), puis `live-mode off` :
  - [ ] `lock` **et** `unlocked` sont supprimés ;
  - [ ] la recette modifiée **reste** active (pas de restauration auto) ;
  - [ ] le journal affiche « aggregate devices unfrozen ».
- [ ] Crasher une session (`kill -9` du processus live-mode) puis
      `live-mode off` : le lock est quand même nettoyé (chemin `is_active`
      « already off »).
- [ ] `AGGREGATE_LOCK=no` : `live-mode on` ne crée pas de lock ; les actions
      restent possibles pendant le live (comportement attendu, mais risque
      assumé par l'utilisateur).

### 8.3 Patchbay dans le live

- [ ] Avec un agrégat actif, `live-mode on` ouvre bien mixbay + qpwgraph
      dans le scratchpad ; après l'ouverture, `repair_aggregate` a tourné
      (`aggregate-status-json` → `links_ok: true`).
- [ ] Supprimer un lien pendant le live : le guard le restaure **malgré le
      lock** (le lock protège la création/suppression de recettes, pas la
      réparation d'une recette déjà active). Le documenter comme tel.

---

## 9. `pipewire-settings` et panneau associé

- [ ] Avec un agrégat actif **hors live**, `pipewire-settings show` renvoie
      `"aggregate_active": true`, `"aggregate_locked": true`, et
      `"aggregate": "Studio Pair"`.
- [ ] Le panneau affiche les deux valeurs grisées et la légende
      `Locked by aggregate Studio Pair · L unlock`; Force/Remember sont
      masqués.
- [ ] `L` → confirmation avec le texte sur la dérive des membres →
      « Unlock » restaure les flèches ; `L` reverrouille sans confirmation.
- [ ] Tant que le verrou est posé, `pipewire-settings set-rate 96000` échoue
      avec « an aggregate device is active — unlock it first », même appelé
      depuis un terminal (le backend, pas seulement le QML).
- [ ] Après déverrouillage `L`, `set-rate` réussit ; tous les membres
      suivent le nouveau taux ou l'état `degraded` est visible (pas de
      silence muet).
- [ ] `live-on` / `live-off` restent fonctionnels avec un agrégat actif :
      aucun blocage, valeurs forcées puis restaurées normalement.
- [ ] Sans agrégat, le comportement historique (live + Move uniquement)
      est inchangé.

---

## 10. Fondation audio, carte par défaut et Levels Guard

- [ ] Choisir une carte physique comme défaut
      (`mixbay-audio-foundation --set-default evo8`), activer l'agrégat,
      puis `systemctl --user restart mixbay-audio-defaults.service`.
      Le sink par défaut **reste** `agg_studio_pair` (le script voit
      `active.json` et sort immédiatement).
- [ ] Désactiver l'agrégat, redémarrer le service de défaut : la carte
      physique redevient le sink par défaut.
- [ ] Sans Levels Guard installé, créer et activer un agrégat : aucune
      ligne n'est grisée pour cause de garde absent (seule la ligne de
      volume natif reste figée sur *free*, comportement historique).
- [ ] Avec Levels Guard installé et l'agrégat sélectionné, les touches
      volume pilotent le **volume logiciel** de l'agrégat (OSD normal) et
      pas le hardware des cartes membres. En live avec
      `LOCK_OUTPUT_VOLUME=yes`, les cartes membres restent verrouillées
      (comportement Levels Guard inchangé).
- [ ] Vérifier qu'aucun `clock.name`, `priority.driver` ou
      `default.clock.rate` global n'a été écrit par l'agrégat
      (`pw-metadata -n settings 0` avant/après identique, hors action
      explicite de l'utilisateur dans pipewire-settings).

---

## 11. Hot-plug, renommage de nœud et dérive

- [ ] **Déconnexion à chaud d'un membre pendant la lecture** : le son des
      autres membres continue ; `aggregate-status-json` passe `degraded`
      avec `missing`/`links_ok` cohérent ; aucune panique, aucun crash de la
      TUI ni du guard.
- [ ] Rebrancher la carte : l'agrégat **ne se réactive pas tout seul**
      (comportement voulu). `a` (désactiver puis réactiver) restaure ;
      vérifier que le sélecteur multi-clés retrouve la carte malgré un
      éventuel changement de suffixe de nom.
- [ ] Changer le profil ALSA d'une carte (ex. `--split on|off` EVO 4 ou
      `wpctl set-profile`) pour modifier `device.profile.name` /
      `node.name` : la recette sauvegardée est refusée à l'apply avec
      « interfaces changed » ; après re-sauvegarde, l'activation fonctionne.
- [ ] **Deux cartes USB non synchronisées** : lire un ton pendant 10 min,
      vérifier l'absence de clics et de dérive audible ; noter le taux et
      `resampling N/N` affichés dans l'UI.
- [ ] **Paire word-clockée** (si dispo) : positionner `"drift": false`
      dans le JSON de la recette pour les membres qui partagent
      `clock.name`, activer, vérifier que le flux reste stable et que
      l'UI n'affiche pas « resampling » pour ces membres.
- [ ] Ne jamais conclure à du bit-perfect quand le resampling est actif.

---

## 12. Cas négatifs et limites connues

- [ ] Deux agrégats actifs : le second `aggregate-activate` est refusé
      (« an aggregate is already active »), aucun module orphelin.
- [ ] Preset JSON corrompu : `aggregate-status-json` et `aggregate-list`
      renvoient une erreur lisible, pas un crash ; la TUI affiche
      « Error: … » et reste utilisable.
- [ ] `active.json` pointant une recette supprimée : état `degraded` avec
      raison, `aggregate-deactivate` nettoie quand même les modules.
- [ ] IDs de modules périmés dans `$XDG_RUNTIME_DIR/mixbay-aggregate.json`
      après redémarrage de PipeWire : `unload-module` sur un ID invalide
      ne bloque pas la désactivation.
- [ ] `pw-mon` absent : le guard sort proprement (exit 0), aucun redémarrage
      en boucle ; l'agrégat reste activable et `aggregate-repair` manuel
      fonctionne.
- [ ] Aucune mesure ppm/xruns n'est promise par l'UI : si elle en affiche,
      c'est une régression à corriger.
- [ ] `aggregate-repair` sans agrégat actif → `{"added":0}`, aucun effet.

---

## 13. Sign-off

- [ ] Sections 1–12 exécutées, date + machine notées.
- [ ] `journalctl --user -u mixbay-aggregate -u mixbay-aggregate-guard`
      sans erreurs persistantes.
- [ ] Aucun `agg_*` résiduel après le dernier `aggregate-deactivate`.
- [ ] Sauvegarde de §0 restaurée **uniquement** si le test devait laisser
      la machine dans son état d'origine ; sinon documenter l'état final
      (recettes créées, réglages Live Mode modifiés).
