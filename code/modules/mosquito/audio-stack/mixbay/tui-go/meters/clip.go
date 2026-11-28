package meters

import (
	"strconv"
	"time"
)

// ClipThreshold is the linear peak at which a stream is considered clipped.
// 0.99 is about -0.09 dBFS: close enough to full scale to be real, far enough
// from float rounding noise to avoid false alarms on a clean signal.
const ClipThreshold = 0.99

// ClipHold is how long a clipped cell stays red after the last clipped block.
// Two seconds is long enough to notice on a control grid, short enough that
// the next phrase is not wrongly marked.
const ClipHold = 2 * time.Second

// IsClip reports whether one linear sample reached full scale.
func IsClip(v float64) bool { return v >= ClipThreshold }

// ClipTracker owns the per-stream clip hold. It lives in the meters package so
// every card (EVO, UGM, Move, community profiles with declared bindings) shares
// the same threshold and hold instead of each renderer inventing its own.
type ClipTracker struct {
	until map[string]time.Time
}

func NewClipTracker() *ClipTracker { return &ClipTracker{until: map[string]time.Time{}} }

func clipKey(key string, ch int) string { return key + ":" + strconv.Itoa(ch) }

// Update records any channel whose last peak (or level) was clipped. Expired
// entries are dropped while we are here so the map cannot grow across a show.
func (c *ClipTracker) Update(snap Snapshot, now time.Time) {
	if c == nil {
		return
	}
	if c.until == nil {
		c.until = map[string]time.Time{}
	}
	for key, until := range c.until {
		if !now.Before(until) {
			delete(c.until, key)
		}
	}
	if _, ok := snap.Peaks[KeyInput]; ok {
		mark(c, KeyInput, snap.Peaks[KeyInput], now)
	}
	if _, ok := snap.Peaks[KeyPlayback]; ok {
		mark(c, KeyPlayback, snap.Peaks[KeyPlayback], now)
	}
	mark(c, KeyInput, snap.Input, now)
	mark(c, KeyPlayback, snap.Playback, now)
}

func mark(c *ClipTracker, key string, vals []float64, now time.Time) {
	for ch, v := range vals {
		if IsClip(v) {
			c.until[clipKey(key, ch)] = now.Add(ClipHold)
		}
	}
}

// Active reports whether the channel is still inside its clip hold window.
func (c *ClipTracker) Active(key string, ch int, now time.Time) bool {
	if c == nil || c.until == nil {
		return false
	}
	until, ok := c.until[clipKey(key, ch)]
	return ok && now.Before(until)
}

// Reset clears every hold, e.g. when the user resets peaks or changes card.
func (c *ClipTracker) Reset() {
	if c == nil {
		return
	}
	c.until = map[string]time.Time{}
}
