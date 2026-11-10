#!/usr/bin/env bash
# tweak-nautilus-audio.sh — Nautilus right-click audio tools: PACPL + makesfz.
#
# Adds two entries to Nautilus' right-click **Scripts** submenu:
#
#   Convert Audio (PACPL) — Perl Audio Converter (pacpl, AUR): converts the
#     selected files to MP3/FLAC/OGG/OPUS/WAV/M4A/AIFF/WV through a small
#     tui-kit Go picker (mosquitOmarchy-audio-convert, themed like the other
#     TUIs), opened in a terminal. Tags are kept. The overwrite question is
#     asked ONLY when at least one output file already exists. The encoder set
#     (vorbis-tools, opus-tools, sox, flac, lame, wavpack, ffmpeg) is installed
#     with it so the common formats work out of the box.
#
#   Make SFZ — makesfz (single bash script from rock-hopper/makesfz, public
#     domain): turns the selected WAV/FLAC/OGG samples into .sfz sampler
#     instrument definition files, in a terminal (foot, fallback xterm). Its
#     interactive mode asks for the mapping: one .sfz per sample spanning the
#     keyboard, or a single multi-sample map (-s), key ranges, velocity layers
#     grouped by name prefix/suffix or sub-directory.
#
# Nautilus watches ~/.local/share/nautilus/scripts, so both entries appear
# without restarting it. The scripts are written here (not shipped as extra
# files) and carry a marker; a same-named file without that marker is the
# user's and is never overwritten or deleted.
#
# Idempotent: may be re-run without risk. --remove deletes the two managed
# Nautilus scripts, ~/.local/bin/makesfz and the converter TUI. pacpl and the
# encoders stay installed (remove them by hand if unwanted), because pacman
# packages are shared with the rest of the system.
#
# Usage:
#   ./tweak-nautilus-audio.sh            # apply (idempotent)
#   ./tweak-nautilus-audio.sh --status   # current state, changes nothing
#   ./tweak-nautilus-audio.sh --remove   # drop the scripts, makesfz and the TUI
#   ./tweak-nautilus-audio.sh -y         # accepted, no prompt (there is none)
#   ./tweak-nautilus-audio.sh -h
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.bash"

MAKESFZ_URL="https://raw.githubusercontent.com/rock-hopper/makesfz/master/makesfz"
BIN_DIR="$HOME/.local/bin"
MAKESFZ="$BIN_DIR/makesfz"
CONVERT_BIN="$BIN_DIR/mosquitomarchy-audio-convert"
TUI_DIR="$SCRIPT_DIR/nautilus-audio/tui-go"
NAUTILUS_DIR="$HOME/.local/share/nautilus/scripts"
PACPL_SCRIPT="$NAUTILUS_DIR/Convert Audio (PACPL)"
SFZ_SCRIPT="$NAUTILUS_DIR/Make SFZ"
MARK="# managed by mosquitOmarchy (tweak-nautilus-audio)"

