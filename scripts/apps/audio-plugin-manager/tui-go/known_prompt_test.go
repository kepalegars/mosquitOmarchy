package main

import (
	"strings"
	"testing"
)

// AUTO_FIX is on by default, so the silent re-apply path is the one a known
// plugin normally takes. The message it carries back lost `known`, so the
// question was skipped and every known plugin got the plain success dialog.
func TestSilentReapplyStillCarriesTheKnownFlag(t *testing.T) {
	msg := afterInstallFixesMsg{carry: installFixesCheckMsg{
		plugin:     "vst:vst3:/x/Plugin Alliance/CrispyTuner.vst3",
		vendor:     "Plugin Alliance",
		autoFix:    true,
		fixPrompt:  true,
		known:      true,
		pluginName: "crispytuner",
	}}

	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrInstalling}

	out, _ := m.update(msg)
	got := out.(model)
	if got.top() != scrInstallFixesConfirm {
		t.Fatalf("landed on screen %d, want the knowledge-base question", got.top())
	}
	view := got.confirm.View()
	if !strings.Contains(view, "crispytuner is part of the apm's plugin knowledge database") {
		t.Errorf("the question is not the known-plugin one: %q", view)
	}
}

// And an unknown plugin still must not be asked.
func TestUnknownPluginGetsNoQuestion(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.nav = []screen{scrMain, scrInstalling}

	out, _ := m.update(afterInstallFixesMsg{carry: installFixesCheckMsg{
		plugin: "vst:vst3:/x/Whatever.vst3", autoFix: true, fixPrompt: true,
		known: false, pluginName: "whatever",
	}})
	got := out.(model)
	if strings.Contains(got.confirm.View(), "knowledge database") {
		t.Errorf("an unknown plugin was asked about fixes: %q", got.confirm.View())
	}
}
