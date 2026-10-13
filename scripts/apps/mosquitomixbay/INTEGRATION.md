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
"mixbay:mosquitomixbay — USB audio bay (EVO 8/4 full control, Fireface UCX II / UGM192 / Quantum ES 4 ALSA level 1 + demo)"

# module_state(): ajouter au case
mixbay) st_mixbay ;;

# st_mixbay — miroir de st_audio (binaire + règle Hyprland + kmod en bonus) :
st_mixbay(){
  [[ -x "$BIN_DIR/mosquito-mixbay-tui" && -x "$BIN_DIR/mosquito-mixbay" ]] || { echo missing; return; }
  local miss=""
  grep -qF "mosquito-mixbay-tui-setup" "$HOME/.config/hypr/hyprland.lua" 2>/dev/null \
    || miss="${miss:+$miss, }hyprland float rule"
  [[ -e /dev/evo8 || -e /dev/evo4 ]] \
    || miss="${miss:+$miss, }evo_raw kmod (demo mode only)"
  [[ -n $miss ]] && { echo "partial:missing ${miss# }"; return; }
  echo ok
}

# run_* : déléguer à scripts/apps/mosquitomixbay/setup-mosquitomixbay.sh -y
# module_of_path(): scripts/apps/mosquitomixbay/*) echo mixbay ;;
```

Catégorie suggérée : audio (à côté de `audio` et `ableton-move-manager`).

## 2. mosquito live mode — garde + snapshot scène

Live-mode ne pilote pas le mixeur (le TUI scratchpad reste l'outil scène),
il **protège** la prise :

```bash
# dans le hook pre-show (exemple) : échec doux si l'EVO décroche
if ! "$HOME/.local/bin/mosquito-mixbay-actions" status-json --device evo8 \
    | jq -e '.online' >/dev/null; then
  echo "live-mode: EVO 8 offline — show continues on DEMO shadow (check USB)" >&2
fi

# snapshot scène (recallable) :
mosquitomixbay_device=evo8 "$HOME/.local/bin/mosquito-mixbay-actions" save
# … après le show, retour au snapshot :
mosquitomixbay_device=evo8 "$HOME/.local/bin/mosquito-mixbay-actions" load
```

Le watchdog `live-mode-watch` peut poller `status-json | jq .online` et
lever un toast via le plugin `mosquito.livemode` si l'interface décroche
en plein set (même pattern que la garde thermale existante).

## 3. Portée volontairement hors v1

- Matrice TotalMix UCX II : attendre `snd-fireface-ctl-service` USB.
- Profils PipeWire EVO 8 (6 canaux, `analog-surround-51`) : voir
  `dev/wireplumber/evo8` upstream — à empaqueter quand le hardware est là.
- `save`/`load` scène nommés (`--scene NAME`) : le format JSON le permet,
  le CLI ne l'expose pas encore.
