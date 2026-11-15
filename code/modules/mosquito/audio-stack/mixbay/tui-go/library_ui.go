// Audio interface library — the TUI face of the community profile store.
//
// Two tabs: Installed (status, update, export, uninstall) and Available
// (install one or several from the repo). Tab selects rows on the active tab;
// ←/→ switch tabs. Downloading only ever touches upstream/, so a profile
// update can never eat the user's layout tweaks.
package main

import (
	"context"
	"fmt"
	"os/exec"
	"sort"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"mosquitomarchy.local/mosquitomixbay-tui/profiles"
	tuikit "mosquitomarchy.local/tui-kit"
)

const (
	libInstalled = iota
	libAvailable
)

type libraryIndexMsg struct {
	ix  profiles.Index
	err error
}

type libraryApplyMsg struct {
	what string
	err  error
	// checkDups asks the screen to re-run duplicate detection (after an
	// install/update/remove), and offer removing a now-redundant scan card.
	checkDups bool
	// setup names the card integration an import must run (oscmix, douze).
	// id is that card, so the setup helper knows which one.
	setup string
	id    string
}

type libraryUninstallMsg struct {
	ids []string
	err error
}

// libraryBusyMsg is the first message of a sequence that shows progress while
// a multi-step install runs (backup, then download).
type libraryBusyMsg struct{ what string }

func libraryIndexCmd() tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		ix, err := profiles.FetchIndex(ctx)
		return libraryIndexMsg{ix: ix, err: err}
	}
}

