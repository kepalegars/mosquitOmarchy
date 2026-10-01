// theme.go — the "Theming" row on the main menu.
//
// This used to be a single row inside the Setup TUI's Themes category, which
// ran the interactive create-theme.sh in a child process. Two problems with
// that: it was filed as "install a module" when it is really a create-this-
// thing action, and gum picking a wallpaper in a popup behind a full-screen TUI
// is how you silently generate a theme from the wrong file.
//
// So it moved here, after Keybindings, and it is now a 4-step flow the TUI
// owns end to end: folder -> image -> name -> create. The generator is only
// ever called with all three already chosen, via mosquitomarchy-actions
// theme-create. Nothing is applied: applying a theme runs every Omarchy theme
// hook, so it is the last row of the success prompt, never a side effect.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	tuikit "mosquitomarchy.local/tui-kit"
)

// ThemeImageRec is one image the backend found in the chosen folder.
type ThemeImageRec struct {
	File     string `json:"file"`     // "Rarity.jpg"
	Name     string `json:"name"`     // "Rarity"  (file name, no extension)
	Proposed string `json:"proposed"` // "Rarity"  (default theme name offered)
}

// themeImagesMsg carries a folder listing back from the backend.
type themeImagesMsg struct {
	dir  string
	rows []ThemeImageRec
	err  error
}

// themeCreateMsg reports the outcome of the generator run.
type themeCreateMsg struct {
	name string
	log  string
	err  error
}

func fetchThemeImagesCmd(dir string) tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("theme-images", dir)
		if err != nil {
			return themeImagesMsg{dir: dir, err: err}
		}
		var rows []ThemeImageRec
		for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			var r ThemeImageRec
			if err := json.Unmarshal([]byte(line), &r); err != nil {
				continue
			}
			rows = append(rows, r)
		}
		return themeImagesMsg{dir: dir, rows: rows}
	}
}

// themeCreateCmd runs the generator. The log is written by create-theme.sh
// itself (--log), so "See log" always shows the real run including the pkexec
// prompt at the end, which is the part that actually fails sometimes.
func themeCreateCmd(dir, image, name string, apply bool) tea.Cmd {
	return func() tea.Msg {
		args := []string{"theme-create", dir, image, name}
		if apply {
			args = append(args, "apply")
		}
		if _, err := runQuick(args...); err != nil {
			return themeCreateMsg{name: name, log: defaultThemeLog(), err: err}
		}
		return themeCreateMsg{name: name, log: defaultThemeLog()}
	}
}

// themeImagesArrived rebuilds the image list once the backend answered. It also
// refuses to leave the screen in the "reading…" state: if the folder turned out
// to be empty (or unreadable), the list becomes two rows that say so and offer a
// way out, because a permanent "reading…" spinner looks like a hang.
func (m model) themeImagesArrived(msg themeImagesMsg) model {
	m.themeImagesFetched = true
	if msg.err != nil {
		m.themeImages = nil
		m.toast, _ = m.toast.SetWarn("could not read the folder: " + msg.err.Error())
	} else {
		m.themeImages = msg.rows
	}
	m.themeImagePicker = m.rebuildThemeImagePicker()
	return m
}

func themeApplyCmd(name string) tea.Cmd {
	return func() tea.Msg {
		if _, err := runQuick("theme-apply", name); err != nil {
			return themeCreateMsg{name: name, err: err}
		}
		return themeCreateMsg{name: name}
	}
}

func defaultThemeLog() string {
	return filepath.Join(os.Getenv("HOME"), ".local/state/mosquitomarchy/theme-create.log")
}

// defaultThemeDir is where Theming looks first: ~/Pictures/Wallpapers, the
// user's own wallpaper folder. It leads the list because it is the answer for
// the actual task — a theme is built from a wallpaper — and the bundled Omarchy
// images are a fallback for a machine that has none of its own yet.
func defaultThemeDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Pictures/Wallpapers")
}

// themeFolderCandidates are the folders offered without typing anything. The
// first one is the user's wallpaper folder; the rest are where people's pictures
// actually are, plus the bundled set so a fresh machine has something to pick.
func themeFolderCandidates() []struct{ Label, Path string } {
	home, _ := os.UserHomeDir()
	repo := ""
	if exe, err := os.Executable(); err == nil {
		// deployed binary: ~/.local/bin/mosquitomarchy-tui -> repo is ../../mosquitOmarchy
		repo = filepath.Join(filepath.Dir(exe), "../../mosquitOmarchy/scripts/theme/Wallpapers")
	}
	def := defaultThemeDir()
	out := []struct{ Label, Path string }{
		{"Wallpapers", def},
		{"Omarchy wallpapers (bundled)", repo},
		{"Pictures", filepath.Join(home, "Pictures")},
		{"Downloads", filepath.Join(home, "Downloads")},
		{"Images", filepath.Join(home, "Images")},
		{"Screenshots", filepath.Join(home, "Pictures/Screenshots")},
	}
	// Drop the ones that do not exist, and the bundled row when it cannot be
	// located — offering a folder that is not there is worse than not offering
	// it, because it looks like the list is broken.
	//
	// The default is the exception: it is the row the user expects to find
	// first, and it is the folder Theming is for. Deleting ~/Pictures/Wallpapers
	// should not quietly move the default elsewhere, so the row is created
	// instead of dropped. Every other row stays read-only.
	kept := out[:0]
	for _, c := range out {
		if c.Path == "" {
			continue
		}
		if _, err := os.Stat(c.Path); err != nil {
			if c.Path != def {
				continue
			}
			if mkErr := os.MkdirAll(c.Path, 0o755); mkErr != nil {
				// Cannot create it (read-only home, a file in the way). Fall
				// through and drop the row rather than offer a dead path.
				continue
			}
		}
		kept = append(kept, c)
	}
	return kept
}

