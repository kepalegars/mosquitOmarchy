package main

import (
	"testing"

	tuikit "mosquitomarchy.local/tui-kit"
)

// handlerTestModel returns a Settings-screen model with the plugin-window
// handler row ready to be acted on (status says "hyprland").
func handlerTestModel(t *testing.T) model {
	t.Helper()
	m := initialModel()
	m.w, m.h = 120, 40
	m.status = Status{FilePicker: "default", PluginWinHandler: "hyprland", SortMode: "vendor"}
	m.push(scrSettings)
	_ = m.enterCmd()
	m.picker = m.picker.SelectIndex(3) // "Plugin window handler: Hyprland-managed"
	if got := m.picker.SelectedValue(); got != "toggle_plugin_handler" {
		t.Fatalf("selected value = %q, want toggle_plugin_handler", got)
	}
	return m
}

// TestPluginHandlerArrowConfirm drives the Left/Right (cycleLoadedSetting)
// path on the plugin-window-handler row, which asks for confirmation
// immediately. It used to crash before the confirm was even reachable:
// cycleLoadedSetting has a pointer receiver but its handler case returned
// `m` (*model) from a method typed to return tea.Model, so model.Update's
// `next.(model)` assertion panicked with "interface conversion: tea.Model
// is *main.model, not main.model" and the whole TUI disappeared.
func TestPluginHandlerArrowConfirm(t *testing.T) {
	m := handlerTestModel(t)

	next, _ := m.Update(tuikit.PickerSortMsg{Dir: 1})
	mm, ok := next.(model)
	if !ok {
		t.Fatalf("handler arrow Update returned %T, want model", next)
	}
	if got, want := mm.top(), scrPluginHandlerConfirm; got != want {
		t.Fatalf("top after handler arrow = %v, want scrPluginHandlerConfirm", got)
	}
	if got, want := mm.pendingHandlerMode, "classic"; got != want {
		t.Fatalf("pendingHandlerMode = %q, want %q", got, want)
	}
	// The confirm must render (a sized InfoConfirm), never panic.
	_ = mm.View()
}

// TestPluginHandlerDwellConfirm drives the deferred-apply path: after the
// arrow armed the dwell timer, the tick must reach the confirm screen and
// keep returning a model value.
func TestPluginHandlerDwellConfirm(t *testing.T) {
	m := handlerTestModel(t)
	next, _ := m.Update(tuikit.PickerSortMsg{Dir: 1})
	mm := next.(model)
	seq := mm.settingsDwellSeq

	next2, _ := mm.Update(settingsDwellMsg{row: "toggle_plugin_handler", seq: seq})
	m2, ok := next2.(model)
	if !ok {
		t.Fatalf("handler dwell Update returned %T, want model", next2)
	}
	if got, want := m2.top(), scrPluginHandlerConfirm; got != want {
		t.Fatalf("top after handler dwell = %v, want scrPluginHandlerConfirm", got)
	}
	_ = m2.View()
}

