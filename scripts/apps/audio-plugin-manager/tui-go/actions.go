package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
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
}

type Status struct {
	FilePicker         string `json:"file_picker"`
	PluginWinHandler   string `json:"plugin_win_handler"`
	SuperfileInstalled bool   `json:"superfile_installed"`
	HideVst2           bool   `json:"hide_vst2"`
	Hide32Bit          bool   `json:"hide_32bit"`
	SortMode           string `json:"sort_mode"`
	PluginsRoot        string `json:"plugins_root"`
	DownloadsDir       string `json:"downloads_dir"`
	WizardDone         bool   `json:"wizard_done"`
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
	return func() tea.Msg {
		out, err := runQuick("list-prefixes")
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
func fetchAllPlugins() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("list-all-plugins")
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
		out, err := runQuick("set-sort-and-list", mode)
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
}

// fixesMsg carries the catalog fetched for a plugin.
type fixesMsg struct {
	plugin string
	items  []FixItem
	err    error
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

// syncFixesCmd commits only the Tab-marked delta: newly checked fixes are
// applied, unchecked-and-previously-applied ones are removed. Both bash
// verbs are idempotent, so a re-run never duplicates the Lua rule blocks.
func syncFixesCmd(plugin string, toApply, toRemove []string) tea.Cmd {
	return func() tea.Msg {
		var parts []string
		if len(toApply) > 0 {
			if _, err := runQuick(append([]string{"apply-fixes", plugin}, toApply...)...); err != nil {
				return actionErrMsg{err: err}
			}
			parts = append(parts, fmt.Sprintf("%d applied", len(toApply)))
		}
		if len(toRemove) > 0 {
			if _, err := runQuick(append([]string{"remove-fixes", plugin}, toRemove...)...); err != nil {
				return actionErrMsg{err: err}
			}
			parts = append(parts, fmt.Sprintf("%d removed", len(toRemove)))
		}
		return fixesDoneMsg{what: "fixes for " + plugin + ": " + strings.Join(parts, ", ")}
	}
}

// installFixesCheckMsg carries the fixes catalog fetched right after a
// successful plugin install, so the model can offer to apply the remaining
// plugin-scope fixes for the freshly installed plugin.
type installFixesCheckMsg struct {
	plugin string
	items  []FixItem
	err    error
}

// checkInstallFixesCmd reuses list-plugin-fixes on the value the installer
// reported (the "installed-plugin: vst:<type>:<path>" marker line).
func checkInstallFixesCmd(plugin string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("list-plugin-fixes", plugin)
		if err != nil {
			return installFixesCheckMsg{plugin: plugin, err: err}
		}
		items, err := decodeJSONLines[FixItem](out)
		return installFixesCheckMsg{plugin: plugin, items: items, err: err}
	}
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
