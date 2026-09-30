package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// actionsBin resolves mosquito-move-manager-actions next to this binary
// (both live in the same deployed bin dir, or side by side in the repo
// during development).
func actionsBin() string {
	exe, err := os.Executable()
	if err == nil {
		cand := filepath.Join(filepath.Dir(exe), "mosquito-move-manager-actions")
		if _, statErr := os.Stat(cand); statErr == nil {
			return cand
		}
	}
	return "mosquito-move-manager-actions" // fall back to PATH
}

// runnerReportedDownload reads the last non-empty line of an
// open-manager-and-wait run, which is always "DOWNLOADED=true|false".
func runnerReportedDownload(output string) bool {
	sc := bufio.NewScanner(bytes.NewReader([]byte(output)))
	last := ""
	for sc.Scan() {
		if l := strings.TrimSpace(sc.Text()); l != "" {
			last = l
		}
	}
	return last == "DOWNLOADED=true"
}

// runQuick runs a fast, non-streaming action and returns its stdout.
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

type BundleItem struct {
	Path  string `json:"path"`
	Label string `json:"label"`
}

type ExeItem struct {
	Path  string `json:"path"`
	Label string `json:"label"`
}

type MoveStatus struct {
	Connected          bool   `json:"connected"`
	Host               string `json:"host"`
	Address            string `json:"address"`
	HideConverted      bool   `json:"hide_converted"`
	MoveDir            string `json:"move_dir"`
	AbletonVer         string `json:"ableton_version"`
	FilePicker         string `json:"file_picker"`
	SuperfileInstalled bool   `json:"superfile_installed"`
	OpenAlsYdotool     bool   `json:"open_als_ydotool"`
}

type statusMsg struct {
	status MoveStatus
	err    error
	skip   bool
}

type bundlesMsg struct {
	items []BundleItem
	err   error
}

type abletonConflictMsg struct {
	running bool
	err     error
}

func checkAbletonConflictCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("check-ableton-conflict")
		if err != nil {
			return abletonConflictMsg{err: err}
		}
		var v struct {
			Running bool `json:"running"`
		}
		if err := json.Unmarshal(out, &v); err != nil {
			return abletonConflictMsg{err: fmt.Errorf("check-ableton-conflict: %w", err)}
		}
		return abletonConflictMsg{running: v.Running}
	}
}

// extractAlsPath reads the "ALS_PATH=..." sentinel the open-ableton-route
// action prints as its very last line (native's own terminal never sees
// this — only this wrapper action emits it, see mosquito-move-manager-
// actions) -- same "last line is the machine-readable result" convention
// open-manager-and-wait's "DOWNLOADED=" line already uses.
func extractAlsPath(output string) (string, bool) {
	sc := bufio.NewScanner(strings.NewReader(output))
	for sc.Scan() {
		if l := strings.TrimSpace(sc.Text()); strings.HasPrefix(l, "ALS_PATH=") {
			return strings.TrimPrefix(l, "ALS_PATH="), true
		}
	}
	return "", false
}

// extractBitwigPID reads the "BITWIG_PID=..." sentinel the finish-bitwig-open
// action prints (fd 3) after handing the .als over — the Bitwig instance the
// TUI's hidden discretion watchdog then waits on. 0 when Bitwig is not running
// (nothing to watch: the manager exits instead of staying hidden forever).
func extractBitwigPID(output string) int {
	sc := bufio.NewScanner(strings.NewReader(output))
	for sc.Scan() {
		l := strings.TrimSpace(sc.Text())
		if strings.HasPrefix(l, "BITWIG_PID=") {
			if n, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(l, "BITWIG_PID="))); err == nil {
				return n
			}
		}
	}
	return 0
}

// runnerExitCode returns the process exit status behind a Runner error, or
// -1 when it isn't an *exec.ExitError. The Ableton phase uses this to tell
// a launch failure (exit 1, retryable) from a clean close with no saved
// .als (exit 2, the "no set detected" screen) — both of which carry an
// empty ALS_PATH= sentinel.
func runnerExitCode(err error) int {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return -1
}

