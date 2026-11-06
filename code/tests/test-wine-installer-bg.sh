#!/usr/bin/env bash
# Regression test for the blank Wine/Inno Setup background window helper.
#
# It does NOT launch Wine and never touches the live session: a fake `hyprctl`
# returns a clients JSON with an English pair ("Setup" + "Setup - Product"), an
# Italian pair ("Installazione" + "Installazione di Product"), an ISSKIN failure
# ("Setup" + "Error"), an empty-titled blank next to a wizard, a single-window
# installer ("Setup" alone) and an unrelated window whose title happens to be
# generic. The helper must move only the blank windows of installer classes.
#
# The process-risk check is the last assertions: the unrelated window and the
# only window of a lone installer must not be moved, so a normal Wine app/dialog
# can never be pulled to the hidden workspace by this helper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/code/lib/wine-installer-bg.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/hyprctl" <<'FAKE'
#!/usr/bin/env bash
if [[ ${1:-} == clients ]]; then
  cat <<'JSON'
[
 {"address":"0x1","class":"arturia.tmp","title":"Setup","size":[636,616]},
 {"address":"0x2","class":"arturia.tmp","title":"Setup - Tape MELLO-FI","size":[476,345]},
 {"address":"0x3","class":"vendor.tmp","title":"Installazione","size":[636,615]},
 {"address":"0x4","class":"vendor.tmp","title":"Installazione di Product","size":[476,345]},
 {"address":"0x5","class":"real.app","title":"Report","size":[800,600]},
 {"address":"0x6","class":"real.app","title":"Report - Details","size":[400,300]},
 {"address":"0x7","class":"isskin.tmp","title":"Setup","size":[636,616]},
 {"address":"0x8","class":"isskin.tmp","title":"Error","size":[420,180]},
 {"address":"0x9","class":"empty.tmp","title":"","size":[636,616]},
 {"address":"0xa","class":"empty.tmp","title":"Setup - Product","size":[476,345]},
 {"address":"0xb","class":"solo.tmp","title":"Setup","size":[476,345]},
 {"address":"0xc","class":"real.app","title":"Setup","size":[300,200]}
]
JSON
  exit 0
fi
if [[ ${1:-} == eval ]]; then
  printf '%s\n' "$*" >> "$FAKE_LOG"
  exit 0
fi
exit 0
FAKE
chmod +x "$TMP/hyprctl"
export FAKE_LOG="$TMP/moves.log"
export PATH="$TMP:$PATH"
: > "$FAKE_LOG"

stop="$TMP/stop"
"$HELPER" "$stop" &
pid=$!
sleep 1.5
: > "$stop"
wait "$pid" 2>/dev/null || true

moves="$(cat "$FAKE_LOG" 2>/dev/null || true)"
for want in 0x1 0x3 0x7 0x9; do
  grep -q "address:$want" <<<"$moves" || { echo "FAIL: blank window $want not moved"; exit 1; }
done
for deny in 0x2 0x4 0x5 0x6 0x8 0xa 0xb 0xc; do
  if grep -q "address:$deny" <<<"$moves"; then
    echo "FAIL: unrelated/real window $deny was moved"; exit 1
  fi
done
echo "ok: Wine installer background windows are isolated, real windows untouched"
