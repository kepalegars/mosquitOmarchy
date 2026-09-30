package main

import (
	"regexp"
	"strings"
	"testing"
)

var ansiSGR = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// TestFixAppliedBadgeIsTrailing pins the "put the applied-fix square at the
// END of the plugin row" requirement: the chooser must render "Vital  ■",
// with the ■ after the label, and must NOT use the picker's leading badge
// slot (which would render it before the label).
func TestFixAppliedBadgeIsTrailing(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.push(scrFixPluginPick)
	m.loading = false
	m.fixPluginCache = []PluginItem{
		{Display: "Vital", Value: "vst:vst3:/x/Vital.vst3", Kind: "plugin"},
		{Display: "Serum", Value: "vst:vst3:/x/Serum.vst3", Kind: "plugin"},
	}
	m.fixAppliedPlugins = map[string]bool{"Vital": true}
	m.rebuildFixPluginPicker()

	out := ansiSGR.ReplaceAllString(m.picker.View(), "")
	if !strings.Contains(out, "Vital  ■") {
		t.Fatalf("applied-fix square not rendered at the end of the row; view:\n%s", out)
	}
	if strings.Contains(out, "■ Vital") || strings.Contains(out, "■  Vital") {
		t.Fatalf("applied-fix square rendered before the label (leading slot); view:\n%s", out)
	}
	if strings.Contains(out, "Serum  ■") {
		t.Fatalf("unbadged plugin picked up the square; view:\n%s", out)
	}
}
