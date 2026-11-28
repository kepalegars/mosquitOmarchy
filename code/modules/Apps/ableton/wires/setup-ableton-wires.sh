#!/usr/bin/env bash
# setup-ableton-wires.sh — Ableton Live 12 through the Wires runtime.
#
# This replaces the old shibco Wine module. Wires is a Wine fork: the small
# .run installer from wires.sh carries the app-specific scripts; the Wine
# runtime (~409 MB, Wayland build here) and the Ableton Windows installer are
# downloaded once and cached locally. GitHub only ships this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/PATCH"
CACHE="$SCRIPT_DIR/wires"
RUNTIME_ROOT="${MOSQUITOMARCHY_WIRES_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/mosquitomarchy/runtime/wires}"
WIRES_ROOT="$RUNTIME_ROOT/root"
WORK="${WIRES_WORK:-Music-Production}"
MANIFEST="$CACHE/manifest.tsv"
INSTALL_JSON="https://cdn.wires.sh/install/?format=json"
RUNTIME_JSON="https://cdn.wires.sh/runtimes/?format=json"
SUITE_URL="https://cdn-downloads.ableton.com/channels/12.4.7/ableton_live_suite_12.4.7_64.zip"

YES=0 UNINSTALL=0 UPDATE=0 STATUS=0 CHECK=0 LINKS=0 PURGE=0 RUNTIME_ONLY=0
while (($#)); do
  case $1 in
    -y|--yes) YES=1 ;;
    -i|--install) : ;;
    -u|--uninstall) UNINSTALL=1 ;;
    --purge) PURGE=1 ;;
    --update) UPDATE=1 ;;
    --runtime-only) RUNTIME_ONLY=1 ;;
    --status) STATUS=1 ;;
    --check-update) CHECK=1 ;;
    --links) LINKS=1 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; N=$'\033[0m'
msg(){ printf '==> %s\n' "$*"; }
ok(){ printf ' %s✓%s %s\n' "$G" "$N" "$*"; }
warn(){ printf ' %s!%s %s\n' "$Y" "$N" "$*"; }
err(){ printf ' %s✗%s %s\n' "$R" "$N" "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

mkdir -p "$CACHE" "$WIRES_ROOT/.runtimes" "$WIRES_ROOT/Works"
[[ -f $MANIFEST ]] || : > "$MANIFEST"

manifest_get(){ awk -F'\t' -v k="$1" '$1==k {print $2; exit}' "$MANIFEST"; }
manifest_set(){
  local k="$1" v="$2" tmp
  tmp="$(mktemp)"
  awk -F'\t' -v k="$k" -v v="$v" '$1!=k' "$MANIFEST" > "$tmp"
  printf '%s\t%s\n' "$k" "$v" >> "$tmp"
  mv -f "$tmp" "$MANIFEST"
}

latest_installer(){
  curl -fsSL --max-time 25 "$INSTALL_JSON" 2>/dev/null \
    | python3 -c 'import sys,json
try: names=[x["name"] for x in json.load(sys.stdin) if x["name"].startswith("Wires.Install.Ableton.Live.12+") and x["name"].endswith(".Standalone.run")]
except Exception: names=[]
print(sorted(names)[-1] if names else "")' 2>/dev/null || true
}

latest_runtime(){
  curl -fsSL --max-time 25 "$RUNTIME_JSON" 2>/dev/null \
    | python3 -c 'import sys,json
try: names=[x["name"] for x in json.load(sys.stdin) if x["name"].startswith("Wires.Runtime.") and ".WL-PARA.REAL.tar.zst" in x["name"]]
except Exception: names=[]
print(sorted(names)[-1] if names else "")' 2>/dev/null || true
}

sha_for(){ # name -> sha256 from the CDN .sha256 file
  local name="$1" base="${1%.run}" url
  case $name in
    *.run) url="https://cdn.wires.sh/install/$name.sha256" ;;
    *)     url="https://cdn.wires.sh/runtimes/$name.sha256" ;;
  esac
  curl -fsSL --max-time 25 "$url" 2>/dev/null | awk '{print $1}' || true
}

