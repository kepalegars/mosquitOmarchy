package main

import (
	"testing"

	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
)

// The Levels page is spec-driven now: EVO 4 must get its own 4-channel
// layout, not the EVO 8's six bars with two dead channels.
func TestEVOMeterBarsFollowSpec(t *testing.T) {
	cases := []struct {
		spec     drivers.Spec
		capture  []string
		playback []string
	}{
		{
			spec:     drivers.EVO4Spec,
			capture:  []string{"IN1", "IN2", "LP3", "LP4"},
			playback: []string{"PC1", "PC2", "LP3", "LP4"},
		},
		{
			spec:     drivers.EVO8Spec,
			capture:  []string{"IN1", "IN2", "IN3", "IN4", "LP5", "LP6"},
			playback: []string{"PC1", "PC2", "PC3", "PC4", "LP5", "LP6"},
		},
	}
	for _, tc := range cases {
		gotC := evoCaptureBarsFor(tc.spec)
		if len(gotC) != len(tc.capture) {
			t.Fatalf("%s capture bars: got %d, want %d", tc.spec.ID, len(gotC), len(tc.capture))
		}
		for i, want := range tc.capture {
			if gotC[i].label != want || gotC[i].ch != i {
				t.Fatalf("%s capture[%d] = %q/%d, want %q/%d", tc.spec.ID, i, gotC[i].label, gotC[i].ch, want, i)
			}
		}
		gotP := evoPlaybackBarsFor(tc.spec)
		if len(gotP) != len(tc.playback) {
			t.Fatalf("%s playback bars: got %d, want %d", tc.spec.ID, len(gotP), len(tc.playback))
		}
		for i, want := range tc.playback {
			if gotP[i].label != want || gotP[i].ch != i {
				t.Fatalf("%s playback[%d] = %q/%d, want %q/%d", tc.spec.ID, i, gotP[i].label, gotP[i].ch, want, i)
			}
		}
	}
}
