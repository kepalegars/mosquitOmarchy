package main

import (
	"encoding/json"
	"strings"

	"github.com/charmbracelet/bubbles/key"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

type screen int

const (
	scrMain screen = iota
	scrStatus
	scrSetup
	scrSetupCat
	scrUpdate
	scrHealth
	scrKB
	scrKBList
	scrKBCat
	scrKBItems
	scrKBKeys
	scrKBInput
	scrBackup
	scrBackupRestore
	scrMenuEntries
	scrSettings
	scrConfirm
	scrWorking
	scrPassphrase
	scrInfo
	scrBackupOptions
	scrBackupApps
	scrPreinstalls
	// scrQuickFixes is the Quick fixes list, reached from its folder row in
	// Setup. It existed in the shell launcher (launcher_run_category -> fixes)
	// and the TUI replaced that launcher without ever carrying the category
	// across, so Setup had no way to reach a single quick fix.
	scrQuickFixes
	// Creating a theme from an image: a 4-step flow on the main menu. Each
	// step is its own screen so Esc backs out one decision at a time instead of
	// dumping you at the main menu with three choices made.
	scrBackupName
	scrThemeFolder
	scrThemeImage
	scrThemeInput
	scrThemeName
	// scrThemeUnlock is the last step before the build: the lock/boot screen
	// toggle. It sits AFTER the name on purpose — that is the point of the
	// request, and it is also where the information is best: once the theme has
	// a name, "create its boot screen too?" is a question about THAT theme.
	scrThemeUnlock
	scrThemeDone
	// scrThemeUninstall and scrThemeRestore are the two theme-management
	// screens reachable from Theming: remove the user's themes (multi-select),
	// and put the deleted stock ones back.
	scrThemeUninstall
	scrThemeRestore
)

// BackupOpts are the Backup screen's content choices.
//
// Name is the user's label for the archive. It goes into the filename AFTER
// the timestamp, never before it: five places glob omarchy-backup-*.tar.gz* and
// backup_desc() reads the date from fixed offsets in what follows the prefix, so
// a name inserted ahead of the timestamp would make every listed backup show a
// broken date. The backend sanitises it into a slug.
//
// Persisted, because an option the user has to re-choose after every restart is
// not an option. HasKeep/HasZen are NOT persisted: they describe the machine,
// they are re-detected on every visit, and a stale "true" for a program that has
// since been uninstalled would put a row on screen that cannot work.
type BackupOpts struct {
	VST     string // "list" | "full" | "none"
	Keepass bool   // include KeePassXC passwords (only when installed)
	Zen     bool   // include the Zen browser settings (prefs.js/user.js/containers.json + extensions)
	Encrypt bool   // AES-256 with a passphrase
	Name    string // optional label for the archive, "" = the dated default
	HasKeep bool   // the machine has keepassxc + its config/db
	HasZen  bool   // the machine has a Zen profile
}

// storedBackupOpts is the on-disk shape. Deliberately NOT the BackupOpts
// struct: persisting a struct means adding a field silently starts persisting
// it, and the two detection flags must never be written.
type storedBackupOpts struct {
	VST     string `json:"vst"`
	Keepass bool   `json:"keepass"`
	Zen     bool   `json:"zen"`
	Encrypt bool   `json:"encrypt"`
	Name    string `json:"name"`
}

// loadBackupOpts reads the saved choices. A missing file, unreadable file or
// malformed JSON all mean the same thing — no preference yet — so they return
// the defaults instead of an error: a corrupt preference file must never be
// able to stop the Backup screen from opening.
func loadBackupOpts() BackupOpts {
	def := BackupOpts{VST: "list", Keepass: true, Zen: true}
	out, err := runQuick("backup-opts", "get")
	if err != nil {
		return def
	}
	var st storedBackupOpts
	if err := json.Unmarshal(out, &st); err != nil {
		return def
	}
	switch st.VST {
	case "full", "none", "list":
		def.VST = st.VST
	}
	// Only take a preference that is actually a preference. A stored false for
	// keepass/zen is legitimate (the user turned them off), so they are applied
	// as-is; but an absent field decodes to false too, which would silently
	// switch OFF options the user never touched. The file is only written by
	// saveBackupOpts, which always writes all five, so a decode that produced a
	// zero value anywhere means the file was not written by us.
	if st.VST == "" {
		return BackupOpts{VST: "list", Keepass: true, Zen: true}
	}
	def.Keepass = st.Keepass
	def.Zen = st.Zen
	def.Encrypt = st.Encrypt
	def.Name = st.Name
	return def
}

// saveBackupOpts persists the choices. Best-effort: a backup that cannot record
// its own settings is still a valid backup, so a write failure is not surfaced
// as an error on the run that triggered it.
func saveBackupOpts(o BackupOpts) {
	payload, err := json.Marshal(storedBackupOpts{
		VST:     o.VST,
		Keepass: o.Keepass,
		Zen:     o.Zen,
		Encrypt: o.Encrypt,
		Name:    o.Name,
	})
	if err != nil {
		return
	}
	_, _ = runQuick("backup-opts", "set", string(payload))
}

// saveBackupSelection persists the ticked rows of the Backup content screen the
// moment one changes.
//
// The screen used to rebuild its ticks from the LAST ARCHIVE on every visit, so
// a selection assembled over several passes — or a row deliberately unticked —
// was gone the moment you left the page, and gone for good if you quit the TUI
// instead of running the backup. Saving on the keystroke is what makes the list
// survive both.
//
// Written even when EMPTY: unticking everything is a choice, and a file holding
// an empty list is what tells the backend "nothing ticked" apart from "no file
// yet". Only the keys of rows that are currently in the tree are written, so a
// package that has since been uninstalled prunes itself out.
func saveBackupSelection(items []SetupItemRec, checked map[string]bool) {
	keys := make([]string, 0, len(checked))
	for _, it := range items {
		if checked[setupValue(it.Folder, it.Key)] {
			keys = append(keys, it.Key)
		}
	}
	payload, err := json.Marshal(struct {
		Sel []string `json:"sel"`
	}{Sel: keys})
	if err != nil {
		return
	}
	// Best-effort, like saveBackupOpts: a preference that cannot be written must
	// not turn a keystroke into an error toast.
	_, _ = runQuick("backup-sel", "set", string(payload))
}

// model is the single Bubble Tea model for the whole session: every screen
// is a state in m.nav, never a subprocess.
type model struct {
	w, h int

	nav []screen

	mainPicker  navPicker
	setupPicker navPicker
	// setupCatPicker is the folder tree of the Setup category currently open
	// (the first Setup screen lists the categories as plain options).
	setupCatPicker navPicker
	setupCat       string
	updatePicker   navPicker
	// healthPicker lists the pieces the Health check found missing; the rows
	// are toggled with tab (same multi-select convention as Setup/Update) and
	// only the checked ones are re-applied.
	healthPicker navPicker
	// pickPicker backs the TOP-LEVEL "Extras" screen (plugin toggles).
	pickPicker   navPicker
	backupPicker navPicker
	// backupOptPicker drives the Backup options screen; backupAppsPicker is
	// the apps/tuis/webapps content tree.
	backupOptPicker  navPicker
	backupAppsPicker navPicker

	confirm   tuikit.Confirm
	runner    tuikit.Runner
	toast     tuikit.Toast
	info      tuikit.Info
	passInput tuikit.TextInput
	// backupNameInput is its own field rather than a reuse of passInput: both
	// are on screen at different times but they are not the same widget, and
	// sharing one field is how a masked input ends up holding a plain label (or
	// the reverse) because the two screens forgot to re-create it.
	backupNameInput tuikit.TextInput

	statusRecs []StatusRec
	// Status screen: the same folder tree as Setup/Uninstall (a module's
	// category comes from the backend), but a module row carries a STATUS dot
	// instead of a checkbox, and Enter / `i` only read — nothing is installed,
	// stripped or ticked here.
	statusPicker  navPicker
	statusFolders []string
	statusOpen    map[string]bool
	backupRecs    []BackupRec
	updateRec     UpdateRec

	// Setup tree: folders in display order, their items (flat, folder-tagged),
	// and a value -> item index for the "i" info popup.
	setupFolders []FolderRec
	setupItems   []SetupItemRec
	setupByValue map[string]SetupItemRec
	folderOpen   map[string]bool
	selected     map[string]bool
	// updateSelected is the Update screen's own selection (kept apart from
	// the Setup tree's, so visiting one never clears the other).
	updateSelected map[string]bool
	// reinstallMode turns the Update screen into a re-apply screen: when no
	// update is pending, "Reinstall last update" lists every installed
	// module for ticking instead. reinstallMods are those modules (built
	// from the status records); reinstallPending means a status fetch is in
	// flight to build them.
	reinstallMode    bool
	reinstallPending bool
	reinstallMods    []ItemRec
	// healthChecked is the Health check list's checkbox map (default: every
	// missing piece checked, since they're all there to be re-applied).
	healthChecked map[string]bool
	// healthItems keeps the FULL health records (id + label + detail) so the
	// "i" popup can describe the highlighted row.
	healthItems []HealthRec
	blinkOn     bool

	// aiRemoved caches the backend's "is omarchy's agentic stuff gone?" answer
	// and aiRemovedKnown says whether that answer has arrived yet.
	//
	// Answering it costs ~900ms (the backend shells out to `omarchy plugin
	// list` and `crash-notify`), and the Setup rows used to ask for it while
	// BUILDING them — so every blink tick, every tick of a checkbox and every
	// fold forked a shell that took the best part of a second, which froze the
	// screen solid. It is now fetched once, in the background, next to the rest
	// of the Setup data, and read from here. Until it arrives, aiRemoval is
	// false, which greys the "bring back omarchy's agentic stuff" row — the
	// safe answer, since there is nothing to bring back until a removal has
	// actually happened.
	aiRemoved      bool
	aiRemovedKnown bool

	// deferred holds a command the current update() cannot return directly,
	// because it sits on a branch that already returns a different one. It is
	// flushed in Update, so a caller never has to thread the extra cmd through
	// every early return. It is a pointer slot: update() has a value receiver,
	// so a plain field would be written to a copy and lost.
	deferred *deferredCmd

	// Keybindings manager (the old setup-keybindings.sh, now a TUI screen,
	// reached from the main menu). It is one screen with no flavor: adding and
	// removing both live here. kbSel PERSISTS across navigation so a global
	// uninstall run still removes the ticked combos.
	kbPicker     navPicker // the Keybindings MENU
	kbListPicker navPicker // the "Managed keybindings" list (distinct picker: popping back to the menu must not keep showing the list)
	kbItems      []KbRec
	kbSel        map[string]bool
	// menuEntries drives the "Menu entries" cleaner screen: the marked
	// mosquito menu blocks (mega-caffeine, live-mode, move converter,
	// mosquitomarchy) with a present mark; unchecking + Enter strips the
	// block from omarchy-menu.jsonc (re-check restores).
	// preinstalls drives the preinstall step that PRECEDES every uninstall:
	// the full Omarchy stock list, with the already-removed apps greyed out
	// instead of hidden.
	preinstalls       []PreinstallRec
	preinstallChecked map[string]bool
	preinstallPicker  navPicker
	// uninstallWait holds an uninstall that the preinstalls page is currently
	// in front of: the keys it would remove, and the confirmation text it will
	// show once the preinstalls step is out of the way. Empty = no uninstall
	// pending, which is also what puts the preinstalls page back to its old
	// standalone behaviour for the paths that are not an uninstall.
	uninstallWait     []string
	uninstallMsg      string
	menuEntries       []MenuEntryRec
	menuEntriesLoaded bool
	// quickFixes is the Quick fixes catalog (fetched from the backend) and
	// quickFixChecked the ticks on its own screen. pendingFixIDs is the marked
	// set the confirmation is about, held while the dialog is up so the answer
	// carries the exact list that was shown.
	quickFixes       []ItemRec
	quickFixChecked  map[string]bool
	quickFixPicker   navPicker
	quickFixLoaded   bool
	pendingFixIDs    []string
	menuEntryChecked map[string]bool
	menuEntryOrig    map[string]bool
	// crashNotify is the CACHED state of the crash-notification setting. The
	// label used to be built by shelling out to the backend every time the
	// Extras list was rebuilt, so simply opening the screen — and rebuilding
	// after every flip — spawned a subprocess per row. The value is fetched
	// once and then flipped in place (see PickerItem.Toggle for the ordering
	// rule that makes a flip show up before the write finishes).
	crashNotify       bool
	crashNotifyLoaded bool
	// menuEntriesPicker is the STORED picker for that screen. It used to be
	// rebuilt from scratch inside View() on every frame and its result thrown
	// away, so no key ever reached it: arrows were handled by the backup
	// picker (this switch case fell through into scrBackupRestore) and the
	// screen looked frozen.
	menuEntriesPicker navPicker

	// Setup/Uninstall tree typing filter: printable keys build a live
	// substring filter that flattens the tree (leaf rows only, no category
	// folders); tab still ticks rows and Enter acts on them.
	filterText string
	// filterOpen: the 'f' toggle that shows the rectangular filter zone
	// above the shortcut bar (Setup/Uninstall + their subcategories). The
	// zone echoes every pressed key in real time while filtering.
	filterOpen bool
	// kpxGnomeRm tracks the per-install-plan answer to "remove the
	// gnome-keyring package?": 0 = not asked yet, 1 = yes, 2 = no.
	kpxGnomeRm int
	// dvcSpektra tracks the per-install-plan answer to "install the free
	// spektrFilm OFX too?". 0 = not asked yet. Kept separate from kpxGnomeRm
	// because the two questions belong to different modules, and a plan can
	// contain both.
	dvcSpektra   int
	kbCatPicker  navPicker
	kbItemPicker navPicker
	kbCatItems   []KbCatItem
	kbKeyPicker  navPicker
	kbFree       []string
	kbPending    KbCatItem
	kbInput      tuikit.TextInput
	kbInputStep  int // 0 = label, 1 = command

	// "Theming" (theme.go). folder -> image -> name ->
	// create, each kept until the flow finishes so Esc can step back.
	themeDir           string
	themeImages        []ThemeImageRec
	themeImagesFetched bool
	themeImage         string
	themeInput         tuikit.TextInput
	themeInputStep     int // 0 = folder path, 1 = theme name
	themeApplyName     string
	themeCreated       string
	themePendingName   string // the name carried out of the text screen
	themeLog           string
	themeFolderPicker  navPicker
	themeImagePicker   navPicker
	themeDonePicker    navPicker
	// themeUnlockStyle is the "also build the lock/boot screen" toggle. It rides
	// in front of the name screen so it is decided BEFORE the theme is built,
	// rather than discovered afterwards — the boot screen needs a password, and
	// discovering that after a five-step flow is a bad way to find out.
	themeUnlockStyle     bool
	themeUnlockPicker    navPicker
	themeList            []ThemeRec
	themeChecked         map[string]bool
	themeStock           map[string]bool
	themeUninstallPicker navPicker
	themeRestorePicker   navPicker
	themeRemoveCount     int
	themeApply           bool // apply immediately instead of building only
	kbCustomLabel        string

	// Backup content selection (apps/tuis/webapps), reusing the setup tree
	// display; plus the "what to include" options.
	backupFolders []FolderRec
	backupItems   []SetupItemRec
	backupChecked map[string]bool
	backupOpen    map[string]bool
	backupOpts    BackupOpts
	backupSelFile string

	// pending* hold a confirm's/action's decision.
	pendingAction string // "apply" | "update" | "update-repo" | "backup" | "restore" | "menu-entries"
	pendingArgs   []string
	pendingFile   string
	// pendingPass holds the first encrypted-backup passphrase while the
	// confirmation entry is shown.
	pendingPass string
	pendingMsg  string
	pendingNo   string
	pendingYes  string

	// passphraseSet tracks whether OMARCHY_BACKUP_PASSPHRASE is currently
	// exported for the running child, so RunnerDone can unset it.
	passphraseSet bool

	// lastOutput keeps the last action's streamed output so the "finished
	// with errors" prompt can show the full log.
	lastOutput string

	// workingLabel is the label of the running action, used to name its crash
	// log when the run fails.
	workingLabel string

	// pendingPatchKeys holds the app keys whose patch script should be proposed
	// after a successful apply.
	pendingPatchKeys []string

	// treeMode is which tree the Setup screens are showing: "install" (the
	// normal Setup, with selection + Install selection) or "uninstall" (only
	// the installed entries, Enter uninstalls).
	treeMode string

	fatal error
	quit  bool
}

func initialModel() model {
	m := model{
		nav: []screen{scrMain},
		// A new theme builds the lock/boot screen too: that is what makes it a
		// complete Omarchy theme rather than a wallpaper. The toggle in the flow
		// turns it off for the ones who do not want it.
		themeUnlockStyle: true,
		selected:         map[string]bool{},
		updateSelected:   map[string]bool{},
		healthChecked:    map[string]bool{},
		kbSel:            map[string]bool{},
		folderOpen:       map[string]bool{},
		statusOpen:       map[string]bool{},
		setupByValue:     map[string]SetupItemRec{},
		backupChecked:    map[string]bool{},
		backupOpen:       map[string]bool{},
		backupOpts:       loadBackupOpts(),
		treeMode:         "install",
	}
	m.mainPicker = newNavPicker("", m.mainMenuItems()).
		SetHelpKeys(key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "info")))
	m.setupPicker = newNavPicker("", nil)
	m.setupCatPicker = newNavPicker("", nil)
	m.updatePicker = newNavPicker("", nil)
	m.backupPicker = newNavPicker("", nil)
	m.backupOptPicker = newNavPicker("", nil)
	m.backupAppsPicker = newNavPicker("", nil)
	m.runner = tuikit.NewRunner()
	return m
}