// TestPluginHandlerConfirmResult exercises BOTH confirm outcomes end to end:
// Enter on the row opens the framed InfoConfirm, and the resulting
// ConfirmResultMsg must pop back to Settings and (on Yes) schedule the real
// set-plugin-handler command without panicking. The command is deliberately
// NOT executed (cmd is discarded) so no real Hyprland config is touched.
func TestPluginHandlerConfirmResult(t *testing.T) {
	t.Run("yes applies", func(t *testing.T) {
		m := handlerTestModel(t)
		next, _ := m.Update(tuikit.PickerResultMsg{Value: "toggle_plugin_handler"})
		mm, ok := next.(model)
		if !ok {
			t.Fatalf("enter Update returned %T, want model", next)
		}
		if got, want := mm.top(), scrPluginHandlerConfirm; got != want {
			t.Fatalf("top after enter = %v, want scrPluginHandlerConfirm", got)
		}
		_ = mm.View()

		next2, cmd := mm.Update(tuikit.ConfirmResultMsg{Yes: true})
		m2, ok := next2.(model)
		if !ok {
			t.Fatalf("confirm Update returned %T, want model", next2)
		}
		if got, want := m2.top(), scrSettings; got != want {
			t.Fatalf("top after confirm yes = %v, want scrSettings", got)
		}
		if !m2.loading {
			t.Fatalf("loading = false after confirm yes, want true")
		}
		_ = cmd // would run set-plugin-handler; intentionally not executed
		_ = m2.View()
	})

	t.Run("no keeps current", func(t *testing.T) {
		m := handlerTestModel(t)
		next, _ := m.Update(tuikit.PickerResultMsg{Value: "toggle_plugin_handler"})
		mm := next.(model)
		next2, cmd := mm.Update(tuikit.ConfirmResultMsg{Yes: false})
		m2, ok := next2.(model)
		if !ok {
			t.Fatalf("confirm Update returned %T, want model", next2)
		}
		if got, want := m2.top(), scrSettings; got != want {
			t.Fatalf("top after confirm no = %v, want scrSettings", got)
		}
		if m2.pendingHandlerMode != "" {
			t.Fatalf("pendingHandlerMode = %q after cancel, want empty", m2.pendingHandlerMode)
		}
		_ = cmd
	})

	t.Run("esc cancels", func(t *testing.T) {
		m := handlerTestModel(t)
		next, _ := m.Update(tuikit.PickerResultMsg{Value: "toggle_plugin_handler"})
		mm := next.(model)
		next2, _ := mm.Update(tuikit.ConfirmResultMsg{Canceled: true})
		m2, ok := next2.(model)
		if !ok {
			t.Fatalf("confirm Update returned %T, want model", next2)
		}
		if got, want := m2.top(), scrSettings; got != want {
			t.Fatalf("top after confirm esc = %v, want scrSettings", got)
		}
	})
}

// TestPluginHandlerXFromPluginList drives the other handler-change entry
// point — the plugin list's "x" shortcut — through the framed confirm and
// back, ensuring the global-rules path never returns a *model or pops a
// missing screen.
func TestPluginHandlerXFromPluginList(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40
	m.status = Status{PluginWinHandler: "classic", SortMode: "vendor"}
	m.push(scrPluginList)

	next, _ := m.Update(tuikit.PickerActionMsg{Key: "x"})
	mm, ok := next.(model)
	if !ok {
		t.Fatalf("x Update returned %T, want model", next)
	}
	if got, want := mm.top(), scrPluginHandlerConfirm; got != want {
		t.Fatalf("top after x = %v, want scrPluginHandlerConfirm", got)
	}
	if got, want := mm.pendingHandlerMode, "hyprland"; got != want {
		t.Fatalf("pendingHandlerMode after x = %q, want hyprland", got)
	}
	_ = mm.View()

	next2, cmd := mm.Update(tuikit.ConfirmResultMsg{Yes: true})
	m2, ok := next2.(model)
	if !ok {
		t.Fatalf("confirm Update returned %T, want model", next2)
	}
	if got, want := m2.top(), scrPluginList; got != want {
		t.Fatalf("top after confirm = %v, want scrPluginList", got)
	}
	_ = cmd // set-plugin-handler intentionally not executed
}

// TestHandlerResultMessagesAreSafe feeds the command-result messages the
// bash side can return, so neither a success toast nor a handler error can
// panic (nil map, bad pop, etc.).
func TestHandlerResultMessagesAreSafe(t *testing.T) {
	m := initialModel()
	m.w, m.h = 120, 40

	next, _ := m.Update(pluginHandlerOKMsg{handler: "classic"})
	mm, ok := next.(model)
	if !ok {
		t.Fatalf("ok result Update returned %T, want model", next)
	}
	_ = mm.View()

	next2, _ := mm.Update(handlerErrMsg{err: errAction{msg: "boom"}})
	m2, ok := next2.(model)
	if !ok {
		t.Fatalf("err result Update returned %T, want model", next2)
	}
	_ = m2.View()
}
