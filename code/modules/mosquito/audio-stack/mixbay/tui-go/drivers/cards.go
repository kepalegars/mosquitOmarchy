// Native card specs are DATA, shipped as JSON profiles inside the binary.
//
// The community repo (mosquito mixbay profiles) is the source of truth; these
// embedded snapshots make Mixbay work offline and let a native card be updated
// with a normal release. Nothing in this package hardcodes a device's I/O,
// gain range or capabilities any more.
package drivers

import (
	"mosquitomarchy.local/mosquitomixbay-tui/profiles"
)

// specFromProfile converts a card into the runtime Spec. The two types have
// the same JSON shape on purpose; this is the only place they meet.
func specFromProfile(c profiles.Card) Spec {
	s := c.Spec
	return Spec{
		ID: s.ID, Display: s.Display, Vendor: s.Vendor,
		USBVID: s.USBVID, USBPID: s.USBPID,
		NumInputs: s.NumInputs, NumOutPairs: s.NumOutPairs,
		GainMin: s.GainMin, GainMax: s.GainMax, GainOffset: s.GainOffset,
		VolMin: s.VolMin, VolMax: s.VolMax,
		MixerInputs: s.MixerInputs, MixerOutputs: s.MixerOutputs,
		HasMonitor: s.HasMonitor, Backend: Backend(s.Backend),
		NeedsKmod: s.NeedsKmod, Description: s.Description,
		Version: s.Version, Beta: s.Beta,
		CardMatch: append([]string(nil), s.CardMatch...),
		BusNames:  append([]string(nil), s.BusNames...),
		Caps: Caps{
			Volume: s.Caps.Volume, Gain: s.Caps.Gain, Mute: s.Caps.Mute,
			Phantom: s.Caps.Phantom, Monitor: s.Caps.Monitor, Mixer: s.Caps.Mixer,
		},
	}
}

// mustNativeSpec reads one built-in card. A corrupt embedded file is a build
// bug: failing at startup is better than serving a half-configured driver.
func mustNativeSpec(id string) Spec {
	c, ok := profiles.NativeCard(id)
	if !ok {
		panic("embedded native profile missing: " + id)
	}
	if errs := profiles.Errors(profiles.Validate(c)); len(errs) > 0 {
		panic("embedded native profile invalid: " + id + ": " + errs[0].String())
	}
	return specFromProfile(c)
}

// nativeSpecs is the stable order shown by the interface picker.
func nativeSpecs() []Spec {
	return []Spec{EVO8Spec, EVO4Spec, FirefaceSpec, UGM192Spec, SSL12Spec}
}

// localSpecs reads downloaded/local cards from the profile store.
func localSpecs() []Spec {
	cards := profiles.LocalCards()
	out := make([]Spec, 0, len(cards))
	for _, c := range cards {
		out = append(out, specFromProfile(c))
	}
	return out
}

// specByID finds a runtime spec for a known card. Unknown ids are not guessed.
func specByID(id string) (Spec, bool) {
	for _, s := range nativeSpecs() {
		if s.ID == id {
			return s, true
		}
	}
	for _, s := range localSpecs() {
		if s.ID == id {
			return s, true
		}
	}
	return Spec{}, false
}

// driverFor picks the transport from the card's declared backend, so a
// downloaded profile works without touching this switch again.
func driverFor(spec Spec) Driver {
	switch spec.Backend {
	case BackendEvoRaw:
		return newEvo(spec)
	case BackendDouze:
		return newDouze(spec)
	default:
		return newALSA(spec)
	}
}
