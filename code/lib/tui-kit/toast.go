package tuikit

import (
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// Toasts are deliberately short-lived: a notice about a toggle that was
// flipped or a refresh that happened is no longer news a few seconds later.
// OK/info messages linger just long enough to be read; warnings and errors
// get a little longer because they usually carry more to parse.
const (
	toastLifetimeOK   = 10 * time.Second
	toastLifetimeWarn = 10 * time.Second
)

// ToastExpireMsg asks a Toast to hide itself. Gen is the generation the
// timer was scheduled for; a Toast only clears when it still matches, so a
// newer toast is never swallowed by an older toast's timer.
type ToastExpireMsg struct{ Gen int }

// ToastExpireCmd returns a tea.Cmd that fires ToastExpireMsg{Gen: gen} after
// d. Every Set call increments the toast's generation and returns a cmd
// built from this; hosts that cannot thread the returned cmd (many call
// sites) can instead let ToastExpireCmd be issued from the Update wrapper
// when Gen changes.
func ToastExpireCmd(gen int, d time.Duration) tea.Cmd {
	if d <= 0 {
		d = toastLifetimeOK
	}
	return tea.Tick(d, func(time.Time) tea.Msg { return ToastExpireMsg{Gen: gen} })
}

func toastLifetimeFor(kind toastKind) time.Duration {
	if kind == toastWarn || kind == toastErr {
		return toastLifetimeWarn
	}
	return toastLifetimeOK
}

// Toast is a transient, non-blocking status line — the replacement for the
// old bash TUI's plain `ok "…"`/`warn "…"` printf lines that leaked into
// the scrollback between gum screens. Embed one in a host model, call
// SetOK/SetWarn/SetErr when something happens that's worth reporting but
// doesn't need a keypress (a toggle flipped, a refresh happened, a folder
// was cleared), and render View() wherever the host wants the line to
// appear. It clears itself after a few seconds — never accumulates, never
// blocks input.
type Toast struct {
	text string
	kind toastKind
	// gen is bumped on every Set. A pending ToastExpireMsg only clears the
	// toast while its Gen still equals this, so resetting the timer by
	// showing a newer toast can't be undone by the older timer.
	gen int
}

type toastKind int

const (
	toastNone toastKind = iota
	toastOK
	toastWarn
	toastErr
)

func (t Toast) set(kind toastKind, text string) (Toast, tea.Cmd) {
	t.kind = kind
	t.text = text
	t.gen++
	return t, ToastExpireCmd(t.gen, toastLifetimeFor(kind))
}

func (t Toast) SetOK(text string) (Toast, tea.Cmd)   { return t.set(toastOK, text) }
func (t Toast) SetWarn(text string) (Toast, tea.Cmd) { return t.set(toastWarn, text) }
func (t Toast) SetErr(text string) (Toast, tea.Cmd)  { return t.set(toastErr, text) }

// Gen reports the current generation. Hosts compare it before/after
// dispatching a message to detect "a toast was just (re)set" and schedule
// the matching expiry without threading the Set return value through every
// call site.
func (t Toast) Gen() int { return t.gen }

// ExpireCmd returns the command that will hide the currently shown toast
// (nil when nothing is shown). Repeated calls for the same generation are
// harmless — the older timer simply no-ops when it lands.
func (t Toast) ExpireCmd() tea.Cmd {
	if t.kind == toastNone {
		return nil
	}
	return ToastExpireCmd(t.gen, toastLifetimeFor(t.kind))
}

// Expire clears the toast only when gen matches; stale timers are ignored.
func (t Toast) Expire(gen int) Toast {
	if gen == t.gen {
		return t.Clear()
	}
	return t
}

// Clear hides the toast immediately.
func (t Toast) Clear() Toast {
	t.kind = toastNone
	t.text = ""
	return t
}

// ClearNonCritical clears the toast immediately unless it's an error --
// call this when the host navigates back to the previous screen, so a
// non-critical "something happened" notice (OK/Warn) doesn't linger onto a
// screen it no longer describes. An error toast is left alone (the toast
// lifetime above still applies to it) so a real failure isn't silently
// swallowed by a quick back-navigation.
func (t Toast) ClearNonCritical() Toast {
	if t.kind == toastErr {
		return t
	}
	return t.Clear()
}

// Update is a convenience for hosts that forward every message to the
// toast: it clears on a matching ToastExpireMsg and ignores stale ones.
func (t Toast) Update(msg tea.Msg) Toast {
	if m, ok := msg.(ToastExpireMsg); ok {
		return t.Expire(m.Gen)
	}
	return t
}

func (t Toast) View() string {
	switch t.kind {
	case toastOK:
		return StyleOK.Render("✓ " + t.text)
	case toastWarn:
		return StyleWarn.Render("! " + t.text)
	case toastErr:
		return StyleErr.Render("✗ " + t.text)
	default:
		return ""
	}
}