func (m model) Init() tea.Cmd {
	// The update check runs at STARTUP, not only when Setup is opened. A
	// pending repo fast-forward used to be invisible until you went looking
	// for it: the main menu was built once before any check had run, and the
	// Setup tree — the only place the row appeared — is not where people
	// start when they just want the thing current.
	return tea.Batch(tuikit.ThemeWatchCmd(), firstRunCmd(), fetchUpdateCheckCmd())
}

// top, contentSize and their friends take a POINTER receiver. The model holds
// ~360KB of pickers, so a value receiver copied the whole thing on every call
// — and View() calls these several times per frame. That single detail cost
// about a third of the frame budget, which is what made Setup feel laggy
// while the identical list on the Status screen (a different code path) did
// not.
func (m *model) top() screen { return m.nav[len(m.nav)-1] }

func (m *model) push(s screen) { m.nav = append(m.nav, s) }

func (m *model) pop() {
	if len(m.nav) > 1 {
		m.nav = m.nav[:len(m.nav)-1]
		m.toast = m.toast.ClearNonCritical()
	}
}

func (m *model) replace(s screen) { m.nav[len(m.nav)-1] = s }

// mainMenuItems builds the root menu. The Update row carries the same square
// the Setup and Uninstall trees use on a row that has something waiting, so a
// pending update is visible from the main menu instead of only after going
// into Updates. It is rebuilt on every update-check result, which is why it
// takes the model rather than being a package-level list.
func (m model) mainMenuItems() []tuikit.PickerItem {
	upd := tuikit.PickerItem{Display: "Update", Value: "update"}
	if m.updatePending() {
		upd.TrailingBadge = "■"
	}
	return []tuikit.PickerItem{
		{Display: "Status", Value: "status"},
		upd,
		{Display: "Setup", Value: "setup"},
		{Display: "Uninstall", Value: "uninstall"},
		{Display: "Keybindings", Value: "keybindings"},
		{Display: "Theming", Value: "theme"},
		{Display: "Health check", Value: "health", TrailingBadge: conditionalBadge(m.healthPending())},
		{Display: "Backup / Restore", Value: "backup"},
		{Display: "Extras", Value: "settings"},
		{Display: "Close", Value: "close"},
	}
}