// ellipsizeMiddle fits s into w columns, cutting the MIDDLE and not the end, so
// both ends of a path stay readable: "/home/mos…" says the start, "…/Wallpapers"
// says where it ends. A tail-only cut gives "…/mosquitomarchy/scripts/theme/Wal…",
// which is the one part nobody needs — the leaf is already in the row label.
//
// Returns s untouched when it already fits, so short paths are never touched up.
func ellipsizeMiddle(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if lipgloss.Width(s) <= w {
		return s
	}
	keep := w - 1 // the ellipsis itself
	// Below 4 columns there is no room for a head AND a tail: the ellipsis plus
	// one column on each side is the smallest cut that still says "middle". A
	// narrower budget gets the bare marker rather than a string that is longer
	// than the line it is meant to fit on.
	if keep < 3 {
		return "…"
	}
	head := keep/2 + keep%2 // one extra column on the head: paths are read left-to-right
	tail := keep - head
	r := []rune(s)
	var headPart, tailPart strings.Builder
	used := 0
	for _, c := range r {
		cw := lipgloss.Width(string(c))
		if used+cw > head {
			break
		}
		headPart.WriteRune(c)
		used += cw
	}
	used = 0
	for i := len(r) - 1; i >= 0; i-- {
		cw := lipgloss.Width(string(r[i]))
		if used+cw > tail {
			break
		}
		tailPart.WriteRune(r[i])
		used += cw
	}
	// tailPart was filled right-to-left, so reverse it; the head is already in
	// order. Only paths too long to show whole reach this.
	tailRunes := []rune(tailPart.String())
	for i, j := 0, len(tailRunes)-1; i < j; i, j = i+1, j-1 {
		tailRunes[i], tailRunes[j] = tailRunes[j], tailRunes[i]
	}
	return headPart.String() + "…" + string(tailRunes)
}

// rebuildThemeFolderPicker is the first step: which folder to look in.
func (m model) rebuildThemeFolderPicker() navPicker {
	items := []tuikit.PickerItem{}
	// The sub-line is the full path, which is the one thing that does not fit on
	// a real machine: /home/<user>/... is already ~20 columns before the leaf.
	// The picker truncates the RIGHT-hand end, which throws away exactly the
	// informative part: "…/mosquitOmarchy/scripts/theme/Wal…", where the leaf
	// is already spelled out in the row label above it. Ellipsize here instead,
	// in the middle, so the row arrives pre-fitted and the picker's own cut
	// becomes a no-op.
	//
	// The width comes from the same contentWidth every other part of this TUI
	// measures against, minus the picker frame, its indent, and the accent box
	// the row reserves. The sub-line renders at the same indent as the title.
	avail := m.contentWidth() - 10
	if avail < 12 {
		avail = 12
	}
	for _, c := range themeFolderCandidates() {
		items = append(items, tuikit.PickerItem{
			Display: c.Label,
			Value:   c.Path,
			Sub:     ellipsizeMiddle(c.Path, avail),
		})
	}
	items = append(items,
		tuikit.PickerItem{Display: "Type a folder path…", Value: "__type__"},
		tuikit.PickerItem{Display: "Back", Value: "back"},
	)
	h := "Create a theme — where are the images?"
	if m.themeDir != "" {
		h = fmt.Sprintf("Create a theme — where are the images? (now: %s)", m.themeDir)
	}
	return newNavPicker(h, items).SetSize(m.contentSize())
}

// rebuildThemeImagePicker is the second step: which image in that folder.
func (m model) rebuildThemeImagePicker() navPicker {
	if len(m.themeImages) == 0 && m.themeImagesFetched {
		return newNavPicker(
			fmt.Sprintf("No .png/.jpg/.jpeg/.webp in %s — pick another folder", m.themeDir),
			[]tuikit.PickerItem{
				{Display: "Choose another folder", Value: "__refolder__"},
				{Display: "Back", Value: "back"},
			}).SetSize(m.contentSize())
	}
	items := []tuikit.PickerItem{}
	for _, r := range m.themeImages {
		items = append(items, tuikit.PickerItem{Display: r.File, Value: r.File, Sub: "theme name: " + r.Proposed})
	}
	items = append(items, tuikit.PickerItem{Display: "Choose another folder", Value: "__refolder__"})
	return newNavPicker(
		fmt.Sprintf("Create a theme — which image? (%d in %s)", len(m.themeImages), m.themeDir),
		items).SetSize(m.contentSize())
}

