package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	tuikit "mosquitomarchy.local/tui-kit"
)

func actionsBin() string {
	exe, err := os.Executable()
	if err == nil {
		cand := filepath.Join(filepath.Dir(exe), "mosquito-audio-plugin-manager-actions")
		if _, statErr := os.Stat(cand); statErr == nil {
			return cand
		}
	}
	return "mosquito-audio-plugin-manager-actions"
}

// runQuickStdin is runQuick with something on the action's standard input.
//
// Needed for the per-plugin fix verbs: the set of plugins a partial fix reaches
// is a LIST whose contents the fix's own recorded state decides, and inventing
// an argument separator between "the fixes" and "the plugins" would be a format
// to get wrong.
func runQuickStdin(stdin string, args ...string) ([]byte, error) {
	cmd := exec.Command(actionsBin(), args...)
	cmd.Stdin = strings.NewReader(stdin)
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		if errb.Len() > 0 {
			return nil, errAction{msg: errb.String()}
		}
		return nil, err
	}
	return out.Bytes(), nil
}

func runQuick(args ...string) ([]byte, error) {
	cmd := exec.Command(actionsBin(), args...)
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		if errb.Len() > 0 {
			return nil, errAction{msg: errb.String()}
		}
		return nil, err
	}
	return out.Bytes(), nil
}

type errAction struct{ msg string }

func (e errAction) Error() string { return e.msg }

type Item struct {
	Display string `json:"display"`
	Value   string `json:"value"`
	// Kind + Parent describe the role of this row in the uninstall tree
	// produced by list-uninstallable. Kind is "folder" for a wine install
	// root (whose Value starts with "win:" — picking it removes every
	// file the installer dropped in one shot) or "plugin" for an
	// individual plugin file inside or outside of one of those folders.
	// Parent is the Value of the folder row a plugin belongs under
	// (empty string means "standalone — no parent installer"); the Go
	// TUI uses it to render the indented tree, with the folder row
	// first and its sub-plugins nested below.
	Kind   string `json:"kind"`
	Parent string `json:"parent"`
	// Formats is the comma-separated list of formats this plugin is installed
	// in ("vst2,vst3,clap"), carried on the row so the tree can show it.
	//
	// This is the replacement for the three identical rows the list used to
	// emit for a plugin present in three formats: the user asked for the name
	// and the formats, not the same name three times.
	Formats string `json:"formats"`
}

// FormatSuffix renders the format list for a plugin row, or "" when there is
// nothing to say. Short names only ("v2" for vst2) so the tree stays narrow:
// these lists are the widest rows on the page and there can be a dozen per
// folder.
func (i Item) FormatSuffix() string { return formatSuffix(i.Formats) }

func formatSuffix(formats string) string {
	if formats == "" {
		return ""
	}
	parts := strings.Split(formats, ",")
	short := make([]string, 0, len(parts))
	for _, f := range parts {
		switch strings.TrimSpace(f) {
		case "vst2":
			short = append(short, "v2")
		case "vst3":
			short = append(short, "v3")
		case "clap":
			short = append(short, "clap")
		case "":
			continue
		default:
			short = append(short, f)
		}
	}
	if len(short) == 0 {
		return ""
	}
	return "  [" + strings.Join(short, " ") + "]"
}

type PrefixItem struct {
	Path  string `json:"path"`
	Label string `json:"label"`
}

type PrefixedPlugin struct {
	Display string `json:"display"`
	Key     string `json:"key"`
	Prefix  string `json:"prefix"`
}

type ExecToggleItem struct {
	Display string `json:"display"`
	Value   string `json:"value"`
	Shown   bool   `json:"shown"`
}

// PluginItem is one row of the unified Plugin list -- list-all-plugins /
// set-sort-and-list's jq-emitted shape (origin: "vst"|"native", format:
// e.g. "vst2"/"lv2"/"clap", enabled: false when hidden/disabled but still
// tracked by the manager). Kind/Parent mirror the uninstall tree's own row
// shape ("folder" rows carry the wine-program folder, plugin rows carry the
// Parent folder Value), so the setup list can reuse the exact same
// uninstallTree/treeItemsToPicker grouping the uninstall screen uses.
type PluginItem struct {
	Display string `json:"display"`
	Value   string `json:"value"`
	Origin  string `json:"origin"`
	Format  string `json:"format"`
	Enabled bool   `json:"enabled"`
	Kind    string `json:"kind"`
	Parent  string `json:"parent"`
	// Vendor is the folder this plugin groups under, and Formats the
	// comma-separated list it is installed in ("vst2,vst3,clap").
	//
	// Both exist because the flat list used to emit ONE ROW PER FILE, so a
	// plugin present as vst2 + vst3 + clap appeared three times under the same
	// name: the same plugin had to be picked three times to act on it, and a
	// vendor's count read as a file count rather than a plugin count.
	Vendor string `json:"vendor"`
	// Formats is the display side of that merge — it is what the user asked to
	// see instead of three identical rows: the name, and which formats it is
	// in.
	Formats string `json:"formats"`
	// Variants is every installed file of this plugin, semicolon-separated
	// ("vst:<type>:<path>"). One row acts on all of them, which is the point:
	// hiding or showing "FabFilter Pro-Q" should not mean doing it three times.
	Variants string `json:"variants"`
}

// AllValues returns every installed file of the plugin: its own value plus the
// variants the backend grouped under it. Acting on a plugin means acting on all
// of its formats — picking only the first would hide the vst2 copy and leave the
// vst3 one in the DAW.
func (p PluginItem) AllValues() []string {
	seen := map[string]bool{}
	var out []string
	add := func(v string) {
		v = strings.TrimSpace(v)
		if v == "" || seen[v] {
			return
		}
		seen[v] = true
		out = append(out, v)
	}
	add(p.Value)
	for _, v := range strings.Split(p.Variants, ";") {
		add(v)
	}
	return out
}