func libraryImportCmd(ids []string, replaceUI bool) tea.Cmd {
	return func() tea.Msg {
		if replaceUI {
			// Back up before touching anything: a failed copy must abort the
			// install instead of losing the local layout.
			for _, id := range ids {
				if _, err := profiles.BackupUserUI(id); err != nil {
					return libraryApplyMsg{what: "Back up " + id + " layout", err: err}
				}
			}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		res, err := profiles.Import(ctx, ids)
		var done, updated, failed []string
		var firstErr error
		for _, r := range res {
			if r.Err != nil {
				failed = append(failed, r.ID)
				if firstErr == nil {
					firstErr = r.Err
				}
				continue
			}
			if r.Updated {
				updated = append(updated, r.ID)
			} else {
				done = append(done, r.ID)
			}
		}
		if err == nil {
			err = firstErr
		}
		what := "Downloaded " + strings.Join(done, ", ")
		if len(updated) > 0 {
			if len(done) > 0 {
				what += "; updated " + strings.Join(updated, ", ")
			} else {
				what = "Updated " + strings.Join(updated, ", ")
			}
		}
		if len(failed) > 0 {
			what += "; failed " + strings.Join(failed, ", ")
		}
		msg := libraryApplyMsg{what: what, err: err, checkDups: err == nil && len(ids) == 1, id: ids[0]}
		// shortcut: only a single-card install runs its spec.setup; a bulk
		// install of a card that declares one would need the same pass. Add it
		// when a repo card ships setup != "".
		if err == nil && len(res) == 1 {
			msg.setup = res[0].Setup
		}
		return msg
	}
}

// cardSetupCmd runs the integration a downloaded card declares. It goes
// through the foundation so the named integrations live in one place, and
// runs in the real terminal because the installers need sudo/build output.
// The foundation floor is not applied here: that waits for a first connection.
// The result popup offers the transcript like every other setup.
func cardSetupCmd(id string) tea.Cmd {
	return setupCmd(id+" setup", nil, "mixbay-audio-foundation", "--setup", "--device", id)
}

// openRepoCmd opens the community repo page in the desktop's default handler.
// A missing opener is reported like any other library action.
func openRepoCmd() tea.Cmd {
	return func() tea.Msg {
		if err := exec.Command("xdg-open", profiles.RepoPageURL()).Start(); err != nil {
			return libraryApplyMsg{what: "Open community repo", err: err}
		}
		return nil
	}
}

func libraryExportCmd(ids []string) tea.Cmd {
	return func() tea.Msg {
		dest, err := profiles.Export(ids, "")
		if err != nil {
			return libraryApplyMsg{what: "Export failed", err: err}
		}
		return libraryApplyMsg{what: "Exported to " + dest}
	}
}

// libraryUninstallCmd removes the cards and every trace they left: the
// foundation's per-card state and card-specific integration (douze for the
// SSL 12, oscmix for the RME cards, EVO split files), the connection-log
// entry and the local card folder. It runs in the real terminal because the
// integrations and udev cleanup may prompt for sudo, and its transcript is
// offered in the result popup like every other setup.
func libraryUninstallCmd(ids []string) tea.Cmd {
	var script strings.Builder
	script.WriteString("set +e\n")
	for _, id := range ids {
		if !profiles.ValidID(id) {
			continue
		}
		fmt.Fprintf(&script, "mixbay-audio-foundation --remove --device '%s' || true\n", id)
		// Drop the card folder right away so a batch uninstall of several RME
		// cards reaches "no oscmix user left" on the last one. profiles.Remove
		// then only writes the .removed marker for a shipped card.
		fmt.Fprintf(&script, "rm -rf \"$HOME/.config/mosquitomixbay/cards/%s\"\n", id)
		// Drop the history entry too; otherwise the card keeps appearing in
		// "used" lists and the default picker after its profile is gone.
		fmt.Fprintf(&script, `log="$HOME/.config/mosquitomixbay/connected-interfaces.json"
if [ -f "$log" ]; then
  jq --arg id '%s' 'map(select(.id != $id))' "$log" > "$log.tmp" && mv "$log.tmp" "$log"
fi
`, id)
	}
	after := func() tea.Msg {
		var leftovers []string
		for _, id := range ids {
			if rerr := profiles.Remove(id); rerr != nil {
				leftovers = append(leftovers, id)
			}
		}
		var err error
		if len(leftovers) > 0 {
			err = fmt.Errorf("could not remove %s", strings.Join(leftovers, ", "))
		}
		return libraryUninstallMsg{ids: ids, err: err}
	}
	return setupCmd("Removal of "+strings.Join(ids, ", "), after, "bash", "-c", script.String())
}

// bindPreset loads the card's UI composition for the active device.
func (m *model) bindPreset() {
	m.preset = ""
	if c, _, err := profiles.Effective(m.deviceID); err == nil {
		m.preset = c.Preset()
	}
}

func (m model) libraryItems() []tuikit.PickerItem {
	var items []tuikit.PickerItem
	switch {
	case m.libraryLoading:
		items = append(items, tuikit.PickerItem{Display: "  checking the community repo…", Disabled: true})
	case m.libraryErr != "":
		items = append(items, tuikit.PickerItem{Display: "  offline: " + m.libraryErr, Disabled: true})
	}
	if m.libraryTab == libAvailable {
		return append(items, m.availableItems()...)
	}
	return append(items, m.installedItems()...)
}

// installedItems lists every installed card with its repo state: up to date,
// update vX (plus the solid square) or local only.
func (m model) installedItems() []tuikit.PickerItem {
	var items []tuikit.PickerItem
	for _, meta := range profiles.Installed() {
		mark := "○"
		if m.libraryChecked[meta.ID] {
			mark = "●"
		}
		status, badge := "up to date", ""
		ic, inRepo := m.libraryIndex.Card(meta.ID)
		switch {
		case m.libraryIndex.SchemaVersion == 0:
			status = "not checked"
		case !inRepo:
			status = "local only"
		case ic.Version != meta.Version:
			status, badge = "update "+ic.Version, "■"
		}
		items = append(items, tuikit.PickerItem{
			Display:       fmt.Sprintf("%s %-30s %-8s %s", mark, meta.Display, meta.Version, status),
			Value:         "card:" + meta.ID,
			TrailingBadge: badge,
		})
	}
	if dups := profiles.Duplicates(); len(dups) > 0 {
		items = append(items, tuikit.PickerItem{Display: "Duplicate entries", Heading: true})
		for _, d := range dups {
			items = append(items, tuikit.PickerItem{
				Display: fmt.Sprintf("  ! %s also matches %s", d.RemoveDisplay, d.KeepDisplay),
				Value:   "dup:" + d.RemoveID + ":" + d.KeepID,
			})
		}
	}
	if m.libraryIndex.SchemaVersion == 0 && !m.libraryLoading && m.libraryErr == "" {
		items = append(items, tuikit.PickerItem{Display: "  r checks the community repo", Disabled: true})
	}
	return items
}

// availableItems lists repo cards that are not installed here. Installed
// cards live in the other tab, updates included.
func (m model) availableItems() []tuikit.PickerItem {
	var items []tuikit.PickerItem
	for _, ic := range m.libraryIndex.Cards {
		if _, _, err := profiles.Effective(ic.ID); err == nil {
			continue
		}
		mark := "○"
		if m.libraryChecked[ic.ID] {
			mark = "●"
		}
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%s %-30s %-8s %s", mark, ic.Display, ic.Version, ic.Vendor),
			Value:   "repo:" + ic.ID,
		})
	}
	if len(items) == 0 {
		msg := "  no other profile in the repo"
		if m.libraryIndex.SchemaVersion == 0 {
			msg = "  r checks the community repo"
		}
		items = append(items, tuikit.PickerItem{Display: msg, Disabled: true})
	}
	return items
}

