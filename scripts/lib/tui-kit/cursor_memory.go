package tuikit

// Cursor memory: a picker rebuilt from fresh data comes back with the cursor on
// row 0.
//
// Every list in every TUI here is rebuilt the moment something changes — a
// toggle, a refetch, a filter keystroke. A fresh Picker has no cursor position,
// so the row the user was working on vanished and they had to walk the column
// again from the top. On the executable toggle that made each toggle cost a
// full descent, which is why it read as "it threw me back to the beginning".
//
// This is a kit-level fix on purpose: twenty-odd call sites across three TUIs
// each rebuilt their picker by hand, and fixing them one at a time only ever
// fixed the ones somebody remembered. The memory lives in the kit, so a rebuild
// carries the cursor across by default and no host has to remember to ask.
//
// Recall is by VALUE, not index. Index is wrong the moment the list changes
// shape — a plugin removed, a filter narrowed, a folder folded — and then the
// cursor lands on whatever happens to occupy that row now, which is how a
// selection silently lands on the wrong item. Value is the row's identity; if it
// is gone, the kit falls back to the nearest index and then to the top.
//
// Remembers are keyed by the caller's own name for the screen, so two pickers
// on one screen (a list and a dialog) never share a position.

// CursorMemory holds one remembered cursor position per named screen.
type CursorMemory struct {
	byName map[string]cursorMark
}

type cursorMark struct {
	value string
	index int
	// seen is false until something is remembered, so a screen that was never
	// visited does not read back the zero value of the struct.
	seen bool
}

// NewCursorMemory returns an empty memory.
func NewCursorMemory() *CursorMemory {
	return &CursorMemory{byName: map[string]cursorMark{}}
}

// Remember records where the cursor is on a named screen. Call it wherever the
// cursor was when the screen was left.
func (c *CursorMemory) Remember(name string, p Picker) {
	if c == nil {
		return
	}
	if c.byName == nil {
		c.byName = map[string]cursorMark{}
	}
	c.byName[name] = cursorMark{value: p.SelectedValue(), index: p.Index(), seen: true}
}

// RememberIfAbsent records a position only if this screen has none yet.
//
// This is what a rebuild needs. An in-place rebuild (a toggle) must save where
// the cursor was before the fresh Picker replaces it — but a rebuild that runs
// on RE-ENTRY must not: by then the position saved when the screen was left is
// the right one, and overwriting it with whatever picker happens to be current
// loses it. Saving only when there is nothing to lose covers both.
func (c *CursorMemory) RememberIfAbsent(name string, p Picker) {
	if c == nil {
		return
	}
	if c.byName == nil {
		c.byName = map[string]cursorMark{}
	}
	if m, ok := c.byName[name]; ok && m.seen {
		return
	}
	c.Remember(name, p)
}

// Restore moves a freshly rebuilt picker's cursor back to where it was on this
// screen, and returns the picker so it can be chained.
//
// The row is matched by value. When it is still present the cursor goes back to
// it; when it is not — the plugin was uninstalled, the filter narrowed — the
// nearest surviving index is used, so the cursor stays in the region the user
// was looking at instead of jumping to the top.
func (c *CursorMemory) Restore(name string, p Picker) Picker {
	if c == nil {
		return p
	}
	m, ok := c.byName[name]
	if !ok || !m.seen {
		return p
	}
	if v := m.value; v != "" {
		if idx := indexOfValue(p, v); idx >= 0 {
			return p.SelectIndex(idx)
		}
	}
	if m.index > 0 {
		return p.SelectIndex(m.index)
	}
	return p
}

// Forget drops what is remembered for a screen. Call it when the screen's rows
// are replaced by something unrelated, so a stale position cannot leak into an
// unrelated list that happens to share the name.
func (c *CursorMemory) Forget(name string) {
	if c == nil || c.byName == nil {
		return
	}
	delete(c.byName, name)
}

// indexOfValue is the row carrying that value, or -1. Shared with SelectValue's
// search so both agree on what "this row" means.
func indexOfValue(p Picker, value string) int {
	if !p.ready {
		return -1
	}
	items := p.list.Items()
	for i, it := range items {
		pi, ok := it.(PickerItem)
		if !ok {
			continue
		}
		if pi.Value == value {
			return i
		}
	}
	return -1
}
