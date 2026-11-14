#!/usr/bin/env bash
# Self-check for the oscmix module: syntax, MIDI detection, install status,
# and uninstall. Runs entirely under a temporary HOME.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

check() { # name, condition
  if eval "$2"; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1"; FAIL=1; fi
}

check "setup-oscmix syntax" "bash -n '$HERE/setup-oscmix.sh'"
check "launcher syntax" "bash -n '$HERE/launch-oscmix-gtk'"

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/data"
cat > "$TMP/bin/amidi" <<'EOF'
#!/usr/bin/env bash
printf 'Dir Device    Name\nIO  hw:2,0,1  Fireface UCX II\n'
EOF
chmod +x "$TMP/bin/amidi"

out="$(PATH="$TMP/bin:$PATH" "$HERE/launch-oscmix-gtk" --detect 2>&1)" || true
check "detect returns card,dev,sub" "[[ '$out' == '2,0,1' ]]"

cat > "$TMP/bin/amidi" <<'EOF'
#!/usr/bin/env bash
printf 'Dir Device    Name\nIO  hw:0,0,0  Some Other MIDI\n'
EOF
chmod +x "$TMP/bin/amidi"
if PATH="$TMP/bin:$PATH" "$HERE/launch-oscmix-gtk" --detect >/dev/null 2>&1; then
  printf 'FAIL detect rejects a non-UCX device\n'; FAIL=1
else
  printf 'ok   detect rejects a non-UCX device\n'
fi

out="$(HOME="$TMP/home" XDG_DATA_HOME="$TMP/data" bash "$HERE/setup-oscmix.sh" --status 2>&1)" || true
check "status reports missing binaries" "[[ '$out' == missing:* ]]"

mkdir -p "$TMP/home/.local/bin" "$TMP/data/glib-2.0/schemas" "$TMP/data/mosquitomixbay/oscmix"
for b in oscmix alsarawio alsaseqio oscmix-gtk; do
  printf '#!/bin/sh\n' > "$TMP/home/.local/bin/$b"; chmod +x "$TMP/home/.local/bin/$b"
done
touch "$TMP/data/glib-2.0/schemas/oscmix.gschema.xml"
out="$(HOME="$TMP/home" XDG_DATA_HOME="$TMP/data" bash "$HERE/setup-oscmix.sh" --status 2>&1)" || true
check "status reports ok" "[[ '$out' == ok ]]"

HOME="$TMP/home" XDG_DATA_HOME="$TMP/data" bash "$HERE/setup-oscmix.sh" --uninstall >/dev/null 2>&1
check "uninstall removes binaries" "[[ ! -e '$TMP/home/.local/bin/oscmix' && ! -e '$TMP/home/.local/bin/oscmix-gtk' ]]"
check "uninstall removes schema" "[[ ! -e '$TMP/data/glib-2.0/schemas/oscmix.gschema.xml' ]]"
check "uninstall removes source" "[[ ! -d '$TMP/data/mosquitomixbay/oscmix' ]]"

exit "$FAIL"
