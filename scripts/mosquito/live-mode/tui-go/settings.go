package main

import (
	"os"
	"os/exec"
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
	RoutingTool   bool     // park the scratchpad audio apps on activation
	// PatchbayApp fills the patchbay slot: mixbay+qpwgraph (both together,
	// the default), mixbay (the mosquito USB audio bay alone), qpwgraph
	// (the PipeWire graph alone) or mosquito-patchbay (the future native
	// routing surface). live-mode treats it as a preference: a choice that
	// is not installed falls through to whatever is.
	PatchbayApp   string
	NoGaps        bool // disable window gaps during the session
	SilenceNotifs bool // DND during the session
	SwitchTheme   bool // switch to the Live theme on activation
	// ProfilePrompt gates the power panel: with it on, choosing a power
	// profile during a live session asks first, because the watchdog reverts it
	// seconds later and silently. power-saver and ultra-save are refused either
	// way, and that refusal is not a setting.
	ProfilePrompt bool
	// FencePackages pins the machine by holding pacman's database lock for the
	// session. It is OFF by default, and that default is the point: the fence
	// used to be unconditional, and every package operation on the machine then
	// failed with "unable to lock database" for as long as the session lasted.
	// Live mode installs nothing, so the lock protected nothing. It is here for
	// the times you WANT the machine pinned, never imposed.
	FencePackages bool
}

func defaultSettings() Settings {
	return Settings{
		ThermalLimitC: 85,
		CloseApps:     true,
		CloseAppsList: append([]string(nil), knownApps...),
		RoutingTool:   true,
		PatchbayApp:   PatchbayBoth,
		NoGaps:        true,
		SilenceNotifs: true,
		SwitchTheme:   true,
		ProfilePrompt: true,
		FencePackages: false,
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
	if v, ok := kv["PATCHBAY_APP"]; ok {
		if validPatchbayApp(v) {
			s.PatchbayApp = v
		}
	}
	if v, ok := kv["NO_GAPS"]; ok {
		s.NoGaps = v != "no"
	}
	if v, ok := kv["SILENCE_NOTIFICATIONS"]; ok {
		s.SilenceNotifs = v != "no"
	}
	if v, ok := kv["SWITCH_THEME"]; ok {
		s.SwitchTheme = v != "no"
	}
	if v, ok := kv["POWER_PROFILE_PROMPT"]; ok {
		s.ProfilePrompt = v != "no"
	}
	// Matched on "yes" rather than "!= no": an unknown or empty value must
	// leave the fence OFF. Defaulting this setting to ON because the file says
	// nothing is the exact mistake the fence already made once.
	if v, ok := kv["FENCE_PACKAGES"]; ok && v == "yes" {
		s.FencePackages = true
	}
	return s
}

func saveSettings(s Settings) error {
	path := settingsFile()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	app := s.PatchbayApp
	if !validPatchbayApp(app) {
		app = PatchbayBoth
	}
	content := "THERMAL_LIMIT_C=\"" + itoa(s.ThermalLimitC) + "\"\n" +
		"CLOSE_APPS=\"" + boolVal(s.CloseApps) + "\"\n" +
		"CLOSE_APPS_LIST=\"" + joinFields(s.CloseAppsList) + "\"\n" +
		"ROUTING_TOOL=\"" + boolVal(s.RoutingTool) + "\"\n" +
		"PATCHBAY_APP=\"" + app + "\"\n" +
		"NO_GAPS=\"" + boolVal(s.NoGaps) + "\"\n" +
		"SILENCE_NOTIFICATIONS=\"" + boolVal(s.SilenceNotifs) + "\"\n" +
		"SWITCH_THEME=\"" + boolVal(s.SwitchTheme) + "\"\n" +
		"POWER_PROFILE_PROMPT=\"" + boolVal(s.ProfilePrompt) + "\"\n" +
		"FENCE_PACKAGES=\"" + boolVal(s.FencePackages) + "\"\n"
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

// Patchbay choice values. PatchbayBoth is the default: mosquito mixbay as
// the session desk tool plus qpwgraph as the PipeWire graph, parked together.
const (
	PatchbayBoth   = "mixbay+qpwgraph"
	PatchbayMixbay = "mixbay"
	PatchbayGraph  = "qpwgraph"
	PatchbayNative = "mosquito-patchbay"
)

// patchbayApps is what Left/Right cycle through on the patchbay row, in
// display order. mosquito-patchbay (the future native surface) is a valid
// stored value but not offered until it exists.
var patchbayApps = []string{PatchbayBoth, PatchbayMixbay, PatchbayGraph}

func validPatchbayApp(v string) bool {
	switch v {
	case PatchbayBoth, PatchbayMixbay, PatchbayGraph, PatchbayNative:
		return true
	}
	return false
}

// patchbayLabel is the display form of a stored choice: the combo reads
// "mixbay + qpwgraph" on screen while the file keeps the shell-safe value.
func patchbayLabel(v string) string {
	if v == PatchbayBoth {
		return "mixbay + qpwgraph"
	}
	return v
}

// lookPath is exec.LookPath behind a variable so tests can stub the machine
// without touching PATH.
var lookPath = exec.LookPath

func haveMixbay() bool {
	if _, err := lookPath("mosquito-mixbay"); err == nil {
		return true
	}
	if home, err := os.UserHomeDir(); err == nil {
		if st, err := os.Stat(filepath.Join(home, ".local", "bin", "mosquito-mixbay")); err == nil && !st.IsDir() {
			return true
		}
	}
	return false
}

func haveQpwgraph() bool {
	_, err := lookPath("qpwgraph")
	return err == nil
}

// patchbayLocked reports whether the scratchpad audio rows must stay
// greyed out: neither mixbay nor qpwgraph is on this machine, so there is
// nothing a session could park. Installing either one re-enables them.
func patchbayLocked() bool {
	return !haveMixbay() && !haveQpwgraph()
}

func nextPatchbayApp(cur string) string {
	for i, v := range patchbayApps {
		if v == cur {
			return patchbayApps[(i+1)%len(patchbayApps)]
		}
	}
	return patchbayApps[0]
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
