package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tuikit "mosquitomarchy.local/tui-kit"
)

// TestMain isolates the canonical instance-marker/PID directory. Production
// resolves that directory from $HOME only (never an override env var), so
// without this the tests would write real markers under the developer's home
// and could collide with a running manager.
func TestMain(m *testing.M) {
	home, err := os.MkdirTemp("", "move-manager-test-home-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "mkdtemp:", err)
		os.Exit(1)
	}
	os.Setenv("HOME", home)
	code := m.Run()
	os.RemoveAll(home)
	os.Exit(code)
}

func TestExtractBitwigPID(t *testing.T) {
	out := strings.Join([]string{
		"  … opening foo.als in Bitwig…",
		"  ✓ opened foo.als in Bitwig",
		"BITWIG_PID=4321",
	}, "\n")
	if got := extractBitwigPID(out); got != 4321 {
		t.Fatalf("extractBitwigPID = %d, want 4321", got)
	}
	if got := extractBitwigPID("BITWIG_PID="); got != 0 {
		t.Fatalf("empty sentinel = %d, want 0", got)
	}
	if got := extractBitwigPID("no sentinel here"); got != 0 {
		t.Fatalf("missing sentinel = %d, want 0", got)
	}
}

func TestDiscretionMarkerRoundTrip(t *testing.T) {
	pid := os.Getpid()
	t.Cleanup(func() { removeDiscretionMarker(pid) })

	writeDiscretionMarker(pid)
	data, err := os.ReadFile(discretionMarkerPath(pid))
	if err != nil {
		t.Fatalf("marker not written: %v", err)
	}
	if !strings.Contains(string(data), "mode=discretion") ||
		!strings.Contains(string(data), "pid=") {
		t.Fatalf("marker content = %q, want pid=… and mode=discretion", data)
	}
	removeDiscretionMarker(pid)
	if _, err := os.Stat(discretionMarkerPath(pid)); !os.IsNotExist(err) {
		t.Fatalf("marker still present after remove: %v", err)
	}
}

// TestBusyMarkerRoundTrip pins the busy marker: writeBusyMarker() writes
// mode=busy (not mode=discretion) for this PID and removeDiscretionMarker()
// clears it, so the dispatcher can skip an instance whose step is still
// running without waiting for it to reach discretion.
func TestBusyMarkerRoundTrip(t *testing.T) {
	pid := os.Getpid()
	t.Cleanup(func() { removeDiscretionMarker(pid) })

	writeBusyMarker(pid)
	data, err := os.ReadFile(discretionMarkerPath(pid))
	if err != nil {
		t.Fatalf("busy marker not written: %v", err)
	}
	if !strings.Contains(string(data), "mode=busy") ||
		!strings.Contains(string(data), "pid=") {
		t.Fatalf("busy marker content = %q, want pid=… and mode=busy", data)
	}
	removeDiscretionMarker(pid)
	if _, err := os.Stat(discretionMarkerPath(pid)); !os.IsNotExist(err) {
		t.Fatalf("busy marker still present after remove: %v", err)
	}
}

// TestStateDirIgnoresOverrideEnv pins the env-independence fix: a lingering
// MOSQUITO_MOVE_MANAGER_STATE_DIR (the old override) must NOT change where the
// TUI writes markers, or a differing value between launch paths would desync
// it from the dispatcher again — exactly the missed-marker bug.
func TestStateDirIgnoresOverrideEnv(t *testing.T) {
	t.Setenv("MOSQUITO_MOVE_MANAGER_STATE_DIR", filepath.Join(t.TempDir(), "elsewhere"))
	root := filepath.Join(os.Getenv("HOME"), ".local", "state", "mosquito-move-manager")
	if got, want := managerStateDir(), filepath.Join(root, "instances"); got != want {
		t.Fatalf("managerStateDir = %q, want %q", got, want)
	}
	if got, want := managerPidFilePath(), filepath.Join(root, "manager.pid"); got != want {
		t.Fatalf("managerPidFilePath = %q, want %q", got, want)
	}
}

// TestStateDrivenMarker pins the screen-driven marker that replaced the old
// "write busy only at the Bitwig handoff" scheme: entering any active step
// marks the instance busy immediately, returning to a normal menu clears the
// marker so the instance is replaceable again, and discretion wins.
func TestStateDrivenMarker(t *testing.T) {
	pid := os.Getpid()
	t.Cleanup(func() { removeDiscretionMarker(pid) })

	m := initialModel()
	m.push(scrConverting)
	m.syncWorkMarker()
	if m.markerMode != "busy" {
		t.Fatalf("markerMode on scrConverting = %q, want busy", m.markerMode)
	}
	data, err := os.ReadFile(discretionMarkerPath(pid))
	if err != nil {
		t.Fatalf("busy marker not written on scrConverting: %v", err)
	}
	if !strings.Contains(string(data), "mode=busy") {
		t.Fatalf("marker = %q, want mode=busy", data)
	}

	m.pop()
	m.syncWorkMarker()
	if m.markerMode != "" {
		t.Fatalf("markerMode on scrMain = %q, want empty", m.markerMode)
	}
	if _, err := os.Stat(discretionMarkerPath(pid)); !os.IsNotExist(err) {
		t.Fatalf("marker still present on scrMain: %v", err)
	}

	m.discretion = true
	m.syncWorkMarker()
	if m.markerMode != "discretion" {
		t.Fatalf("markerMode in discretion = %q, want discretion", m.markerMode)
	}
}

func TestRemoveManagerPidFile(t *testing.T) {
	pf := managerPidFilePath()
	if err := os.MkdirAll(filepath.Dir(pf), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pf, []byte("1234\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	removeManagerPidFile()
	if _, err := os.Stat(pf); !os.IsNotExist(err) {
		t.Fatalf("pid file still present after remove: %v", err)
	}
}

// TestDiscretionRendersNothingAndStopsTicks pins the "~no CPU, no rendering"
// contract: a discretion model draws an empty frame and drops the recurring
// theme tick instead of re-arming it.
func TestDiscretionRendersNothingAndStopsTicks(t *testing.T) {
	m := initialModel()
	m.discretion = true
	if got := m.View(); got != "" {
		t.Fatalf("View() in discretion = %q, want empty", got)
	}
	_, cmd := m.Update(tuikit.ThemeTickMsg(time.Now()))
	if cmd != nil {
		t.Fatalf("discretion re-armed a theme tick (cmd != nil)")
	}
}