// rebuildMainMenu refreshes the root list, keeping the cursor on the same row.
func (m model) rebuildMainMenu() navPicker {
	return newNavPicker("", m.mainMenuItems()).SetSize(m.contentSize()).
		KeepCursor(m.mainPicker.SelectedValue()).
		SetHelpKeys(key.NewBinding(key.WithKeys("i"), key.WithHelp("i", "info")))
}

func (m *model) contentSize() (int, int) {
	return m.contentSizeFor(m.top() == scrMain)
}

// contentSizeFor sizes the central panel. isMain asks for the home budget no
// matter which screen is on top: the main picker is rebuilt by background
// refreshes that can land while a sub-screen is up, and sizing it at the
// sub-screen's (taller) budget left it one frame out of step when the user
// popped back — the boxed exit row appeared then vanished on the next rebuild.
//
// The home title height comes from a LADDER rung chosen to fit the window
// (tuikit.LadderLayout), not from measuring a header that was rendered first.
// That distinction was the bug: the 121-column wordmark was rendered
// unconditionally and lipgloss wrapped it, so the height measured here was the
// height of the DAMAGE, and every downstream subtraction inherited it.
func (m *model) contentSizeFor(isMain bool) (int, int) {
	if !isMain {
		return contentPolicy.Size(m.w, m.h, subScreenTitleRows)
	}
	l := m.homeLayout()
	return contentPolicy.Size(m.w, m.h, l.TitleRows)
}

