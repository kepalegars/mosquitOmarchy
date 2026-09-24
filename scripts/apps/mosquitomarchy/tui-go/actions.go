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
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// actionsBin resolves mosquitomarchy-actions next to this binary (both
// live in the same deployed bin dir, or side by side in the repo during
// development).
func actionsBin() string {
	exe, err := os.Executable()
	if err == nil {
		cand := filepath.Join(filepath.Dir(exe), "mosquitomarchy-actions")
		if _, statErr := os.Stat(cand); statErr == nil {
			return cand
		}
	}
	return "mosquitomarchy-actions" // fall back to PATH
}

// runQuick runs a fast, non-streaming query and returns its stdout.
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

// decodeJSONLines parses one JSON object per line (the actions backend's
// query output format).
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

// StatusRec is one module's status (mosquitomarchy-setup.sh's module_state:
// ok / partial / missing / na) plus whether the user uninstalled it.
type StatusRec struct {
	Id       string `json:"id"`
	Label    string `json:"label"`
	State    string `json:"state"`
	Excluded bool   `json:"excluded"`
}

// CatRec is one setup category (apps, tuis, webapps, plugins, fixes,
// mosquito, keybindings, llm, themes, vms, menu).
type CatRec struct {
	Id    string `json:"id"`
	Label string `json:"label"`
}

// ItemRec is a selectable setup/fix/update row: candidates use "key", fixes
// and update modules use "id" — the same run payload either way.
type ItemRec struct {
	Key   string `json:"key"`
	Label string `json:"label"`
}

// BackupRec is one dated archive in the backup dir.
type BackupRec struct {
	File string `json:"file"`
	Size string `json:"size"`
	Date string `json:"date"`
}

// UpdateRec is the update zone's check result: whether the repo's remote
// has a newer version, plus the changed installed modules that are safe to
// re-apply.
type UpdateRec struct {
	RepoUpdate  bool      `json:"repo_update"`
	RepoVersion string    `json:"repo_version"`
	Modules     []ItemRec `json:"modules"`
}

// FolderRec is one Setup folder (a setup category).
type FolderRec struct {
	Folder string `json:"folder"`
	Label  string `json:"label"`
	Accent bool   `json:"accent"`
}

// SetupItemRec is one selectable Setup item inside a folder. Info is the long
// description the TUI keeps out of the row and shows behind the "i" key.
// Checked is only used by the backup-options tree (its default selection).
type SetupItemRec struct {
	Folder  string `json:"folder"`
	Key     string `json:"key"`
	Label   string `json:"label"`
	Info    string `json:"info"`
	Checked bool   `json:"checked"`
}

// backupOptionsMsg carries the backup content tree + environment facts.
type backupOptionsMsg struct {
	folders []FolderRec
	items   []SetupItemRec
	keepass bool
	err     error
}

// fetchBackupOptionsCmd loads the installed apps/tuis/webapps (as a tree,
// pre-checked from the previous backup) and whether KeePassXC is present, so
// the Backup screen can ask the same content questions the old flow did.
func fetchBackupOptionsCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("backup-options")
		if err != nil {
			return backupOptionsMsg{err: err}
		}
		var folders []FolderRec
		var items []SetupItemRec
		keepass := false
		sc := bufio.NewScanner(bytes.NewReader(out))
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			line := bytes.TrimSpace(sc.Bytes())
			if len(line) == 0 {
				continue
			}
			var probe struct {
				Key  string `json:"key"`
				Opts bool   `json:"opts"`
			}
			if err := json.Unmarshal(line, &probe); err != nil {
				return backupOptionsMsg{err: err}
			}
			switch {
			case probe.Opts:
				var o struct {
					Keepass bool `json:"keepass"`
				}
				if err := json.Unmarshal(line, &o); err != nil {
					return backupOptionsMsg{err: err}
				}
				keepass = o.Keepass
			case probe.Key != "":
				var it SetupItemRec
				if err := json.Unmarshal(line, &it); err != nil {
					return backupOptionsMsg{err: err}
				}
				items = append(items, it)
			default:
				var f FolderRec
				if err := json.Unmarshal(line, &f); err != nil {
					return backupOptionsMsg{err: err}
				}
				folders = append(folders, f)
			}
		}
		if err := sc.Err(); err != nil {
			return backupOptionsMsg{err: err}
		}
		return backupOptionsMsg{folders: folders, items: items, keepass: keepass}
	}
}

// setupMsg carries the decoded Setup tree.
type setupMsg struct {
	folders []FolderRec
	items   []SetupItemRec
	err     error
}

