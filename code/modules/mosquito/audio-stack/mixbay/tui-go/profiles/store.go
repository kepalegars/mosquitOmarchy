package profiles

import (
	"bytes"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Native card snapshots shipped inside the binary. They are generated from the
// community repo; Mixbay never reads interface definitions from Go constants.
//
//go:embed cards/*.json
var nativeFS embed.FS

// ErrNotFound says a card is not installed and has no built-in copy.
var ErrNotFound = errors.New("profile not found")

// Meta is the per-card bookkeeping file. It is local state only; export
// regenerates nothing from it.
type Meta struct {
	ID          string    `json:"id"`
	Display     string    `json:"display"`
	Vendor      string    `json:"vendor"`
	Version     string    `json:"version"`
	Native      bool      `json:"native"`
	Source      string    `json:"source"` // preinstalled | repo | local
	Revision    string    `json:"revision,omitempty"`
	SHA256      string    `json:"sha256,omitempty"`
	InstalledAt time.Time `json:"installed_at,omitzero"`
}

// ConfigDir is ~/.config/mosquitomixbay (or $MIXBAY_CONFIG_DIR for tests).
func ConfigDir() string {
	if v := os.Getenv("MIXBAY_CONFIG_DIR"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "mosquitomixbay")
}

// CardsDir holds one folder per downloaded/local card.
func CardsDir() string { return filepath.Join(ConfigDir(), "cards") }

func cardDir(id string) string { return filepath.Join(CardsDir(), id) }

func upstreamFile(id string) string {
	return filepath.Join(cardDir(id), "upstream", "card.json")
}

func userLayoutFile(id string) string {
	return filepath.Join(cardDir(id), "user", "layout.json")
}

func metaFile(id string) string { return filepath.Join(cardDir(id), "_meta.json") }

// removedFile marks a card the user uninstalled. It stops the embedded
// snapshot from being seeded back on the next start.
func removedFile(id string) string { return filepath.Join(cardDir(id), ".removed") }

// NativeCards returns every card snapshot shipped in the binary, sorted by
// id. They are only a bootstrap: the first read seeds them into the local
// store, where they become normal, uninstallable cards.
func NativeCards() []Card {
	entries, _ := fs.ReadDir(nativeFS, "cards")
	var out []Card
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		data, err := nativeFS.ReadFile("cards/" + e.Name())
		if err != nil {
			continue
		}
		var c Card
		if json.Unmarshal(data, &c) == nil {
			out = append(out, c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Spec.ID < out[j].Spec.ID })
	return out
}

// NativeCard returns the built-in card for id.
func NativeCard(id string) (Card, bool) {
	for _, c := range NativeCards() {
		if c.Spec.ID == id {
			return c, true
		}
	}
	return Card{}, false
}

// IsNative reports whether the binary ships a snapshot of id. It says nothing
// about what is installed any more: a shipped card can be uninstalled like any
// other and then reappears in the repo list.
func IsNative(id string) bool {
	_, ok := NativeCard(id)
	return ok
}

// EnsureSeeded copies each embedded snapshot into the local store once. A
// card the user uninstalled keeps a .removed marker and is not restored; an
// existing upstream file is never overwritten.
func EnsureSeeded() {
	entries, _ := fs.ReadDir(nativeFS, "cards")
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		id := strings.TrimSuffix(e.Name(), ".json")
		if !ValidID(id) {
			continue
		}
		// The Move ships in the binary but is not installed by default: it is
		// offered when the card is plugged in, and the library lists it under
		// Available. Installing it for everyone would make "uninstall" the
		// only half of the lifecycle that works.
		if id == "move" {
			continue
		}
		if _, err := os.Stat(upstreamFile(id)); err == nil {
			continue
		}
		if _, err := os.Stat(removedFile(id)); err == nil {
			continue
		}
		data, err := nativeFS.ReadFile("cards/" + e.Name())
		if err != nil {
			continue
		}
		var c Card
		if json.Unmarshal(data, &c) != nil {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(upstreamFile(id)), 0o755); err != nil {
			continue
		}
		if writeFileAtomic(upstreamFile(id), data) != nil {
			continue
		}
		_ = writeMeta(id, Meta{
			ID: id, Display: c.Spec.Display, Vendor: c.Spec.Vendor,
			Version: c.Spec.Version, Source: "preinstalled",
		})
	}
}

