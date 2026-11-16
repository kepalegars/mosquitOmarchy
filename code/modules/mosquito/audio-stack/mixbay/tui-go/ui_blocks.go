// UI presets compose the shared mixbay blocks. The EVO renderer and the
// UGM192 panel already draw from the same primitives (evoCanvas, boxTop/Side,
// hslider, drawMeter*, drawStatusBarWith, drawHelpFooter); this table names
// the composition so a community card can request the same blocks by data.
//
// Block → renderer
//
//	tabBar         evoRender.tabBar / evoRender.ugmTabBar
//	controlsGrid   EVO Controls sections (inputs/outputs, mono/stereo)
//	controlsSingle evoRender.ugmControlsBody (one software control + meter)
//	mixerGrid      EVO MIXER bus matrix
//	levelsColumns  evoRender.ugmLevelsBody / EVO Levels columns
//	statusBar      drawStatusBarWith
//	help           drawHelpFooter
package main

// presetBlockSets is the default composition of each preset. A card may
// declare ui.blocks explicitly; that list is validated against
// profiles.Blocks and is documentation for contributors. Presets remain the
// thing the renderer routes on, because a composition must have a matching
// input model (the UGM panel has one control, the EVO grid has many).
//
// shortcut: presets route to whole renderers, ui.blocks is declarative until
// the EVO renderer is split — see TODO-PROFILES.md §1.
var presetBlockSets = map[string][]string{
	"evo8":   {"tabBar", "controlsGrid", "mixerGrid", "levelsColumns", "statusBar", "help"},
	"evo4":   {"tabBar", "controlsGrid", "mixerGrid", "levelsColumns", "statusBar", "help"},
	"ugm192": {"tabBar", "controlsSingle", "levelsColumns", "statusBar", "help"}, "single-pair": {"controlsSingle", "statusBar", "help"},
	"move": {"levelsColumns", "statusBar", "help"},
	"auto": {"controlsGrid", "statusBar", "help"},
}

// presetBlocks returns the default blocks for a preset, falling back to the
// generic composition for an unknown one.
func presetBlocks(preset string) []string {
	if b, ok := presetBlockSets[preset]; ok {
		return b
	}
	return presetBlockSets["auto"]
}
