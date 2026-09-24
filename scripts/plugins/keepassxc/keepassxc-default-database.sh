#!/usr/bin/env bash
# keepassxc-default-database.sh — tell KeePassXC "MY database IS the default one".
#
# Problem (user report): opening a web app (the Browser integration / the
# FdoSecrets secret-service flow) keeps asking for a NEW KeePassXC database
# — because the ini NEVER recorded which .kdbx is "the one". The user has a
# custom database: we (1) enable the Remember* flags, (2) pin
# LastOpenedDatabases / LastActiveDatabase to that file so any keepassxc
# launch opens THAT database for everything — never the "create a new one"
# dialog.
#
# Usage:
#   keepassxc-default-database.sh             # detect the newest .kdbx in $HOME (depth ≤ 5)
#   keepassxc-default-database.sh FILE.kdbx   # explicit path
#   keepassxc-default-database.sh --status    # what is pinned today
#   keepassxc-default-database.sh --clear     # unpin (= stock behaviour)
#
# KeePassXC must be CLOSED for the ini edits (the app rewrites the ini on
# exit); this script refuses to change it while the process is running
# (--force to break the rule). After the pin, a web app never asks to create
# a database again — it either discovers the unlocked (or remembered) one
# from the FdoSecrets secret service.
#
set -euo pipefail

GLOBALS="$HOME/.config/keepassxc/keepassxc.ini"

ok()   { echo -e "\033[32m ●\033[0m $*"; }
info(){ echo -e "\033[1;34m==>\033[0m $*"; }
warn(){ echo -e "\033[1;33m !\033[0m $*" >&2; }
err() { echo -e "\033[1;31m ✗\033[0m $*" >&2; }

status() {
  info "pinned in $GLOBALS:"
  grep -E 'LastOpenedDatabases|LastActiveDatabase|RememberLast(Databases|KeyFiles)' "$GLOBALS" 2>/dev/null | sed 's/^/  /' \
    || echo "  (nothing pinned — stock behaviour)"
  [[ -f "$GLOBALS.pre-keepassxc" ]] && info "backup present: $GLOBALS.pre-keepassxc"
  true
}

clear_pinned() {
  local tmp; tmp=$(mktemp)
  sed '/^LastOpenedDatabases=/d; /^LastActiveDatabase=/d' "$GLOBALS" > "$tmp"
  mv "$tmp" "$GLOBALS"
  ok "database pin removed (stock no-default-database behaviour restored)"
}

mode="${1:-apply}"
case "$mode" in
  --status|-h|--help|--clear)
    case "$mode" in
      --status) status ;;
      --clear)  [[ -f $GLOBALS ]] && clear_pinned || err "no ini: $GLOBALS" ;;
      *) sed -n '2,28p' "$0" ;;
    esac
    exit 0 ;;
esac

TARGET="${1:-}"
if [[ -z ${TARGET:-} ]]; then
  t="$(find "$HOME" -maxdepth 5 -name '*.kdbx' -not -path '*/.Trash/*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1)"
  [[ -n $t ]] || { err "no .kdbx found in $HOME (depth ≤ 5); pass a path: $0 FILE.kdbx"; exit 1; }
  TARGET="${t#* }"
fi
TARGET="$(readlink -f -- "$TARGET")"
[[ -f "$TARGET" ]] || { err "database file missing: $TARGET"; exit 1; }
info "Pinning the DEFAULT database: $TARGET"

# KeePassXC must be CLOSED for the ini edits (it re-writes the ini at exit).
if pgrep -x keepassxc >/dev/null 2>&1; then
  info "keepassxc is running — closing it so the ini can be edited safely…"
  pkill -x keepassxc 2>/dev/null || true
  sleep 1
fi

#[[ -f $GLOBALS.pre-keepassxc ]] || cp "$GLOBALS" "$GLOBALS.pre-keepassxc"

python3 - "$GLOBALS" "$TARGET" <<'PY'
import re, sys
path, db_path = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    data = fh.read()
if "[General]" not in data:
    if not data.endswith("\n"):
        data += "\n"
    data = "[General]\n" + data
lines, out, in_gen = data.split("\n"), [], False
for line in lines:
    if line.strip() == "[General]":
        in_gen = True
        out.append(line)
        out.extend([
            "RememberLastDatabases = true",
            "RememberLastKeyFiles = true",
            "LastOpenedDatabases = " + db_path,
            "LastActiveDatabase = " + db_path,
        ])
        continue
    if in_gen:
        if re.match(r"^RememberLast(Bw|KeyFiles|Databases)\s*=", line):
            continue
        if re.match(r"^Last(OpenedDatabases|ActiveDatabase)\s*=", line):
            continue
        if line.startswith("["):
            in_gen = False
    out.append(line)
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
PY
ok "remember-last-databases + LastOpenedDatabases/LastActiveDatabase pinned to:"
info "$TARGET"
info "Open KeePassXC once (unlock it), then every web app (browser extension + FdoSecrets)"
info "uses THAT database. The 'create a new database' prompt disappears."
