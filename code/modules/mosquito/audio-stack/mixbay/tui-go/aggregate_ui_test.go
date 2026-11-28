package main

import (
	"strings"
	"testing"

	"mosquitomarchy.local/mosquitomixbay-tui/aggregate"
	tuikit "mosquitomarchy.local/tui-kit"
)

func deviceRow(t *testing.T, value string) tuikit.PickerItem {
	t.Helper()
	m := initialModel()
	for _, it := range m.deviceItems() {
		if it.Value == value {
			return it
		}
	}
	t.Fatalf("devices page has no %q row", value)
	return tuikit.PickerItem{}
}

func TestAggregateRowIsProminent(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	row := deviceRow(t, "aggregate")
	if row.Display != "Aggregate devices" {
		t.Fatalf("row reads %q", row.Display)
	}
	if strings.Contains(row.Display, "patchbay") {
		t.Fatalf("old label leaked into %q", row.Display)
	}
}

func TestAggregateItemsGreyWhenLocked(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	if err := aggregate.SetLock(true); err != nil {
		t.Fatal(err)
	}
	m := initialModel()
	m.aggregate.info.Locked = true
	m.aggregate.info.Available = true
	m.aggregate.presets = nil
	var newRow tuikit.PickerItem
	for _, it := range m.aggregateItems() {
		if it.Value == "new" {
			newRow = it
		}
	}
	if !newRow.Disabled || !strings.Contains(newRow.Suffix, "locked by Live Mode") {
		t.Fatalf("new row must be greyed while locked: %+v", newRow)
	}
	if err := aggregate.SetLock(false); err != nil {
		t.Fatal(err)
	}
	if aggregate.Locked() {
		t.Fatal("release must clear the fence")
	}
}