// fetchTreeCmd loads a Setup-style tree (folders + items) in one backend call.
// `sub` is "setup" (installable tree) or "uninstall-tree" (installed only); the
// two share the exact same format, so the same screens render both.
func fetchTreeCmd(sub string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick(sub)
		if err != nil {
			return setupMsg{err: err}
		}
		var folders []FolderRec
		var items []SetupItemRec
		sc := bufio.NewScanner(bytes.NewReader(out))
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			line := bytes.TrimSpace(sc.Bytes())
			if len(line) == 0 {
				continue
			}
			var probe struct {
				Key string `json:"key"`
			}
			if err := json.Unmarshal(line, &probe); err != nil {
				return setupMsg{err: err}
			}
			if probe.Key == "" {
				var f FolderRec
				if err := json.Unmarshal(line, &f); err != nil {
					return setupMsg{err: err}
				}
				folders = append(folders, f)
			} else {
				var it SetupItemRec
				if err := json.Unmarshal(line, &it); err != nil {
					return setupMsg{err: err}
				}
				items = append(items, it)
			}
		}
		if err := sc.Err(); err != nil {
			return setupMsg{err: err}
		}
		return setupMsg{folders: folders, items: items}
	}
}

// queryMsg reports the outcome of one actions-backend query.
type queryMsg struct {
	kind    string // "status" | "categories" | "candidates" | "fixes" | "backups" | "update"
	status  []StatusRec
	cats    []CatRec
	items   []ItemRec
	fixes   []ItemRec
	backups []BackupRec
	update  UpdateRec
	err     error
}

// fetch executes an actions-backend query and delivers a queryMsg.
func fetch(kind string, args ...string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick(args...)
		if err != nil {
			return queryMsg{kind: kind, err: err}
		}
		if len(bytes.TrimSpace(out)) == 0 {
			return queryMsg{kind: kind}
		}
		switch kind {
		case "status":
			recs, err := decodeJSONLines[StatusRec](out)
			return queryMsg{kind: kind, status: recs, err: err}
		case "categories":
			recs, err := decodeJSONLines[CatRec](out)
			return queryMsg{kind: kind, cats: recs, err: err}
		case "candidates", "update":
			recs, err := decodeJSONLines[ItemRec](out)
			return queryMsg{kind: kind, items: recs, err: err}
		case "fixes":
			recs, err := decodeJSONLines[ItemRec](out)
			return queryMsg{kind: kind, fixes: recs, err: err}
		case "backups":
			recs, err := decodeJSONLines[BackupRec](out)
			return queryMsg{kind: kind, backups: recs, err: err}
		}
		return queryMsg{kind: kind, err: fmt.Errorf("fetch: unknown kind %q", kind)}
	}
}

// updateCheckJSON decodes the update-check object, which is a single JSON
// object rather than JSON-lines.
func updateCheckJSON(out []byte) (UpdateRec, error) {
	var u UpdateRec
	if err := json.Unmarshal(out, &u); err != nil {
		return UpdateRec{}, err
	}
	return u, nil
}

func fetchStatusCmd() tea.Cmd             { return fetch("status", "status") }
func fetchCatsCmd() tea.Cmd               { return fetch("categories", "categories") }
func fetchCandidatesCmd(c string) tea.Cmd { return fetch("candidates", "candidates", c) }
func fetchFixesCmd() tea.Cmd              { return fetch("fixes", "fixes") }
func fetchBackupsCmd() tea.Cmd            { return fetch("backups", "backups") }

// MissingAssetRec is one selected app whose manually-downloaded installer is
// absent (the backend's `missing-assets` query).
type MissingAssetRec struct {
	Folder string `json:"folder"`
	Key    string `json:"key"`
	Label  string `json:"label"`
	File   string `json:"file"`
	URL    string `json:"url"`
	Note   string `json:"note"`
}

// missingAssetsMsg carries the pre-install check result for a plan.
type missingAssetsMsg struct {
	items []MissingAssetRec
	plan  []string
	err   error
}

// fetchMissingAssetsCmd checks, BEFORE running a selection, whether any selected
// app needs a manually-downloaded installer that is not there yet. An empty
// result means "go ahead"; otherwise the TUI names the missing file(s).
func fetchMissingAssetsCmd(plan []string) tea.Cmd {
	return func() tea.Msg {
		var items []MissingAssetRec
		for _, group := range plan {
			parts := strings.Split(group, "\t")
			if len(parts) < 2 {
				continue
			}
			out, err := runQuick(append([]string{"missing-assets", parts[0]}, parts[1:]...)...)
			if err != nil {
				return missingAssetsMsg{plan: plan, err: err}
			}
			recs, err := decodeJSONLines[MissingAssetRec](out)
			if err != nil {
				return missingAssetsMsg{plan: plan, err: err}
			}
			items = append(items, recs...)
		}
		return missingAssetsMsg{items: items, plan: plan}
	}
}

// HealthRec is one drifted piece the `health` query reports: a partially
// installed module, or a mosquitOmarchy artifact that went missing.
type HealthRec struct {
	Kind   string `json:"kind"`
	ID     string `json:"id"`
	Label  string `json:"label"`
	Detail string `json:"detail"`
}

