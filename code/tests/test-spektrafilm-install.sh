#!/usr/bin/env bash
# The SpektraFilm module must use any spektrafilm*.zip, run the install.sh the
# archive contains, delete the extracted copy, keep the zip, and remove only
# its own OFX bundles.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/code/modules/Apps/spektrafilm/setup-spektrafilm.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GUI_RUN_EXEC=1
export MQ_OFX_DIR="$TMP/ofx"
export MQ_SPEKTRAFILM_ZIP_DIR="$TMP/zips"
export MQ_SPEKTRAFILM_AUR_PKG="spektrafilm-test-pkg"
export TMPDIR="$TMP/work"
export MQ_TEST_MARKER="$TMP/installed"
export PKG_MARK="$TMP/pkg-installed"
export AUR_STUB_LOG="$TMP/aur.log"
mkdir -p "$MQ_OFX_DIR" "$MQ_SPEKTRAFILM_ZIP_DIR" "$TMPDIR" "$TMP/bin"

# The module installs the AUR package alongside the OFX. Keep the test off the
# real package manager: these stubs answer the same questions for a fake name.
cat > "$TMP/bin/pacman" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -Q) [[ -f $PKG_MARK ]] ;;
  -Rns) rm -f "$PKG_MARK" ;;
  *) exit 0 ;;
esac
EOF
cat > "$TMP/bin/yay" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == -S ]] || exit 0
printf 'yay %s\n' "$*" >> "$AUR_STUB_LOG"
touch "$PKG_MARK"
EOF
cat > "$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -n && ${2:-} == -v ]]; then exit 0; fi
exec "$@"
EOF
chmod +x "$TMP/bin/pacman" "$TMP/bin/yay" "$TMP/bin/sudo"
export PATH="$TMP/bin:$PATH"

fail(){ echo "FAIL: $*" >&2; exit 1; }

make_archive(){
  local name="$1" with_installer="$2" pkg="$TMP/pkg" b
  rm -rf "$pkg"; mkdir -p "$pkg/spektrafilm-linux-x86_64-v1"
  for b in spektrafilm spektrafilm_flow spektrafilm_diffuse spektrafilm_lens; do
    mkdir -p "$pkg/spektrafilm-linux-x86_64-v1/$b.ofx.bundle/Contents/Resources"
  done
  if (( with_installer )); then
    cat > "$pkg/spektrafilm-linux-x86_64-v1/install.sh" <<'EOF'
#!/bin/sh
set -eu
dest=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dest) dest=$2; shift 2 ;;
    --system|--no-prewarm) shift ;;
    *) echo "unexpected arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$dest" ] || exit 3
cp -R "$(dirname "$0")"/spektrafilm*.ofx.bundle "$dest/"
printf 'installed\n' > "$MQ_TEST_MARKER"
EOF
    printf '{"version":"9.9.9"}\n' > "$pkg/spektrafilm-linux-x86_64-v1/spektrafilm.ofx.bundle/Contents/Resources/update_config.json"
  else
    printf 'not an installer\n' > "$pkg/spektrafilm-linux-x86_64-v1/README.txt"
  fi
  (cd "$pkg" && zip -qr "$MQ_SPEKTRAFILM_ZIP_DIR/$name" .)
}

# ── a generic zip is ignored; the expected name is reported ─────────────────
printf 'x' > "$MQ_SPEKTRAFILM_ZIP_DIR/other.zip"
if bash "$SCRIPT" >"$TMP/none.log" 2>&1; then fail "install ran without a SpektraFilm zip"; fi
grep -q 'No SpektraFilm zip' "$TMP/none.log" || fail "missing no-zip message"
rm -f "$MQ_SPEKTRAFILM_ZIP_DIR/other.zip"

# ── a zip without install.sh is refused, and nothing is written ─────────────
make_archive "spektrafilm-bad.zip" 0
if bash "$SCRIPT" >"$TMP/bad.log" 2>&1; then fail "bad archive accepted"; fi
grep -q 'No install.sh' "$TMP/bad.log" || fail "missing bad-archive message"
[[ ! -e "$MQ_OFX_DIR/spektrafilm.ofx.bundle" ]] || fail "bad archive installed a bundle"
[[ ! -f "$PKG_MARK" ]] || fail "bad archive installed the AUR package"
rm -f "$MQ_SPEKTRAFILM_ZIP_DIR/spektrafilm-bad.zip"

# ── install: runs the payload, keeps the zip, deletes the extraction ───────
make_archive "spektrafilm-9.9.9.zip" 1
bash "$SCRIPT" >"$TMP/apply.log" 2>&1 || fail "install exited non-zero"
[[ -f "$MQ_OFX_DIR/spektrafilm.ofx.bundle/Contents/Resources/update_config.json" ]] \
  || fail "payload installer did not run"
[[ -f "$MQ_TEST_MARKER" ]] || fail "install.sh did not run"
[[ -f "$PKG_MARK" ]] || fail "AUR package was not installed"
grep -q 'yay -S --needed --noconfirm spektrafilm-test-pkg' "$AUR_STUB_LOG" \
  || fail "yay was not asked to install the AUR package"
[[ -f "$MQ_SPEKTRAFILM_ZIP_DIR/spektrafilm-9.9.9.zip" ]] || fail "zip was deleted"
compgen -G "$TMPDIR/spektrafilm.*" >/dev/null && fail "extracted archive was left behind"

# ── status sees it ──────────────────────────────────────────────────────────
bash "$SCRIPT" --status >"$TMP/status.log" 2>&1 || fail "status exited non-zero"
grep -q '^ok: SpektraFilm 9.9.9' "$TMP/status.log" || fail "status did not report the installed version"

# ── remove: only the bundles go, the zip stays ──────────────────────────────
bash "$SCRIPT" --remove -y >"$TMP/remove.log" 2>&1 || fail "remove exited non-zero"
[[ ! -e "$MQ_OFX_DIR/spektrafilm.ofx.bundle" ]] || fail "bundle still present after remove"
[[ ! -f "$PKG_MARK" ]] || fail "AUR package still present after remove"
[[ -f "$MQ_SPEKTRAFILM_ZIP_DIR/spektrafilm-9.9.9.zip" ]] || fail "remove deleted the zip"
bash "$SCRIPT" --status >"$TMP/status2.log" 2>&1
grep -q '^missing:' "$TMP/status2.log" || fail "status did not report missing after remove"

echo 'ok: spektrafilm zip is used, kept, and its extraction removed'
