// Audio interface library — the TUI face of the community profile store.
//
// This screen is deliberately read-mostly: Enter installs a repo card, Tab
// marks cards for export, d removes a downloaded card, u drops a local UI
// override. Downloading only ever touches upstream/, so a profile update can
// never eat the user's layout tweaks.
package main

import (
	"context"
	"fmt"
	"os/exec"
	"sort"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	"mosquitomarchy.local/mosquitomixbay-tui/profiles"
	tuikit "mosquitomarchy.local/tui-kit"
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

type profileOfferMsg struct {
	offers []profiles.Offer
	ix     profiles.Index
	err    error
}

func libraryIndexCmd() tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		ix, err := profiles.FetchIndex(ctx)
		return libraryIndexMsg{ix: ix, err: err}
	}
}

func libraryImportCmd(id string) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		res, err := profiles.Import(ctx, []string{id})
		if err == nil && len(res) > 0 {
			err = res[0].Err
		}
		verb := "Downloaded"
		if err == nil && len(res) > 0 && res[0].Updated {
			verb = "Updated"
		}
		msg := libraryApplyMsg{what: verb + " " + id, err: err, checkDups: err == nil, id: id}
		if err == nil && len(res) > 0 {
			msg.setup = res[0].Setup
		}
		return msg
	}
}