YES=0

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------
install_audio_tools() {
  local c missing=()
  for c in pacpl oggenc opusenc sox flac lame wavpack ffmpeg; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  # pacpl loads these at startup, but its AUR package does not declare them:
  # without them it dies with "Can't locate File/Util.pm". Check the modules
  # themselves instead of trusting a package name.
  local m
  for m in File::Util Ogg::Vorbis::Header String::ShellQuote; do
    perl -M"$m" -e1 >/dev/null 2>&1 || missing+=("$m")
  done
  if ((${#missing[@]} == 0)); then
    ok "audio tools already installed (pacpl + encoders)"
    return 0
  fi
  require_yay || return 1
  if ! command -v pacpl >/dev/null 2>&1; then
    # An interrupted earlier run can leave a truncated source in yay's cache;
    # makepkg then fails every later run on a checksum that can never pass
    # ("pacpl-6.1.3.tar.bz2 ... FAILED", bzip2 "trailing garbage after EOF").
    # Clearing just this package's build cache makes yay fetch it again; the
    # dependency caches are separate and survive.
    rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/yay/pacpl"
  fi
  msg "Installing pacpl (AUR) + encoders: ${missing[*]}"
  # One yay call for AUR and repo packages alike; --needed keeps a re-run free.
  # The three perl-* packages are pacpl's undeclared startup modules.
  yay -S --needed --noconfirm pacpl \
    perl-file-util perl-ogg-vorbis-header perl-string-shellquote \
    vorbis-tools opus-tools sox flac lame wavpack ffmpeg || {
    err "package installation failed — see the yay output above"
    return 1
  }
  command -v pacpl >/dev/null 2>&1 || { err "pacpl still missing after install"; return 1; }
  ok "pacpl: $(command -v pacpl)"
}

install_makesfz() {
  mkdir -p "$BIN_DIR"
  local tmp
  tmp="$(mktemp "$BIN_DIR/.makesfz.XXXXXX")"
  # Download to a temp next to the target so the move is atomic. If the network
  # is down but a working copy exists, keep it instead of failing the tweak.
  if curl -fsSL --max-time 30 "$MAKESFZ_URL" -o "$tmp" \
     && [[ -s $tmp ]] && head -1 "$tmp" | grep -q 'bash'; then
    chmod 755 "$tmp"
    mv -f "$tmp" "$MAKESFZ"
    ok "makesfz: $MAKESFZ"
  else
    rm -f "$tmp"
    if [[ -x $MAKESFZ ]] && grep -q 'makesfz' "$MAKESFZ" 2>/dev/null; then
      warn "could not refresh makesfz (offline?) — keeping the installed copy"
    else
      err "could not download makesfz from $MAKESFZ_URL"
      return 1
    fi
  fi
}

install_convert_tui() {
  command -v go >/dev/null 2>&1 || {
    err "Go is required to build the converter TUI — install it first (pacman -S go)"
    return 1
  }
  [[ -d $TUI_DIR ]] || { err "converter source missing at $TUI_DIR"; return 1; }
  msg "Building the converter TUI (tui-kit)…"
  mkdir -p "$BIN_DIR"
  (
    cd "$TUI_DIR" || exit 1
    # shellcheck source=../../lib/go-build-env.bash
    source "$SCRIPT_DIR/../../lib/go-build-env.bash"
    go build -o "$CONVERT_BIN" .
  ) || { err "converter TUI build failed"; return 1; }
  ok "converter TUI: $CONVERT_BIN"
}

# ---------------------------------------------------------------------------
# Nautilus scripts
# ---------------------------------------------------------------------------
install_nautilus_script() { # $1 = path; content on stdin
  local path="$1" tmp
  if [[ -e $path ]] && ! grep -qF -- "$MARK" "$path" 2>/dev/null; then
    err "$path exists and is not managed by mosquitOmarchy — refusing to overwrite"
    return 1
  fi
  tmp="$(mktemp "$NAUTILUS_DIR/.tmp.XXXXXX")"
  cat > "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$path"
}

install_nautilus_scripts() {
  mkdir -p "$NAUTILUS_DIR"

  install_nautilus_script "$PACPL_SCRIPT" <<'PACPL'
#!/usr/bin/env bash
# Convert Audio (PACPL) — Nautilus script.
# managed by mosquitOmarchy (tweak-nautilus-audio) — re-run the tweak to restore, --remove to delete.
set -euo pipefail

mapfile -t files < <(printf '%s\n' "${NAUTILUS_SCRIPT_SELECTED_FILE_PATHS:-}" | sed '/^$/d')
((${#files[@]})) || exit 0

bin="$HOME/.local/bin/mosquitomarchy-audio-convert"
if [[ ! -x $bin ]]; then
  notify-send -a mosquitOmarchy "Convert Audio" "Converter not installed — re-run the nautilus-audio tweak."
  exit 1
fi

# The tui-kit picker (and the overwrite question, only when needed) runs in a
# real terminal; the trailing read keeps the window open to show pacpl's output.
run=(bash -c '"$0" "$@"; ec=$?; echo; read -rp "Press Enter to close…" _; exit $ec' "$bin" "${files[@]}")
if command -v foot >/dev/null 2>&1; then
  exec foot "${run[@]}"
elif command -v xterm >/dev/null 2>&1; then
  exec xterm -e "${run[@]}"
else
  notify-send -a mosquitOmarchy "Convert Audio" "No terminal found (foot or xterm)."
  exit 1
fi
PACPL

  install_nautilus_script "$SFZ_SCRIPT" <<'SFZ'
#!/usr/bin/env bash
# Make SFZ — Nautilus script.
# managed by mosquitOmarchy (tweak-nautilus-audio) — re-run the tweak to restore, --remove to delete.
set -euo pipefail

mapfile -t files < <(printf '%s\n' "${NAUTILUS_SCRIPT_SELECTED_FILE_PATHS:-}" | sed '/^$/d')
((${#files[@]})) || exit 0

bin="$(command -v makesfz || true)"
[[ -n $bin ]] || bin="$HOME/.local/bin/makesfz"
if [[ ! -x $bin ]]; then
  notify-send -a mosquitOmarchy "Make SFZ" "makesfz is not installed — re-run the nautilus-audio tweak."
  exit 1
fi

# makesfz -I asks its questions on stdin, so it needs a terminal. The trailing
# read keeps the window open to show the result.
if command -v foot >/dev/null 2>&1; then
  exec foot bash -c '"$0" -I --files "$@"; ec=$?; echo; read -rp "Press Enter to close…" _; exit $ec' "$bin" "${files[@]}"
elif command -v xterm >/dev/null 2>&1; then
  exec xterm -e bash -c '"$0" -I --files "$@"; ec=$?; echo; read -rp "Press Enter to close…" _; exit $ec' "$bin" "${files[@]}"
else
  notify-send -a mosquitOmarchy "Make SFZ" "No terminal found (foot or xterm)."
  exit 1
fi
SFZ

  ok "Nautilus: right-click → Scripts → Convert Audio (PACPL) / Make SFZ"
}

# ---------------------------------------------------------------------------
# Status / remove
# ---------------------------------------------------------------------------
show_status() {
  msg "nautilus-audio status:"
  if command -v pacpl >/dev/null 2>&1; then
    ok "pacpl present ($(pacpl --version 2>/dev/null | head -1 || true))"
  else
    warn "pacpl NOT installed"
  fi
  local c
  for c in oggenc opusenc sox flac lame wavpack ffmpeg; do
    command -v "$c" >/dev/null 2>&1 || warn "encoder missing: $c"
  done
  local m
  for m in File::Util Ogg::Vorbis::Header String::ShellQuote; do
    perl -M"$m" -e1 >/dev/null 2>&1 || warn "perl module missing: $m"
  done
  if [[ -x $MAKESFZ ]]; then ok "makesfz: $MAKESFZ"; else warn "makesfz NOT installed"; fi
  if [[ -x $CONVERT_BIN ]]; then ok "converter TUI: $CONVERT_BIN"; else warn "converter TUI NOT built"; fi
  local s
  for s in "$PACPL_SCRIPT" "$SFZ_SCRIPT"; do
    if [[ -e $s ]] && grep -qF -- "$MARK" "$s" 2>/dev/null; then
      ok "Nautilus script: $(basename "$s")"
    else
      warn "Nautilus script missing: $(basename "$s")"
    fi
  done
}

remove_all() {
  msg "Removing the Nautilus audio tools (pacpl and the encoders are left installed)…"
  local s
  for s in "$PACPL_SCRIPT" "$SFZ_SCRIPT"; do
    if [[ -e $s ]] && grep -qF -- "$MARK" "$s" 2>/dev/null; then
      rm -f "$s"
      ok "removed $(basename "$s")"
    elif [[ -e $s ]]; then
      warn "kept $(basename "$s") — not managed by mosquitOmarchy"
    fi
  done
  if [[ -e $MAKESFZ ]] && grep -q 'makesfz' "$MAKESFZ" 2>/dev/null; then
    rm -f "$MAKESFZ"
    ok "removed makesfz"
  fi
  if [[ -e $CONVERT_BIN ]]; then
    rm -f "$CONVERT_BIN"
    ok "removed the converter TUI"
  fi
  echo
  echo "pacpl and the encoders stay installed. Remove them with:"
  echo "  yay -Rns pacpl vorbis-tools opus-tools sox"
}

case "${1:-}" in
  --status) show_status; exit 0 ;;
  --remove|--uninstall) remove_all; exit 0 ;;
  -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -y|--yes) YES=1 ;;
  "") ;;
  *) err "Unknown option: $1 (supported: -y --status --remove)"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
msg "== 1/4 Audio tools (pacpl + encoders) =="
install_audio_tools

msg "== 2/4 makesfz =="
install_makesfz

msg "== 3/4 Converter TUI (tui-kit) =="
install_convert_tui

msg "== 4/4 Nautilus scripts =="
install_nautilus_scripts

echo
ok "Done. Select audio files in Nautilus → right-click → Scripts."
