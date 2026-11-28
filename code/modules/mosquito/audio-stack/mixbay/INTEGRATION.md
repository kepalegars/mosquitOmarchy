# Intégration mosquitOmarchy — mosquitomixbay

Patron suivi : même montage que `audio-plugin-manager` (dispatcher stable +
binaire Go sur tui-kit + bloc Hyprland marqué). Le module est **enregistré**
(`mixbay` : Setup › mosquito + entrée menu + slot patchbay de live mode,
défaut `PATCHBAY_APP=mixbay`). Sans hardware EVO le bay tourne en DEMO
persistant — le contrôle réel reste à valider sur EVO 8 quand le hardware
est là, mais l'intégration n'en dépend plus.

## 1. `mosquitomarchy-setup.sh` — MODULES + états

```bash
# MODULES+=( … )
"mixbay:mosquitomixbay — USB audio bay (EVO 8/4 full control, SSL 12 via douze, RME CC-mode cards via oscmix GTK/Qt, UGM192 ALSA level 1, beta interfaces + demo)"

# module_state(): ajouter au case
mixbay) st_mixbay ;;

# st_mixbay — binaire + règle Hyprland. Le kmod et la fondation audio sont
# par interface : une installation propre (aucune carte configurée) est "ok".
# C'est le contrat de setup-mosquitomixbay.sh --status, dupliqué ici parce que
# l'orchestrateur ne connaît pas le chemin du checkout.
st_mixbay(){
  [[ -x "$BIN_DIR/mosquito-mixbay-tui" && -x "$BIN_DIR/mosquito-mixbay" ]] || { echo missing; return; }
  grep -qF "mosquito-mixbay-tui-setup" "$HOME/.config/hypr/hyprland.lua" 2>/dev/null \
    || { echo "partial:missing hyprland float rule"; return; }
  if jq -e '.devices | to_entries | any(.value.installed == true)' \
       "$HOME/.config/mosquitomixbay/foundation.json" >/dev/null 2>&1; then
    [[ -f "$HOME/.config/wireplumber/wireplumber.conf.d/50-mixbay-interfaces.conf" ]] \
      || { echo "partial:missing the audio foundation files"; return; }
  fi
  echo ok
}

# run_* : déléguer à code/modules/mosquito/audio-stack/mixbay/setup-mosquitomixbay.sh -y
# module_of_path(): code/modules/mosquito/audio-stack/mixbay/*) echo mixbay ;;
```

Catégorie suggérée : audio (à côté de `audio` et `ableton-move-manager`).

## 2. mosquito live mode — garde + snapshot scène

Live-mode ne pilote pas le mixeur (le TUI scratchpad reste l'outil scène),
il **protège** la prise :

```bash
# dans le hook pre-show (exemple) : échec doux si l'EVO décroche
if ! "$HOME/.local/bin/mosquito-mixbay-actions" status-json --device evo8 \
    | jq -e '.online' >/dev/null; then
  echo "live-mode: EVO 8 offline — check USB (writes are blocked)" >&2
fi

# snapshot scène (recallable) :
mosquitomixbay_device=evo8 "$HOME/.local/bin/mosquito-mixbay-actions" save
# … après le show, retour au snapshot :
mosquitomixbay_device=evo8 "$HOME/.local/bin/mosquito-mixbay-actions" load
```

`save`/`load` sont stricts depuis v1.1 : interface absente, ils échouent au
lieu d'écrire le shadow DEMO. Ajouter `--demo` seulement pour une répète
volontairement débranchée.

Depuis v1.3, la garde des volumes natifs est un module séparé
(`audio-stack/levels-guard` : panneau audio Omarchy cloné + bloc
`levels-guard` dans `bindings.lua`). Mixbay seul ne pose que son propre
raccourci. `ui.json` porte `allow_native_volume` (défaut true, c'est-à-dire
*free* ; *hardware & UI exclusive* est opt-in), mais le réglage n'est
réellement bloquant que si `mosquito.levels-guard` est installé et activé. Une
session Live Mode avec `LOCK_OUTPUT_VOLUME` (défaut) reprend la main et force
l'exclusivité pour la durée de la session. La
capture des mètres USB tourne sur un EVO 8 live dès qu'un onglet EVO est visible
(CONTROLS, MIXER ou LEVELS), même si la fenêtre perd le focus.

Le watchdog `live-mode-watch` peut poller `status-json | jq .online` et
lever un toast via le plugin `mosquito.livemode` si l'interface décroche
en plein set (même pattern que la garde thermale existante).

## 3. Portée volontairement hors v1

- Matrice TotalMix des RME : portée par `oscmix` (installé et lancé depuis
  le menu de la carte), pas par le driver ALSA de Mixbay.
- Profils PipeWire EVO 8 (6 canaux, `analog-surround-51`) : livrés par
  `50-mixbay-evo.conf` et le watchdog de split (`--split on`).
- Patchbay automatique au branchement : volontairement absent. Les presets se
  sauvent/appliquent à la main (`patchbay-save` / `patchbay-apply`).
- Agrégats : activation explicite (`aggregate-activate`) uniquement. Le guard
  `pw-mon` ne fait que rejouer les liens d'un agrégat **déjà actif**, il n'en
  crée aucun au branchement.
- `save`/`load` scène nommés (`--scene NAME`) : le format JSON le permet,
  le CLI ne l'expose pas encore.
