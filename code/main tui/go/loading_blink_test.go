package main

import "testing"

// The loading indicator is a blinking square, not a spinner. It must toggle
// between the solid square and an invisible (space) frame without changing
// the row's width, and stop once the check has landed.
func TestLoadingSquareBlinks(t *testing.T) {
	m := initialModel()
	m.nav = []screen{scrMain}
	m.w, m.h = 100, 34
	m.updateChecking, m.healthChecking = true, true
	m.loadingFrame = 0
	m.mainPicker = m.rebuildMainMenu()
	if !updateSquareOnMainRow(m) {
		t.Fatal("the first loading frame should show the square")
	}
	m.loadingFrame = 1
	m.mainPicker = m.rebuildMainMenu()
	if updateSquareOnMainRow(m) {
		t.Fatal("the second loading frame should be the off phase")
	}
}