type Status struct {
	// AutoFixOn / FixPromptOn mirror the backend's fix-prefs file. Both default
	// to true when the read fails, because the backend's own default is "on" and
	// a failed read must not quietly disable a feature.
	AutoFixOn          bool   `json:"auto_fix_on"`
	FixPromptOn        bool   `json:"fix_prompt_on"`
	FilePicker         string `json:"file_picker"`
	PluginWinHandler   string `json:"plugin_win_handler"`
	SuperfileInstalled bool   `json:"superfile_installed"`
	HideVst2           bool   `json:"hide_vst2"`
	Hide32Bit          bool   `json:"hide_32bit"`
	SortMode           string `json:"sort_mode"`
	PluginsRoot        string `json:"plugins_root"`
	DownloadsDir       string `json:"downloads_dir"`
	WizardDone         bool   `json:"wizard_done"`
	QuarantineEntries  int    `json:"quarantine_entries"`
}

type statusMsg struct {
	status Status
	err    error
	skip   bool
}
type itemsMsg struct {
	kind  string
	items []Item
	err   error
}
type prefixesMsg struct {
	items []PrefixItem
	err   error
}
type prefixedPluginsMsg struct {
	items []PrefixedPlugin
	err   error
}
type execToggleMsg struct {
	items []ExecToggleItem
	err   error
}
type textMsg struct {
	kind string
	text string
	err  error
}
type pathMsg struct {
	kind string
	path string
	err  error
}
type actionOKMsg struct{ what string }
type actionErrMsg struct{ err error }

// pluginListMsg carries a fetch/re-sort of the unified Plugin list. mode is
// only set when the result came from an `s` sort-cycle (cycleSortCmd) -- it
// tells the model which sort mode is now active, since the bash side already
// persisted it.
// installFixesCheckMsg carries the fixes catalog fetched right after a plugin
// was installed, plus the vendor it belongs to when that is known.
type installFixesCheckMsgVendor struct{}

type pluginListMsg struct {
	items []PluginItem
	mode  string
	err   error
}

// pluginSaveDoneMsg reports the result of committing hide/show changes made
// via Tab in the Plugin list (see saveHiddenChangesCmd).
type pluginSaveDoneMsg struct {
	what string
	err  error
}

func decodeJSONLines[T any](out []byte) ([]T, error) {
	var items []T
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		var t T
		if err := json.Unmarshal(line, &t); err != nil {
			return nil, err
		}
		items = append(items, t)
	}
	return items, sc.Err()
}

func fetchStatus() tea.Cmd {
	return fetchStatusMsg
}

// fetchPluginFolders loads the merged, vendor-grouped plugin list as Items, for
// the Uninstall screen. It is the same list the Installed-plugins and fixes
// screens use, so a plugin is one row everywhere — the uninstall tree used to
// list a plugin once per installed format, so removing "FabFilter Pro-Q" meant
// picking the same name three times.
func fetchPluginFolders(kind string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("list-plugin-folders")
		if err != nil {
			return itemsMsg{kind: kind, err: err}
		}
		items, err := decodeJSONLines[Item](out)
		return itemsMsg{kind: kind, items: items, err: err}
	}
}

func fetchItems(kind string, args ...string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick(args...)
		if err != nil {
			return itemsMsg{kind: kind, err: err}
		}
		items, err := decodeJSONLines[Item](out)
		return itemsMsg{kind: kind, items: items, err: err}
	}
}

func fetchPrefixes() tea.Cmd {
	return prefixListCmd("")
}

// prefixListCmd lists the wine prefixes; an optional installer path switches
// on the RECOMMENDED marker for the prefix that matches the plugin.
func prefixListCmd(installer string) tea.Cmd {
	return func() tea.Msg {
		args := []string{"list-prefixes"}
		if installer != "" {
			args = append(args, installer)
		}
		out, err := runQuick(args...)
		if err != nil {
			return prefixesMsg{err: err}
		}
		items, err := decodeJSONLines[PrefixItem](out)
		return prefixesMsg{items: items, err: err}
	}
}

func fetchPrefixedPlugins() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("list-prefixed-plugins")
		if err != nil {
			return prefixedPluginsMsg{err: err}
		}
		items, err := decodeJSONLines[PrefixedPlugin](out)
		return prefixedPluginsMsg{items: items, err: err}
	}
}

func fetchExecToggle() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("list-executables-toggle")
		if err != nil {
			return execToggleMsg{err: err}
		}
		items, err := decodeJSONLines[ExecToggleItem](out)
		return execToggleMsg{items: items, err: err}
	}
}

func fetchText(kind string, args ...string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick(args...)
		if err != nil {
			return textMsg{kind: kind, err: err}
		}
		if len(bytes.TrimSpace(out)) == 0 {
			return textMsg{kind: kind, err: fmt.Errorf("%s: no output", args[0])}
		}
		var v struct {
			Text string `json:"text"`
		}
		if err := json.Unmarshal(out, &v); err != nil {
			return textMsg{kind: kind, err: fmt.Errorf("%s: %w", args[0], err)}
		}
		return textMsg{kind: kind, text: v.Text}
	}
}

func fetchPath(kind string, args ...string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick(args...)
		if err != nil {
			return pathMsg{kind: kind, err: err}
		}
		if len(bytes.TrimSpace(out)) == 0 {
			return pathMsg{kind: kind, err: fmt.Errorf("%s: no output", args[0])}
		}
		var v struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal(out, &v); err != nil {
			return pathMsg{kind: kind, err: fmt.Errorf("%s: %w", args[0], err)}
		}
		return pathMsg{kind: kind, path: v.Path}
	}
}

