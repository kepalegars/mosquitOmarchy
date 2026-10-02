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
	"sort"
	"strings"

	key "github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	tuikit "mosquitomarchy.local/tui-kit"
)

// ThemeImageRec is one image the backend found in the chosen folder.
// ThemeRec is one installed theme, for the uninstall screen.
type ThemeRec struct {
	Name    string `json:"name"`
	Current bool   `json:"current"`
}

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

// defaultThemeDir is where Theming looks first: whatever the user last chose
// with "Make this the default folder", and ~/Pictures/Wallpapers until they do.
//
// It leads the list because it is the answer for the actual task — a theme is
// built from a wallpaper — and the bundled Omarchy images are a fallback for a
// machine that has none of its own yet.
//
// The stored preference wins, so the row survives a restart instead of asking
// again every time. A preference pointing at a folder that is gone falls back to
// the wallpaper folder rather than being offered as a dead row.
func defaultThemeDir() string {
	if p := storedThemeDefaultDir(); p != "" {
		if st, err := os.Stat(p); err == nil && st.IsDir() {
			return p
		}
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Pictures/Wallpapers")
}

// storedThemeDefaultDir reads the saved preference, or "" when there is none.
func storedThemeDefaultDir() string {
	out, err := runQuick("theme-default-dir", "get")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// ensureDefaultThemeDir creates the default folder if it is missing.
//
// The list of candidate folders is gone (the screen is actions only now), but
// creating the default still matters: a wallpaper folder that does not exist is
// the one thing the chooser would open on and find empty. ~/Pictures/Wallpapers
// is the default, and it is created rather than complained about.
//
// Returns the default path either way, so the caller has something to show.
func ensureDefaultThemeDir() string {
	def := defaultThemeDir()
	if _, err := os.Stat(def); err != nil {
		_ = os.MkdirAll(def, 0o755)
	}
	return def
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

// rebuildThemeFolderPicker is the first screen of Theming.
//
// It used to list candidate folders — Wallpapers, Omarchy wallpapers,
// Pictures, Downloads, Images, Screenshots — above the actions. That list was
// gone the moment the folder row is chosen: every entry is a directory, and
// the row above it already says which one it is. Five rows of paths to reach
// an action, when the action opens a picker anyway.
//
// So the screen is actions only, and the folder is whatever the image chooser
// comes back with. "Make this the default folder" appears ONLY once a folder
// has actually been chosen in this visit: it sets a preference about a folder,
// and offering it before one exists would be offering to save nothing.
func (m model) rebuildThemeFolderPicker() navPicker {
	def := defaultThemeDir()
	items := []tuikit.PickerItem{
		// The whole flow in one row: an image chooser opens, and the flow
		// continues at the name step — the folder is settled by having picked a
		// file inside it.
		{Display: "Select image", Value: "__pick__"},
		{Display: "Remove Themes (any)", Value: "__uninstall__"},
	}
	if m.themeDir != "" {
		if st, err := os.Stat(m.themeDir); err == nil && st.IsDir() {
			items = append(items, tuikit.PickerItem{
				Display: "Make this the default folder: " + baseName2(m.themeDir),
				Value:   "__setdefault__",
				Sub:     "this session looks in " + ellipsizeMiddle(m.themeDir, m.contentWidth()-10),
			})
		}
	}
	// Restoring the deleted stock themes lives at the END of the menu, on its
	// own, for the same reason it is not the first row: it is a repair for a
	// situation you have to be in before it means anything.
	items = append(items,
		tuikit.PickerItem{Display: "Restore the deleted stock Omarchy themes", Value: "__restorestock__"},
		tuikit.PickerItem{Display: "Back", Value: "back"},
	)
	h := "Create a theme from an image"
	if def != "" {
		h += " (looks in " + baseName2(def) + ")"
	}
	return newNavPicker(h, items).SetSize(m.contentSize())
}

// baseName2 is the leaf of a path, for showing "Wallpapers" rather than
// "/home/someone/Pictures/Wallpapers" in a place with no room for the rest.
func baseName2(p string) string {
	if i := strings.LastIndexByte(p, '/'); i >= 0 && i+1 < len(p) {
		return p[i+1:]
	}
	return p
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

// rebuildThemeDone is the success prompt. It matches the shape every other
// finished action uses in this TUI — "Back" / "See log", same words, same
// order — because a screen that reads "OK — back to the menu" instead is the
// same idea wearing different clothes, and the reader has to learn it twice.
//
// "Apply theme" is the third row rather than the second: it is the only choice
// that touches the desktop, and it is deliberately not the one Enter lands on
// by default. The whole point of not applying automatically is that the user
// sees what they made first.
func (m model) rebuildThemeDone() navPicker {
	return newNavPicker(
		fmt.Sprintf("Theme '%s' created — not applied", m.themeCreated),
		[]tuikit.PickerItem{
			{Display: "See log", Value: "log", Sub: "what the generator did"},
			{Display: "Back", Value: "ok", Sub: "back to the menu"},
			{Display: "Apply theme", Value: "apply", Sub: "repaints the desktop: wallpaper, bar, icons, terminal, GTK…"},
		}).SetSize(m.contentSize())
}

// themeAskName opens the name step, pre-filled with the image's own name so
// Enter twice is a complete theme for anyone who does not care what it is
// called. Shared by the folder→image→name path and the one-row "Select image"
// path, so both ask the same question in the same words.
//
// Pointer receiver on purpose: it pushes a screen and writes two fields. With a
// value receiver that all happened on a copy, the caller kept its own model and
// the name screen never opened — which is the whole step.
func (m *model) themeAskName(proposed, fallback string) tea.Cmd {
	if proposed == "" {
		proposed = fallback
	}
	if proposed == "" {
		proposed = "my-theme"
	}
	m.themeInput = tuikit.NewTextInput("Theme name:", proposed)
	m.themeInputStep = 1
	m.push(scrThemeName)
	return m.themeInput.Init()
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
	case "__pick__":
		// The one-row version of the whole flow: choose an image in the file
		// chooser, and go straight to naming it. The folder list is bypassed,
		// which is the point — picking an image already answers where it is.
		return m, pickThemeImageCmd()
	case "__setdefault__":
		// Remember this folder so the next visit opens here. Refuses a row that
		// is not a real folder (Back, Type a folder path…, Select Image…), since
		// those are values, not paths.
		if m.themeDir != "" {
			if st, err := os.Stat(m.themeDir); err == nil && st.IsDir() {
				return m, setThemeDefaultDirCmd(m.themeDir)
			}
		}
		m.toast, _ = m.toast.SetWarn("choose a folder first, then set it as the default")
		return m, nil
	case "__unlock__":
		// Toggle and re-render the SAME screen — no navigation, because there is
		// nowhere to go until the choice is made.
		m.themeUnlockStyle = !m.themeUnlockStyle
		m.themeUnlockPicker = m.rebuildThemeUnlock()
		return m, nil
	case "create":
		m.pendingAction = "theme-create"
		// No "the theme is NOT applied — you get that choice afterwards". It
		// was on this page AND on the success page, saying the same thing
		// twice, and on this page it reads as a caveat about a state the user
		// cannot see yet. The success screen's own rows say what they do.
		m.pendingMsg = fmt.Sprintf(
			"Create the theme '%s' from %s?\n\nFolder: %s\n\n%s",
			m.themePendingName, m.themeImage, m.themeDir, unlockLineFor(m.themeUnlockStyle))
		m.pendingNo = "Cancel"
		m.pendingYes = "Create"
		m.push(scrConfirm)
		m.confirm = tuikit.NewConfirm(m.pendingMsg, m.pendingNo, m.pendingYes)
		return m, nil
	case "__uninstall__":
		m.themeList = nil
		m.themeChecked = map[string]bool{}
		return m, fetchThemeList()
	case "__restorestock__":
		m.themeStock = nil
		return m.startWorking("Restoring the stock themes", "theme-restore-stock")
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
		// Through startWorking, NOT a bare push(scrWorking). The bare push put
		// the working screen up with no runner behind it, so its Esc handler --
		// which only pops once m.runner.Done() -- could never fire: the screen
		// rendered the raw log with no frame and there was no way off it. That
		// is the "stuck in the log" this row used to lead to. startWorking
		// attaches a real runner, so the screen is a runner screen like every
		// other one and Esc behaves the same way everywhere.
		name := m.themeCreated
		m.resetThemeFlow()
		m.pop()
		m.themeApplyName = name
		return m.startWorking("Applying the theme",
			workingArgs("theme-apply", []string{name})...)
	}

	// Not one of the control rows: on the image list this is a real file name.
	if from == scrThemeImage && res.Value != "" {
		for _, r := range m.themeImages {
			if r.File == res.Value {
				m.themeImage = r.File
				cmd := m.themeAskName(r.Proposed, r.Name)
				return m, cmd
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

// pickThemeImageCmd opens the image chooser and, on a real choice, fills in the
// folder and the image so the flow continues at the NAME step — which is where
// the user actually has something to decide.
//
// An empty answer is a cancel, not a failure: it must leave the screen exactly
// as it was, because the chooser is a separate window and closing it without
// choosing is a normal thing to do.
func pickThemeImageCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("theme-pick", "file")
		if err != nil {
			return themePickErrMsg{err: err}
		}
		p := strings.TrimSpace(string(out))
		if p == "" {
			return themeImagePickedMsg{} // cancelled
		}
		abs, aerr := filepath.Abs(p)
		if aerr != nil {
			abs = p
		}
		return themeImagePickedMsg{path: abs, dir: filepath.Dir(abs)}
	}
}

// pickThemeFolderCmd is the folder half of the same chooser, for "set a new
// default folder" from the Theming menu itself.
func pickThemeFolderCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("theme-pick", "folder")
		if err != nil {
			return themePickErrMsg{err: err}
		}
		p := strings.TrimSpace(string(out))
		if p == "" {
			return themeFolderPickedMsg{}
		}
		abs, aerr := filepath.Abs(p)
		if aerr != nil {
			abs = p
		}
		return themeFolderPickedMsg{path: abs}
	}
}

// themeImagePickedMsg carries an image chosen outside the TUI.
type themeImagePickedMsg struct {
	path string
	dir  string
}

// themeFolderPickedMsg carries a folder chosen outside the TUI.
type themeFolderPickedMsg struct{ path string }

// setThemeDefaultDirCmd persists the folder preference and reports it.
func setThemeDefaultDirCmd(dir string) tea.Cmd {
	return func() tea.Msg {
		if _, err := runQuick("theme-default-dir", "set", dir); err != nil {
			return themePickErrMsg{err: err}
		}
		return toastThemeMsg{text: "default folder set: " + dir}
	}
}

// themePickErrMsg is a failed chooser, kept separate from the generic error so
// the flow stays where it is instead of dropping to the main menu.
type themePickErrMsg struct{ err error }

// toastThemeMsg reports a theme-flow side effect (the default folder being set)
// as a toast, so it does not need its own screen.
type toastThemeMsg struct{ text string }

// stripImageExt drops the extension so a picked "nebula-4k.png" proposes the
// theme name "nebula-4k" rather than "nebula-4k.png".
func stripImageExt(s string) string {
	if i := strings.LastIndexByte(s, '.'); i > 0 {
		return s[:i]
	}
	return s
}

// rebuildThemeUnlock is the last step before the build: whether to also create
// the lock/boot screen from this theme.
//
// It is its own screen, and it comes AFTER the name, because that is what the
// decision is about. Before the name there is no theme yet, so the row would
// read as a setting; after it, the row can say which theme's boot screen is
// being talked about — and it is the moment the user has the most context for
// the one part of the build that will ask for a password.
//
// Left/Right toggles it, Enter continues. Same pending-then-dwell shape as the
// Live Mode settings so the arrows work the way they do everywhere else.
func (m model) rebuildThemeUnlock() navPicker {
	on := "off"
	if m.themeUnlockStyle {
		on = "on"
	}
	name := m.themePendingName
	if name == "" {
		name = "this theme"
	}
	// No sub-lines here, and no "(←/→)" in the label. Both were redundant with
	// the shortcut bar: the arrows are what the row is FOR, and spelling them
	// into the name meant the same instruction appeared twice, once where it
	// belongs and once where the reader has to parse it out of a sentence.
	items := []tuikit.PickerItem{
		{Display: "Create an unlock style too? " + on, Value: "__unlock__"},
		{Display: "Create the theme", Value: "create"},
		{Display: "Back", Value: "back"},
	}
	h := fmt.Sprintf("Create the theme '%s'", name)
	if m.themeUnlockStyle {
		h += " — the boot screen will ask for your password"
	}
	return newNavPicker(h, items).
		SetHelpKeys(
			key.NewBinding(key.WithKeys("left", "right"), key.WithHelp("←/→", "toggle unlock screen")),
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "continue")),
		).
		SetSize(m.contentSize())
}

// unlockLineFor names the lock/boot-screen choice in the confirmation text, so
// the user reads what the build will do before it does it — the boot screen is
// the step that asks for a password, and a prompt that arrives unannounced is
// the thing worth avoiding.
func unlockLineFor(on bool) string {
	if on {
		return "Unlock / boot screen: created too — this will ask for your password."
	}
	return "Unlock / boot screen: skipped (you turned it off)."
}

// themeListMsg carries the installed themes back from the backend.
type themeListMsg struct {
	themes []ThemeRec
	err    error
}

// themeStockMsg carries the stock-theme availability map from the restore verb.
type themeStockMsg struct {
	present map[string]bool
	err     error
}

// fetchThemeList loads the user's installed themes.
func fetchThemeList() tea.Cmd {
	return func() tea.Msg {
		out, err := runQuick("theme-list")
		if err != nil {
			return themeListMsg{err: err}
		}
		rows, err := decodeJSONLines[ThemeRec](out)
		return themeListMsg{themes: rows, err: err}
	}
}

// rebuildThemeUninstall lists the user's themes with a circle per row, Tab to
// tick several and Enter to remove them all at once — the same multi-select
// shape the plugin and fix screens use, because removing five themes one at a
// time through five confirmations is the thing multi-select exists to avoid.
func (m model) rebuildThemeUninstall() navPicker {
	items := make([]tuikit.PickerItem, 0, len(m.themeList)+1)
	for _, t := range m.themeList {
		mark := "○"
		if m.themeChecked[t.Name] {
			mark = "●"
		}
		// No sub-line. The rows are a list of names to tick; the sentence under
		// each said the same thing the row already said, and the applied-theme
		// caveat is enforced on the tick itself (it refuses, with a toast), so
		// spelling it out per row was noise.
		items = append(items, tuikit.PickerItem{Display: mark + " " + t.Name, Value: t.Name})
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	h := "Uninstall which themes? (Tab ticks, Enter removes the ticked ones)"
	if len(m.themeList) == 0 {
		h = "No theme of yours to uninstall — the stock ones belong to Omarchy"
	}
	return newNavPicker(h, items).SetSize(m.contentSize())
}

// rebuildThemeRestore lists the stock themes with a circle on the ones already
// present, so the row answers "what would this give me back" instead of "press
// a button and hope".
func (m model) rebuildThemeRestore() navPicker {
	names := make([]string, 0, len(m.themeStock))
	for n := range m.themeStock {
		names = append(names, n)
	}
	sort.Strings(names)
	items := make([]tuikit.PickerItem, 0, len(names)+1)
	missing := 0
	for _, n := range names {
		mark := "✓"
		if !m.themeStock[n] {
			mark = "○"
			missing++
		}
		items = append(items, tuikit.PickerItem{Display: mark + " " + n, Value: n})
	}
	items = append(items, tuikit.PickerItem{Display: "Back", Value: "back"})
	h := fmt.Sprintf("Stock Omarchy themes — ✓ means already on this machine (%d missing)", missing)
	return newNavPicker(h, items).SetSize(m.contentSize())
}

// themeRemoveDoneMsg reports the outcome of a removal batch, so the screen can
// say how many went rather than just "finished".
type themeRemoveDoneMsg struct{ n int }

// toggleThemeTick flips one theme's selection, refusing the theme that is
// currently applied: removing it would leave the desktop pointing at a theme
// that is no longer there.
func (m *model) toggleThemeTick(name string) {
	if m.themeChecked == nil {
		m.themeChecked = map[string]bool{}
	}
	for _, t := range m.themeList {
		if t.Name == name && t.Current {
			m.toast, _ = m.toast.SetWarn("'" + name + "' is the applied theme — switch to another one first")
			return
		}
	}
	if m.themeChecked[name] {
		delete(m.themeChecked, name)
	} else {
		m.themeChecked[name] = true
	}
}