// presetOutputPaths pulls the converted preset paths out of the converter's
// own log lines ("   .adg   -> /path", "   preset -> /path") so the
// post-conversion screen can show exactly what was produced. Anything after
// the first "->" on a line is treated as the path.
func presetOutputPaths(output string) []string {
	var paths []string
	sc := bufio.NewScanner(strings.NewReader(output))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if i := strings.Index(line, "->"); i >= 0 {
			if p := strings.TrimSpace(line[i+2:]); p != "" {
				paths = append(paths, p)
			}
		}
	}
	return paths
}

type exesMsg struct {
	items []ExeItem
	err   error
}

type pathMsg struct {
	kind string
	path string
	err  error
}
type actionOKMsg struct{ what string }
type actionErrMsg struct{ err error }

type silentDoneMsg struct{ err error }

// runSilent runs an action with no UI consequence — completion (or error) is
// ignored. Unlike runFireAndForget (whose actionOKMsg handler pops the top
// screen, shows a toast and refetches status — right for one-shot settings
// toggles), this is for background effects that must not disturb whatever
// screen is up: raising the TUI's own window over the floating Move Manager,
// killing the Manager after the user confirmed.
func runSilent(args ...string) tea.Cmd {
	return func() tea.Msg {
		_, err := runQuick(args...)
		return silentDoneMsg{err: err}
	}
}

// ───────────────────────────── Manager wait poll ─────────────────────────────
// The TUI owns the whole "Open the Move Manager" wait (the actions script's
// ui_confirm is stubbed, so the native mid-wait "downloaded — close it?" prompt
// can never appear in this flow). scrManagerWait runs a 1s tick loop against
// the read-only `manager-poll` action and shows its own Confirm when a bundle
// appears — including a raise-own-window so the prompt is visible above the
// (floating) Move Manager.

type managerPollResultMsg struct {
	running bool
	newest  string
	err     error
}

// managerPollCmd ticks once a second, running one read-only manager-poll on
// each tick (the handler re-arms it to keep the loop going, per the standard
// Tea Tick pattern).
func managerPollCmd() tea.Cmd {
	return tea.Tick(time.Second, func(time.Time) tea.Msg {
		out, err := runQuick("manager-poll")
		if err != nil {
			return managerPollResultMsg{err: err}
		}
		var v struct {
			Running bool   `json:"running"`
			Newest  string `json:"newest"`
		}
		if err := json.Unmarshal(out, &v); err != nil {
			return managerPollResultMsg{err: fmt.Errorf("manager-poll: %w", err)}
		}
		return managerPollResultMsg{running: v.Running, newest: v.Newest}
	})
}

// finishManagerAndList runs the post-manager deposit (moves sets saved in the
// auto-download folders into ablbundle), then lists the bundles in one cmd so
// scrManagerWait can drop straight into the bundle picker on manager close.
func finishManagerAndList() tea.Cmd {
	return func() tea.Msg {
		if _, err := runQuick("finish-manager-session"); err != nil {
			return managerPollResultMsg{err: err}
		}
		out, err := runQuick("list-bundles")
		if err != nil {
			return bundlesMsg{err: err}
		}
		items, err := decodeJSONLines[BundleItem](out)
		return bundlesMsg{items: items, err: err}
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

// pickBundleFileViaSuperfileEmbedded runs superfile IN this program's own
// terminal (tea.ExecProcess suspends Bubble Tea, hands over the terminal,
// resumes after) instead of shelling out to pick_file_via_superfile(),
// which would spawn a brand-new terminal window external to the TUI.
func pickBundleFileViaSuperfileEmbedded() tea.Cmd {
	return pickViaSuperfileEmbedded("pick-file", "")
}

// pickViaSuperfileEmbedded is the generalized form: runs superfile in this
// program's terminal starting at dir, delivering the choice as a pathMsg of
// the given kind (empty path = user quit without picking — a cancel).
func pickViaSuperfileEmbedded(kind string, dir string) tea.Cmd {
	tmp, err := os.CreateTemp("", "move-manager-pick-*")
	if err != nil {
		return func() tea.Msg { return pathMsg{kind: kind, err: err} }
	}
	tmpPath := tmp.Name()
	tmp.Close()
	os.Remove(tmpPath) // spf writes this path itself on pick; must not pre-exist as a stale non-empty file
	if dir == "" {
		dir, _ = os.UserHomeDir()
	}
	cmd := exec.Command("spf", "--chooser-file", tmpPath, dir)
	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		defer os.Remove(tmpPath)
		if err != nil {
			return pathMsg{kind: kind, err: err}
		}
		data, rerr := os.ReadFile(tmpPath)
		if rerr != nil || len(bytes.TrimSpace(data)) == 0 {
			return pathMsg{kind: kind} // quit/Esc without picking -- a cancel, not an error
		}
		return pathMsg{kind: kind, path: strings.TrimSpace(string(data))}
	})
}

