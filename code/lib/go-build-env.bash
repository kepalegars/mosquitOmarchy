# Keep every Go module/download/build cache inside mosquitOmarchy's own cache
# directory. Without this, the first `go build` in an installer creates
# ~/go/pkg/mod (the Go default GOPATH) in the user's home — 42 MB here, and it
# looks like the app dropped a scratch directory it never cleans.
#
# Source this from any script that runs `go build`. It only affects that script
# and its children; the user's global `go env` is untouched.

_mq_go_cache="${XDG_CACHE_HOME:-$HOME/.cache}/mosquitomarchy"
export GOPATH="$_mq_go_cache/go"
export GOMODCACHE="$_mq_go_cache/go/pkg/mod"
export GOCACHE="$_mq_go_cache/go-build"

# mise ships a `go` shim that refuses to run inside this repo until its
# .mise.toml is trusted, which broke every TUI build ("Config files are not
# trusted"). Trust this repo's own config for the build only, without writing
# persistent mise state.
_mq_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f "$_mq_repo/.mise.toml" ]]; then
  export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:+$MISE_TRUSTED_CONFIG_PATHS:}$_mq_repo/.mise.toml"
fi