// healthMsg carries the health-check result.
type healthMsg struct {
	items []HealthRec
	err   error
}

func fetchHealthCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("health")
		if err != nil {
			return healthMsg{err: err}
		}
		recs, err := decodeJSONLines[HealthRec](out)
		return healthMsg{items: recs, err: err}
	}
}

// PatchRec is one selected app whose PATCH script is present (the backend's
// `patches` query) — the TUI proposes it after a successful install.
type PatchRec struct {
	Folder  string `json:"folder"`
	Key     string `json:"key"`
	Label   string `json:"label"`
	Script  string `json:"script"`
	Applied bool   `json:"applied"`
}

// patchSecretMsg carries the secret "p" check for a set of apps: install mode
// offers to patch, uninstall mode offers to remove the applied patches.
type patchSecretMsg struct {
	items  []PatchRec
	remove bool
}

// fetchPatchSecretCmd runs `patches apps <keys…>` for the secret "p" key.
func fetchPatchSecretCmd(remove bool, keys []string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick(append([]string{"patches", "apps"}, keys...)...)
		if err != nil {
			return patchSecretMsg{remove: remove}
		}
		recs, _ := decodeJSONLines[PatchRec](out)
		return patchSecretMsg{items: recs, remove: remove}
	}
}

// patchesMsg carries the post-install patch check for a plan.
type patchesMsg struct {
	items []PatchRec
	err   error
}

// fetchPatchesCmd checks, AFTER a successful apply, which of the applied apps
// have a patch script present, so the TUI can propose it (and stay silent when
// there is none — the pre-TUI launcher behaviour).
func fetchPatchesCmd(plan []string) tea.Cmd {
	return func() tea.Msg {
		var items []PatchRec
		for _, group := range plan {
			parts := strings.Split(group, "\t")
			if len(parts) < 2 {
				continue
			}
			out, err := runQuick(append([]string{"patches", parts[0]}, parts[1:]...)...)
			if err != nil {
				return patchesMsg{err: err}
			}
			recs, err := decodeJSONLines[PatchRec](out)
			if err != nil {
				return patchesMsg{err: err}
			}
			items = append(items, recs...)
		}
		return patchesMsg{items: items}
	}
}

func fetchUpdateCheckCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("update-check")
		if err != nil {
			return queryMsg{kind: "update", err: err}
		}
		u, err := updateCheckJSON(out)
		return queryMsg{kind: "update", update: u, err: err}
	}
}

// repoRoot resolves the mosquitOmarchy checkout: the dispatcher exports
// MOSQUITOMARCHY_REPO, and during development the actions backend is a symlink
// into <repo>/scripts/apps/mosquitomarchy/.
func repoRoot() string {
	if r := os.Getenv("MOSQUITOMARCHY_REPO"); r != "" {
		return r
	}
	if p, err := filepath.EvalSymlinks(actionsBin()); err == nil {
		// <repo>/scripts/apps/mosquitomarchy/mosquitomarchy-actions
		return filepath.Clean(filepath.Join(filepath.Dir(p), "..", "..", "..", ".."))
	}
	return ""
}

// crashLogDir is the repo-local, never-committed folder crash logs go to.
func crashLogDir() string {
	if d := os.Getenv("MOSQUITOMARCHY_LOG_DIR"); d != "" {
		return d
	}
	r := repoRoot()
	if r == "" {
		return ""
	}
	return filepath.Join(r, ".local", "crash-logs")
}

// reportCrash stores ONE dated log for the failed run and raises the clickable
// Omarchy notification that opens the default AI on the mosquitomarchy-crash
// skill. Best-effort: reporting must never break the TUI.
func reportCrash(tool, output string) {
	if strings.TrimSpace(output) == "" {
		return
	}
	dir := crashLogDir()
	if dir == "" {
		return
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	if tool == "" {
		tool = "mosquitomarchy"
	}
	slug := strings.NewReplacer(" ", "-", "/", "-", "\t", "-").Replace(strings.ToLower(tool))
	path := filepath.Join(dir, time.Now().Format("2006-01-02-150405")+"-"+slug+".log")
	body := "# mosquitOmarchy crash log\n# tool: " + tool +
		"\n# date: " + time.Now().Format(time.RFC3339) +
		"\n# cmd:  mosquitomarchy-actions " + tool + "\n\n" + output + "\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		return
	}
	if _, err := exec.LookPath("omarchy-notification-send"); err != nil {
		return
	}
	agent := filepath.Join(repoRoot(), "scripts/apps/mosquitomarchy/mosquitomarchy-agent-crash")
	_ = exec.Command("omarchy-notification-send",
		"--urgency", "critical",
		"--glyph", "\U000f16a1",
		"mosquitOmarchy: "+tool+" failed",
		"Click to diagnose with AI",
		"--exec", agent, path, tool,
	).Run()
}
