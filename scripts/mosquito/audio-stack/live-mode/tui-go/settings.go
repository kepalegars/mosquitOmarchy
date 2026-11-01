package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Settings persisted by the Live Manager — they configure everything the
// next activation applies. The file is shell-sourceable (KEY="value"), the
// exact format live-mode and its watchdog read back via source.

// knownApps is the historical default close-at-start set. The chooser itself
// lists what is actually installed (installedApps); these names only seed the
// default selection and keep settings written by older versions meaningful.
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
	// seconds later and silently. power-saver is refused either
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
		// Keep every saved name, including apps that are not installed right
		// now: they stay silent in the chooser and come back ticked when the
		// app is reinstalled. Filtering against a hardcoded list used to erase
		// them for good.
		s.CloseAppsList = parseAppList(v)
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

// parseAppList accepts both settings formats: the old space-separated list and
// the current "|"-separated one, which allows app names containing spaces.
func parseAppList(v string) []string {
	raw := strings.Fields(v)
	if strings.Contains(v, "|") {
		raw = strings.Split(v, "|")
	}
	seen := map[string]bool{}
	out := make([]string, 0, len(raw))
	for _, name := range raw {
		name = strings.TrimSpace(name)
		if name == "" || seen[name] {
			continue
		}
		seen[name] = true
		out = append(out, name)
	}
	return out
}

// joinFields writes names with a "|" delimiter so "Visual Studio Code" stays
// one entry. Commas/colons occur in real app names; "|" does not.
func joinFields(list []string) string {
	return strings.Join(list, "|")
}

// installedApps lists the applications shown in the Omarchy app menu: every
// visible [Desktop Entry] of Type=Application in the XDG application dirs.
// Hidden/NoDisplay entries are skipped, which is exactly what the menu does.
func installedApps() []string {
	dirs := []string{}
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, ".local", "share", "applications"))
	}
	if data := os.Getenv("XDG_DATA_HOME"); data != "" {
		dirs = append(dirs, filepath.Join(data, "applications"))
	}
	dataDirs := os.Getenv("XDG_DATA_DIRS")
	if dataDirs == "" {
		dataDirs = "/usr/local/share:/usr/share"
	}
	for _, d := range strings.Split(dataDirs, ":") {
		if d != "" {
			dirs = append(dirs, filepath.Join(d, "applications"))
		}
	}
	seen := map[string]bool{}
	var apps []string
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, ent := range entries {
			if ent.IsDir() || !strings.HasSuffix(ent.Name(), ".desktop") {
				continue
			}
			if name, ok := desktopAppName(filepath.Join(dir, ent.Name())); ok && !seen[name] {
				seen[name] = true
				apps = append(apps, name)
			}
		}
	}
	sort.Slice(apps, func(i, j int) bool { return strings.ToLower(apps[i]) < strings.ToLower(apps[j]) })
	return apps
}

// desktopAppName returns an app's menu name when the entry is a visible
// application. Only the [Desktop Entry] section counts; the localized Name[xx]
// keys are ignored on purpose so the stored name does not change with locale.
func desktopAppName(path string) (string, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	section, name, kind := "", "", ""
	hidden := false
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = line
			continue
		}
		if section != "[Desktop Entry]" || line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		val = strings.TrimSpace(val)
		switch key {
		case "Name":
			if name == "" {
				name = val
			}
		case "Type":
			kind = val
		case "NoDisplay", "Hidden":
			if val == "true" {
				hidden = true
			}
		}
	}
	return name, name != "" && kind == "Application" && !hidden
}