func (m *model) openLibrary() tea.Cmd {
	m.push(scrLibrary)
	m.libraryTab = libInstalled
	m.libraryChecked = map[string]bool{}
	m.syncPicker()
	if dups := profiles.Duplicates(); len(dups) > 0 {
		m.toast, _ = m.toast.SetWarn(fmt.Sprintf("%d duplicate profile(s) — select a duplicate row to remove it", len(dups)))
	}
	if m.libraryIndex.SchemaVersion == 0 && !m.profileChecking {
		m.libraryLoading = true
		m.profileChecking = true
		return libraryIndexCmd()
	}
	return nil
}

func (m model) libraryKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	k := msg.String()
	switch k {
	case "esc", "backspace":
		m.pop()
		return m, nil
	case "left", "right":
		tab := libInstalled
		if k == "right" {
			tab = libAvailable
		}
		if m.libraryTab != tab {
			m.libraryTab = tab
			m.libraryChecked = map[string]bool{}
			m.syncPicker()
		}
		return m, nil
	case "r":
		m.libraryLoading = true
		m.libraryErr = ""
		m.libraryManual = true
		m.profileChecking = true
		m.toast, _ = m.toast.SetOK("Checking the community repo…")
		return m, libraryIndexCmd()
	case "i":
		return m.openInfo()
	case "e":
		if m.libraryTab == libInstalled {
			return m.exportSelected()
		}
	case "D":
		if m.libraryTab == libInstalled {
			cmd := m.promptUninstall(m.actionIDs())
			return m, cmd
		}
	case "O":
		if m.libraryTab == libAvailable {
			return m, openRepoCmd()
		}
	case "enter":
		val := m.picker.SelectedValue()
		switch {
		case strings.HasPrefix(val, "dup:"):
			parts := strings.SplitN(val, ":", 3)
			if len(parts) == 3 {
				if d, ok := findDuplicate(parts[1], parts[2]); ok {
					return m, m.promptDuplicate(d)
				}
			}
		case m.libraryTab == libAvailable && strings.HasPrefix(val, "repo:"):
			ids := m.actionIDs()
			if len(ids) == 0 {
				return m, nil
			}
			return m.startInstall(ids)
		case m.libraryTab == libInstalled && strings.HasPrefix(val, "card:"):
			return m.updateCursor()
		}
		return m, nil
	}
	// Everything else (arrows, j/k, tab, PgUp/PgDn, …) is normal picker
	// navigation. Without this the screen was frozen on its first row.
	var cmd tea.Cmd
	m.picker, cmd = m.picker.Update(msg)
	return m, cmd
}

// actionIDs returns the selected rows, or the row under the cursor when
// nothing is selected. Duplicate rows are never action targets.
func (m model) actionIDs() []string {
	var ids []string
	for id, on := range m.libraryChecked {
		if on {
			ids = append(ids, id)
		}
	}
	if len(ids) > 0 {
		sort.Strings(ids)
		return ids
	}
	val := m.picker.SelectedValue()
	for _, prefix := range []string{"card:", "repo:"} {
		if strings.HasPrefix(val, prefix) {
			return []string{strings.TrimPrefix(val, prefix)}
		}
	}
	return nil
}

// updateCursor installs the repo version of the highlighted installed card.
// Enter is the update action on the Installed tab.
func (m model) updateCursor() (tea.Model, tea.Cmd) {
	val := m.picker.SelectedValue()
	if !strings.HasPrefix(val, "card:") {
		return m, nil
	}
	id := strings.TrimPrefix(val, "card:")
	ic, ok := m.libraryIndex.Card(id)
	if !ok {
		return m, nil
	}
	inst, _, err := profiles.Effective(id)
	if err == nil && inst.Spec.Version == ic.Version {
		m.toast, _ = m.toast.SetOK(id + " is already up to date")
		return m, nil
	}
	return m.startInstall([]string{id})
}

