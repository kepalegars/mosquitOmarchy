package main

import (
	"testing"
)

func TestBandLabel(t *testing.T) {
	if bandLabel("a") != "5 GHz" {
		t.Errorf("band a = %q, want 5 GHz", bandLabel("a"))
	}
	if bandLabel("bg") != "2.4 GHz" {
		t.Errorf("band bg = %q, want 2.4 GHz", bandLabel("bg"))
	}
	if bandLabel("") != "2.4 GHz" {
		t.Errorf("empty band = %q, want the 2.4 GHz fallback", bandLabel(""))
	}
}

func TestMaskPassword(t *testing.T) {
	if got := maskPassword("secret123"); got == "secret123" {
		t.Error("password shown in clear")
	}
	if maskPassword("") == "" {
		t.Error("empty password renders as nothing — say so explicitly")
	}
}

func TestHostnameDefault(t *testing.T) {
	if hostnameDefault() == "" {
		t.Error("empty hostname default — the SSID field would start blank")
	}
}

func TestSaveValidatesBeforeTouchingTheBackend(t *testing.T) {
	if msg := saveCmd("", "12345678", "a")().(saveResultMsg); msg.err == nil {
		t.Error("empty SSID accepted")
	}
	if msg := saveCmd("Test-AP", "short", "a")().(saveResultMsg); msg.err == nil {
		t.Error("short password accepted")
	}
}

func TestArtLinesShareOneWidth(t *testing.T) {
	w := -1
	for _, l := range hotspotArt {
		n := len([]rune(l))
		if w < 0 {
			w = n
		} else if n != w {
			t.Fatalf("art line %q width %d, want %d", l, n, w)
		}
	}
}

func TestCleanLineTakesFirstLine(t *testing.T) {
	if got := cleanLine("Omarchy-Hotspot\n\ntestashot"); got != "Omarchy-Hotspot" {
		t.Fatalf("cleanLine = %q", got)
	}
}

func TestQuitSavesOnlyWhenDirty(t *testing.T) {
	m := initialModel()
	m.origSsid, m.origPassword, m.origBand = m.ssid, m.password, m.band
	if m.dirty() {
		t.Fatal("fresh form reads dirty")
	}
	m.ssid += "-x"
	if !m.dirty() {
		t.Fatal("edited form reads clean")
	}
}
