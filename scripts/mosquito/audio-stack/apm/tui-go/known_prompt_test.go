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
		// A fix beyond the always-applied input one, so the question has
		// something to offer. With only the input fix there is nothing pending
		// and the offer is deliberately not made.
		items: []FixItem{
			{ID: "wine_gui_input", Scope: "plugin", Applied: false, Title: "Editor input"},
			{ID: "wine_tooltip", Scope: "plugin", Applied: false, Title: "Tooltips"},
		},
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

// A plugin whose entire fix catalog is the one fix that is applied to every
// plugin anyway has nothing to offer when the install ends: the input fix is
// already applied (or about to be), so the fixes page would open to a single
// ticked row. Asking "does this plugin need fixes?" for it answers yes to
// nothing, and "Yes" opens a page with no work on it.
func TestOnlyTheAlwaysAppliedFixIsNotOffered(t *testing.T) {
	m := initialModel()
	m.status.FixPromptOn = true
	m.status.AutoGuiInput = true
	m.nav = []screen{scrMain, scrInstalling}

	carry := installFixesCheckMsg{
		plugin:     "vst:vst3:/x/Plugin Alliance/CrispyTuner.vst3",
		vendor:     "Plugin Alliance",
		fixPrompt:  true,
		autoFix:    true,
		known:      true,
		pluginName: "crispytuner",
		items: []FixItem{
			{ID: "wine_gui_input", Scope: "plugin", Applied: false, Title: "Editor input"},
		},
	}
	// With the input fix applied by default the install ends in a silent
	// re-apply first; the question is only decided when that reports back.
	out, _ := m.update(carry)
	q, _ := out.(model).update(afterInstallFixesMsg{carry: carry})
	got := q.(model)
	if got.top() != scrRunnerSuccessConfirm {
		t.Fatalf("offered the fixes page for a plugin with nothing to offer: screen %d", got.top())
	}
}

// The offer is about PENDING fixes, not about the catalog size. A fix that was
// applied already is not pending, so a plugin with two recorded fixes but
// nothing left to apply is also not worth a question.
func TestNoPendingFixIsNotOfferedEvenWithARecordedCatalog(t *testing.T) {
	m := initialModel()
	m.status.FixPromptOn = true
	m.status.AutoGuiInput = true
	m.nav = []screen{scrMain, scrInstalling}

	carry := installFixesCheckMsg{
		plugin:     "vst:vst3:/x/Plugin Alliance/CrispyTuner.vst3",
		vendor:     "Plugin Alliance",
		fixPrompt:  true,
		autoFix:    true,
		known:      true,
		pluginName: "crispytuner",
		items: []FixItem{
			{ID: "wine_gui_input", Scope: "plugin", Applied: true, Title: "Editor input"},
			{ID: "wine_tooltip", Scope: "plugin", Applied: true, Title: "Tooltips"},
		},
	}
	out, _ := m.update(carry)
	q, _ := out.(model).update(afterInstallFixesMsg{carry: carry})
	got := q.(model)
	if got.top() != scrRunnerSuccessConfirm {
		t.Fatalf("offered the fixes page with nothing pending: screen %d", got.top())
	}
}
