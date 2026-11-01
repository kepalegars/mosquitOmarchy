package main

import (
	"errors"

	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
)

// liveSession owns the connection state of the current device. It is the only
// place that decides whether a read is real, when values freeze, and whether a
// write may reach the hardware. The model just renders what apply returns.
type liveSession struct {
	live    bool // hardware has answered at least once in this session
	online  bool // the latest hardware read succeeded
	dataGen int  // invalidates reads requested before the last write
	last    drivers.Status
}

func (s *liveSession) selectDevice() {
	s.live = false
	s.online = false
	s.dataGen++
	s.last = drivers.Status{}
}

func (s *liveSession) beginRead() int { return s.dataGen }

func (s *liveSession) wrote() { s.dataGen++ }

// canWrite is false only when a real session lost its interface. Demo sessions
// may write to their persistent demo state.
func (s *liveSession) canWrite() bool { return !s.live || s.online }

// apply merges one read. ok=false means the model keeps what it displays:
// stale poll, repeated offline poll, or a demo payload trying to demote a
// live session (a refresh after unplugging must not silently switch to DEMO).
func (s *liveSession) apply(msg statusMsg) (drivers.Status, bool) {
	if msg.quiet && msg.gen != s.dataGen {
		return drivers.Status{}, false
	}
	if msg.err != nil {
		if !errors.Is(msg.err, drivers.ErrOffline) || !s.live {
			return drivers.Status{}, false
		}
		s.online = false
		st := s.last
		st.Online = false
		st.Note = "interface offline — last known values; retrying"
		return st, true
	}
	if msg.demo {
		if s.live {
			return drivers.Status{}, false
		}
		s.last = msg.status
		return msg.status, true
	}
	s.live = true
	s.online = msg.status.Online
	s.last = msg.status
	return msg.status, true
}