// InstallNative (re)installs a shipped card from the binary. It is the
// offline counterpart of a repo import: the card is already in the build, so
// installing one never needs the network — and an uninstalled card keeps a
// .removed marker that this clears.
func InstallNative(id string) (Card, bool, error) {
	c, ok := NativeCard(id)
	if !ok {
		return Card{}, false, fmt.Errorf("no built-in profile %q", id)
	}
	was := false
	if _, err := os.Stat(upstreamFile(id)); err == nil {
		was = true
	}
	if err := os.MkdirAll(filepath.Dir(upstreamFile(id)), 0o755); err != nil {
		return Card{}, was, err
	}
	if err := writeFileAtomic(upstreamFile(id), Encode(c)); err != nil {
		return Card{}, was, err
	}
	best := readMeta(id)
	if best.InstalledAt.IsZero() {
		best.InstalledAt = time.Now().UTC()
	}
	best.ID, best.Display, best.Vendor = id, c.Spec.Display, c.Spec.Vendor
	best.Version, best.Native, best.Source = c.Spec.Version, true, "preinstalled"
	if err := writeMeta(id, best); err != nil {
		return Card{}, was, err
	}
	_ = os.Remove(removedFile(id))
	return c, was, nil
}

// LocalCards returns every installed card (shipped or downloaded), sorted by
// id. The embedded bootstrap is seeded first, so callers never need a second
// source of truth.
func LocalCards() []Card {
	// One-time upgrade from the pre-profile beta list, so the driver registry
	// already sees those cards on first start after the update.
	_ = MigrateLegacyBeta()
	EnsureSeeded()
	entries, err := os.ReadDir(CardsDir())
	if err != nil {
		return nil
	}
	var out []Card
	for _, e := range entries {
		id := e.Name()
		if !e.IsDir() || !ValidID(id) {
			continue
		}
		data, err := os.ReadFile(upstreamFile(id))
		if err != nil {
			continue
		}
		var c Card
		if json.Unmarshal(data, &c) == nil {
			out = append(out, c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Spec.ID < out[j].Spec.ID })
	return out
}

// Installed returns the metadata of every installed card. Shipped cards are
// seeded into the store, so this is the same list for everyone.
func Installed() []Meta {
	var out []Meta
	for _, c := range LocalCards() {
		m := readMeta(c.Spec.ID)
		m.ID, m.Display, m.Vendor, m.Version = c.Spec.ID, c.Spec.Display, c.Spec.Vendor, c.Spec.Version
		if m.Source == "" {
			m.Source = "local"
		}
		out = append(out, m)
	}
	return out
}

// Effective returns the installed card with the user's sparse layout override
// applied.
func Effective(id string) (Card, Meta, error) {
	if !ValidID(id) {
		return Card{}, Meta{}, fmt.Errorf("invalid profile id %q", id)
	}
	EnsureSeeded()
	card, meta, err := baseCard(id)
	if err != nil {
		return Card{}, Meta{}, err
	}
	if data, err := os.ReadFile(userLayoutFile(id)); err == nil {
		var over map[string]any
		if json.Unmarshal(data, &over) == nil {
			merged, _ := mergeMaps(map[string]any(card.UI), over).(map[string]any)
			card.UI = merged
		}
	}
	return card, meta, nil
}

func baseCard(id string) (Card, Meta, error) {
	data, err := os.ReadFile(upstreamFile(id))
	if err != nil {
		return Card{}, Meta{}, fmt.Errorf("%w: %s", ErrNotFound, id)
	}
	var c Card
	if err := json.Unmarshal(data, &c); err != nil {
		return Card{}, Meta{}, fmt.Errorf("%s: %w", upstreamFile(id), err)
	}
	m := readMeta(id)
	m.Native, m.ID = false, id
	if m.Source == "" {
		m.Source = "repo"
	}
	return c, m, nil
}

func readMeta(id string) Meta {
	data, err := os.ReadFile(metaFile(id))
	if err != nil {
		return Meta{}
	}
	var m Meta
	_ = json.Unmarshal(data, &m)
	return m
}

func writeMeta(id string, m Meta) error {
	if err := os.MkdirAll(cardDir(id), 0o755); err != nil {
		return err
	}
	data, _ := json.MarshalIndent(m, "", "  ")
	return writeFileAtomic(metaFile(id), append(data, '\n'))
}

// SaveUserLayout stores a sparse UI override for one card. The file is
// validated as a JSON object but merged only when the card is rendered, so a
// later upstream update never destroys the user's tweak.
func SaveUserLayout(id string, data []byte) error {
	if !ValidID(id) {
		return fmt.Errorf("invalid profile id %q", id)
	}
	if !json.Valid(data) {
		return errors.New("layout override is not valid JSON")
	}
	var obj map[string]any
	if err := json.Unmarshal(data, &obj); err != nil || obj == nil {
		return errors.New("layout override must be a JSON object")
	}
	if err := os.MkdirAll(filepath.Dir(userLayoutFile(id)), 0o755); err != nil {
		return err
	}
	return writeFileAtomic(userLayoutFile(id), data)
}

// HasUserUI reports whether the card carries a local layout override.
func HasUserUI(id string) bool {
	if !ValidID(id) {
		return false
	}
	_, err := os.Stat(userLayoutFile(id))
	return err == nil
}

// UserUIBackupDir is where a local layout is parked before a repo profile
// replaces it.
func UserUIBackupDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "mosquitomixbay", "backups")
}

