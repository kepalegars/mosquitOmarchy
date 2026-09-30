package tuikit

import (
	"regexp"
	"strings"
	"testing"
)

var ansiSGR = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func stripANSI(s string) string { return ansiSGR.ReplaceAllString(s, "") }

// TestTrailingBadgeRendersAfterTitle pins the requirement that a
// TrailingBadge is a suffix of the row's own label ("name  ■"), never a
// leading column: the Display must come first and the marker after it.
func TestTrailingBadgeRendersAfterTitle(t *testing.T) {
	items := []PickerItem{
		{Display: "Vital", Value: "vst:vst3:/x/Vital.vst3", TrailingBadge: "■"},
		{Display: "Serum", Value: "vst:vst3:/x/Serum.vst3"},
	}
	p := NewPicker("", items).SetSize(80, 10)
	out := stripANSI(p.View())

	if !strings.Contains(out, "Vital  ■") {
		t.Fatalf("trailing badge not rendered after the title; view:\n%s", out)
	}
	if strings.Contains(out, "■  Vital") || strings.Contains(out, "■ Vital") {
		t.Fatalf("badge rendered before the title (leading slot still used); view:\n%s", out)
	}
	if strings.Contains(out, "Serum  ■") {
		t.Fatalf("unbadged row picked up a trailing badge; view:\n%s", out)
	}
}

// TestTrailingBadgeDoesNotMoveLabels pins the reported symptom: the Update
// row's square slid the other options to the left. The row block is centered,
// so letting a marker widen the block re-centered the entire list. The
// trailing column is now reserved on every picker, which means a label must
// keep its exact column whether a marker is shown or not.
func TestTrailingBadgeDoesNotMoveLabels(t *testing.T) {
	labels := []string{"Status", "Update", "Setup", "Uninstall"}
	base := []PickerItem{
		{Display: "Status", Value: "a"},
		{Display: "Update", Value: "b"},
		{Display: "Setup", Value: "c"},
		{Display: "Uninstall", Value: "d"},
	}
	withBadge := append([]PickerItem(nil), base...)
	withBadge[1].TrailingBadge = "■"

	columns := func(p Picker) map[string]int {
		out := map[string]int{}
		for _, line := range strings.Split(stripANSI(p.View()), "\n") {
			for _, l := range labels {
				if i := strings.Index(line, l); i >= 0 {
					if _, seen := out[l]; !seen {
						out[l] = i
					}
				}
			}
		}
		return out
	}

	plain := columns(NewPicker("", base).SetSize(70, 10))
	badged := columns(NewPicker("", withBadge).SetSize(70, 10))
	for _, l := range labels {
		if badged[l] != plain[l] {
			t.Fatalf("%q moved from column %d to %d when a marker appeared", l, plain[l], badged[l])
		}
	}

	found := false
	for _, line := range strings.Split(stripANSI(NewPicker("", withBadge).SetSize(70, 10).View()), "\n") {
		if i := strings.Index(line, "■"); i >= 0 {
			found = true
			if i <= badged["Update"] {
				t.Fatalf("marker column %d is not right of its label column %d", i, badged["Update"])
			}
		}
	}
	if !found {
		t.Fatal("trailing marker was not rendered")
	}
}

// TestLeadingBadgeStillWorks is a guard that the new trailing slot did not
// disturb the pre-existing leading Badge convention.
func TestLeadingBadgeStillWorks(t *testing.T) {
	items := []PickerItem{
		{Display: "Vital", Value: "a", Badge: "●"},
		{Display: "Serum", Value: "b"},
	}
	p := NewPicker("", items).SetSize(80, 10)
	out := stripANSI(p.View())
	if !strings.Contains(out, "● Vital") {
		t.Fatalf("leading badge not rendered before the title; view:\n%s", out)
	}
}
