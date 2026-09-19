package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// State mirrors the JSON snapshot the backend writes atomically to
// ~/.local/state/jamjamjam/state.json. Unknown snapshot fields are ignored.
type State struct {
	Recording     bool      `json:"recording"`
	RecorderError string    `json:"recorderError"`
	CaptureTarget string    `json:"captureTarget"`
	InputSource   string    `json:"inputSource"`
	Hold          bool      `json:"hold"`
	Paused        bool      `json:"paused"`
	TuiActive     bool      `json:"tuiActive"`
	NeedsReset    bool      `json:"needsReset"`
	Mic           Mic       `json:"mic"`
	Config        Config    `json:"config"`
	Metronome     Metronome `json:"metronome"`
	Analyzer      Analyzer  `json:"analyzer"`
	Loop          Loop      `json:"loop"`
	Tuner         Tuner     `json:"tuner"`
	Song          Song      `json:"song"`
	Guitar        Guitar    `json:"guitar"`
	NoteNaming    string    `json:"noteNaming"`
}

type Mic struct {
	Available bool `json:"available"`
	Muted     bool `json:"muted"`
}

type Config struct {
	NoteNaming string `json:"noteNaming"`
}

type Metronome struct {
	Enabled bool    `json:"enabled"`
	BPM     float64 `json:"bpm"`
	Beats   int     `json:"beats"`
}

type Analyzer struct {
	Key           string      `json:"key"`
	KeyConfidence float64     `json:"keyConfidence"`
	KeyStable     bool        `json:"keyStable"`
	BPM           float64     `json:"bpm"`
	BeatsPerBar   int         `json:"beatsPerBar"`
	TimeSignature string      `json:"timeSignature"`
	CurrentChord  string      `json:"currentChord"`
	ChordNotes    []string    `json:"chordNotes"`
	NoSignal      bool        `json:"noSignal"`
	SongChanged   bool        `json:"songChanged"`
	Progression   []ProgEntry `json:"progression"`
}

type ProgEntry struct {
	Chord    string  `json:"chord"`
	Started  float64 `json:"started"`
	Ended    float64 `json:"ended"`
	Duration float64 `json:"duration"`
}

type Loop struct {
	Active bool     `json:"active"`
	Length int      `json:"length"`
	Chords []string `json:"chords"`
	Pos    int      `json:"pos"`
}

type Tuner struct {
	Active bool    `json:"active"`
	Freq   float64 `json:"freq"`
	Note   string  `json:"note"`
	Octave int     `json:"octave"`
	Cents  int     `json:"cents"`
}

type SongMatch struct {
	Title  string  `json:"title"`
	Artist string  `json:"artist"`
	Score  float64 `json:"score"`
}

type Song struct {
	Available bool       `json:"available"`
	Match     *SongMatch `json:"match"`
	Error     string     `json:"error"`
}

type Fret struct {
	Fret   int `json:"fret"`
	Degree int `json:"degree"`
	PC     int `json:"pc"`
}

type GuitarString struct {
	Name  string `json:"name"`
	Tone  int    `json:"tone"`
	Frets []Fret `json:"frets"`
}

type Dot struct {
	String int `json:"string"`
	Fret   int `json:"fret"`
	Degree int `json:"degree"`
}

type Guitar struct {
	Root      int            `json:"root"`
	ScaleType string         `json:"scaleType"`
	Label     string         `json:"label"`
	Strings   []GuitarString `json:"strings"`
	Dots      []Dot          `json:"dots"`
	DegreeOf  map[string]int `json:"degreeOf"`
}

// statePath is shared with the backend's own default.
func statePath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".local/state/jamjamjam/state.json"
	}
	return filepath.Join(home, ".local/state/jamjamjam/state.json")
}

// commandPath is the file the TUI writes reset commands into; the running
// backend polls it and reacts (like the QML panel's IPC writer).
func commandPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".local/state/jamjamjam/commands.json"
	}
	return filepath.Join(home, ".local/state/jamjamjam/commands.json")
}

// loadState reads the latest snapshot. The backend replaces the file
// atomically, so a partial read can't happen; a missing/stale file simply
// reports err and the view shows the "waiting for backend" panel.
func loadState() (State, error) {
	var s State
	data, err := os.ReadFile(statePath())
	if err != nil {
		return s, err
	}
	if err := json.Unmarshal(data, &s); err != nil {
		return s, err
	}
	if s.Loop.Chords == nil {
		s.Loop.Chords = []string{}
	}
	if s.Analyzer.Progression == nil {
		s.Analyzer.Progression = []ProgEntry{}
	}
	return s, nil
}

// stateAge reports how stale the snapshot is (Unix seconds), -1 when unreadable.
func stateAge() float64 {
	st, err := os.Stat(statePath())
	if err != nil {
		return -1
	}
	return float64(time.Since(st.ModTime()).Seconds())
}

// writeCommand writes a JSON command to the command file; the running backend
// keys off mtime so every write is picked up, even with identical content.
func writeCommand(payload string) error {
	path := commandPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(payload), 0o644)
}

// writeReset writes a reset command to the command file.
func writeReset() error {
	return writeCommand(`{"op":"resetAnalysis"}`)
}

// writeHold tells the backend whether the chord-progression scout is being
// held (it records the progression only while the button is held).
func writeHold(active bool) error {
	if active {
		return writeCommand(`{"op":"setHold","active":true}`)
	}
	return writeCommand(`{"op":"setHold","active":false}`)
}

// writeMetronome toggles the click track derived from the held analysis BPM.
func writeMetronome(enabled bool) error {
	if enabled {
		return writeCommand(`{"op":"setMetronome","enabled":true}`)
	}
	return writeCommand(`{"op":"setMetronome","enabled":false}`)
}

// writeConfig persists the TUI-owned settings (note naming) through the
// backend, which also writes ~/.config/jamjamjam/config.json.
func writeConfig(naming string) error {
	payload, err := json.Marshal(map[string]string{
		"op":         "setConfig",
		"noteNaming": naming,
	})
	if err != nil {
		return err
	}
	return writeCommand(string(payload))
}

func tuiPidPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".local/state/jamjamjam/tui.pid"
	}
	return filepath.Join(home, ".local/state/jamjamjam/tui.pid")
}

// writeTuiPid marks this TUI as the active session so the backend stops its
// real-time panel analysis and freezes the TUI-owned results.
func writeTuiPid() error {
	path := tuiPidPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())), 0o644)
}

func clearTuiPid() {
	_ = os.Remove(tuiPidPath())
}

// configPath is the shared settings file the backend also owns.
func configPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".config/jamjamjam/config.json"
	}
	return filepath.Join(home, ".config/jamjamjam/config.json")
}

// loadLocalConfig reads the shared config so the TUI keeps the user's
// note naming even when the backend is not running yet.
func loadLocalConfig() Config {
	cfg := Config{NoteNaming: "flats"}
	data, err := os.ReadFile(configPath())
	if err != nil {
		return cfg
	}
	var parsed Config
	if json.Unmarshal(data, &parsed) != nil {
		return cfg
	}
	if parsed.NoteNaming == "flats" || parsed.NoteNaming == "sharps" {
		cfg.NoteNaming = parsed.NoteNaming
	}
	return cfg
}

// saveLocalConfig writes the shared config directly (the backend re-reads it
// on its next start; the running instance is updated via setConfig too).
func saveLocalConfig(cfg Config) {
	path := configPath()
	if os.MkdirAll(filepath.Dir(path), 0o755) != nil {
		return
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return
	}
	_ = os.WriteFile(path, data, 0o644)
}