// pickFileViaSuperfileEmbedded runs superfile IN this program's own terminal
// (tea.ExecProcess suspends the Bubble Tea render loop, hands the terminal
// to the child process, then resumes once it exits) instead of shelling out
// to the bash action, which used to spawn a brand-new terminal window --
// visually external to the running TUI and, while it was up, left the TUI's
// own window sitting there doing nothing underneath it.
// adoptPluginsCmd registers every plugin already on disk into the log, in ONE
// pass, and says how many were added.
//
// This is the answer to a machine whose plugins predate the manager: the log is
// empty, so every one of them counts as an "orphan", and the startup sweep
// offers them again on EVERY launch. Tick-by-tick was never a workable shape
// for that — the screen was one row per file, so a suite installed outside the
// manager came back as dozens of near-identical rows, every time.
func adoptPluginsCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("adopt-plugins")
		if err != nil {
			return adoptPluginsMsg{err: err}
		}
		var v struct {
			Registered int `json:"registered"`
		}
		if err := json.Unmarshal(bytes.TrimSpace(out), &v); err != nil {
			return adoptPluginsMsg{err: err}
		}
		return adoptPluginsMsg{n: v.Registered}
	}
}

// adoptPluginsMsg reports the outcome. The result is a TOAST, not a screen: the
// user asked for the log to be brought up to date, not for a list to work
// through, and once it has run there is nothing left to pick.
type adoptPluginsMsg struct {
	n   int
	err error
}

func pickFileViaSuperfileEmbedded(startDir string) tea.Cmd {
	tmp, err := os.CreateTemp("", "audio-plugin-manager-pick-*")
	if err != nil {
		return func() tea.Msg { return pathMsg{kind: "pick-file", err: err} }
	}
	tmpPath := tmp.Name()
	tmp.Close()
	os.Remove(tmpPath) // spf writes this path itself on pick; must not pre-exist as a stale non-empty file
	if startDir == "" {
		startDir, _ = os.UserHomeDir()
	}
	cmd := exec.Command("spf", "--chooser-file", tmpPath, startDir)
	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		defer os.Remove(tmpPath)
		if err != nil {
			return pathMsg{kind: "pick-file", err: err}
		}
		data, rerr := os.ReadFile(tmpPath)
		if rerr != nil || len(bytes.TrimSpace(data)) == 0 {
			return pathMsg{kind: "pick-file"} // quit/Esc without picking -- a cancel, not an error
		}
		return pathMsg{kind: "pick-file", path: strings.TrimSpace(string(data))}
	})
}

type reconcileMissingMsg struct {
	labels []string
	keys   []string
}

func reconcileMissingCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("reconcile-missing")
		if err != nil {
			return reconcileMissingMsg{}
		}
		type row struct {
			Key   string `json:"key"`
			Label string `json:"label"`
		}
		rows, _ := decodeJSONLines[row](out)
		labels := make([]string, len(rows))
		keys := make([]string, len(rows))
		for i, r := range rows {
			labels[i] = r.Label
			keys[i] = r.Key
		}
		return reconcileMissingMsg{labels: labels, keys: keys}
	}
}

type reconcileOrphansMsg struct{ items []Item }

func reconcileOrphansCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("reconcile-orphans")
		if err != nil {
			return reconcileOrphansMsg{}
		}
		items, _ := decodeJSONLines[Item](out)
		return reconcileOrphansMsg{items: items}
	}
}

// rescanMsg carries the combined result of a manually triggered "Rescan for
// untracked plugins" (Settings) -- unlike the automatic startup checks
// (reconcileMissingCmd/reconcileOrphansCmd, silent when nothing's found),
// an explicit manual rescan always reports something back, even "nothing
// found".
type rescanMsg struct {
	labels []string
	keys   []string
	items  []Item
}

func rescanCmd() tea.Cmd {
	return func() tea.Msg {
		var labels, keys []string
		if out, err := runQuick("reconcile-missing"); err == nil {
			type row struct {
				Key   string `json:"key"`
				Label string `json:"label"`
			}
			rows, _ := decodeJSONLines[row](out)
			for _, r := range rows {
				labels = append(labels, r.Label)
				keys = append(keys, r.Key)
			}
		}
		var items []Item
		if out, err := runQuick("reconcile-orphans"); err == nil {
			items, _ = decodeJSONLines[Item](out)
		}
		return rescanMsg{labels: labels, keys: keys, items: items}
	}
}

// cleanupReport is the `cleanup` action's single JSON report (the bash side
// prints human lines then one final machine-readable line).
type cleanupReport struct {
	Kept       []string `json:"kept"`
	Registered []string `json:"registered"`
	Desktops   []string `json:"desktops"`
	Deduped    []string `json:"deduped"`
}

type cleanupMsg struct {
	report cleanupReport
	err    error
}

// cleanupCmd runs the one-shot non-destructive "cleanup!" pass and reports
// what was fixed (missing kept, orphans registered, debris launchers removed).
func cleanupCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("cleanup")
		if err != nil {
			return cleanupMsg{err: err}
		}
		var report cleanupReport
		lines := bytes.Split(bytes.TrimSpace(out), []byte{'\n'})
		if n := len(lines); n > 0 {
			_ = json.Unmarshal(bytes.TrimSpace(lines[n-1]), &report)
		}
		return cleanupMsg{report: report}
	}
}

// quarantineDirReport is one emptied quarantine folder as reported by the
// `empty-quarantine` action.
type quarantineDirReport struct {
	Dir     string `json:"dir"`
	Removed int    `json:"removed"`
	Bytes   int64  `json:"bytes"`
}

// quarantineReport is the `empty-quarantine` action's single JSON report.
type quarantineReport struct {
	Dirs []quarantineDirReport `json:"dirs"`
}

type quarantineClearMsg struct {
	report quarantineReport
	out    []byte // full run output, shown by the result prompt's "See log"
	err    error
}

