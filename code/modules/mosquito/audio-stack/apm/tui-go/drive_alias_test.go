package main

import "testing"

// The VST menu advertises the cleanup only when there is something to clean,
// so a tidy machine never opens a confirmation that would remove nothing.
func TestDriveAliasRow(t *testing.T) {
	clean := vstMenuItems(Status{})
	for _, it := range clean {
		if it.Value == "cleanup_drive_aliases" {
			if !it.Disabled {
				t.Fatalf("clean machine row = %q, want disabled", it.Display)
			}
		}
	}
	dirty := vstMenuItems(Status{DriveAliases: 4})
	found := false
	for _, it := range dirty {
		if it.Value == "cleanup_drive_aliases" {
			found = true
			if it.Disabled {
				t.Fatalf("row with 4 aliases is disabled")
			}
			if it.Display != "Clean up redundant wine drive letters (4)" {
				t.Fatalf("row = %q", it.Display)
			}
		}
	}
	if !found {
		t.Fatal("drive-alias cleanup row missing")
	}

	blocked := vstMenuItems(Status{DriveAliases: 5, DriveAliasBlocked: 5, DriveAliasBlockedNames: ".wine-vst"})
	for _, it := range blocked {
		if it.Value == "cleanup_drive_aliases" {
			if !it.Disabled {
				t.Fatal("blocked-only row must be disabled")
			}
			if it.Display != "Wine drive letters: 5 pending — close .wine-vst first" {
				t.Fatalf("blocked row = %q", it.Display)
			}
		}
	}
}

func TestDriveAliasCleanupConfirmOpens(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.status = Status{DriveAliases: 3}
	m.nav = []screen{scrMain, scrVstMenu}
	next, _ := m.handleVstMenuChoice("cleanup_drive_aliases")
	mm, ok := next.(model)
	if !ok {
		t.Fatalf("handler returned %T, want model", next)
	}
	if got, want := mm.top(), scrDriveAliasConfirm; got != want {
		t.Fatalf("top = %v, want scrDriveAliasConfirm", got)
	}
	_ = mm.View() // the confirm must render, never panic
}
