package main

import (
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// TestCycleLoadedSettingReturnsModel guards the deferred-apply settings path
// (Left/Right preview -> dwell/blur/leave apply) against the crash that made
// the whole TUI disappear: cycleLoadedSetting has a pointer receiver but used
// to return `m` (*model) from a method typed to return tea.Model, while
// model.Update asserts next.(model) on every message. A single horizontal
// arrow on any Settings / Windows VST row therefore panicked with
// "interface conversion: tea.Model is *main.model, not main.model".
func TestCycleLoadedSettingReturnsModel(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.status = Status{FilePicker: "default", PluginWinHandler: "hyprland", SortMode: "vendor"}
	m.push(scrSettings)
	_ = m.enterCmd()

	next, _ := m.Update(tuikit.PickerSortMsg{Dir: 1})
	mm, ok := next.(model)
	if !ok {
		t.Fatalf("settings arrow Update returned %T, want model", next)
	}
	if got, want := mm.settingsPending["switch_file_picker"], "superfile"; got != want {
		t.Fatalf("pending file picker = %q, want %q", got, want)
	}
}

// TestCycleLoadedSettingNonValueRow guards the default branch of
// cycleLoadedSetting: Left/Right on a row that has no cycleable value (Back,
// Plugins folder, Rescan, …) used to return the *model receiver and panic
// model.Update's next.(model) assertion, exactly like the handler row did.
func TestCycleLoadedSettingNonValueRow(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.status = Status{FilePicker: "default", PluginWinHandler: "hyprland", SortMode: "vendor"}
	m.push(scrSettings)
	_ = m.enterCmd()
	m.picker = m.picker.SelectIndex(len(m.settingsItemsWithPending()) - 1) // "Back"
	if got := m.picker.SelectedValue(); got != "back" {
		t.Fatalf("selected value = %q, want back", got)
	}

	next, _ := m.Update(tuikit.PickerSortMsg{Dir: 1})
	if _, ok := next.(model); !ok {
		t.Fatalf("non-value-row arrow Update returned %T, want model", next)
	}
}

// TestSettingsDwellAppliesWithoutPanic drives the dwell timer the arrow armed
// for both a Settings row (file picker -> Superfile confirm) and a VST Hide
// row (pure toggle), so both deferred-apply screens are exercised.
func TestSettingsDwellAppliesWithoutPanic(t *testing.T) {
	t.Run("settings file picker", func(t *testing.T) {
		m := initialModel()
		m.w, m.h = 120, 40
		m.status = Status{FilePicker: "default", PluginWinHandler: "hyprland", SortMode: "vendor"}
		m.push(scrSettings)
		_ = m.enterCmd()

		next, _ := m.Update(tuikit.PickerSortMsg{Dir: 1})
		mm := next.(model)
		seq := mm.settingsDwellSeq

		next2, _ := mm.Update(settingsDwellMsg{row: "switch_file_picker", seq: seq})
		m2, ok := next2.(model)
		if !ok {
			t.Fatalf("dwell Update returned %T, want model", next2)
		}
		if got, want := m2.top(), scrSuperfileInstallConfirm; got != want {
			t.Fatalf("top after dwell = %v, want superfile install confirm", got)
		}
	})

	t.Run("vst hide filter", func(t *testing.T) {
		m := initialModel()
		m.w, m.h = 120, 40
		m.status = Status{HideVst2: false, SortMode: "vendor"}
		m.push(scrVstMenu)
		_ = m.enterCmd()

		// Select the Hide VST2 row (index 1) before the arrow.
		m.picker = m.picker.SelectIndex(1)
		next, _ := m.Update(tuikit.PickerSortMsg{Dir: 1})
		mm, ok := next.(model)
		if !ok {
			t.Fatalf("vst arrow Update returned %T, want model", next)
		}
		if got, want := mm.settingsPending["toggle_hide_vst2"], "on"; got != want {
			t.Fatalf("pending hide-vst2 = %q, want %q", got, want)
		}

		seq := mm.settingsDwellSeq
		next2, _ := mm.Update(settingsDwellMsg{row: "toggle_hide_vst2", seq: seq})
		if _, ok := next2.(model); !ok {
			t.Fatalf("vst dwell Update returned %T, want model", next2)
		}
	})
}
