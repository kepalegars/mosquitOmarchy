package main

import "testing"

// TestUninstallKeyKeepsCatalogLines: uninstall keys survive normalization in
// backend-routable shape. Regression test: catalog lines carry URLs, and the
// old strip-at-first-colon turned
// "WEB WhatsApp|https://web.whatsapp.com/|whatsapp" into
// "//web.whatsapp.com/|whatsapp" — "Unknown module" for every webapp (and
// the same fate for any APP/TUI/PLUG line with a colon in it).
func TestUninstallKeyKeepsCatalogLines(t *testing.T) {
	cases := []struct{ in, want string }{
		{"reaper", "reaper"},
		{"apps:reaper", "reaper"},
		{"item:apps:reaper", "reaper"},
		{"WEB WhatsApp|https://web.whatsapp.com/|whatsapp", "WEB WhatsApp|https://web.whatsapp.com/|whatsapp"},
		{"item:webapps:WEB WhatsApp|https://web.whatsapp.com/|whatsapp", "WEB WhatsApp|https://web.whatsapp.com/|whatsapp"},
		{"webapps:WEB Schwung Manager|http://move.local:7700|schwung-manager", "WEB Schwung Manager|http://move.local:7700|schwung-manager"},
		{"item:tuis:TUI calcure|calcure — terminal calendar", "TUI calcure|calcure — terminal calendar"},
		{"item:apps:APP GIMP|gimp", "APP GIMP|gimp"},
		{"mosquitomarchy", "mosquitomarchy"},
		{"plugins:mosquitomarchy", "mosquitomarchy"},
	}
	for _, c := range cases {
		if got := uninstallKey(c.in); got != c.want {
			t.Errorf("uninstallKey(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
