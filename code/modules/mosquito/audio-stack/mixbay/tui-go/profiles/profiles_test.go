package profiles

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testHome(t *testing.T) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("MIXBAY_CONFIG_DIR", filepath.Join(home, ".config", "mosquitomixbay"))
	t.Setenv("XDG_CACHE_HOME", filepath.Join(home, ".cache"))
	t.Setenv("XDG_DATA_HOME", filepath.Join(home, ".local", "share"))
}

func TestNativeCardsAreValid(t *testing.T) {
	cards := NativeCards()
	if len(cards) != 5 {
		t.Fatalf("native cards = %d, want 5", len(cards))
	}
	for _, c := range cards {
		if errs := Errors(Validate(c)); len(errs) > 0 {
			t.Errorf("%s: %s", c.Spec.ID, errs[0])
		}
		if c.Preset() == "" {
			t.Errorf("%s: no UI preset", c.Spec.ID)
		}
	}
	if !IsNative("evo8") || IsNative("quantum-es4") {
		t.Fatal("native detection wrong")
	}
}

func TestParseRejectsTypoAndBadPreset(t *testing.T) {
	_, issues, err := Parse([]byte(`{"schema_version":1,"spec":{"spce":{}},"ui":{"preset":"nope"},"spce":{}}`))
	if err != nil {
		t.Fatal(err)
	}
	fields := map[string]bool{}
	for _, i := range issues {
		fields[i.Field] = true
	}
	if !fields["spce"] || !fields["spec.spce"] || !fields["ui.preset"] || !fields["spec.id"] {
		t.Fatalf("missing issues: %+v", issues)
	}
}

func TestEffectiveMergesSparseOverride(t *testing.T) {
	testHome(t)
	card, err := InstallLocalCard("quantum-es4", "PreSonus Quantum ES 4", "Quantum ES")
	if err != nil {
		t.Fatal(err)
	}
	if card.Preset() != "single-pair" {
		t.Fatalf("default preset = %q", card.Preset())
	}
	if err := SaveUserLayout("quantum-es4", []byte(`{"preset":"auto","sections":{"gain":{"min_db":-5}}}`)); err != nil {
		t.Fatal(err)
	}
	got, meta, err := Effective("quantum-es4")
	if err != nil {
		t.Fatal(err)
	}
	if got.Preset() != "auto" {
		t.Fatalf("override preset = %q", got.Preset())
	}
	if meta.Source != "local" {
		t.Fatalf("meta source = %q", meta.Source)
	}
	// Upstream stays intact: a later repo update does not absorb the tweak.
	raw, err := os.ReadFile(upstreamFile("quantum-es4"))
	if err != nil {
		t.Fatal(err)
	}
	var onDisk Card
	if err := json.Unmarshal(raw, &onDisk); err != nil {
		t.Fatal(err)
	}
	if onDisk.Preset() != "single-pair" {
		t.Fatalf("upstream was modified: %q", onDisk.Preset())
	}
	if _, ok := got.UI["sections"]; !ok {
		t.Fatal("user sections dropped by merge")
	}
}

func TestEmbeddedCardCanBeUninstalledAndStaysRemoved(t *testing.T) {
	testHome(t)
	if _, _, err := Effective("evo8"); err != nil {
		t.Fatal("embedded card was not seeded")
	}
	if err := Remove("evo8"); err != nil {
		t.Fatalf("removing an embedded card failed: %v", err)
	}
	if _, _, err := Effective("evo8"); err == nil {
		t.Fatal("uninstalled card is still effective")
	}
	// Reading the store seeds missing embedded cards, but never a removed one.
	for _, c := range LocalCards() {
		if c.Spec.ID == "evo8" {
			t.Fatal("seeding restored a removed card")
		}
	}
}

