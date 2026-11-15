#!/usr/bin/env bash
# Self-check for the oscmix module: syntax, status, GTK handoff and uninstall.
# Runs entirely under a temporary HOME.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

check() { # name, condition
  if eval "$2"; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1"; FAIL=1; fi
}

check "setup-oscmix syntax" "bash -n '$HERE/setup-oscmix.sh'"
check "GTK launcher syntax" "bash -n '$HERE/launch-oscmix-gtk'"
check "Qt launcher syntax" "bash -n '$HERE/launch-oscmix-qt'"

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/run"
export HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run"
out="$(PATH="$TMP/bin:/usr/bin:/bin" bash "$HERE/setup-oscmix.sh" --status 2>&1)" || true
check "status reports the missing engine" "[[ '$out' == missing:*oscmix* ]]"

# Fake a complete per-user install.
mkdir -p "$TMP/home/.local/bin" "$TMP/home/.local/lib/oscmix/gtk"
for b in oscmix alsaseqio alsarawio oscmix-gtk; do
  printf '#!/bin/sh\n' > "$TMP/home/.local/bin/$b"
  chmod +x "$TMP/home/.local/bin/$b"
done
touch "$TMP/home/.local/lib/oscmix/gtk/gschemas.compiled"
out="$(PATH="$TMP/bin:/usr/bin:/bin" bash "$HERE/setup-oscmix.sh" --status 2>&1)"
check "status reports ok with GTK" "[[ '$out' == *ok* && '$out' == *'qt: missing'* ]]"

printf '#!/bin/sh\n' > "$TMP/home/.local/lib/oscmix/oscmix-qt.AppImage"
chmod +x "$TMP/home/.local/lib/oscmix/oscmix-qt.AppImage"
out="$(PATH="$TMP/bin:/usr/bin:/bin" bash "$HERE/setup-oscmix.sh" --status 2>&1)"
check "status reports the Qt AppImage" "[[ '$out' == *'qt: ok'* ]]"

# The GTK launcher finds the Fireface sequencer client, starts alsaseqio with
# the last port, then runs oscmix-gtk.
cat > "$TMP/bin/aconnect" <<'EOF'
#!/usr/bin/env bash
cat <<'LIST'
client 14: 'Midi Through' [type=kernel]
    0 'Midi Through Port-0'
client 16: 'Fireface UCX II (12345678)' [type=Kernel,card=2]
    0 'Fireface UCX II (12345678) Port 1'
    1 'Fireface UCX II (12345678) Port 2'
LIST
EOF
cat > "$TMP/bin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'UNCONN 0 0 127.0.0.1:7222 0.0.0.0:*\n'
EOF
cat > "$TMP/home/.local/bin/alsaseqio" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TMP/seqio-args"
EOF
cat > "$TMP/home/.local/bin/oscmix-gtk" <<EOF
#!/usr/bin/env bash
touch "$TMP/gtk-ran"
EOF
chmod +x "$TMP/bin/aconnect" "$TMP/bin/ss" \
  "$TMP/home/.local/bin/alsaseqio" "$TMP/home/.local/bin/oscmix-gtk"
PATH="$TMP/bin:/usr/bin:/bin" "$HERE/launch-oscmix-gtk" >/dev/null 2>&1 || true
check "launcher starts alsaseqio on the control port" "[[ -f '$TMP/seqio-args' && \"\$(< '$TMP/seqio-args')\" == *'16:1'* ]]"
check "launcher opens oscmix-gtk" "[[ -f '$TMP/gtk-ran' ]]"
check "launcher leaves no pid behind" "[[ ! -e '$TMP/run/mixbay-oscmix-gtk.pid' ]]"

# Without an install the launcher explains what to run.
mkdir -p "$TMP/empty"
out="$(PATH="/usr/bin:/bin" HOME="$TMP/empty" "$HERE/launch-oscmix-gtk" 2>&1)" || true
check "launcher explains a missing install" "[[ '$out' == *'oscmix is not installed'* ]]"

HOME="$TMP/home" XDG_DATA_HOME="$TMP/home/.local/share" \
  bash "$HERE/setup-oscmix.sh" --uninstall >/dev/null 2>&1
check "uninstall removes binaries" "[[ ! -e '$TMP/home/.local/bin/oscmix-gtk' ]]"
check "uninstall removes the Qt AppImage" "[[ ! -e '$TMP/home/.local/lib/oscmix' ]]"

exit "$FAIL"
