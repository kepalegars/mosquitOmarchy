package main

import "testing"

// A MANAGER install produces no plugin, so there is no list value to offer
// fixes for — but the run is a success and must not read as "the step failed".
func TestManagerMarkerIsRead(t *testing.T) {
	out := "manager installed into the prefix and tracked: Kilohearts\n" +
		"installed-manager: /p/drive_c/ProgramData/Kilohearts/Kilohearts Installer.exe\n" +
		"manager-note: listed under \"Launch a standalone plugin\"\n"
	if got := installedManagerValue(out); got == "" {
		t.Error("the manager marker was not read from a completed manager install")
	}
	if got := installedManagerValue("installed-plugin: vst:vst3:/x/a.vst3\n"); got != "" {
		t.Errorf("a plugin install was mistaken for a manager one: %q", got)
	}
	if got := installedManagerValue(""); got != "" {
		t.Errorf("empty output produced a manager: %q", got)
	}
}
