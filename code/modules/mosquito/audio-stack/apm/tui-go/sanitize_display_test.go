package main

import (
	"strings"
	"testing"
)

// A folder picker running inside this terminal once wrote its own alt-screen
// init/exit bytes into DOWNLOADS_DIR, and every later render of the settings
// row re-emitted them — including ESC[?1049l, which kicks the terminal OUT of
// the TUI's alt-screen mid-frame and breaks the display permanently (bizarre
// first render of the settings page, rows "revealed" progressively by cursor
// moves). sanitizeDisplay is the display-side containment: no backend string
// may ever reach a row label with escape/control bytes intact.
func TestSanitizeDisplayStripsTerminalSequences(t *testing.T) {
	poisoned := "\x1b[?2026$p\x1b[?2027$p\x1b[>4m\x1b[=0;1u\x1b[?1049h\x1b[?25l" +
		"\x1b[?2004h\x1b]2;superfile\x07\x1b[H\x1b[2J\x1b[?1049l\x1b[?25h" +
		"/run/media/mosquito/Crucial X9/plugins from windows"
	got := sanitizeDisplay(poisoned)
	if strings.Contains(got, "\x1b") {
		t.Fatalf("sanitizeDisplay left escape bytes: %q", got)
	}
	if !strings.Contains(got, "/run/media/mosquito/Crucial X9/plugins from windows") {
		t.Fatalf("sanitizeDisplay ate the real path: %q", got)
	}
	// The exact byte from the poisoned prefs file must be gone in
	// particular: emitting it exits the alt-screen.
	if strings.Contains(got, "[?1049l") {
		t.Fatalf("sanitizeDisplay left the alt-screen-exit sequence: %q", got)
	}
}

// Sourcing the prefs file expands $p to nothing, so the runtime value is
// NOT the stored bytes: sequences arrive WITHOUT their final byte
// ("\x1b[?2026" + ESC), which the complete-sequence matcher cannot fire on.
// These fragments must go too — they render as literal "?2026" garbage.
func TestSanitizeDisplayStripsFragmentSequences(t *testing.T) {
	runtime := "\x1b[?2026\x1b[?2027\x1b[>4m\x1b[=0;1u\x1b[?1049h/run/media/mosquito/Crucial X9/plugins from windows"
	got := sanitizeDisplay(runtime)
	if strings.Contains(got, "\x1b") || strings.Contains(got, "?2026") || strings.Contains(got, ">4m") {
		t.Fatalf("sanitizeDisplay left fragments: %q", got)
	}
	if !strings.Contains(got, "/run/media/mosquito/Crucial X9/plugins from windows") {
		t.Fatalf("sanitizeDisplay ate the real path: %q", got)
	}
}

func TestShortPathNeverEmitsEscapes(t *testing.T) {
	poisoned := "\x1b[?1049h\x1b]2;superfile\x07/run/media/mosquito/Crucial X9/plugins from windows"
	got := shortPath(poisoned)
	if strings.Contains(got, "\x1b") {
		t.Fatalf("shortPath emitted escape bytes: %q", got)
	}
	if strings.Contains(got, "\n") {
		t.Fatalf("shortPath emitted a newline: %q", got)
	}
}

func TestSanitizeDisplayKeepsLegitPaths(t *testing.T) {
	for _, p := range []string{
		"/home/mosquito/Music/Audio Plugins",
		"/run/media/mosquito/Crucial X9/plugins from windows",
		"~/.wine-vst",
		"",
	} {
		if got := sanitizeDisplay(p); got != p {
			t.Errorf("sanitizeDisplay(%q) = %q, want unchanged", p, got)
		}
	}
}