// startInstall imports the cards, first offering to back up any local layout
// the repo layout is about to replace.
func (m model) startInstall(ids []string) (tea.Model, tea.Cmd) {
	sort.Strings(ids)
	var local []string
	for _, id := range ids {
		if profiles.HasUserUI(id) {
			local = append(local, id)
		}
	}
	if len(local) == 0 {
		m.libraryChecked = map[string]bool{}
		m.libraryLoading = true
		m.toast, _ = m.toast.SetOK("Installing " + strings.Join(ids, ", ") + "…")
		return m, libraryImportCmd(ids, false)
	}
	var b strings.Builder
	if len(local) == 1 {
		fmt.Fprintf(&b, "%s has a local layout.\n\n", local[0])
	} else {
		fmt.Fprintf(&b, "%s have local layouts.\n\n", strings.Join(local, ", "))
	}
	fmt.Fprintf(&b, "It will be backed up to\n%s\nbefore the repo layout replaces it.\n\nContinue?",
		profiles.UserUIBackupDir())
	m.confirm = tuikit.NewConfirm(b.String(), "Cancel", "Replace")
	m.confirmAct = func() tea.Cmd {
		return tea.Sequence(
			func() tea.Msg {
				return libraryBusyMsg{what: "Installing " + strings.Join(ids, ", ") + "…"}
			},
			libraryImportCmd(ids, true),
		)
	}
	m.push(scrConfirm)
	return m, nil
}

func (m model) openInfo() (tea.Model, tea.Cmd) {
	val := m.picker.SelectedValue()
	id := strings.TrimPrefix(strings.TrimPrefix(val, "card:"), "repo:")
	if id == "" || (!strings.HasPrefix(val, "card:") && !strings.HasPrefix(val, "repo:")) {
		return m, nil
	}
	m.info = tuikit.NewInfo(m.libraryDetail(id)).SetSize(m.contentSize())
	m.push(scrInfo)
	return m, nil
}

// repoNews counts what the index offers: updates for installed cards (the
// square in Settings) and repo cards that are not installed here.
func (m model) repoNews() (updates, installs int) {
	for _, ic := range m.libraryIndex.Cards {
		inst, _, err := profiles.Effective(ic.ID)
		if err != nil {
			installs++
			continue
		}
		if inst.Spec.Version != ic.Version {
			updates++
		}
	}
	return updates, installs
}

func repoNewsLabel(updates, installs int) string {
	var parts []string
	if updates > 0 {
		parts = append(parts, fmt.Sprintf("%d update(s)", updates))
	}
	if installs > 0 {
		parts = append(parts, fmt.Sprintf("%d to download", installs))
	}
	if len(parts) == 0 {
		return "everything is up to date"
	}
	return strings.Join(parts, ", ")
}

func findDuplicate(removeID, keepID string) (profiles.Duplicate, bool) {
	for _, d := range profiles.Duplicates() {
		if d.RemoveID == removeID && d.KeepID == keepID {
			return d, true
		}
	}
	return profiles.Duplicate{}, false
}

// promptDuplicate warns once per pair and offers to drop the redundant card.
// "Skip" leaves both entries exactly as they are; the duplicate row stays in
// the library so it can be handled later.
func (m *model) promptDuplicate(d profiles.Duplicate) tea.Cmd {
	key := d.RemoveID + ":" + d.KeepID
	if m.dupPrompted[key] {
		return nil
	}
	if m.dupPrompted == nil {
		m.dupPrompted = map[string]bool{}
	}
	m.dupPrompted[key] = true
	m.confirm = tuikit.NewConfirm(
		fmt.Sprintf("%s and %s look like the same interface.\nRemove \"%s\" and keep \"%s\"? Its local UI overrides are deleted with it.",
			d.RemoveDisplay, d.KeepDisplay, d.RemoveID, d.KeepID),
		"Skip", "Remove")
	m.confirmAct = func() tea.Cmd { return libraryRemoveCmd(d.RemoveID) }
	m.push(scrConfirm)
	return nil
}

func libraryRemoveCmd(id string) tea.Cmd {
	return func() tea.Msg {
		return libraryApplyMsg{what: "Removed " + id, err: profiles.Remove(id), checkDups: true}
	}
}

func (m model) exportSelected() (tea.Model, tea.Cmd) {
	ids := m.actionIDs()
	if len(ids) == 0 {
		m.toast, _ = m.toast.SetWarn("Tab selects cards to export")
		return m, nil
	}
	m.toast, _ = m.toast.SetOK("Exporting " + strings.Join(ids, ", "))
	return m, libraryExportCmd(ids)
}

