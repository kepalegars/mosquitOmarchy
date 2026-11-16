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
	"unicode"

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
	ix       profiles.Index
	upstream map[string]profiles.Card
	err      error
}

type libraryApplyMsg struct {
	what string
	err  error
	// checkDups asks the screen to re-run duplicate detection (after an
	// install/update/remove), and offer removing a now-redundant scan card.
	checkDups bool
	// setupIDs lists the cards whose integration must run after the import,
	// in order (one terminal setup at a time).
	setupIDs []string
	id       string
	// focusID is the card page to open once the install (and its integration)
	// finishes; only notification clicks set it.
	focusID string
}

type libraryUninstallMsg struct {
	ids []string
	err error
}

// libraryBusyMsg is the first message of a sequence that shows progress while
// a multi-step install runs (backup, then download).
type libraryBusyMsg struct{ what string }

// cardOpenCmd is the notification click's final step: show the installed
// card's control page once there is nothing left to install.
func cardOpenCmd(id string) tea.Cmd {
	return func() tea.Msg { return cardOpenMsg{id: id} }
}

func libraryIndexCmd() tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
		defer cancel()
		ix, err := profiles.FetchIndex(ctx)
		return libraryIndexMsg{ix: ix, upstream: profiles.CheckUpstreams(ctx), err: err}
	}
}

func libraryImportCmd(ids []string, replaceUI bool, focusID string) tea.Cmd {
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
		msg := libraryApplyMsg{what: what, err: err, checkDups: err == nil && len(ids) == 1, id: ids[0], focusID: focusID}
		for _, r := range res {
			if r.Err == nil && r.Setup != "" {
				msg.setupIDs = append(msg.setupIDs, r.ID)
			}
		}
		return msg
	}
}

// libraryDeployUpstreamCmd writes a card fetched straight from its upstream
// URL. No second download: the confirmation applies exactly what was shown.
func libraryDeployUpstreamCmd(card profiles.Card) tea.Cmd {
	return func() tea.Msg {
		err := profiles.DeployCard(card)
		what := "Updated " + card.Spec.Display + " to " + card.Spec.Version
		return libraryApplyMsg{what: what, err: err, id: card.Spec.ID}
	}
}

// cardSetupCmd runs the integration a downloaded card declares. It goes
// through the foundation so the named integrations live in one place, and
// runs in the real terminal because the installers need sudo/build output.
// The foundation floor is not applied here: that waits for a first connection.
// The result popup offers the transcript like every other setup.
func cardSetupCmd(id string, after tea.Cmd) tea.Cmd {
	return setupCmd(id+" setup", after, "mixbay-audio-foundation", "--setup", "--device", id)
}