// contentWidth is the single width number every part of this TUI measures
// against, so the ladder and the panel can never be sized against different
// widths.
func (m *model) contentWidth() int {
	return contentPolicy.ContentWidth(m.w)
}

// subScreenTitleRows is the title height for every screen except the home
// menu: they all use a single accent line, so it is one row everywhere. The
// constant exists so the number lives in one place if a sub-screen ever grows
// a real title block.
const subScreenTitleRows = 1

// mainContentSize is contentSize() as it would be on the home screen no matter
// which screen is on top. See contentSizeFor for why.
func (m *model) mainContentSize() (int, int) {
	return contentPolicy.Size(m.w, m.h, m.homeLayout().TitleRows)
}

// homeLayout picks the title rung that fits and returns the matching budget.
func (m *model) homeLayout() tuikit.Layout {
	w := m.titleWidth()
	return tuikit.LayoutForLadder(w, m.h, titleLadder(w))
}

func (m *model) contentSizeW() int {
	return m.contentWidth()
}

// titleLadder is the mosquitomarchy wordmark, measured against the content
// width so the widest rung is never wider than the panel.
func titleLadder(width int) tuikit.TitleLadder {
	return tuikit.MosquitOmarchyTitleLadder()
}

// titleWidth is the width the wordmark ladder is measured against, and it is
// NOT contentWidth().
//
// contentWidth() caps the PANEL at ManagerContent.MaxW (92) so a list stays
// readable instead of stretching to a 4K terminal. Feeding that same number to
// the ladder meant the 121-column wordmark could never fit, so a wide terminal
// got the 3-row compact box instead of the boxed wordmark — the cap meant for
// the list was silently demoting the title, and no amount of extra width fixed
// it.
//
// The title is a single centred line with nothing to read beside it, so it is
// bounded by the window itself, not by the panel's comfortable width. The
// ladder still refuses any rung wider than this, so nothing ever wraps.
func (m *model) titleWidth() int {
	w := m.w - 2 // one column of breathing room each side, so the frame is not flush
	if w < 1 {
		return 1
	}
	return w
}