// quarantineClearCmd runs the destructive "empty the quarantine" pass and
// reports which folder hold how many entries (and how many bytes) were
// permanently deleted.
func quarantineClearCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("empty-quarantine")
		if err != nil {
			return quarantineClearMsg{err: err}
		}
		var report quarantineReport
		lines := bytes.Split(bytes.TrimSpace(out), []byte{'\n'})
		if n := len(lines); n > 0 {
			_ = json.Unmarshal(bytes.TrimSpace(lines[n-1]), &report)
		}
		return quarantineClearMsg{report: report, out: out}
	}
}

// humanBytes renders a byte count the way the rest of the suite does: the
// most readable binary unit, one decimal, no trailing space.
func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return strconv.FormatInt(n, 10) + " B"
	}
	div, exp := int64(unit), 0
	for m := n / unit; m >= unit; m /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "KMGTPE"[exp])
}

// reconcileDoneMsg reports a "keep in log / remove everywhere" decision
// applied through remove-missing — a dedicated message because the remove
// path pops TWO confirm screens (the shared-log prompt and its second
// "really?" prompt) where the generic actionOKMsg pops a single one.
type reconcileDoneMsg struct {
	what string
	err  error
}

func removeMissingCmd(what string, keys []string) tea.Cmd {
	return func() tea.Msg {
		args := append([]string{"remove-missing"}, keys...)
		if _, err := runQuick(args...); err != nil {
			return reconcileDoneMsg{err: err}
		}
		return reconcileDoneMsg{what: what}
	}
}

// toggleExecAndRefetch runs the toggle then re-lists in one command, so the
// screen can refresh in place without popping back to the main menu —
// matches manage_executables()'s own "keep picking to toggle several"
// bash behavior.
func toggleExecAndRefetch(exe string) tea.Cmd {
	return func() tea.Msg {
		_, _ = runQuick("toggle-executable", exe)
		out, err := runQuick("list-executables-toggle")
		if err != nil {
			return execToggleMsg{err: err}
		}
		items, _ := decodeJSONLines[ExecToggleItem](out)
		return execToggleMsg{items: items}
	}
}

// addOrphanAndRefetch mirrors toggleExecAndRefetch for the reconcile
// "tick to add" screen — same "stay and keep picking" shape.
// reconcileResultMsg bundles the visible feedback of an orphan
// registration with the refreshed orphan list: what the action printed
// ("added to the manager: X" / the bash error), plus the new orphan set
// (nil = no orphan left → the screen pops).
type reconcileResultMsg struct {
	items []Item
	ok    string
	err   error
}

func addOrphanAndRefetch(file string) tea.Cmd {
	return func() tea.Msg {
		// Capture the register step's output: a silent failure here left
		// the picker identical to the previous frame, which read as
		// "Enter does nothing" (the user's report while stuck on the
		// ScaleFinder orphan). The bash action prints a line
		// ("added to the manager: <name>") on success or an error to
		// stderr — surface both as a visible toast.
		addOut, addErr := runQuick("add-orphan", file)
		out, err := runQuick("reconcile-orphans")
		if addErr != nil {
			return reconcileResultMsg{err: addErr}
		}
		if err != nil {
			return reconcileResultMsg{err: err}
		}
		items, _ := decodeJSONLines[Item](out)
		what := strings.TrimSpace(string(addOut))
		if what == "" {
			what = "added: " + filepath.Base(file)
		}
		return reconcileResultMsg{items: items, ok: what}
	}
}

// setFilePickerAndRefetch writes the file-picker preference then re-fetches
// status in one command, so the screen (scrSettings) can refresh in place
// without popping back to the main menu — same "stay and refresh" shape as
// toggleExecAndRefetch/addOrphanAndRefetch above.
func setFilePickerAndRefetch(mode string) tea.Cmd {
	return func() tea.Msg {
		_, _ = runQuick("set-file-picker", mode)
		return fetchStatusMsg()
	}
}

// setDownloadsDirAndRefetch mirrors setFilePickerAndRefetch: write the pref
// then re-fetch status in one command, so scrSettings refreshes in place.
func setDownloadsDirAndRefetch(dir string) tea.Cmd {
	return func() tea.Msg {
		_, _ = runQuick("set-downloads-dir", dir)
		return fetchStatusMsg()
	}
}

// pickFolderCmd runs the bash pick-folder verb -- used for both Settings
// folder pickers (Plugins folder / default plugin installation file directory). Folder-picking always
// goes through the native/zenity dialog regardless of the file-picker
// preference: superfile has no clean way to pick a bare folder (its
// --chooser-file only fires on "opening" a FILE, and --print-last-dir's
// output can't be captured without breaking its live terminal takeover via
// tea.ExecProcess), so this is a deliberate simplification.
func pickFolderCmd(kind, title, start string) tea.Cmd {
	return fetchPath(kind, "pick-folder", title, start)
}

// wizardBrowseThenPick runs superfile IN this terminal so the user can
// browse to the plugins folder they want (same embedded-terminal trick as
// pickFileViaSuperfileEmbedded). superfile's --chooser-file only fires on
// "opening" a FILE, so it can't return a bare directory — the follow-up
// native folder dialog (the same one the Settings screens use) captures
// the real choice after browsing; the returned message just marks
// "browsing done".
func wizardBrowseThenPick() tea.Cmd {
	start, _ := os.UserHomeDir()
	cmd := exec.Command("spf", start)
	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		return pathMsg{kind: "wizard-browse-done"}
	})
}

// toggleHideVst2AndRefetch and toggleHide32BitAndRefetch mirror
// setFilePickerAndRefetch: write the pref then re-fetch status in one
// command, so scrVstMenu refreshes in place instead of popping back.
func toggleHideVst2AndRefetch() tea.Cmd {
	return func() tea.Msg {
		_, _ = runQuick("toggle-hide-vst2")
		return fetchStatusMsg()
	}
}

