package main

import (
	"strings"
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// The Cleanup settings page is all-on except the one option that can invalidate
// a stored Wine reference, and "Cleanup now!" sits immediately before Back.
func TestCleanupDefaultsOrderAndToggle(t *testing.T) {
	m := initialModel()
	if len(m.cleanupOpts) != len(cleanupOrder) {
		t.Fatalf("cleanup opts = %d, want %d", len(m.cleanupOpts), len(cleanupOrder))
	}
	for _, id := range cleanupOrder {
		want := id != "apm-drives"
		if m.cleanupOpts[id] != want {
			t.Fatalf("%s = %v, want %v", id, m.cleanupOpts[id], want)
		}
	}

	// Enter on the drive-letter toggle flips only the local option set.
	m.nav = []screen{scrMain, scrSettings, scrCleanup}
	m, _ = m.update(tuikit.PickerToggleOptionMsg{
		Value: "cleanup:apm-drives", Next: true, Previous: false,
	})
	if !m.cleanupOpts["apm-drives"] {
		t.Fatal("drive-letter toggle did not turn on")
	}

	picker := m.rebuildCleanup()
	if picker.Len() != len(cleanupOrder)+2 {
		t.Fatalf("cleanup picker has %d rows, want %d", picker.Len(), len(cleanupOrder)+2)
	}
	if got := picker.items[picker.Len()-1].Value; got != "back" {
		t.Fatalf("last row = %q, want back", got)
	}
	if got := picker.items[picker.Len()-2].Value; got != "run" {
		t.Fatalf("second-to-last row = %q, want run", got)
	}
	for i, row := range picker.items[:len(cleanupOrder)] {
		id := cleanupOrder[i]
		if row.Value != "cleanup:"+id {
			t.Fatalf("row %d = %q, want cleanup:%s", i, row.Value, id)
		}
		if row.Toggle == nil {
			t.Fatalf("row %d (%s) is not a toggle", i, id)
		}
		if row.Toggle.Value != m.cleanupOpts[id] {
			t.Fatalf("row %d shows %v, model has %v", i, row.Toggle.Value, m.cleanupOpts[id])
		}
	}

	if got := m.selectedCleanupIDs(); len(got) != len(cleanupOrder) {
		t.Fatalf("selected ids = %d, want all %d after toggling the last one on", len(got), len(cleanupOrder))
	}
}

// The "Cleanup now!" row must open a confirmation with the measured size, the
// free space and the Yes button focused, before anything is deleted.
func TestCleanupPreviewOpensConfirmWithSizes(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain, scrSettings, scrCleanup}
	m.cleanupOpts = defaultCleanupOpts()
	m, _ = m.update(cleanupPreviewMsg{
		ids: []string{"setup-cache", "lists-cache"},
		preview: cleanupPreview{
			Bytes: 2 << 30,
			Free:  6 << 30,
			Items: []cleanupPreviewItem{
				{ID: "setup-cache", Bytes: 1 << 30},
				{ID: "lists-cache", Bytes: 1 << 30},
			},
		},
	})
	if m.top() != scrConfirm {
		t.Fatalf("top = %v, want the confirmation screen", m.top())
	}
	if m.pendingAction != "cleanup" || len(m.pendingArgs) != 2 {
		t.Fatalf("pending cleanup = %q / %v", m.pendingAction, m.pendingArgs)
	}
	for _, want := range []string{"2.0 GB", "6.0 GB", "8.0 GB"} {
		if !strings.Contains(m.confirm.Message, want) {
			t.Fatalf("confirmation missing %q:\n%s", want, m.confirm.Message)
		}
	}
	if len(m.confirm.List) != 2 {
		t.Fatalf("confirmation list = %v, want the two selected cleanups", m.confirm.List)
	}
}