// setupValue is the stable picker/selection key for a Setup item.
func setupValue(folder, key string) string { return tuikit.TreeItemPrefix + folder + ":" + key }

// menuEntriesFolder is the pseudo-folder id for the "Menu entries" section of
// Setup. It is not a module category: its children are the marked blocks
// mosquito adds to the Omarchy menu, and they are toggled, not installed.
const menuEntriesFolder = "menu-entries"

// splitSetupValue is the inverse of setupValue: it takes a leaf row's value
// ("item:<folder>:<key>") back to the folder and the key, so Enter on a single
// module can install that one without going through the tick list.
func splitSetupValue(v string) (folder, key string) {
	rest := strings.TrimPrefix(v, tuikit.TreeItemPrefix)
	if i := strings.Index(rest, ":"); i >= 0 {
		return rest[:i], rest[i+1:]
	}
	return "", rest
}

// folderValue is the picker key for a Setup folder row.
func folderValue(folder string) string { return "cat:" + folder }

// setupItemsOf returns the children of one folder, in backend order.
func (m model) setupItemsOf(folder string) []SetupItemRec {
	out := make([]SetupItemRec, 0, 8)
	for _, it := range m.setupItems {
		if it.Folder == folder {
			out = append(out, it)
		}
	}
	return out
}

