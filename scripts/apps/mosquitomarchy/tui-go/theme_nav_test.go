package main

import "testing"

// "Back" on the theme success screen must land on the main menu.
//
// It landed on the runner instead. The create path replaced the stack with
// [working] and then PUSHED the success screen, so Back popped exactly one
// screen and uncovered the runner: the raw log, no frame, no way off it. That
// read as "Back takes me to the log and traps me there", which is what it did.
func TestThemeDoneBackReachesTheMenu(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain}

	mm, _ := m.startWorking("Creating the theme", "theme-create")
	if mm.top() != scrWorking {
		t.Fatalf("the runner is not on top: %d", mm.top())
	}
	mm.themeCreated = "Nebula"
	mm.themeDonePicker = mm.rebuildThemeDone()
	mm.replace(scrThemeDone)

	if len(mm.nav) != 1 || mm.top() != scrThemeDone {
		t.Fatalf("stack is %v, want the success screen alone over the menu", mm.nav)
	}

	// The log opens OVER the success screen, and Back off it returns to the
	// success screen rather than past it to the log-less stack.
	mm.push(scrInfo)
	if mm.top() != scrInfo {
		t.Fatal("the log did not open")
	}
	mm.pop()
	if mm.top() != scrThemeDone {
		t.Fatalf("Back off the log landed on %d, want the success screen", mm.top())
	}

	mm.resetThemeFlow()
	mm.nav = []screen{scrMain, scrThemeDone}
	mm.pop()
	if mm.top() != scrMain {
		t.Fatalf("Back on the success screen landed on %d, want the main menu", mm.top())
	}
}

// Applying must not leave the success screen under the runner: the run then
// finishes on top of it again, and Esc pops whatever is left rather than the
// menu.
func TestThemeApplyDoesNotStack(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain}
	m.themeCreated = "Nebula"

	mm, _ := m.startWorking("Applying the theme", "theme-apply", "Nebula")
	if len(mm.nav) != 1 || mm.top() != scrWorking {
		t.Fatalf("stack is %v, want the runner alone over the menu", mm.nav)
	}

	done, _ := mm.update(themeCreateMsg{name: "Nebula"})
	if len(done.nav) != 1 || done.top() != scrMain {
		t.Fatalf("after applying, stack is %v, want the main menu alone", done.nav)
	}
}
