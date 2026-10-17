#!/bin/bash
# Force l'adaptation des thèmes des TUIs au thème Omarchy courant.
# Le thème dynamique est déjà en place (scripts/lib/tui-kit relit la palette
# Omarchy à chaque démarrage) ; ce fix FORCE la régénération de la palette
# + un rebuild/déploiement des 2 TUIs Go pour être sûr de la prise en compte.

echo "=== Fix TUI theme ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN_DIR="$HOME/.local/bin"

# 1. Régénérer la palette Omarchy courante (colors.toml) — source du thème.
if command -v omarchy >/dev/null 2>&1 && omarchy theme refresh >/dev/null 2>&1; then
  echo "Palette Omarchy régénérée."
else
  echo "omarchy non dispo — palette conservée telle quelle (les TUIs relisent quand même la version actuelle)."
fi

# 2. Rebuild + redéploiement des 2 TUIs Go.
rebuild_tui() { # src_dir, bin_name
  local src_dir="$1" bin_name="$2"
  if [[ ! -d "$src_dir" ]]; then
    echo "Sources introuvables ($src_dir) — $bin_name non reconstruit."
    return 0
  fi
  if ! command -v go >/dev/null 2>&1; then
    echo "go non dispo — $bin_name non reconstruit."
    return 0
  fi
  local tmp_out
  tmp_out="$(mktemp "$BIN_DIR/.$bin_name.XXXXXX")"
  if ! (cd "$src_dir" && go build -o "$tmp_out" .); then
    rm -f "$tmp_out"
    echo "Échec du build — $bin_name conservé tel quel."
    return 0
  fi
  chmod +x "$tmp_out"
  mv -f "$tmp_out" "$BIN_DIR/$bin_name"
  echo "$bin_name reconstruit et redéployé ($BIN_DIR/$bin_name)."
}

mkdir -p "$BIN_DIR"
rebuild_tui "$REPO_ROOT/scripts/apps/audio-plugin-manager/tui-go" mosquito-audio-plugin-manager-tui
rebuild_tui "$REPO_ROOT/scripts/apps/ableton-move-manager/tui-go" mosquito-move-manager-tui

echo "Thème des TUIs synchronisé avec le thème Omarchy courant (redémarre le menu si déjà ouvert)."