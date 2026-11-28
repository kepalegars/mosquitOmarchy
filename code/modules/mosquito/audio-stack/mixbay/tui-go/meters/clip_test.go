package meters

import (
	"testing"
	"time"
)

func TestClipTrackerHoldAndExpiry(t *testing.T) {
	c := NewClipTracker()
	now := time.Unix(1000, 0)
	c.Update(Snapshot{
		Peaks: map[string][]float64{KeyInput: {0.4, 0.995}},
	}, now)
	if !c.Active(KeyInput, 1, now) {
		t.Fatal("clipped channel must be active immediately")
	}
	if c.Active(KeyInput, 0, now) {
		t.Fatal("clean channel must not be marked")
	}
	if !c.Active(KeyInput, 1, now.Add(ClipHold-time.Millisecond)) {
		t.Fatal("clip must hold for the full window")
	}
	if c.Active(KeyInput, 1, now.Add(ClipHold+time.Millisecond)) {
		t.Fatal("clip must expire after the hold")
	}
}

func TestClipTrackerLevelBindingAndReset(t *testing.T) {
	c := NewClipTracker()
	now := time.Unix(2000, 0)
	c.Update(Snapshot{Playback: []float64{1}}, now)
	if !c.Active(KeyPlayback, 0, now) {
		t.Fatal("declared playback levels must mark a clip")
	}
	c.Reset()
	if c.Active(KeyPlayback, 0, now) {
		t.Fatal("Reset must clear the hold")
	}
}