// cardSetupCmd runs the integration a downloaded card declares. It goes
// through the foundation so the named integrations live in one place, and
// runs in the real terminal because the installers need sudo/build output.
// The foundation floor is not applied here: that waits for a first connection.
func cardSetupCmd(id string, checkDups bool) tea.Cmd {
	c := exec.Command("mixbay-audio-foundation", "--setup", "--device", id)
	return tea.ExecProcess(c, func(err error) tea.Msg {
		return libraryApplyMsg{what: "Set up " + id, err: err, checkDups: checkDups}
	})
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

func libraryRemoveCmd(id string) tea.Cmd {
	return func() tea.Msg {
		return libraryApplyMsg{what: "Removed " + id, err: profiles.Remove(id), checkDups: true}
	}
}

func libraryClearUserCmd(id string) tea.Cmd {
	return func() tea.Msg {
		return libraryApplyMsg{what: "Cleared local UI for " + id, err: profiles.ClearUser(id)}
	}
}

// profileCheckCmd offers an install/update at startup for interfaces in the
// connection log. Offline is a normal outcome: no prompt, local cards win.
func profileCheckCmd() tea.Cmd {
	return func() tea.Msg {
		entries := drivers.ConnectionLog()
		conns := make([]profiles.ConnEntry, 0, len(entries))
		for _, e := range entries {
			conns = append(conns, profiles.ConnEntry{ID: e.ID, Name: e.Name, Match: e.Match})
		}
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		defer cancel()
		ix, offers, err := profiles.CheckUpdatesWithIndex(ctx, conns)
		return profileOfferMsg{offers: offers, ix: ix, err: err}
	}
}

// libraryItems builds the installed + available list. Repo rows are only
// shown when the index was fetched; "Check community repo" is the fallback.
func (m *model) bindPreset() {
	m.preset = ""
	if c, _, err := profiles.Effective(m.deviceID); err == nil {
		m.preset = c.Preset()
	}
}

func (m model) libraryItems() []tuikit.PickerItem {
	items := []tuikit.PickerItem{{Display: "Installed profiles", Heading: true}}
	for _, meta := range profiles.Installed() {
		mark := "○"
		if m.libraryChecked[meta.ID] {
			mark = "●"
		}
		// Plain words beat "built-in | repo | local" and hide the preset id
		// (evo8/auto): the renderer name is a detail, not a state.
		status := "built in"
		switch meta.Source {
		case "repo":
			status = "downloaded"
		case "local":
			status = "local"
		}
		if ic, ok := m.libraryIndex.Card(meta.ID); ok && !ic.Native && ic.Version != meta.Version {
			status += "  ↑ " + ic.Version
		}
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("%s %-30s %-8s %s", mark, meta.Display, meta.Version, status),
			Value:   "card:" + meta.ID,
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
	switch {
	case m.libraryLoading:
		items = append(items, tuikit.PickerItem{Display: "  fetching index…", Disabled: true})
	case m.libraryErr != "":
		items = append(items, tuikit.PickerItem{Display: "  offline: " + m.libraryErr, Disabled: true})
	}
	available := 0
	for _, ic := range m.libraryIndex.Cards {
		if ic.Native {
			continue
		}
		installed, _, err := profiles.Effective(ic.ID)
		if err == nil && installed.Spec.Version == ic.Version {
			continue
		}
		verb := "download"
		if err == nil {
			verb = "update"
		}
		// ↓ separates "not installed yet" from the ○/● export marks above.
		items = append(items, tuikit.PickerItem{
			Display: fmt.Sprintf("↓ %-30s %-8s %-9s %s", ic.Display, ic.Version, ic.Vendor, verb),
			Value:   "repo:" + ic.ID,
		})
		available++
	}
	if m.libraryIndex.SchemaVersion > 0 && available == 0 {
		items = append(items, tuikit.PickerItem{Display: "  everything is up to date", Disabled: true})
	}
	items = append(items,
		tuikit.PickerItem{Display: "Actions", Heading: true},
		tuikit.PickerItem{Display: "  Export marked cards for a PR", Value: "export"},
		tuikit.PickerItem{Display: "  Open community repo", Value: "open-repo"},
		tuikit.PickerItem{Display: "Back", Value: "back"},
	)
	return items
}

func (m *model) openLibrary() tea.Cmd {
	m.push(scrLibrary)
	m.libraryChecked = map[string]bool{}
	m.syncPicker()
	if dups := profiles.Duplicates(); len(dups) > 0 {
		m.toast, _ = m.toast.SetWarn(fmt.Sprintf("%d duplicate profile(s) — select a duplicate row to remove it", len(dups)))
	}
	if m.libraryIndex.SchemaVersion == 0 {
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
	case "r":
		m.libraryLoading = true
		m.libraryErr = ""
		m.libraryManual = true
		m.profileChecking = true
		m.toast, _ = m.toast.SetOK("Checking the community repo…")
		return m, libraryIndexCmd()
	case "e":
		return m.exportChecked()
	case "enter":
		val := m.picker.SelectedValue()
		switch {
		case val == "back":
			m.pop()
		case val == "export":
			return m.exportChecked()
		case val == "open-repo":
			return m, openRepoCmd()
		case strings.HasPrefix(val, "repo:"):
			id := strings.TrimPrefix(val, "repo:")
			m.libraryLoading = true
			return m, libraryImportCmd(id)
		case strings.HasPrefix(val, "card:"):
			id := strings.TrimPrefix(val, "card:")
			m.info = tuikit.NewInfo(libraryDetail(id))
			m.push(scrInfo)
		case strings.HasPrefix(val, "dup:"):
			parts := strings.SplitN(val, ":", 3)
			if len(parts) == 3 {
				if d, ok := findDuplicate(parts[1], parts[2]); ok {
					return m, m.promptDuplicate(d)
				}
			}
		}
		return m, nil
	case "d":
		id := strings.TrimPrefix(m.picker.SelectedValue(), "card:")
		if !strings.HasPrefix(m.picker.SelectedValue(), "card:") {
			return m, nil
		}
		if profiles.IsNative(id) {
			m.toast, _ = m.toast.SetWarn("Native cards are built in and cannot be removed")
			return m, nil
		}
		m.confirm = tuikit.NewConfirm("Remove the downloaded profile \""+id+"\"? Local UI overrides go with it.", "Cancel", "Remove")
		m.confirmAct = func() tea.Cmd { return libraryRemoveCmd(id) }
		m.push(scrConfirm)
		return m, nil
	case "u":
		id := strings.TrimPrefix(m.picker.SelectedValue(), "card:")
		if !strings.HasPrefix(m.picker.SelectedValue(), "card:") {
			return m, nil
		}
		m.confirm = tuikit.NewConfirm("Drop the local UI override for \""+id+"\"?", "Cancel", "Clear")
		m.confirmAct = func() tea.Cmd { return libraryClearUserCmd(id) }
		m.push(scrConfirm)
		return m, nil
	}
	// Everything else (arrows, j/k, tab, PgUp/PgDn, …) is normal picker
	// navigation. Without this the screen was frozen on its first row.
	var cmd tea.Cmd
	m.picker, cmd = m.picker.Update(msg)
	return m, cmd
}

// repoNews counts what the index offers: updates for installed cards (the
// square in Settings) and repo cards that are not installed here.
func (m model) repoNews() (updates, installs int) {
	for _, ic := range m.libraryIndex.Cards {
		if ic.Native {
			continue
		}
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

func (m model) exportChecked() (tea.Model, tea.Cmd) {
	var ids []string
	for id, on := range m.libraryChecked {
		if on {
			ids = append(ids, id)
		}
	}
	if len(ids) == 0 {
		m.toast, _ = m.toast.SetWarn("Tab marks cards for export")
		return m, nil
	}
	sort.Strings(ids)
	m.toast, _ = m.toast.SetOK("Exporting " + strings.Join(ids, ", "))
	return m, libraryExportCmd(ids)
}

func libraryDetail(id string) string {
	card, meta, err := profiles.Effective(id)
	if err != nil {
		return err.Error()
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%s (%s)\n\n", card.Spec.Display, card.Spec.Vendor)
	fmt.Fprintf(&b, "id       %s\n", card.Spec.ID)
	fmt.Fprintf(&b, "version  %s\n", card.Spec.Version)
	fmt.Fprintf(&b, "source   %s\n", meta.Source)
	fmt.Fprintf(&b, "backend  %s\n", card.Spec.Backend)
	preset := card.Preset()
	if preset == "auto" {
		preset += " (layout follows the card backend)"
	}
	fmt.Fprintf(&b, "preset   %s\n", preset)
	blocks := card.Blocks()
	if len(blocks) == 0 {
		blocks = presetBlocks(card.Preset())
	}
	if len(blocks) > 0 {
		fmt.Fprintf(&b, "blocks   %s\n", strings.Join(blocks, ", "))
	}
	fmt.Fprintf(&b, "\n%d input(s) · %d output pair(s) · mixer %d in / %d out\n",
		card.Spec.NumInputs, card.Spec.NumOutPairs, card.Spec.MixerInputs, card.Spec.MixerOutputs)
	if meta.Revision != "" {
		fmt.Fprintf(&b, "revision %s\n", meta.Revision)
	}
	b.WriteString("\nTab marks this card for export to a PR folder.")
	return b.String()
}

// promptNextOffer asks once per session about the first available profile.
// The library screen handles the rest without interrupting the user again.
func (m *model) promptNextOffer(offers []profiles.Offer) tea.Cmd {
	if len(offers) == 0 || m.profilePrompted {
		return nil
	}
	m.profilePrompted = true
	o := profiles.SortedOffers(offers)[0]
	verb := "Download"
	if o.Kind == "update" {
		verb = "Update"
	}
	m.confirm = tuikit.NewConfirm(
		fmt.Sprintf("%s the community profile for %s (%s)?\nOnly the card data is downloaded; your local UI overrides are kept.", verb, o.Display, o.Version),
		"Later", verb)
	m.confirmAct = func() tea.Cmd { return libraryImportCmd(o.ID) }
	m.push(scrConfirm)
	return nil
}