// rebuildThemeDone is the success prompt. Three ways out, and the wording
// matters: "Apply theme" is the only one that touches the desktop, and it says
// so, because the whole point of not applying automatically is that the user
// gets to see what they made first.
func (m model) rebuildThemeDone() navPicker {
	return newNavPicker(
		fmt.Sprintf("Theme '%s' created — not applied", m.themeCreated),
		[]tuikit.PickerItem{
			{Display: "See log", Value: "log", Sub: "what the generator did"},
			{Display: "OK — back to the menu", Value: "ok"},
			{Display: "Apply theme", Value: "apply", Sub: "repaints the desktop: wallpaper, bar, icons, terminal, GTK…"},
		}).SetSize(m.contentSize())
}

// themePicked routes every Enter on the theme flow's pickers. from is the
// screen the Enter happened on, because "Rarity.jpg" means "use this image" on
// the image list and nothing at all on the other two.
func (m model) themePicked(from screen, res tuikit.PickerResultMsg) (model, tea.Cmd) {
	switch res.Value {
	case "back":
		m.pop()
		return m, nil
	case "__type__":
		m.themeInput = tuikit.NewTextInput("Folder to look for images in:", "")
		m.themeInputStep = 0
		m.push(scrThemeInput)
		return m, m.themeInput.Init()
	case "__refolder__":
		m.pop() // back out of the image list…
		m.themeDir = ""
		m.themeImages = nil
		m.themeImagesFetched = false
		m.themeFolderPicker = m.rebuildThemeFolderPicker()
		return m, nil
	case "log":
		body, err := os.ReadFile(m.themeLog)
		if err != nil {
			m.toast, _ = m.toast.SetWarn("could not read the log: " + err.Error())
			return m, nil
		}
		if len(body) == 0 {
			body = []byte("(the log is empty)")
		}
		m.info = tuikit.NewInfo(string(body)).SetSize(m.contentSize())
		m.push(scrInfo)
		return m, nil
	case "ok":
		m.resetThemeFlow()
		m.pop()
		return m, nil
	case "apply":
		name := m.themeCreated
		m.resetThemeFlow()
		m.pop()
		m.push(scrWorking)
		m.workingLabel = fmt.Sprintf("Applying the theme '%s'", name)
		return m, themeApplyCmd(name)
	}

	// Not one of the control rows: on the image list this is a real file name.
	if from == scrThemeImage && res.Value != "" {
		for _, r := range m.themeImages {
			if r.File == res.Value {
				m.themeImage = r.File
				// Step 3: the name field starts on the image's own name, so
				// Enter twice is a complete theme for anyone who does not care
				// what it is called.
				proposed := r.Proposed
				if proposed == "" {
					proposed = r.Name
				}
				m.themeInput = tuikit.NewTextInput("Theme name:", proposed)
				m.themeInputStep = 1
				m.push(scrThemeName)
				return m, m.themeInput.Init()
			}
		}
	}
	return m, nil
}

// themeInputDone handles Enter on the folder-path field.
func (m model) themeInputDone(v string) (model, tea.Cmd) {
	raw := strings.TrimSpace(v)
	m.pop()
	if raw == "" {
		m.toast, _ = m.toast.SetWarn("no folder given")
		return m, nil
	}
	path := strings.Trim(raw, `"'`)
	if strings.HasPrefix(path, "~/") {
		path = filepath.Join(os.Getenv("HOME"), path[2:])
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		m.toast, _ = m.toast.SetWarn(err.Error())
		return m, nil
	}
	if st, err := os.Stat(abs); err != nil || !st.IsDir() {
		m.toast, _ = m.toast.SetWarn(fmt.Sprintf("not a folder: %s", abs))
		return m, nil
	}
	return m.startThemeImages(abs)
}

// startThemeImages is step 2: list what is actually in that folder.
func (m model) startThemeImages(dir string) (model, tea.Cmd) {
	m.themeDir = dir
	m.themeImages = nil
	m.themeImagesFetched = false
	m.themeImagePicker = newNavPicker("Reading folder…",
		[]tuikit.PickerItem{{Display: "reading…", Value: "", Disabled: true}}).SetSize(m.contentSize())
	m.push(scrThemeImage)
	return m, fetchThemeImagesCmd(dir)
}

func (m *model) resetThemeFlow() {
	m.themeDir = ""
	m.themeImages = nil
	m.themeImagesFetched = false
	m.themeImage = ""
	m.themeCreated = ""
	m.themeLog = ""
	m.themeInput = tuikit.TextInput{}
}

var errNoImage = errors.New("no image selected")
