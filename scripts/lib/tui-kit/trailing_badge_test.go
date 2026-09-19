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