// setupChain runs one card integration after another, each in the real
// terminal, so a bulk install does not silently skip oscmix or evo-raw.
func setupChain(ids []string, after tea.Cmd) tea.Cmd {
	if len(ids) == 0 {
		return after
	}
	return cardSetupCmd(ids[0], setupChain(ids[1:], after))
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
		fmt.Fprintf(&script, "rm -rf \"${MIXBAY_CONFIG_DIR:-$HOME/.config/mosquitomixbay}/cards/%s\"\n", id)
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

// libraryMatch is the live filter: case- and punctuation-insensitive, so
// "ssl12" finds "SSL 12" and "quantum es" finds "PreSonus Quantum ES 4".
func (m model) libraryMatch(fields ...string) bool {
	q := libraryNorm(m.libraryFilterText)
	if q == "" {
		return true
	}
	for _, f := range fields {
		if strings.Contains(libraryNorm(f), q) {
			return true
		}
	}
	return false
}

func libraryNorm(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// installedItems lists every installed card with its repo state: up to date,
// update vX (plus the solid square) or local only.
func (m model) installedItems() []tuikit.PickerItem {
	var items []tuikit.PickerItem
	shown := 0
	for _, meta := range profiles.Installed() {
		mark := "○"
		if m.libraryChecked[meta.ID] {
			mark = "●"
		}
		status, badge := "up to date", ""
		ic, _ := m.libraryIndex.Card(meta.ID)
		target := ic.Version
		if up, ok := m.libraryUpstream[meta.ID]; ok && profiles.VersionLess(meta.Version, up.Spec.Version) {
			target = up.Spec.Version
		}
		switch {
		case m.libraryIndex.SchemaVersion == 0 && target == "":
			status = "not checked"
		case target == "":
			status = "local only"
		case target != meta.Version:
			status, badge = "update "+target, "■"
		}
		if !m.libraryMatch(meta.Display, meta.ID, meta.Version, status) {
			continue
		}
		items = append(items, tuikit.PickerItem{
			Display:       fmt.Sprintf("%s %-30s %-8s %s", mark, meta.Display, meta.Version, status),
			Value:         "card:" + meta.ID,
			TrailingBadge: badge,
		})
		shown++
	}
	dupsShown := 0
	if dups := profiles.Duplicates(); len(dups) > 0 {
		var rows []tuikit.PickerItem
		for _, d := range dups {
			if !m.libraryMatch(d.RemoveDisplay, d.KeepDisplay) {
				continue
			}
			rows = append(rows, tuikit.PickerItem{
				Display: fmt.Sprintf("  ! %s also matches %s", d.RemoveDisplay, d.KeepDisplay),
				Value:   "dup:" + d.RemoveID + ":" + d.KeepID,
			})
		}
		if len(rows) > 0 {
			items = append(items, tuikit.PickerItem{Display: "Duplicate entries", Heading: true})
			items = append(items, rows...)
			dupsShown = len(rows)
		}
	}
	if m.libraryFilterText != "" && shown+dupsShown == 0 {
		items = append(items, tuikit.PickerItem{
			Display:  fmt.Sprintf("  no installed profile matches %q", m.libraryFilterText),
			Disabled: true,
		})
	}
	if m.libraryFilterText == "" && m.libraryIndex.SchemaVersion == 0 && !m.libraryLoading && m.libraryErr == "" {
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
		if !m.libraryMatch(ic.Display, ic.ID, ic.Version, ic.Vendor) {
			continue
		}
		mark := "○"
		if m.libraryChecked[ic.ID] {
			mark = "●"
		}
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%s %-30s %-8s", mark, ic.Display, ic.Version),
			Value:   "repo:" + ic.ID,
		})
	}
	// Cards embedded in the binary but not published in the repo (the Move)
	// are installable too, and without the network: this is where they show
	// up, so "uninstall" is not a one-way door.
	for _, c := range profiles.NativeCards() {
		if _, _, err := profiles.Effective(c.Spec.ID); err == nil {
			continue
		}
		if _, inRepo := m.libraryIndex.Card(c.Spec.ID); inRepo {
			continue
		}
		if !m.libraryMatch(c.Spec.Display, c.Spec.ID, c.Spec.Vendor) {
			continue
		}
		mark := "○"
		if m.libraryChecked[c.Spec.ID] {
			mark = "●"
		}
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%s %-30s %-8s", mark, c.Spec.Display, c.Spec.Version),
			Value:   "native:" + c.Spec.ID,
		})
	}
	if len(items) == 0 {
		msg := "  no other profile in the repo"
		if m.libraryFilterText != "" {
			msg = fmt.Sprintf("  no available profile matches %q", m.libraryFilterText)
		} else if m.libraryIndex.SchemaVersion == 0 {
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
	m.libraryFilterOpen = false
	m.libraryFilterText = ""
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
	// Search: SHIFT+F (or /) toggles the framed filter zone, exactly like
	// mosquitomarchy's Setup. While it is open every printable key feeds the
	// live filter, so the per-tab shortcuts are not triggered by typing.
	if k == "F" || k == "shift+F" || k == "/" {
		m.libraryFilterOpen = !m.libraryFilterOpen
		if !m.libraryFilterOpen {
			m.libraryFilterText = ""
		}
		m.syncPicker()
		return m, nil
	}
	if m.libraryFilterOpen {
		switch k {
		case "esc":
			m.libraryFilterOpen = false
			m.libraryFilterText = ""
			m.syncPicker()
			return m, nil
		case "backspace":
			if m.libraryFilterText != "" {
				r := []rune(m.libraryFilterText)
				m.libraryFilterText = string(r[:len(r)-1])
				m.syncPicker()
			}
			return m, nil
		}
		if msg.Type == tea.KeyRunes && len(msg.Runes) > 0 {
			printable := true
			for _, r := range msg.Runes {
				if !unicode.IsPrint(r) {
					printable = false
				}
			}
			if printable {
				m.libraryFilterText += string(msg.Runes)
				m.syncPicker()
				return m, nil
			}
		}
	}
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
		case m.libraryTab == libAvailable &&
			(strings.HasPrefix(val, "repo:") || strings.HasPrefix(val, "native:")):
			ids := m.actionIDs()
			if len(ids) == 0 {
				return m, nil
			}
			return m.startInstall(ids, "")
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
	for _, prefix := range []string{"card:", "repo:", "native:"} {
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
	if err != nil {
		return m, nil
	}
	if up, ok := m.libraryUpstream[id]; ok && profiles.VersionLess(inst.Spec.Version, up.Spec.Version) {
		return m.promptUpstream(inst, up)
	}
	if inst.Spec.Version == ic.Version {
		m.toast, _ = m.toast.SetOK(id + " is already up to date")
		return m, nil
	}
	return m.startInstall([]string{id}, "")
}

// promptUpstream warns that this update bypasses the published index: the
// card is pulled straight from the profiles repository, so it may be newer
// than this Mixbay build expects.
func (m model) promptUpstream(inst, up profiles.Card) (tea.Model, tea.Cmd) {
	var b strings.Builder
	fmt.Fprintf(&b, "Update %s from %s to %s?\n\n", inst.Spec.Display, inst.Spec.Version, up.Spec.Version)
	b.WriteString("This update is not in the published profiles index yet: it is pulled directly from\n")
	b.WriteString("github.com/kepalegars/mosquito-mixbay-profiles.\n\n")
	b.WriteString("There is a very small risk that it is not fully compatible with this Mixbay build.\n")
	b.WriteString("If something breaks, uninstall the profile and install it again.\n\nContinue?")
	m.confirm = tuikit.NewConfirm(b.String(), "Cancel", "Update")
	m.confirmAct = func() tea.Cmd { return libraryDeployUpstreamCmd(up) }
	m.push(scrConfirm)
	return m, nil
}

// startInstall imports the cards, first offering to back up any local layout
// the repo layout is about to replace. focusID is the card page to reveal once
// the install completes (notification clicks); empty keeps the current screen.
func (m model) startInstall(ids []string, focusID string) (tea.Model, tea.Cmd) {
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
		return m, libraryImportCmd(ids, false, focusID)
	}
	var b strings.Builder
	if len(local) == 1 {
		fmt.Fprintf(&b, "%s has a local layout.\n\n", local[0])
	} else {
		fmt.Fprintf(&b, "%s have local layouts.\n\n", strings.Join(local, ", "))
	}
	fmt.Fprintf(&b, "It will be backed up to\n%s/<id>-<date>.json\nbefore the repo layout replaces it.\n\nContinue?",
		profiles.UserUIBackupDir())
	m.confirm = tuikit.NewConfirm(b.String(), "Cancel", "Replace")
	m.confirmAct = func() tea.Cmd {
		return tea.Sequence(
			func() tea.Msg {
				return libraryBusyMsg{what: "Installing " + strings.Join(ids, ", ") + "…"}
			},
			libraryImportCmd(ids, true, focusID),
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
	seen := map[string]bool{}
	for _, ic := range m.libraryIndex.Cards {
		seen[ic.ID] = true
		inst, _, err := profiles.Effective(ic.ID)
		if err != nil {
			installs++
			continue
		}
		target := ic.Version
		if up, ok := m.libraryUpstream[ic.ID]; ok && profiles.VersionLess(inst.Spec.Version, up.Spec.Version) {
			target = up.Spec.Version
		}
		if inst.Spec.Version != target {
			updates++
		}
	}
	for id, up := range m.libraryUpstream {
		if seen[id] {
			continue
		}
		if inst, _, err := profiles.Effective(id); err == nil &&
			profiles.VersionLess(inst.Spec.Version, up.Spec.Version) {
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
		parts = append(parts, fmt.Sprintf("%d available", installs))
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
	b.WriteString("\nThis deletes the profile, its local UI overrides, its audio foundation setup and its history entry.")
	if notes := uninstallIntegrationNotes(ids); notes != "" {
		b.WriteString("\n" + notes)
	}
	m.confirm = tuikit.NewConfirm(b.String(), "Cancel", "Uninstall")
	m.confirmAct = func() tea.Cmd { return libraryUninstallCmd(ids) }
	m.push(scrConfirm)
	return nil
}

// uninstallIntegrationNotes names only the integration the selected cards
// actually use. oscmix is shared by every RME profile: say whether it stays or
// goes with the last one instead of talking about it for an ESI UGM192.
func uninstallIntegrationNotes(ids []string) string {
	removing := map[string]bool{}
	for _, id := range ids {
		removing[id] = true
	}
	setups := map[string]bool{}
	for _, id := range ids {
		if c, _, err := profiles.Effective(id); err == nil && c.Spec.Setup != "" {
			setups[c.Spec.Setup] = true
		}
	}
	remaining := map[string]bool{}
	for _, m := range profiles.Installed() {
		if removing[m.ID] {
			continue
		}
		if c, _, err := profiles.Effective(m.ID); err == nil && c.Spec.Setup != "" {
			remaining[c.Spec.Setup] = true
		}
	}
	var notes []string
	if setups["oscmix"] {
		if remaining["oscmix"] {
			notes = append(notes, "oscmix is shared with the other installed RME cards and stays installed.")
		} else {
			notes = append(notes, "oscmix is removed completely too: no installed card will use it after this.")
		}
	}
	if setups["douze"] {
		notes = append(notes, "douze is uninstalled too (service, udev rule, PipeWire split and Omarchy360 plugin). SSL 12 mixer state in ~/.config/sslctl is kept.")
	}
	return strings.Join(notes, "\n")
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
	if up, ok := m.libraryUpstream[id]; ok && up.Spec.Version != card.Spec.Version {
		fmt.Fprintf(&b, "upstream   %s  (direct from the profiles repo, not in the index)\n", up.Spec.Version)
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

// libraryFilterRows is the height of the framed search box (top border,
// text, bottom border). The same blank rows are reserved when it is shut, so
// opening the search replaces empty space and never moves the list.
const libraryFilterRows = 3

// libraryFilterBar is the framed search field shared by both tabs, copied
// from mosquitomarchy's Setup/Addons filter zone.
func (m model) libraryFilterBar(w int) string {
	if !m.libraryFilterOpen {
		return strings.Join([]string{" ", " ", " "}, "\n")
	}
	inner := m.libraryFilterText + "▏"
	if m.libraryFilterText == "" {
		inner = lipgloss.NewStyle().Foreground(tuikit.ColorDisabled).Render("search")
	}
	fieldW := 44
	if w-12 < fieldW {
		fieldW = w - 12
	}
	if fieldW < 20 {
		fieldW = 20
	}
	inner = lipgloss.NewStyle().Width(fieldW).Align(lipgloss.Center).Render(inner)
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(tuikit.ColorAccent).
		Foreground(tuikit.ColorAccent).
		Padding(0, 4).
		Render(inner)
	return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(box)
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