// toggle marks/unmarks a Setup item by picker value.
func (m *model) toggle(value string) {
	if m.selected[value] {
		delete(m.selected, value)
	} else {
		m.selected[value] = true
	}
}

// toggleFolder marks every child of a folder, or unmarks them all when they
// were all marked already (one keystroke always flips to an extreme, exactly
// like the audio-plugin-manager's folder select-all).
func (m *model) toggleFolder(folder string) {
	toggleTreeFolder(m.setupItems, m.selected, folder)
}

// toggleTreeFolder is the shared folder select-all/none used by the Setup and
// backup-content trees.
func toggleTreeFolder(items []SetupItemRec, checked map[string]bool, folder string) {
	n := 0
	anyUnchecked := false
	for _, it := range items {
		if it.Folder != folder {
			continue
		}
		n++
		if !checked[setupValue(folder, it.Key)] {
			anyUnchecked = true
			break
		}
	}
	if n == 0 {
		return
	}
	for _, it := range items {
		if it.Folder != folder {
			continue
		}
		if anyUnchecked {
			checked[setupValue(folder, it.Key)] = true
		} else {
			delete(checked, setupValue(folder, it.Key))
		}
	}
}

// updatePending reports whether anything is waiting to be updated: a repo
// fast-forward, or at least one installed module whose files changed. One
// predicate for the main-menu square, the Setup row and the Update screen, so
// the three can never disagree about whether an update exists.
func (m model) updatePending() bool {
	return m.updateRec.RepoUpdate || len(m.updateRec.Modules) > 0
}