// promptUninstall shows the exact list before anything is removed. Every
// installed card can be uninstalled now, embedded snapshots included: the
// profile is the card's only reader, so removing it removes the access.
func (m *model) promptUninstall(ids []string) tea.Cmd {
	if len(ids) == 0 {
		m.toast, _ = m.toast.SetWarn("Select a profile to uninstall")
		return nil
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Uninstall %d profile(s)?\n\n", len(ids))
	for _, id := range ids {
		if card, _, err := profiles.Effective(id); err == nil {
			fmt.Fprintf(&b, "  • %s  %s\n", card.Spec.Display, card.Spec.Version)
		} else {
			fmt.Fprintf(&b, "  • %s\n", id)
		}
	}
	b.WriteString("\nThis deletes the profile, its local UI overrides, its audio foundation setup (douze, oscmix, split files) and its history entry. A shared integration such as oscmix stays while another installed card still uses it.")
	m.confirm = tuikit.NewConfirm(b.String(), "Cancel", "Uninstall")
	m.confirmAct = func() tea.Cmd { return libraryUninstallCmd(ids) }
	m.push(scrConfirm)
	return nil
}

// libraryDetail is the info popup: what the card is, its installed and repo
// versions, and who made it.
func (m model) libraryDetail(id string) string {
	ic, inRepo := m.libraryIndex.Card(id)
	card, meta, err := profiles.Effective(id)
	if err != nil {
		if !inRepo {
			return err.Error()
		}
		var b strings.Builder
		fmt.Fprintf(&b, "%s (%s)\n\n", ic.Display, ic.Vendor)
		fmt.Fprintf(&b, "id         %s\n", ic.ID)
		b.WriteString("installed  not installed\n")
		fmt.Fprintf(&b, "repo       %s\n", ic.Version)
		if c := creditsLine(ic.Credits); c != "" {
			fmt.Fprintf(&b, "credits    %s\n", c)
		}
		b.WriteString("\nEnter downloads this profile.")
		return b.String()
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%s (%s)\n\n", card.Spec.Display, card.Spec.Vendor)
	fmt.Fprintf(&b, "id         %s\n", card.Spec.ID)
	installed := card.Spec.Version
	fmt.Fprintf(&b, "installed  %s\n", installed)
	if inRepo {
		repo := ic.Version
		if ic.Version != card.Spec.Version {
			repo += "  (update available)"
		}
		fmt.Fprintf(&b, "repo       %s\n", repo)
	} else {
		b.WriteString("repo       not in the repo (local only)\n")
	}
	if profiles.HasUserUI(id) {
		b.WriteString("layout     local override\n")
	}
	fmt.Fprintf(&b, "backend    %s\n", card.Spec.Backend)
	preset := card.Preset()
	if preset == "auto" {
		preset += " (layout follows the card backend)"
	}
	fmt.Fprintf(&b, "preset     %s\n", preset)
	credits := creditsLine(card.Credits)
	if credits == "" {
		credits = creditsLine(ic.Credits)
	}
	if credits != "" {
		fmt.Fprintf(&b, "credits    %s\n", credits)
	}
	fmt.Fprintf(&b, "\n%d input(s) · %d output pair(s) · mixer %d in / %d out\n",
		card.Spec.NumInputs, card.Spec.NumOutPairs, card.Spec.MixerInputs, card.Spec.MixerOutputs)
	if meta.Revision != "" {
		fmt.Fprintf(&b, "revision   %s\n", meta.Revision)
	}
	b.WriteString("\ni closes this popup.")
	return b.String()
}

// creditsLine renders "author, contributor, contributor". Cards made here
// credit mosquito; outside cards add their contributors.
func creditsLine(c profiles.Credits) string {
	var names []string
	if c.Author != "" {
		names = append(names, c.Author)
	}
	for _, n := range c.Contributors {
		if strings.TrimSpace(n) != "" {
			names = append(names, n)
		}
	}
	return strings.Join(names, ", ")
}

// libraryTabs draws the active tab as an accent block, like the EVO tab bar.
func (m model) libraryTabs(w int) string {
	tab := func(i int, label string) string {
		if m.libraryTab == i {
			return lipgloss.NewStyle().
				Background(tuikit.ColorAccent).
				Foreground(tuikit.ColorOnSurface).
				Bold(true).
				Render(" " + label + " ")
		}
		return lipgloss.NewStyle().Foreground(tuikit.ColorOnSurface).Render(" " + label + " ")
	}
	line := tab(libInstalled, "Installed") + "  " + tab(libAvailable, "Available")
	return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(line)
}
