#!/usr/bin/env bash
# Shared resolution + application of the wine runtime a DAW must launch under.
#
# Why this file exists: a wine VST3 editor that builds a DirectComposition
# surface dies during editor creation on stock wine-staging
# (STATUS_STACK_BUFFER_OVERRUN / c0000409 inside dcomp). Serum 2 does exactly
# that. Only the ableton-linux fork (~/.local/opt/wine-d2d1-nspa-*) has working
# DComp, so a DAW launched with the system wine cannot open that editor even
# though the plugin is installed and yabridged correctly.
#
# This was hand-fixed once in ~/.local/bin/reaper, a wrapper nothing launched,
# while the desktop entry pointed at a different wrapper that used the system
# wine -- so the fix looked applied and was not. Both launchers are generated
# from here now, and the audio plugin manager re-applies them after installing
# a plugin that is known to need this runtime.
#
# Source it, do not execute it.

# The canonical runtime's bin directory, or empty when it is not installed.
# The name is matched exactly: siblings sitting next to it are dated
# *-rollback-* safety copies and aborted *.transaction-installer.* directories,
# and a plain glob would let the aborted one sort last and win.
mosquitomarchy_nspa_wine_dir() {
  local c d
  for c in "$HOME"/.local/opt/wine-d2d1-nspa-*/bin; do
    [[ -x $c/wine ]] || continue
    d="$(basename "$(dirname "$c")")"
    [[ $d =~ ^wine-d2d1-nspa-[0-9]+(\.[0-9]+)*$ ]] || continue
    mosquitomarchy_nspa_wine_dir="$c"
  done
  printf '%s' "${mosquitomarchy_nspa_wine_dir:-}"
}

# The prefix a Windows DAW's plugins live in.
#
# This is not cosmetic. A wine VST3 is not prefix-independent: its loader hands
# its vendor's shared DLL to LoadLibrary by name, at a path compiled into the
# binary (Kilohearts -> C:\ProgramData\Kilohearts\HeartCore.core_64, 74 MB;
# iZotope bundles -> C:\Program Files\iZotope\<product>\Cores). Run the host
# under a prefix that lacks those and the plugin reports its own data missing --
# "Could not load HeartCore", "missing impulse response files" -- while the
# plugin files themselves are perfectly fine in the shared store.
#
# It also aborts the whole DAW. REAPER here was launched with the patched wine
# on PATH but WINEPREFIX unset, so it fell back to ~/.wine -- the GAMING prefix,
# last initialised by stock wine-staging 11.17 while the patched 11.13 ran on
# top of it. Wine answers a version switch by rewriting every builtin DLL
# (wineboot -u), and yabridge's Wine host process died inside that. yabridge
# then does what its own source says it does: the blocking accept() has no
# cancellation, so it calls std::terminate() and takes REAPER with it. 61 of
# the 63 aborts in that window were REAPER's plugin scanner, one process per
# wrapped plugin, all identical.
#
# So the prefix is pinned here rather than left to the environment. ~/.wine
# goes back to being the gaming prefix, which is what it was created for.
mosquitomarchy_vst_prefix() {
  local p="${MOSQUITOMARCHY_VST_PREFIX:-$HOME/.wine-vst}"
  [[ -d $p/drive_c ]] || return 1
  printf '%s' "$p"
}

# Which runtime does a DAW wrapper currently launch under?
#   prints "nspa" | "system" | "absent"
mosquitomarchy_daw_wrapper_runtime() {
  local w="$1"
  [[ -f $w ]] || { printf 'absent'; return; }
  if grep -q 'wine-d2d1-nspa' "$w" 2>/dev/null; then printf 'nspa'; else printf 'system'; fi
}

# Is a wrapper already launching under exactly this runtime dir?
mosquitomarchy_daw_wrapper_points_at() {
  local w="$1" dir="$2"
  [[ "$(mosquitomarchy_daw_wrapper_runtime "$w")" == nspa ]] || return 1
  grep -qF -- "$dir" "$w" 2>/dev/null
}

# Rewrite a DAW wrapper so it launches under the patched runtime.
#   $1 = wrapper path
#   $2 = the real binary the wrapper execs
#   $3 = "noscale" to keep the caller's GDK_* variables (REAPER wants them
#        dropped, Bitwig has always run with them)
# Returns 1 (and changes nothing) when the runtime is not installed: silently
# writing a wrapper that falls back to the system wine is what made the original
# bug invisible.
# An extra command to run just before exec, per application.
#
# REAPER's UI scale cannot follow the monitor on its own: libSwell derives one
# DPI from a single system-wide value, and X11 has no per-monitor DPI, so the
# number cannot change when the window moves. `reaper-ui-scale` writes the
# focused monitor's Hyprland scale into reaper.ini instead. It has to happen
# BEFORE the process starts, because REAPER reads ui_scale once at startup and
# writes its own value back on exit.
#
# Silent, and optional on purpose: a missing reaper-ui-scale must not stop
# REAPER from launching, so this is a plain "run it if it is there".
mosquitomarchy_daw_prelaunch() {
  case "$1" in
    reaper)
      [[ -x "$HOME/.local/bin/reaper-ui-scale" ]] \
        && "$HOME/.local/bin/reaper-ui-scale" --quiet
      ;;
  esac
  return 0
}