func conditionalBadge(show bool) string {
	if show {
		return "■"
	}
	return ""
}

// healthPending reports whether the health check found any issues.
func (m model) healthPending() bool {
	return len(m.healthItems) > 0
}

// selectedCount counts the checked Setup items.
func (m model) selectedCount() int {
	n := 0
	for _, v := range m.selected {
		if v {
			n++
		}
	}
	return n
}

// toggleUpdate marks/unmarks an Update module by key.
func (m *model) toggleUpdate(key string) {
	if m.updateSelected[key] {
		delete(m.updateSelected, key)
	} else {
		m.updateSelected[key] = true
	}
}

// toggleHealth marks/unmarks one piece of the Health check list.
func (m *model) toggleHealth(key string) {
	if m.healthChecked[key] {
		delete(m.healthChecked, key)
	} else {
		m.healthChecked[key] = true
	}
}

// filteredCheckedKeys lists the ticked Setup/Uninstall leaf rows. While the
// typing filter is active only the visible (matching) rows count, so acting
// from the filtered view never touches unlisted ticked rows.
func (m model) filteredCheckedKeys() []string {
	if m.filterText == "" {
		return nil
	}
	ft := strings.ToLower(m.filterText)
	var out []string
	// The Preinstalls row is not a module and it is not named after one, so the
	// text filter would silently drop it from the ticked set. It is a request to
	// open the stock-app list, not a module to install, so it rides along with
	// the selection whatever the user typed: filtering to "reaper" and applying
	// must not quietly forget that the preinstalls list was asked for.
	pre := setupValue(preinstallsFolder, preinstallsKey)
	if m.selected[pre] {
		out = append(out, preinstallsKey)
	}
	for _, f := range m.setupFolders {
		if f.Folder == preinstallsFolder {
			continue // already handled above, and it is never a module
		}
		for _, it := range m.setupItemsOf(f.Folder) {
			if !strings.Contains(strings.ToLower(it.Label), ft) {
				continue
			}
			v := setupValue(f.Folder, it.Key)
			if m.selected[v] {
				out = append(out, strings.TrimPrefix(v, "item:"))
			}
		}
	}
	return out
}