func toggleHide32BitAndRefetch() tea.Cmd {
	return func() tea.Msg {
		_, _ = runQuick("toggle-hide-32bit")
		return fetchStatusMsg()
	}
}

// fetchStatusMsg is the synchronous body fetchStatus()'s tea.Cmd wraps --
// factored out so the *AndRefetch helpers above can call it directly after
// their own write, in the same command, instead of a second round trip.
func fetchStatusMsg() tea.Msg {
	out, err := runQuick("status-json")
	if err != nil {
		return statusMsg{err: err}
	}
	if len(bytes.TrimSpace(out)) == 0 {
		return statusMsg{skip: true}
	}
	var s Status
	if err := json.Unmarshal(out, &s); err != nil {
		return statusMsg{err: fmt.Errorf("status-json: %w", err)}
	}
	return statusMsg{status: s}
}

// nativeInstallCmd installs a native (LV2/CLAP/VST3, or archive containing
// one) plugin file already picked -- reached generically via the
// auto-detecting "pick-file" pathMsg handling in model.go, so it reports
// through the same actionOKMsg/actionErrMsg contract the wine install flow
// eventually reaches too (both end up resetting nav back to scrMain).
func nativeInstallCmd(path string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("install-native-plugin", path)
		if err != nil {
			return actionErrMsg{err: err}
		}
		var v struct {
			Path string `json:"path"`
		}
		_ = json.Unmarshal(out, &v)
		return actionOKMsg{what: "plugin installed: " + filepath.Base(v.Path)}
	}
}

// fetchAllPlugins loads the unified Plugin list (VST + native together).
//
// It asks for list-plugin-folders, which merges the formats of one plugin into
// a single row carrying the formats it is installed in. The older
// list-all-plugins emitted one row per FILE, so a plugin present as
// vst2 + vst3 + clap appeared three times under the same name.
func fetchAllPlugins() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("list-plugin-folders")
		if err != nil {
			return pluginListMsg{err: err}
		}
		items, err := decodeJSONLines[PluginItem](out)
		return pluginListMsg{items: items, err: err}
	}
}

// cycleSortCmd is the btop-style live sort-cycle (the `s` key on the
// Installed-plugins and Uninstall screens): sets the sort mode then
// immediately re-lists, in one round trip.
func cycleSortCmd(mode string) tea.Cmd {
	return func() tea.Msg {
		// Set the sort, then read the SAME grouped list the first load used —
		// switching sort must not change the rows from merged-per-plugin back
		// to one-per-file.
		if _, err := runQuick("set-sort-and-list", mode); err != nil {
			return pluginListMsg{err: err, mode: mode}
		}
		out, err := runQuick("list-plugin-folders")
		if err != nil {
			return pluginListMsg{err: err, mode: mode}
		}
		items, err := decodeJSONLines[PluginItem](out)
		return pluginListMsg{items: items, mode: mode, err: err}
	}
}

// targetKindPath splits a unified plugin value ("vst:<type>:<path>" or
// "native:<path>") back into which toggle verb applies and the bare path
// that verb expects.
func targetKindPath(value string) (kind, path string) {
	switch {
	case strings.HasPrefix(value, "vst:"):
		rest := strings.TrimPrefix(value, "vst:")
		if i := strings.IndexByte(rest, ':'); i >= 0 {
			return "vst", rest[i+1:]
		}
		return "vst", rest
	case strings.HasPrefix(value, "native:"):
		return "native", strings.TrimPrefix(value, "native:")
	}
	return "", value
}

// pluginPathOf returns the bare filesystem path behind a self-describing
// list value ("vst:<type>:<path>" or "native:<path>"), for display in the
// post-install fixes prompt.
func pluginPathOf(value string) string {
	_, path := targetKindPath(value)
	return path
}

// pluginStemOf reduces any unified list value to the canonical product stem
// the fixes state records fixes under — the exact Go mirror of the bash
// side's fix_plugin_canonical(): strip the "vst:<type>:"/"native:"/"win:"
// prefix, take the basename, then drop everything from the first dot. It is
// what lets the fixes plugin chooser match a row value against the stems
// returned by list-applied-fix-plugins.
func pluginStemOf(value string) string {
	p := value
	switch {
	case strings.HasPrefix(p, "vst:"):
		p = strings.TrimPrefix(p, "vst:")
		if i := strings.IndexByte(p, ':'); i >= 0 {
			p = p[i+1:]
		}
	case strings.HasPrefix(p, "native:"):
		p = strings.TrimPrefix(p, "native:")
	case strings.HasPrefix(p, "win:"):
		p = strings.TrimPrefix(p, "win:")
	}
	if i := strings.LastIndexByte(p, '/'); i >= 0 {
		p = p[i+1:]
	}
	if i := strings.IndexByte(p, '.'); i >= 0 {
		p = p[:i]
	}
	return p
}

// appliedFixPluginsMsg carries the set of plugin stems that already have at
// least one applied fix, for the fixes plugin chooser's accent badge.
type appliedFixPluginsMsg struct {
	plugins map[string]bool
	err     error
}

// fetchAppliedFixPlugins loads the "has an applied fix" plugin set in one
// cheap call (list-applied-fix-plugins) instead of probing every plugin.
func fetchAppliedFixPlugins() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("list-applied-fix-plugins")
		if err != nil {
			return appliedFixPluginsMsg{err: err}
		}
		rows, err := decodeJSONLines[struct {
			Plugin string `json:"plugin"`
		}](out)
		if err != nil {
			return appliedFixPluginsMsg{err: err}
		}
		set := map[string]bool{}
		for _, r := range rows {
			if r.Plugin != "" {
				set[r.Plugin] = true
			}
		}
		return appliedFixPluginsMsg{plugins: set}
	}
}

