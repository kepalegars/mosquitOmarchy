package drivers

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// ConnectionEntry is one interface ever seen in the connection log written by
// the audio foundation. It deliberately covers native, beta and unsupported
// cards: the default/priority picker is allowed to target any of them.
type ConnectionEntry struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Version  string `json:"version"`
	Match    string `json:"match"`
	Native   bool   `json:"native"`
	LastSeen string `json:"last_seen"`
}

func connectionFile() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "mosquitomixbay", "connected-interfaces.json")
}

func ConnectionLog() []ConnectionEntry {
	data, err := os.ReadFile(connectionFile())
	if err != nil {
		return nil
	}
	var out []ConnectionEntry
	if json.Unmarshal(data, &out) != nil {
		return nil
	}
	return out
}

// UsedIDs is the set of interface ids ever connected; the "Only used" list
// mode and the default picker are built from it.
func UsedIDs() map[string]bool {
	out := map[string]bool{}
	for _, e := range ConnectionLog() {
		if e.ID != "" {
			out[e.ID] = true
		}
	}
	return out
}