// healthKeys returns the checked Health check pieces in list order.
func (m model) healthKeys() []string {
	out := make([]string, 0, len(m.healthChecked))
	for _, it := range m.healthItems {
		if m.healthChecked[it.ID] {
			out = append(out, it.ID)
		}
	}
	return out
}

func (m model) updateSelectedCount() int { return len(m.updateSelected) }

// preselectUpdate marks EVERY available changed module as selected so the
// Update screen's module list starts fully ticked (the user can un-tick
// anything they want to skip manually).
func (m *model) preselectUpdate() {
	for _, it := range m.updateRec.Modules {
		m.updateSelected[it.Key] = true
	}
}

// updateKeys returns the checked Update module keys as a stable slice (in
// the order the modules are listed). In reinstall mode the rows come from
// the installed-modules list instead of the changed-modules list.
func (m model) updateKeys() []string {
	mods := m.updateRec.Modules
	if m.reinstallMode {
		mods = m.reinstallMods
	}
	out := make([]string, 0, len(m.updateSelected))
	for _, it := range mods {
		if m.updateSelected[it.Key] {
			out = append(out, it.Key)
		}
	}
	return out
}

// applyPlan groups the checked Setup items by folder, in folder order, as
// TAB-separated "<folder>\t<key>…" groups for the backend's `apply`.
func (m model) applyPlan() []string {
	var groups []string
	for _, f := range m.setupFolders {
		var keys []string
		for _, it := range m.setupItemsOf(f.Folder) {
			if m.selected[setupValue(f.Folder, it.Key)] {
				keys = append(keys, it.Key)
			}
		}
		if len(keys) > 0 {
			group := f.Folder
			for _, k := range keys {
				group += "\t" + k
			}
			groups = append(groups, group)
		}
	}
	return groups
}

// selectedKeysOfCat returns the checked item keys of one category only.
func (m model) selectedKeysOfCat(cat string) []string {
	var keys []string
	for _, it := range m.setupItemsOf(cat) {
		if m.selected[setupValue(cat, it.Key)] {
			keys = append(keys, it.Key)
		}
	}
	return keys
}

// allSelectedKeys returns every checked item key across all folders (used by
// the Uninstall tree's "Uninstall selection", the mirror of "Install
// selection").
func (m model) allSelectedKeys() []string {
	var keys []string
	for _, it := range m.setupItems {
		if m.selected[setupValue(it.Folder, it.Key)] {
			keys = append(keys, it.Key)
		}
	}
	return keys
}

// highlightedKey returns the item key under the cursor in the Setup folder
// tree (used by Uninstall: Enter on an unchecked row uninstalls just that row).
func (m model) highlightedKey() []string {
	v := m.setupCatPicker.SelectedValue()
	if !strings.HasPrefix(v, "item:") {
		return nil
	}
	rest := strings.TrimPrefix(v, "item:")
	if i := strings.Index(rest, ":"); i >= 0 {
		return []string{rest[i+1:]}
	}
	return nil
}

// applyPlanCat is the apply plan for ONE category only (the Setup submenu's
// Enter installs just what is checked there).
func (m model) applyPlanCat(cat string) []string {
	var keys []string
	for _, it := range m.setupItemsOf(cat) {
		if m.selected[setupValue(cat, it.Key)] {
			keys = append(keys, it.Key)
		}
	}
	if len(keys) == 0 {
		return nil
	}
	group := cat
	for _, k := range keys {
		group += "\t" + k
	}
	return []string{group}
}