// saveHiddenChangesCmd commits the Tab-marked hide/show changes from the
// Plugin list: each target's current on-disk state gets flipped exactly
// once (the toggle verbs are pure toggles, so this only runs for rows whose
// checked-state actually differs from the server baseline).
func saveHiddenChangesCmd(targets []string) tea.Cmd {
	return func() tea.Msg {
		var errs []string
		for _, v := range targets {
			kind, path := targetKindPath(v)
			var err error
			switch kind {
			case "vst":
				_, err = runQuick("toggle-vst-hidden", path)
			case "native":
				_, err = runQuick("toggle-native-plugin", path)
			}
			if err != nil {
				errs = append(errs, err.Error())
			}
		}
		if len(errs) > 0 {
			return pluginSaveDoneMsg{err: fmt.Errorf("%s", strings.Join(errs, "; "))}
		}
		return pluginSaveDoneMsg{what: fmt.Sprintf("%d plugin(s) updated", len(targets))}
	}
}

func runFireAndForget(what string, args ...string) tea.Cmd {
	return func() tea.Msg {
		if _, err := runQuick(args...); err != nil {
			return actionErrMsg{err: err}
		}
		return actionOKMsg{what: what}
	}
}

// setPluginHandlerCmd applies an already-decided plugin-window handler mode
// (classic/hyprland) through the bash side, which also rewrites the global
// Hyprland rule block, and refetches the status so the Settings row and the
// plugin-list hint show the active mode. The mode is decided (and confirmed
// by the user) before this runs — see requestPluginHandlerChange.
func setPluginHandlerCmd(mode string) tea.Cmd {
	return func() tea.Msg {
		if _, err := runQuick("set-plugin-handler", mode); err != nil {
			return handlerErrMsg{err}
		}
		return pluginHandlerOKMsg{handler: mode}
	}
}

// togglePluginHandlerTarget returns the mode a handler toggle from the
// current status would switch to.
func togglePluginHandlerTarget(current string) string {
	if current == "classic" {
		return "hyprland"
	}
	return "classic"
}

// pluginHandlerOKMsg reports a successful classic⇄hyprland flip so the
// model can show a confirmation toast (the plugin-list "x" shortcut has no
// other visible effect) before refetching the status.
type pluginHandlerOKMsg struct{ handler string }

// FixItem is one row of the "Plugin fixes" catalog (list-plugin-fixes): a
// general, independently-applicable fix, with the scope ("plugin" or
// "global"), its category (the picker's expanded-folder heading), the
// product it is plugin-specific to ("" when generic) and whether it is
// already applied for the chosen plugin. Plugin-specific fixes are always
// shown — grouped under their "<Product> specific" category, which names the
// product, so the row carries no extra tag; they are never filtered out.
type FixItem struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Scope       string `json:"scope"`
	Description string `json:"description"`
	Category    string `json:"category"`
	Plugin      string `json:"plugin"`
	Applied     bool   `json:"applied"`
	// Vst is the plugin format this fix targets: "any" (the default) covers
	// the product's VST2 AND VST3 copies at once, while "vst2"/"vst3" restricts
	// it to one format. A fix is recorded per PRODUCT STEM, so "any" really
	// does reach both formats — the rules match the editor window's title,
	// which is the same window for both. Only a genuinely one-format fix says
	// so, and its row is tagged so the restriction is visible.
	Vst string `json:"vst"`

	// AppliedTo names the plugins of a vendor-wide selection this fix is
	// ALREADY recorded on, and Candidates is how many plugins of that
	// selection it can reach.
	//
	// They are filled in by the vendor merge, not by the backend, because
	// list-plugin-fixes only ever answers for one plugin at a time. Collapsing
	// that to a single Applied bool is what made a fix that is on 1 of a
	// vendor's 21 plugins report itself as simply "applied" — so the row said
	// ●, the user read it as "all of them", and re-running it looked like a
	// no-op while three quarters of the suite was in fact untouched.
	AppliedTo  []string
	Candidates int
}

// IsPartial reports whether a fix is recorded on SOME of the plugins it can
// reach, which is the only state a filled-left-half circle can honestly mean.
//
// A fix with no candidate count comes from a single-plugin request, where
// applied is applied and there is no "part" to speak of.
func (it FixItem) IsPartial() bool {
	return it.Candidates > 1 && len(it.AppliedTo) > 0 && len(it.AppliedTo) < it.Candidates
}

// fixesMsg carries the catalog fetched for a plugin, or for a whole vendor
// when Vendor is set — in which case "Applied" means "applied to at least one
// plugin of that vendor", which is what a check on the row has to mean when
// Enter will apply to all of them.
type fixesMsg struct {
	plugin string
	vendor string
	items  []FixItem
	// vendorPlugins are the plugin names of a vendor-wide selection, in the
	// order the vendor lists them. The apply confirmation names them, so the
	// user can see the blast radius before answering.
	vendorPlugins []string
	err           error
}

// fixesDoneMsg reports a successful apply/remove batch.
type fixesDoneMsg struct{ what string }

// fetchPluginFixes loads every fix with its applied flag for one plugin.
func fetchPluginFixes(plugin string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("list-plugin-fixes", plugin)
		if err != nil {
			return fixesMsg{plugin: plugin, err: err}
		}
		items, err := decodeJSONLines[FixItem](out)
		return fixesMsg{plugin: plugin, items: items, err: err}
	}
}

