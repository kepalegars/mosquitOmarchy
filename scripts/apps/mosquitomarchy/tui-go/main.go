// Command mosquitomarchy-tui is the terminal interface for the
// mosquitOmarchy setup launcher (see ../../mosquitomarchy-setup.sh for what
// this does) — a real Bubble Tea program on the same kit the other mosquito
// managers use, replacing the previous bash+gum launcher. The TUI is the
// ONLY interface. One persistent tea.Program for the whole session: every
// screen is a state in this program's own model, not a separate
// subprocess, so there is nothing to leave half-drawn — ctrl+c and esc
// are ordinary key cases, never a special-cased signal handler.
//
// Business logic (modules, categories, status, backup/restore, uninstall,
// repo updates) is NOT reimplemented here — see mosquitomarchy-actions,
// which sources the exact same mosquitomarchy-setup.sh the launcher used and
// exposes it as plain, scriptable subcommands this program calls once every
// decision (which category, which items, confirm/cancel) has already been
// made here.
//
// Not meant to be launched directly under normal use — the stable
// mosquitomarchy dispatcher routes every no-argument launch straight here.
// Runs standalone fine too (no-args via the dispatcher and a plain run are
// equivalent).
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"

	tea "github.com/charmbracelet/bubbletea"
	tuikit "mosquitomarchy.local/tui-kit"
)

func main() {
	// Headless mode: `mosquitomarchy-tui --status` prints the status JSON
	// lines and exits WITHOUT any terminal UI. This is what boot-time hooks
	// (the update-check watchdog) call, so the plugin never opens a Foot
	// window on the desktop just to print a small JSON blob.
	if len(os.Args) > 1 {
		for _, a := range os.Args[1:] {
			if a == "--status" || a == "status" {
				out, err := runQuick("status")
				if err != nil {
					fmt.Fprintln(os.Stderr, "mosquitomarchy-tui:", err)
					os.Exit(1)
				}
				fmt.Print(string(out))
				return
			}
			if a == "--help" || a == "-h" {
				fmt.Println("mosquitomarchy-tui: the manager TUI. Headless: --status (print the module status JSON lines).")
				return
			}
		}
	}
	m := initialModel()
	for _, a := range os.Args[1:] {
		// Open straight on the Update page (used by the update-available
		// notification's click action). The startup update check (see
		// model.Init) fills the page when it lands.
		if a == "--update" || a == "update" {
			m.updateSelected = map[string]bool{}
			m.push(scrUpdate)
			m.updatePicker = newNavPicker("", []tuikit.PickerItem{{Display: "checking…", Value: "", Disabled: true}})
			break
		}
	}
	p := tea.NewProgram(m, tea.WithAltScreen())
	final, err := p.Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, "mosquitomarchy-tui:", err)
		os.Exit(1)
	}
	if fm, ok := final.(model); ok && fm.restart {
		restartThroughDispatcher()
	}
}

// restartThroughDispatcher relaunches the manager after the update-reboot
// confirm's Restart button. The target is the `mosquitomarchy` dispatcher
// sitting next to this binary — NOT this binary itself: the dispatcher is
// what applies a pending rebuild before opening the TUI, so re-execing the
// TUI would reopen the stale build the restart is meant to leave behind.
// The original arguments are kept (e.g. --update reopens the Update page).
func restartThroughDispatcher() {
	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "mosquitomarchy-tui: restart: cannot locate executable:", err)
		os.Exit(1)
	}
	disp := filepath.Join(filepath.Dir(exe), "mosquitomarchy")
	args := append([]string{disp}, os.Args[1:]...)
	if st, err := os.Stat(disp); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
		if err := syscall.Exec(disp, args, os.Environ()); err != nil {
			fmt.Fprintln(os.Stderr, "mosquitomarchy-tui: restart: exec dispatcher:", err)
		}
	}
	// No dispatcher beside the binary (dev runs, tests): fall back to the
	// binary itself. The rebuild-pending flag survives for the next
	// dispatcher launch, so nothing is lost, just deferred.
	if err := syscall.Exec(exe, os.Args, os.Environ()); err != nil {
		fmt.Fprintln(os.Stderr, "mosquitomarchy-tui: restart: exec:", err)
		os.Exit(1)
	}
}