// BackupUserUI copies the local layout aside and drops it, so the repo layout
// becomes the effective one. It returns the backup path shown in the prompt.
func BackupUserUI(id string) (string, error) {
	if !ValidID(id) {
		return "", fmt.Errorf("invalid profile id %q", id)
	}
	src := userLayoutFile(id)
	data, err := os.ReadFile(src)
	if err != nil {
		return "", err
	}
	dir := UserUIBackupDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	dest := filepath.Join(dir, id+"-"+time.Now().UTC().Format("20060102-150405.000")+".json")
	if err := writeFileAtomic(dest, data); err != nil {
		return "", err
	}
	if err := os.Remove(src); err != nil {
		return "", err
	}
	return dest, nil
}

// Remove uninstalls a card: its folder, upstream copy and user overrides. A
// shipped card leaves a .removed marker so seeding does not bring it back.
func Remove(id string) error {
	if !ValidID(id) {
		return fmt.Errorf("invalid profile id %q", id)
	}
	if err := os.RemoveAll(cardDir(id)); err != nil {
		return err
	}
	// A profile that also deployed a helper must take it with it, from every
	// uninstall path (library, CLI, a script). The Move's helper is the only
	// one today: leaving it behind would keep its notices alive after the card
	// page is gone.
	if id == "move" {
		removeMoveHelper()
	}
	if IsNative(id) {
		if err := os.MkdirAll(cardDir(id), 0o755); err != nil {
			return err
		}
		return writeFileAtomic(removedFile(id), []byte("removed\n"))
	}
	return nil
}

