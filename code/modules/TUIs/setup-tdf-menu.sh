#!/usr/bin/env bash
# Float the foot window used when SuperFile launches the tdf PDF viewer.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"
set -euo pipefail

CONF="$HOME/.config/hypr/hyprland.lua"
BEGIN='-- >>> superfile-tdf-setup >>>'
END='-- <<< superfile-tdf-setup <<<'

remove_rule() {
  [[ -f $CONF ]] || return 0
  sed -i '/-- >>> superfile-tdf-setup >>>/,/-- <<< superfile-tdf-setup <<</d' "$CONF"
}

case "${1:-install}" in
  --status)
    if grep -qF -- "$BEGIN" "$CONF" 2>/dev/null; then echo ok; else echo missing; fi
    exit 0
    ;;
  --remove)
    remove_rule
    hyprctl reload >/dev/null 2>&1 || true
    echo "tdf floating rule removed"
    exit 0
    ;;
  install) ;;
  *) echo "Usage: $0 [--status|--remove]" >&2; exit 2 ;;
esac

command -v tdf >/dev/null || { echo "tdf is not installed" >&2; exit 1; }
mkdir -p "$(dirname "$CONF")"
touch "$CONF"
if ! grep -qF -- "$BEGIN" "$CONF"; then
  cp -n "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M%S)"
fi
remove_rule
cat >> "$CONF" <<'EOF'
-- >>> superfile-tdf-setup >>> float the foot terminal used by SuperFile's PDF action
o.window("org.mosquitomarchy.superfile-tdf", { float = true, center = true, size = { 1100, 800 } })
-- <<< superfile-tdf-setup <<<
EOF
hyprctl reload >/dev/null || exit 1
errors="$(hyprctl configerrors 2>/dev/null || true)"
[[ -z $errors ]] || { echo "$errors" >&2; exit 1; }
echo "tdf PDF window floats in a centered 1100×800 Foot terminal"
