package main

import "testing"

func bitwigTestModel() model {
	m := initialModel()
	m.w, m.h = 100, 30
	m.bitwigInstalled = true
	return m
}

// The routes menu always offers both routes; the two route menus grey their
// uninstall row exactly when that route is not installed.
func TestBitwigRouteMenusDisableMissingUninstalls(t *testing.T) {
	m := bitwigTestModel()

	routes := m.wireBitwigRoutesMenu()
	values := map[string]bool{}
	for _, it := range routes {
		values[it.Value] = true
	}
	if !values["schwung_route"] || !values["native_route"] {
		t.Fatalf("routes menu = %+v, want both routes", routes)
	}

	disabled := map[string]bool{}
	for _, it := range m.wireBitwigMenu() {
		disabled[it.Value] = it.Disabled
	}
	if !disabled["uninstall"] {
		t.Fatal("Schwung uninstall must be disabled while its controller is absent")
	}
	m.bitwigControllers = true
	for _, it := range m.wireBitwigMenu() {
		if it.Value == "uninstall" && it.Disabled {
			t.Fatal("Schwung uninstall must be enabled once installed")
		}
	}

	if !m.bitwigNative {
		for _, it := range m.wireBitwigNativeMenu() {
			if it.Value == "uninstall" && !it.Disabled {
				t.Fatal("native uninstall must be disabled while its script is absent")
			}
		}
	}
	m.bitwigNative = true
	for _, it := range m.wireBitwigNativeMenu() {
		if it.Value == "uninstall" && it.Disabled {
			t.Fatal("native uninstall must be enabled once installed")
		}
	}
}

// Each install gate asks its question before any work starts.
func TestBitwigInstallGates(t *testing.T) {
	cases := []struct {
		name    string
		mutate  func(*model)
		route   string
		gate    string
		install bool
	}{
		{
			name:   "Move absent asks to connect",
			mutate: func(m *model) { m.status.Connected = false },
			route:  "native", gate: "connect",
		},
		{
			name:   "Schwung absent offers to install it",
			mutate: func(m *model) { m.status.Connected = true; m.schwungInstalled = false },
			route:  "schwung", gate: "schwung",
		},
		{
			name: "other route installed warns about the override",
			mutate: func(m *model) {
				m.status.Connected = true
				m.schwungInstalled = true
				m.bitwigControllers = true
			},
			route: "native", gate: "override",
		},
		{
			name: "clear path installs",
			mutate: func(m *model) {
				m.status.Connected = true
				m.schwungInstalled = true
			},
			route: "native", install: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := bitwigTestModel()
			tc.mutate(&m)
			nm, _ := m.requestBitwigInstall(tc.route)
			got := nm.(model)
			if tc.install {
				if got.top() != scrBitwigInstalling {
					t.Fatalf("top = %v, want the install screen", got.top())
				}
				return
			}
			if got.top() != scrBitwigGateConfirm || got.bitwigGate != tc.gate {
				t.Fatalf("top = %v gate = %q, want %q", got.top(), got.bitwigGate, tc.gate)
			}
		})
	}
}
