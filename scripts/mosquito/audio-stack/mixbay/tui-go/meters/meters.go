// Package meters captures the EVO USB playback monitor and hardware input
// stream and turns raw f32 frames into smoothed per-channel levels.
//
// It deliberately knows nothing about the TUI: the renderer only receives
// linear 0..1 peaks and decides how to draw or freeze them.
package meters

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	KeyPlayback = "playback"
	KeyInput    = "input"

	DefaultRate   = 48000
	DefaultFrames = 480 // 10 ms blocks at 48 kHz
	DefaultTick   = 33 * time.Millisecond
)

// Source is one pw-record capture. Monitor=true asks PipeWire for a sink
// monitor (stream.capture.sink), which is how the USB playback channels are
// observed without touching the hardware output mix.
type Source struct {
	Key      string
	Node     string
	Channels int
	Monitor  bool
}

// Snapshot is the latest smoothed state. Levels are linear peak amplitudes
// (0..1) in channel order; Peaks hold the recent maximum.
type Snapshot struct {
	Playback []float64
	Input    []float64
	Peaks    map[string][]float64
	Errors   []string
}

// Engine owns the pw-record children and one ticker that publishes snapshots.
type Engine struct {
	updates chan Snapshot
	cancel  context.CancelFunc
	wg      sync.WaitGroup
	once    sync.Once
}

type partial struct {
	key    string
	levels []float64
	err    error
}

// Start launches one pw-record per source. A missing binary or a rejected
// node is reported through Snapshot.Errors instead of failing Start, so the
// TUI can render the meter panel with a useful message.
func Start(sources []Source) *Engine {
	ctx, cancel := context.WithCancel(context.Background())
	e := &Engine{updates: make(chan Snapshot, 4), cancel: cancel}
	ch := make(chan partial, 16)

	for _, src := range sources {
		e.wg.Add(1)
		go e.capture(ctx, src, ch)
	}
	e.wg.Add(1)
	go e.publish(ctx, sources, ch)
	return e
}

func (e *Engine) Updates() <-chan Snapshot { return e.updates }

// Stop kills the captures and waits for their pipes to close. Safe to call
// more than once.
func (e *Engine) Stop() {
	e.once.Do(func() {
		e.cancel()
		e.wg.Wait()
		close(e.updates)
	})
}

func (e *Engine) capture(ctx context.Context, src Source, out chan<- partial) {
	defer e.wg.Done()
	cmd := recordCommand(ctx, src)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		sendPartial(ctx, out, partial{key: src.Key, err: err})
		return
	}
	if err := cmd.Start(); err != nil {
		sendPartial(ctx, out, partial{key: src.Key, err: err})
		return
	}
	defer func() {
		_ = cmd.Wait()
	}()

	acc := NewAccumulator(src.Channels)
	buf := make([]byte, DefaultFrames*src.Channels*4)
	for {
		if _, err := io.ReadFull(stdout, buf); err != nil {
			if ctx.Err() == nil {
				sendPartial(ctx, out, partial{key: src.Key, err: captureErr(err, stderr.String())})
			}
			return
		}
		if err := acc.AddRaw(buf); err != nil {
			sendPartial(ctx, out, partial{key: src.Key, err: err})
			return
		}
		levels := acc.Levels()
		if !sendPartial(ctx, out, partial{key: src.Key, levels: levels}) {
			return
		}
		acc.Reset()
	}
}

func sendPartial(ctx context.Context, out chan<- partial, p partial) bool {
	select {
	case out <- p:
		return true
	case <-ctx.Done():
		return false
	}
}

func captureErr(err error, stderr string) error {
	msg := strings.TrimSpace(stderr)
	if msg == "" {
		return err
	}
	if i := strings.LastIndexByte(msg, '\n'); i >= 0 {
		msg = msg[i+1:]
	}
	return fmt.Errorf("%w (%s)", err, msg)
}

func (e *Engine) publish(ctx context.Context, sources []Source, in <-chan partial) {
	defer e.wg.Done()
	ticker := time.NewTicker(DefaultTick)
	defer ticker.Stop()

	latest := map[string][]float64{}
	smoothers := map[string]*Ballistics{}
	for _, src := range sources {
		smoothers[src.Key] = NewBallistics(src.Channels)
	}
	errs := map[string]string{}
	for {
		select {
		case <-ctx.Done():
			return
		case p := <-in:
			if p.err != nil {
				errs[p.key] = p.err.Error()
				continue
			}
			latest[p.key] = p.levels
			delete(errs, p.key)
		case now := <-ticker.C:
			snap := Snapshot{Peaks: map[string][]float64{}}
			for _, src := range sources {
				b := smoothers[src.Key]
				if b == nil {
					continue
				}
				levels, peaks := b.Update(latest[src.Key], now)
				snap.Peaks[src.Key] = peaks
				if src.Key == KeyPlayback {
					snap.Playback = levels
				} else {
					snap.Input = levels
				}
			}
			for _, src := range sources {
				if msg := errs[src.Key]; msg != "" {
					snap.Errors = append(snap.Errors, msg)
				}
			}
			select {
			case e.updates <- snap:
			default:
				// A slow UI frame skips one update; meters must never block
				// the audio pipes.
			}
		}
	}
}