// fetchFixesForVendorCmd loads the fix catalog for a WHOLE vendor: the union of
// what applies to any of its plugins, deduplicated.
//
// list-plugin-fixes only answers for one plugin, so a vendor-wide run has to
// ask per plugin and merge. A fix that already applies to a member is reported
// as applied, because Enter will touch all of them and a row that claimed
// "not applied" would be re-applied for no reason.
func fetchFixesForVendorCmd(vendor string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("list-vendor-plugins", vendor)
		if err != nil {
			return fixesMsg{vendor: vendor, err: err}
		}
		plugins, err := decodeJSONLines[PluginItem](out)
		if err != nil {
			return fixesMsg{vendor: vendor, err: err}
		}
		byID := map[string]FixItem{}
		// appliedTo[id] and reach[id] count the plugins of the selection that
		// already carry the fix and that it can reach at all. A fix only
		// present on one product (a tooltip rewrite) is NOT partial, however
		// many products the suite has, so reach is tracked separately from the
		// suite size: partial means "some of what it can reach", not "some of
		// the vendor".
		appliedTo := map[string][]string{}
		reach := map[string]int{}
		var order []string
		var anyErr error
		var names []string
		for _, p := range plugins {
			name := pluginStemOf(p.Value)
			if name != "" {
				names = append(names, name)
			}
			raw, e := runQuick("list-plugin-fixes", p.Value)
			if e != nil {
				if anyErr == nil {
					anyErr = e
				}
				continue
			}
			items, e := decodeJSONLines[FixItem](raw)
			if e != nil {
				continue
			}
			for _, it := range items {
				reach[it.ID]++
				if it.Applied {
					appliedTo[it.ID] = append(appliedTo[it.ID], name)
				}
				prev, seen := byID[it.ID]
				if !seen {
					order = append(order, it.ID)
					byID[it.ID] = it
					continue
				}
				// Already collected from another plugin of the same vendor:
				// keep the first, but remember that it applies to one of them.
				if it.Applied {
					prev.Applied = true
					byID[it.ID] = prev
				}
			}
		}
		out2 := make([]FixItem, 0, len(order))
		for _, id := range order {
			it := byID[id]
			it.AppliedTo = appliedTo[id]
			it.Candidates = reach[id]
			out2 = append(out2, it)
		}
		return fixesMsg{vendor: vendor, items: out2, vendorPlugins: names, err: anyErr}
	}
}

// The two single-target sync commands that used to live here are gone.
//
// syncFixesCmd committed a delta to ONE plugin, and syncVendorFixesCmd applied
// it to every plugin of a vendor. Between them they could not express "apply
// this fix to the two plugins of the suite that do not have it": the only
// choice on a vendor visit was the whole suite, which rewrote the plugins that
// were already done and dragged the group's other fixes along with it, or a
// single-plugin removal that named no plugin at all on a vendor visit and failed
// with "plugin required".
//
// runFixPlan (screens.go) builds the target set from each fix's own recorded
// state and runs apply-fixes-plugins / remove-fixes-plugins against exactly
// that, keeping the one-call vendor path for a fix that really does cover the
// whole selection.

// installFixesCheckMsg carries the fixes catalog fetched right after a
// successful plugin install, so the model can offer to apply the remaining
// plugin-scope fixes for the freshly installed plugin.
type installFixesCheckMsg struct {
	plugin string
	items  []FixItem
	// vendor is the folder this plugin groups under, when known. Non-empty it
	// means the question can be about the whole suite instead of this plugin.
	vendor string
	// autoFix / fixPrompt are the two independent switches read from the
	// backend. They are carried on the message rather than re-read here, so the
	// decision is made once, at the moment the catalog arrives, from the same
	// values the Settings screen shows.
	autoFix   bool
	fixPrompt bool
	err       error
}

// fixPrefsCmd reads the two post-install fix switches.
//
// They live on the Status rather than in a struct of their own: the Settings
// screen is built from Status, and a second source of truth would be a second
// thing that can disagree with what the user last toggled.
func fixPrefsCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("get-fix-prefs")
		if err != nil {
			return fixPrefsMsg{}
		}
		var v struct {
			AutoFix   string `json:"auto_fix"`
			FixPrompt string `json:"fix_prompt"`
		}
		_ = json.Unmarshal(bytes.TrimSpace(out), &v)
		return fixPrefsMsg{autoFix: v.AutoFix != "no", fixPrompt: v.FixPrompt != "no"}
	}
}

// fixPrefsMsg carries the two switches. Both default to true when the read
// fails: the backend's own default is "on", so a failed read must not silently
// turn a feature off.
type fixPrefsMsg struct{ autoFix, fixPrompt bool }

// setFixPrefCmd writes one switch and returns the fresh pair, so the caller
// does not have to guess what the other one is.
func setFixPrefCmd(key string, on bool) tea.Cmd {
	return func() tea.Msg {
		v := "no"
		if on {
			v = "yes"
		}
		if _, err := runQuick("set-fix-prefs", key, v); err != nil {
			return fixPrefsMsg{autoFix: true, fixPrompt: true}
		}
		out, err := runQuick("get-fix-prefs")
		if err != nil {
			return fixPrefsMsg{autoFix: on, fixPrompt: true}
		}
		var p struct {
			AutoFix   string `json:"auto_fix"`
			FixPrompt string `json:"fix_prompt"`
		}
		_ = json.Unmarshal(bytes.TrimSpace(out), &p)
		return fixPrefsMsg{autoFix: p.AutoFix != "no", fixPrompt: p.FixPrompt != "no"}
	}
}

// checkInstallFixesCmd reuses list-plugin-fixes on the value the installer
// reported (the "installed-plugin: vst:<type>:<path>" marker line).
// pluginVendorCmd resolves which vendor folder a plugin groups under, so the
// post-install question can offer the fixes for the WHOLE SUITE rather than for
// the single plugin that happened to finish installing. Installing FabFilter
// means nineteen plugins, and asking once per plugin is the same dialog
// nineteen times.
func pluginVendorCmd(plugin string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("plugin-vendor", plugin)
		if err != nil {
			return installFixesCheckMsg{plugin: plugin, err: err}
		}
		return installFixesCheckMsg{plugin: plugin, vendor: strings.TrimSpace(string(out))}
	}
}

