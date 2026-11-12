package main

import (
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// Left/Right on a Settings row used to kill the whole TUI: cycleSetting has
// a pointer receiver but its handler returned the *model straight into a
// chain typed as model, so Update's next.(model) assertion panicked. Every
// row — value rows and navigation rows alike — must survive both arrows and
// stay on the Settings screen.
func TestSettingsArrowsNeverCrash(t *testing.T) {
	for _, row := range []string{"hide_converted", "open_als_ydotool", "ableton_version", "working_dir", "switch_file_picker", "clear_als", "back"} {
		for _, dir := range []int{-1, 1} {
			m := initialModel()
			m.w, m.h = 120, 40
			m.status = MoveStatus{Connected: false, Host: "move.local", MoveDir: "/tmp/x", FilePicker: "default"}
			m.push(scrSettings)
			_ = m.enterCmd()
			m.settingsPicker.Picker = m.settingsPicker.SelectValue(row)
			if got := m.settingsPicker.SelectedValue(); got != row {
				t.Fatalf("row %q not selectable", row)
			}
			func() {
				defer func() {
					if r := recover(); r != nil {
						t.Fatalf("Left/Right dir=%d on row %q panicked: %v", dir, row, r)
					}
				}()
				mm, _ := m.Update(tuikit.PickerSortMsg{Dir: dir})
				m = mm.(model)
			}()
			if m.top() != scrSettings {
				t.Fatalf("Left/Right dir=%d on row %q left the Settings screen", dir, row)
			}
		}
	}
}