// InstallLocalCard registers a card Mixbay discovered itself (Add an audio
// interface). It lives under upstream/ with source=local so a later repo
// profile can replace it without touching user overrides.
func InstallLocalCard(id, name, match string) (Card, error) {
	if !ValidID(id) {
		return Card{}, fmt.Errorf("invalid profile id %q", id)
	}
	card := Card{
		SchemaVersion: SchemaVersion,
		Spec: Spec{
			ID: id, Display: name, Vendor: "beta",
			NumInputs: 2, NumOutPairs: 1,
			GainMin: 0, GainMax: 60, VolMin: -96, VolMax: 0,
			MixerInputs: 2, MixerOutputs: 2,
			Backend: BackendALSA, Version: "beta", Beta: true,
			CardMatch: []string{match},
			Caps:      Caps{Volume: true, Mute: true},
			Description: "Beta: ALSA level 1 (volume/mute only). " +
				"Native controls and routing are not mapped yet.",
		},
		UI: map[string]any{"preset": "single-pair", "blocks": []any{"controlsSingle", "statusBar", "help"}},
	}
	data, _ := json.MarshalIndent(card, "", "  ")
	if err := os.MkdirAll(filepath.Dir(upstreamFile(id)), 0o755); err != nil {
		return Card{}, err
	}
	if err := writeFileAtomic(upstreamFile(id), append(data, '\n')); err != nil {
		return Card{}, err
	}
	_ = os.Remove(removedFile(id))
	err := writeMeta(id, Meta{
		ID: id, Display: name, Vendor: "beta", Version: "beta",
		Source: "local", InstalledAt: time.Now().UTC(),
	})
	return card, err
}

// legacyBetaPath is the pre-profile store, migrated once on first read.
func legacyBetaPath() string { return filepath.Join(ConfigDir(), "beta-devices.json") }

type legacyBeta struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Match string `json:"match"`
}

// MigrateLegacyBeta turns the old beta-devices.json entries into card folders.
// The old file is renamed, never deleted, so a failed migration is recoverable.
func MigrateLegacyBeta() error {
	data, err := os.ReadFile(legacyBetaPath())
	if err != nil {
		return nil
	}
	var list []legacyBeta
	if json.Unmarshal(data, &list) != nil {
		return nil
	}
	for _, b := range list {
		if b.ID == "" || b.Name == "" {
			continue
		}
		if _, err := os.Stat(upstreamFile(b.ID)); err == nil {
			continue
		}
		match := b.Match
		if match == "" {
			match = b.Name
		}
		if _, err := InstallLocalCard(b.ID, b.Name, match); err != nil {
			return err
		}
	}
	_ = os.Rename(legacyBetaPath(), legacyBetaPath()+".migrated")
	return nil
}

func writeFileAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp-")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(name, 0o644); err != nil {
		return err
	}
	return os.Rename(name, path)
}

// mergeMaps applies a sparse override: objects merge recursively, everything
// else (arrays included) replaces. nil base/over are treated as empty.
func mergeMaps(base, over any) any {
	bm, bok := base.(map[string]any)
	om, ook := over.(map[string]any)
	if !bok || !ook {
		if over == nil {
			return base
		}
		return over
	}
	out := make(map[string]any, len(bm)+len(om))
	for k, v := range bm {
		out[k] = v
	}
	for k, v := range om {
		out[k] = mergeMaps(out[k], v)
	}
	return out
}

// Encode renders a card with stable indentation, ready for git.
func Encode(c Card) []byte {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	_ = enc.Encode(c)
	return buf.Bytes()
}

// removeMoveHelper drops what the Move profile deployed outside the store. It
// releases first: uninstalling while the Move is the selected interface must
// put the graph and its defaults back, or the 44.1 kHz pin would outlive the
// only helper able to undo it.
func removeMoveHelper() {
	home, err := os.UserHomeDir()
	if err != nil {
		return
	}
	helper := filepath.Join(home, ".local", "bin", "move-audio")
	if _, err := os.Stat(helper); err == nil {
		_ = exec.Command(helper, "--release").Run()
	}
	_ = os.Remove(helper)
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		state = filepath.Join(home, ".local", "state")
	}
	_ = os.Remove(filepath.Join(state, "mosquitomarchy", "move-audio-state"))
}
