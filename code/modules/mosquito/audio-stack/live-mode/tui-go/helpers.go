package main

import (
	"os"
	"strconv"
	"strings"

	"github.com/charmbracelet/bubbles/key"
)

func parseKV(content string, out map[string]string) {
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.Index(line, "=")
		if eq <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		val = strings.Trim(val, "\"'")
		out[key] = val
	}
}

func readKV(path string) map[string]string {
	out := map[string]string{}
	data, err := os.ReadFile(path)
	if err != nil {
		return out
	}
	parseKV(string(data), out)
	return out
}

func itoa(n int) string { return strconv.Itoa(n) }

func boolVal(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

// mainHelpKeys names the main screen's two non-obvious keys: Enter both opens
// a row and toggles a boolean, and Left/Right change the value under the
// cursor. The old hint said "thermal limit", which was only ever true for one
// row.
func mainHelpKeys() []key.Binding {
	return []key.Binding{
		key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "toggle / select")),
		key.NewBinding(key.WithKeys("left", "right"), key.WithHelp("←/→", "change value")),
	}
}
