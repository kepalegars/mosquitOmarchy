# Project Journal — mosquitOmarchy

## ⚠️ Maintenance contract — read this before doing anything else

This file is a **living resume-point**, not a changelog nobody reads. Its only purpose is
letting **any AI assistant** (or human) pick up this project cold — in a brand new session,
possibly a different model or tool — and continue exactly where the last one stopped,
without re-deriving context that already exists here.

Rules for whoever (human or AI) touches this project from now on:

1. **Read this file first**, before README.md or any code, whenever resuming work on this
   repo after a gap. It tells you what's done, what's in flight, and what's next.
2. **Update it after every meaningful step** — not just at the end of a session. A "step" is
   anything a future reader would need to know to avoid redoing or re-breaking it: a fix, a
   design decision, a discovered constraint, a test result, a mistake and its recovery.
3. **Keep the *Log* dynamic**: the newest entry is always the most detailed one (full
   context: what, why, how it was verified, what's still open). Every time you add a new
   entry, compress the *previous* newest entry down to a short paragraph (what changed, one
   line on why, current status) — don't let old entries keep accumulating full detail
   forever, but don't delete the trail either. Older entries stay as one-paragraph summaries
   indefinitely; they're history, not instructions.
4. **This file is itself a prompt.** Treat the *Roadmap* section as the standing instruction
   set for "what to do next" absent other direction from the user — it's not just a status
   report, it's meant to be actionable as-is by an AI that has read nothing else.
5. **Don't duplicate reference docs.** This file links to `README.md` (root),
   `scripts/README.md`, and each module's own `scripts/<module>/README.md` for how things
   work. Update *those* when behavior changes; update *this* file for status, decisions, and
   history. If you find this journal and a README disagreeing, the README wins for
   "how it works today" — but note the discrepancy in the Log so it gets reconciled.
6. **Language**: the project (code, comments, commit messages, docs, this file) is in
   **English**. Conversation with the project's owner happens in whatever language they use
   (currently French) — that doesn't change what goes in the repo.
7. **This file IS the compaction target.** Whatever tool you are (Claude Code, opencode, or
   anything else), when your own context window fills up and you're about to compact or
   summarize — or when you're picking this repo back up in a fresh session — **this file is
   the summary**. Don't re-derive it from scratch, don't re-read the whole git history, don't
   re-read every module's code to rebuild a mental model: read *Current state at a glance* +
   the top *Log* entry + *Roadmap*, and that's the complete, accurate, up-to-date context.
   That only stays true if rule 2 is actually followed (update as you go, not "at the end" —
   there may not be a controlled "end" before compaction hits). Keeping this file current
   is not busywork on the side of the real task; for any tool that compacts or restarts,
   **it is the fastest path back to a correct, coherent state**, which is the whole point.
8. **Anti-drift protocol — stop before you loop.** A "drift" is: re-attempting the same fix
   more than twice without it sticking, re-reading the same file over and over looking for
   something you already looked at, editing a file back and forth between two forms, or
   losing track of which of several related changes across several files you've actually
   made vs. still need to make. The instant you notice one of these:
   - **Stop.** Don't retry a fourth way hoping it works.
   - **Write down, right here in the Log (even mid-task, as a short "blocked" note), exactly
     what you were trying to do and what's not working** — this is cheaper than looping, and
     it's exactly the kind of "discovered constraint" rule 2 already asks you to record.
   - **Verify before claiming something is done**: `bash -n` / build / a real non-destructive
     run, not "this should work now". A claim in this file that isn't true is worse than no
     claim, because the next reader (tool or human) will trust it.
   - When several files need the same kind of change (a path, a rename, a convention), do a
     repo-wide grep for every occurrence **before** starting, fix them all in one pass, then
     grep again to confirm zero remain — don't fix one, move on, and discover the others
     later by trial and error.
   - If genuinely stuck after that, say so plainly to the user instead of continuing to spin.

## Where to look for what

| Question | Answer |
|---|---|
| What does the whole repo do, module by module? | [`README.md`](README.md) — canonical reference, module table, orchestrator usage |
| What's under `scripts/`, folder by folder? | [`scripts/README.md`](scripts/README.md) |
| How does module X work in detail (flags, files, caveats)? | `scripts/<module>/README.md` (linked from the root README's Modules table) |
| What's the current status / what's next? | **This file** — Roadmap + Log below |

## Current state at a glance

Most modules (see the root README's [Modules](README.md#modules) tables) are stable and not
under active work. The ones currently receiving attention:

- **`ableton-move-converter`** — module id unchanged, but its folder now lives at
  `scripts/apps/ableton-move-converter/` (moved there this round from a former top-level
  `scripts/ableton-move-converter/` — see the thirtieth-round Log entry). **A real bug fixed
  the thirty-second round**: the TUI's Bitwig-conversion route used to silently no-op past
  the Ableton launch (two primary decisions were still gated by the actions script's
  always-declining `ui_confirm` stub) — now split into Go-owned Confirm screens
  (`open_ableton_route_phase1`/`finish_bitwig_open`/`close_configured_ableton_and_wait` in
  `lib-move-manager-core.sh`); native was unaffected. Move Manager also gained the same
  superfile-vs-default file-picker Settings toggle VST Manager already had. Deployed binary and
  Omarchy menu entry are **"mosquito Move Manager"**, webapp stays **"Move Manager"**. "Refresh
  connection status" is the first main-menu option (no live-push mechanism exists anymore —
  abandoned two rounds ago; status is checked once per redraw only). `wait_ableton_close()`'s
  hang bug is fixed (exit keyed on `is_ableton_running()` alone, not the `ableton-live`
  wrapper's own PID). Ableton auto-close no longer uses `wtype` at all — found (by reading
  Omarchy's own shipped Hyprland Lua config) that `wtype`'s synthetic keystrokes have a
  documented Hyprland quirk causing them to merge incorrectly with real modifier state, which
  is almost certainly why every previous auto-close attempt silently failed; now uses
  Omarchy's own `hl.dsp.send_key_state` dispatcher, sent directly to Ableton's window by PID
  (`window = "pid:N"`, validated live), sidestepping the whole focus/Wine-process-tree
  correlation problem entirely. `.als` detection switched from `lsof` (fragile, dependent on
  correctly guessing which Wine PID holds the file) to kernel-level `inotifywait -e
  close_write` watching the save folders directly — no process/PID dependency at all. The
  Move Manager actively prompts ("`<name>` finished downloading — close and continue?") the
  moment a download completes, instead of only passively waiting for the window to close.
  Auto-close now uses title-stability detection (waits for Ableton's window title to hold
  steady ~15s before sending Super+W) instead of a fixed delay, which was firing too early
  once the previous round's pipe-redirect fix let real timing through. This round added
  **pre-flight conflict detection**: before launching a new conversion, checks whether the
  *configured* Ableton install and/or Bitwig are already open — if so, informs which and
  waits for closure (passive) before the Bitwig route proceeds; separately, if Ableton
  specifically is already open right at the launch moment, offers to close it (active,
  `ui_confirm` + auto-close + wait) before relaunching fresh. A different, unconfigured
  Ableton edition is deliberately left alone. Bitwig's post-handoff save-wait is now capped
  at 5 minutes (was the full multi-hour Ableton-session bound) — pure background
  bookkeeping, shouldn't keep the script alive for hours. **Root-caused (very likely)** why
  Bitwig sometimes opens an empty project: its own `.desktop` entry, unlike every other app
  on the system, has no file-open argument placeholder at all — a fallback notification with
  the exact path now covers that case. **Found 4 stale zombie processes** (pre-rename
  binary, 19+ hours old, one nested 3 levels deep holding a badly stale prompt) — flagged to
  the user rather than unilaterally killed; still not cleaned up (the newer single-instance
  mechanism below doesn't retroactively catch them — different path string). Thirteenth
  round added **single-instance enforcement** (`enforce_single_instance()` — a fresh launch
  kills any other running copy of *this* script, Ableton/Bitwig untouched) and a **30-minute
  idle-timeout auto-exit** for the main menu, both tested live; the single-instance matcher's
  first version had a real, demonstrated self-inflicted-kill bug (substring matching on
  `pgrep -f` output killed an unrelated decoy process and took the whole test session down
  with it) — fixed by requiring `$SELF` as an exact `/proc/<pid>/cmdline` argv field,
  re-tested clean (real target killed, decoy spared, own process untouched). Also added a
  20s minimum display time for the Ableton-opening notification (`notify()`'s new
  `--timeout SECONDS`), and researched — confirmed infeasible, not implemented — two ideas:
  launching the `.als` file *with* Bitwig (system MIME routes `.als` to Nautilus, not
  Bitwig) and an Ableton-side scripted auto-save/auto-close handshake (the Live Object
  Model's `Application` class has no save/quit capability at all, confirmed against the
  official LOM reference and AbletonOSC). Fourteenth round dropped the adaptive
  title-stability close-detection entirely for a **fixed schedule** measured directly off
  the user's own timing (~20s Ableton startup): repeated Super+W attempts from 20-25s after
  launch, then a single "still waiting on you" notice at 30s if still open — verified with a
  time-compressed test harness, not yet against a real launch. Reworded the Ableton-opening
  and pre-Bitwig notifications to the user's exact requested text (shorter, states the save
  path, drops "Project ready — confirm..." for a plain "Opening Bitwig — import..." line;
  the actual confirm-then-open behavior itself is unchanged). Settings gained "Clear the als
  working folder" (confirmation-gated, `ALS_DIR` only). Confirmed, via `strings` on Bitwig's
  own launcher binary, that it has **zero** CLI file-open support at any level (no
  undocumented flag either) — so it can never be added to Nautilus's "Open With" list in a
  way that actually works. Found and fixed the real cause of "a ton of stale Ableton entries
  in Open With": `setup-ableton.sh` used to deliberately keep `wine-extension-*`/
  `wine-protocol-*.desktop` file associations (assumed hidden via `NoDisplay=true`, but
  GNOME Files' Open-With chooser shows them anyway) — several were found pointing at the
  old, no-longer-used default `~/.wine` prefix from before this module's dedicated
  `~/.wine-ableton`; the policy is reversed, they're removed every run now (per-edition
  entries already cover the same MimeTypes). Applied the equivalent cleanup live on this
  machine (10 stale entries gone). Fixed the per-folder `README.md` (still said the
  three-renames-ago `move-session` name; the in-script template was already correct but
  never re-runs once the file exists — overwritten directly). The twelfth round's 4 zombie
  processes are gone (exited on their own by this round — nothing left to clean up).
  Fifteenth round: widened the auto-close window to 23-30s and added a best-effort
  save-dialog detector (`ableton_save_dialog_open()`, `hyprctl`+`jq` title-matching) that
  pauses close attempts while a save prompt is up, waits for it to go, then a short grace
  period before warning — verified with three time-compressed scenarios. Shortened the
  Ableton-opening notification to one line; dropped the Bitwig fallback notification
  entirely (redundant with the one already sent moments earlier, now reworded to reference
  the working directory generically instead of a literal path). Fixed two bugs behind
  "closing Bitwig quickly makes the script come back after a while": `wait_bitwig_saved()`
  now bails the instant Bitwig itself closes (not the full 5-minute cap), and a new
  `BITWIG_OPENED` flag stops the interactive main menu from redrawing itself over Bitwig at
  all once it's been opened. Settings gained "Change working directory location" (a zenity
  folder picker, moves/merges the working directory into a new parent) and "Ableton
  auto-close timer" (numeric prompt, replaces the old hardcoded 23s default) — both
  unit-tested with stubs. Re-confirmed (again, by re-reading Omarchy's own `Menu.qml`) that
  the "…" appended to every native-overlay prompt is unconditional platform behavior, not
  this script's own text. Investigated the still-reported stale Nautilus "Open With"
  entries further: the .desktop-level state is confirmed already clean (`gio mime` shows
  exactly one registered app); also found, independently, that a real `.als` file's actual
  detected type doesn't reliably resolve to the custom Ableton mimetype at all (content
  sniffing for gzip/json wins over the glob-only custom type) — consistent with, not
  contradicting, prior findings. **First commit + push of this entire multi-round saga**
  (`1cbbb1d`), spanning this module's full build-out, VST Manager v0.4.0, and smaller pending
  fixes across several other modules — a `.gitignore` regression (a dropped
  `SECRET-README.md` pattern, file didn't actually exist so no real leak) was caught and
  fixed before staging. Sixteenth round reinforced Ableton auto-close further (still
  reported not closing): `close_ableton_window()` now sends both Super+W and Ctrl+Q per
  attempt (confirmed live, harmlessly, that neither the standard Hyprland `closewindow`
  dispatcher nor this fork's own `hl.dsp.window.close()` is a usable targeted alternative),
  and phase 2 now retries every 30s instead of a single burst, polling at 2s instead of 5s
  for faster next-step reaction. Also answered (researched, not implemented — explicitly a
  question) whether SuperFile could become the system-wide file manager including Ableton's
  own Save dialog: yes for folder-opening actions (a real, buildable module), no for
  Ableton's dialog specifically — that conclusion was corrected the very next round (see
  below) after actually reading `ableton-linux`'s own patch set. Seventeenth round
  root-caused a real regression from the round before: Ctrl+Q (added to reinforce
  `close_ableton_window()`) was reported causing a repeated "swap instrument" action instead
  of closing anything — confirmed against Ableton's own official shortcuts manual that a
  bare, unmodified **Q** is "Hot-Swap Selected Device," proving the Ctrl modifier was being
  dropped in transit. Removed Ctrl+Q entirely rather than guess at a replacement; Super+W
  (unaffected, since it's meant to be intercepted by Hyprland itself rather than depend on
  the modifier reaching Ableton's own keymap) is the only keystroke sent now. Also
  consolidated the Bitwig-phase notifications from two into one (20s), and fixed a stale
  README claim about a confirm prompt that was never actually removed. **Built the new
  `scripts/superfile` module** (see its own bullet below) after finding, by reading
  `ableton-linux`'s own patches, that Ableton's Save dialog genuinely does route through
  `org.freedesktop.portal.FileChooser` — an existing `xdg-desktop-portal-termfilechooser`
  project (AUR) already ships an official `superfile-wrapper.sh` for exactly this. Eighteenth
  round fixed a real notification-join bug (`IFS=' and '` only ever uses its first
  character), and used the fix as the occasion to redesign the pre-flight check entirely per
  explicit request: Bitwig is never blocked or closed anywhere in this flow anymore, only the
  configured Ableton install is (unchanged `ensure_ableton_not_already_open()`); if Bitwig is
  already open by the time its own step is reached, its window is focused directly instead
  (`focus_existing_bitwig()`, via Omarchy's own `omarchy-hyprland-focus-app`). Ableton's
  auto-close timer is now per power profile (performance/balanced/power-saver/this project's
  own `ultra-save` toggle, 15/20/30/60s defaults) — reported "way too short" while on
  `ultra-save`, whose CPU throttling plausibly explains why. Also sends a Space keystroke
  every ~2s during the load wait, to help dismiss any lingering startup dialog. Found (and
  the user is now actually pursuing) a real "Ableton is ready" signal instead of a timer:
  AbletonOSC sends `/live/startup` automatically on its own control-surface init. Nineteenth
  round: removed the just-added Settings timer submenu again (per-profile delays are now
  plain constants, no longer user-editable) since AbletonOSC is meant to replace timer-tuning
  entirely; added a one-time "enable AbletonOSC" reminder prompt (`maybe_show_osc_reminder()`,
  shown right after Ableton launches) using new `noLabel`/`yesLabel` support added to the
  shared `mosquito.confirm` Omarchy plugin itself (this project's own custom overlay, also
  used by `mega-caffeine` — verified live, backward compatible); documented the exact Wine
  Remote Scripts path on this machine, confirmed Ableton Link isn't required, and reasoned
  (not fully confirmed) that Intro should work too. Twentieth round automated the AbletonOSC
  file placement itself: `ensure_abletonosc()` in `setup-ableton-move-converter.sh` clones it
  straight into the right Wine-mapped Remote Scripts folder (idempotent, non-fatal if Ableton
  isn't installed — an informational, non-blocking warning instead), tested against four
  isolated scenarios and then run for real on this machine — **AbletonOSC is now actually
  installed here**. Enabling it in Ableton's own Preferences is still a manual step (can't be
  automated from outside Ableton). **Twenty-first round: split into a shared core +
  two real interfaces.** All workflow logic now lives in `lib-move-manager-core.sh`, sourced
  by `mosquito-move-manager-native` (the original native Omarchy overlay, byte-identical
  behavior) and the new `mosquito-move-manager-tui` (a real, fully-functional `gum`-based
  terminal UI — not a mockup, does everything native does). `mosquito-move-manager` is now a
  tiny stable dispatcher — the only file any launcher needs to point at — routing to whichever
  interface is active; switch any time from Settings ("Switch interface"), which relaunches
  detached so the new process's own tty-detection does the right thing regardless of
  direction. `setup-ableton-move-converter.sh` asks which to default to once, on a fresh
  install only. Fixed a real `$SELF`-resolves-to-the-wrong-file bug surfaced by the split.
  `ensure_confirm_plugin()`'s staleness bug (flagged two rounds ago) is fixed — always
  re-syncs now. Rounds 23/25 chased a `gum`-rendering bug through several launch-mechanism
  fixes. **Round 26 made it moot: `mosquito-move-manager-tui` is now a real, compiled Go +
  Bubble Tea program** (`scripts/apps/ableton-move-converter/tui-go/`, using the shared
  `scripts/tui-kit/` component library — list picker, confirm, input, toast, a
  command-streaming `runner`), inspired by and built the same way as the user's own
  `omagrab`. `mosquito-move-manager-actions` is the new thin, non-interactive bash backend
  (sources the unmodified core with stubbed UI primitives) Go calls once every decision is
  made — the core's actual business logic is untouched. `go` is a build-time-only
  dependency (installed via `mise`, pinned in `.mise.toml`); native stays fully functional
  without it. `setup-ableton-move-converter.sh`'s own interactive menu also gained a
  "Switch interface" option, reachable even when the running app itself won't launch.
  Verified live through the real dispatcher (clean full-menu screenshots, one confirmed
  real keypress). **Still not exercised end-to-end with real hardware** across any of the
  Ableton/Bitwig logic in this module. The OSC listener itself still isn't built. The setup
  script's udev rule + Chromium policy steps still need the user's own `sudo` run — only
  this machine's non-root state hand-synced.
- **`superfile`** (module, `scripts/apps/superfile`, moved there this round from a former
  top-level `scripts/superfile/` — see the thirtieth-round Log entry) — makes `superfile`
  (`spf`) the default
  file manager (folder-opening actions, `.desktop` + `xdg-mime default`, previous default
  captured/restorable). **Forty-first round**: superfile's own theme now follows Omarchy's
  active theme — `apply-omarchy-theme.sh` generates `~/.config/superfile/theme/omarchy.toml`
  from Omarchy's `colors.toml` and points `config.toml` at it, run once at install and again
  on every Omarchy theme switch via a registered `~/.config/omarchy/hooks/theme-set.d/` hook.
  Also optionally (`--with-dialogs`, opt-in, not bundled into `-y`)
  overrides the `org.freedesktop.impl.portal.FileChooser` XDG portal via
  `xdg-desktop-portal-termfilechooser` (AUR) + its own official `superfile-wrapper.sh`
  (`spf --chooser-file`) — session-wide, affecting every portal-aware app's Open/Save
  dialog, including Ableton Live's (its `ableton-linux` Wine build patches `comdlg32` to
  route through exactly this portal). Wired into `setup-customarchy.sh`
  (`st_/un_/run_superfile`, `MODULES` entry). Default-file-manager piece live-tested on
  this machine (install/status/remove/reinstall round-trip, all correct) and left applied;
  the AUR+portal piece needs the user's own `sudo` and hasn't been applied yet. Thirtieth
  round: black-border fix (foot launched directly with `-o pad=0x0`) and "Enter on an
  executable → new terminal". Thirty-second round: `superfile-open-exec` extended to also
  open text/code extensions in a *configurable* editor (`write_editor_choice()`, state at
  `~/.config/superfile-module/editor`) in a new terminal on right-arrow; the file-picker
  invoked from either TUI now embeds in the TUI's own terminal (`tea.ExecProcess`) instead of
  spawning an external window; an Esc-in-superfile-falls-through-to-nautilus bug fixed (both
  managers). Pixelated video preview confirmed as a real foot limitation (no Kitty graphics
  protocol support — superfile's own docs list foot as unsupported for image/video preview),
  not fixable from this module.
- **`audio-stack` — the tool is now "mosquito Audio Plugin Manager"** (renamed from "VST
  Manager" the thirty-ninth round — every file/binary/Go-module/`.desktop`/icon/Hyprland
  app-id, plus a real state/prefs migration; see that round's Log entry). **Fortieth round
  unified it**: Plugin list, Install a plugin from file, Uninstall a plugin and Launch a
  standalone plugin sit directly on the **first menu** (common to both universes — VST +
  native LV2/CLAP/Linux-VST3 merged into one list/one uninstall picker); Install
  auto-detects the picked file (exe/msi → the existing wine-prefix wizard, anything else →
  native install, including `.zip`/`.tar.gz`/`.tgz` archives); Uninstall supports Tab
  multi-select (batch removal in one pass); the Plugin list itself supports Tab to mark a
  plugin hidden/shown (kept in the manager, excluded from DAW scans — VST via a new
  `.hidden`-suffix rename + `post_install()` resync, native via the pre-existing
  `.disabled` rename) with an explicit save-or-discard confirm on the way out, and
  Left/Right cycles the sort mode live (vendor/name/format/date) without leaving the
  list — all btop-style, via two new `tuikit.Picker` messages
  (`PickerToggleMsg`/`PickerSortMsg`). **"Windows VST Plugins (Wine)"** (renamed from
  "Manage VST plugins" — avoid "Manage", make the Wine-only scope explicit, per a same-day
  follow-up) is now a submenu holding *only* the Wine-specific leftovers as flat items (no
  nested settings sub-page): Manage prefixes, Manage visible executables, Hide VST2, Hide
  32-bit — its header no longer repeats the app's own name. The single top-level
  **Settings** screen holds everything else: File picker, "Plugins folder" (change
  `PLUGINS_ROOT`, default `~/Music/Plugins` — a `Plugins` folder *inside* `~/Music`, not a
  folder literally named "Plugins Music" — with `VST2`/`VST3`/`CLAP`/`LV2`/`VST3-Native`/
  `CLAP-Native` subfolders — native VST3/CLAP kept separate from the Windows ones so
  `yabridgectl`'s recursive plugin scan never mis-treats a native Linux plugin as a
  bridgeable Windows one; a freshly created root gets this app's own icon via `gio set
  metadata::custom-icon`, harmlessly skipped wherever `gio` isn't available; changing it
  moves real files and re-links wine/yabridge via `migrate_plugins_root()`,
  confirm-gated), "Downloads folder" (where the Install picker starts, default
  `~/Downloads`), and a manual "Rescan
  for untracked plugins" (native needs no reconcile — a directory scan is always current;
  VST reuses the existing reconcile-missing/reconcile-orphans checks). **Forty-first
  round** also made both this tool's TUI and the sibling Move Manager's follow Omarchy's
  active theme automatically (`tui-kit/theme.go` reads
  `~/.local/state/omarchy/current/theme/colors.toml` at startup) and added a generic
  success prompt after a completed install/uninstall/move step. File names below still say
  `vst-manager`/`VST Manager` where they describe pre-rename history — left as-is, that's
  what was true at the time.
- **`audio-stack` VST side (formerly "VST Manager")** — Thirty-second round: the TUI's Readme view had a real
  unbounded-box bug (`tuikit.Info` had no width/height at all — fixed with a proper
  `bubbles/viewport`, word-wrapped, scrollable, `SetSize()` added at every call site); its
  file-picker now embeds in the TUI's own terminal via `tea.ExecProcess` instead of spawning
  an external window; the Esc-in-superfile-falls-through-to-nautilus bug fixed in
  `install_flow()`; "for install" dropped from the Settings label; window shrunk 875×600 →
  700×480. `vst-manager` **v0.4.0** built, pty-tested and
  deployed this session: **Plugin list** (first menu option, grouped by vendor folder,
  `name - prefix`, trailing **Readme** opening in a native info card and returning to the
  list), no more "Launching VST Manager…" OSD (closed locally), uninstall and list grouped
  by vendor folder, History → "🕘 Management history", dedicated `~/.wine-vst` default
  prefix auto-created when nothing is installed yet (no generic-prefix fallback anymore),
  witch/Edge/Copilot/Guitar-Pro excluded from standalones + standalone log, standalone and
  menu-toggle lists driven by the state log (foreign executables never show), launch
  reconciliation (log-but-missing warning in a native info card; disk-but-untracked plugins
  offered as a ✓/○ checkbox add), empty-state feedback via native info prompts. Menu entry +
  `setup-vst-manager.sh` (renamed from `setup-vst-install-menu.sh`) aligned; **pending**:
  `setup-audio-stack.sh` re-check, commit/push. **Twenty-first round: split into a shared
  core + two real interfaces**, the identical architecture applied to `ableton-move-converter`
  the same round (see that module's own bullet for the full rationale — kept deliberately
  consistent between the two, per explicit request): `lib-vst-manager-core.sh` (all logic) +
  `vst-manager-native` (original behavior, byte-identical) + `vst-manager-tui` (new, real
  `gum` terminal UI) + `vst-manager` (tiny stable dispatcher). "Switch interface" added to
  the main menu (no separate Settings submenu here). `setup-vst-manager.sh` gained a real
  `-y` flag (had none before), asks the default interface once on a fresh install, and now
  also ensures the `mosquito.confirm` plugin itself — previously an unstated dependency on
  `ableton-move-converter` having installed it first. Since renamed to the
  `mosquito-vst-manager`/`mosquito-vst-manager-native`/`mosquito-vst-manager-tui`/
  `mosquito-vst-manager` naming (matching the sibling module's convention) by a
  concurrent session. **Round 26: same Go/Bubble Tea rewrite as move-manager** —
  `mosquito-vst-manager-tui` is now a compiled Go program (`scripts/apps/audio-stack/
  tui-go/`, same shared `tui-kit`), `mosquito-vst-manager-actions` is its non-interactive
  bash backend; `uninstall_plugin()` in the core was split (extract-function refactor,
  native's own behavior unchanged) into `uninstall_target(kind:target)` so the mechanical
  removal is callable once Go has already picked and confirmed. Covers the full menu tree
  including install/uninstall/prefix-move/standalone-launch/executable-toggle and the
  startup reconcile checks, with one accepted simplification vs. the old bash flow:
  "manage prefixes" is a single-shot move rather than the old repeat-without-reopening
  loop. Verified: `go build`/`go vet` clean, the real setup script builds and deploys it
  end-to-end, launched live through the real dispatcher and screenshotted — legible
  through the user's own busy concurrent desktop but not a fully unobstructed shot, and
  real keystroke interaction wasn't separately re-verified here the way move-manager's
  was — **treat as good-confidence-but-less battle-tested than move-manager's** until
  used for real. `setup-vst-manager.sh` has no top-level install/uninstall/status/quit
  menu (linear script) so it didn't get the setup-script-level "Switch interface" addition
  move-manager's setup script got.
- **`mx-master`** — **new module** (this session): Logitech MX Master (any model) thumb
  gesture button → **SUPER**, momentary, via **logiops** (`/etc/logid.cfg` with one device
  block per known MX Master model name, marker `mosquitOmarchy-mx-master`, idempotent, user
  config backed up to `.bak`). Registered in `setup-customarchy.sh` + both READMEs; sandbox-
  tested (install/config/status/remove). **Pending:** user runs `setup-customarchy.sh` and
  picks `mx-master` (or `sudo bash scripts/mx-master/setup-mx-master.sh`); then either logiops
  from the AUR or the gesture-button pay attention — first live check on the real device.
  Also re-verified the earlier "No plugin found in … should be OK, not Yes/No" report: already
  satisfied in the deployed v0.4.0 `vst-manager` (L931 `ui_info`, `okOnly`).
- **`guitarpro`** — a font-rendering issue was reported; not yet diagnosed (waiting on the
  exact symptom from the user — missing/blank glyphs vs. everything too small/DPI).
- **`power-management`** — the `custom.power` panel now couples **ultra-save** with the power
  profile: picking a plan (≠ power-saver) while ultra-save is on turns ultra-save **off** first,
  then applies the plan (live plugin copy synced). The `mx-master` setup script's right-click
  launch was also fixed (`chmod +x` — the repo script wasn't executable).
- **`audio-stack` (VST Manager) — this session's batch, all deployed:** (1) the plugin list
  still shows the **Readme** when the list is empty, with a precise "No plugin found in …"
  first line; (2) plugin list now updates after installs at any depth — `scan_plugins()`
  dropped its `-maxdepth 3` cap (it only matched shallow files while install detection had no
  depth limit, so deep bundles like `Plugin.vst3/Contents/…` never appeared); (3) installs now
  **auto-detect new `.aux` support files** and offer to delete them — replacing the old
  "Installation finished? (wine window closed)" prompt; (4) the truncated "Manage prefixes"
  prompt lost its "…(Management history is at the bottom)" tail so it fits the overlay.

- **`apps` module** (`scripts/apps/`) — gained a new `PLUG` catalog kind alongside the
  existing `APP`/`TUI`/`WEB` ones, for git-based Omarchy shell plugins installed via
  `omarchy plugin add/remove` rather than pacman (`lib/common.bash`: `plugin_installed()`,
  `install_one`/`remove_one`/`status_type`/`tick_entries`/`tick_removal` all PLUG-aware).
  `tui/tuis.catalog` now also carries `PLUG` lines — `setup-tuis.sh`/`uninstall-tuis.sh`
  handle `TYPES=(TUI PLUG)` together via new `selection_of_types`/`all_catalog_types`
  multi-type helpers, so a PLUG entry is proposed by default alongside plain TUIs.
  `28allday/Monitor-TUI-Omarchy` (id `nosignal.monitor-settings`, confirmed via its
  `manifest.json` — despite the name it's now a QML Hyprland-monitor-settings panel, not a
  bash TUI) is the first PLUG entry, in `tuis.catalog`. **`davinci` module**
  (`scripts/apps/davinci/setup-davinci.sh`) gained an optional companion-tool offer for
  `28allday/omarchy-resolve` (id `nosignal.davinci-resolve`, confirmed via its
  `manifest.json`): asked right after `recap()` (before the existing resolution-patch step),
  actually installed after that patch step completes (independent of whether the patch was
  applied), then opens the panel on its Status tab (`omarchy-shell -q nosignal.davinci-resolve
  show status`) and sends a notification via `omarchy-notification-send` (with a `notify-send`
  fallback). Live-verified: `bash -n` clean on every touched file, `setup-tuis.sh --status`/
  `--all --list-selection` and `setup-apps.sh --status` all correctly show the new Plugins
  section; the actual `omarchy plugin add` install and the davinci companion-tool prompt were
  NOT live-exercised (neither plugin is installed on this machine, and the davinci prompt only
  fires mid-install of an actual DaVinci Resolve ZIP).

- **`macos-vm` module** (`scripts/macos-vm/`) — new this round. Vendored OSX-For-Omarchy
  (commit d8cd6f4) as `osx-kvm-installer.sh` + TUI + launcher, all patched to self-locate
  and delegate the Super+Alt+A keybinding to `setup-keybindings.sh`; menu block and
  window-rule block via `setup-macos-vm.sh` (conventions-compatible with
  `setup-windows-vm.sh`). Integrated into `setup-customarchy.sh` at all 7 wiring points.
  See the module's own README.

The project itself was renamed `Omarchy_Custom_Scripts` → **`mosquitOmarchy`**, local
directory and GitHub repo both (`~/mosquitOmarchy`,
`github.com/kepalegars/mosquitOmarchy`) — see Log for what was and wasn't touched (some
internal Hyprland-config block markers still say `Omarchy_Custom_Scripts_*` on purpose,
deferred to Roadmap step 5).

The two commits that carried a Claude co-author trailer have been rewritten and
force-pushed (user-confirmed) — see Log. A local-only safety branch
(`backup-before-strip-claude-attribution`) still exists, not pushed; fine to delete whenever.

Everything else in the README's module tables should be assumed working as documented until
this journal or the module's own README says otherwise.

## Roadmap

Ordered; do them in this order unless the user redirects. Check off as completed, but leave
the checkmark and a one-line pointer to the Log entry that covers it — don't delete finished
items, this list is also part of the history.

- [x] ~~**1. `ableton-move-converter` — single-key shortcuts**~~ Done 2026-09-10, then
      **reverted the same day** — the user said they weren't useful. `ui_select` is back to
      plain numbered prompts. See Log (top entry).
- [x] **1b. (unplanned) Move Manager webapp icon fix.** Done 2026-09-10 — see Log.
      Self-heals fully only once the real Move is reachable again (open item, see Log).
- [x] **1c. (unplanned) Module rename `move-ablbundle-converter` → `ableton-move-converter`,
      and project rename `Omarchy_Custom_Scripts` → `mosquitOmarchy` (local dir + GitHub
      repo).** Done 2026-09-10 — see Log for exact scope, including what was deliberately
      deferred.
- [x] **1d. (unplanned) `ableton-move-converter` large UX/flow rewrite**, then **1e.
      (unplanned) real-usage bug-fix + feature follow-up round** on top of it (Settings menu,
      auto-detect background watcher + systemd unit, notification icon system, `detect_move`
      timeout/caching fix, Chromium insecure-download fix, manager-close/set-before-route
      simplification, converted-set hide/rename, narrowed `"mosquito"` alias, a real
      libmodplug/Tracker crash root-caused and mitigated). Both done 2026-09-10 — see Log for
      the full breakdown. **Still not exercised against real Move/Ableton/Bitwig hardware end
      to end** — unit- and flow-tested with stubs throughout.
- [x] **1f. (unplanned) Third real-usage round + full rename to "mosquito Move Manager".**
      Done 2026-09-11 — see Log (top entry). Dropped the network-reachability watcher
      entirely (USB-only auto-detect via udev, connect+disconnect); moved Ableton-version
      picking into Settings-only; fixed a real premature-notification-dismiss bug
      (`manager_running()`'s `pgrep -f` host-string match); type-specific converted-file
      marking + green "(converted!)"; fixed white-logo webapp icon (from the user's own
      licensed Ableton asset); Hyprland-dispatch auto-close of Ableton after project load
      (non-trivial syntax discovery on this Omarchy Hyprland fork); investigated the menu
      flicker and confirmed it's a structural `omarchy-menu-select`/`omarchy-shell` platform
      limitation, not fixable from this module; renamed the main script/binary and every
      user-facing label to "mosquito Move Manager" (module directory/id deliberately left as
      `ableton-move-converter` — see Log for the exact scope decision). **The setup script's
      install flow itself still hasn't been (re-)run** — only this machine's live state was
      hand-synced (binary, desktop entry, `omarchy-menu.jsonc`); the deployed udev rule on
      this machine is also now one `sudo` step behind the repo copy (harmless — same
      add/remove logic, just fires on both events already; needs the user's one sudo run to
      pick up any wording/comment changes).
- [x] **1g. (unplanned) Fourth real-usage round: checkmark labels, real Ableton icon, Ctrl+Q
      auto-close, version extraction, Escape-quit confirm, legacy-marker regression fix.**
      Done 2026-09-11 — see Log (top entry). `WEBAPP_NAME` reverted to "Move Manager" (the
      global "mosquito Move Manager" rename explicitly excludes the webapp's own display
      name, user-confirmed). Chromium's "unsupported command-line flag" banner has a real
      fix queued (`CommandLineFlagSecurityWarningsEnabled: false` in the managed policy) —
      needs the pending `sudo` setup run to take effect. Investigated true right-alignment
      of the main-menu title's dot+address and confirmed it's not achievable — the native
      overlay renders the whole prompt as one left-aligned, proportional-font, elide-right
      `Text` element with no alignment/segment control exposed to callers; explained to the
      user rather than attempting a padding hack that wouldn't reliably work.
- [x] **1h. (unplanned) Fifth real-usage round: dropped the notify-on-connect feature for a
      live-redraw-while-open mechanism, fixed wrong-Ableton-version launches, custom webapp
      icon.** Done 2026-09-11 — see Log (top entry). Removed the standalone USB
      connect/disconnect notification system entirely (no toast, no Settings toggle, no
      detection while the script isn't running) per explicit user request; replaced with a
      live-redraw-while-open mechanism using Omarchy's own `shell hide` IPC (not process
      killing) — **not verified against a real open overlay**, only isolated command tests.
      `open_in_ableton()` now always launches through the `ableton-live` wrapper instead of
      sometimes invoking a raw `.exe` directly — likely the real fix for "always launches the
      wrong version". Webapp icon replaced again with a user-provided custom asset. Confirmed
      a second platform limitation (list-row right-alignment, same category as the title-bar
      one). Could not resolve the "no notification during Ableton" complaint — ruled out the
      obvious causes, flagged for more diagnostic info rather than guessing further.
- [x] **1i. (unplanned) Sixth real-usage round: PID-based Ableton window detection, a
      demonstrated `pgrep -f` false-positive fixed, diagnostic logging for the silent
      "no .als detected" path.** Done 2026-09-11 — see Log (top entry). User's detailed
      description of Ableton's actual multi-stage Wine startup explained why window-class
      matching was unreliable; switched to `/proc`-based PID/process-tree matching. Found a
      real bug in the same investigation: `ableton_pids()` (and `is_ableton_running()`, which
      now delegates to it) matched a stray shell command from this very session that
      happened to mention the search strings — fixed by filtering on process name. Clarified
      that the connection dot's day-to-day responsiveness comes from the pre-existing
      per-loop `refresh_connected()`, not the live-redraw-while-open mechanism from the
      previous round — genuinely live updates while the menu sits idle still need the
      pending `sudo` re-deploy to reload the udev rule at all.
- [x] **1j. (unplanned) `audio-stack` VST Manager integration.** Done 2026-09-11 — see Log
      (v0.2.0 + v0.3.0 + v0.4.0 entries). The manager + `vst-manager.desktop` ("VST Manager",
      `Exec=uwsm app -- vst-manager`) are deployed via
      `setup-vst-manager.sh` (renamed from `setup-vst-install-menu.sh`), which
      also drops the old `vst-install` wrapper/entry. `setup-audio-stack.sh` `step_vst_menu`
      aligns with the new entry name. Re-deployed and pty-tested this session.
- [ ] **1j2. (unplanned) `setup-audio-stack.sh` step_vst_menu re-verify** against the
      current repo state (entry name now matches; quick read-through left for a later pass).
- [x] **1k. (unplanned) Seventh real-usage round: abandoned the live-redraw mechanism,
      Super+W + lsof-tracked Ableton→Bitwig handoff, disconnect-during-Manager-use
      notification.** Done 2026-09-11 — see Log. The previous round's omarchy-shell-IPC
      live-redraw mechanism (1i) was abandoned per explicit user request in favor of a
      manual "Refresh connection status" menu option — confirmed (again) the native overlay
      has no Tab-key hook to bind that to instead. `move-udev-refresh` repurposed to only
      warn on disconnect during active Move Manager use. Ableton auto-close switched from
      Ctrl+Q to a Super+W keystroke (still didn't fire — see 1l). The Ableton→Bitwig `.als`
      handoff was rebuilt around `lsof` file-descriptor tracking rather than folder-mtime
      guessing, after a broad-scan miss on a file saved to `~/Downloads`.
- [x] **1l. (unplanned) Eighth real-usage round: root-caused the Ableton "script never
      comes back" hang, dropped the fragile Hyprland-focus check, active download-complete
      prompt in the Move Manager.** Done 2026-09-11 — see Log (top entry). Found (very
      likely) why the script appeared to hang after a manual save+close: it was waiting on
      the `ableton-live` **wrapper's** PID, not Ableton's own process, and the wrapper does
      real post-exit housekeeping of its own that could plausibly stall. Fixed by keying the
      exit condition on `is_ableton_running()` alone. Dropped the Hyprland-IPC PID/focus
      check that gated the Super+W auto-close entirely — it never once fired across two
      implementations, and Wine's process model (`wineserver` as a long-lived daemon, not a
      child of the specific launch) plausibly made the ancestry check structurally unable to
      succeed; replaced with process-exists + a flat 20s settle delay + unconditional send.
      `wait_manager_close()` now actively prompts the moment a Chromium download completes
      instead of only passively waiting for the window to close.
- [x] **1m. (unplanned) Ninth round: found Omarchy's own `send_key_state` dispatcher and
      switched `.als` detection to kernel-level `inotify`.** Done 2026-09-11 — see Log (top
      entry). Root-caused every prior auto-close failure by reading Omarchy's own
      `clipboard.lua`: `wtype`'s synthetic keystrokes have a documented Hyprland quirk
      (linked upstream issue) causing them to merge incorrectly with real modifier state —
      Omarchy's own "Universal copy/paste" feature explicitly avoids `wtype` for this exact
      reason, using `hl.dsp.send_key_state` instead. Validated live (bogus-key-name calls
      only, nothing real triggered) that this dispatcher accepts an explicit
      `window = "pid:N"` target, letting `close_ableton_window()` send Super+W directly to
      Ableton's window by PID regardless of focus. Replaced `lsof`-based `.als` detection
      with `inotifywait -e close_write` (kernel-level, no Wine-PID dependency at all) —
      tested end-to-end with a real background watcher and a simulated file write.
- [x] **1n. (unplanned) Tenth round: found and fixed a real, reproduced root-cause bug in
      `open_in_ableton()`'s background launch.** Done 2026-09-11 — see Log (top entry).
      Read the actual session log instead of guessing again after "toujours rien ne marche"
      — found a ~36s gap between two log lines that should be near-instant apart. Traced to
      a classic bash pitfall: the three `"$cmd" &` background launches in `open_in_ableton()`
      (always called as `pid=$(open_in_ableton ...)`) had no stdout/stderr redirect, unlike
      every other backgrounded launch in this module — the unredirected Wine child inherits
      and holds open the command substitution's own pipe, blocking it for however long Wine
      takes to detach from its inherited fds. Reproduced the exact mechanism in isolation
      (a `sleep &` with vs. without redirection) before fixing it with `>/dev/null 2>&1 &`
      added to all three launch lines. Plausibly the shared root cause behind several
      rounds' worth of "no notification / no auto-close / no .als found" reports.
- [x] **1o. (unplanned) Eleventh round: title-stability readiness detection, notification
      moved to route-selection time.** Done 2026-09-11 — see Log (top entry). First round
      with user-confirmed real progress: auto-close fired (previous round's pipe fix
      worked) but too early, closing a still-loading project — the fixed 20s settle delay
      had been getting an accidental head start from the pipe bug it no longer gets.
      Replaced with `ableton_window_title()` (`hyprctl clients -j` + `jq`) and title-change
      polling: waits for the title to hold steady ~15s before closing, adapting to actual
      load time instead of guessing a fixed number. The "opening in Ableton" notification
      now fires exactly where asked — the instant "Bitwig" is chosen as the route, not
      later in the flow.
- [x] **1p. (unplanned) Twelfth round: pre-flight Ableton/Bitwig conflict detection, 5-min
      Bitwig-wait cap, Bitwig `.desktop` file-open-argument finding, 4 stale zombie
      processes found.** Done 2026-09-11 — see Log (top entry). Added active
      (`ensure_ableton_not_already_open`, at the Ableton-launch moment) and passive
      (`ensure_daw_apps_closed_before_convert`, at conversion start, gates only the Bitwig
      route) conflict checks — a different, unconfigured Ableton edition is left alone.
      Found a second live `pgrep -f` self-match false positive in the new `bitwig_running()`,
      fixed with the same comm-filter pattern before shipping. Compared Bitwig's `.desktop`
      against every other app on the system and found it alone lacks a `%f`/`%U` file-open
      argument — likely explains "Bitwig opens empty" reports; added a fallback notification
      with the exact path. **Pending, not yet actioned**: 4 stale `ableton-move-converter`
      (old, deleted binary path) zombie processes found running 19+ hours — need the user's
      go-ahead before cleanup, see Log for exact PIDs/ages at time of discovery.
- [x] **1q. (unplanned) Thirteenth round: single-instance enforcement (with a
      self-inflicted-kill bug caught and fixed by testing), idle-timeout auto-exit, 20s
      Ableton notification, two research-backed dead ends.** Done 2026-09-12 — see Log (top
      entry). `enforce_single_instance()` + `MAIN_MENU_IDLE_TIMEOUT`; first matcher version
      demonstrably could self-inflict-kill an unrelated process via `pgrep -f` substring
      matching (caught before shipping), fixed via exact `/proc/<pid>/cmdline` argv-field
      matching. `notify()` gained `--timeout SECONDS`. Confirmed infeasible (researched, not
      implemented): file-with-Bitwig launch, Ableton-scripted auto-save/quit handshake.
      **Still pending**: the 4 old-path zombie processes from the twelfth round need a
      separate, explicit cleanup — this round's mechanism doesn't retroactively match them.
      **Resolved next round**: they'd exited on their own (see 1r).
- [x] **1r. (unplanned) Fourteenth round: fixed-schedule Ableton auto-close, reworded
      notifications, Settings "clear als folder", stale Wine desktop-entry cleanup, stale
      per-folder README fix.** Done 2026-09-12 — see Log (top entry). Dropped the adaptive
      title-stability close-detection for a fixed 20-25s repeated-Super+W schedule (timed
      off the user's own measured ~20s Ableton startup) + a single 30s "still waiting"
      notice; verified with a time-compressed test harness. Notifications reworded to exact
      requested text. `clear_als_folder()` added to Settings, unit-tested. Confirmed via
      `strings` on Bitwig's own binary that it has zero CLI file-open support at any level —
      "Open with Bitwig" in Nautilus can never work, not implemented. Found and fixed the
      real cause of stale duplicate "Ableton Live" entries cluttering Nautilus's Open-With:
      `setup-ableton.sh` used to deliberately keep `wine-extension-*`/`wine-protocol-*`
      associations, some pointing at a stale pre-dedicated-prefix `~/.wine` install — policy
      reversed, cleaned up live on this machine too (10 entries). Fixed the stale per-folder
      `README.md` (still said `move-session`, 3 renames ago). The twelfth round's 4 zombies
      were confirmed gone (exited on their own since).
- [x] **1s. (unplanned) Fifteenth round: close window widened to 23-30s + save-dialog
      detection, shorter notifications, script no longer reopens over Bitwig, two new
      Settings options, first commit+push of everything.** Done 2026-09-12 — see Log (top
      entry). Widened the auto-close window and added a best-effort save-dialog detector
      that pauses close attempts while a dialog is up. Fixed `wait_bitwig_saved()`'s
      5-minute-even-after-Bitwig-closed bug and the "script pops back up over Bitwig" bug
      (new `BITWIG_OPENED` flag). Settings gained working-directory relocation (with merge
      support) and a configurable Ableton close timer. Re-confirmed the "…" title suffix is
      Omarchy's own unconditional overlay behavior. First `git commit` + `push`
      (`1cbbb1d`) of this module's entire build-out plus other pending module work — caught
      and fixed a `.gitignore` regression (dropped `SECRET-README.md` pattern) before
      staging.
- [x] **1t. (unplanned) Sixteenth round: reinforced Ableton auto-close (Ctrl+Q added,
      persistent phase-2 retries, faster polling); SuperFile-as-default-file-manager
      feasibility researched (question only); baseline system benchmark gathered.** Done
      2026-09-12 — see Log (top entry). Confirmed live (harmlessly) that neither stock
      Hyprland's `closewindow` nor this fork's `hl.dsp.window.close()` can be targeted at a
      specific window — `send_key_state` remains the only addressable mechanism, now sending
      both Super+W and Ctrl+Q per attempt; phase 2 retries every 30s instead of giving up,
      polling at 2s. SuperFile: yes for folder-opening actions (buildable module), no for
      Ableton's own Save dialog (Wine's Win32 common-dialog reimplementation isn't routed
      through any Linux file-manager mechanism — confirmed via WineHQ). Gathered this
      machine's current boot/idle-memory baseline as the benchmark starting point.
- [x] **1u. (unplanned) Seventeenth round: root-caused the Ctrl+Q "swap instrument" misfire
      (dropped modifier), consolidated Bitwig notifications, built the `superfile` module.**
      Done 2026-09-12 — see Log (top entry) and the standalone `superfile` bullet above.
      Confirmed via Ableton's own shortcuts manual that bare "Q" = Hot-Swap Selected Device,
      proving Ctrl+Q's modifier was dropping in transit — removed rather than replaced with
      another guess. Corrected the sixteenth round's SuperFile conclusion after reading
      `ableton-linux`'s own `comdlg32` portal patch: Ableton's Save dialog is reachable after
      all, via `org.freedesktop.portal.FileChooser` + `xdg-desktop-portal-termfilechooser`.
- [x] **1v. (unplanned) Eighteenth round: Ableton-only pre-flight close (Bitwig auto-focused
      instead), per-power-profile auto-close timer, Space-bar dismissal during load,
      AbletonOSC `/live/startup` researched.** Done 2026-09-13 — see Log (top entry). Fixed a
      real `IFS=' and '` join bug and used it as the occasion to stop ever blocking/closing
      Bitwig in this flow — `focus_existing_bitwig()` switches to its window instead, via
      Omarchy's own `omarchy-hyprland-focus-app`. Auto-close timer now per power profile
      (`current_power_profile()`/`ableton_close_delay()`, Settings submenu, nameref-based
      editor). Found AbletonOSC sends `/live/startup` automatically — a real readiness
      signal, strictly better than a timer — but it needs the user to install/enable it in
      Ableton's own Preferences first; flagged for a future round rather than half-built.
- [x] **1w. (unplanned) Nineteenth round: user pursuing AbletonOSC setup — removed the
      Settings timer UI, added a one-time reminder prompt, extended `mosquito.confirm` with
      custom button labels, answered 3 setup questions.** Done 2026-09-13 — see Log (top
      entry). `noLabel`/`yesLabel` added to the shared `mosquito.confirm` plugin (also used
      by `mega-caffeine`) and `ui_confirm()` — verified live, backward compatible; caught the
      deployed plugin copy had diverged from the repo's own source copy and re-synced both.
      Settings' per-profile timer submenu removed (delays are now fixed constants) in favor
      of the coming AbletonOSC integration; new one-time "enable AbletonOSC" reminder added
      instead. Confirmed Ableton Link isn't required, reasoned Intro should work, and found
      (by inspecting the real Wine prefix) exactly why the user couldn't find AbletonOSC yet:
      the `Remote Scripts` folder doesn't exist under `Documents/Ableton/User Library/` until
      created — documented the exact path.
- [x] **1x. (unplanned) Twentieth round: automated the AbletonOSC file placement
      (`ensure_abletonosc()` in `setup-ableton-move-converter.sh`), a non-blocking
      Ableton-not-installed advisory, a throwaway `gum` TUI draft.** Done 2026-09-14 — see
      Log (top entry). Tested against 4 isolated scenarios, then run for real on this
      machine — AbletonOSC is now genuinely installed at the documented Wine path. Enabling
      it in Ableton's own Preferences remains the user's own manual step. Built
      `tui-draft.sh` (unshipped, every action simulated) exploring a `gum`-based terminal UI
      for the same menu flow. Noted, not fixed: `ensure_confirm_plugin()` only ever copies
      the shared plugin once, never re-syncing it on a later repo update — flagged for a
      future pass, very plausibly why the deployed/repo copies had already drifted before
      last round caught and fixed it.
- [x] **1y. (unplanned) Twenty-first round: split `ableton-move-converter` AND `audio-stack`
      (VST Manager) into a shared core + native/TUI interfaces with a live-switchable
      dispatcher, per-module; the TUI draft became the real, shipped implementation;
      `ensure_confirm_plugin()` staleness fixed in both install scripts.** Done 2026-09-14 —
      see Log (top entry) for the full architecture. `lib-move-manager-core.sh` /
      `lib-vst-manager-core.sh` hold all logic; `*-native` (byte-identical to the originals)
      and the new, real `*-tui` (gum) implement the same small UI-primitive contract; the
      stable dispatcher (`mosquito-move-manager` / `vst-manager`) is the only launcher target,
      `exec`-routing to whichever interface `switch_interface()` last selected. Both install
      scripts deploy all the new files, ask the default interface once on a fresh install,
      and now both ensure `mosquito.confirm` correctly (always re-synced, and VST Manager
      does this at all for the first time). Two real bugs found and fixed mid-refactor: a
      `$SELF`-resolves-to-the-core-file issue, and `gui-run.bash` not being found once
      deployed (fixed by deploying it alongside and checking the entry script's own directory
      first). `tui-draft.sh` deleted, fully superseded.
- [x] **1z. (unplanned) Twenty-second round: fixed a live "TUI doesn't launch" bug in both
      modules and removed unnecessary parentheses from the switch-interface confirm labels.**
      Done 2026-09-14 — see Log (top entry). The 1y fix for `gui-run.bash` (deploy alongside,
      check own directory first) turned out not to be enough in practice; replaced the whole
      mechanism with Omarchy's own `omarchy-launch-or-focus-tui`, decision centralized in the
      stable dispatcher. Not yet confirmed fixed on the user's real desktop.
- [x] **1za. (unplanned) Twenty-third round: root-caused the TUI's blank-window bug live and
      fixed it, plus a Hyprland float windowrule for the TUI window (both modules).** Done
      2026-09-14 — see Log (top entry). The 1z fix wasn't enough either:
      `omarchy-launch-or-focus-tui` (via `xdg-terminal-exec`) reliably corrupts gum's
      interactive rendering, isolated and confirmed via live screenshots on the real desktop.
      Dispatcher now opens `foot`/`xterm` directly. Separately found the TUI window was never
      in Omarchy's floating-window whitelist (verbatim app-id match) so it always tiled — a
      windowrule now floats+centers it. Verified live as far as reasonably possible without
      disrupting the user's own desktop (which had other real windows, including a password
      manager, in view by the end). **Turned out incomplete — see 1zb**: the float fix was
      real and correct, but the blank-render bug had a different, still-unfound cause at
      this point.
- [x] **1zb. (unplanned) Twenty-fifth round: the TUI's blank-window bug, actually
      root-caused this time (gum breaks when anything runs concurrently with it), fixed;
      setup script gained its own "Switch interface" option.** Done 2026-09-14 — see Log
      (top entry). User tried 1za's fix and still saw a blank window. Isolated live via many
      paired clean/broken screenshots of the real content: a bare, synchronous `gum choose`
      never failed; wrapping it in anything concurrent (external `timeout`, gum's own
      `--timeout`, or a manually backgrounded job) reliably broke it. The TUI main menu's
      idle-auto-exit was the only such user in this codebase — dropped (VST Manager's TUI
      never had this feature, so it needed no change). Confirmed live: the real production
      menu and a submenu rendered correctly, repeatably. Also added, per explicit request:
      `setup-ableton-move-converter.sh`'s own menu can now switch interface directly.
- [ ] **2. `guitarpro` font-rendering fix.** Blocked: need the exact symptom from the user
      (missing/blank glyphs? DPI/size?) before touching `setup-guitarpro.sh` (`step_fonts`,
      `corefonts`, `winetricks allfonts`, `--dpi`). Verify with `patch-guitarpro --check`.
- [ ] **3. Regression tests**, in this order (each against the *current* repo state, not
      historical):
  - [ ] 3.1 **Orchestrator** — `setup-customarchy.sh` status + per-module `st_`/`un_`
        (including the 4 move bins), update/exclude/uninstall roles, `MODULES` descriptions.
  - [ ] 3.2 **Backup/restore** — `setup-customarchy.sh --backup` to `/tmp`, then
        `--restore`.
  - [ ] 3.3 **Bootstrap** — `scripts/bootstrap.sh` against a real GitHub connection
        (`curl … | bash -s -- --status` without triggering a full install at `$HOME`);
        `--zips` checked demo/status-only.
  - [ ] 3.4 **Keybindings** — `scripts/setup-keybindings.sh` (category "Ableton Move
        converter" / `CAT_MOVE`, `launch`/`cmd` types, `--status`, add/show a binding
        without breaking the existing Hyprland config).
  - [ ] 3.5 **Update watchdog** — `scripts/customarchy-update/setup-customarchy-update.sh`
        + `setup-customarchy.sh --update-repo` (detects an update without pushing,
        notifies; never push without explicit user authorization).
  - [ ] 3.6 **Archive** — `archive-customarchy.sh` (tar.gz to `/tmp`, `tar tzf` contents
        check, Ableton/DaVinci/GuitarPro filtering, no large installers ending up
        committed to the repo).
- [ ] **3.7 (new) Zen config follow-up** — `scripts/browsers/zen/` module built (round
      24): seeds the active profile's plugins/settings/chrome. `keepassxc-browser`
      v1.10.3 XPI fetched into the seed (password autofill). Remaining: KeePassXC
      browser-integration step live (see `scripts/browsers/zen/README.md`), then
      optionally refresh `seed/extension-settings.json` from the live profile.
      `deps`-by-module restore mechanism + omagrab backup are in place.
- [x] **3.8 (unplanned) User's UI-list round 1/2: menu icons + grayed-out disabled TUI
      options.** Done 2026-09-15 — see Log (top entry). Keyboard-backlight menu icon
      `""`→`\uf11c`; music trigger icon deduped (orphan block removed) and
      `\uf09e1`→`\uf001` — both in the live `~/.config/omarchy/extensions/omarchy-menu.jsonc`
      and in the setup-menu block (`setup-ableton-move-converter.sh`). TUIs: picker options
      can now be `PickerItem.Disabled` (greyed via new `StyleDisabled`, skipped by
      navigation, inert on enter) — wired to the move-manager's "Open the Move Manager and
      convert" entry whenever status is "checking…" or not connected.
- [x] **3.9 (user's list) Remove the native (bash/gum) interface modes from both mosquito
      managers** — `ableton-move-converter` and `audio-stack` move/vst-manager setup scripts
      + TUIs — including their "Switch interface" options, leaving the TUI as the only
      interface. Done 2026-09-15 — see Log (top entry).
- [ ] **3.10 (user's list) TUI colors auto-adapt to the active Omarchy theme** (e.g. the
      lime achraff-67 palette) instead of the current hardcoded `tui-kit` color constants.
- [ ] **4. End-of-session review** — list commit candidates, **always ask before any
      `git push`**, tidy the README if needed, confirm with the user the remaining `sudo`
      steps (udev rule + Chromium policy for the Move module).
- [ ] **5. FINAL — full project clean & coherence pass.** Do this **last**, only once
      everything above is done. Scope (this is deliberately broad — that's the point):
  - **Naming coherence**: every module folder name, script name (`setup-*.sh`,
    `uninstall-*.sh`), and the module id used in `setup-customarchy.sh`'s `MODULES` table
    line up with each other and with what the README calls them.
  - **Docs-vs-code accuracy**: every module README (and the root README's module table)
    actually matches current script behavior, flags, and file paths — no stale
    documentation left over from a rename or refactor.
  - **Dead code / cruft**: unused functions, leftover debug scaffolding, orphaned files,
    stale TODOs.
  - **Convention consistency**: shared idioms (the `ui_confirm`/`ui_select`/`ui_input`
    native-Omarchy-prompt pattern, `log()`/`info()`/`ok()`/`warn()`/`err()` logging, idempotent
    re-run behavior) are applied the same way across modules, not reinvented per-module
    where a shared helper would do.
  - **Static checks**: `bash -n` (and `shellcheck` if available) clean across every script.
  - **Repo hygiene**: `.gitignore` coverage still correct, no stray build artifacts,
    secrets, or personal paths committed.
  - **Deferred marker rename** (from the 2026-09-10 project rename, see Log): decide
    whether to rename the `Omarchy_Custom_Scripts_*` Hyprland/`omarchy-menu.jsonc` block
    markers to `mosquitOmarchy_*` across `power-management`, `touchpad`, `display`
    (brightness + keyboard-backlight), `apps/handbrake`, `windows-vm`, and the general
    `setup-keybindings.sh` — and if so, write + test a live-config migration (old marker
    text → new, in place) for each, since this machine already has several of these blocks
    actually deployed in `~/.config/hypr/*.lua`.
  - Produce a short report of what was found/fixed; get the user's sign-off before any
    resulting `git push`.

## Log

Most recent entry first. **The newest entry is the detailed one** — see maintenance rule 3
above for how to fold this over time.

---

### 2026-09-19 — fifty-eighth round: TUI gets live detection (backend captures while the neck is open), panel pinning via the red ♪ icon with a hover hint

The chord detection worked in the panel but barely in the TUI because of the
capture gate: `_sync_capture` only ran while the panel was visible or a hold was
active, so a TUI opened on its own heard nothing. It now also captures while
**the neck TUI is open** (`_tui_active()`), and the key-confident auto-lock is
skipped while the TUI owns the session (it wants continuous detection). The
`resetAnalysis` command also clears the lock now. Verified with the TUI open:
`tuiActive:true`, `recording:true`, `captureBackend:parec`, live key/BPM/chords
(Fmaj7, Cadd9, C7 at ~109 BPM).

Pinning reuses the popup's **input region** instead of fighting the overlay:
clicking the red **♪** in the header toggles `pinned`, which swaps the
KeyboardPanel's `mask` from the full screen to just the card rect — so the
overlay no longer eats outside clicks and other apps stay usable while the panel
stays visible (previously a full-screen layer-shell overlay dismissed on any
outside click). The ♪ is now a `Button` whose tooltip explains the function
("Pin the panel — keep it open while you use other apps"), and closing the panel
clears the pin. Verified: QML loads, panel opens/closes via IPC (`visible:true,
recording:true` → `false`), no shell errors.

---

### 2026-09-19 — fifty-seventh round: chord progression set aside (live chord estimate instead), "Open TUI" flush with the right edge

Two small follow-ups. The **chord-progression detection was not reliable
enough**, so it is **disabled, not deleted**: `PROGRESSION_ENABLED = False` gates
the `ChordSeq` feed in `analyze()` and the snapshot returns an empty
`progression` and an inactive `loop`. The TUI's below-neck area no longer lists
the progression or the ↻ LOOP badge — it now renders a **live chord estimate**
(`CHORD <name>  <notes>`, refreshed each pass; "listening for a chord…" / "no
music — could not find the chord" otherwise), and the scale line above the neck
is now scale-only so the chord estimate has a single home. Flipping the flag
re-enables the old behaviour untouched.

The **Open TUI** button is now anchored to the toolbar's **right edge** (the
toolbar is a full-width `Item` with MIDI anchored left and Open TUI anchored
right) so it lines up exactly with the right edge of the chord card above it,
instead of relying on a spacer.

Verified: `py_compile`, qmllint, `go vet`/`test`, plugin IN SYNC, live capture
showing chords but `progression:[]` / `loop.active:false`, and a TUI render with
the new live-chord line. Committed and pushed.

---

### 2026-09-19 — fifty-sixth round: two capture bugs fixed (parec monitor, stale analysis window), analyzer rebuilt (harmonic chroma, extended chords, same-window BPM, time signature, song-change), analysis auto-lock + space, plugin layout (Open TUI right / MIDI left, g/r, gated fretboard, 12th fret)

**Bug 1 — capture was silence.** The backend recorded `pw-record --target
<default-sink>.monitor`. Measured on this machine, that returns the noise floor
(peak ~130) while `parec -d <sink>.monitor` returns the real signal (peak 6553):
on PipeWire 1.6 monitors are *ports*, not nodes, so `pw-record` silently falls
back. The recorder now prefers **`parec`** for monitors and keeps `pw-record` as
a fallback; verified live: `captureBackend:parec`, `recording:true`, real chords.
Also measured that the sink monitor is **pre-volume and mute-immune** (identical
peak at output volume 1.0, 0.0 and muted), so the requirement "detect even when
the sound is cut" holds, and the backend now **re-resolves the default sink every
3 s** and re-targets when the output device changes (internal/HDMI/Bluetooth/
jack) or the capture dies.

**Bug 2 — stale window.** `AudioBuffer.take()` returned the **oldest** 2 s and
advanced only one 1024-sample hop per call while audio arrived 48 000/s, so the
analyzer kept re-hearing ~2 s-stale audio and never caught up. It now returns the
most recent window; chords track the audio again.

**Analyzer rebuild (NNLS-Chroma/Chordino-informed).** New harmonic pitch-class
chroma (fundamentals across octaves + the octave-only 2nd harmonic, which cannot
leak onto other pitch classes; broadband whitening was tried and rejected because
it flattens the chroma). Extended chord dictionary (maj, m, 7, maj7, m7, m7♭5,
dim, dim7, 6, m6, sus2, sus4, add9) with a separate **bass chroma** for slash
chords/inversions, and a "smallest chord that explains the notes" score (a
missing-tone penalty stops C reading as Cmaj7). Key stays Krumhansl-Schmuckler
but is adopted only after holding two analyses and exposes `keyStable`; **BPM is
computed from the same 2 s onset envelope as the key** (locks in within ~2 s);
a **time-signature** estimate (4/4 vs 3/4) comes from the bar autocorrelation;
**song-change detection** flags a sustained key+chroma shift so the UIs offer a
reset. Offline harness: C→Am→F→G progression read back as C, Am, F, G at ~120 BPM.

**Analysis lock + space.** Once the key is stable with confidence ≥ 0.2 the
analysis stops on its own (capture pauses, `locked:true`); **space** in the panel
(or a global RIGHT CTRL hold) resumes/restarts it. Verified via the command file:
`recording:false, locked:true` after lock, then space → `locked:false,
recording:true`.

**Plugin UI.** GUITAR → **Open TUI**, pinned right; **MIDI** moved to the left
where GUITAR was; `g` opens the TUI and `r` resets (hints in the tooltips); the
empty-chord `· · ·` is now centred; the popup widens to 560 so the neck fits; the
fretboard is drawn **only once a key is confidently established** and follows the
input source (PC/mic) automatically. The neck no longer overlaps its legend
(height derived from the legend row) and its old canvas scale label — which
collided with the 12th-fret dots at the right edge — is gone; the 12th fret now
carries the double-dot octave marker **plus an explicit "12"**. TUI: time
signature in the header and a song-change reset banner. Opening the TUI no longer
disables the panel (`tuiActive` gating removed).

Verified: `py_compile`, qmllint ×4, `go vet`/`test`, plugin IN SYNC, live parec
capture + detection, lock/resume, TUI render. Committed and pushed. Still
heuristic (not yet implemented): A/B segmentation and vocal-robust source
separation — loop detection and song-change are the current structure signals.

---

### 2026-09-19 — fifty-fifth round: mouse-click analysis removed — the global RIGHT CTRL is the only way to start an analysis hold

The user asked to drop the click shortcut. The last in-TUI trigger was the mouse
click on the bottom-right button; it is gone. Analysis now starts exclusively
with the global **RIGHT CTRL** hold (or the recording toggle paths for the
influencer), passed through the backend's `hold` flag and mirrored by the TUI.
Removed the whole internal press mechanism: the `tea.MouseMsg` handler,
`keyDown`/`pressHold`/`inAnalyzeButton`, the `analyzeWatchCmd` auto-repeat/gap
inference (bubbletea has no release event, so a held press was tracked by
repeat/motion timing — no longer needed without key or mouse triggers), the
`analyzeDown`/`analyzeOn` fields, the `analyzeGap`/`analyzeMinHold` constants,
and `tea.WithMouseAllMotion()` from `main.go`. `analyzeStart` is kept and reset
when the backend hold is adopted on a tick, so the `analyzing… N chords · Xs`
progress line keeps counting from the real hold start. The hint line and the
`HOLD` help row no longer say "or click" — they read `hold Right Ctrl`.

Verified: `go vet`/`test`, zero leftover references (grep), plugin IN SYNC
after setup + rsync, and a live tmux render showing the new hint line and help.
Committed and pushed.

---

### 2026-09-19 — fifty-fourth round: in-TUI '+' analyze shortcut removed (Right Ctrl is the only trigger), wordmark hold-box switched from the warm-orange error colour to the theme's true red, bar ring pulses by thickness instead of opacity

The user asked to drop the leftover `+` key. The TUI-local analysis key (dark `+` press
inside the window, a leftover of the old shortcut) is **removed entirely** — analysis is now
triggered only by the global **Right Ctrl** hold or a click. The bottom-right button and the
hint line both read `hold Right Ctrl` and the `▷` glyph in front of the button is gone. The
full feature was peeled out: the key-capture flow, the keypress toggle, the settings
`ANALYSIS KEY` row (TUI and panel), the `setAnalyzeKey` IPC RPC, and `analyzeKey` from the
`Config` struct, the snapshot `config` object, and the backend `DEFAULT_CONFIG`/`setConfig`
handler. Every `Ctrl_R` string in the TUI, bar, dispatcher and docs became `Right Ctrl`.

**Perfect red.** The box around the `jamjamjam` wordmark while the hold is active used
`tuikit.ColorErr` — which is deliberately the theme's warm **orange** (`#ee5e21`) — so the
"recording red" barely read as red. New `tuikit.ColorRed` picks the theme's actual `red`
(`#ed1c24`, ANSI-196 fallback) and the logo box now uses it. The bar's analysis ring also
pulses by **border thickness** (1→3) instead of fading opacity to 0.25, so it stays a solid
theme red instead of a pale wash.

Verified: `py_compile`, `go vet`/`test`, qmllint ×3, `bash -n`, setup + rsync (plugin IN
SYNC), shell restarted, and a live tmux render: hint/button show `hold Right Ctrl …`, and
with a real hold the wordmark border emits ANSI `38;2;237;28;36` (`#ed1c24`) with no orange
left. Committed and pushed.

---

### 2026-09-19 — fifty-third round: detection reinforced against silence/noise, tuner always fully shown (full null state), TUI analyze label names Ctrl_R, GUITAR button accent-filled with contrast text

Four fixes. **False chords on silence.** The analyzer used to emit a chord whenever
`best_score > 0` and normalised chroma hides level, so a quiet/noisy chunk could be "C".
Reinforced: named gates `SILENCE_RMS = 0.004` / `QUIET_CHUNKS_TO_MUTE = 2` (a chunk below the
floor now **skips detection entirely** and clears the live chord, while the debounced
`noSignal` UI flag still avoids flicker), plus `CHORD_PEAK_MIN = 0.16` (the winning pitch
class must actually stand out — a flat noisy chroma is rejected), `CHORD_MARGIN = 1.05` (the
best template must clearly beat the runner-up, else "no chord"), and `KEY_PEAK_MIN = 0.12`
before deriving a key. Unit-checked on synthetic chroma: flat noise → `''`, flat+tiny bump →
`''`, C major → `C`, A minor → `Am`, a single tone → `''` (ambiguous, rejected). Live silent
backend: `noSignal:true`, `chord:''`, `key:''`.

**Tuner always whole.** The TUI header now always renders the complete tuner
`TUNER no note ♭······│······♯` instead of a bare `TUNER —`; `tunerGauge()` gained an `active`
flag so the idle gauge draws the track and centre mark with **no needle**. The panel's null
note is a full-size dash (`—`, same 40 px as a note) rather than the tiny `· · ·`, and even
the mic-muted state keeps the gauge. Go test updated for the new signature.

**TUI analyze label.** The bottom-right button now reads `hold <key> or Ctrl_R to analyze`,
naming the global shortcut.

**GUITAR button.** The toolbar GUITAR button is filled with the theme **accent**; its label
picks black/white via a new `contrastText()` (BT.601 luminance, threshold 0.5) for maximum
contrast with that fill, and hover just brightens the accent.

Verified: `py_compile`, `go vet`/`test` green, qmllint ×4, the detector unit-check above,
setup + `rsync --delete` (source ⇄ installed IN SYNC), shell restarted clean, and a tmux
render showing the header tuner, the new bottom-right label.

---

### 2026-09-19 — fifty-second round: global analyze hold rebound to RIGHT CTRL (physical-code keydown + modifier release), pulsing analysis ring on the quickshell bar

The user's `SUPER+SHIFT+=` didn't fire, so the global hold was rebound after a **mapping
audit**: layout **fr**, `compose:caps` → Caps Lock = Compose, both Shifts = Caps, Super+G /
Alt+G / Super+Shift+G taken, `CTRL+SHIFT+=` is the universal app zoom; free keys were
Insert/Delete/Escape/Right Shift/Right Ctrl/F-keys. The user chose **RIGHT CTRL**. Hyprland
delivers no usable keydown for a lone modifier keysym, so the press half binds the physical
`code:105` (evdev KEY_RIGHTCTRL 97 + 8) and the release half `CTRL + Control_R` (verified by
injecting key events with `ydotool` via `/tmp/.ydotool_socket`, using F8 as control). The
quickshell `BarWidget` gained an `analyzing` flag and a **pulsing ring** around the ♪ while
the hold is active. End-to-end: injected Ctrl_R down → `hold/recording:true`, up → false.

---

### 2026-09-19 — fifty-first round: analyze shortcut moved to SUPER+SHIFT+=, TUI wordmark floated lower and block-centred, fretboard ruler trimmed (numbers bottom-only, vertical lines stop at the strings), PC icon becomes a computer screen

Four tweaks, later partly superseded. The global hold was moved `SUPER+CTRL+G` →
`SUPER+SHIFT+=` (bound as `SUPER + SHIFT + PLUS` because Hyprland matches the shifted keysym)
— replaced again by RIGHT CTRL in the 52nd. `logoTitle()` was removed: the wordmark now lives
in the **body**, floating below the header and vertically centred, and is centred as a **block**
by the new `centerBlockText()` (preserving the figlet art's internal alignment). The top fret
ruler was removed (numbers only below the neck) and `rulerRow()` writes a space where each `│`
sat, so the vertical fret lines stop at the strings. The PC input icon became a computer screen
`󰍹`. go vet/build/test + qmllint green, IN SYNC.

---

### 2026-09-19 — fiftieth round: global SUPER+CTRL+G analyze (TUI-open only), clickable BPM card that flashes white on the beat, reset that really empties, chord-card right-edge alignment, compact MIDI switch, TUI wordmark below the header + centred fretboard, coherent icons + square PC/MIC

Nine user requirements. The analysis gained a **global push-to-talk chord** (`SUPER + CTRL + G`
then, since the 51st, `SUPER + SHIFT + =`): a `jamjamjam-analyze` helper no-ops unless
`tui.pid` is alive and drives the backend by IPC, with an idempotent `o.bind` block in
`~/.config/hypr/bindings.lua`, and the TUI adopts an external `hold`. The **BPM card** is
clickable (toggles the metronome) and flashes white each beat. **Reset** now also clears the
audio window (`AudioBuffer.clear()`), so the cleared cards stay empty ~1.4 s instead of
re-detecting in 0.15 s. The card row uses `(W−2·spacing)·fraction` so the chord card's right
edge aligns. The MIDI header swapped the overflowing `Toggle` for a compact `ToggleSwitch`.
The TUI wordmark moved below the header and the fretboard rows were centred (with numbers
bottom-only and `│` lines stopping at the strings from the 51st). Icons moved to the
Material-Design set and the INPUT control became a 26×26 square. qmllint/vet/build/test
clean, IN SYNC.

---

### 2026-09-19 — forty-ninth round: whole UI in English, play-style triangle pause, panel/fretboard/tuner follow the Omarchy theme, chord card shows only the chord name, MIDI two-row + no box, TUI logo on top with a red hold box, header tuner gauge

All user-facing strings switched to **English only** (panel, TUI, README); the tuner section
was the last French holdout. The pause became a play-triangle Canvas `PauseButton.qml`
(superseded by MDI glyphs in the 50th), every hard-coded color in `Panel.qml` +
`GuitarFretboard.qml` was replaced by `Color`/`Style`/`Util` tokens (whole plugin re-tints
with the theme), the chord card was reduced to the chord name, MIDI split into two rows with
the big chord box removed, and the TUI got the wordmark in the title block with a red hold
box plus an `IN`-less header tuner needle gauge (covered by `logo_view_test.go`). qmllint ×5
+ `go vet`/`build`/`test` clean, source ⇄ installed IN SYNC, shell restarted.

---

### 2026-09-19 — forty-eighth round: "jamjamjam" lowercase everywhere, tuner fixed (mic-default + YIN), pause & plugin gear + TUI settings, TUI-owned analysis, chord-notes line, neck redesign, MIDI cleanup

Fourteen requirements implemented. Renamed every user-facing `JamJamJam` → lowercase
`jamjamjam` (manifest/QML/TUI/README). **Tuner fixed:** now always listens to the **default
microphone** on its own 0.5 s clock, and the detector was rewritten as vectorised **YIN**
(~6 ms, was a 2.1 s pure-Python autocorrelation); a new `wpctl` mic probe exposed that the
user's silence was the **default source being muted** → both tuners show "micro coupé".
**TUI-owned analysis:** while the TUI runs it holds the session; analysis triggers on the
configured key (default `+`) or the bottom-right click via an auto-repeat-gap hold (~250 ms
minimum), holds **accumulate** instead of resetting, `paused` freezes capture, panel shows the
TUI's results. TUI redesign: splash wordmark above the neck, centered scale+chord, high-strings-
on-top fretboard with top+bottom rulers, `s` settings (key + flats/sharps), `?` help. Panel:
header reset·pause·INPUT·gear row, chord-notes single line, compact MIDI section, gear settings,
plus a `GuitarFretboard` paint-warning guard. qmllint / go vet / py_compile / bash -n clean,
source ⇄ installed IN SYNC, baseline `paused:false, tuiActive:false, visible:false,
mic:{available:true,muted:true}, config:{analyzeKey:"+",noteNaming:"flats"}`.

---
**Compressed — forty-seventh round:** the tuner followed the selected INPUT (since reverted in the 48th), RMS silence detection with `analyzer.noSignal` ("impossible de trouver l'accord"), the `jamjamjam-tui` dispatcher became single-instance + instant + refocusing (`hyprctl focuswindow`), the neck opened on the standard `BoxedMosquito()` + `MosquitoSubtitle("jamjamjam")` splash (new art in `tui-kit/mosquito_banner.go`), the space/hold became a true auto-repeat-gap hold (dropping the round-45 debounced toggle; local intent authoritative, backend state adopted on the first tick only), the title showed `BPM <n>` instead of the chord/`idle`, the fretboard got a ruler + crisp `│` fret lines, the HOLD button dropped a line, and the hint became a single greyed `StyleHelp` line with a real `?` help overlay. qmllint/vet clean, IN SYNC.

---

### 2026-09-19 — forty-sixth round: capture lifecycle, hold-gated progression, loop gating, tuner panel, INPUT PC/MIC, metronome, single-hint + icon-only bar, flat-key fretboard bug

Ten user requirements, all verified live. **Capture is now lifecycle-driven instead of always-on:** the backend no longer auto-starts the analyzer recorder at boot; it resolves capture to `panel_visible or hold` (`_sync_capture()` — start/stop the recorder as either changes) and resets analysis on panel-open (`setVisible`) and at hold-start (a fresh `ChordSeq(8)`). End-to-end through the live shell IPC, `quickshell ipc -p /usr/share/omarchy/shell call jamjamjam-plugin …` → panel `open` → `recording:true`+reset, `close` → `recording:false`, `setHold true` (even while the panel is closed) → capture on, release → off, `setSource mic|pc` → `inputSource` + capture target flip (`@DEFAULT_SOURCE@` ↔ monitor of default sink).

**Chord progression is recorded only while the TUI's HOLD button is held.** New backend ops `setVisible/setHold/setSource/setMetronome` routed through `handle_command` (the poll_command_file known-set too, so the TUI's `commands.json` path works — verified: `{"op":"setHold","active":true}` lands in state, same op set the shell min<style>; ~2 s poll latency, the shell service path is instant stdin IPC). `analyze(record_progression=self.hold)` gates the sequence. **Loop markers appear only once the held progression actually repeats and then changes** — `ChordSeq.loop_matches` must be ≥ 2 (regression: `C G Am F C G` → active len 4 pos 2; `C G Am C` stuck → not active).

**Metronome** (backend `MidiSynth`): `set_metronome(enabled,bpm,beats)`, immediate downbeat click on enable (triangles, 1760 Hz downbeat / 1100 Hz other, 40 ms decay), phase-based in `_render_block`, streams in `_run` while enabled, BPM pushed from the held-analysis BPM each pass. Snapshot adds `inputSource/visible/hold/metronome{enabled,bpm,beats}`.

**QML:** `Service.qml` gained the props/functions + IpcHandlers (`setVisible/setHold/setSource/setMetronome`; the `visible` mirror is named `panelVisible` — `visible` collided with the base `Item.visible` FINAL property, which made the service fail to load with "Cannot override FINAL property"; fixed, shell reload logs clean). `Panel.qml`'s progression zone is now a **tuner view** (tuner InstrumentView row + live note display + local capture button), the GUITAR tooltip reads "Scale AND chord progression live in the guitar tab (tui)", a new **INPUT PC/MIC** button calls `service.setSource(...)`, and `onOpenedChanged` drives `service.setVisible(opened)` (was toggleRecording). `BarWidget.qml` is **icon-only** (key/BPM Row + props removed). All three files qmllint-clean in both source and installed copies.

**TUI** (`tui-go/`): big **HOLD button** (bordered box, stable geometry; idle muted "HOLD TO ANALYZE PROGRESSION"; while held green "⏺ HOLDING — metronome BPM = N"), driven by **mouse press/release** (`tea.WithMouseAllMotion()`, MouseLeft down/up) and **space with a 250 ms auto-repeat debounce** — note bubbletea v1.3.10 has no `tea.WithKeyReleases()`/`KeyReleaseMsg` (a v2 API), so mouse is the true press/release and space is a debounced toggle. `m` toggles the metronome via `writeMetronome`; the title shows `IN PC|MIC` and `♪ M <bpm>` when enabled. **Single hint line**: "hold space or click to analyze · m metronome · r reset · q quit" (was duplicated in two branches). Render verified pixel-faithful inside a real foot pane via `tmux capture-pane` (idle and holding states; a raw pty can't drive it — bubbletea waits for the terminal's `ESC[6n` size answer, and my probe replies gave a 1-column size, hence a misleading "loading…" screen; tmux is the reliable harness). Command channel verified against the live backend.

**Bonus fix found during verification**: the fretboard never showed for flat keys — `GuitarModes.tone_map` uses ASCII spellings (`Ab`) while flat keys are unicode (`A♭`), so `scales_for("A♭m")` fell into the empty "unknown root" branch (snapshot got `strings:[]`, no `label`). Fixed by normalizing `♭`→`b`/`♯`→`#` before the lookup; verified `A♭m → label "A♭ minor", 6 strings, 45 dots`, and the TUI now renders the full B♭ minor neck (degrees, root 1, marker row).

**Setup script**: `install_shazam()` added (idempotent — skips when already importable; `pip install --user shazamio`, with a PEP 668 `--break-system-packages` retry for Arch, never fatal), wired into the install flow; header bullets updated; `bash -n` clean. **Shazamio reality on this box (Python 3.14):** `pip install --user shazamio` is blocked by PEP 668; the `--break-system-packages` fallback installs it but the pydub dep needs `audioop`, which no longer exists on 3.14 — and the `audioop-lts` backport **segfaults** the interpreter (rc 139, uncatchable — a backend import would kill the plugin). Decision: shazamio stays installed-but-unimportable → `song.available:false`, graceful; audioop-lts uninstalled to avoid the segfault landmine. Note in README. **Open:** rapid-command overwrite in `commands.json` (two near-simultaneous writes race the single-file poll — the TUI emits one op at a time so fine in practice); retry shazamio when pydub/audioop work on 3.14.

**Syncing discipline learned the hard way:** the installed copy `~/.config/omarchy/plugins/jamjamjam-plugin/` gets clobbered by every `rsync source → installed`; edits must go **source-first, then rsync**. An rsync mid-round reverted the installed QML once, and the shell ran stale Service.qml ("setVisible → Function not found"); recovered by re-applying all edits to source + re-sync + `omarchy restart shell`. Backend currently running fresh (PID check), snapshot clean (`recording:false, hold:false, visible:false, inputSource:pc`).

---

**Compressed — forty-fifth round (real audio analysis that works):** system-audio capture via the default-sink **monitor** (wpctl/pw-dump resolution, `--standalone` + atomic `state.json`), the `_onset_strength` method-vs-attribute shadow bug fixed (renamed `_onset_values`), chroma computed before chord/key/BPM (no more one-chunk-stale); chord **quality** (C/Cm/C7/Cmaj7/sus) + `ChordSeq._update_cycle` loop badges; an input **tuner** class (second `pw-record`, autocorrelation + margin test, A4→`+1¢`/noise→inactive); optional **Shazam** hook (`shazamio`, graceful when missing); panel fixes (reset glyph ``, anchors-based MIDI row, GUITAR button → `openTui`); the new **tiled guitar-neck TUI** (bubbletea v1.3.10 + lipgloss, pure `state.json` viewer, `jamjamjam-tui` dispatcher, `jamjamjam-neck` binary, Hyprland tiled rule in setup). Verified live; open item was installing shazamio.

---

**Compressed — forty-fourth round (rename + Panel rework):** `audio-analyzer` was renamed
everywhere to `jamjamjam-plugin` (repo `scripts/plugins/jamjamjam/`, display name
"JamJamJam", backend file/`PLUGIN_ID`, installed dir `~/.config/omarchy/plugins/jamjamjam-plugin/`,
`shell.json`, `setup-customarchy.sh`); `Panel.qml` got a full visual rework — ANALYZE/STOP
removed (the card strip toggles analysis), reset became a borderless icon-only button, all
toolbar buttons text-only, the MIDI section un-boxed, green replaced by accent throughout
(incl. `GuitarFretboard.qml` 3rd/6th dots), progression min-height raised to 240, content
height is now `fittedContentHeight(column.implicitHeight, 760)` with the toolbar pinned at
the bottom, dead props and the `pragma ComponentBehavior: Bound` (qmllint-crash) removed.
Hot-reload verified with no QML errors.

---

### 2026-09-16 — forty-third round: Live Mode v2 (mega-caffeine decoupling, no tint, Live Manager settings TUI) + the menu-clone crash permanently retired

Two big threads this round. **(1) The menu-clone crash class is retired for good.** Cloning
`omarchy.menu` to per-entry-color it broke the whole menu twice (blank rows, empty Apps) —
first from a hard QML TypeError (`row.color.length` on rows missing the field), then again
even after null-safety, because runtime hot-swapping the bar's menu widget leaves an empty
Apps submenu regardless. Decision recorded: **never clone `omarchy.menu` again**. Recovery
is now scripted and registered: `scripts/fixes/fix-omarchy-menu.sh` (removes any
`clonedFrom: omarchy.menu` user plugin — `omarchy plugin remove` auto-restores the stock
menu — re-enables `omarchy.menu`, repoints stale bar references, restarts the shell,
verifies ping + desktop-entry count), wired into `setup-customarchy.sh` FIXES as
`omarchy-menu`. The red/white circle icons are done crash-free instead with **emoji glyphs**
(`🔴` Live Mode / `⚪` Manage Live Mode) — the stock menu already renders `🔴` natively via
Noto Color Emoji, giving per-entry color without touching any QML. Menu hot-reload picked
them up; shell verified healthy (152 desktop entries, Apps restored). **(2) Live Mode v2.**
It no longer activates mega-caffeine at all: it replicates only mega-caffeine's sleep
management under its own name — `systemd-inhibit` lid block + stay-awake indicator — while
the bar's coffee icon shows red with the "Live Mode ON" tooltip (StayAwake.qml now reports
live mode by testing the active-flag file directly, independent of caffeine state). No
screen tint ever: activation neutralizes a warm hyprsunset tint (saved, set 6500K) and
deactivation restores it. Activation keeps the two-step prompt (activate? → close listed
background apps, names only), rewritten in English with the theme line removed, "Maximum
performance — audio optimized" added, and the routing line "Audio routing tool added to the
scratchpad (SUPER + S)" — activation parks qpwgraph into `special:scratchpad` (best-effort
install of qpwgraph added to the installer). Deactivation is a plain confirm, restores the
memorized pre-live theme, and force-ends any mega-caffeine session
(`CAFFEINE_LIVE_FORCE_OFF=1`). **The Live Manager TUI was rebuilt** (`tui-go`):
settings-for-the-next-session manager persisted to
`~/.config/live-mode/settings` (shell-sourceable), read by `live-mode` and the watchdog —
thermal limit (75–95 °C, cycled with Enter or ←/→ when its row is selected), close-apps
prompt on/off, "Choose background apps to close at start" (Tab multi-select screen over the
six known apps, stored as `CLOSE_APPS_LIST`), routing tool on/off, gaps on/off, silence
notifications on/off, a "Reset defaults" row, values rendered at line-end ("…: On"), and a
"mosquito live mode manager" FIGlet banner (MOSQUITO LIVE / MODE MANAGER blocks) with a
compact one-line fallback when the terminal is narrower than the art (title can never be
clipped in any terminal). FIGlet, tuikit picker with save-toasts, opened via `live-mode
manage` (foot 92x92) — and opening is refused with an OK notice while a session is active.
**All three managers unified**: tui-kit's `Picker.View()` now strips each row's trailing
padding and centers every line (title, items, pagination, help) + a `SelectedValue()`
helper; audio/move/live all launch foot at `-W 92x92` and float+center via Hyprland rules —
the old managed blocks forced `size = {700,480}`, which shrank the window under the TUI's
content and clipped titles; those size overrides were dropped from both owning setup
scripts and the live-mode installer now writes the shared float+center block (no pixel
size) into `hyprland.lua` (applied + `hyprctl reload` clean; audio/move scripts updated in
place so reruns stay consistent). Search alias `mosquito` added to Manage Live Mode too.
Watchdog no longer re-enables mega-caffeine (that was the tint leak) and derives its
threshold from settings. `bash -n` clean on all touched scripts; Go build/vet/fmt clean;
deployed to ~/.local/bin; fix script executed live (menu healthy). Open: full on/off cycle
still needs the sudoers file (`sudo bash setup-live-mode.sh`).

**Title pass**: the three managers now share a tuikit helper (`BoxedMosquito`
+ `MosquitoSubtitle`) that renders "mosquito" as a bubbletea-style rounded
box (white on the active theme's accent color) with a single accent-colored
subtitle line ("vst manager" / "move manager" / "live mode manager")
underneath. The font is TAAG's "Crazy" figlet (12-row boxed label + 1
blank + 1 subtitle = 14 rows); a width-aware fallback drops to
subtitle-only on narrow/short terminals so the title can never be eaten
by the borders. **Wallpaper**: the Live theme's `backgrounds/black.png`
is now a 1920×1080 black canvas with a centered red "live mode" rendered
in the same Crazy font (Pillow + pyfiglet, 32px
MesloLGSDZNerdFontMono-Bold). **Activation prompt**: each line shortened
to fit the confirm card on a single row (the scratchpad bullet is now
"Routing tool in scratchpad (SUPER + S)", 40 chars). **Restore guard**:
`restore_previous_theme` refuses to land on the Live theme even if the
saved name were "Live" (and falls back to "Achraff" if no memory was kept),
so the user can never be stranded on the red theme. **Select menu**: the
setup script's interactive prompt now prints explicit `1) 2) 3) 4)` labels
between actions so the option list always re-appears. Touched + deployed:
the three TUIs, the live-mode dispatcher, the wallpaper, the menu jsonc.

**Follow-up fixes (same day)**: root-caused "Manage Live Mode does not
launch" — two compounding issues: (a) `cmd_on` wrote the ACTIVE_FLAG
*before* the sudo step, so a failed activation stranded the flag and every
later `manage` just showed the "while active" OK notice; the flag is now
removed by an EXIT trap on any activation failure; (b) the deployed
`mosquito-live-mode-tui` binary was root-owned (a previous root-context
deploy), blocking updates — replaced with a user-owned build (rm from the
user-owned dir works; note for future deploys: never deploy as root into
~/.local/bin). **Routing tool v2**: renamed "mosquito routing tool"
(activation prompt line + notifications); scratchpad parking is now
idempotent (pre-existing qpwgraph in scratchpad is left untouched and
flagged `patchbay_preexisting`); a scratchpad snapshot at activation makes
deactivation restore the exact previous state (session-spawned patchbay is
closed, pre-existing apps keep running, empty stays empty); the watchdog
intercepts a closed patchbay with a confirm prompt — "yes" parks it for
the session, "no" respawns+parks it. **Slow activation**: root apply now
runs in the background while gaps/DND/frame/scratchpad proceed in
parallel, with a late sudo-status check kept for the failure signal.
**Theme switch/restore detached + self-healing**: both `switch_to_live_
theme` and `restore_previous_theme` retry in a detached loop until
theme.name lands — this was the real "restore doesn't work": theme-set's
post-hooks restart the terminal the script may run in, killing the OFF
flow before the inline restore finished. **Fonts**: all three manager
titles switched to the TAAG **ANSI Shadow** figlet font (6-row block
"mosquito", white-on-accent box + accent subtitle), header budget 10 rows.
**Window size**: all three dispatchers launch foot at `-W 82x40`
(≈pixel-square 631×640 at CaskaydiaMono 9, fits 1080p; all TUI content
fits — banner ≤74 cols, item text centered per line). All scripts
`bash -n` clean, deployed copies in sync, shell ping ok.

### 2026-09-16 — forty-second round: Audio Analyzer plugin + setup-customarchy module integration + Panel.qml MIDI section fix

Full bar widget plugin (`mosquito.audio-analyzer`) — real-time key/BPM/chord detection,
chord grid, MIDI detection, mini synth — installed as a `setup-customarchy.sh` module
(`MODULES`/state/uninstall wiring, README updated). `Panel.qml` MIDI section made
content-driven (`midiContent.implicitHeight`, MIDI-gated synth controls) and a
`root.synthVolume` undefined-property bug fixed; `qmllint` clean.

### 2026-09-15 — forty-first round: Omarchy theme compatibility (both TUIs + superfile), unified "Plugins Music" folder with migration, Settings folder pickers, toast/success-prompt UX, menu reorder — plus a self-inflicted STATE_DIR regression found and fixed

Large multi-part request, handled directly (no plan-mode). **Theme compatibility**: both TUIs now read Omarchy's active `colors.toml` at startup (`init()`) and map accent/muted/green/yellow/red onto existing ANSI-256 slots. **Superfile** also follows the Omarchy theme (`apply-omarchy-theme.sh` + `theme-set.d/` hook, re-syncs on every theme switch). **Unified "Plugins Music" folder**: `PLUGINS_ROOT` pref (default `~/Music/Plugins`); native VST3/CLAP get separate sibling folders (`VST3-Native`/`CLAP-Native`) to avoid bridgeable-plugin misclassification; backward-compatible seeding for existing installs; `migrate_plugins_root()` does the real move when triggered explicitly from Settings. **Settings screen**: plugins-folder + downloads-folder pickers, toast-clears-on-pop, generic success-prompt modal, VST menu reorder. **STATE_DIR regression**: stray `link-vst-shared.sh` in `~/.local/bin` silently redirected state writes to an empty file; deleted, real state file never at risk. **Two same-day corrections**: "Windows VST Plugins (Wine)" rename + `PLUGINS_ROOT` default fix (`~/Music/Plugins`). Not committed (concurrent opencode work in tree).

### 2026-09-15 — fortieth round: "mosquito Audio Plugin Manager" unified — single VST menu, merged plugin list, Tab/arrow btop-style navigation, batch uninstall, hide/save — compressed, see history for full detail

Revision of the thirty-ninth round's two-category design: unified VST + native into one
Plugin list/Uninstall (self-describing `vst:<type>:<path>`/`native:<path>` values,
`all_plugin_list_rows_sorted()` in the core), Tab/Left-Right btop-style live sort-cycle and
multi-select via two new `tuikit.Picker` messages (`PickerToggleMsg`/`PickerSortMsg`), a
hide/show-with-save mechanism for VST (`toggle_vst_plugin_hidden()`, mirroring native's
existing `.disabled` trick), and batch uninstall (`uninstall-batch`). Found and fixed two
pre-existing bugs while wiring this up for real: a disabled native plugin was silently
dropped from the list instead of showing `enabled:false` (LV2-manifest check used a wrong
hypothetical path), and three actions-script verbs leaked a core function's progress-line
stdout into their JSON `path` field. Same-day follow-up moved Plugin list/Install/Uninstall/
Launch onto the first menu directly (common to both plugin universes), left "Manage VST
plugins" holding only the Wine-specific leftovers as flat items, and unified Settings.

### 2026-09-15 — thirty-ninth round: VST Manager renamed to "mosquito Audio Plugin Manager" and given a two-category native-plugin subsystem — compressed, superseded by the fortieth round above

Full rename (every file/binary/Go-module/`.desktop`/icon/Hyprland app-id/state path) with a
real migration step, verified live (idempotent `-y` reinstall, old artifacts gone, state
carried forward). Added a from-scratch native-plugin subsystem (LV2/CLAP/native-Linux-VST3,
`~/.lv2`/`~/.clap`/`~/.vst3`, yabridge-stub-aware via `readlink -f` + `.wine*` check,
LV2 spec-bundle-aware via a `manifest.ttl` `lv2:Plugin` grep) as a **separate** "Manage native
plugins" top-level category, sharing only Settings with the VST side. Discovered mid-round
that a concurrent agent (opencode) had already stripped the module's old bash/gum interface
entirely, so the whole new surface went into the Go TUI only. The two-category shape was
revised the same day into the unified design above — see that entry for the current
structure.

### 2026-09-15 — thirty-eighth round: superfile setup now asks whether it takes the default-FM role and which text editor to use (omanotes added) — compressed, see history for full detail

Both were force-set/hardcoded before, now explicit setup questions: a new `fm-mode`
(`default`/`app-only`) state file gates whether superfile actually takes over XDG-default +
SUPER+SHIFT+F, or is just installed launchable/Open-With; the editor picker gained
**Omanotes** (`ykzird/omanotes`) as a fourth built-in choice alongside Neovim/Nano/Obsidian.
`-y` keeps prior behavior (default role) for non-interactive/automated installs. Verified in
a faked home with `gum` masked to force the numbered fallback menu (piped-pty limitation);
`--status`/`--remove` both updated for the new state file.

### 2026-09-15 — thirty-seventh round: macOS binding integrated into setup-keybindings.sh (the custom keybinds script)

The Super+Alt+A binding is owned by `setup-keybindings.sh` (its single `Omarchy_Custom_Scripts_Keys`
block) instead of a dedicated module block. `setup-keybindings.sh` gained idempotent
non-interactive modes `--ensure <combo> <label> <cmd> <type>` (`add_binding_silent`) and
`--remove-key <combo>` (`remove_binding`, drops the whole block when the last key goes) plus a
"macOS VM Manager" catalog entry (Add menu option 5). `setup-macos-vm.sh` no longer touches
bindings.lua — it calls `--ensure` on install and `--remove-key` on remove, keeping only the
window-rule block (hyprland.lua, Lua `--` markers — the JSONC `//` markers I briefly reused
for it were invalid Lua AND made the block duplicate/ungrep-able) and the menu `//` block.
`st_macos_vm` detects the binding inside the Keys block. Fake-home verified: idempotent
install ×2, clean remove (bindings.lua back to header), standalone ensure/remove-key, TUI
shows the new category; `SUPER + ALT + A` collides with no Omarchy default.

### 2026-09-15 — thirty-sixth round: VST-manager install/uninstall fixes (real live bug) + new `macos-vm` module (OSX-For-Omarchy, properly integrated in customarchy)

Root-caused a real CrispyAudio install that "detected nothing in ~/VST" — `install_plugin`
only sees new files when the prefix's `Program Files/...` dirs are symlinks into `~/VST`,
and the manager's `~/.wine-vst` was never linked (only `~/.wine`, `~/.wine-ableton` were).
Fixed with `link_prefix_to_vst()` (runs before the new-file snapshot, links the 6 standard
locations, `rm -rf`+migrate real folders, no self-copy) + `~/.wine-vst` auto-detect in
link-vst-shared. Uninstall now quarantines same-stem siblings (`.so`, `.dat`…) + all `.aux`
and no longer dies on missing wine/applications dirs (two `errexit`+`pipefail` find guards).
Verified end-to-end in an isolated fake home (stub wine installs through the symlink,
uninstall leaves unrelated plugins), deployed + `cmp`, pty smokes. Also vendored
OSX-For-Omarchy as a new `macos-vm` module (`osx-kvm-installer.sh` + TUI + launcher,
self-locating, upstream bindings.conf step neutralized), with `setup-macos-vm.sh`
conventions-compatible (deploy, menu block, window rule, `--remove`), wired into
setup-customarchy.sh at all 7 points; fake-home idempotency + remove verified.

### 2026-09-15 — thirty-fifth round: Roadmap 3.9 — the native (bash/gum) interface is gone from both mosquito managers; the TUI is now the only interface

The move-manager and VST-manager modules are single-interface now — Roadmap 3.9 done.
Cores + dispatchers + TUIs + actions backends + setup scripts all reworked so the dispatchers
run the Go TUI with no args and the shared core's `main "$@"` with args (guards + inline
`ui_*` primitives replace the deleted `*-native` scripts and the interface-mode files);
deployed + `cmp` + pty + guard-unit smokes all green. **Open:** Roadmap 3.10 (TUI colors
auto-adapt to the active Omarchy theme). Nothing committed.

---

### 2026-09-15 — thirty-fourth round: GitHub public-link cleanup (the repo URL now appears everywhere "private GitHub repo" used to say it) + the persistent thin black right/bottom bars inside superfile's foot window finally root-caused and painted away

Condensed from the previous top entry: README/`bootstrap.sh` no longer reference a private
repo (real clone/raw URLs, fork-override note). Superfile’s foot residual dark bars were
root-caused as `width/height mod cell` slivers painted in foot’s own near-black background
inside superfile’s lighter theme (no way to fit a tiled window to the char grid) — fixed by
making the foot background match superfile’s current theme `full_screen_bg` (resolved from
`config.toml` at launch-command time; graceful when unreadable); re-run of `setup-superfile.sh`
updated `bindings.lua` SUPER+SHIFT+F etc. and the `.desktop`. Gotcha recorded: that setup
sources `gui-run.bash`, which relaunches into a foot window when stdin/stdout aren’t ttys
(the agent shell “hangs” while the script actually finishes there). Status: verified by
reasoning + function-level tests; no desktop screenshot possible this session.

---

### 2026-09-15 — thirty-third round: user's UI-list round 1/2 — menu-entry icons fixed (keyboard backlight + music) and the TUIs' clickable-but-inert options are now properly greyed out and unreachable

User's UI-list round 1/2: menu icons + greyed-out disabled TUI options. Icons: live
`~/.config/omarchy/extensions/omarchy-menu.jsonc` gets `trigger.hardware.keyboard-backlight`
`""`→`\uf11c` and the duplicated `trigger.music` entry deduped (orphan block near the top of
the file removed) with its icon `\uf09e1`→`\uf001` (both glyphs verified in the active
CaskaydiaMono Nerd Font); the repo mirror in `setup-ableton-move-converter.sh`
`menu_block()` updated to match, no `\uf09e` refs left. Grey-out: `tui-kit` gained
`PickerItem.Disabled` — a new `pickerDelegate` wrapping `list.DefaultDelegate` renders them
from a new `StyleDisabled` (fg 238, no selection border), `Init`/`navDirection` clamp the
cursor off them, Enter on one returns nothing (name-collision hurdle fixed: type
`pickerDelegate`, singleton var `defaultPickerDelegate`). Move-manager TUI's
`mainMenuItems()` sets `Disabled` on "Open the Move Manager and convert" while
"checking…"/not-connected. Verified: `go vet` clean (tui-kit + both tui-go), `go mod tidy`
(x/ansi now a direct dep), behavior proven via a throwaway Go driver (`/tmp/opencode/picktest`:
down/End skip the disabled row, first-row-disabled clamps to the next enabled one, all-enabled
lists unchanged, grey = ANSI 38;5;238/90), binaries rebuilt + redeployed to `~/.local/bin/`
and the tracked repo copies, `cmp` identical, pty smoke-tested. Recovered from a stray
`.m.XXXXXX` left in `~/.local/bin/` by an exploratory build command (deleted). Open: Roadmap
3.9 (drop native interfaces) and 3.10 (adopt theme colors). Nothing committed.

---

### 2026-09-15 — thirty-second round: a real live-usage bug report on both TUIs (move-manager's Bitwig conversion silently short-circuiting, superfile falling through to nautilus, an unbounded Readme box, slow move-manager startup, oversized windows) — root-caused and fixed all of it, plus new superfile editor-on-arrow-right support

The user's live-usage report on both TUIs, root-caused and fixed: the Bitwig conversion
silently short-circuiting — `ui_confirm()` is stubbed `return 1` in the TUI actions script
by design, but `lib-move-manager-core.sh` still held TWO primary `ui_confirm` calls
("already an Ableton instance open — close it?", "open in Bitwig?") that auto-declined,
aborting the flow before Ableton even relaunched and never actually opening Bitwig; fixed by
splitting each into a Go `Confirm` screen (`scrAbletonConflictConfirm`,
`scrBitwigOpenConfirm`) + a mechanical callable (`close_configured_ableton_and_wait()`,
`finish_bitwig_open()`), the phase result carried via a global `PHASE1_ALS_RESULT` + an
`ALS_PATH=` sentinel the actions wrapper prints (native unchanged, still gates via its own
real `ui_confirm`). Superfile: a deliberate cancel (Esc/q) no longer falls through to the
GTK/nautilus picker. `tuikit.Info` rebuilt around a bounded, scrollable `viewport` with
`SetSize` (root cause: the Readme had one 156-char unwrapped line and the modal had no
width/height bound). Superfile embedded IN both TUIs' own terminals via `tea.ExecProcess`
(`spf --chooser-file`), external-window spawn left native-only; Move Manager gained the same
file-picker Settings toggle VST Manager already had ("for install" dropped from the label),
plus a real "pick a file manually" path for an empty bundle scan. move-manager-tui startup
no longer gated behind the ~1.5s status probe — menu pre-filled with a "checking… 🟡"
placeholder, status updates in place. Both TUI Hyprland float rules shrunk 875×600→700×480
(verified by screenshots, not guessed). Superfile's right/enter now opens text files
(md/py/conf/…) in a configured editor in a NEW terminal (executables keep the existing
"run in new terminal" path; editor set via a new prompt in `setup-superfile.sh`, defaulted
by detecting nvim/nano/-custom command — deliberately NOT superfile's own `e` binding, which
suspends in the same terminal). Known limitations confirmed not fixable here: pixelated video
preview (foot lacks the Kitty graphics protocol) and text non-wrapping in tiled windows
(superfile's internal resize quirk). Verified: `bash -n`, `go build`/`go vet`, real `.md`
open test (`nvim` confirmed via `ps aux`), idempotent re-runs; Ableton/Bitwig conflict and
hand-off paths reasoned through but not exercised end-to-end. All redeployed to
`~/.local/bin/` and `cmp`-verified; not committed until the user explicitly asked.

---

### 2026-09-15 — thirtieth round: cleaned up after a different tool (opencode) moved `superfile`/`ableton-move-converter` into `scripts/apps/` and got stuck mid-task

The user pasted an opencode status report claiming a module move
(`scripts/{superfile,ableton-move-converter}` → `scripts/apps/{superfile,ableton-move-converter}`,
`scripts/apps/omagrab` deleted) plus two unfinished superfile features (black-border fix,
"Enter on an executable → new terminal"), reporting it had started looping and asking me to
finish, verify, and commit. The move itself was real and clean; the two features were not
actually implemented — built both (a `superfile_launch_cmd()` helper launching `foot -a
org.omarchy.superfile -o pad=0x0` directly, since `xdg-terminal-exec` has no flag passthrough;
and a `[open_with]` wrapper mapped for bare/`.sh`/`.bash`/`.appimage`/`.run`/`.bin` files that
relays an executable into a held-open foot window, `xdg-open` otherwise). Found and fixed a
real bug the move introduced that opencode never hit: the move-manager TUI's `go.mod`
`replace` directive still pointed one level too shallow at the shared `tui-kit` module —
`go build` would have failed outright on a fresh checkout. Fixed every stale path reference in
both READMEs and the root README (module table + tree diagram). Hardened `JOURNAL.md`'s own
maintenance contract (rules 7–8): explicitly the compaction target for any tool now, plus a
concrete anti-drift protocol (stop after two failed attempts, grep every occurrence of a
repo-wide change before starting, verify before claiming done). Verified: `bash -n` repo-wide,
`go build`/`go vet` clean, `setup-superfile.sh -y` idempotency-tested live twice,
`superfile-open-exec` functionally tested on both an executable and a non-executable file,
`--status` clean on every touched orchestrator/module script, no secrets in the commit.
Committed (`1a2bca5`) at the user's explicit request — see the thirty-first round for one
follow-up correction (the `omagrab/` folder).

---

### 2026-09-14 — twenty-eighth round: VST Manager gained a superfile-vs-default file-picker Settings toggle (install-on-demand, no relaunch ever needed), and the separate `superfile` module's real bug fixed — it never touched Omarchy's own SUPER+SHIFT+F keybinding (hardcoded to `nautilus`, bypassing xdg-mime entirely), so setting the XDG default had no user-visible effect. Root cause: Omarchy's own binding launches `nautilus` by name, ignoring xdg-mime entirely — fixed via an idempotent `hl.unbind()`/`o.bind()` override block in `~/.config/hypr/bindings.lua`, applied live (`hyprctl reload` clean) but not confirmed by an actual keypress. VST Manager's new Settings item toggles the picker with auto-install-in-terminal when superfile is missing, never needs a relaunch (the preference is re-read fresh every use), and uses `spf --chooser-file` once selected. `wtype`-based keystroke testing dropped entirely this round (carried over finding: it leaked into the user's real input); all verification was screenshots + direct backend/`go vet` testing.

---

### 2026-09-14 — twenty-seventh round: real root cause of the Go TUI's JSON crash found and fixed (`jq` without `-c` pretty-prints, breaking line-by-line parsing), Esc vs. "No" no longer conflated in confirms, VST Manager gained a Settings submenu, both TUIs' views centered, VST Manager's Readme wired in

User reports: "unexpected end of json input sur move manager convert a move set" + "close
the menu" should say "quit mosquito x manager". **Root cause, found by rereading my own
earlier terminal output**: every `jq -n` call in both new `*-actions` scripts (list-
bundles, list-plugins, etc.) omitted `-c`, so `jq` pretty-printed each JSON object across
4 lines — but Go's `decodeJSONLines` reads *one JSON value per line*, so it tried to
parse a lone `{` as a complete value → exactly "unexpected end of JSON input". Reproduced
by rerunning `list-bundles` directly and noticing the multi-line output (visible in an
earlier tool result this session, only recognized as the bug on a second look). Fixed by
adding `-c` to every `jq -n` call in both actions scripts (`sed`, verified each now emits
one compact object per line). Also hardened both TUIs' JSON fetchers regardless: empty
output no longer reaches `json.Unmarshal` blind — `fetchStatus` treats it as a transient
skip-and-immediately-retry (never leaves the very first screen blank), `fetchText`/
`fetchPath` (VST Manager) report which action produced it instead of the bare decode
error. **"Quit mosquito Move Manager?"**: move-manager's Go TUI said "Close the menu?"
where the original bash said "Quit mosquito Move Manager?" — fixed (VST Manager's own
Go TUI already had the right text, "Close the mosquito VST Manager?", matching its own
bash original — no change needed there).

**Esc vs. "No", audited across every confirm** (per explicit request — "regarde les
autres prompts... pour t'assurer de la coherence"): `tuikit.ConfirmResultMsg` gained a
`Canceled` field, distinct from `Yes:false` — Esc/Ctrl+C now always means "back out",
never "press the No button", matching Picker's and TextInput's own convention. This was
a real, reachable bug in VST Manager's install flow: "Install into the default wine
prefix?" uses its No button for a genuine alternate path (new prefix), not cancel — Esc
there was wrongly read as that same "No, new prefix" choice instead of aborting the
install. Fixed there; the other 7 confirm sites across both TUIs already happened to
treat Canceled and explicit No identically (same outcome either way), so behavior is
unchanged for those, just made explicit.

**VST Manager gained a Settings submenu** (native *and* TUI, matching move-manager's
existing structure): "Switch interface" moved out of the flat main-menu list into
`menu_settings()` (bash, new function, `main_menu()`'s own behavior otherwise untouched)
/ a new `scrSettings` screen (Go), each with just "Switch interface" + "Back" for now.

**Both TUIs' views centered**: every screen's rendered panel is now wrapped in
`lipgloss.Place(w, h, Center, Center, …)`, and pickers/runners are capped to a natural
content size (`contentSize()`, ~76×22 max) instead of being stretched to fill the whole
terminal edge-to-edge — confirmed live (clean centered screenshots, both modules).

**VST Manager's Readme wired into the TUI** (it was fetched via an already-written but
never-called `fetchText`/`readme-text` action — a real gap from last round): Plugin list
now always appends a "📖 Readme" entry, matching the native interface's own "Readme is
always last" convention, backed by the fix above so an empty fetch degrades gracefully.

**Note on testing method**: stopped using `wtype` for synthetic keystroke tests partway
through this round — evidence surfaced (stray text appearing in the user's own next
message) that keystrokes sent this way were not reliably scoped to the intended test
window and could leak into the user's real input. Verification for this round's changes
relied on screenshots only (centering, Settings menu placement), not live keystroke
navigation — reasonable for what changed (mostly layout/wiring, covered well enough by
the build + `go vet` + direct actions-script testing already done), but means the Esc-
fix and Settings submenu's actual keyboard interaction should still be confirmed by the
user directly.

---

### 2026-09-14 — twenty-sixth round: both TUIs rewritten as real Go + Bubble Tea programs, replacing bash+`gum` entirely

Rewrote `mosquito-move-manager-tui` / `mosquito-vst-manager-tui` as compiled Go programs
(`charmbracelet/bubbletea`+`bubbles`+`lipgloss`, same stack as the user's own `omagrab`,
confirmed via `gh api`), after the user asked to eliminate "terminal biases" (Ctrl+C
misbehaving, background messages disrupting the interface) and explicitly chose a full
rewrite over a bash/gum patch. New shared `scripts/tui-kit/` component library (picker,
confirm, input, toast, a command-streaming `runner`); the bash cores keep 100% of real
business logic unchanged, Go owns every interactive decision and calls a new thin
non-interactive backend per module (`*-actions`) once a decision is made. One persistent
`tea.Program` per session makes Ctrl+C structurally safe (an ordinary key case, never a
special-cased handler, nothing left half-drawn). `go` installed via `mise`, build-time
only. Verified: clean builds, both real setup scripts run end-to-end, both TUIs launched
live through the real dispatcher and screenshotted (move-manager thoroughly; VST
Manager's flows are more complex and got comparatively less exhaustive testing).
**Turned out to have a real, reachable bug** (the JSON crash, and an Esc/No mixup) —
see the entry above, found and fixed the very next round. Separately, per explicit
request: AbletonOSC's Preferences instructions made precise (Input/Output stay at None,
no checkboxes — it's OSC, not MIDI), and `mega-caffeine` no longer prompts to enable
ultra-save when it's already on.

---

### 2026-09-14 — twenty-fifth round: the TUI's blank-window bug, actually root-caused (`gum choose` corrupts its own render whenever anything runs concurrently with it) and fixed by dropping the main menu's idle-timeout; setup script gained its own "Switch interface" option

Round 23's fix (direct `foot`/`xterm` spawn) was incomplete — live re-diagnosis (paired
clean/broken screenshots) found `gum choose` itself breaks whenever *anything* runs
alongside it (external `timeout`, gum's own `--timeout`, a manually backgrounded job) —
a real gum/bubbletea bug, not this repo's launch mechanism. Fixed by dropping the TUI
main menu's idle-auto-exit (`ui_select --timeout`), the only concurrent-process user in
this codebase; VST Manager's TUI never had this feature so was never affected. Confirmed
live, repeatably. **Fully superseded next round**: both TUIs were rewritten in Go/Bubble
Tea shortly after, making the entire class of gum-rendering bugs moot — see the entry
above.

---

### 2026-09-14 — twenty-fourth round: new `zen` module (Zen Browser config seeding: extensions, settings, chrome, into the active profile), omagrab backup integration, restore-time "deps by module" auto-install, KeePassXC-Browser added to the seed for password autofill

New `scripts/browsers/zen/` module (`setup-zen.sh`) deploys a seed (4 XPIs including
the newly-added KeePassXC-Browser, settings, chrome theme) into the **active** Zen
profile (detected from `profiles.ini`), preserving hand-tweaked files unless `-y`;
wired into the orchestrator end to end (`MODULES`, `st_zen`/`run_zen`/`un_zen`,
`module_state`). Backup now also picks up omagrab + the live Zen config. New
restore-time "deps by module" mechanism: each module declares a `deps` file
(one pacman package per line), collected and auto-installed on restore. Password
autofill: researched and recommended KeePassXC-Browser (native Zen + native KeePassXC,
not Flatpak — the clean path), then implemented at the user's request by adding the
XPI to the zen module's seed. All `bash -n` clean, `setup-customarchy.sh --status`
confirms `zen` ✓.

---

### 2026-09-14 — twenty-second round: fixed the TUI launch (both modules) by replacing the ad-hoc `gui-run.bash` self-respawn with Omarchy's own `omarchy-launch-or-focus-tui`, removed parenthesized interface labels from the switch-confirm prompt

Fixed two reported issues from the split (parenthesized confirm-prompt labels; the TUI not
launching at all) by moving the terminal-or-not decision into the dispatcher and routing
through Omarchy's `omarchy-launch-or-focus-tui`. **Superseded next round**: this mechanism
turned out to reliably corrupt gum's interactive rendering (blank/partial window) — see the
newer entry above for the root cause and the real fix (a direct `foot`/`xterm` spawn).

---

### 2026-09-14 — auto-disable ultra-save on AC plug-in + dismiss the stuck "Time to recharge!" toast + recalibrated `backlight`

Fixed two live user-reported bugs. `backlight` brightness buttons were dead at low levels
because the raw→actual calibration table (`scripts/display/backlight`) was stale — recalibrated
`_A`/`_R` from a fresh monotonic sweep on `amdgpu_bl1`, verified +5%/40%/100%/5% now move actual
brightness as expected. The "Time to recharge!" toast never auto-dismissed on AC plug-in because
Omarchy's stock battery service sends it as `critical` (duration 0, never auto-expires) — added
`onAcPlugged()` to `custom.power` `Panel.qml`, which dismisses the toast and also auto-disables
ultra-save on AC (separate user request). Both re-deployed/hot-reloaded and verified live.

---

### 2026-09-13 — VST Manager UX batch + power panel ultra-save coupling + mx-master right-click fix

Four user-reported `vst-manager` polish items, all edited in
`scripts/apps/audio-stack/vst-manager`, `bash -n` clean, and **re-deployed** to
`~/.local/bin/vst-manager` (`cmp` identical). (1) **Readme in the empty plugin list** —
`plugin_list()` previously showed only a "No plugin found in …" notice and returned, so the
Readme (how to point DAWs at `~/VST/{VST2,VST3,CLAP}`) was unreachable before any install.
Now the same loop runs with the prompt text swapped to a precise first line ("No plugin found
in $VST_ROOT/{VST2,VST3,CLAP} — the Readme below explains where DAWs must point:"), and the
Readme stays last/selectable. (2) **List not updating after install** — root cause:
`scan_plugins()` used `find -maxdepth 3` while the install-time new-file detection
(`install_plugin`) had no depth cap, so any installer that wrote below depth 3 (classic VST3
bundles `Vendor/Plugin.vst3/Contents/x86_64-linux/…`) was copied to `~/VST` but never shown in
any scan-driven list (plugin list, uninstall, reconcile). Dropped the depth cap to match
install; verified in `/tmp/vstsand` that a depth-5 `.so` is now found and that the empty list
still surfaces the Readme. (3) **`.aux` auto-detection** — the "Installation finished? (wine
window closed)" confirm (redundant now that `wine` runs synchronously) is replaced by a scan
of `$wine_prefix/drive_c` + the three `~/VST` folders for `*.aux` files **newer than the pre-
install snapshot**; when found, they're listed and a confirm offers to delete them (each
deletion gets an `ok`), then the normal new-VST-file registration proceeds. (4) **Truncated
"Manage prefixes" prompt** — `ui_select` line was clipped by the overlay
("…Management history is at the bottom):"), shortened to just "Manage prefixes — move a plugin
to another prefix:". Separately this session: **`custom.power` panel** — `setProfile()` in
`scripts/power-management/omarchy-plugins/custom.power/Panel.qml` now runs
`power-helper ultrasave off; omarchy-powerprofiles-set ac|battery <profile>` (instead of only
the profile set) when ultra-save is on and the chosen plan isn't power-saver; the live
`~/.config/omarchy/plugins/custom.power/Panel.qml` was re-copied to match. And the
**mx-master right-click launch** failed because `scripts/mx-master/setup-mx-master.sh` wasn't
executable — `chmod +x` applied (it was `-rw-r--r--`, so the file manager's "Run as a program"
refused).

### 2026-09-12 — new `mx-master` module — Logitech MX Master (any model) thumb gesture button → SUPER via logiops

New module `scripts/mx-master/` (registered in `setup-customarchy.sh`: `MODULES`,
`st_mx_master`, `run_mx_master`, `un_mx_master`, `MXMASTER_DIR`, status dispatch ~L424,
run dispatch ~L1892; `scripts/README.md` + root `README.md` module tables). What it does:
installs `logiops` from the AUR if missing (`yay -S --noconfirm logiops`, user-level; root
parts use `sudo` internally — `install` to `/etc/logid.cfg`, `systemctl enable --now logid`),
then writes `/etc/logid.cfg` mapping the **thumb gesture button (cid 0xc3)** to
`KEY_LEFTMETA` as a **momentary** `Keypress` (hold = SUPER held, tap = SUPER tap). Because
logid only applies the device block whose `name` matches the connected device's HID++ name
exactly (`Device::_getConfig`, `devices.count(name)`), the config writes **one block per
known MX Master model name** (`MX Master 3S`, `Wireless Mouse MX Master 3`, `MX Master 3 for
Mac`, `Wireless Mouse MX Master 2S`, `Wireless Mouse MX Master` — TESTED.md in upstream
v0.3.5), so any model works with no detection needed; `MX_MASTER_NAME` overrides to a single
block. The generated file carries the marker `mosquitOmarchy-mx-master` (idempotent:
rerunning replaces the whole managed file), and a pre-existing user config is backed up once
to `/etc/logid.cfg.bak` and restored by `--remove`. `--status` reports package/config/service
plus which configured models are physically connected (proper case-based matching via
`connected_mx()` reading `/sys/class/hidraw/*/device/uevent` HID_NAME — fixed from a first
draft that substring-grepped and wrongly marked the base "Wireless Mouse MX Master" as
connected when an MX Master 3 is present). Defaults are overridable through the environment
(`MX_MASTER_BUTTON`=0xc3, `MX_MASTER_KEY`=KEY_LEFTMETA, `MX_MASTER_NAME`). Everything but the
thumb button is left untouched (no smartshift/hires-scroll change). Fully function-tested in
a sandbox (`/tmp/mxws`) with stubbed `install`/`systemctl`/`sudo`/`yay`: install → generated
config with all 5 model blocks, rerun idempotent (still 5 blocks), `--status` correct
(real machine's MX Master 3 marked ●, base model ○), `--remove` disables service + removes
config. `bash -n` clean on script + orchestrator. Not deployed/built as a desktop entry (it's
a system daemon; invoked via the orchestrator's module picker like `touchpad`); the user runs
`setup-customarchy.sh` and picks `mx-master`, or `sudo bash scripts/mx-master/setup-mx-master.sh`.

Also re-verified the separate report "the 'No plugin found in …' prompt should offer OK, not
Yes/No": already satisfied in the deployed `~/.local/bin/vst-manager` (== repo `scripts/apps/
audio-stack/vst-manager`): GUI path uses `ui_info` (mosquito.confirm with `okOnly:true`) at
vst-manager L931, the `warn` at L889 is only the CLI one-shot `status_report` path. No change
needed.

---

### 2026-09-11 — `ableton-move-converter`: twelfth round — pre-flight Ableton/Bitwig conflict detection, 5-minute cap on the post-handoff wait, found Bitwig's `.desktop` entry has no file-open argument, and discovered 4 stale zombie processes from before today's renames

Added active (`ensure_ableton_not_already_open`, at the Ableton-launch moment — closes and
relaunches fresh if Settings' configured install is already open, leaves a different
unconfigured edition alone) and passive (`ensure_daw_apps_closed_before_convert`, gates only
the Bitwig route in `convert_flow()`) conflict checks. Found and fixed a second live
`pgrep -f` self-match false positive in the new `bitwig_running()` (same comm-filter fix as
`ableton_pids()` previously). Capped Bitwig's post-handoff save-wait at 5 minutes
(`MAX_WAIT_BITWIG_SAVE`). Root-caused (very likely) "Bitwig opens on an empty project":
alone among every app's `.desktop` entry on this system, Bitwig's `Exec=` line has no
`%f`/`%F`/`%U`/`%u` placeholder and its `MimeType=` list has no `.als` entry — added a
fallback notification with the exact path. Found 4 stale zombie processes (old, pre-rename
binary path, 19+ hours old) — flagged to the user, not killed (superseded by the 13th
round's single-instance enforcement, see below — though note that mechanism only matches the
*current* `$SELF` path, so these specific old-path zombies still need a one-time separate
cleanup). `bash -n` clean, deployed, unit-tested piece by piece — not exercised end-to-end
against real running apps.

---

### 2026-09-14 — `ableton-move-converter` AND `audio-stack`: twenty-first round — both modules split into a shared core + native/TUI interfaces with a live-switchable stable dispatcher, the TUI draft turned into a real, fully-functional implementation, `ensure_confirm_plugin()`'s staleness bug fixed

The largest single round of this whole saga: a real architectural change applied identically
to **both** modules that have an interactive menu (`ableton-move-converter` and
`audio-stack`'s VST Manager), per an explicit "make both ultra-coherent — same install, same
interface pattern" request, plus turning last round's throwaway `gum` draft into the real,
shipped thing.

**Architecture** (identical in both modules): each 2000+-line monolithic script was split
into a shared core (`lib-move-manager-core.sh` / `lib-vst-manager-core.sh` — all business
logic, sourced but never run directly) plus two thin interface scripts implementing the same
small set of UI primitive functions against different backends:
- **`*-native`**: the existing native Omarchy overlay (`mosquito.confirm`,
  `omarchy-menu-input`/`-select`), zenity/tty fallbacks — extracted verbatim from the
  original monolithic scripts, byte-for-byte identical behavior.
- **`*-tui`**: a genuinely new, real implementation via `gum` (`choose`/`confirm`/`input`),
  not a mockup — sources `gui-run.bash` first (same mechanism the install scripts already
  use) so it always has a real terminal to render into, spawning one itself when launched
  from the Omarchy Trigger menu.
- A **stable dispatcher** keeps the original public name (`mosquito-move-manager` /
  `vst-manager`) and is the *only* file any launcher (the Omarchy menu entry, a keybinding,
  typing the command by hand) ever needs to point at — it reads a one-line preference file
  and `exec`s straight into whichever interface is active. Per explicit request, this avoids
  both bad alternatives: a heavier merged script deciding at runtime, and needing to rewrite
  the launcher's Exec= line on every switch. The dispatcher itself never changes.

**The split correctly separated true UI primitives from things that only looked
interface-specific**: `notify()`/`notify_dismiss()` (move-manager) don't actually branch on
which interactive UI is active at all — moved into the shared core rather than duplicated,
after noticing this partway through. `is_tty()` also stays in the core (a plain, literal
fd-0 check, correctly true for both "real terminal, native fallback" and "TUI, always a real
terminal via gui-run.bash" contexts, false only for "native, headless from the Omarchy
menu"). `ui_confirm`/`ui_input`/`ui_select`(/`ui_info` for VST Manager) are the real,
irreducible per-interface primitives. A `ui_ready_or_die` hook (interface-specific: native
checks tty/omarchy-menu-select/zenity, TUI checks `gum`+tty) replaced each core's old
native-only readiness check in `main()`'s tail.

**A real bug found and fixed mid-refactor**: `$SELF`, previously computed via
`${BASH_SOURCE[0]}` *inside* what's now the shared core, would have resolved to the core
file's own path once sourced rather than the actual entry-point script — broken for the
"pick a file" notification's `--exec` relaunch and for `enforce_single_instance`. Fixed by
having each entry-point script set `$SELF` itself (its own resolved path) *before* sourcing
the core. `enforce_single_instance()` (move-manager only — VST Manager has no equivalent)
was generalized to treat native and TUI as the same logical app: matches either
`$NATIVE_BIN` or `$TUI_BIN` as an exact `/proc/<pid>/cmdline` argv field (same strict
matching discipline as before, just against two candidate paths instead of one).

**`switch_interface()`** (added identically to both cores' main menu/Settings): asks to
confirm via the (also extended, see below) `ui_confirm`, writes the mode file, then relaunches
the *other* interface **fully detached** (`setsid ... < /dev/null &`, `disown`) before this
process exits outright. The detached, non-inherited stdin/stdout is deliberate: it lets the
freshly-started process's own `is_tty()`/`gui-run.bash` logic reach the right conclusion on
its own regardless of which direction the switch goes — switching to native from inside a
real terminal must *not* inherit that terminal (or it would wrongly take the plain-tty
fallback instead of the overlay); switching to TUI from a headless native launch must *not*
inherit a non-tty stdin either (gui-run.bash already handles spawning its own terminal
correctly given that).

**`mosquito.confirm` extended** (again — `noLabel`/`yesLabel` were already added two rounds
ago) is unchanged this round; `ui_confirm()` in both native scripts already carries that
contract. VST Manager's `ui_confirm()` didn't have it before this round — added to match
move-manager's exactly, both for `switch_interface()`'s own "No" / "Yes, reboot" labels and
for general cross-module consistency.

**A real deployment bug caught by testing, not assumed away**: `mosquito-move-manager-tui`
sourcing `gui-run.bash` via `../gui-run.bash` (correct for the repo layout) broke once
deployed to `~/.local/bin/`, where no `gui-run.bash` exists one level up. Fixed two ways:
the TUI scripts now check their *own* directory for `gui-run.bash` first (falling back to
the repo-relative path), and both install scripts now deploy `gui-run.bash` itself
alongside everything else (idempotent, `cmp`-gated like every other deployed file here).
Caught by actually running `mosquito-move-manager-tui --version` post-deployment rather than
assuming the split "obviously" worked — it didn't, the first time.

**`ensure_confirm_plugin()`'s staleness bug fixed**, per explicit request: it used to skip
entirely once the destination directory existed ("already present"), meaning a repo update
to `Confirm.qml` never got redeployed on a later re-install — flagged, not fixed, last
round; this is very plausibly why the deployed and repo copies had already drifted apart
before that got caught. Now always re-copies (`cp -a`, cheap and idempotent either way).
Applied to **both** modules — VST Manager's install script never ensured this plugin at all
before this round (an implicit, unstated dependency on `ableton-move-converter` having
installed it first) — now self-sufficient, using the identical logic.

**Both install scripts updated to match, deliberately kept in lockstep**: deploy the shared
core + both interfaces + the dispatcher + `gui-run.bash`; ask which interface to default to,
once, only on a genuinely fresh install (checks the mode-file first — a re-install/update
never re-asks), defaulting to native under `-y`/non-interactive; `do_status()`/the
end-of-install summary report the active interface. `setup-vst-manager.sh` also gained a
proper `-y` flag (didn't parse any options before).

**The TUI draft became the real thing, not a mockup dressed up**: the previous round's
`tui-draft.sh` (every action simulated, nothing real) is deleted — superseded entirely by
`mosquito-move-manager-tui`, which runs the actual shared core, doing real conversions,
real Settings changes, everything the native interface does. `vst-manager-tui` is built the
same way from scratch (VST Manager never had a draft). README sections referencing the
draft were removed/updated accordingly.

**Verification**: `bash -n` clean across all 10 new/modified script files (5 per module).
Both modules' native/TUI/dispatcher entry points functionally smoke-tested (`--version`,
`status`) against the real repo copies *and* separately after running the real install
scripts non-interactively end-to-end (not just deploy_bin in isolation) — output identical
to the pre-split originals in every case. `ui_select`/`ui_confirm`/`ui_input`'s TUI
implementations unit-tested with a stubbed `gum` across normal-choice, tab-free-option,
cancelled, and (move-manager only) timed-out cases — all correct; `gum`'s own real flags
(`choose --header`, `confirm --affirmative/--negative`, `input --value`) were checked
against the installed `gum --help` output before use, not guessed. `switch_interface()`
tested in full isolation (fake target binaries) for both modules — confirms correctly
gate the mode-file write and the detached relaunch. Confirmed gum genuinely cannot render
without a real TTY (fails fast, exit 1) — validates why `gui-run.bash` is load-bearing here,
not optional. **Not verified**: `gum`'s actual interactive rendering and keyboard handling
(Escape/Tab/Enter) in a real terminal session — this sandbox has none; the TUI's `ui_select`
wraps `gum choose` in the external `timeout` command specifically to get an unambiguous
"timed out" exit code (124) rather than trust gum's own less-clearly-specified `--timeout`
return behavior, with a `stty sane` safety net after a timeout-kill in case SIGTERM
interrupts gum mid-render — reasoned, not observed against a real terminal. A pre-existing,
unrelated cosmetic bug was noticed (not caused by this round, not fixed): `install_menu()`'s
own status-line echo still says "Ableton Move Set to Bitwig converter" even though the
actual deployed menu entry's `label` field correctly says "mosquito Move Manager" — flagged
for a later pass.

---

### 2026-09-14 — Twentieth round: AbletonOSC auto-install (`ensure_abletonosc()`), a non-blocking Ableton-not-installed advisory, a throwaway `gum` TUI draft

Automated the AbletonOSC file placement (`ensure_abletonosc()` in
`setup-ableton-move-converter.sh`, idempotent, non-fatal if Ableton isn't installed yet) —
tested against 4 isolated scenarios then run for real on this machine, genuinely installing
AbletonOSC at the documented Wine path. Enabling it in Ableton's own Preferences remains a
manual step. Built a throwaway `gum`-based TUI draft to explore the interaction — superseded
next round by the real, fully-functional TUI (see above).

------

### 2026-09-13 — Nineteenth round: user pursuing AbletonOSC setup — removed the Settings timer UI, added a one-time reminder prompt, extended `mosquito.confirm` with custom button labels, answered 3 setup questions

Extended the shared `mosquito.confirm` Omarchy plugin (also used by `mega-caffeine`) with
optional `noLabel`/`yesLabel` payload fields, fully backward compatible — verified live
(caught the deployed copy had drifted from the repo's own source copy, re-synced both).
Removed the per-power-profile Settings timer UI (delays are now fixed constants) in favor of
the coming AbletonOSC integration; added a one-time "enable AbletonOSC" reminder prompt
instead (`maybe_show_osc_reminder()`, "OK" / "Don't show again"). Answered three setup
questions: Ableton Link isn't required for AbletonOSC, Intro should work (reasoned from
Ableton's own documented edition differences, not separately confirmed), and the real reason
AbletonOSC wasn't showing up — the `Remote Scripts` folder didn't exist yet under `Documents/
Ableton/User Library/` on this machine (confirmed by direct inspection) — documented the
exact path (automated the very next round, see above).

------

### 2026-09-13 — Eighteenth round: Ableton-only pre-flight close (Bitwig auto-focused instead of blocked/closed), per-power-profile auto-close timer, Space-bar dismissal during load, AbletonOSC `/live/startup` researched

Fixed a real `IFS=' and '` notification-join bug and used it as the occasion to redesign the
pre-flight check: Bitwig is never blocked or closed in this flow anymore, only the configured
Ableton install is — `focus_existing_bitwig()` switches to Bitwig's existing window instead
(via Omarchy's own `omarchy-hyprland-focus-app`, found after confirming this Hyprland fork
exposes neither the standard `closewindow`/`focuswindow` dispatchers nor a targetable
`hl.dsp.window.close()`). Ableton's auto-close timer became per power profile
(performance/balanced/power-saver/this project's own `ultra-save`, 15/20/30/60s defaults,
Settings submenu — since removed next round in favor of AbletonOSC, see above). Added a
background Space-keystroke sender during the load wait to help dismiss lingering startup
dialogs. Researched (found a real, concrete answer) whether AbletonOSC could give a genuine
readiness signal instead of a timer: yes, it sends `/live/startup` automatically — flagged for
a future round pending the user's own AbletonOSC install, which began the very next round.

------

### 2026-09-12 — Seventeenth round: root-caused the Ctrl+Q misfire (dropped modifier, "swap instrument" = Ableton's own Hot-Swap shortcut), consolidated the Bitwig notifications, built the `superfile` module

Root-caused a real regression from the round before: Ctrl+Q (added to reinforce
`close_ableton_window()`) was reported causing a repeated "swap instrument" action — confirmed
against Ableton's own shortcuts manual that bare "Q" is "Hot-Swap Selected Device," proving the
Ctrl modifier was dropping in transit. Removed Ctrl+Q; Super+W (WM-level, doesn't depend on
Ableton's own keymap) is the only keystroke sent since. Consolidated the Bitwig-phase
notifications from two into one (20s). Built the new `scripts/superfile` module — default file
manager (live-tested, applied) plus an optional, session-wide `org.freedesktop.portal.FileChooser`
override via `xdg-desktop-portal-termfilechooser`, after finding `ableton-linux`'s own Wine patch
routes Ableton's Save dialog through exactly that portal.

------

### 2026-09-12 — Sixteenth round: reinforced Ableton auto-close (Ctrl+Q added, later found to misfire — see seventeenth round), persistent phase-2 retries, faster polling; SuperFile feasibility researched; baseline benchmark gathered

Reinforced `close_ableton_window()` to send both Super+W and Ctrl+Q per attempt (the Ctrl+Q
addition was reversed next round once direct evidence showed its modifier was being dropped,
misfiring into Ableton's own Hot-Swap shortcut instead of quitting). Confirmed live that neither
stock Hyprland's `closewindow` nor this fork's `hl.dsp.window.close()` is a usable targeted
alternative. Phase 2 gained persistent 30s retries and a faster 2s poll. Researched (not yet
built) whether SuperFile could become the system-wide file manager including Ableton's own Save
dialog — concluded at the time that Ableton's dialog specifically couldn't be reached this way
(a conclusion corrected next round after finding `ableton-linux`'s actual portal patch). Gathered
this machine's baseline boot/idle-memory numbers as a benchmark starting point.

------

### 2026-09-12 — Fifteenth round: close window widened to 23-30s + save-dialog detection, shorter notifications, script no longer reopens over Bitwig, two new Settings options, first commit+push

Widened the auto-close window to 23-30s with a best-effort save-dialog detector that pauses
close attempts while a dialog is up (superseded by the sixteenth round's further reinforcement
— see above). Shortened notifications; dropped the redundant Bitwig fallback. Fixed
`wait_bitwig_saved()`'s 5-minute-even-after-Bitwig-closed bug and the "script pops back up over
Bitwig" bug (`BITWIG_OPENED` flag). Settings gained working-directory relocation (with merge
support) and a configurable Ableton close timer. Re-confirmed the main-menu title's "…" is
Omarchy's own unconditional overlay behavior, not this script's. First `git commit`+`push`
(`1cbbb1d`, `95f3944`) of this module's entire build-out plus other pending module work —
caught and fixed a `.gitignore` regression (dropped `SECRET-README.md` pattern) before staging.

------

### 2026-09-12 — Fourteenth round: fixed-schedule Ableton auto-close (20-25s), shorter/friendlier notifications, Settings "clear als folder", stale Wine desktop-entry cleanup, stale per-folder README fix

Dropped the adaptive title-stability close-detection for a fixed 20-25s repeated-Super+W
schedule + a single 30s "still waiting" notice (later widened to 23-30s with save-dialog
detection — see fifteenth round). Notifications reworded to exact requested text. Added
`clear_als_folder()` to Settings. Confirmed via `strings` on Bitwig's own binary that it has
zero CLI file-open support at any level. Found and fixed the real cause of stale duplicate
"Ableton Live" entries in Nautilus's Open-With: `setup-ableton.sh` used to deliberately keep
`wine-extension-*`/`wine-protocol-*` associations, some pointing at a stale pre-dedicated-
prefix install — policy reversed, cleaned up live on this machine too (10 entries). Fixed
the per-folder `README.md` (stale `move-session` name). The twelfth round's 4 zombie
processes were confirmed gone.

------

### 2026-09-12 — Thirteenth round: single-instance enforcement, idle-timeout auto-exit, 20s Ableton notification, two research-backed dead ends

Added `enforce_single_instance()` (a fresh launch kills any other running copy of this
script, Ableton/Bitwig untouched) and a 30-minute idle-timeout auto-exit for the main menu.
The single-instance matcher's first version had a real, demonstrated self-inflicted-kill bug
— `pgrep -f` substring matching killed an unrelated decoy process and took the whole test
session down with it — caught by testing before shipping, fixed by requiring `$SELF` as an
exact `/proc/<pid>/cmdline` argv field (re-tested clean: real target killed, decoy spared,
own process untouched). Added `notify()`'s `--timeout SECONDS` and used it for a 20s Ableton
notification. Researched and confirmed infeasible (not implemented): launching the `.als`
file *with* Bitwig (system MIME routes it to Nautilus) and an Ableton-side scripted
auto-save/quit handshake (the LOM's `Application` class has no such capability, confirmed
against the official reference and AbletonOSC). The 4 old-path zombies from the twelfth
round were left for a follow-up round — confirmed gone by the fourteenth round (see above).

---
---

### 2026-09-11 — Eleventh round: first confirmed real progress — title-stability readiness detection replaces the fixed settle delay, notification moved to route-selection time

Auto-close fired for the first time (previous round's pipe fix worked) but too early,
closing a still-loading project — the fixed 20s settle delay had been getting an accidental
head start from the pipe bug it no longer gets. Replaced with `ableton_window_title()`
(`hyprctl clients -j` + `jq`) and title-change polling: waits for the title to hold steady
~15s before closing, adapting to actual load time instead of guessing a fixed number. The
"opening in Ableton" notification moved to fire the instant "Bitwig" is chosen as the route.
### 2026-09-11 — Tenth round: found and fixed a real, reproduced root-cause bug in `open_in_ableton()`'s background launch (missing stdout/stderr redirect)

Read the real session log instead of guessing again after "toujours rien ne marche" — found
a ~36s gap between two log lines that should be near-instant apart. Traced to a classic bash
pitfall: `open_in_ableton()`'s three `"$cmd" &` background launches (always called as
`pid=$(open_in_ableton ...)`) had no stdout/stderr redirect, unlike every other backgrounded
launch in this module — the unredirected Wine child inherits and holds open the command
substitution's own pipe, blocking it for however long Wine takes to detach from its
inherited fds. Reproduced the mechanism in isolation (a `sleep &` with vs. without
redirection) before fixing it with `>/dev/null 2>&1 &`. Confirmed the following round to be
the real fix — see entry above for what it uncovered next (the fixed settle delay was too
short once real timing was no longer masked by this bug).
### 2026-09-11 — Ninth round: found Omarchy's own `send_key_state` dispatcher (why every wtype-based auto-close attempt was doomed) and switched .als detection to kernel-level inotify

Found, by reading Omarchy's own shipped `clipboard.lua`, that `wtype`'s synthetic keystrokes
have a documented Hyprland quirk causing them to merge incorrectly with real modifier
state — almost certainly why every Ctrl+Q/Super+W `wtype` auto-close attempt failed.
Switched to Omarchy's own `hl.dsp.send_key_state` dispatcher, validated live to accept an
explicit `window = "pid:N"` target — sends the keystroke directly to Ableton's window by
PID regardless of focus. Replaced `lsof`-based `.als` detection (fragile, dependent on
correctly guessing which Wine PID held the file) with kernel-level `inotifywait -e
close_write`, tested end-to-end with a simulated file write. Both later turned out not to
be sufficient on their own — see entry above for the actual root cause found this round.

---

### 2026-09-11 — Eighth real-usage round: root-caused the Ableton "script never comes back" hang, dropped the fragile Hyprland-focus check, active download-complete prompt in the Move Manager

Found the likely cause of the script appearing to hang after Ableton closed: it was waiting
on the `ableton-live` wrapper's own PID (which does its own post-exit housekeeping) instead
of Ableton's actual process — fixed by keying the exit condition on `is_ableton_running()`
alone. Dropped the Hyprland-IPC PID/focus check gating Super+W entirely after it never once
fired (later found why — see entry above); replaced with process-exists + a flat settle
delay + unconditional `wtype` send (this too turned out not to work — see entry above).
`wait_manager_close()` gained an active prompt the moment a Chromium download completes,
instead of only passively waiting for the window to close.
### 2026-09-11 — Seventh real-usage round: abandoned the live-redraw mechanism for a manual refresh, Super+W + lsof-tracked Ableton→Bitwig handoff, disconnect-during-Manager-use notification

Removed the previous round's `omarchy-shell`-IPC live-redraw mechanism entirely (connection
status checked once per redraw only) in favor of an explicit "Refresh connection status"
menu option — confirmed the native overlay has no Tab-key hook to bind that to instead.
`move-udev-refresh` repurposed to warn only on Move disconnect during active Move Manager
use. Ableton auto-close switched from Ctrl+Q to a Super+W keystroke (later found to still
never fire — see entry above). Rebuilt the Ableton→Bitwig `.als` handoff around `lsof`
file-descriptor tracking instead of folder-mtime guessing, after a broad-scan miss on a file
saved to `~/Downloads`.

---

### 2026-09-11 — `audio-stack`: VST Manager v0.3.0 (plugin list, groups, dedicated prefix, OSD fix, exclusions)

New user batch for the VST Manager (= the processed menu in the Omarchy launcher, plus its CLI).
All in English UI wording.

**Changes in `scripts/apps/audio-stack/vst-manager`**:
- **Plugin list** is now the **first** main-menu option (`plugin_list`): grouped by vendor
  folder, each row `name - prefix` (state log), sorted by group; a **Readme** entry is always
  last and prints where DAWs must point their plugin folders (`VST2 → $VST_VST2`, `VST3 →
  $VST_VST3`, `CLAP → $VST_CLAP`) + a note on yabridge.
- **Grouped uninstall** — options sorted by vendor folder (`plugin_group_label`, strips the
  `VST2/VST3/CLAP` prefix) and rendered as `[FakeLabs]  FakePlugin.vst3`. Plugin list uses the
  same grouping.
- **"No prefix to manage"** empty state: when no state keys, no live windows folders **and**
  no prefixes at all, the message says "No prefix to manage — …" instead of the generic
  "No plugin to manage…". All English.
- **History → "🕘 Management history"** (prompt, heading, empty-state text updated too).
- **Dedicated default prefix**: `default_prefix()` now prefers the first prefix that owns a
  tracked plugin; when nothing is installed and no prefix owns anything, it proposes
  `~/.wine-vst` (instead of reusing `~/.wine`), and the "same prefix" install path
  bootstraps it via `wineboot` + re-registers it in `WINE_PREFIXES`. User-confirmed choice
  (asked via question tool): dedicated fresh prefix, not the current first-prefix behavior.
- **Exclusion sweep**: `is_native_win_app` now also excludes anything matching
  `*witch*`, `*edge*`, `*webview2*`, `*copilot*` (witchwand.exe, all Edge/WebView2 flavors,
  Windows Copilot) from the standalone scan AND from the standalone registration that writes
  the state log. Verified: only `RealVSTApp.exe`/`FakePlugin.exe` remain offered.
- **"Launching VST Manager…" OSD**: Omarchy's `AppLibrary.launch` shows that OSD because the
  menu opens no toplevel window (`/usr/share/omarchy/shell/services/AppLibrary.qml:164`, stays
  15 s at duration 0). `/usr/share` is read-only → local fix: `suppress_launch_osd()` in
  `main_menu` closes the OSD best-effort (`omarchy-shell -q osd close`) a few times around the
  launch window.

**Verified in the pty sandbox** (`HOME=/tmp/vsttest VST_STATE_DIR=/tmp/vsttest/state`,
plugins under `/tmp/vsttest/VST/VST3/{FakeLabs,Witch Spire}`, prefix `.wine-early`):
plugin list + grouping + Readme; uninstall grouping; no-prefix empty message; management
history flow; exclusions; install flow on an empty HOME proposes `~/.wine-vst` and
bootstraps it. Deployed via `setup-vst-manager.sh`, `cmp` says deployed copy == repo
copy, `bash -n` clean. `--version` now `vst-manager v0.3.0`. Extra find during tests: the
move-history timestamp was empty (`date +%Y-%m-%d %H:%M` unquoted → "date: extra operand");
now `date '+%Y-%m-%d %H:%M'`, verified the move writes `at` into the history.

**Pending** (unchanged): root Move converter steps awaiting the user's `sudo bash
…/setup-ableton-move-converter.sh`; commit/push still not authorized; Guitar Pro font
symptom still untransmitted; `ScaleFinder.vst3` (lost via the old CrispyTuner uninstaller)
still sitting in `~/.cache/vst-quarantine/` awaiting the user's word.

---

### 2026-09-12 — `audio-stack`: VST Manager v0.4.0 (native info prompts, launch reconciliation, prefix fix, foreign-executable exclusion, setup script rename)

New user batch:

- **Readme opens in a native prompt**: `plugin_list()` is now a loop — the Readme (and each
  plugin path) opens in a pseudo-`mosquito.confirm` info card with a single **OK** button
  (Enter / Escape / click all dismiss), then comes back to the same list. Escape on the list
  returns to the main menu.
- **`mosquito.confirm` okOnly mode**: the user-owned confirm plugin
  (`~/.config/omarchy/plugins/mosquito.confirm/Confirm.qml`) gained an optional
  `okOnly:true` payload → single-button info card. Back-compatible with mega-caffeine
  (default stays No/Yes). New `ui_info()` in the manager summons it (tty → print + Enter,
  zenity fallback).
- **Empty-state feedback is now visible on the GUI**: uninstall/manage-prefixes/standalone
  empty messages no longer go to `warn` (invisible when launched from the menu — no tty).
  They use `ui_info` (native info card), which is what the user was missing before.
- **`default_prefix` no longer falls back to the first detected prefix**: when no plugin is
  tracked it now always proposes the dedicated `~/.wine-vst`, even if generic prefixes
  (`~/.wine`, bottles…) exist — the reported "proposed same prefix ~/.wine" behavior.
- **Guitar Pro added to the exclusions**: `*guitarpro*`, `guitar*pro*`, `gp[0-9]*` added to
  `is_native_win_app`.
- **Foreign executables never reach the lists anymore**: `executable_list` and the app-menu
  toggle are now driven by `state_list_standalones()` (what THIS manager registered), not a
  live prefix scan. Auto-installed/foreign programs (bottles, manual wine installs…) stay
  out of "Launch a standalone plugin" and "Manage visible executables"; `scan_executables`
  removed. Old `.desktop` toggles for now-untracked exes are left as-is (can be removed
  manually).
- **Launch reconciliation** (`reconcile()`): on every `menu` launch the log and disk are
  compared — (1) plugins listed in the log whose files are missing on disk are reported in a
  native info card ("Listed in the log but NOT on this computer"); (2) plugin files found on
  disk but not tracked are offered as a native ✓/○ checkbox list and the ticked ones get
  registered into the manager. Added to the README section.
- **Setup script renamed** `setup-vst-install-menu.sh` → `setup-vst-manager.sh` via `git mv`;
  header comment now says "Launches / installs the VST Manager". References updated in
  `setup-audio-stack.sh` (`step_vst_menu`), `scripts/apps/audio-stack/README.md`, and this
  journal.
- The user reported the same-prefix install proposed `~/.wine` and asked to empty the log:
  the fresh log was already empty (`vst-state.json` = `plugins:{}`) and the prefix fix above
  addresses the former.

**PTY-tested**: Readme loop + info card, plugin path info, uninstall empty state,
manage-prefixes empty state, exec toggle from state standalones, reconcile orphan
registration, `bash -n` clean. `--version` now `vst-manager v0.4.0`. Deployed and
`cmp`-verified SYNCED.

---

### 2026-09-11 — `audio-stack`: VST Manager v0.2.0 rewrite (state log, prefixes, no status menu) + `mosquito` search + patch discretion

New user batch, three parts:

1. **`mosquito` Omarchy search** — verified `omarchy-menu.jsonc`: `move-converter` and
   `mega-caffeine` carry the `mosquito` alias; the user confirmed `setup.winvm` and
   `keyboard-backlight` stay **excluded** ("Non, winvm est aussi exclue"). No jsonc change.
2. **Patch privacy** — wording now "Patch detected, patch now ?" in ableton / davinci /
   bitwig / guitarpro setups; removed every "NOT on GitHub / LATEST RELEASE" warning and
   gated each patch on it existing in the module folder. davinci README: "libav patch" →
   "system-codec enablement". Deleted `scripts/SECRET-README.md` and purged all mentions
   (in `archive-customarchy.sh` and `.gitignore`).
3. **VST Manager v0.2.0 rewrite** — full new file; tested in pty sandbox, deployed.

**VST Manager v0.2.0 changes** (user: "log dans le dossier du script", "manage prefixes",
"remove plugin status", "same prefix ask at install", "exclude native Windows apps",
"Escape at menu-1 = close?" confirmation):
- **Machine-scoped state log** `vst-state.json` in the module folder (script dir when
  `link-vst-shared.sh` is present, else `~/mosquitOmarchy/scripts/apps/audio-stack`),
  guarded by `/etc/machine-id` (fallback hostname); a foreign-machine log is ignored and
  reinitialised. Env `VST_STATE_DIR` overrides for tests. New `.gitignore` entry.
- **Dynamic prefix discovery** at every run: any `~/.wine*` holding `drive_c` (+
  `$AUDIOSTACK_VST_ROOT/*.wine*`), sorted. No hardcoded prefix list.
- **Install flow**: file explorer first (`omarchy-file-select` → `omarchy-menu-file` →
  zenity → tty), title "Install a plugin" without parens; asks "Install into the same wine
  prefix (default) or a new one" — new one creates `~/.wine-<name>` via `wineboot`; asks
  re-install when the state log says the plugin is already there.
- **Manage prefixes** menu (+ move + History): state keys first, fallback to a live
  `win:` scan; History button is always last and prints "plugin : from → to" lines; move
  asks for a target prefix or a new one and physically copies the wine program folder.
- **Removed the "Plugin status" menu option** (the one-shot `vst-manager status` CLI is
  kept). Option renamed "Manage visible executables in Omarchy Menu". Sweep: all
  `ui_select` calls now use `--plain`, `manage_executables` loops for multi-select.
- **Native Windows apps excluded everywhere** (iexplore, wmplayer, wordpad, write,
  notepad, mspaint, calc, magnify, osk, cmd, powershell, regedit, explorer, rundll32,
  taskmgr, control) + uninstallers.
- **Empty states warn** in every submenu ("No plugin to uninstall.", "No standalone
  executable found…", "No plugin to manage…").
- Escape at the main prompt asks "Close the VST Manager?" before exiting.

**Bugs found and fixed in pty sandbox tests**
(`AUDIOSTACK_VST_ROOT=/tmp/vsttest HOME=/tmp/vsttest VST_STATE_DIR=/tmp/vsttest/state`):
- `scan_plugins` returned 1 when a VST2/VST3/CLAP dir was absent → killed the script under
  `set -euo pipefail` (added `return 0`).
- `state_register_install` / `state_register_standalone` rewrote the whole file — now merge
  via `jq` and `unique`-dedupe the file lists.
- Install copy path duplicated the format dir (`VST3/VST3/FakeLabs/…`) — `rel` is now
  relative to the target dir.
- `plugin_key` normalised: `VST3/Vendor/Plugin.vst3` keys as `Vendor/Plugin` regardless of
  the format folder.
- `<<< "$(state_list_keys)"` injects an empty trailing line → empty menu option in Manage
  prefixes (guard `[[ -n $k ]]`).
- **Data-loss bug**: uninstall said "quarantined" but `cp -a` to a nested target failed
  (missing parents) and `rm` still deleted the file — now `mkdir -p` + only `rm` on a
  successful copy, with a warning otherwise.
- **Orphan logic bug**: `wine_source_of` returned success even with no output, so every
  plugin looked like it "had a source and lost it" → everything got quarantined on
  uninstall. Now returns non-zero when nothing found (callers rely on that).

Deployed via `setup-vst-install-menu.sh`; `cmp` says deployed copy == repo copy.

**Pending**: root Move converter steps still awaiting the user's `sudo bash
…/setup-ableton-move-converter.sh`; commit/push still not authorized; Guitar Pro font
symptom still untransmitted (glyphs vs DPI).

---

### 2026-09-11 — `audio-stack`: VST Manager v0.1.0 built and deployed

Built and deployed the original **VST Manager** (`scripts/apps/audio-stack/vst-manager`):
Omarchy overlay UI + tty/zenity fallbacks; status, install (wine + diff-snapshot +
yabridge sync), uninstall (quarantine to `~/.cache/vst-quarantine/`), standalone wine
launch, executable menu visibility toggles. Fixed during build: `scan_wine_programs`
word-splitting ("Program Files" phantom entry), orphan detection quarantining native `.so`
files (snapshot `had_source` first), install UI now prefers `omarchy-menu-input` (zenity
hung headless), removed dead `find_wine_home`, added `wine_uninstaller_for()`, disabled
`winemenubuilder`. Superseded by v0.2.0 above (state log, dynamic prefixes, no status menu
option, native-app filtering, multi-select execs, Escape-close confirmation).

---

### 2026-09-11 — `ableton-move-converter`: sixth real-usage round — PID-based Ableton detection, `pgrep -f` false-positive fixed, diagnostic logging

Sixth real-usage session. User gave a detailed account of Ableton's real multi-stage Wine
startup (dialog → splash → real window), explaining why class-string matching was unreliable.
Switched `wait_ableton_window()`/`close_ableton_window()` to **PID/process-tree matching**
(`focused_window_is_ableton()` walks `/proc` PPID chains, waits for stable focused-window
PID over 4 seconds). Found and fixed a real `pgrep -f` false-positive: a shell process
*mentioning* the search strings matched — now filtered by process name (`ps -o comm=`).
Added `info()`-level tracing and a user-facing `notify()` toast on the previously-silent
"no .als detected" path in `open_ableton_route()`. Not exercised against real hardware —
changes are reasoned from the user's descriptions, flagged plainly. Chromium policy fix and
udev-dependent live redraw still await the pending `sudo` re-deploy.

---

### 2026-09-11 — Fifth real-usage round: dropped notify-on-connect for live-redraw-while-open, fixed wrong-Ableton-version launches, custom webapp icon

Dropped the standalone "notify when the Move connects" feature entirely (toast, Settings
toggle, detection while the script isn't running) per explicit user request, replacing it
with a live-redraw-while-open mechanism (`move-udev-refresh`, via `omarchy-shell shell hide
omarchy.menu` — later clarified as not the actual source of day-to-day dot responsiveness,
see entry above). Rewired `open_in_ableton()` to always launch through the `ableton-live`
wrapper instead of sometimes invoking the raw `.exe` directly, after reading the wrapper's
real version-discovery logic — likely the actual fix for "wrong Ableton version" launches
(later found to need further work on window/focus detection, see entry above). Replaced the
webapp icon with a user-provided custom asset. Removed literal "…" from a menu option label
(the title bar's own "…" is QML-injected, unfixable). Investigated the "no notification
during Ableton" complaint — ruled out DND-suppression and a notification collision as
causes but couldn't diagnose further without live access.
---

### 2026-09-11 — Fourth real-usage round: checkmark labels, real-color Ableton icon, Ctrl+Q auto-close, version extraction, Escape-quit confirmation, legacy-marker regression fix

Switched converted-file labels from a leading emoji + "!" to a plain green "✓" suffix
(matching Omarchy's own checked-item convention) and found/fixed a real regression: a
pre-rename marker format (`-converted`, no type) was silently unrecognized, causing at least
one already-converted set to look unconverted and get duplicated — added recognition plus a
durable `converted.log` audit trail independent of the filename marker. Replaced the white
silhouette webapp icon with a full-color extraction of Ableton's own real app icon (later
replaced again with a custom user-provided asset, see entry above). Switched Ableton
auto-close from a Hyprland window-close dispatch to a Ctrl+Q keystroke via `wtype` (the
dispatch didn't reliably reach Wine apps as a real close request). Added real Ableton
version extraction (PE VERSIONINFO via `pefile`, "Live Suite 12.4.5") replacing the raw
`.exe` display. Made Escape at the main menu ask for quit confirmation instead of exiting
silently. Added the Chromium `CommandLineFlagSecurityWarningsEnabled` policy key. Confirmed
the main-menu title's dot+address can't be truly right-aligned (native overlay renders it as
one left-aligned proportional-font string, no alignment control exposed).

---

### 2026-09-11 (earlier) — Third real-usage round: full rename to "mosquito Move Manager", USB-only auto-detect, Settings-only Ableton version, type-specific converted marking, first Hyprland auto-close attempt

Dropped the network-reachability watcher entirely (systemd unit + script, USB-only
auto-detect via udev, connect+disconnect). Moved Ableton-version picking into Settings-only.
Fixed a premature-notification-dismiss bug (`manager_running()` matching on the Chromium
profile's `--user-data-dir=` instead of an unreliable host-string). Introduced type-specific
converted-file marking (`-converted-<type>`) and a first icon fix (white silhouette,
superseded by the entry above). First attempt at Ableton auto-close via Hyprland's
`hl.dsp.window.close()` dispatch — later found unreliable and replaced with a real Ctrl+Q
keystroke (see entry above). Renamed the main script/binary and every user-facing label to
"mosquito Move Manager" (scope clarified via `AskUserQuestion`: module directory/id and the
other helper binaries deliberately kept their names) — later refined to exclude the webapp's
own display name (see entry above). Investigated and root-caused the menu flicker as a
structural `omarchy-menu-select`/`omarchy-shell` platform limitation, not fixable from this
module.

---

### 2026-09-10 — `ableton-move-converter`: real-usage bug reports + Settings, auto-detect watcher, icon system (~15 items)

Follow-up session after real usage of the previous rewrite. Added a Settings menu
(auto-detect notify toggle, show-converted toggle), a USB+network auto-detect background
watcher (`move-connection-watcher`, systemd user unit — **since fully removed, see the entry
above**), a small notification-icon vocabulary (🟢🔴◎🔳✅⚪), fixed a real root cause of
"not snappy" (`detect_move()`'s unbounded ping resolution, wrapped in `timeout 1.5`), the
Chromium insecure-download flag, manager-close/set-before-route flow simplification,
converted-sets hide/rename (`mark_converted()`, later made type-specific — see entry above),
narrowed the `"mosquito"` menu alias, and root-caused/fixed a real `localsearch-extractor`
crash (libmodplug MIDI-parsing bug, mitigated via Tracker exclusion). Fully verified via pty
and function-extraction harnesses; deployed `~/.local/bin` + live `omarchy-menu.jsonc`
re-synced. The install flow itself (systemd watcher enable) was deliberately left for the
user to run, not auto-installed.

---

### 2026-09-10 — `ableton-move-converter`: large UX/flow rewrite (7 items from one user message)

Removed the just-added single-key shortcuts (user: not useful — later fully reverted anyway,
see next entry's item 1 for the full story). Added a manual file picker for when no set is
found (`pick_file_manually()`, `--pick-file`/`FORCE_PICK`). Renamed the Manager menu label
to "...and Convert". Added a 🟢/🔴 connection dot + address to the main-menu title, with the
Manager option blocked and labeled when disconnected (fixed a latent bug in `detect_move()`
along the way: it pinged a hardcoded "move.local" regardless of the configured address).
Manager-close no longer unconditionally offers to convert — only if something was actually
downloaded; otherwise a clickable notification. Made the Move Manager webapp single-instance
(kills any existing one on the same profile before launching) and persisted its download
folder + "don't ask" straight into the Chromium profile's own Preferences (works even
launched outside this script). Fully reworked the Ableton→Bitwig handoff: stopped
pre-renaming the bundle to a fake `.als` (turned out to be an unnecessary workaround — the
real `ableton-live` wrapper has no such extension restriction, confirmed by reading it) —
opens the original bundle directly, detects wherever the `.als`/`.bwproject` actually gets
saved (bounded scan of common folders), copies it into the target with a "-backup" suffix
only if it wasn't saved there directly, and Bitwig is never auto-closed. Folder renamed to
"Ableton Move Projects" with a one-time migration. Added a `"mosquito"` omarchy-menu alias
to every custom mosquito function (later narrowed, see next entry). Found and fixed a real
bug while testing: a captured-via-`$(...)` helper was calling `ok()` (stdout) instead of
`info()` (log-file only), polluting its own return value.

---

### 2026-09-10 — Two renames: module → `ableton-move-converter`, whole project → `mosquitOmarchy` (incl. GitHub)

Renamed the module (`move-ablbundle-converter` → `ableton-move-converter`, folder + files via
`git mv`, every reference incl. deployed bins and the live `omarchy-menu.jsonc` — purged a
stray duplicate JSON key while in there, fixed `move-udev-notify`'s wrongly-tracked file
mode) and the whole project (`Omarchy_Custom_Scripts` → `mosquitOmarchy`, local dir moved,
GitHub repo renamed via `gh`, remote URL updated, every functional path and doc reference
fixed — deliberately leaving the `Omarchy_Custom_Scripts_*` Hyprland/menu block-delimiter
markers alone for now, assigned to Roadmap step 5, since renaming those touches several
untested modules' live config). Added the README's "vibe-coded" disclosure. Caught and fixed
a self-inflicted bug: the rename `sed` pass had corrupted a historical Log entry below.
Also resolved the user's question about Claude's GitHub co-author attribution: rewrote the
two affected commits' messages (tree hashes verified identical, content untouched) and
force-pushed, after explicit confirmation — see git history for exact commands if needed
again; a local-only safety branch `backup-before-strip-claude-attribution` is still around.

---

### 2026-09-10 — Move Manager webapp icon: root-caused and fixed (self-heal), but I destroyed the real icon file while testing

The Move's favicon is a legacy `.ico` that `omarchy-webapp-install` (an Omarchy system
script) always saves under a `<id>.png` filename regardless of real format; some loaders
cope, ImageMagick's icon decoder doesn't. Added `normalize_webapp_icon()`/`fetch_webapp_icon()`
to `ableton-move-converter` — re-encodes to a real PNG (GdkPixbuf, falls back to
ImageMagick), self-heals (re-fetches) whenever the icon file is missing/invalid, called on
every `ensure_webapp()` run. Unit- and integration-tested (fake local HTTP server standing
in for the device) — works. While debugging *before* writing the fix, destroyed the real
deployed icon file with an unguarded `mv` directly on the live file (not a copy) — the
original bytes are gone, device wasn't reachable to re-fetch. Removed the broken file rather
than leave a valid-but-wrong stand-in (which would have silently blocked the self-heal
forever). Current state, confirmed by the user: launcher shows a generic gear/cog
placeholder — expected, will self-heal with zero manual steps the next time the Move is
connected and "Open the Move Manager" is used.

---

### 2026-09-10 — `ableton-move-converter`: single-key shortcuts on every menu prompt (Priority 1)

Added optional per-option shortcut keys to `ui_select()` (format
`display<TAB>key<TAB>value`, backward compatible with the old 2-field form). Main menu now
shows `a`/`m`/`c`/`q` (address/manager/convert/close); the MIDI-vs-Bitwig route prompt shows
`m`/`b`. On a real terminal (`is_tty`), ≤9-option prompts read a single keystroke with no
Enter required (mirrors the pre-existing Ableton-version-cycle `read -n1` pattern); Ctrl-D is
explicitly caught (`read -n` disables canonical mode for that call, so a real EOF arrives as
a literal `0x04` byte rather than a read failure — mapped back to the existing "stdin
closed" contract). In the native Omarchy overlay (`omarchy-menu-select`), the subtext now
shows the shortcut key, and the return value is looked up by matching the display label
(instead of trusting the returned subtext, which is now the key, not the value).

**Investigated and confirmed as a hard limit** (not fixable from this repo): the native
overlay (`/usr/share/omarchy/shell/plugins/menu/Menu.qml`, an Omarchy system file) has no
true instant-keystroke-select mechanism — every typed character does a plain substring
filter over label+subtext, still requiring Enter/click afterward. So the shortcut key is
visible and useful there as a filter hint, but only the TTY path gets genuine one-key select.

**A more ambitious fix was attempted and reverted**: tried to make a stray Enter typed right
after the shortcut key (habit) not leak into the next prompt, via a one-byte lookahead stash
shared between `ui_select`/`ui_confirm`/`ui_input`. Discovered `ui_select` is always called
as `opt=$(ui_select ...)` — a command substitution, i.e. a **subshell** — so any variable it
sets is lost the moment it returns; the stash could never reach the caller. Reverted rather
than ship something broken. Accepted trade-off instead: a genuinely fast keystroke burst
(e.g. typing `q` then `y` for the following confirm, no pause) works correctly; a *habitual*
extra Enter right after the shortcut can leak into the next prompt and read as a blank
answer there (confirms default to the safe "no" direction — never destructive, just an extra
retry cycle).

**Verified**: `bash -n`; `--demo`; pty tests (`script -qec`, `TERM=xterm`) for numeric
select, keystroke select, invalid-key reprompt, Ctrl-D/EOF (including the subtlety that
`printf '' | script ...` is a racy way to simulate EOF for a pty — a real Ctrl-D byte in the
input stream is the correct way to test it), fast-typed bursts, and the route prompt. All
clean, no hangs, no regressions. Repo file and `~/.local/bin/ableton-move-converter` kept
in sync (`cmp` after every edit, per the standing session convention).

---

### 2026-09-10 (earlier) — `move-session` → `move-ablbundle-converter` rename, v0.3.0

> Note: the module was renamed *again* the same day, `move-ablbundle-converter` →
> `ableton-move-converter` (see the top entry) — this entry describes it under the name it
> had at the time, not the current one. Wherever this entry says `move-ablbundle-converter`,
> read it as "the module, then named that."

Renamed the module (4 files: main script, `move-bundle-to-midi`, `move-udev-notify`, setup
script; `99-ableton-move.rules` and `README.md` moved with it) and rebuilt it around native
Omarchy prompts (`ui_select`/`ui_input`/`ui_confirm`, tty-vs-overlay dispatch via `is_tty()`)
instead of `gum`. Added the Move Manager webapp (dedicated Chromium profile via
`move-manager-webapp`, downloads land straight in `<projects>/ablbundle`) and MIDI export
route (`--midi`). Fixed a launch bug where a flagless, stdin-closed launch (Omarchy menu
trigger, `execDetached`) errored out instead of opening the native overlay menu — non-tty
with a GUI available now correctly goes to `main_menu()`. This work (plus the webapp +
Chromium policy JSON + `setup-keybindings.sh`/`setup-customarchy.sh` wiring) is committed
locally but **not yet pushed** (last pushed commit before this cycle: `ae7d609`; two
unrelated Reaper commits have landed on top since, `c518875`/`b9bc627`, already pushed).

**Follow-up 2 (same day)**: Round-2 visual/UX pass — (a) wallpaper regenerated in ANSI Shadow (`live mode`, red #ff1a1a, 1920×1080, Pillow+pyfiglet); (b) "mosquito" inside the accent box now picks text color by accent luminance (black/white); (c) subtitles ("vst manager" / "move manager" / "live mode manager") rendered in `small_shadow` figlet (compact 3-4 rows); (d) TUI picker centers the entire `▶ + title` row, nothing left-aligned; (e) window size set to `foot -W 80x30`; (f) "Manage Live Mode" → "Live Mode Manager" rename (confirm_ok, menu jsonc, aliases, setup script); (g) Move Manager `headerFor` returns just `<host> <dot>`; (h) live-mode theme fallback `Achraff` → `achraff-67`, detached theme switch + restore use `bash -lc`; (i) root-caused: `omarchy-restart-terminal` hook was killing inline OFF script's terminal — now detached + self-healing (up to 30 retries); (j) deployed the freshly-built user-owned TUI binary to `~/.local/bin/` (previous root-owned copy blocked user updates).

**Follow-up 3 (2026-09-17)**: Round-3 multi-issue batch — six user complaints, all root-caused. (1) **Live Mode Manager didn't launch** because `appsPicker` was a zero-value `tuikit.Picker` whose inner `list.Model.delegate` was nil until the apps screen opened; `model.Update` called `appsPicker.SetSize` on every `WindowSizeMsg`, dereferencing the nil delegate inside bubbles' `updatePagination` and crashing on the first paint — fixed by initializing appsPicker in `initialModel()` plus adding a `ready bool` guard in `tuikit.Picker` (SetSize/Update/View short-circuit when not ready), so any future zero-value picker is inert. (2) **Theme change didn't work** because `LIVE_THEME_NAME="Live"` but `omarchy theme set` lowercases its argument and writes the lowercase name into `theme.name` — so every check against `Live` silently failed (12 s of wasted self-heal retries, and `restore_previous_theme`'s gate never fired, leaving the theme stuck on live/black) — fixed by setting `LIVE_THEME_NAME="live"` (lowercase) and routing the self-heal loop's comparison through the same variable. (3) **Scratchpad didn't auto-fill** because `qpwgraph_addr()` matched `.class == "qpwgraph"`, but the installed qpwgraph is `org.rncbc.qpwgraph.desktop` → Hyprland reports `class = "org.rncbc.qpwgraph"` (Wayland app_id from the desktop file); the match returned nothing and the parking timed out — fixed in all three jq selectors (live-mode, live-mode-watch×2) to match the union `("qpwgraph" OR "org.rncbc.qpwgraph" OR "org.pq_graph.Qpwgraph")`. (4) **Subtitles unreadable** because the `live mode manager` small_shadow art is 85 columns wide and the panel is 72 → art clipped at right edge → garbled glyphs — fixed by `MosquitoSubtitle(s, maxW)` falling back to a plain accent-colored bold label when the art would overflow (and same for unknown keys). (5) **TUI windows badly opened, text not centered** because bubbles' default `Spacing()` reserves an extra row per item, so at the picker's actual height only ~half the items fit and bubbles emitted spurious `••••` pagination dots plus blank rows between options, AND `renderCentered` emitted a trailing newline per item (doubling the gap) — fixed by `delegate.SetSpacing(0)` when no item has a Sub and `fmt.Fprint` (no trailing newline) in renderCentered; items now read as a contiguous aligned column. (6) **Hide options that don't fit, accessible by page dots, reinforce display** — contentSize's home-screen branch was double-subtracting the banner reserve (computed `h = m.h-6` then subtracted the banner again), producing a picker of only `m.h-16` rows at the configured 80-wide × 30-tall window with an avalanche of bogus page dots — fixed by computing picker h as `m.h - homeBannerReserve() - 1` directly (no double-subtraction) and shrinking the dispatcher window to `foot -W 80x24`; the live manager's 8 main items all show contiguously on one page with zero spurious dots, sub-screens with many items still paginate honestly. Cross-cutting: all three TUI binaries rebuilt gofmt-clean and user-owned in `~/.local/bin/`; `Picker.ready` makes any future forgotten-init zero-value picker inert; `bash -n` clean on both `live-mode` and `live-mode-watch`.

**Follow-up 4 (2026-09-17)**: Three more visual / behavioural complaints addressed.

  1. **"L'icône de café met trop de temps à s'arrêter à la désactivation"** — root cause: race in `cmd_off`. The watchdog (`live-mode-watch`) re-creates `~/.local/state/omarchy/indicators/stay-awake` on every tick in `reassert_state` (lines 83–84), and `cmd_off` previously only ran `pkill -f live-mode-watch` (which doesn't wait) before removing that file in `stop_sleep_management` → between the rm and the watchdog actually exiting, a watchdog tick could TOUCH the file back into existence → red coffee icon in the bar stayed on long after deactivation (or until the next session). **Fix**: `stop_watchdog()` now both (a) waits up to 3 s for the watchdog process to fully exit (`pgrep` loop) and (b) **drops the active flag immediately** — `rm -f "$ACTIVE_FLAG"` — because the watchdog's loop condition is `while is_active; do … done`, so as soon as the flag is gone its next iteration check fails and `reassert_state` never runs again. Net effect: the red coffee icon disappears within a fraction of a second of `live-mode off` exiting, not after the next 5 s watchdog tick. Defensive duplicate `rm -f "$ACTIVE_FLAG"` at the end of `cmd_off` is now a no-op but kept for clarity.

  2. **"Ajoute une ligne de couleur au-dessus de l'écriture pour agrandir légèrement le cadre coloré autour de mosquito"** — root cause: `BoxedMosquito` rendered only the 6-row art on the accent background; the colored frame was exactly the art's height with no breathing room. **Fix**: `BoxedMosquito` now sandwiches the art between two solid accent-colored strips (one above, one below) of the same width as the rendered art's framed width (art width + 1-space padding on each side). The framed title block goes from 6 rows to **8 rows** (1 strip + 6 art + 1 strip), making the colored frame visibly taller and the title a clearer anchor at the top of every manager. Strip width is computed at render time from the actual art so it always matches the boxed width — no risk of misalignment if the art ever changes.

  3. **"Je veux pouvoir voir clairement le titre à l'ouverture, même si cela implique de cacher une partie des options dans une autre page"** + **"le reste du titre (vst manager, live mode manager, move manager) doit être dans la même police que mosquito"** — two parts.

     - **Title always visible / items paginate honestly**: with the new 8-row boxed frame the home-screen header reserves 15 rows instead of the previous 10. Updated `headerRows = 15` (and `narrowHeaderRows = 4`) in all three managers (`apps/ableton-move-converter/tui-go/view.go`, `apps/audio-stack/tui-go/view.go`, `live-mode/tui-go/view.go`). At `foot -W 80x24` the live manager's home screen now shows the full framed title + subtitle + 4 items + honest `••` pagination (the remaining 4 items live on page 2 — the user's explicit request: "cacher certaines options / descendre vers le bas / bubbletea affiche des points de pages"). At 100×30 everything fits on one page. No more empty space at the top, no more clipping of the title, no more bogus dots.
      - **Subtitles in the same font as mosquito**: `subtitleArt` map split into `subtitleArt` (ansi_shadow — the SAME font the boxed mosquito label uses) and `subtitleArtSmall` (small_shadow fallback). New ansi_shadow art baked in for all three subtitles: "vst manager" (62 cols), "move manager" (62 cols), "live mode manager" (68 cols, after pyfiglet width-1000 forced single-row rendering of each word). `MosquitoSubtitle(s, maxW)` now tries ansi_shadow first; if that art would overflow the panel, it tries small_shadow; if that would also overflow, it falls back to a plain accent-colored bold label. Result: at panel widths ≥ 92 (100-wide foot window), the audio manager renders "vst manager" in the actual same ansi_shadow font as the boxed mosquito header; at 80-wide windows the wider subtitles still fall back to small_shadow or plain, never clipping.

**Follow-up 5 (2026-09-17)**: Five visual / behavioural complaints — all fixed and rebuilt.

  1. **"Les sous-titres [...] sont moches, écrits-les tous dans une nouvelle police [Small patorjk font] dans la couleur de l'accent du thème et bien centrés"** — switched from `small_shadow` to patorjk's "Small" font for all three subtitles (vst manager / move manager / live mode manager). `MosquitoSubtitle(s, maxW)` now tries the Small-font art first; if that would overflow the panel it falls back to a one-line spaced variant (`subtitleArtTiny`); if even that's too wide it falls back to a plain accent-colored bold label. Net result: every subtitle renders in the same compact outlined "Small" style the user picked, in the active theme's accent color, centered in the panel, never clipped — replacing the previous `small_shadow` (which mixed outlines with shadows and looked inconsistent with the boxed "mosquito" ANSI Shadow above). Art strings baked in via pyfiglet (font="small"), with `\`` ``/` and `_` properly escaped for Go source.

  2. **"Centre les textes 'plugin list' / 'install plugin from file' / 'close' dans TOUT les managers"** — root cause: bubbles' `DefaultDelegate` has built-in `Padding(0,0,0,2)` for `NormalTitle` and `Padding(0,0,0,1)` for `SelectedTitle`; my delegate was using those styles unchanged, so each rendered title got 1-2 extra invisible columns of left padding and the rows ended up stair-stepping (short rows left-aligned, long rows left-shifted, all at different columns). **Fix**: `tuikit.pickerDelegate` now owns `maxRowW` (computed at `NewPicker` time as `max(item_width) + 3` for the indicator slot). The delegate pads every shorter row with leading spaces to `maxRowW` before centering, AND strips the default styles' left padding (`Padding(0)` on all four styles + `Border(...)` set to no-sides on the SelectedTitle/NormalTitle chain). Net effect: every option's visual centre lands in the same column regardless of title length — "Plugin list" (11 chars), "Install a plugin from file" (26 chars), "Settings" (8 chars), and "Close" (5 chars) all share a single centred column instead of stair-stepping from left to right.

  3. **"Ouvre tout les TUI dans une fenêtre un peu plus grande par défaut, garde le même ratio"** — bumped all three dispatchers' `foot -W` from 80×24 to 100×30 (exact same 10:3 ratio preserved, just larger). Files: `scripts/live-mode/live-mode` line 769, `scripts/apps/ableton-move-converter/mosquito-move-manager` line 52, `scripts/apps/audio-stack/mosquito-audio-plugin-manager` line 44. At 100×30 the panel inside is wide enough to render every subtitle (incl. live mode manager's 76-col small_shadow art) without falling back to the plain one-line label; everything fits one page at the larger size.

  4. **"Pourquoi les plugins VST wine [...] visibles dans Ableton mais pas dans Reaper et Bitwig natif ?"** — investigated the install + bridge chain: `install_plugin()` correctly creates the symlink (`link_prefix_to_vst`) BEFORE running the wine installer, so DLLs land directly in `~/VST/{vst,vst3,clap}`; `post_install()` runs `yabridgectl sync` AND `link-vst-shared.sh` after the install; `~/.wine/drive_c/Program Files/{Common Files/{VST3,CLAP}, Steinberg/VSTPlugins}` are all symlinked to the shared folders; `yabridgectl status` confirms the chain is in place. The actual gap: `yabridge-host-32.exe: <not found>` — only the 64-bit yabridge chainloaders are installed; any 32-bit Windows VST can't be bridged to a native Linux DAW (Bitwig/Reaper), but appears fine inside Ableton's own 64-bit wine prefix. No code change here — flagged for the user as a host-package gap to fill (`omarchy-add yabridge-host-32` or whatever their distro's equivalent is); the manager's install + bridge steps are doing the right thing.

  5. **"Tu dois revoir la séquence auto close d'Ableton : détecte l'OSC, envoie la bonne fonction à la fermeture et envoie barre espace plein de fois pendant le lancement, jusqu'à la détection du OSC (l'OSC d'Ableton peut arriver jusqu'à 30s après lancement)"** — overhauled `lib-move-manager-core.sh`'s launch/close sequence. New helper `ableton_osc_ready()` (uses bash's `/dev/tcp/127.0.0.1/11000` — no extra dep) returns 0 the moment AbletonOSC's Control Surface script is listening on its default OSC port (the real readiness signal — "AbletonOSC: Listening for OSC on port 11000" in Live's status bar). `send_space_during_load` (the background job launched as soon as Ableton's process is up) now floods Space at 0.5 s cadence (was every 2 s — the user explicitly asked for "barre espace plein de fois") and stops the moment OSC becomes ready, the close-attempt window begins, OR 30 s elapsed (whichever lands first), with a clear log line at every transition. The close function itself (`close_ableton_window` → `hl.dsp.send_key_state({ mods = "SUPER", key = "W", window = "pid:N" })`) was already correct — kept as-is, with the new OSC context logged before each attempt so the user can see whether OSC came up before the close attempts started.

  + **"Renforce les fonctions cancel via Esc"** (received as a separate clarification during this round) — root-cause: Esc on the home screen of both Move Manager and Audio Manager was pushing a "Close?" confirm before quitting — but `ctrl+c` on the same screen quit directly. Inconsistent, and forced an extra confirmation step on what should be a clean cancel. **Fix**: `scrMain` in both managers now treats `PickerResultMsg{Canceled: true}` (i.e. Esc) identically to ctrl+c — `m.quit = true; return m, tea.Quit`. The `scrQuitConfirm` screen still exists, but only as the destination of the explicit `Close` menu item. Beyond the home-screen inconsistency, the Esc/Enter handlers on every Runner-bearing screen were reworked too — the old pattern was `Esc cancels runner but stays on screen until runner is done; only then does Esc pop`. New pattern: **Esc cancels (if still running) AND pops back to the previous screen immediately**, so the user is never trapped on a half-drawn waiting view they've already dismissed. Enter still requires the runner to be done before continuing (no accidental skips). Affected screens (move): `scrSuperfileInstalling`, `scrAbletonClosing`, `scrBitwigOpening` (Esc quits the TUI here since Bitwig is the terminal step), `scrConverting`/`scrWorkingDirRunning`, `scrManagerWait`. Affected screens (audio): `scrSuperfileInstalling`, `scrUninstalling`/`scrInstalling`/`scrMoving`/`scrPluginsRootMigrating`. Move's `scrOscReminder` had a latent bug where Esc silently fell through to "proceed with conversion" — now Esc drops back to the conversion log without starting the Ableton route. Live Manager had no changes here (its Esc/cancel path was already correct from Follow-up 3's appsPicker upfront-init fix).

  Cross-cutting: all three TUI binaries (`mosquito-live-mode-tui`, `mosquito-move-manager-tui`, `mosquito-audio-plugin-manager-tui`) rebuilt gofmt-clean, deployed to `~/.local/bin/` with user ownership, in sync with the in-repo binaries. `live-mode` + `lib-move-manager-core.sh` deployed. `bash -n` clean on every script touched. `go build ./...` clean on every Go module. Headless `WindowSizeMsg → View` smoke tests pass for all three managers at 100×30. No desktop-only verification possible from this shell — the OSC/scratchpad/launch-flow fixes need a real AbletonOSC-enabled session to confirm end-to-end.

**Follow-up 6 (2026-09-17)**: Big visual / behavioural reinforcement batch — universal-layout rule applied everywhere, item-centering depth, Tab no-wrap, Cancel fix, uninstall tree, Bitwig/Reaper plugin paths, OSC deploy on version change. 1. **Universal layout rule** — every screen now uses `tuikit.FrameScreen(w, h, title, body, shortcuts)` which pins the title at the top, vertically centres the body in the area between the title and the shortcut bar, and pins the shortcuts at the very last row. New `ShortcutsHint()` methods on Picker / Runner / Confirm / TextInput / Info return the per-screen hint string (built from bubbles KeyMap + SetHelpKeys extras) so the bar is identical everywhere. Home screen keeps the boxed "mosquito" header as the title; every other screen gets an accent-coloured bold title (e.g. "Settings", "Pick a set", "Working…") at the same pinned position. 2. **Tighter subtitle art** — `BoxedMosquito` now ends with its bottom accent strip + a trailing newline so the subtitle sits flush against the box (no extra blank gap), and `header()` in all three managers drops the redundant `"\n"` between box and subtitle; the boxed-frame-plus-subtitle reads as one compact block. 3. **"(Wine)" removed** — the 5th main-menu item "Windows VST Plugins (Wine)" became just "Windows VST Plugins" everywhere (display, picker title, screen title). 4. **Live Mode Manager Enter broken on non-thermal rows** — root cause: both `m.picker` and `m.appsPicker` were always fed every `KeyMsg` from `Update`, so pressing Enter on a non-thermal main-screen row made BOTH pickers respond; the appsPicker always overwrote the home picker's `PickerResultMsg` (with the app name under the cursor, e.g. "kDrive"), so the model's actual `apply(value)` got called with the wrong value and silently fell into the `default` branch. Fix: only feed the message to the picker whose screen is on top of the navigation stack (`switch m.top() { case scrMain: m.picker.Update(msg); case scrApps: m.appsPicker.Update(msg) }`). 5. **Multi-select Tab/Down no-wrap** — Tab on a multi-select picker now toggles the current item AND advances the cursor down by one (skips disabled items) so a rapid-fire Tab-Tab-Tab session naturally progresses through the list. Down arrow no longer crosses page boundaries (cursor stops at the bottom of the visible page); Up arrow no longer crosses the other way. The user's complaint: "le curseur retourne à la première valeur pour faciliter la sélection et ne pas avoir à redescendre toute la page" — fixed. 6. **Uninstall tree (folders)** — `list-uninstallable` now emits each plugin with `kind` (`folder` for `win:` wine install folders, `plugin` for individual plugin files) and `parent` (the wine folder the plugin was installed into, or empty for standalone). The Go side reorganises these into a tree: each wine folder row first with a `▢` outline icon, then its sub-plugins indented below, then standalone plugins at the end. Tab on a folder row toggles every sub-plugin (▢→✓ or ▣→○, never partial — the user's "select the whole installer" gesture is one keystroke). Selected folder → uninstalls the whole installer in one shot (the wine folder's `uninstall.exe` removes every plugin file the installer dropped). Selected sub-plugins → only those files. 7. **VST manager README** — removed the "These are the shared folders the manager fills on install" line from the readme-text JSON (`mosquito-audio-plugin-manager-actions`) and the bash-side `lib-audio-plugin-manager-core.sh` Readme screen (both had the same stale paragraph; the user explicitly flagged it as useless). 8. **Bitwig/Reaper yabridge plugin visibility** — `setup-audio-stack.sh` now (a) writes `~/.config/environment.d/mosquito-vst-paths.conf` exposing `VST_PATH`, `VST3_PATH`, `CLAP_PATH` for every native Linux host that respects the env vars (Ardour, Carla, LSP-aware DAWs), (b) rewrites Reaper's `vstpath=` in `~/.config/REAPER/reaper.ini` to include `~/.vst`, `~/.vst3`, `~/.clap` (Reaper's own default lists `~/.vst3` but NOT `~/.vst` or `~/.clap`, so Windows-VST2 yabridge chainloaders were invisible), (c) adds a new `step_bitwig_plugin_paths` reminder step that detects whether Bitwig's `~/.config/Bitwig Studio/settings.xml` references any of the yabridge drop targets — if not, prints the exact Preferences → Plug-ins → "Folders for VST Plug-ins" instruction to add `~/.vst / ~/.vst3 / ~/.clap` (Bitwig has no CLI for plugin folders). 9. **OSC tip prompt fits** — `scrOscReminder`'s confirm text was one long 380-char line that wrapped unpredictably across the screen; rewritten with explicit newlines so every line fits inside the 100-wide window cleanly. 10. **OSC deploys on Ableton-version change** — `select-ableton-version` (the Settings menu item that picks which Ableton install to use) now calls a new `deploy_abletonosc` function that clones https://github.com/ideoforms/AbletonOSC into the prefix's `User Library/Remote Scripts/AbletonOSC/` if not already present (brand-new Ableton installs / fresh prefixes don't ship with OSC). Same logic that `setup-ableton-move-converter.sh` already had at install time — extracted to `lib-move-manager-core.sh` so both the installer AND the runtime Settings picker reuse it. 11. **`.als (beta)` route renamed** to `.ablbundle to .als auto converter (beta)` in `scrRoutePick` (the user explicitly asked for the longer label so the auto-converter is unmistakably distinct from the Ableton→Bitwig path). 12. **Don't kill Bitwig if user closes the script** — the move-manager dispatcher never explicitly closes Bitwig (Bitwig is treated as a user-managed external app), so this rule was already satisfied; documented in the comment for `BITWIG_OPENED=true` in the core. Cross-cutting: all three TUI binaries + `lib-move-manager-core.sh` + the audio manager core + `setup-audio-stack.sh` + `mosquito-move-manager` + `mosquito-move-manager-actions` rebuilt / re-deployed to `~/.local/bin/` with user ownership. `gofmt -w` clean across the Go tree, `bash -n` clean across the bash tree (modulo the pre-existing `$kind` unquoted in `lib-audio-plugin-manager-core.sh:1403`, untouched).

**Follow-up 7 (2026-09-17)**: Big layout + correctness pass WITH the actual yabridge root cause found and fixed live on the machine.

  1. **Yabridge root cause (the "plugins invisible in Reaper/Bitwig" mystery)** — there were THREE generations of share-root config coexisting: `~/VST/{VST2,VST3,CLAP}` (uppercase, EMPTY, still registered in yabridgectl), `~/VST/{vst,vst3,clap}` (lowercase, what the plugin manager core scanned), and the REAL shared root `~/Music/Audio Plugins/{vst,vst3,clap}` (where the wine prefixes' `Common Files/{VST3,CLAP}` symlinks point, where Windows installers actually land, and what Reaper's default vstpath mentions). yabridgectl was syncing EMPTY dirs → **zero chainloaders ever produced** → nothing for any native Linux host to load. Fixed everywhere by one `resolve_vst_root()` (prefers `AUDIOSTACK_VST_ROOT`, else the root that actually contains plugin files, else `Music/Audio Plugins` in the same order) replicated identically in `setup-audio-stack.sh`, `link-vst-shared.sh`, and `lib-audio-plugin-manager-core.sh`. `setup-audio-stack.sh` also removes the stale `~/VST/*` yabridgectl registrations (`yabridgectl rm`; note the subcommand is `rm`, not `remove`) and re-adds the real ones. Applied LIVE: `yabridgectl rm ~/VST/*`, added `Music/Audio Plugins/{vst,vst3,clap}`, ran sync — output "Finished setting up 2 plugins (2 new)" (CrispyTuner + ScaleFinder chainloaders in `~/.vst3/yabridge/Plugin Alliance/`). Speaking honestly to the user about what THEY still must do interactively (Bitwig's plugin folders have no CLI in this fork of the setup): open Bitwig → Preferences → Plug-ins → "Folders for VST Plug-ins" → add `~/.vst`, `~/.vst3`, `~/.clap`; in Reaper rescan (the reaper.ini `vstpath` update is now live — `~/.vst`+`~/.vst3`+`~/.clap`+Music/Audio Plugins are on it). New `~/.config/environment.d/mosquito-vst-paths.conf` exposes `VST_PATH/VST3_PATH/CLAP_PATH/LV2_PATH` for every other host.

  2. **Pre-existing `lib-audio-plugin-manager-core.sh:1403 syntax error`** — my own earlier edit had left a dangling `$'` at the end of the readme `ui_info` string (an unterminated ANSI-C string broke bash parsing 200 lines downstream). Closed properly (`...\n'` with a trailing newline inside the string, all quotes balanced). `bash -n` clean — finally.

  3. **Rename to "audio plugin manager" everywhere including the opening subtitle** — `subtitleArt["audio plugin manager"]` (Small font, 84 cols, generated at build via pyfiglet, fits the 92-col panel; falls back to `subtitleArtTiny`'s spaced one-liner when narrower). The subtitle key `"vst manager"` kept as an alias in the map for any stale call site, and tiny variants for all four names updated (the earlier edit had accidentally eaten two tiny lines — restored). Audio TUI call sites pass `"audio plugin manager"`.

  4. **Live theme following** — every TUI re-stamps its colors while running: new `tuikit.ThemeTickMsg`/`ThemeWatchCmd()` (2 s poll) + `tuikit.ApplyTheme()`. Wired in all three managers' `Update()`. Crucially, made all component colors resolve AT RENDER TIME from the package-level vars so ApplyTheme recolors live: pickerDelegate builds the row styles from `ColorAccent`/`AdaptiveColor` each frame (no more baked `SelectedTitle.Foreground` capture); `Picker.View` re-stamps `p.list.Styles.Title` from the live `StyleHeader`; `Runner.View` re-stamps the spinner style from live `StyleAccent`; `BoxedMosquito`/`screenTitle` already read the vars. Switch a theme while any manager is open → colors change on the next frame.

  5. **Live Mode Manager buttons actually work now** — root cause (the "only the thermal row reacts" report): `Update()` fed BOTH `m.picker` and `m.appsPicker` every `KeyMsg` — the apps picker always overwrote the home picker's `PickerResultMsg` (emitting e.g. "kDrive" instead of "close_apps"), so `apply()` fell through to no-op. Fix: only the picker on TOP of the nav stack gets the message.

  6. **Cursor preserved across row-label rebuilds** — `apply()`/`adjustThermal()` (live) now capture `m.picker.Index()` before rebuilding the picker and `SelectIndex()` after, and audio's `rebuildPluginPicker()`/`rebuildUninstallPicker()` do the same. The user's complaint "changer un setting ne doit pas renvoyer le curseur tout en haut" fixed everywhere it was reachable through a rebuild (live manager home + apps toggle, audio plugin list Tab toggle, uninstall Tab toggle).

  7. **Universal layout locks** — (a) toast now renders REPLACING the bottom shortcut hint for its 4 s life (the bar is a fixed one-row floor) — no more "toast pushes the whole interface up"; (b) move manager home: options first, "move.local ●" status BELOW them (user's explicit placement); (c) FrameScreen horizontally centers each block (title/body/bar) across the window with Align+Width before the vertical pass, and pads vertically clamped to ≥0 — no more negative-pad drift; (d) contentSize budgets are computed from the REAL title height (8 art rows + 5 subtitle rows at wide panels, 1 subtitle row narrow) minus status + bar + frame pad + spare → move/audio/live all render exactly ≤ window height (verified 29 at 100x30) — the "settings oblige plein écran" failure mode is gone.

  8. **Esc at home → quit confirm restored** — move/audio `scrMain Canceled` pushes `scrQuitConfirm` again (the user wanted the confirm restored, not the F5-era direct quit); the explicit "Close" item pushes the same dialog. Live manager gained a `scrQuit` screen + `tuikit.Confirm` field: Esc on home AND the "Close" item both land there ("Quit mosquito Live Mode Manager?"); while it's up the confirm owns every key.

  9. **OSC/auto-close rework (repensé dans l'ordre)** — the old `/dev/tcp/127.0.0.1/11000` probe was DOOMED: AbletonOSC is UDP (Live listens 11000, replies 11001), TCP can never connect a UDP daemon → the "OSC ready" signal never fired. New helpers: `osc_ping` (real OSC packet `/live/ping` + 4-byte-aligned typetag via a python one-liner on UDP with an unbound ephemeral socket — replies to whatever source port we used), `osc_quit` (`/live/application/quit` OSC datagram, zero-arg typetag spec-compliant). `send_space_during_load` now floods Space at 0.5 s until OSC answers OR 30 s OR the close window begins; the close window sends Super+W AND, when OSC is up, `/live/application/quit` as an independent second channel; if OSC comes up LATE (after the window), it gets one last-resort quit attempt. AbletonOSC is confirmed deployed at `~/.wine-ableton/.../Remote Scripts/AbletonOSC/__init__.py` on this machine. `detect_new_als`/`detect_new_bwproject` roots now include `~/Documents/Ableton` + `~/Music/Ableton` (Live's own default save-dir roots).

  10. **OSC tip text made TRUE** — both the TUI's `scrOscReminder` confirm and the bash core's `maybe_show_osc_reminder` comment no longer claim "purely informational — nothing here reads OSC yet"; they describe what OSC actually now does (readiness ping stops the Space flood early; /live/application/quit becomes a second close channel).

  11. **Row column alignment root-fixed** — `maxRowW` measured with the EXACT composition the delegate draws (lipgloss.Width through `"   " + Display`) rather than a separate `ansi.StringWidth(+3)` number; indicator rebuilt to a fixed 3-column slot (`"   "` unselected, `" " + styled("▶ ")` selected — identical visible width) so the ▶ glyph's East-Asian-Ambiguous width quirk can't shift any row by a column. Verified in a kit test: all rows share one text column.

  Cross-cutting: all three TUI binaries rebuilt gofmt+vet-clean and user-owned in `~/.local/bin/`; bash diffs synced (live-mode, lib-*, actions, setup-audio-stack); `yabridgectl list` now clean (3 real dirs, 0 stale); `bash -n` clean everywhere (the 1403 syntax error fixed). NOT verified headless: how the ▶ glyph renders in the real terminal (2 vs 1 col depends on the terminal's width Picks; the layout tolerates either), the actual OSC ping/quit behavior needs a running Live+AbletonOSC session, and the Bitwig Preferences step needs the user's click. Judged ready for the user to run the conversion once and report the log.

**Follow-up 8 (2026-09-17)**: Same-day continuation — the Bitwig SIGABRT root cause, tab-static, screen double titles, the stuck-reconcile symptom, the wine white window, and the Ableton auto-close patience overhaul.

  1. **Bitwig PluginHost SIGABRT root cause = invalid yabridge.toml** — the setup script's `apply_tweaks` (kb_* knowledge base) emits `[["*Serum*"]]`-array-of-table headers as `[["*Serum*"]]` only if the patterns are QUOTED. The actual generated files had `[["*Serum*"]]` UNQUOTED: `*` is not a bare-key character, and Bitwig's own toml++ plugin-metadata reader asserts at `parse_key()` (`Assertion 'is_bare_key_character(*cp) || is_string_delimiter(*cp)' failed`) while SCANNING yabridge.toml near the chainloaders — the exact stderr in the user's coredump with both Plugin Alliance plugins. yabridge's own loader tolerates the unquoted form (which is why this hide for months: "works in yabridge, crashes Bitwig"). Fix: the generator now writes the section as `[["*CrispyTuner*"]]` (single-quoted string inside the TOML, valid TOML) — and the three live `~/.vst*/yabridge/yabridge.toml` files were rewritten in place with the same sed so Bitwig stops crashing on rescan (no re-install needed).

  2. **Uninstall-folder UX (v2)** — per user's spec: trailing "▢" removed from the folder display entirely (that glyph was a leftover from the bash `list-uninstallable` writer); the LEADING slot is now a Nerd-Font folder icon (fa-folder-open-o `\uf115` hollow, fa-folder `\uf07b` filled — CaskaydiaCove Nerd Font ships with Omarchy so both glyphs render); selected-and-filled icon when every sub-plugin inside is Tab-checked (the "whole installer" gesture); sub-plugins NEVER render outside the expanded folder — collapsed folders show one single line "…Anturual  (→ open)", Left collapses, Right expands (the RIGHT key is free on this screen since there's no sort cycle). Tab on a folder row still toggles the whole pack (verified headless: collapsed rows=1, expanded rows=3 for a 2-plugin folder).

  3. **Tab fixes on multi-select** — reverted the F6 "Tab also advances the cursor" change; Tab toggles the CURRENT row only and the cursor STAYS where it is (the user's explicit rule). The no-wrap Down/Up (no page-crossing) stays so navigation is bounded.

  4. **"?" help** — the picker's built-in "?" key used to do nothing visible once the bubbles help line was disabled (real bug: "ca bug"). New: "?" opens a centered in-place shortcut overlay inside the Picker itself — full key list (move/enter/esc/ctrl+c + every SetHelpKeys extra like "tab select", "enter uninstall", "→ open folder"), any key closes it. No host wiring needed anywhere, layout never moves.

  5. **Duplicate titles removed** — `tuikit.NewPicker` now ALWAYS hides the bubbles built-in title row (the earlier `if header == ""` opt-in only suppressed it for the banner-bearing screens — any screen WITH a header string like "Settings" printed the label TWICE: colored in the accent title bar AND again inside the picker frame). Every screen's label comes from the single accent `screenTitle`. The plugin-list sort label moved into its screen title (`Plugin list — sort: …`); the live manager's apps screen title is now `screenTitle("Background apps — Tab toggles · Enter saves")` and its picker header became empty. The `scrQuit` screen ALSO hides the boxed home title — only the dialog on screen (matching the other managers' confirm rule).

  6. **Reconcile-orphans feedback** — the add-orphan bash action now produces visible feedback in the TUI: success prints the action's own line ("added to the manager: CrispyTuner.vst3") as an OK toast, failure as an Err toast (before, `_, _ = runQuick(...)` swallowed both — hence the user's "Enter does nothing" while stuck on the ScaleFinder orphan row). After the refreshed orphans come back empty the screen pops cleanly; the item's cursor index is preserved otherwise. Live-verified: the bash side of add-orphan echoes the success line with a scratch state dir.

  7. **Wine's Mono/Gecko white square suppressed** — the "large white window in the corner during wine installs" is the Wine Mono/Gecko helper dialogue. All five scripts that touch wine (`lib-move-manager-core.sh`, `setup-ableton-move-converter.sh`, `lib-audio-plugin-manager-core.sh`, `link-vst-shared.sh`, `setup-audio-stack.sh`) now export `WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"` at startup — the empty override tells wine to never invoke the mscoree/mshtml helper that draws that white box, while still honoring a pre-existing override if the user exported one. No .run files touched.

  8. **Ableton auto-close, repensé encore avec des tolérances réelles (le "repense" demandé)** — new pacing:
     - `wait_ableton_window` extended to 180 s (a wine process under the patched runtime genuinely can take longer than the old 90 s to surface at all; every "Ableton failed to auto stop" before was often premature);
     - an OSC watchdog pings every tick from the SECOND the process exists, logging the flip exactly once — `post-Ableton: OSC UP at Ns (AbletonOSC ping answered)` — the log line the user asked for verbatim;
     - a 60 s post-window grace keeps close attempts RUNNING (`close_ableton_window` + `osc_quit` when OSC is up) instead of parking on a toast; only after that grace does the "Still waiting for you to save and exit" verdict fire (non-blocking );
     - exiting the loop — auto OR manual close — logs `post-Ableton: Ableton exited after Ns — scanning for the exported .als` (the "manual close not detected" observation was the missing signal, not missing detection).
     Combined with the existing 0.5 s Space flood until OSC, the sequence is: launch → wait (180s cap) → space-flood → OSC watch-dog with logged flips → close window (Super+W AND OSC quit) → extended patience (60s) → manual-close detection line → ALS scan across the broadened roots.

  9. **move.local status air** — one blank row after the status inside the move manager's home body so its line lifts off the bottom hint bar ("légèrement vers le haut" per the user's wording).

  Cross-cutting: all three TUI binaries rebuilt again (gofmt+vet clean) and redeployed; every touched bash script passes `bash -n`; reconcile state file paths verified consistent from BOTH the repo copy and the deployed one (`~/.local/bin` resolution when link-vst-shared.sh sits next to the actions bin — that's where the TUI's `actionsBin()` resolves, so add-orphan/tracking coincide). Live tested the add-orphan + reconcile-orphans pipeline end-to-end with scratch state. NOT verifiable headless: giving Bitwig one more launch to see the crash gone (the crash was ganranteed deterministic from the malformed toml; with a valid TOML the reader has no reason to abort), the Rendering of the ▶ in the user's actual terminal, and A Real auto-close session (/live ping + quit — unavoidable headless limit).

Changes DEPLOYED to ~/.local/bin. Not committed/pushed yet (explicit request needed).

**Follow-up 9 (2026-09-18)**: User's in-app feedback batch + the user-reported live Lua crash. All changes land in the install scripts (fresh-install parity) and were rebuilt/redeployed.

  1. **`hyprland.lua` invalid-escape crash, generator fixed for real** — the user hit `hyprland.lua:112: invalid escape sequence near '"^(yabridge-.*|.*\.'` after a handler flip. TWO bugs in `apply_plugin_handler()` (`lib-audio-plugin-manager-core.sh`): (a) the rule was emitted as `.*\.exe` inside a Lua double-quoted string — `\.` is not a legal Lua escape, so the WHOLE hyprland.lua failed to parse; must be `.*\\.exe` (Lua escape `\\` → regex `\.`). (b) the appended block wrote the `-- >>> mosquito_plugin_handler` start marker but **never wrote the `-- <<< mosquito_plugin_handler` end marker**, so the strip regex `^-- >>> …\n.*?^-- <<< …\n` could never match — every toggle appended a fresh block and 3 identical blocks piled up. Fixed the generator: emit `\\.exe`, emit the end marker, and make the strip self-heal both the well-formed form and the legacy un-terminated form (second regex removes start-marker..`o.window(` line). Verified in a sandbox HOME: 3 legacy duplicate blocks collapsed to 0, two successive classic applications leave exactly ONE well-formed block, and `luac -p` accepts the result (the old single-backslash form was confirmed invalid by `luac -p`). The user had already hand-fixed their live file; the generator now matches.

  2. **Plugin window handler toggle (classic / hyprland)** — new pref `PLUGIN_WIN_HANDLER` (default `hyprland`), `set_plugin_handler()`, CLI action `set-plugin-handler`, and `status-json` now includes `plugin_win_handler` so the TUI can show it. Exposed in the audio manager BOTH as a Settings row ("Plugin window handler: Hyprland-managed / Classic (float + decorations)") and as a direct `x` shortcut inside the plugin list (new reserved single-key side-channel `tuikit.PickerActionMsg{Key}` in the kit; host decides meaning per screen). `classic` writes the marked Hyprland float block (applies to yabridge editor toplevels and bare wine `.exe` windows), `hyprland` removes it. Applies to future launches (a running GUI needs its window reopened). A successful flip shows a confirmation toast — important for the plugin-list `x`, which otherwise has no visible effect — before the status refetch updates the Settings row label (`pluginHandlerOKMsg`).

  3. **"Plugin list" → "Setup installed plugins"** — renamed the main-menu entry, the plugin-list screen title, and the README mention; the underlying list/feature is unchanged.

  4. **Notifications no longer hide the shortcuts** — new `tuikit.BottomBar(notify, hint, w)` reserves a dedicated notification row immediately ABOVE the single-line shortcut hint, so a toast is shown adjacent to (not instead of) the shortcuts and auto-disappears without moving anything. Used by all three managers. Also removed a leftover duplicate in the audio view that ALSO appended the toast to the body (the notification rendered twice and shoved the centred body around — very likely the user's "notification hides shortcuts / moves the interface" complaint).

  5. **Refresh connection status dot → orange, cursor preserved** — `headerFor(m.status, m.loading)` now drives the ORANGE dot while a refresh fetch is in flight (was hardcoded `false`, so the refresh never showed). The statusMsg handler preserves the cursor via `Index()`/`SelectIndex()` on the rebuilt home and settings pickers, so refreshing never resets the highlight. (Audio has no connection, so only the move manager.)

  6. **"Interface too high / title hidden briefly on page 1" root-caused** — a picker sized for a one-line-title sub-screen was rendered under the 8-row home banner, overflowing the window (measured 38 rows in 30 — the terminal scrolls, hiding the title). Fixed defensively: each manager's `View()` now re-`SetSize(m.contentSize())`s its active picker(s) on every render (value receiver, so it is only the local copy). Also fixed a latent `FrameScreen` bug: when the body exactly filled the gap there was no bottom padding, and the shortcut bar concatenated onto the body's last line; the bar is now guaranteed to start on its own line (`strings.HasSuffix(out, "\n")` guard). Verified with temporary render-budget tests in the audio and move packages at 100×30 (home, settings, toast, and navigate-back-with-stale-picker all ≤ 30) — tests removed after passing.

  7. **Failed/aborted install no longer reads as "Success!"** — `install_via_wine` already returns 1 when the installer produced no new file, but the TUI's `RunnerDoneMsg` only pushed the success prompt on `Err == nil` and otherwise left the user parked on the runner screen. Now a non-zero exit on `scrInstalling`/`scrUninstalling`/`scrMoving`/`scrPluginsRootMigrating` pushes the same "See log / OK" prompt with explicit failure wording ("The step failed or was aborted — nothing was installed or changed. See the log for details."). Never calls an aborted install a success again.

  8. **README scope disclaimers** — root `README.md`, `scripts/apps/audio-stack/README.md` and `scripts/apps/ableton-move-converter/README.md` now carry a block stating every module is built exclusively for Omarchy (Arch + Hyprland + Omarchy tooling) and is only tested on the author's own machine, not on other distros/desktops.

  Carried from the same user message and already implemented before this entry (verified present): the user-proven xdotool close chain (`windowactivate` → `alt+F4` → Space carousel → open the Explorer window → Enter → wait), the assisted `.als` MOVE (no "backup" suffix, `.assisted-clean` marker), the uninstall parent/folder grouping fix, the Bitwig toml quoting, and the `WINEDLLOVERRIDES` white-window suppression.

  Cross-cutting: all three TUI binaries rebuilt (`gofmt`/`go build`/`go vet` clean) and redeployed; `lib-audio-plugin-manager-core.sh`, `lib-move-manager-core.sh` and every touched bash script redeployed to `~/.local/bin` (user-owned) and confirmed byte-identical to their repo copies; `bash -n` clean everywhere; `luac -p` validates the generated Hyprland block. NOT verifiable headless: the real plugin-GUI interaction after a classic/hyprland flip, the orange-dot refresh, and the notification placement in a live terminal.

**Follow-up 10 (2026-09-18)**: New "Apply fixes for Wine VSTs" feature (per-plugin Hyprland fixes + install-time dependencies), and a live regression fix that the previous commit had introduced in every TUI command.

  1. **Regression fixed: `apply_plugin_handler()` polluted stdout on every command** — the toggle added in `3ae3255` called `ok "plugin window handler: …"` in BOTH branches, and `load_prefs()` re-applies the handler on every actions invocation. `ok()` writes to **stdout**, so EVERY JSON backend command (`status-json`, `list-all-plugins`, `list-plugin-fixes`, …) was prefixed with ` ✓ plugin window handler: hyprland (rules removed)` — the Go TUI's `decodeJSONLines`/`json.Unmarshal` would choke on the first line, breaking the whole manager. Reproduced against both the repo and the deployed copy. Fix: the re-apply path is now silent (the user-visible confirmation remains `set_plugin_handler()`'s own `msg`). `status-json 2>/dev/null | jq` now emits pure JSON.

  2. **Fix registry in the core lib** (`lib-audio-plugin-manager-core.sh`) — new `FIXES_STATE` (`~/.config/audio-plugin-manager/fixes.json`), `fixes_catalog()` (id|title|scope|description), `fixes_list_json`/`fixes_for_plugin_json`, `fix_apply`/`fix_remove`, `known_plugin_fixes()` + `apply_known_fixes_for()`. Each fix is written as its own marked, idempotent block in `~/.config/hypr/hyprland.lua` (`-- >>> mosquito_fix_<id>` … `-- <<< mosquito_fix_<id>`, comments prefixed `--`), always regenerated from the state file so re-applying can never stack duplicates and removing the last plugin removes the block; `hyprctl reload` runs afterwards. `fix_re_escape()` (python `re.escape` + Lua `"` escaping) makes plugin-name title matches regex/Lua-safe. Verified in a sandbox HOME: legacy un-terminated block stripped, two plugins collapse into one per-fix block, global fix stored once as `__global__`, removal deletes the block, and `luac -p` accepts every generated file.

  3. **Fix catalog** (general, selectable): `wine_gui_input` (per plugin; floats/unblurs the editor and adds `allows_input = true` on a title-scoped XWayland rule — the CrispyTuner inert-GUI fix; a generic `yabridge-*/.*\.exe/wine*` float+no_blur class rule is included), `wine_tooltip` (Ableton/Wine hover tooltips: float, no blur/anim, never focused, `suppress_event = "activate activatefocus"`), and `cursor_no_warp` (**global** — Hyprland 0.56.2 has no per-window warp rule, so it writes `hl.config({ cursor = { no_warps = true, persistent_warps = true } })`; never auto-applied, clearly labelled `[global]`).

  4. **Install-time dependencies** — `install_plugin()` now derives the installed plugin's stem and calls `apply_known_fixes_for()` after `post_install`, so known plugins get their fixes on first install (map: `CrispyTuner → wine_gui_input wine_tooltip`). Idempotent, so re-installing is a no-op for the rules.

  5. **TUI: "Apply fixes for Wine VSTs"** — new top-level menu item, two screens (`scrFixPluginPick` → pick an installed plugin from the unified list; `scrFixChoose` → Tab multi-select the fixes, Enter applies the delta). Same Tab-diff contract as the Plugin list: Enter only sends newly-checked fixes to `apply-fixes` and newly-unchecked ones to `remove-fixes` (`syncFixesCmd`), with a cursor-preserving `rebuildFixPicker`. New actions backend verbs `list-fixes`, `list-plugin-fixes <plugin>`, `apply-fixes <plugin> <fix…>`, `remove-fixes <plugin> <fix…>`. All command output re-verified pure JSON.

  6. **Docs** — `scripts/apps/audio-stack/README.md` gains an "Apply fixes for Wine VSTs" section and the new item is listed in the manager overview. Fresh-install parity automatic (`setup-audio-plugin-manager.sh` `deploy_one`s the lib + actions and builds the TUI with an absolute temp path).

  Cross-cutting: TUI `gofmt`/`go build`/`go vet` clean; `bash -n` clean on lib + actions; lib and actions redeployed to `~/.local/bin` (user-owned, byte-identical to repo), TUI rebuilt and redeployed as a valid ELF (7.85 MB). The real machine config was NOT modified: no `fixes.json` created and `~/.config/hypr/hyprland.lua` still contains zero `mosquito_fix` blocks (all sandbox-verified). NOT verifiable headless: whether `allows_input` genuinely makes the CrispyTuner GUI clickable in a live Bitwig/Ableton session, and the tooltip rule's effect — both need the user's desktop.

**Follow-up 11 (2026-09-18)**: User's two live bug reports on the fresh build, fixed and deployed.

  1. **Double "global" label on the cursor fix** — the fix catalog title for `cursor_no_warp` already said "(global)" AND the fixes picker appends its own `  [global]` tag (from `fixItemsToPicker`), so the row read "Stop the cursor recentering (global)  [global]". Dropped "(global)" from the catalog title; the tagger is now the single source of the scope hint.

  2. **`warn()` wrote to stdout and could corrupt JSON commands** — only `err()` went to stderr; `msg`/`ok`/`warn` all printed to stdout. `load_prefs()` re-runs `apply_plugin_handler()` on EVERY actions invocation, and that path emits `warn "hyprland.lua not found — …"` whenever the file is absent — so any machine without `~/.config/hypr/hyprland.lua` got that warning line prepended to every JSON command (same class of bug as Follow-up 10's `ok`). `warn()` now writes to stderr; `status-json 2>/dev/null` emits pure JSON even with no hyprland.lua (sandbox-verified).

  3. **Uninstall folder rows with no detected children** — the Go folder-expand logic (`PickerSortMsg` → `folderExpanded`, `treeItemsToPicker`) is correct and passes an isolated key-path test, but a folder whose sub-plugins never got a `parent` renders as an empty row: → shows nothing new and Tab checks nothing (exactly the user's "right arrow does nothing / folder not selected"). Root cause is parent detection in `list-uninstallable`, which relied on the uninstaller DAT mentioning the plugin stem or a ±1h mtime cluster. Added a last-resort heuristic: when both miss, match the plugin's own vendor folder name (`basename dirname <src>`, case-insensitive) against each wine program folder's basename (e.g. `vst3/Crispy Audio/CrispyTuner.vst3` → the `Crispy Audio` installer folder). Sandbox-verified: a plugin whose DAT does NOT contain its stem now groups under the `Crispy Audio` folder row.

  Cross-cutting: TUI `gofmt`/`go vet`/build clean (7.85 MB ELF); `bash -n` clean on lib + actions; lib, actions and the TUI rebuilt/redeployed to `~/.local/bin` (user-owned, lib + actions byte-identical to repo). Real machine config untouched.

**Follow-up 12 (2026-09-18)**: Hardened the Hyprland crash-recovery script added in `d072777` — the first live sandbox E2E exposed a corruption bug in its `sanitize` step.

  1. **`sanitize` clobbered the restored config** — the original generic `awk` dedupe assumed one `o.window(...)` per generated block (the real config has several per block) and printed its buffer with `printf "%s"` (no trailing newline), so restored files came back with glued lines (`o.window(...})-- <<< Omarchy_Custom_Scripts_Handbrake`) and reordered/duplicated rules. Verdict: too fragile for the actual `hyprland.lua`; replaced with a marker-keyed line-array `perl` dedupe that splits on `^-- >>> `, compares consecutive segment signatures byte-for-byte, and keeps only the first copy — byte-identical output on the real backup (verified: only the yabridge dedupe + escape differ).

  2. **Two footguns found while testing** — (a) the dedupe `perl` reads stdin but was invoked with a filename argument → empty output → `mv` over the restored file, which then silently regressed to a 6-line stub; fixed with `< "$tmp"`. (b) The Lua-escape `\Q...\E` pattern carried one extra backslash (2 instead of 1), so it matched already-double content that never existed in a single-backslash source → the `.*\.exe` → `.*\\.exe` fix never fired; corrected to `\Q|.*\.exe|\E`.

  3. **Added a safety net** — sanitize now refuses to commit any result that dropped the Omarchy bootstrap (`bootstrap.lua`) or `require("default.hypr.omarchy")` or went empty; on such a result it keeps the pre-sanitize content and warns. The full script is idempotent (a second run performs no rewrite, only "hook already installed").

  Cross-cutting: `bash -n` clean; sandbox E2E (fragment + `hyprland.lua.bak.1789659686` + personal modules) restores byte-identical to the backup modulo the two intended changes (single deduped yabridge block with `.*\\.exe`, recovery requires added when needed); post-boot hook `zzz-fix-hyprland-crash` installed on the REAL machine (`~/.config/omarchy/hooks/post-boot.d/`), `hyprctl configerrors` empty, keyboard `fr`, shell running. `setup-customarchy.sh` FIXES array + `run_fix` case were already registered in `d072777`. Working-tree change (script bugfix) still uncommitted.

**Follow-up 13 (2026-09-18)**: Repo-wide reorg (`scripts/apps/audio-stack` → `scripts/apps/audio-plugin-manager`, keeping the installer's filename `setup-audio-stack.sh`), plus the first-launch setup wizard on both the backend and the TUI.

1. **Reorg/rename** — `git mv` of the whole app dir plus every path reference (`setup-customarchy.sh`, `scripts/README.md`, `.gitignore`, `fix-tui-theme.sh`, both READMEs), `setup-audio-stack.sh` slimmed to a fast one-shot that installs deps then delegates to the parameterised `setup-audio-plugin-manager.sh` (new `ask()` + `-y/--yes` auto-yes verified), and `scripts/apps/audio-plugin-manager/README.md` fully rewritten to match the real v2 behaviour instead of the pre-rewrite copy.

2. **Wizard (backend)** — `status-json` grew `wizard_done`, true on genuinely fresh machines only (`WIZARD_DONE` unset AND the prefs file didn't exist before `load_prefs()` ran — upgrades never see it; this already-configured machine correctly reports true). New verb `wizard-finish [root]` (fresh setup, no migration): persists `PLUGINS_ROOT` + `WIZARD_DONE`, `init_plugins_root()`, `apply_plugins_root()`, then streams per-DAW lines for the TUI runner — **REAPER** (python3 idempotent update of `vstpath=`/`vst3path=`/`clappath=` in `~/.config/REAPER/reaper.ini` to the yabridge chainloaders `~/.vst`/`~/.vst3`/`~/.clap`, which are exactly what a Linux REAPER must scan — the initial iteration pointed at the shared root's Windows `.dll` subfolders, corrected after real-README review; dirs created, one-time `reaper.ini.mosquito.bak`, separator-tolerant append), **Ableton Live** (yabridge-suite linker into `~/.wine-ableton/drive_c`), **Bitwig** (manual Preferences → Plug-ins instruction line), then a "Finished — the plugins folder is …" line. Sandbox-verified fresh (`wizard_done` false→true), upgrade (true from the start), REAPER-append idempotent (re-run adds nothing).

3. **Wizard (TUI)** — on a `status-json` with `wizard_done=false`, `scrWizardRoot` (tuikit Confirm) offers the current root: *Yes, use the default* → straight to the runner; *No, choose a folder* → superfile browse (exiting then opens the native folder dialog — spf's `--chooser-file` can't return bare dirs) when superfile is installed, else the native dialog immediately; Esc skips (keeps the default, does NOT mark done, so the next launch re-offers — completing the wizard is what finishes it). `scrWizardDaw` streams the `wizard-finish` readout (Esc cancels the readout early without undoing the already-persisted folder decision; Enter only advances once the runner is done), then main menu + toast. Unknown `pathMsg` kinds now bubble to the active screen's `updateScreen` instead of being swallowed (model.go previously `return m, nil`'d them), so the `wizard-browse-done` marker reaches the wizard's pick-folder case.

4. **Deployed** — lib + actions byte-identical to the repo, TUI rebuilt with an absolute `mktemp` path and user-owned, and the tracked `tui-go/audio-plugin-manager-tui` cursor-of-the-build binary rebuilt to the identical image. `gofmt -l` and `go vet` clean, `go build` clean; `bash -n` clean on every audio script plus `setup-customarchy.sh`.

5. **README reconciled with reality** — the wizard + "Setup installed plugins" sections now describe exactly what the wizard does (the old "REAPER … `setup-reaper.sh` already normalises this list" claim removed — it never did), and Settings' default corrected to `~/Music/Audio Plugins` with the actual lowercase `vst`/`vst3`/`clap`/`lv2`/`vst3-native`/`clap-native` subfolder set plus the legacy-`~/VST`-reuse note.

**Follow-up 14 (2026-09-18)**: Regression pass on the JOURNAL todo list (items 3.1–3.7, 3.10, 3.4, 3.5), with two script hardenings.

1. **Orchestrator (3.1)** — `GUI_RUN_EXEC=1 ./setup-customarchy.sh --status`: 16 modules ✓, 3 genuinely absent (macos-vm, davinci, mx-master), 3 partial (apps, achraff, customarchy-update); all 22 `MODULES` have matching `st_*`/`un_*`; move-bin modules all present. Fixed `un_audio`'s purge resolving the REAL plugins root (env override → populated settings dir → legacy `~/VST`) and declared it before the if/else (`set -u` safe). Committed `f1cb21f`.

2. **Archive (3.6)** — `archive-customarchy.sh --list-heavy` (Ableton zips 3–4 GB, `install-ableton-latest.run`, Guitar Pro .exe, no DaVinci zips) then `--type=release` to `/tmp` → 370 MB archive; `tar tzf` verified: no logs, backups, `.git`, `.venv` or heavy installers; only the legitimate git-ignored local Bitwig .deb carried. Cleaned up.

3. **Backup (3.2)** — `--backup --vst-backup=none` to `/tmp` (26 MB); `tar tzf` shows real target files in `config-backup.tar.gz` (bindings.lua, reaper.ini, omarchy-menu.jsonc, desktop). Restore deliberately NOT run live (it would clobber this machine): verified by listing instead. Headless bubbletea "unable to confirm" lines are only the interactive picker degrading — harmless.

4. **Bootstrap (3.3)** — local `./scripts/bootstrap.sh --status` fine, but the advertised `curl | bash` fails against `raw.githubusercontent.com`: **this repo is PRIVATE** (HTTP 404 repo page, API, and raw endpoint). Push works; the one-line bootstrap only works for the owner or once public — user decides.

5. **Zen (3.7)** — module fully applied on the real machine: active profile `c8ixn63v.Default`, seed extensions 4/4 (Zen Internet, Dark Reader, uBlock, keepassxc-browser), settings + chrome present; native messaging bridge `~/.mozilla/native-messaging-hosts/org.keepassxc.keepassxc_browser.json` live with keepassxc installed.

6. **TUI themes (3.10)** — verified already-implemented: `tui-kit` re-reads the active Omarchy palette (`~/.local/state/omarchy/current/theme/colors.toml`, current accent `#6c3b88`, orange `#ee5e21`) at every startup via `applyPalette(loadOmarchyPalette())`, and both managers render exclusively through `tuikit.Style*` (no hardcoded colors) — the `lipgloss.NewStyle()` wrappers only set width/alignment. Today's builds ship it.

7. **Keybindings (3.4)** — full add/verify/remove cycle tested against the live `bindings.lua` (backed up + restored byte-identical) and `hyprctl configerrors` from a LIVE Hyprland. The test surfaced a real gap: `--ensure` with an invalid keysym wrote the binding and still said "Bound ✓" while `configerrors` flagged `Unknownkeysym`. `add_binding` now detects a NEW `Unknownkeysym:<key>` error right after the reload, rolls the block back, and exits 1 (machine left pristine; valid combos like `SUPER+B` still pass). Didn't find a raised false alarm.

8. **Update watchdog (3.5)** — `--update-repo` on this machine failed with `cannot pull with rebase: You have unstaged changes` (owner machine has `pull.rebase=true`). `update_repo_ff` switched to `git fetch` + `git merge --ff-only FETCH_HEAD`: immune to `pull.rebase`, safe on a dirty tree, still refuses to destroy anything. No-op on an up-to-date repo returns the same ✓.

**Follow-up 15 (2026-09-18)**: Interactive launcher menu on `setup-customarchy.sh` + type filter for the apps module + combined fixes README.

1. **Launcher menu** — when you sit in a *terminal* without any flag, `setup-customarchy.sh` now opens a 6-entry menu loop (gum when available, numbered otherwise): `status` (module states with the existing ✓/!/✗ icons) / `update` (explains the update zone, checks GitHub, then re-applies + completes every module interactively) / `setup` (10 categories: Apps, TUIs, Webapps, Plugins, Quick fixes, mosquito, keybindings, LLM, Themes, VMs) / `remove` (per-module uninstall) / `backup/restore` / `quit`. BACKUP/RESTORE now states its function FIRST (where the dated archive lives, its contents incl. KeePassXC+note "never to the repo", GPG AES-256 option, restore = files not packages) before asking what to do — mirroring the update zone. The setup categories map: Apps=reaper audio ableton guitarpro davinci handbrake superfile zen; Plugins=jamjamjam-plugin battery brightness keyboard-backlight touchpad mx-master; LLM=ollama; VMs=windows-vm macos-vm; TUIs/Webapps→apps module restricted by `--only`; Quick fixes→all FIXES; mosquito→audio-plugin-manager (setup-audio-stack.sh) + move converter; Themes→achraff + wallpaper theme creation; keybindings→its TUI. The step-by-step wizard remains reachable via `-y`/`--update`/the categories. launcher_pick renders menus to stderr so `$()` capture only returns the picked label (first pty test swallowed the item list). pty-tested: main menu, setup submenu, status, backup explanation + submenu, quit; headless `--status`/`--update-repo` unchanged.

2. **`--only=<gui|tui|webapps>`** in `setup-apps.sh` — restricts the selection to one catalog type (used by the TUIs/Webapps launcher categories) and seeds the selection from that type's catalog when the backup has none; `delegate_types` and the extra-candidates loop are scoped to the type. Bad values are rejected.

3. **Module exec loop refactored** into `exec_modules()` (shared by the -y path, --update path and the launcher's update/setup) — no behavior change.

4. **scripts/fixes/README.md** — combined documentation of every fix in the folder: the 5 quick fixes (FIXES array), the display/mx-master/touchpad modules (linking the three detailed .md), the optional Evince→Papers swap, and notes (backlight helper, ids ↔ FIXES mapping).

5. Deprecation answer for the follow-up: there is **no `gui-run.sh`** — only `scripts/gui-run.bash`, and it IS used by the orchestrator (sourced at setup-customarchy.sh:35) plus ~20 scripts; it re-opens a file-manager launch inside foot/xterm so output is visible and the window keeps the "press Enter" prompt. Not deletable.

**Follow-up 16 (2026-09-18)**: Move Manager extension — "Convert a preset" (Ableton .adg → Move preset), Schwung submenu, "Move as Bitwig controller" submenu, menu-label fixes, `gui-run.bash` → `scripts/lib/`, and the setup deploy for all of it.

1. **Convert-a-preset** — ported/validated `convert-adg-to-move` (untracked python3 L2Move port, works) converting an Ableton `.adg` into either a standalone Move `.adg` (gzip, 32 DrumBranchPreset = 16 open+close pairs, 16 SampleRef, ReceivingNote 92,91,90… descending) or a `.ablpresetbundle` (`Preset.ablpreset` JSON, camelCase per L2Move's resolver: `receivingNote`/`sendingNote`/`chokeGroup` — fixed a PascalCase regression in `drumZoneSettings`) + 16 `Samples/sNN.wav`; notes 36,37,38 ascending, send 60, choke None, uri `Samples/s01.wav`. Partial-success semantics: a missing-samples bundle keeps the valid `.adg`, rc=0, note on stderr. Samples are resolved through `--search-root` remapping Wine `C:/…` paths onto the Ableton version's `drive_c` (`/home/mosquito/.wine-ableton/drive_c` from prefs). New `lib-move-manager-features.sh` (presets helpers + all schwung/bitwig helpers, functions-only) + actions subcommands `preset-status-json` (→ `$MOVE_DIR/presets`, search_root, default_dir = `/home/mosquito/Documents/Ableton/User Library/Presets/Instruments/Drum Rack`, connected), `pick-adg`, `convert-preset`. TUI flow: `Convert a preset` → source picker (Ableton ✓ / Bitwig disabled "(coming later)" per the roadmap) → embedded superfile picker → "add another / convert now" → progress screen → toast. pty-verified; converter resources + template deploy to `<bin-dir>/converter/`.
2. **Schwung** — appears in the main menu only while the Move is connected (rows hidden, per the earlier decision, not greyed). Submenu: install/update (foot window running `schwung_run_installer`), open the manager (`schwung-manager-webapp`, new launcher mirroring `move-manager-webapp` with its own `~/.cache/schwung-manager` Chromium profile + single-instance + insecure-origin treatment), uninstall (confirm screen), back. Backend: `schwung_url` = http://move[N].local:7700, `schwung-status`/`schwung-latest` (release.json → 1.4.0), manager poll/close. Status fetched on entry + on-install refreshes the picker.
3. **Move as Bitwig controller** — vendored the upstream `move-bitwig` into the module (740K, controller scripts + on-device module + build/install scripts), deployed to `~/.local/share/mosquito-move-manager/move-bitwig` by setup. Backend: `bitwig-move-status` (Bitwig installed ✓ + controllers present + ssh probe of move.local for on-device status), `bitwig-move-install` (copies `Controller Scripts` then foot: `bash scripts/build.sh && bash scripts/install.sh`), `bitwig-move-uninstall`, `open-bitwig`, `bitwig-running`. TUI submenu with status line, uninstall confirm, and an end "controller ready — Settings → Controllers → add midiin4/midiou4" tip screen that polls Bitwig and auto-returns once it's running/the user dismisses.
4. **Menu fixes** — label "Open the Move Manager & convert" (was "(unavailable)"-suffixed when disconnected) in both the bash `main_menu` and the Go `mainMenuItems`; verified in pty (disconnected = clean muted label, no suffix; connected stub shows Schwung + "Move as Bitwig controller").
5. **`gui-run.bash` → `scripts/lib/gui-run.bash`** — moved (existing 0 `gui-run.sh`), all 33 `source` sites updated by depth (`../lib/…` / `../../lib/…`), plus the `bootstrap.sh` probe path and `setup-customarchy.sh:35`; comments/docs untouched; full `bash -n` sweep clean.
6. **Setup deploy** — `setup-ableton-move-converter.sh` now also deploys: `lib-move-manager-features.sh`, `convert-adg-to-move`, `schwung-manager-webapp` (all via `deploy_bin`), `converter/` resources (new `deploy_converter_resources`), and the vendored `move-bitwig` (new `deploy_move_bitwig`); summary + uninstall text updated. Sandbox-tested (deploy_bin + both new functions, idempotent).
7. **Quick fixes multi-select** — already satisfied in `setup-customarchy.sh` (`gum choose --no-limit` + `LAUNCHER_NUMERIC` numbered fallback); no change needed.
8. **Verification & notes** — `go build ./... && go vet ./...` clean; pty driver confirmed the schwung menu ("Install schwung", "Open the Schwung Manager (only after installation)", "Back"), the bitwig menu (+ status line), and the preset source/picking screens; `convert-preset` action E2E (rc=0, "OK mykit — 16 pads" → `$MOVE_DIR/presets/mykit.adg`, artifact cleaned). Left for the real device: any schwung/bitwig on-Move install (needs a connected Move), the superfile `pick-adg` path on this host (spf presence unconfirmed), and re-running setup to refresh the deployed `~/.local/bin` copies.

**Follow-up 17 (2026-09-18)**: Big UX/bug batch across setup-customarchy, the Move Manager and the Audio Plugin Manager; folder/module rename `ableton-move-converter` → `ableton-move-manager`.

1. **gum multi-select (setup-customarchy + apps module)** — root cause of the "nothing selected" bug: in gum 2.0 **Space does nothing**; only **Tab/x** toggles, and nothing is pre-checked unless `--selected` is given. All multi-selects now pre-select (`--selected "*"` for "everything checked", or the default NAMES in the backup), use honest `[ ]`/`[x]` prefixes, and say "Tab/x" in the header (`multi_select`, `fixes_pick`, `tick_entries`/`tick_removal`, `setup-apps.sh`, `uninstall-apps.sh`, `uninstall_chooser`). The grey selected-row box came from the theme's `GUM_CHOOSE_SELECTED_BACKGROUND=#918f93`; both `setup-customarchy.sh` and `scripts/lib/common.bash` now `export GUM_CHOOSE_SELECTED_BACKGROUND=""` (+ `GUM_FILTER_…`). `multi_select` also neutralises commas in labels (they broke gum's comma-joined `--selected`), so the backup now really pre-checks its default apps and lists every installed one.
2. **`update` action** — no longer installs missing modules: it diffs the repo (fast-forward + local working-tree edits) and, via `module_of_path`, offers a multi-select of **only the installed modules whose scripts changed** (`launcher_multiselect`, Esc-safe).
3. **`backup now`** — asks whether to encrypt **first**, then the passphrase **twice, hidden**, and only then what to back up. Fixed the "empty passphrase" bug: `ask_passphrase` now writes the value to `ASK_PASSPHRASE` (never inside `$()`, which broke gum's interactive input in the launcher), uses gum only when stdin/stdout/stderr are all a tty, and falls back to a hidden `read -rs` otherwise.
4. **setup menu** — category/main-menu lines shortened (no more `(✓/!/✗)`, `--purge`, `explains first`, long per-module blurbs, `mosquito*`, etc.); **Esc returns to the main menu** (`*) continue` + `quit) break`, and `gum choose || true` so aborts don't trip `set -e`).
5. **Omarchy install menu entry** — new category `menu` / `install_menu_entry()` registers an idempotent `install.mosquitomarchy` key (managed block, `menu_json_valid` check) that launches setup-customarchy.sh; references the mosquito icon, warns if absent.
6. **Move Manager TUI** — Schwung and "Move as Bitwig controller" are now **visible but greyed/disabled** when the Move is not connected (was: hidden); the `(checking…)` label is gone (the move.local status line already shows the orange dot). Never auto-closes Bitwig (audit: no kill/close of Bitwig anywhere; the tip screen only polls and pops the TUI).
7. **Automatic `.als`-in-Bitwig opening** — the user's `open-als-in-bitwig` was **integrated** (not called) as `open_als_in_bitwig_via_ydotool()` + helpers in `lib-move-manager-core.sh`, hooked once in `finish_bitwig_open()`. New global setting **`Open the converted .als directly with Bitwig using ydotool: On`** (default On, prefs `~/.config/move-session/prefs`, key `OPEN_ALS_WITH_YDOTOOL=true`), toggle in the bash + Go Settings, documented in the move-manager README (Hyprland-only, temporarily disables keyboard/mouse via hyprctl, needs sudo/hyprctl/jq/ydotool/wl-copy, 15 s watchdog). Off → normal launch/focus + a notification to open the `.als` manually. The standalone script was deleted.
8. **Move Manager post-conversion** — after a successful preset conversion: if the Move is connected, ask to open the Move Manager and then show the converted preset path(s) with an upload hint; if not connected, show a "not connected" screen with "Refresh connection status" / "Back to the main menu".
9. **Hyprland gate** — the Move Manager and Audio Plugin Manager interactive launchers detect a non-Hyprland session and warn (designed for Hyprland, untested elsewhere) before doing anything; flag/`--status`/action paths are not gated.
10. **Audio Plugin Manager** — "Apply fixes" now asks "What fixes do you want to apply for <plugin>?" with fixes grouped under **expanded folder rows** (select a whole category or individual fixes; unselected `○` / selected `●`, Tab+x); already-applied fixes are auto-detected and pre-checked (`fix_applied_for_plugin` matches full value/path/stem). A successful plugin install now proposes "Apply fixes for <plugin> now?". The plugin list is renamed **"Installed plugins"** with a subtitle about Tab hiding/showing plugins so DAWs ignore them, and **folder grouping identical to uninstall** (shared `wine_program_parent_of`/`wine_program_rows_json`). Uninstall's "open folder" was broken (no action existed) → new `open-folder` action (`xdg-open` + fallbacks).
11. **Rename** — `scripts/apps/ableton-move-converter/` → `scripts/apps/ableton-move-manager/`, `setup-ableton-move-converter.sh` → `setup-ableton-move-manager.sh`, module id `ableton-move-manager` (all live path/id references updated; the Omarchy menu key `trigger.music.ableton-move-converter` and the managed-marker text are intentionally kept as compatibility anchors, and the legacy `$BIN_DIR/ableton-move-converter` cleanup is kept). JOURNAL history left unchanged.
12. **Left open** — the Ableton auto-close/timer/OSC reinforcement is deliberately untouched (the user is still researching). Verification this round: `bash -n` clean across all touched shell files, `go build`/`go vet`/`gofmt -l` clean for both TUIs (binaries rebuilt), `setup-customarchy.sh --status` and the move-manager `--status` run clean, `status-json` reports `open_als_ydotool: true`. Nothing committed.

**Follow-up 18 (2026-09-18)**: TUI layout/navigation rules + setup-fixes/menu corrections + SuperFile keybind.

1. **Universal cursor rule (tui-kit)** — `Picker.advanceDown/advanceUp` (Arrow/j/k) now skip every `Disabled` row instead of only greying it, so the cursor can never rest — invisibly — on an unselectable option; left/right and page keys still use `clampDisabled`. Applies to all three TUIs (they share `scripts/lib/tui-kit`). The centered-text layout rule (`renderCentered` + `FrameScreen`) was already the shared universal rule and now applies everywhere.
2. **←/→ toggles On/Off settings in place** — Move Manager Settings handles `PickerSortMsg` for the boolean rows (`Hide converted`, `Open … ydotool`) and cycles the file picker when safe; the action is fired via a new non-popping `fireToast` (the generic `actionOKMsg` handler pops the screen) and the status refresh re-selects the same row, so the cursor never moves. Live Mode Manager's `PickerSortMsg` now flips its On/Off rows (`close_apps`, `routing`, `gaps`, `notifs`) in addition to stepping `thermal`, also preserving the cursor.
3. **setup-customarchy — `fixes` option** — no longer applies every fix on entry: it calls `fixes_pick`, a Tab/x multi-select that shows fixes grouped under **`▾ <Category>` folder rows** (pick a whole category or individual fixes), expanding CAT rows to their fixes. Nothing selected → nothing applied.
4. **setup-customarchy — `menu` option** — now asks "Add the mosquitOmarchy setup to the Omarchy install menu?" and, if yes, does ONLY the menu registration (no status/final report). Removed the trailing `status_report` from `launcher_run_category` and `launcher_update`, so the module state list is shown by the `status` action only.
5. **SuperFile keybind** — `scripts/setup-keybindings.sh` quick-function catalog gained "Default file manager (Super+Shift+F)" (`xdg-open "$HOME"`) and "SuperFile (terminal file manager)" (`foot -e spf`), so both can be bound to different keys (the default FM on Super+Shift+F).
6. **Redeploy** — move/audio/live-mode TUIs rebuilt and reinstalled to `~/.local/bin` (17:29). `bash -n` clean; `go build`/`go vet`/`gofmt -l` clean.

**Follow-up 19 (2026-09-18)**: fixes readability/tree, backup menu loop, passphrase abort.

1. **Backup / Restore menu loops** — `launcher_backup` now redisplays the Backup/Restore menu after every action (backup/restore/list) and only leaves via "Back to the main menu", so a passphrase mismatch/empty passphrase returns to the previous menu instead of dropping to the main menu. `do_backup` aborts (returns 1, cleans the temp dir) on empty passphrase or mismatch.
2. **Quick-fixes readability + tree** — `fixes_pick` now prints every fix's FULL description wrapped to the terminal width before the picker, so a narrow default window never hides the end of an explanation; the fixes under each `▾ Category` row are indented with file-tree angles (`    ├─ …` / `    └─ …`). The Audio Plugin Manager's Go fixes picker got the same tree angles on its child rows.
3. **Horizontal arrows** — the Settings toggles that flip a parameter (On/Off, Superfile/Default) are driven with ←/→ (Move Manager: `hide_converted`, `open_als_ydotool`, file-picker cycle; Live Mode: `close_apps`/`routing`/`gaps`/`notifs`, plus `thermal`), cursor preserved. Centered option alignment stays the universal tui-kit rule.
4. Redeployed the audio TUI (18:06). `bash -n` clean; `go build`/`go vet`/`gofmt -l` clean.

**Follow-up 20 (2026-09-18)**: CRITICAL — a bad cleanup regex gutted `~/.config/hypr/hyprland.lua` (the "emergency mode" report), config restored, writer made safe.

- **Symptom**: repeated `hyprctl configerrors` → `hyprland.lua:8: attempt to index a nil value (global 'o')`; the user file had been reduced to two duplicated `mosquito_plugin_handler` blocks (~1 KB) with the whole Omarchy preamble (`dofile bootstrap`, `require("default.hypr.omarchy")`, `require("hypr.*")`) gone, so Hyprland ran a gutted config.
- **Root cause**: `apply_plugin_handler()` (audio manager, re-run on EVERY actions invocation via `load_prefs`) stripped its old block with an UNBOUNDED legacy regex `(?ms)^-- >>> mosquito_plugin_handler\n(?!...).*?^o\.window\(...`. When a stray start marker sat above the preamble (older writes used a malformed `>>>` end marker and emitted invalid Lua `\.`), the regex deleted everything from that marker to the next `o.window(` — including the preamble. Blocks then re-accumulated with malformed markers.
- **Recovery**: kept the broken file (`hyprland.lua.broken.<ts>`), restored the newest full backup `hyprland.lua.bak.1789659686` (preamble + touchpad/handbrake/reaper/keepassxc/move-manager/audio-tui/move-webapp/live-mode blocks), stripped the corrupt handler blocks line-by-line and wrote one canonical block (`\\.` in Lua). `hyprctl configerrors` back to empty; verified after a live actions invocation (preamble intact, single block).
- **Fix**: `apply_plugin_handler` now drops ONLY the known handler lines (markers/comments/the one `o.window` rule) with a line-based filter (can never span unrelated content) and refuses to write a file that lost the Omarchy preamble. Deployed via the audio setup. No other repo block-stripper uses that pattern (the others are JSONC comment strip / bounded marker ranges).

**Follow-up 21 (2026-09-18)**: TUI alignment + paging + audio folder/sort unification.

1. **Disabled rows aligned** — `renderDisabled` now composes exactly like `renderCentered` (same 3-col indicator slot, same maxRowW padding, same full-width centering), so greyed rows (Schwung / Move as Bitwig controller) share the same visual column as the enabled ones instead of using a different centering width.
2. **Vertical arrows cross pages** — `Picker.advanceDown/advanceUp` now scan the whole list (not just the current page), so the pagination dots are reachable with ↓/j ↑/k; `list.Select` updates the page. Still skips Disabled rows and never wraps.
3. **Audio manager lists unified** (agent): Installed-plugins and Uninstall now expand/collapse folder rows with Left/Right (shared `folderExpanded` + `treeItemsToPicker`); sort moved to the `s` key on Installed/Uninstall/Fixes; the fixes screen also gets Left/Right folder collapse + `s` sort; every folder list renders the same `▾/▸ …` + `├─ /└─` tree angles. Hints/subtitles updated (`Tab … · s sort · ←/→ folders`). `go build`/`go vet`/`gofmt` clean.
4. Redeployed move/audio/live TUIs (18:48); `hyprctl configerrors` clean.


## Open TODOs

- [ ] Compatibilité audio interface Ableton Move avec Bitwig (audio interface Move ↔ Bitwig).

**Follow-up 22 (2026-09-18)**: folder-collapse crash, Apply-fixes chooser grouping, deferred-apply settings.

1. **Crash fix (tui-kit)** — `Picker.SelectIndex` now CLAMPS the index: bubbles' `list.Select` does not, so collapsing a folder (which shortens the list) left the cursor past the end and panicked (the "crash in Uninstall plugins with ←/→" report). This is a universal fix, so it protects every list rebuild in all three TUIs.
2. **Apply-fixes chooser** — `scrFixPluginPick` now uses the same tree/sort as Installed plugins (`treeItemsToPicker` + shared `folderExpanded` + `s` sort via `set-sort-and-list`), single-select (Enter chooses one plugin; Left/Right fold folders; `s` sorts). The fixes list categories are seeded expanded on every entry (the "no folders in Apply fixes" report).
3. **Deferred-apply settings (all three TUIs)** — settings rows that toggle/cycle a value (On/Off, file picker, plugin window handler, thermal, …) now change their DISPLAYED value immediately with ←/→ but APPLY it only after a ~800 ms dwell, or when the cursor leaves the row, or when the page is exited — cursor stays put, no page reset. Apply reuses the Enter path (no pop). Confirmation-requiring rows (SuperFile) still show the pending label and confirm at apply time.
4. Page continuity (↑ from page 2 reaches page 1, ↓ blocks at the last row) comes from the Follow-up-21 paging change. Redeployed move/audio/live TUIs (19:04); `hyprctl configerrors` clean. Added the Open TODO: Ableton Move audio-interface compatibility with Bitwig.

**Follow-up 23 (2026-09-18)**: "Plugin fixes" rework, paging root cause, Ableton auto-close option.

1. **Applied fixes now detected** — `fix_applied_for_plugin` canonicalized only the query side; a fix stored as the full picker value (`vst:vst3:/…/CrispyTuner.vst3`) never matched a query by stem, so it read `applied:false` (unchecked) and Enter said "no change". Now both sides canonicalize to the product stem (`fix_plugin_canonical`; `__global__` handled), `fix_apply`/`fix_remove` write canonical keys (old full-value entries migrated) and `fix_render_rules` builds `^CrispyTuner` instead of a path regex. Applied fixes come back `●` pre-checked.
2. **Renamed to "Plugin fixes"** — menu, chooser picker, screen titles and README; the header now reads "Choose the fixes to apply or remove for <plugin>" (the model is apply **or remove**), help bar unchanged (`Tab toggle · s sort · ←/→ folders · enter apply`).
3. **Plugin-specific grouping** — catalogue gained a 6th `plugin` field; `wine_tooltip` is grouped under "CrispyTuner specific" and rows are tagged `[plugin: CrispyTuner]`; every fix stays visible for every plugin (nothing filtered).
4. **Plugin window handler confirmation** — changing it now pushes a confirm screen explaining the global Hyprland rules / next-windows-only / per-plugin override; applied only on Yes (No/Esc drops the pending value).
5. **No-wrap root cause (universal)** — `tui-kit` used `list.Cursor()` (page-local) as the scan start and for `Index()`, so page-crossing/selection-preservation were wrong (the "cursor goes past Close and back to the first" report). Now uses `list.Index()` (absolute); the Move Manager also got a `navPicker` wrapper that selects by absolute index and dead-stops at both ends.
6. **New setting "Ableton auto-close & project save: On/Off"** (pref `ABLETON_AUTOCLOSE_SAVE`, default On) right after the ydotool row, with deferred-apply. On = existing behaviour. Off = open Ableton, wait for the user to close it, detect the `.als` saved by this session, move it into `$MOVE_DIR/als` as `… (backup).als` (never overwriting, left untouched if already in place), then open in Bitwig (respecting the ydotool setting). README documents both.
7. Redeployed move/audio/live TUIs + cores (19:27); `hyprctl configerrors` clean.


**Follow-up 24 (2026-09-18)**: Schwung detection, Bitwig vendor folder, TUI polish, on-device module uninstall.

1. **Schwung falsely "not installed"** — `schwung_status_json` required HTTP 200 but the manager answers 303; now accepts 2xx/3xx (verified live: `installed:true`).
2. **Bitwig controller scripts under a vendor folder** — installed into `~/Documents/Bitwig Studio/Controller Scripts/Ableton/Move/` (was flat at the root) so Bitwig lists vendor **Ableton → Move**; detection/install/uninstall updated; the tip now says to restart Bitwig (or rescan Controllers) and leads with "choose vendor Ableton, then controller Move". Migrated the existing flat files live.
3. **Move module uninstall** — new "Uninstall the Move module from the device" row in the Move-as-Bitwig-controller menu (vendored uninstall.sh, else ssh rm), install+uninstall always offered; `onDevice` stays `unknown` when ssh fails (the Move's ssh key changed).
4. **TUI polish** — tui-kit renders terminal rows (Close/Back/Return/…) in an accent-filled box with contrast-aware text (same luminance pick as the mosquito banner), and gained a generic `Badge` slot; audio fixes list dropped the redundant `[plugin: X]` tag; the Plugin-fixes plugin chooser marks plugins that have applied fixes (`●` badge); the Plugin-window-handler confirm now fires immediately on the key and uses the Readme-style framed `InfoConfirm`. JOURNAL updated.
5. Redeployed all three TUIs + cores (19:54); `hyprctl configerrors` clean.


**Follow-up 25 (2026-09-18)**: stop the spurious Hyprland reload ("entering Plugin fixes reset my config").

- `apply_plugin_handler` (called on EVERY actions invocation via `load_prefs`) and `fix_write_block` unconditionally ran `hyprctl reload`, re-applying the whole config (monitors/autostart/rules) → perceived as a desktop reset. Both now snapshot the file and reload ONLY when the content actually changed (`cmp -s`), so merely opening screens/actions no longer reloads anything (verified: an action leaves hyprland.lua byte-identical, no reload, `configerrors` clean). `fix_write_block`'s strip regex is also bounded against the next start marker + gated by the preamble guard. Applying/removing a fix still triggers ONE reload (file-based Hyprland rules need it).


**Follow-up 26 (2026-09-18)**: Schwung download, Bitwig native controller path, Plugin-fixes badge, tip/prompt UI.

1. **Schwung install/update/uninstall failed** — `schwung_run_installer` overwrote the URL variable with the temp path before `curl`, so it always failed to download. Now the URL and temp file are distinct (`scripts/install.sh` / `scripts/uninstall.sh` on the repo are valid, 200). Also capitalised "Schwung" in all user-facing strings.
2. **Bitwig controller scripts path** — Bitwig on Linux watches `~/Bitwig Studio/Controller Scripts` (confirmed in `~/.BitwigStudio/log/BitwigStudio.log`), NOT `~/Documents/Bitwig Studio/...`. `BITWIG_CONTROLLERS_ROOT` corrected and the files migrated live under `~/Bitwig Studio/Controller Scripts/Ableton/Move/`; detection reports `controllers:true`. Restart Bitwig (or rescan Controllers) to see vendor **Ableton → Move**.
3. **Plugin-fixes applied marker** — root cause: the chooser reuses the Installed-plugins tree which starts with every folder collapsed, and folder rows were skipped by the badge pass, so the badged child was never drawn. Now folders containing a matching plugin auto-expand on entry, the row gets a distinct `★` accent badge, and the parent folder is badged too. (The backend/action/canonicalisation were already correct.)
4. **Bitwig tip** — prompt changed to "Open Bitwig to set up the controller in Settings?" (No/Yes); the tip body renders through `tuikit.Info` (same framed modal as the Readme) and leads with the vendor/controller wording.
5. **Stuck prompt** — removing the Move module / controller scripts now pops the confirm+runner on success OR failure (with the right toast); previously the runner's pop landed back on the open confirm until "keep".
6. Redeployed all three TUIs (20:40); `hyprctl configerrors` clean.

## Open TODO (added)
- Trackpad scroll stops working in the browser and some apps (works again under a default "emergency" Hyprland config) — investigate the user Hyprland/input config (likely a rule/option in `hyprland.lua` or the touchpad module), reproduce and fix.


**Follow-up 27 (2026-09-18)**: Ableton→Bitwig post-save pipeline completed; `test-ableton.sh` removed.

- Added `ableton_window_count` + `wait_ableton_windows_closed_stable` (stable close gate: window count must stay 0 for 3 consecutive checks) and `wait_for_als_stable` (size+mtime unchanged across polls). `wait_ableton_close_manual` (Off path) and `wait_ableton_close` (On path) now use the stable gate, so Wine/DXGI/JUCE teardown never races detection. `detect_new_als` emits the chosen path only after stabilization. Decision unchanged (in WORKDIR → open directly; else `<name> - backup/` folder + copy, open the copy), and the resolved path flows to `finish_bitwig_open` (Bitwig opens only after save + close). The existing Ctrl+Q/Enter/xdotool/window-detection code was NOT touched. Scratch `test-ableton.sh` deleted.