download_checked(){ # url dest [expected_sha]
  local url="$1" dest="$2" expected="${3:-}" tmp
  [[ -f $dest && -z $expected ]] && return 0
  if [[ -f $dest && -n $expected ]] && [[ $(sha256sum "$dest" | cut -d' ' -f1) == "$expected" ]]; then
    return 0
  fi
  tmp="$dest.part"
  msg "Downloading $(basename "$dest")"
  curl -fL --retry 3 -o "$tmp" "$url"
  if [[ -n $expected ]] && [[ $(sha256sum "$tmp" | cut -d' ' -f1) != "$expected" ]]; then
    rm -f "$tmp"; err "SHA-256 mismatch for $(basename "$dest")"; return 1
  fi
  mv -f "$tmp" "$dest"
  ok "$(basename "$dest") cached"
}

find_live_exe(){
  local z base shared
  shared="$(cd "$SCRIPT_DIR/.." && pwd)"
  for z in "$shared"/Ableton*.zip "$shared"/ableton*.zip "$SCRIPT_DIR"/*.zip "$HOME/Downloads"/ableton_live_suite*.zip; do
    [[ -f $z ]] || continue
    base="$(unzip -Z1 "$z" 2>/dev/null | grep -iE 'Installer.*\.exe$' | head -1 || true)"
    [[ -n $base ]] || continue
    cp -n -- "$z" "$CACHE/archive.zip" 2>/dev/null || true
    unzip -p "$z" "$base" > "$CACHE/AbletonLiveSuite.exe"
    printf '%s\n' "$CACHE/AbletonLiveSuite.exe"
    return 0
  done
  return 1
}

prepare_assets(){
  local ins run sha rt rsha
  for c in curl unzip python3 sha256sum tar; do
    have "$c" || { err "Missing tool: $c"; return 1; }
  done
  ins="$(latest_installer)"; rt="$(latest_runtime)"
  [[ -n $ins && -n $rt ]] || { err "Could not read the Wires CDN catalogue."; return 1; }

  run="$CACHE/$ins"
  if [[ $(manifest_get installer) != "$ins" || ! -f $run ]]; then
    download_checked "https://cdn.wires.sh/install/$ins" "$run" "$(sha_for "$ins")" || return 1
    manifest_set installer "$ins"
    rm -rf "$CACHE/installer"
  fi
  local archive="$CACHE/$rt"
  if [[ $(manifest_get runtime) != "$rt" || ! -f $archive ]]; then
    sha="$(sha_for "$rt")"
    download_checked "https://cdn.wires.sh/runtimes/$rt" "$archive" "$sha" || return 1
    manifest_set runtime "$rt"
    local dir="${rt%.tar.zst}"
    rm -rf "$WIRES_ROOT/.runtimes/$dir"
    mkdir -p "$WIRES_ROOT/.runtimes/$dir"
    tar --use-compress-program=zstd -xf "$archive" -C "$WIRES_ROOT/.runtimes" --strip-components=1 2>/dev/null \
      || tar -xf "$archive" -C "$WIRES_ROOT/.runtimes" --strip-components=1
    manifest_set runtime_name "$dir"
  fi

  if [[ ! -f $CACHE/installer/entrypoint.sh ]]; then
    mkdir -p "$CACHE/installer"
    ( cd "$CACHE/installer" && bash "$run" --target "$CACHE/installer" --noexec ) >/dev/null
  fi
  # Local overrides only: point at the Wayland runtime and allow --installer.
  python3 - "$CACHE/installer/install.sh" "$(manifest_get runtime_name)" <<'PY'
import sys, re
p, name = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
s = re.sub(r"WIRES_RUNTIME='[^']*'", "WIRES_RUNTIME='%s'" % name, s, count=1)
s = s.replace("WIRES_CATALOGUE=0", "WIRES_CATALOGUE=1", 1)
open(p, "w", encoding="utf-8").write(s)
PY

  local exe="${CACHE}/AbletonLiveSuite.exe"
  [[ -f $exe ]] || find_live_exe >/dev/null || {
    warn "No Ableton Suite zip found — downloading the 12.4.7 installer from Ableton."
    curl -fL --retry 3 -o "$CACHE/suite.zip" "$SUITE_URL"
    unzip -p "$CACHE/suite.zip" "$(unzip -Z1 "$CACHE/suite.zip" | grep -iE 'Installer.*\.exe$' | head -1)" > "$exe"
  }
  printf '%s\n' "$exe"
}

do_links(){
  local linker="$SCRIPT_DIR/../../../../mosquitomarchy/audio-stack/apm/link-vst-shared.sh"
  [[ -x $linker ]] || linker="$HOME/mosquitOmarchy/code/modules/mosquitomarchy/audio-stack/apm/link-vst-shared.sh"
  [[ -x $linker ]] && bash "$linker" || warn "APM linker missing."
}

hypr_rules(){
  local conf="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua" begin='-- >>> mosquitomarchy-ableton-wires >>>' end='-- <<< mosquitomarchy-ableton-wires <<<'
  [[ -f $conf ]] || return 0
  sed -i "/$begin/,/$end/d" "$conf"
  cat >> "$conf" <<EOF
$begin
windowrulev2 = float, class:(?i)Ableton Live
windowrulev2 = opacity 1.0 override, class:(?i)Ableton Live
windowrulev2 = no_initial_focus, class:(?i)Ableton Live
$end
EOF
  ok "Hyprland rules written"
}

do_install(){
  local exe
  exe="$(prepare_assets)" || return 1
  msg "Installing Ableton Live 12 with Wires into $WIRES_ROOT/Works/$WORK"
  bash "$CACHE/installer/entrypoint.sh" install \
    --installer "$exe" --runtime "$CACHE/$(manifest_get runtime)" \
    --work "$WORK" --root "$WIRES_ROOT" --language en
  local rc=$?
  ((rc)) && return "$rc"
  do_links
  hypr_rules
  local patch="$PATCH_DIR/patch-ableton-wires.sh"
  if [[ -f $patch ]]; then
    msg "Applying the R2R patch to the Wires prefix"
    ABLETON_PREFIX="$WIRES_ROOT/Works/$WORK/environment" bash "$patch" -y || warn "R2R patch step was inconclusive."
  fi
  ok "Wires installation finished"
}

do_update(){ do_install; }

do_uninstall(){
  local w="$WIRES_ROOT/Works/$WORK" apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  [[ -d $w ]] || { warn "No Wires Work at $w"; return 0; }
  msg "Removing the Wires Ableton Work: $w"
  rm -rf -- "$w"
  rm -f -- "$apps"/wires-ableton-live-12-*.desktop
  command -v update-desktop-database >/dev/null && update-desktop-database "$apps" >/dev/null 2>&1 || true
  (( PURGE )) && rm -rf -- "$CACHE"
  ok "Wires Ableton removed"
}

state(){
  local w="$WIRES_ROOT/Works/$WORK"
  [[ -f "$w/PLUGS.WIRES" ]] && grep -qx 'ableton-live-12' "$w/PLUGS.WIRES" \
    && [[ -d "$w/environment/drive_c" ]] && echo installed || echo missing
}

if (( CHECK )); then
  ins="$(latest_installer)"; rt="$(latest_runtime)"
  [[ $(manifest_get installer) == "$ins" && -f "$CACHE/$ins" ]] && echo 'installer:up-to-date' || echo 'installer:update'
  [[ $(manifest_get runtime) == "$rt" && -f "$CACHE/$rt" ]] && echo 'runtime:up-to-date' || echo 'runtime:update'
  exit 0
fi
if (( STATUS )); then
  s="$(state)"
  [[ $s == installed ]] && ok "Ableton Live 12 (Wires) installed in $WIRES_ROOT/Works/$WORK" \
                        || warn "Ableton Live 12 (Wires) not installed"
  exit 0
fi
if (( UNINSTALL )); then do_uninstall; exit 0; fi
if (( LINKS )); then do_links; exit 0; fi
if (( UPDATE )); then
  [[ $(state) == installed ]] || { warn "Nothing installed to update."; exit 0; }
  do_update; exit $?
fi
do_install
