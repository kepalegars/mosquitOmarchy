#!/usr/bin/env bash
# Install both Omarchy credential dialogs from source without `just`:
# omaskpass speaks SSH_ASKPASS; omapin speaks GnuPG's pinentry Assuan protocol.
set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "Run this as the desktop user, not with sudo." >&2; exit 1; }
command -v omarchy >/dev/null || { echo "omarchy is required" >&2; exit 1; }
command -v cargo >/dev/null || { echo "cargo is required to build the two binaries" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required by omarchy plugin management" >&2; exit 1; }

plugins_dir="$HOME/.config/omarchy/plugins"
bin_dir="$HOME/.local/bin"
env_dir="$HOME/.config/environment.d"
env_file="$env_dir/90-ssh-askpass.conf"
gnupg_dir="${GNUPGHOME:-$HOME/.gnupg}"
agent_conf="$gnupg_dir/gpg-agent.conf"

install_plugin() {
  local id="$1" url="$2"
  if omarchy plugin list --json 2>/dev/null | jq -e --arg id "$id" '.[] | select(.id == $id)' >/dev/null; then
    omarchy plugin enable "$id" >/dev/null
  else
    omarchy plugin add "$url" --enable --yes
  fi
}

install_plugin lbssousa.omaskpass https://github.com/lbssousa/omaskpass.git
install_plugin lbssousa.omapin https://github.com/lbssousa/omapin.git

for app in omaskpass omapin; do
  source_dir="$plugins_dir/lbssousa.$app"
  [[ -f "$source_dir/Cargo.toml" ]] || { echo "Source missing: $source_dir/Cargo.toml" >&2; exit 1; }
  cargo build --release --manifest-path "$source_dir/Cargo.toml"
  install -Dm755 "$source_dir/target/release/$app" "$bin_dir/$app"
done

mkdir -p "$env_dir"
if [[ -e $env_file ]] && ! cmp -s "$env_file" <(printf 'SSH_ASKPASS=%s\nSSH_ASKPASS_REQUIRE=prefer\n' "$bin_dir/omaskpass"); then
  cp -n "$env_file" "$env_file.bak.$(date +%Y%m%d%H%M%S)"
fi
tmp=$(mktemp "$env_dir/.90-ssh-askpass.XXXXXX")
printf 'SSH_ASKPASS=%s\nSSH_ASKPASS_REQUIRE=prefer\n' "$bin_dir/omaskpass" > "$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$env_file"

mkdir -p "$gnupg_dir"
chmod 0700 "$gnupg_dir"
if [[ -e $agent_conf ]] && ! grep -qF '# >>> mosquitOmarchy omaskpinpass >>>' "$agent_conf"; then
  cp -n "$agent_conf" "$agent_conf.bak.$(date +%Y%m%d%H%M%S)"
fi
tmp=$(mktemp "$gnupg_dir/.gpg-agent.conf.XXXXXX")
if [[ -f $agent_conf ]]; then
  awk '
    /^# >>> mosquitOmarchy omaskpinpass >>>$/ { skip=1; next }
    /^# <<< mosquitOmarchy omaskpinpass <<</ { skip=0; next }
    !skip { print }
  ' "$agent_conf" > "$tmp"
fi
cat >> "$tmp" <<EOF
# >>> mosquitOmarchy omaskpinpass >>>
pinentry-program $bin_dir/omapin
# <<< mosquitOmarchy omaskpinpass <<<
EOF
chmod 0600 "$tmp"
mv "$tmp" "$agent_conf"
gpgconf --reload gpg-agent 2>/dev/null || echo "Note: reload GPG agent after the next login."

echo "omaskpass (SSH askpass) and omapin (GnuPG pinentry) installed from source; no just required."
echo "SSH_ASKPASS_REQUIRE=prefer is set in $env_file; log out and back in to load it."
echo "GnuPG now uses $bin_dir/omapin via $agent_conf."