func fetchStatus() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("status-json")
		if err != nil {
			return statusMsg{err: err}
		}
		// A background status refresh that comes back empty (the action
		// exited 0 but printed nothing — seen, rarely, presumably a
		// transient hiccup around detect_move's ~1.5s network check) is
		// not worth interrupting whatever the user is doing with a raw
		// JSON decode error: just skip this refresh, keep showing the
		// last known status, and let the next one (there's always a
		// next one — every screen re-enter or action completion
		// refetches) catch up.
		if len(bytes.TrimSpace(out)) == 0 {
			return statusMsg{skip: true}
		}
		var s MoveStatus
		if err := json.Unmarshal(out, &s); err != nil {
			return statusMsg{err: fmt.Errorf("status-json: %w", err)}
		}
		return statusMsg{status: s}
	}
}

// setFilePickerAndRefetch writes the file-picker preference then re-fetches
// status in one command, so scrSettings can refresh in place instead of
// popping back to the main menu.
func setFilePickerAndRefetch(mode string) tea.Cmd {
	return func() tea.Msg {
		_, _ = runQuick("set-file-picker", mode)
		out, err := runQuick("status-json")
		if err != nil {
			return statusMsg{err: err}
		}
		if len(bytes.TrimSpace(out)) == 0 {
			return statusMsg{skip: true}
		}
		var s MoveStatus
		if err := json.Unmarshal(out, &s); err != nil {
			return statusMsg{err: fmt.Errorf("status-json: %w", err)}
		}
		return statusMsg{status: s}
	}
}

func fetchBundles() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("list-bundles")
		if err != nil {
			return bundlesMsg{err: err}
		}
		items, err := decodeJSONLines[BundleItem](out)
		return bundlesMsg{items: items, err: err}
	}
}

func fetchAbletonExes() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("list-ableton-exes")
		if err != nil {
			return exesMsg{err: err}
		}
		items, err := decodeJSONLines[ExeItem](out)
		return exesMsg{items: items, err: err}
	}
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

func runFireAndForget(what string, args ...string) tea.Cmd {
	return func() tea.Msg {
		if _, err := runQuick(args...); err != nil {
			return actionErrMsg{err: err}
		}
		return actionOKMsg{what: what}
	}
}

// toastOKMsg is actionOKMsg without the pop: a background action that
// opened something (the Schwung Manager webapp) succeeds with a toast but
// must NOT dismiss whatever screen on top.
type toastOKMsg struct{ what string }

// fireToast runs an action that only reports success with a toast and a
// status refresh, WITHOUT popping the current screen — used by the
// Settings screen's ←/→ in-place toggles (the cursor must stay on the row).
func fireToast(what string, action string) tea.Cmd {
	return func() tea.Msg {
		if _, err := runQuick(action); err != nil {
			return actionErrMsg{err: err}
		}
		return toastOKMsg{what: what}
	}
}

// openSchwungManagerCmd fires the open-schwung-manager action (dedicated
// Chromium profile, exactly like the Move Manager webapp) and reports back
// as a toast without touching the nav stack.
func openSchwungManagerCmd() tea.Cmd {
	return func() tea.Msg {
		if _, err := runQuick("open-schwung-manager"); err != nil {
			return actionErrMsg{err: err}
		}
		return toastOKMsg{what: "Schwung Manager opened"}
	}
}

// openMoveManagerCmd opens the Move Manager webapp (the same open-manager
// action the main menu's wait flow uses) and reports back as a toast without
// touching the nav stack — the post-preset screen stays up so its upload
// path remains visible.
func openMoveManagerCmd() tea.Cmd {
	return func() tea.Msg {
		if _, err := runQuick("open-manager"); err != nil {
			return actionErrMsg{err: err}
		}
		return toastOKMsg{what: "Move Manager opened"}
	}
}

// ─────────────────────────── Convert a preset ────────────────────────────

