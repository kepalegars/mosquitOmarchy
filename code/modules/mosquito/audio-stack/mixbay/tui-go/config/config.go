// Package config resolves the one Mixbay configuration root. Every package
// must use it instead of joining $HOME by hand, so a test or a non-standard
// install ($MIXBAY_CONFIG_DIR) never splits state across two trees.
package config

import (
	"os"
	"path/filepath"
)

// Dir is ~/.config/mosquitomixbay, or $MIXBAY_CONFIG_DIR when set.
func Dir() string {
	if v := os.Getenv("MIXBAY_CONFIG_DIR"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "mosquitomixbay")
}
