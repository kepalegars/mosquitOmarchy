package meters

import (
	"encoding/binary"
	"math"
	"strings"
	"testing"
	"time"
)

func f32(v float32) []byte {
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, math.Float32bits(v))
	return b
}

func TestAccumulatorInterleavesChannels(t *testing.T) {
	a := NewAccumulator(2)
	var raw []byte
	raw = append(raw, f32(0.25)...)
	raw = append(raw, f32(-0.75)...)
	raw = append(raw, f32(-0.5)...)
	raw = append(raw, f32(0.1)...)
	if err := a.AddRaw(raw); err != nil {
		t.Fatal(err)
	}
	got := a.Levels()
	if got[0] != 0.5 || got[1] != 0.75 {
		t.Fatalf("levels = %v, want [0.5 0.75]", got)
	}
	a.Reset()
	if got := a.Levels(); got[0] != 0 || got[1] != 0 {
		t.Fatalf("reset = %v", got)
	}
}

func TestAccumulatorRejectsPartialFrame(t *testing.T) {
	a := NewAccumulator(2)
	if err := a.AddRaw(make([]byte, 7)); err == nil {
		t.Fatal("partial frame must be rejected")
	}
}

func TestBallisticsAttackReleaseAndPeakHold(t *testing.T) {
	b := NewBallistics(1)
	now := time.Unix(0, 0)
	level, peak := b.Update([]float64{0.8}, now)
	if level[0] < 0.4 || peak[0] != 0.8 {
		t.Fatalf("attack = %v peak = %v", level, peak)
	}
	afterAttack := level[0]
	level, _ = b.Update([]float64{0}, now.Add(time.Millisecond))
	if level[0] >= afterAttack || level[0] <= 0.4 {
		t.Fatalf("release = %v (attack was %v)", level[0], afterAttack)
	}
	_, peak = b.Update([]float64{0}, now.Add(500*time.Millisecond))
	if peak[0] != 0.8 {
		t.Fatalf("peak must hold, got %v", peak[0])
	}
	_, peak = b.Update([]float64{0}, now.Add(2*time.Second))
	if peak[0] >= 0.8 {
		t.Fatalf("peak must decay after hold, got %v", peak[0])
	}
}

func TestBallisticsResetPeaks(t *testing.T) {
	b := NewBallistics(1)
	now := time.Unix(0, 0)
	b.Update([]float64{0.8}, now)
	b.ResetPeaks()
	_, peak := b.Update([]float64{0.1}, now.Add(time.Millisecond))
	if peak[0] != 0.1 {
		t.Fatalf("peak after reset = %v, want 0.1", peak[0])
	}
}

func TestRecordCommandUsesRawF32AndMonitorProperty(t *testing.T) {
	cmd := recordCommand(t.Context(), Source{Node: "node", Channels: 6, Monitor: true})
	args := strings.Join(cmd.Args, " ")
	for _, want := range []string{
		"pw-record",
		"--target node",
		"--rate 48000",
		"--channels 6",
		"--format f32",
		"--raw",
		"-P stream.capture.sink=true",
		"-",
	} {
		if !strings.Contains(args, want) {
			t.Fatalf("args %q missing %q", args, want)
		}
	}
}
