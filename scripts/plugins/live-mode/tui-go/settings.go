package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Settings persisted by the Live Manager — they configure everything the
// next activation applies. The file is shell-sourceable (KEY="value"), the
// exact format live-mode and its watchdog read back via source.

// knownApps is the fixed background-app set the close-at-start list draws
// from (the same names live-mode detects while running).
var knownApps = []string{"kDrive", "qBittorrent", "Steam", "Discord", "Slack", "Spotify"}

type Settings struct {
	ThermalLimitC int      // 95|90|85|80|75 (°C)
	CloseApps     bool     // offer closing background apps at start
	CloseAppsList []string // subset of knownApps (configured app names)
	RoutingTool   bool     // park qpwgraph in the scratchpad on activation
	NoGaps        bool     // disable window gaps during the session
	SilenceNotifs bool     // DND during the session
}

func defaultSettings() Settings {
	return Settings{
		ThermalLimitC: 85,
		CloseApps:     true,
		CloseAppsList: append([]string(nil), knownApps...),
		RoutingTool:   true,
		NoGaps:        true,
		SilenceNotifs: true,
	}
}

func settingsFile() string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	return filepath.Join(home, ".config", "live-mode", "settings")
}

func loadSettings() Settings {
	s := defaultSettings()
	kv := readKV(settingsFile())
	if v, ok := kv["THERMAL_LIMIT_C"]; ok {
		if n, err := strconv.Atoi(v); err == nil {
			switch n {
			case 95, 90, 85, 80, 75:
				s.ThermalLimitC = n
			}
		}
	}
	if v, ok := kv["CLOSE_APPS"]; ok {
		s.CloseApps = v != "no"
	}
	if v, ok := kv["CLOSE_APPS_LIST"]; ok {
		var list []string
		for _, name := range splitFields(v) {
			for _, k := range knownApps {
				if stringsEqualFold(name, k) {
					list = append(list, k)
					break
				}
			}
		}
		s.CloseAppsList = list
	}
	if v, ok := kv["ROUTING_TOOL"]; ok {
		s.RoutingTool = v != "no"
	}
	if v, ok := kv["NO_GAPS"]; ok {
		s.NoGaps = v != "no"
	}
	if v, ok := kv["SILENCE_NOTIFICATIONS"]; ok {
		s.SilenceNotifs = v != "no"
	}
	return s
}

func saveSettings(s Settings) error {
	path := settingsFile()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	content := "THERMAL_LIMIT_C=\"" + itoa(s.ThermalLimitC) + "\"\n" +
		"CLOSE_APPS=\"" + boolVal(s.CloseApps) + "\"\n" +
		"CLOSE_APPS_LIST=\"" + joinFields(s.CloseAppsList) + "\"\n" +
		"ROUTING_TOOL=\"" + boolVal(s.RoutingTool) + "\"\n" +
		"NO_GAPS=\"" + boolVal(s.NoGaps) + "\"\n" +
		"SILENCE_NOTIFICATIONS=\"" + boolVal(s.SilenceNotifs) + "\"\n"
	return os.WriteFile(path, []byte(content), 0o644)
}

func hasApp(list []string, name string) bool {
	for _, a := range list {
		if a == name {
			return true
		}
	}
	return false
}

func splitFields(s string) []string {
	var out []string
	for _, f := range strings.Fields(s) {
		out = append(out, f)
	}
	return out
}

func joinFields(list []string) string {
	return strings.Join(list, " ")
}

func stringsEqualFold(a, b string) bool {
	return strings.EqualFold(a, b)
}
