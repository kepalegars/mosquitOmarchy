package main

import (
	"strings"
	"testing"

	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
)

func TestLiveSessionDemoIsWritable(t *testing.T) {
	s := liveSession{}
	st := drivers.Status{Online: false, Backend: drivers.BackendDemo, Note: "DEMO", Inputs: []drivers.InputState{{GainDb: 4}}}
	got, ok := s.apply(statusMsg{status: st, demo: true, quiet: true, gen: s.beginRead()})
	if !ok || got.Note != "DEMO" || got.Inputs[0].GainDb != 4 {
		t.Fatalf("demo seed not applied: ok=%v status=%+v", ok, got)
	}
	if !s.canWrite() {
		t.Fatal("a demo session must stay writable")
	}
}

func TestLiveSessionFreezesAndReconnects(t *testing.T) {
	s := liveSession{}
	live := drivers.Status{Online: true, Inputs: []drivers.InputState{{GainDb: 12}}}
	if _, ok := s.apply(statusMsg{status: live, quiet: true, gen: s.beginRead()}); !ok {
		t.Fatal("live read should apply")
	}
	if !s.canWrite() {
		t.Fatal("online session must accept writes")
	}

	frozen, ok := s.apply(statusMsg{err: drivers.ErrOffline, quiet: true, gen: s.beginRead()})
	if !ok {
		t.Fatal("offline read should freeze the last values")
	}
	if frozen.Inputs[0].GainDb != 12 || frozen.Online {
		t.Fatalf("freeze = %+v, want gain 12 and online=false", frozen)
	}
	if !strings.Contains(frozen.Note, "offline") {
		t.Errorf("offline note missing: %q", frozen.Note)
	}
	if s.canWrite() {
		t.Fatal("a lost live session must refuse writes")
	}

	back := drivers.Status{Online: true, Inputs: []drivers.InputState{{GainDb: 20}}}
	got, ok := s.apply(statusMsg{status: back, quiet: true, gen: s.beginRead()})
	if !ok || got.Inputs[0].GainDb != 20 {
		t.Fatalf("reconnect not applied: ok=%v status=%+v", ok, got)
	}
	if !s.canWrite() {
		t.Fatal("reconnected session must accept writes again")
	}
}

// A user refresh after unplugging asks Status(), which returns DEMO. That
// payload must not demote a live session.
func TestLiveSessionDemoCannotDemoteLive(t *testing.T) {
	s := liveSession{}
	live := drivers.Status{Online: true, Inputs: []drivers.InputState{{GainDb: 12}}}
	s.apply(statusMsg{status: live, quiet: true, gen: s.beginRead()})
	s.apply(statusMsg{err: drivers.ErrOffline, quiet: true, gen: s.beginRead()})

	demo := drivers.Status{Online: false, Backend: drivers.BackendDemo, Note: "DEMO", Inputs: []drivers.InputState{{GainDb: 99}}}
	if _, ok := s.apply(statusMsg{status: demo, demo: true, quiet: true, gen: s.beginRead()}); ok {
		t.Fatal("demo payload must not replace a frozen live session")
	}
	if s.canWrite() {
		t.Fatal("demo payload must not reopen writes")
	}
}

func TestLiveSessionDropsStalePolls(t *testing.T) {
	s := liveSession{}
	s.apply(statusMsg{status: drivers.Status{Online: true}, quiet: true, gen: s.beginRead()})
	gen := s.beginRead()
	s.wrote()
	stale := drivers.Status{Online: true, Note: "stale"}
	if _, ok := s.apply(statusMsg{status: stale, quiet: true, gen: gen}); ok {
		t.Fatal("a poll started before the last write must be dropped")
	}
}

func TestLiveSessionSelectResetsToDemo(t *testing.T) {
	s := liveSession{}
	s.apply(statusMsg{status: drivers.Status{Online: true}, quiet: true, gen: s.beginRead()})
	s.apply(statusMsg{err: drivers.ErrOffline, quiet: true, gen: s.beginRead()})
	s.selectDevice()
	if !s.canWrite() {
		t.Fatal("re-selecting a device starts a writable demo session")
	}
	demo := drivers.Status{Online: false, Backend: drivers.BackendDemo, Note: "DEMO"}
	if _, ok := s.apply(statusMsg{status: demo, demo: true, quiet: true, gen: s.beginRead()}); !ok {
		t.Fatal("demo seed after re-select should apply")
	}
}
