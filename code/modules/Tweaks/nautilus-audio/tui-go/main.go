// mosquitomarchy-audio-convert — the terminal picker behind Nautilus'
// "Convert Audio (PACPL)" script.
//
// A Nautilus script has no terminal of its own, so the wrapper opens this
// binary in foot (fallback xterm). It asks for the output format with the
// shared tui-kit picker — themed like every mosquitOmarchy TUI — and asks
// about overwriting ONLY when at least one output file already exists: asking
// unconditionally made a plain conversion look dangerous. It then runs pacpl
// in the same terminal, so the encoder's own output stays visible.
//
// Output naming mirrors pacpl itself: the source's final extension is replaced
// by the lowercase target format, in the source's directory.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	tuikit "mosquitomarchy.local/tui-kit"
)

var formats = []string{"MP3", "FLAC", "OGG", "OPUS", "WAV", "M4A", "AIFF", "WV"}

type stage int

const (
	stageFormat stage = iota
	stageOverwrite
)

type model struct {
	files     []string
	format    string
	overwrite bool
	stage     stage
	picker    tuikit.Picker
	confirm   tuikit.Confirm
	w, h      int
}

func newModel(files []string) model {
	items := make([]tuikit.PickerItem, len(formats))
	for i, f := range formats {
		items[i] = tuikit.PickerItem{Display: f, Value: strings.ToLower(f)}
	}
	m := model{
		files:  files,
		picker: tuikit.NewPicker(fmt.Sprintf("Output format — %d file(s)", len(files)), items),
	}
	m.picker = m.picker.SetSize(60, 15)
	return m
}

func (m model) Init() tea.Cmd { return tuikit.ThemeWatchCmd() }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		w, h := tuikit.ManagerContent.Size(m.w, m.h, 1)
		m.picker = m.picker.SetSize(w, h)
		return m, nil
	case tuikit.ThemeTickMsg:
		tuikit.ApplyTheme()
		return m, tuikit.ThemeWatchCmd()
	case tuikit.PickerResultMsg:
		if m.stage != stageFormat {
			return m, nil
		}
		if msg.Canceled {
			return m, tea.Quit
		}
		m.format = msg.Value
		existing := existingOutputs(m.files, m.format)
		if len(existing) == 0 {
			return m, tea.Quit
		}
		// Only when there is something to overwrite.
		m.confirm = tuikit.NewConfirm(
			fmt.Sprintf("%d output file(s) already exist. Overwrite?", len(existing)),
			"No", "Yes").SetList("Existing files", existing, 8)
		m.stage = stageOverwrite
		return m, nil
	case tuikit.ConfirmResultMsg:
		if m.stage != stageOverwrite {
			return m, nil
		}
		if msg.Canceled {
			return m, tea.Quit
		}
		m.overwrite = msg.Yes
		return m, tea.Quit
	}
	var cmd tea.Cmd
	if m.stage == stageFormat {
		m.picker, cmd = m.picker.Update(msg)
	} else if m.stage == stageOverwrite {
		m.confirm, cmd = m.confirm.Update(msg)
	}
	return m, cmd
}

func (m model) View() string {
	if m.w == 0 || m.h == 0 {
		return ""
	}
	w, h := tuikit.ManagerContent.Size(m.w, m.h, 1)
	var title, body, bar string
	switch m.stage {
	case stageFormat:
		title = centered(w, fmt.Sprintf("Convert Audio (PACPL) — %d file(s)", len(m.files)))
		m.picker = m.picker.SetSize(w, h)
		body = m.picker.View()
		bar = tuikit.BottomBar("", m.picker.ShortcutsHint(), w)
	case stageOverwrite:
		title = centered(w, "Overwrite existing output?")
		body = m.confirm.View()
		bar = tuikit.BottomBar("", m.confirm.ShortcutsHint(), w)
	}
	return tuikit.FrameScreen(m.w, m.h, title, body, bar)
}

// centered paints a one-line accent title at the content width, the way the
// other managers title their sub-screens.
func centered(w int, text string) string {
	return lipgloss.NewStyle().Width(w).Align(lipgloss.Center).
		Render(tuikit.StyleAccent.Bold(true).Render(text))
}

// outputPath is what pacpl will write for this source and format.
func outputPath(file, format string) string {
	base := filepath.Base(file)
	base = strings.TrimSuffix(base, filepath.Ext(base))
	return filepath.Join(filepath.Dir(file), base+"."+format)
}

func existingOutputs(files []string, format string) []string {
	var out []string
	for _, f := range files {
		if p := outputPath(f, format); fileExists(p) {
			out = append(out, p)
		}
	}
	return out
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func main() {
	files := os.Args[1:]
	if len(files) == 0 {
		return
	}
	p := tea.NewProgram(newModel(files), tea.WithAltScreen())
	final, err := p.Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, "mosquitomarchy-audio-convert:", err)
		os.Exit(1)
	}
	m := final.(model)
	if m.format == "" {
		return
	}
	os.Exit(convert(m.files, m.format, m.overwrite))
}

// convert runs pacpl per file, in the terminal, so its output is visible.
func convert(files []string, format string, overwrite bool) int {
	failed := 0
	for _, f := range files {
		args := []string{"--to", format, "--outdir", filepath.Dir(f)}
		if overwrite {
			args = append(args, "--overwrite")
		}
		args = append(args, f)
		fmt.Printf("\n==> %s → %s\n", filepath.Base(f), strings.ToUpper(format))
		cmd := exec.Command("pacpl", args...)
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		if err := cmd.Run(); err != nil {
			failed++
		}
	}
	if failed > 0 {
		fmt.Printf("\n%d file(s) failed.\n", failed)
		return 1
	}
	fmt.Printf("\nDone: %d file(s) processed.\n", len(files))
	return 0
}
