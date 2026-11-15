package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Every setup ends on the same prompt, success or failure, and its "See log"
// button must open the transcript instead of running the confirm action.
func TestSetupResultOffersTheLogEitherWay(t *testing.T) {
	for _, runErr := range []error{nil, errors.New("exit status 1")} {
		m := model{nav: []screen{scrDevices}}
		next, _ := m.setupResult(setupDoneMsg{what: "oscmix setup", log: "/tmp/a.log", err: runErr})
		if next.top() != scrConfirm {
			t.Fatalf("setup must end on the result prompt, top=%v", next.top())
		}
		if next.confirmLog != "/tmp/a.log" {
			t.Errorf("result prompt lost the transcript path")
		}
		if next.confirmAct != nil {
			t.Errorf("a finished setup must not run another action on Yes")
		}
	}
}

func TestReadSetupLogStripsANSI(t *testing.T) {
	path := filepath.Join(t.TempDir(), "log")
	body := "\x1b[1;34m==>\x1b[0m build\r\n \x1b[1;32m✓\x1b[0m done\r\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	got := readSetupLog(path)
	if got != "==> build\n ✓ done" {
		t.Errorf("readSetupLog = %q", got)
	}
	if got := readSetupLog(filepath.Join(t.TempDir(), "missing")); !strings.HasPrefix(got, "No log captured") {
		t.Errorf("missing log should say so, got %q", got)
	}
}