// recordCommand is split out so the argument contract (raw f32, fixed rate,
// sink monitor property) is testable without spawning audio processes.
func recordCommand(ctx context.Context, src Source) *exec.Cmd {
	args := []string{
		"--target", src.Node,
		"--rate", strconv.Itoa(DefaultRate),
		"--channels", strconv.Itoa(src.Channels),
		"--format", "f32",
		"--raw",
		"--latency", "50ms",
	}
	if src.Monitor {
		args = append(args, "-P", "stream.capture.sink=true")
	}
	args = append(args, "-")
	return exec.CommandContext(ctx, "pw-record", args...)
}

// Accumulator keeps the absolute peak of each channel in one read block.
type Accumulator struct {
	channels int
	peak     []float64
}

func NewAccumulator(channels int) *Accumulator {
	if channels < 1 {
		channels = 1
	}
	return &Accumulator{channels: channels, peak: make([]float64, channels)}
}

func (a *Accumulator) Reset() {
	for i := range a.peak {
		a.peak[i] = 0
	}
}

func (a *Accumulator) Levels() []float64 {
	out := make([]float64, len(a.peak))
	copy(out, a.peak)
	return out
}

// AddRaw decodes interleaved little-endian f32 samples and keeps each
// channel's absolute peak. A partial frame is rejected: pw-record's pipe can
// split on any byte, but the reader always hands us whole blocks.
func (a *Accumulator) AddRaw(data []byte) error {
	frame := a.channels * 4
	if len(data) == 0 || len(data)%frame != 0 {
		return fmt.Errorf("meters: block of %d bytes is not whole %d-channel frames", len(data), a.channels)
	}
	for off := 0; off < len(data); off += 4 {
		bits := binary.LittleEndian.Uint32(data[off : off+4])
		v := math.Abs(float64(math.Float32frombits(bits)))
		ch := (off / 4) % a.channels
		if v > a.peak[ch] {
			a.peak[ch] = v
		}
	}
	return nil
}

// Ballistics smooths peaks with a fast attack, slow release and a peak hold.
// The time constants are fixed: meters are a display aid, not a measurement.
type Ballistics struct {
	levels []float64
	peaks  []float64
	until  []time.Time
	last   time.Time

	attack  float64
	release float64
	hold    time.Duration
	decay   float64
}

func NewBallistics(channels int) *Ballistics {
	if channels < 1 {
		channels = 1
	}
	return &Ballistics{
		levels:  make([]float64, channels),
		peaks:   make([]float64, channels),
		until:   make([]time.Time, channels),
		attack:  0.65,
		release: 0.10,
		hold:    1500 * time.Millisecond,
		decay:   0.97,
	}
}

func (b *Ballistics) Update(target []float64, now time.Time) (levels, peaks []float64) {
	b.levels = resize(b.levels, len(target))
	b.peaks = resize(b.peaks, len(target))
	b.until = resizeTime(b.until, len(target))
	for i, v := range target {
		if v < 0 {
			v = 0
		}
		k := b.release
		if v > b.levels[i] {
			k = b.attack
		}
		b.levels[i] += (v - b.levels[i]) * k
		switch {
		case v >= b.peaks[i] || b.until[i].IsZero():
			b.peaks[i] = v
			b.until[i] = now.Add(b.hold)
		case now.After(b.until[i]):
			b.peaks[i] *= b.decay
			if b.peaks[i] < v {
				b.peaks[i] = v
			}
		}
	}
	b.last = now
	return copyFloats(b.levels), copyFloats(b.peaks)
}

func (b *Ballistics) Last() time.Time { return b.last }

func resize(v []float64, n int) []float64 {
	if len(v) == n {
		return v
	}
	out := make([]float64, n)
	copy(out, v)
	return out
}

func resizeTime(v []time.Time, n int) []time.Time {
	if len(v) == n {
		return v
	}
	out := make([]time.Time, n)
	copy(out, v)
	return out
}

func copyFloats(v []float64) []float64 {
	out := make([]float64, len(v))
	copy(out, v)
	return out
}
