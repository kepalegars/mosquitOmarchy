// UI presets compose the shared mixbay blocks. The EVO renderer and the
// UGM192 panel already draw from the same primitives (evoCanvas, boxTop/Side,
// hslider, drawMeter*, drawStatusBarWith, drawHelpFooter); this table names
// the composition so a community card can request the same blocks by data.
//
// Block → renderer
//
//	tabBar         evoRender.drawTabBar / ugmTabBar / singleTabBar
//	controlsGrid   EVO Controls sections (inputs/outputs, mono/stereo)
//	controlsSingle evoRender.ugmControlsBody (one software control + meter)
//	mixerGrid      EVO MIXER bus matrix
//	levelsColumns  drawLevelsBody / ugmLevelsBody
//	statusBar      drawStatusBarWith
//	help           drawHelpFooter
package main

import "mosquitomarchy.local/mosquitomixbay-tui/drivers"

// presetBlockSets is the default composition of each preset, used when a card
// does not declare ui.blocks. A declared list is authoritative for which tabs
// and pages are drawn; the preset (or the device) still chooses the input
// model, because a composition must match the controls it can drive.
var presetBlockSets = map[string][]string{
	"evo8":        {"tabBar", "controlsGrid", "mixerGrid", "levelsColumns", "statusBar", "help"},
	"evo4":        {"tabBar", "controlsGrid", "mixerGrid", "levelsColumns", "statusBar", "help"},
	"ugm192":      {"tabBar", "controlsSingle", "levelsColumns", "statusBar", "help"},
	"single-pair": {"tabBar", "controlsSingle", "statusBar", "help"},
	"move":        {"tabBar", "levelsColumns", "statusBar", "help"},
	"auto":        {"controlsGrid", "statusBar", "help"},
}

// presetBlocks returns the default blocks for a preset, falling back to the
// generic composition for an unknown one.
func presetBlocks(preset string) []string {
	if b, ok := presetBlockSets[preset]; ok {
		return b
	}
	return presetBlockSets["auto"]
}

// hasBlock reports whether the active card asked for a block. An undeclared
// composition keeps the preset's historical default.
func (m model) hasBlock(b string) bool {
	blocks := m.blocks
	if len(blocks) == 0 {
		blocks = presetBlocks(m.preset)
	}
	for _, v := range blocks {
		if v == b {
			return true
		}
	}
	return false
}

// controlModel names the input model behind the composition. A preset (or the
// native device id) keeps its historical model; a card that declares blocks
// on another preset picks one from them, but only when the card can actually
// drive it. That is what routes a single-pair card to the one-control panel
// and an auto card with a controls grid to the EVO frame, while an
// action-only card (no controls, no mixer) stays on the picker with its
// openers.
func (m model) controlModel() string {
	switch m.preset {
	case "evo8", "evo4":
		return modelGrid
	case "ugm192":
		return modelSingle
	case "move":
		return modelLevels
	}
	switch m.deviceID {
	case drivers.DevEVO8, drivers.DevEVO4:
		return modelGrid
	case drivers.DevUGM192:
		return modelSingle
	case drivers.DevMove:
		return modelLevels
	}
	if m.status.Spec.Backend == drivers.BackendEvoRaw {
		return modelGrid
	}
	if len(m.blocks) == 0 {
		return ""
	}
	caps := m.status.Spec.Caps
	switch {
	case m.hasBlock("controlsGrid"):
		if hasControls(m.status) {
			return modelGrid
		}
	case m.hasBlock("mixerGrid") && caps.Mixer:
		return modelGrid
	case m.hasBlock("controlsSingle"):
		if caps.Volume || caps.Mute {
			return modelSingle
		}
	case m.hasBlock("levelsColumns"):
		return modelLevels
	}
	return ""
}

const (
	modelGrid   = "grid"
	modelSingle = "single"
	modelLevels = "levels"
)

// uiPage is one viewable tab: the block that draws its body plus the window
// id the renderers already use for it.
type uiPage struct {
	block string
	label string
	win   int
}

// pages returns the tabs the active composition may show, in tab-bar order.
// Empty groups are skipped by the renderers, so a card with only outputs or
// only meters still gets its page.
func (m model) pages() []uiPage {
	model := m.controlModel()
	var out []uiPage
	for _, p := range []uiPage{
		{"controlsGrid", " Controls ", evoWinControls},
		{"controlsSingle", " Controls ", evoWinControls},
		{"mixerGrid", " Mixer ", evoWinMixer},
		{"levelsColumns", " Levels ", evoWinLevels},
	} {
		if !m.hasBlock(p.block) {
			continue
		}
		switch p.block {
		case "controlsGrid", "mixerGrid":
			if model != modelGrid {
				continue
			}
		case "controlsSingle":
			if model == modelGrid {
				continue
			}
		}
		if p.block == "mixerGrid" && !m.status.Spec.Caps.Mixer {
			continue
		}
		out = append(out, p)
	}
	return out
}

// currentPage returns the page to draw, falling back to the first one when
// the stored window belongs to a composition the card no longer has.
func (m model) currentPage() (uiPage, bool) {
	pages := m.pages()
	if len(pages) == 0 {
		return uiPage{}, false
	}
	for _, p := range pages {
		if p.win == m.evo.window {
			return p, true
		}
	}
	if m.top() == scrMixer {
		for _, p := range pages {
			if p.block == "mixerGrid" {
				return p, true
			}
		}
	}
	return pages[0], true
}

// cyclePage moves to the next tab in the composition and keeps the nav stack
// in step: only the mixer is a pushed screen.
func (m *model) cyclePage() {
	pages := m.pages()
	if len(pages) < 2 {
		return
	}
	cur, found := 0, false
	for i, p := range pages {
		if p.win == m.evo.window {
			cur, found = i, true
			break
		}
	}
	next := pages[0]
	if found {
		next = pages[(cur+1)%len(pages)]
	}
	wasMixer := m.top() == scrMixer
	switch {
	case next.block == "mixerGrid" && !wasMixer:
		m.push(scrMixer)
	case next.win == evoWinControls && wasMixer:
		// Levels is drawn over the mixer stack entry, exactly as the evotui
		// port did; only landing back on Controls pops it.
		m.pop()
	}
	m.evo.window = next.win
	m.numBuf = ""
}
