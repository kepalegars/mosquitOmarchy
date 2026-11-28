package aggregate

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"mosquitomarchy.local/mosquitomixbay-tui/config"
	"mosquitomarchy.local/mosquitomixbay-tui/patchbay"
)

// Dir is the aggregate store. It deliberately lives outside pipewire/ so the
// patchbay preset reader never tries to parse these recipes.
func Dir() string { return filepath.Join(config.Dir(), "aggregate") }

func presetPath(name string) string { return filepath.Join(Dir(), name+".json") }

func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// Save writes a preset. Overwrite is refused by the TUI and allowed by the CLI
// only when explicitly requested, the same split patchbay uses.
func Save(p Preset, overwrite bool) error {
	if err := p.Validate(); err != nil {
		return err
	}
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	path := presetPath(p.Name)
	if !overwrite {
		if _, err := os.Stat(path); err == nil {
			return fmt.Errorf("aggregate %q already exists", p.Name)
		} else if !os.IsNotExist(err) {
			return err
		}
	}
	return writeAtomic(path, data)
}

// Load reads one named preset.
func Load(name string) (Preset, error) {
	if err := validName(name); err != nil {
		return Preset{}, err
	}
	data, err := os.ReadFile(presetPath(name))
	if err != nil {
		return Preset{}, err
	}
	var p Preset
	if err := json.Unmarshal(data, &p); err != nil {
		return Preset{}, fmt.Errorf("%s: %w", name, err)
	}
	if err := p.Validate(); err != nil {
		return Preset{}, fmt.Errorf("%s: %w", name, err)
	}
	return p, nil
}

// List returns the saved recipes sorted by name.
func List() ([]Preset, error) {
	entries, err := os.ReadDir(Dir())
	if os.IsNotExist(err) {
		return nil, ErrNoPresets
	}
	if err != nil {
		return nil, err
	}
	var out []Preset
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
			continue
		}
		p, err := Load(stringsTrimSuffix(e.Name(), ".json"))
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	if len(out) == 0 {
		return nil, ErrNoPresets
	}
	return out, nil
}

func stringsTrimSuffix(s, suffix string) string {
	if len(s) > len(suffix) && s[len(s)-len(suffix):] == suffix {
		return s[:len(s)-len(suffix)]
	}
	return s
}

// Delete removes a recipe. The active one cannot be deleted while loaded.
func Delete(name string) error {
	if err := validName(name); err != nil {
		return err
	}
	if active, err := ActiveName(); err == nil && active == name {
		return fmt.Errorf("deactivate %q before deleting it", name)
	}
	if err := os.Remove(presetPath(name)); err != nil {
		return err
	}
	return nil
}

func activePath() string { return filepath.Join(Dir(), "active.json") }
func lockPath() string   { return filepath.Join(Dir(), "lock") }
func unlockPath() string { return filepath.Join(Dir(), "unlocked") }
func runtimePath() string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return filepath.Join(d, "mixbay-aggregate.json")
	}
	return filepath.Join(os.TempDir(), "mixbay-aggregate.json")
}

func ActiveName() (string, error) {
	data, err := os.ReadFile(activePath())
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	var v struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(data, &v); err != nil {
		return "", err
	}
	return v.Name, nil
}

func SetActive(name string) error {
	return writeAtomic(activePath(), []byte(fmt.Sprintf(`{"name":%q}`+"\n", name)))
}

func ClearActive() error {
	err := os.Remove(activePath())
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

// Locked reports whether Live Mode froze aggregate changes. An explicit
// per-session unlock is the only escape, exactly like pipewire-settings' L.
func Locked() bool {
	if _, err := os.Stat(lockPath()); err != nil {
		return false
	}
	_, err := os.Stat(unlockPath())
	return err != nil
}

func Unlocked() bool {
	_, err := os.Stat(unlockPath())
	return err == nil
}

func SetLock(on bool) error {
	if on {
		if err := os.MkdirAll(Dir(), 0o755); err != nil {
			return err
		}
		// A stale session unlock from a crashed session must not survive a new
		// fence: start every session locked.
		if err := os.Remove(unlockPath()); err != nil && !os.IsNotExist(err) {
			return err
		}
		return os.WriteFile(lockPath(), []byte("live-mode\n"), 0o600)
	}
	for _, p := range []string{lockPath(), unlockPath()} {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

func SetUnlocked(on bool) error {
	if on {
		if !Locked() {
			return errors.New("aggregate devices are not locked")
		}
		if err := os.MkdirAll(Dir(), 0o755); err != nil {
			return err
		}
		return os.WriteFile(unlockPath(), []byte("session\n"), 0o600)
	}
	err := os.Remove(unlockPath())
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

// EnsureWritable is called by every mutating CLI action before any side effect.
func EnsureWritable() error {
	if Locked() {
		return fmt.Errorf("aggregate devices are locked by Live Mode")
	}
	return nil
}

type runtimeState struct {
	Name    string          `json:"name"`
	Modules []int           `json:"modules"`
	Links   []patchbay.Link `json:"links,omitempty"`
}

func readRuntime() (runtimeState, error) {
	var s runtimeState
	data, err := os.ReadFile(runtimePath())
	if os.IsNotExist(err) {
		return s, nil
	}
	if err != nil {
		return s, err
	}
	if err := json.Unmarshal(data, &s); err != nil {
		return s, err
	}
	return s, nil
}

func writeRuntime(s runtimeState) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(runtimePath(), data)
}

func clearRuntime() error {
	err := os.Remove(runtimePath())
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