func TestBackupUserUIDropsTheOverride(t *testing.T) {
	testHome(t)
	if _, err := InstallLocalCard("quantum-es4", "PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	override := []byte(`{"preset":"auto"}`)
	if err := SaveUserLayout("quantum-es4", override); err != nil {
		t.Fatal(err)
	}
	if !HasUserUI("quantum-es4") {
		t.Fatal("local layout not detected")
	}
	dest, err := BackupUserUI("quantum-es4")
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(dest)
	if err != nil || string(got) != string(override) {
		t.Fatalf("backup = %q, %v", got, err)
	}
	if HasUserUI("quantum-es4") {
		t.Fatal("local layout still active after backup")
	}
	card, _, err := Effective("quantum-es4")
	if err != nil {
		t.Fatal(err)
	}
	if card.Preset() != "single-pair" {
		t.Fatalf("repo layout did not take over: %q", card.Preset())
	}
}

func TestImportAndUpdate(t *testing.T) {
	testHome(t)
	card := Card{
		SchemaVersion: 1,
		Spec: Spec{
			ID: "quantum-es4", Display: "PreSonus Quantum ES 4", Vendor: "PreSonus",
			NumInputs: 4, NumOutPairs: 2, GainMin: 0, GainMax: 60,
			VolMin: -96, VolMax: 0, MixerInputs: 4, MixerOutputs: 2,
			Backend: "alsa", Version: "v1.0.0",
			Caps:  Caps{Volume: true, Mute: true},
			Setup: SetupOscmix,
		},
		UI: map[string]any{"preset": "single-pair"},
	}
	body := Encode(card)
	sum := sha256.Sum256(body)
	digest := hex.EncodeToString(sum[:])
	index := Index{SchemaVersion: 1, Revision: "r1", Cards: []IndexCard{{
		ID: "quantum-es4", Display: card.Spec.Display, Vendor: card.Spec.Vendor,
		Version: card.Spec.Version, Path: "cards/quantum-es4/card.json", SHA256: digest,
	}}}
	mux := http.NewServeMux()
	mux.HandleFunc("/index.json", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(index)
	})
	mux.HandleFunc("/cards/quantum-es4/card.json", func(w http.ResponseWriter, r *http.Request) {
		w.Write(body)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	t.Setenv("MIXBAY_PROFILES_URL", srv.URL)

	res, err := Import(context.Background(), []string{"quantum-es4"})
	if err != nil {
		t.Fatal(err)
	}
	if len(res) != 1 || res[0].Err != nil || res[0].Updated {
		t.Fatalf("import = %+v", res)
	}
	if res[0].Setup != SetupOscmix {
		t.Fatalf("import setup = %q, want %q", res[0].Setup, SetupOscmix)
	}
	got, meta, err := Effective("quantum-es4")
	if err != nil {
		t.Fatal(err)
	}
	if got.Spec.Version != "v1.0.0" || meta.Revision != "r1" || meta.Source != "repo" {
		t.Fatalf("effective = %+v meta=%+v", got.Spec, meta)
	}
	// A second import updates in place and keeps user overrides.
	if err := SaveUserLayout("quantum-es4", []byte(`{"preset":"auto"}`)); err != nil {
		t.Fatal(err)
	}
	res, err = Import(context.Background(), []string{"quantum-es4"})
	if err != nil || !res[0].Updated {
		t.Fatalf("update = %+v err=%v", res, err)
	}
	if eff, _, _ := Effective("quantum-es4"); eff.Preset() != "auto" {
		t.Fatal("update destroyed the user override")
	}
	// Corrupt digest is refused.
	index.Cards[0].SHA256 = "0000000000000000000000000000000000000000000000000000000000000000"
	if _, err := Import(context.Background(), []string{"quantum-es4"}); err != nil {
		t.Fatal(err)
	}
	if res, _ := Import(context.Background(), []string{"quantum-es4"}); res[0].Err == nil {
		t.Fatal("sha mismatch accepted")
	}
}

func TestCardSetupAndFoundationSchema(t *testing.T) {
	mk := func(setup string, f *Foundation) []byte {
		return Encode(Card{SchemaVersion: 1, Spec: Spec{
			ID: "usb-card", Display: "USB Card", Vendor: "ACME",
			NumInputs: 2, NumOutPairs: 1, GainMin: 0, GainMax: 60,
			VolMin: -96, VolMax: 0, Backend: "alsa", Version: "v1.0.0",
			Setup: setup, Foundation: f,
		}, UI: map[string]any{"preset": "single-pair"}})
	}
	assertIssue := func(name string, data []byte, field string) {
		t.Helper()
		_, issues, err := Parse(data)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		for _, i := range Errors(issues) {
			if i.Field == field {
				return
			}
		}
		t.Fatalf("%s: no %q issue in %+v", name, field, issues)
	}
	if _, issues, err := Parse(mk(SetupOscmix, &Foundation{Sink: "HiFi__Line5__sink", Source: "Fireface"})); err != nil || len(Errors(issues)) > 0 {
		t.Fatalf("valid setup/foundation refused: %v %+v", err, issues)
	}
	assertIssue("unknown setup", mk("shell", nil), "spec.setup")
	assertIssue("unsafe foundation name", mk("", &Foundation{Sink: "a; reboot"}), "spec.foundation.sink")

	ff, ok := NativeCard("fireface-ucx2")
	if !ok || ff.Spec.Setup != SetupOscmix || ff.Spec.Foundation == nil || ff.Spec.Foundation.Source == "" {
		t.Fatalf("native UCX II setup/foundation = %+v", ff.Spec)
	}
}

func TestCheckUpdatesInstallAndUpdate(t *testing.T) {
	testHome(t)
	card := Card{SchemaVersion: 1, Spec: Spec{
		ID: "quantum-es4", Display: "PreSonus Quantum ES 4", Vendor: "PreSonus",
		NumInputs: 4, NumOutPairs: 2, Backend: "alsa", Version: "v1.0.0",
		Caps: Caps{Volume: true},
	}, UI: map[string]any{"preset": "auto"}}
	if _, err := InstallLocalCard("quantum-es4", card.Spec.Display, "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	body := Encode(card)
	sum := sha256.Sum256(body)
	index := Index{SchemaVersion: 1, Cards: []IndexCard{{
		ID: "quantum-es4", Display: card.Spec.Display, Version: "v1.1.0",
		Path: "cards/quantum-es4/card.json", SHA256: hex.EncodeToString(sum[:]),
	}}}
	mux := http.NewServeMux()
	mux.HandleFunc("/index.json", func(w http.ResponseWriter, r *http.Request) { json.NewEncoder(w).Encode(index) })
	srv := httptest.NewServer(mux)
	defer srv.Close()
	t.Setenv("MIXBAY_PROFILES_URL", srv.URL)

	offers, err := CheckUpdates(context.Background(), []ConnEntry{{ID: "beta-quantum-es-4", Name: card.Spec.Display}})
	if err != nil {
		t.Fatal(err)
	}
	if len(offers) != 1 || offers[0].Kind != "update" || offers[0].ID != "quantum-es4" {
		t.Fatalf("offers = %+v", offers)
	}
	offers, _ = CheckUpdates(context.Background(), []ConnEntry{{ID: "beta-unknown", Name: "Brand New Card"}})
	if len(offers) != 0 {
		t.Fatalf("unknown matched: %+v", offers)
	}
}

func TestExportRedactsAndWritesIndex(t *testing.T) {
	testHome(t)
	card, err := InstallLocalCard("beta-lab", "Lab Card", "Lab")
	if err != nil {
		t.Fatal(err)
	}
	card.Captures = []Capture{{File: "captures/gain.jsonl", SHA256: "0000000000000000000000000000000000000000000000000000000000000000"}}
	if err := writeFileAtomic(upstreamFile("beta-lab"), Encode(card)); err != nil {
		t.Fatal(err)
	}
	capDir := filepath.Join(cardDir("beta-lab"), "captures")
	if err := os.MkdirAll(capDir, 0o755); err != nil {
		t.Fatal(err)
	}
	capture := `{"bus":1,"dev":7,"serial":"ABC","action":"gain:input1","value":12,"nested":{"path":"/dev/bus/001"}}` + "\n"
	if err := os.WriteFile(filepath.Join(capDir, "gain.jsonl"), []byte(capture), 0o644); err != nil {
		t.Fatal(err)
	}
	dest, err := Export([]string{"beta-lab"}, filepath.Join(t.TempDir(), "out"))
	if err != nil {
		t.Fatal(err)
	}
	exported, err := os.ReadFile(filepath.Join(dest, "cards", "beta-lab", "captures", "gain.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	var line map[string]any
	if err := json.Unmarshal(exported, &line); err != nil {
		t.Fatalf("capture is not one JSON line: %v", err)
	}
	for _, k := range []string{"bus", "dev", "serial"} {
		if _, ok := line[k]; ok {
			t.Fatalf("capture leaked %q: %s", k, exported)
		}
	}
	if _, ok := line["nested"].(map[string]any)["path"]; ok {
		t.Fatal("nested path leaked")
	}
	var ix Index
	data, err := os.ReadFile(filepath.Join(dest, "index.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &ix); err != nil {
		t.Fatal(err)
	}
	if len(ix.Cards) != 1 || ix.Cards[0].ID != "beta-lab" || len(ix.Cards[0].SHA256) != 64 {
		t.Fatalf("index = %+v", ix)
	}
	for _, name := range []string{"README.md", "PR.md"} {
		if _, err := os.Stat(filepath.Join(dest, name)); err != nil {
			t.Fatalf("%s missing", name)
		}
	}
}

func TestDuplicatesPreferRepoOverBeta(t *testing.T) {
	testHome(t)
	if _, err := InstallLocalCard("beta-quantum-es-4", "PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	if _, err := InstallLocalCard("quantum-es4", "PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	dups := Duplicates()
	if len(dups) != 1 {
		t.Fatalf("duplicates = %+v, want 1", dups)
	}
	if dups[0].KeepID != "quantum-es4" || dups[0].RemoveID != "beta-quantum-es-4" {
		t.Fatalf("kept %s / removed %s, want quantum-es4 / beta-quantum-es-4", dups[0].KeepID, dups[0].RemoveID)
	}
}

func TestDuplicatesNeverProposeRemovingNative(t *testing.T) {
	testHome(t)
	if _, err := InstallLocalCard("beta-evo-8", "Audient EVO 8", "EVO 8"); err != nil {
		t.Fatal(err)
	}
	dups := Duplicates()
	if len(dups) != 1 || dups[0].KeepID != "evo8" || dups[0].RemoveID != "beta-evo-8" {
		t.Fatalf("duplicates = %+v", dups)
	}
}

func TestUpstreamURLGuardAndDeploy(t *testing.T) {
	good := "https://raw.githubusercontent.com/kepalegars/mosquito-mixbay-profiles/main/cards/rme/fireface-802/card.json"
	if !ValidUpstreamURL(good) {
		t.Fatal("official raw card URL refused")
	}
	for _, bad := range []string{
		"http://raw.githubusercontent.com/kepalegars/mosquito-mixbay-profiles/main/x.json",
		"https://raw.githubusercontent.com/someone/mosquito-mixbay-profiles/main/x.json",
		"https://raw.githubusercontent.com/kepalegars/mosquito-mixbay-profiles/main/../x.json",
		"https://raw.githubusercontent.com/kepalegars/mosquito-mixbay-profiles/main/x.sh",
		"https://example.com/card.json",
	} {
		if ValidUpstreamURL(bad) {
			t.Errorf("unsafe upstream URL accepted: %s", bad)
		}
	}

	testHome(t)
	if _, err := InstallLocalCard("quantum-es4", "PreSonus Quantum ES 4", "Quantum ES"); err != nil {
		t.Fatal(err)
	}
	card, _, err := Effective("quantum-es4")
	if err != nil {
		t.Fatal(err)
	}
	card.Spec.Version = "v9"
	card.Spec.Upstream = good
	if err := DeployCard(card); err != nil {
		t.Fatal(err)
	}
	got, _, err := Effective("quantum-es4")
	if err != nil || got.Spec.Version != "v9" || got.Spec.Upstream != good {
		t.Fatalf("deployed upstream card = %+v, %v", got.Spec, err)
	}
}

func TestEnsureIntegrationDownloadsAndVerifies(t *testing.T) {
	testHome(t)
	script := []byte("#!/usr/bin/env bash\necho ok\n")
	sum := sha256.Sum256(script)
	digest := hex.EncodeToString(sum[:])
	ix := Index{SchemaVersion: SchemaVersion, Integrations: map[string]Integration{
		"oscmix": {Version: "1", Path: "integrations/oscmix", Files: map[string]string{"setup-oscmix.sh": digest}},
	}}
	mux := http.NewServeMux()
	mux.HandleFunc("/index.json", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(ix)
	})
	requests := 0
	mux.HandleFunc("/integrations/oscmix/setup-oscmix.sh", func(w http.ResponseWriter, r *http.Request) {
		requests++
		_, _ = w.Write(script)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	t.Setenv("MIXBAY_PROFILES_URL", srv.URL)

	dir, err := EnsureIntegration(context.Background(), "oscmix")
	if err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(filepath.Join(dir, "setup-oscmix.sh")); err != nil || string(got) != string(script) {
		t.Fatalf("downloaded script = %q, %v", got, err)
	}
	info, err := os.Stat(filepath.Join(dir, "setup-oscmix.sh"))
	if err != nil || info.Mode()&0o111 == 0 {
		t.Fatalf("script is not executable: %v", err)
	}
	if _, err := EnsureIntegration(context.Background(), "oscmix"); err != nil {
		t.Fatal(err)
	}
	if requests != 1 {
		t.Fatalf("ready integration downloaded again (%d requests)", requests)
	}

	ix.Integrations["oscmix"] = Integration{Version: "2", Path: "integrations/oscmix",
		Files: map[string]string{"setup-oscmix.sh": strings.Repeat("0", 64)}}
	if _, err := EnsureIntegration(context.Background(), "oscmix"); err == nil {
		t.Fatal("a bad digest was accepted")
	}
}

func TestVersionLess(t *testing.T) {
	if !versionLess("v1.2.0", "v1.10.0") || versionLess("v2.0.0", "v1.9.9") {
		t.Fatal("version comparison wrong")
	}
}

func TestLegacyBetaMigration(t *testing.T) {
	testHome(t)
	dir := ConfigDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	legacy := `[{"id":"beta-lab","name":"Lab Card","match":"Lab"}]`
	if err := os.WriteFile(filepath.Join(dir, "beta-devices.json"), []byte(legacy), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := MigrateLegacyBeta(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(legacyBetaPath() + ".migrated"); err != nil {
		t.Fatal("legacy file was not archived")
	}
	if _, _, err := Effective("beta-lab"); err != nil {
		t.Fatal(err)
	}
}
