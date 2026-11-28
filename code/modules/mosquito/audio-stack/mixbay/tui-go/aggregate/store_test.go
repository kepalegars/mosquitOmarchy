package aggregate

import (
	"testing"

	"mosquitomarchy.local/mosquitomixbay-tui/config"
)

func useStore(t *testing.T) {
	t.Helper()
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
}

func TestSaveListLoadDelete(t *testing.T) {
	useStore(t)
	p := Preset{Name: "Studio pair", DisplayName: "Studio", Outputs: []Member{{Node: "card_a", Drift: true}}}
	if err := Save(p, false); err != nil {
		t.Fatal(err)
	}
	if err := Save(p, false); err == nil {
		t.Fatal("overwrite must be refused")
	}
	list, err := List()
	if err != nil || len(list) != 1 || list[0].Name != p.Name {
		t.Fatalf("list = %+v, %v", list, err)
	}
	got, err := Load(p.Name)
	if err != nil || got.DisplayName != "Studio" {
		t.Fatalf("load = %+v, %v", got, err)
	}
	if err := SetActive(p.Name); err != nil {
		t.Fatal(err)
	}
	if active, err := ActiveName(); err != nil || active != p.Name {
		t.Fatalf("active = %q, %v", active, err)
	}
	if err := Delete(p.Name); err == nil {
		t.Fatal("active preset must not be deleted")
	}
	if err := ClearActive(); err != nil {
		t.Fatal(err)
	}
	if err := Delete(p.Name); err != nil {
		t.Fatal(err)
	}
	if _, err := List(); err != ErrNoPresets {
		t.Fatalf("list after delete = %v", err)
	}
}

func TestLiveLockAndSessionUnlock(t *testing.T) {
	useStore(t)
	if Locked() || Unlocked() {
		t.Fatal("fresh store must be writable")
	}
	if err := SetLock(true); err != nil {
		t.Fatal(err)
	}
	if !Locked() || Unlocked() {
		t.Fatalf("lock = %v, unlock = %v", Locked(), Unlocked())
	}
	if err := EnsureWritable(); err == nil {
		t.Fatal("mutating action must be refused while locked")
	}
	if err := SetUnlocked(true); err != nil {
		t.Fatal(err)
	}
	if Locked() || !Unlocked() {
		t.Fatalf("after unlock: lock = %v, unlock = %v", Locked(), Unlocked())
	}
	if err := EnsureWritable(); err != nil {
		t.Fatal(err)
	}
	if err := SetLock(false); err != nil {
		t.Fatal(err)
	}
	if Locked() || Unlocked() {
		t.Fatal("deactivation must clear both files")
	}
}

func TestStoreUsesConfigRoot(t *testing.T) {
	useStore(t)
	if Dir() != config.Dir()+"/aggregate" {
		t.Fatalf("Dir = %q", Dir())
	}
}