// presetStatusMsg carries the "Convert a preset" flow facts (where .adg
// output lands, which Wine drive_c the samples get remapped to, where the
// picker should start). Fetched when the flow opens (so the superfile
// picker can start at the right preset folder) and reused by Handlers on
// success (to point at the output folder).
type presetStatusMsg struct {
	presetsDir   string
	searchRoot   string
	defaultDir   string // .adg picker start (Ableton preset folder)
	bwDefaultDir string // .bwpreset picker start (manager working dir)
	connected    bool
	err          error
}

func fetchPresetStatus() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("preset-status-json")
		if err != nil {
			return presetStatusMsg{err: err}
		}
		var v struct {
			PresetsDir   string `json:"presets_dir"`
			SearchRoot   string `json:"search_root"`
			DefaultDir   string `json:"default_dir"`
			BwDefaultDir string `json:"bw_default_dir"`
			Connected    bool   `json:"connected"`
		}
		if err := json.Unmarshal(out, &v); err != nil {
			return presetStatusMsg{err: fmt.Errorf("preset-status-json: %w", err)}
		}
		return presetStatusMsg{
			presetsDir: v.PresetsDir, searchRoot: v.SearchRoot,
			defaultDir: v.DefaultDir, bwDefaultDir: v.BwDefaultDir,
			connected: v.Connected,
		}
	}
}

// ───────────────────────────── Schwung ────────────────────────────────────

type schwungInfoMsg struct {
	reachable bool
	installed bool
	version   string
	latest    string
	err       error
}

// fetchSchwungInfo asks the move for schwung's state (schwung-status: is
// its manager webapp answering on :7700, so "installed?") and the latest
// upstream release (schwung-latest) in one round-trip to the actions script.
func fetchSchwungInfo() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("schwung-status")
		if err != nil {
			return schwungInfoMsg{err: err}
		}
		var v struct {
			Reachable bool   `json:"reachable"`
			Installed bool   `json:"installed"`
			Version   string `json:"version"`
		}
		if err := json.Unmarshal(out, &v); err != nil {
			return schwungInfoMsg{err: fmt.Errorf("schwung-status: %w", err)}
		}
		latest := ""
		if lout, lerr := runQuick("schwung-latest"); lerr == nil {
			var lv struct {
				Version string `json:"version"`
			}
			if json.Unmarshal(lout, &lv) == nil {
				latest = lv.Version
			}
		}
		return schwungInfoMsg{reachable: v.Reachable, installed: v.Installed, version: v.Version, latest: latest}
	}
}

// ───────────────────── Bitwig Move integration ───────────────────────────

type bitwigMoveStatusMsg struct {
	bitwig      bool
	bitwigBin   string
	controllers bool
	onDevice    string
	err         error
}

func fetchBitwigMoveStatus() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("bitwig-move-status")
		if err != nil {
			return bitwigMoveStatusMsg{err: err}
		}
		var v struct {
			Bitwig      bool   `json:"bitwig"`
			BitwigBin   string `json:"bitwig_bin"`
			Controllers bool   `json:"controllers"`
			OnDevice    string `json:"onDevice"`
		}
		if err := json.Unmarshal(out, &v); err != nil {
			return bitwigMoveStatusMsg{err: fmt.Errorf("bitwig-move-status: %w", err)}
		}
		return bitwigMoveStatusMsg{bitwig: v.Bitwig, bitwigBin: v.BitwigBin, controllers: v.Controllers, onDevice: v.OnDevice}
	}
}

type bitwigRunningMsg struct {
	running bool
	err     error
}

// bitwigRunningCmd ticks once a second asking the actions script whether
// Bitwig Studio is up — the drive behind the controller-install tip screen
// that returns to the menu when Bitwig is closed (set bitwigSawRunning
// first so a still-launching Bitwig can't false-trigger the "closed" path).
func bitwigRunningCmd() tea.Cmd {
	return tea.Tick(time.Second, func(time.Time) tea.Msg {
		out, err := runQuick("bitwig-running")
		if err != nil {
			return bitwigRunningMsg{err: err}
		}
		var v struct {
			Running bool `json:"running"`
		}
		if err := json.Unmarshal(out, &v); err != nil {
			return bitwigRunningMsg{err: fmt.Errorf("bitwig-running: %w", err)}
		}
		return bitwigRunningMsg{running: v.Running}
	})
}