mosquitomarchy_write_daw_wrapper() {
  local w="$1" bin="$2" mode="${3:-}" pre="${4:-}" dir exec_line prefix
  dir="$(mosquitomarchy_nspa_wine_dir)"
  if [[ -z $dir ]]; then
    return 1
  fi
  prefix="$(mosquitomarchy_vst_prefix)" || prefix=""
  if [[ $mode == noscale ]]; then
    exec_line="exec $bin \"\$@\""
  else
    exec_line="exec /usr/bin/env -u GDK_SCALE -u GDK_DPI_SCALE -u QT_SCALE_FACTOR $bin \"\$@\""
  fi

  cat > "$w" <<EOF
#!/usr/bin/env bash
# Generated by mosquitomarchy (scripts/lib/wine-runtime-daw.bash).
# Patched wine runtime first in PATH: a DComp VST3 editor (Serum 2) cannot be
# created under stock wine-staging. Regenerate by re-running the setup, do not
# hand-edit -- an edit that drops this block turns the crash back on.
AWINE_DIR="$dir"
if [ -x "\$AWINE_DIR/wine" ]; then
  export PATH="\$AWINE_DIR:\$PATH"
fi
# The pre-launch hook has to live in the wrapper too: the call above runs in
# THIS shell while it was being written, which is the setup's shell and not the
# one REAPER will start in.
mosquitomarchy_daw_prelaunch() {
  case "\$1" in
    reaper)
      [ -x "\$HOME/.local/bin/reaper-ui-scale" ] \
        && "\$HOME/.local/bin/reaper-ui-scale" --quiet
      ;;
  esac
  return 0
}
PRELAUNCH="$pre"
if [ -n "\$PRELAUNCH" ]; then
  mosquitomarchy_daw_prelaunch "\$PRELAUNCH"
fi
# And the prefix those plugins were installed into, pinned. Without it the DAW
# falls back to ~/.wine, which is the gaming prefix: no HeartCore, no iZotope
# Cores, and a patched-runtime re-init that kills yabridge's host and aborts
# the whole DAW. ~/.wine stays the gaming prefix because that is what it is for.
VST_PREFIX="$prefix"
if [ -d "\$VST_PREFIX/drive_c" ]; then
  export WINEPREFIX="\$VST_PREFIX"
fi
$exec_line
EOF
  chmod +x "$w"
}

# Does the wrapper pin a wine prefix? A wrapper that does not is treated as
# needing a rewrite even when its runtime is already right: the two are separate
# failure modes and fixing only one leaves the other in place.
wrapper_pins_prefix() {
  local w="$1"
  [[ -f $w ]] || return 1
  grep -q 'WINEPREFIX=' "$w" 2>/dev/null
}

# And does it carry the pre-launch hook it is supposed to? A wrapper written
# before a hook existed is otherwise indistinguishable from a correct one --
# the runtime check and the prefix check both pass, so the hook would simply
# never be added until something else forced a rewrite.
wrapper_has_prelaunch() {
  local w="$1" app="$2"
  [[ -f $w ]] || return 1
  case "$app" in
    reaper) grep -q 'reaper-ui-scale' "$w" 2>/dev/null ;;
    *)      return 0 ;;
  esac
}

# Apply the runtime to every DAW wrapper we own. Idempotent: it rewrites only
# when the current state would leave a DAW on the wrong wine.
#   $1 = "quiet" to stay silent when there is nothing to do
mosquitomarchy_apply_daw_wine_runtime() {
  local quiet="${1:-}" dir rc=0 changed=0
  dir="$(mosquitomarchy_nspa_wine_dir)"
  if [[ -z $dir ]]; then
    [[ $quiet == quiet ]] || {
      echo "warning: no wine-d2d1-nspa runtime in ~/.local/opt -- DAWs keep the" >&2
      echo "         system wine, and DComp VST3 editors (Serum 2) will crash" >&2
      echo "         on open. Run the Ableton setup to install it." >&2
    }
    return 1
  fi

  # REAPER: the desktop entry cockos-reaper.desktop launches this wrapper.
  if [[ -x /usr/lib/REAPER/reaper || -x /opt/REAPER/reaper ]]; then
    local rbin="" w="$HOME/.local/bin/reaper-launch"
    [[ -x /usr/lib/REAPER/reaper ]] && rbin=/usr/lib/REAPER/reaper || rbin=/opt/REAPER/reaper
    if ! mosquitomarchy_daw_wrapper_points_at "$w" "$dir" || ! wrapper_pins_prefix "$w" \
       || ! wrapper_has_prelaunch "$w" reaper; then
      mkdir -p "$HOME/.local/bin"
      if mosquitomarchy_write_daw_wrapper "$w" "$rbin" "" reaper; then
        changed=1
      else
        rc=1
      fi
    fi
  fi

  # Bitwig: same editor, same crash, and its wrapper was hand-written with the
  # runtime path hardcoded, so it silently broke on the next version bump.
  if [[ -x /usr/bin/bitwig-studio ]]; then
    local w="$HOME/.local/bin/bitwig-studio"
    if ! mosquitomarchy_daw_wrapper_points_at "$w" "$dir" || ! wrapper_pins_prefix "$w"; then
      if mosquitomarchy_write_daw_wrapper "$w" /usr/bin/bitwig-studio noscale ""; then
        changed=1
      else
        rc=1
      fi
    fi
  fi

  if (( changed )) && [[ $quiet != quiet ]]; then
    echo "DAW wine runtime set to the patched build: $dir"
  fi
  return $rc
}
