# TODO — profile system (v1 → v2)

Deferred on purpose. Each item is a real gap, not a nice-to-have; keep the
profile format stable while closing them.

Shipped since the first pass: two-tab library with search, bulk install,
profile-owned integrations (`oscmix`, `evo-raw`) pinned by sha256, direct RME
`spec.upstream` updates, credits/info, one-shot repo check, uninstall of every
card including the seeded snapshots, duplicate detection by USB identity
(VID/PID, then card_match, then display name).

## 1. Split the EVO renderer into composable blocks

Today `evo_tui.go` (single 73K renderer) draws the tabs, controls grid, mixer
grid, levels columns, status bar and help. The UGM panel already reuses the
primitives, and cards declare `ui.blocks`, but a card cannot yet compose them
freely: `ui.preset` routes to a whole renderer.

Goal:
- extract `tabBar`, `controlsGrid`, `controlsSingle`, `mixerGrid`,
  `levelsColumns`, `statusBar`, `help` into standalone draw functions;
- keep a per-preset input model (EVO grid ↔ many controls, UGM ↔ one control);
- render an unknown card from its `ui.blocks` list when the composition is
  valid, not only from a hardcoded preset;
- keep `git diff` behaviour identical for the shipped cards (golden-frame
  tests before/after).

## 2. Generic USB/HID interpreter + `mixbay-reverse propose`

ALSA level 1 already works for imported cards (`card_match`, volumes/mutes).
Still missing:
- declarative hardware bindings in the card (ALSA control names, HID report
  ids/ranges, HTTP endpoints) instead of transport-specific Go code;
- USB/HID interpreter driven by those bindings;
- `mixbay-reverse propose`: turn a distilled `candidates.jsonl` into a draft
  `card.json` (roles + bindings + confidence), ready for a PR.

## 3. Declarative meter bindings

Done: `hardware.meters` (`node`, `capture`, `playback`, `floor_db`) is parsed,
validated, carried into `drivers.Spec.Meters`, and drives node discovery, the
channel count, the Levels bars and the scale. A declared binding is
authoritative: a missing node means no meters, never another card's fallback.
Absent keeps the historical EVO/UGM discovery.

Remaining: a card whose composition has no `levelsColumns` block (`auto`,
`single-pair`) still has nowhere to draw the meters; that is §1's renderer
work.

## 5. Captures in the client (not needed yet)

Import downloads only `card.json`; captures remain in the repo. If a Mixbay
screen ever displays capture-derived data, add opt-in per-capture download with
the same sha256 + validation path.

## 6. Integration supply chain

Integrations are downloaded from the profiles repo and verified per file. A
future hardening step: sign `index.json` (or fetch integrations from a release
asset pinned by a signed tag) so a compromised raw host cannot swap both the
card and its installer.