// checkInstallFixesCmd resolves the vendor first, then fetches the fixes.
//
// The order matters: the question it feeds is about the whole suite, so the
// vendor has to be known before the catalog is asked, and the fix list shown is
// the union of every plugin of that vendor — otherwise it would offer fixes
// scoped to the one plugin that happened to finish installing and quietly
// under-offer the other eighteen.
func checkInstallFixesCmd(plugin string) tea.Cmd {
	return func() tea.Msg {
		vendor := strings.TrimSpace(mustRun("plugin-vendor", plugin))
		out, err := runQuick("list-plugin-fixes", plugin)
		if err != nil {
			return installFixesCheckMsg{plugin: plugin, vendor: vendor, err: err}
		}
		items, err := decodeJSONLines[FixItem](out)
		// Read the two switches here, alongside the catalog, so the handler
		// below decides from one snapshot: the vendor, the catalog, and what
		// the user has allowed to happen automatically.
		autoFix, fixPrompt := true, true
		if out, e := runQuick("get-fix-prefs"); e == nil {
			var v struct {
				AutoFix   string `json:"auto_fix"`
				FixPrompt string `json:"fix_prompt"`
			}
			if json.Unmarshal(bytes.TrimSpace(out), &v) == nil {
				autoFix = v.AutoFix != "no"
				fixPrompt = v.FixPrompt != "no"
			}
		}
		return installFixesCheckMsg{plugin: plugin, vendor: vendor, items: items,
			autoFix: autoFix, fixPrompt: fixPrompt, err: err}
	}
}

// mustRun returns a command's trimmed output, or "" on any failure. Used only
// where a missing answer degrades the wording of a question, never where it
// decides whether something happens.
func mustRun(args ...string) string {
	out, err := runQuick(args...)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// installedPluginValueMarker is the prefix install_plugin prints after a
// successful install (see lib-audio-plugin-manager-core.sh); the Go Runner
// streams it back and installedPluginValue() recovers the value from the
// runner's captured output.
const installedPluginValueMarker = "installed-plugin: "

func installedPluginValue(output string) string {
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, installedPluginValueMarker) {
			return strings.TrimSpace(strings.TrimPrefix(line, installedPluginValueMarker))
		}
	}
	return ""
}

// folderOpenedMsg reports the "open-folder" action's outcome. Unlike
// actionOKMsg it never pops the active screen: opening a folder from the
// uninstall list must leave the user right where they were.
type folderOpenedMsg struct {
	what string
	err  error
}

// openFolderCmd opens the containing folder of a list value in the system
// file manager through the core's canonical opener.
func openFolderCmd(value string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("open-folder", value)
		if err != nil {
			return folderOpenedMsg{err: err}
		}
		what := strings.TrimSpace(string(out))
		if what == "" {
			what = "opened folder"
		}
		return folderOpenedMsg{what: what}
	}
}

type handlerErrMsg struct{ err error }

// afterInstallFixesMsg reports the end of the SILENT re-apply, and carries the
// original catalog on so the question can still be asked from the same data.
type afterInstallFixesMsg struct {
	carry installFixesCheckMsg
	err   error
}

// reapplyAppliedFixesCmd rewrites the fixes this plugin ALREADY carries, for
// the whole vendor when one is known.
//
// This is the write the AUTO_FIX switch is about. It is silent by design — the
// rules were already there, this only refreshes them — which is exactly why it
// needs a switch: a write nobody sees is a write nobody can object to.
func reapplyAppliedFixesCmd(vendor, plugin string, fixIDs []string) tea.Cmd {
	return func() tea.Msg {
		carry := installFixesCheckMsg{plugin: plugin, vendor: vendor, autoFix: true, fixPrompt: true}
		if len(fixIDs) == 0 {
			return afterInstallFixesMsg{carry: carry}
		}
		var err error
		if vendor != "" {
			_, err = runQuick(append([]string{"apply-fixes-vendor", vendor}, fixIDs...)...)
		} else {
			_, err = runQuick(append([]string{"apply-fixes", plugin}, fixIDs...)...)
		}
		return afterInstallFixesMsg{carry: carry, err: err}
	}
}

// afterInstallFixesPrompt decides what the end of an install looks like: the
// question, or the plain success dialog.
//
// Split out because the prompt is reached from two places — straight from the
// install, and after the silent re-apply — and it has to read the same either
// way.
func (m model) afterInstallFixesPrompt(msg installFixesCheckMsg) (model, tea.Cmd) {
	if msg.err != nil {
		m.confirm = tuikit.NewConfirm("Success! The step completed without errors.", "See log", "OK")
		m.replace(scrRunnerSuccessConfirm)
		return m, nil
	}
	if !msg.fixPrompt {
		// The question is off. Say the install worked and stop there; the
		// fixes remain one row away under "Plugin fixes".
		m.confirm = tuikit.NewConfirm("Success! The step completed without errors.", "See log", "OK")
		m.replace(scrRunnerSuccessConfirm)
		return m, nil
	}
	var toApply []string
	for _, it := range msg.items {
		if it.Scope == "plugin" && !it.Applied {
			toApply = append(toApply, it.ID)
		}
	}
	if len(toApply) == 0 {
		m.confirm = tuikit.NewConfirm("Success! The step completed without errors.", "See log", "OK")
		m.replace(scrRunnerSuccessConfirm)
		return m, nil
	}
	// The question is about the SUITE: FabFilter is nineteen plugins and the
	// useful action is "fix them all". Without a known vendor it names the one
	// plugin that finished installing.
	if msg.vendor != "" {
		m.confirm = tuikit.NewConfirm(
			"Plugin installed. Apply fixes to every "+msg.vendor+" plugin now?",
			"No", "Yes")
	} else {
		m.confirm = tuikit.NewConfirm(
			"Plugin installed. Apply fixes for "+baseName(pluginPathOf(msg.plugin))+" now?",
			"No", "Yes")
	}
	m.replace(scrInstallFixesConfirm)
	return m, nil
}
