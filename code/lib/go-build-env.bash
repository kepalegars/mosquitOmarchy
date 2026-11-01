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
