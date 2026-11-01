package main

import (
	"math"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
)

// Received hardware values are smoothed over evoAnimDur so a 500 ms poll does
// not make the on-screen slider jump. Local writes are followed by a
// non-quiet refresh, which clears the animation: the value the user just set
// appears immediately.
const evoAnimDur = 220 * time.Millisecond

type evoAnim struct {
	cur, from, to float64
	start         time.Time
}

type evoAnimTickMsg struct{ gen int }

func evoAnimTick(gen int) tea.Cmd {
	return tea.Tick(30*time.Millisecond, func(time.Time) tea.Msg { return evoAnimTickMsg{gen: gen} })
}

// startEvoRamps compares the previous and current hardware status and starts
// one ramp per changed gain/volume/monitor value. It returns true when a tick
// chain is needed.
func (m *model) startEvoRamps(old, cur drivers.Status) bool {
	if m.evo.spec.ID == "" || old.Spec.ID != cur.Spec.ID || !cur.Online {
		return false
	}
	changed := false
	for _, g := range evoGroups(cur.Spec) {
		for _, e := range g.elements {
			from := evoElemValueIn(old, e)
			to := evoElemValueIn(cur, e)
			if math.Abs(to-from) < 0.01 {
				continue
			}
			m.evo.startAnim(e.key, from, to)
			changed = true
		}
	}
	if !changed {
		return false
	}
	m.evo.animGen++
	return true
}

func (u *evoUI) startAnim(key string, from, to float64) {
	if u.anims == nil {
		u.anims = map[string]evoAnim{}
	}
	if a, ok := u.anims[key]; ok {
		from = a.cur
	}
	u.anims[key] = evoAnim{cur: from, from: from, to: to, start: time.Now()}
}

func (u *evoUI) clearAnims() {
	if len(u.anims) > 0 {
		u.anims = nil
		u.animGen++
	}
}

// tickAnims advances every ramp. It returns true while at least one is still
// moving, so the caller can schedule the next frame.
func (u *evoUI) tickAnims(now time.Time) bool {
	active := false
	for key, a := range u.anims {
		f := float64(now.Sub(a.start)) / float64(evoAnimDur)
		if f >= 1 {
			delete(u.anims, key)
			continue
		}
		if f < 0 {
			f = 0
		}
		// Ease-out: fast first half, gentle landing.
		ease := 1 - math.Pow(1-f, 3)
		a.cur = a.from + (a.to-a.from)*ease
		u.anims[key] = a
		active = true
	}
	return active
}
