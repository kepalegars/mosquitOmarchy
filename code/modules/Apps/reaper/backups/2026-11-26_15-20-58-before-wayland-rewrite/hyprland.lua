-- Learn how to configure Hyprland: https://wiki.hypr.land/Configuring/Start/

-- Omarchy's bootstrap keeps path setup out of this user config.
dofile((os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua")

-- Disable all Omarchy default bindings. Add your own in hypr/bindings.lua.
-- omarchy_default_bindings = false
--
-- Or disable only bindings for Omarchy's preinstalled apps/web apps while
-- keeping core window-manager bindings:
-- omarchy_preinstalled_bindings = false

-- Load Omarchy defaults.
require("default.hypr.omarchy")

-- Put your personal overrides in these files. They're loaded after Omarchy's
-- defaults so package updates can improve the defaults without rewriting your
-- ~/.config/hypr files.
require("hypr.monitors")
require("hypr.input")
require("hypr.bindings")
require("hypr.looknfeel")
require("hypr.autostart")

-- Toggle config flags dynamically.
require("default.hypr.toggles")

-- Add any other personal Hyprland configuration below.
-- o.window("qemu", { workspace = "5" })

-- >>> ableton-setup >>> Ableton Live window handling.
--
-- Five concerns:
--   1. the Windows installer (wine / XWayland) floats — it is a small
--      wizard with its own sizing and it crashes the tiled layout otherwise;
--   2. every Ableton window is fully opaque, because Omarchy's default
--      translucency makes a dark DAW unreadable;
--   3. everything with Live's class floats: VST/VST3 editors and Live's own
--      dialogs/popups share WM class "ableton live 12 <edition>.exe" with the
--      main window (verified with hyprctl clients), so a class-only
--      float=false tiled every plugin GUI;
--   4. the main window is the exception and tiles, recognised by its title
--      suffix "<project> - Ableton Live 12 <Edition>" (verified at map time:
--      "Untitled - Ableton Live 12 Suite"). No center/size on this class: a
--      Wine plugin editor moved away from the origin gets offset mouse
--      coordinates (yabridge#409). float=false only, no tile=true: the
--      explicit tile rule broke fullscreen. Later rules win, hence the order;
--   5. no Ableton window may take focus on its own, including the main one
--      at launch: no_initial_focus suppresses map focus and
--      focus_on_activate suppresses activation requests. Click to focus.
o.window({ class = "^ableton live 12 .*install.*$" }, { float = true, no_initial_focus = true })
o.window({ class = "^ableton.*$" }, { tag = "-default-opacity", opaque = true, no_initial_focus = true, focus_on_activate = false })
o.window({ class = "^ableton live 12 (suite|standard|intro)\\.exe$" }, { float = true, no_blur = true })
o.window({ class = "^ableton live 12 (suite|standard|intro)\\.exe$", title = ".* - Ableton Live 12 (Suite|Standard|Intro)$" }, { float = false })
-- <<< ableton-setup <<<
-- >>> mosquito-davinci-tiling >>> Resolve opens tiled, not fullscreen.
-- Omarchy's default app rule floats Resolve and fullscreens the project window
-- (usr/share/omarchy/default/hypr/apps/davinci-resolve.lua). Later rules win:
-- undo both for the main project window only; the Project Manager stays floating.
o.window({ class = ".*[Rr]esolve.*", title = "^DaVinci Resolve( Studio)? - .+$" }, { float = false, fullscreen = false })
-- <<< mosquito-davinci-tiling <<<
-- The Hyprland rules for REAPER.
--
-- This file IS the block. It used to live inside a heredoc in setup-reaper.sh,
-- which made it dangerous to extract: the markers also appear in that script's
-- own `sed -i` line, so a range match printed the surrounding shell too and put
-- `cat >> "$CONF" <<'EOF'` into the user's hyprland.lua -- a Lua syntax error
-- near '>>' that silently killed every rule after it. Nothing here is shell, so
-- there is nothing left to match by accident.
--
-- reaper-apply-block injects it between the >>> / <<< markers. Do not edit the
-- copy in ~/.config/hypr/hyprland.lua: it is overwritten from here.







-- >>> mosquito-wine-tray-setup >>> hide Wine's standalone "System Tray" window
o.window({ class = "(?i)^explorer\\.exe$" }, { workspace = "special:wine-tray", no_focus = true, no_anim = true, no_blur = true })
-- <<< mosquito-wine-tray-setup <<<

-- >>> Omarchy_Custom_Scripts_Handbrake
-- HandBrake (Qt6 / Wayland): opaque window, exempt from the default opacity
-- (avoids rendering artifacts while encoding / previewing).
o.window({ class = "^org\\.handbrake\\.ghb$|^ghb$|^HandBrake$" }, { tag = "-default-opacity", opaque = true })
-- <<< Omarchy_Custom_Scripts_Handbrake
-- >>> mosquito-dialogs-handbrake >>> handbrake: main window TILED, dialogs/menus float
-- at the pointer without stealing focus (the Zoom-recipe fix, applied to this
-- app alone). See code/lib/hypr-dialogs.sh for the rationale + word list.
o.window({ class = "^(?i)org\\.handbrake\\.ghb$|^(?i)ghb$|^(?i)HandBrake$" }, { float = false, tile = true })
o.window({ class = "^(?i)org\\.handbrake\\.ghb$|^(?i)ghb$|^(?i)HandBrake$", title = "^(?i)(^save\\b|^save as\\b|^open\\b|^import\\b|^export\\b|^print\\b|^options\\b|^preferences\\b|^settings\\b|^properties\\b|^rename\\b|^confirm\\b|^error\\b|^warning\\b|^choose\\b|^choosefolder\\b|^browse\\b|^select\\b|^select folder\\b|^select file\\b|^select device\\b|^select destination\\b|^progress\\b|^please wait\\b|^are you sure\\b|^question\\b|^information\\b|^alert\\b|^dialog\\b)" }, { float = true, no_initial_focus = true, move = { "cursor_x-(window_w*0.5)", "cursor_y-(window_h*0.5)" } })
-- <<< mosquito-dialogs-handbrake <<<


-- >>> mosquito_fix_wine_gui_input
-- mosquito fix: Wine plugin GUI input (Hyprland/XWayland) — applied for: Addictive Drums 2 Airwindows Consolidated Analog Lab V Archetype Nolly Auto-Key Basslane Pro FabFilter Micro HyperTune Keyscape LANDR Mastering Pro Ozone 12 Bass Control RX 11 Breath Control Serum2 SubLabXL Tape MELLO-FI ValhallaDelay iZNeutron5VisualMixer smartEQ4 smartcomp3 smartgate smartreverb2
-- Keeps wine/yabridge plugin editor windows floating + unblurred.
o.window({ class = "^(yabridge-.*|.*\\.exe|wine.*)$" }, { float = true, no_blur = true })
o.window({ title = "(?i).*Addictive Drums 2.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*Airwindows Consolidated.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*Analog Lab V.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*Archetype Nolly.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*Auto-Key.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*Basslane Pro.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*FabFilter Micro.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*HyperTune.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*Keyscape.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*LANDR Mastering Pro.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*Ozone 12 Bass Control.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*RX 11 Breath Control.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*Serum2.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*SubLabXL.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*Tape MELLO-FI.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*ValhallaDelay.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*iZNeutron5VisualMixer.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*smartEQ4.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*smartcomp3.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*smartgate.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
o.window({ title = "(?i).*smartreverb2.*", xwayland = true }, { float = true, no_blur = true, allows_input = true })
-- <<< mosquito_fix_wine_gui_input

-- >>> Omarchy_Custom_Scripts_OmarchyVm
-- Omarchy VM Manager TUI: floating centered window (setup-omarchy-vm.sh)
o.window("org.omarchy.omarchy-vm-tui", {
  float = true,
  center = true,
  size = { 920, "920 * monitor_h / monitor_w" },
})
-- Omarchy VM keyboard: toggle where SUPER+… goes (the "focus").
-- NORMAL (default): the host keeps ALL its shortcuts, so you can fullscreen
-- the VM window (SUPER + F), move it, switch workspaces, etc.
-- SUPER + ALT + V: focus the VM — every SUPER+… shortcut goes to the in-VM
-- Omarchy instead; press it again to focus the host. Every press pops a
-- compositor notification (hyprctl notify, drawn on top even in fullscreen)
-- saying where the focus is. Both Omarchy shortcut sets therefore coexist.
o.bind("SUPER + ALT + V", "Omarchy VM: focus the VM / host shortcuts", "omarchy-vm-focus")
hl.define_submap("omarchy-vm", function()
  o.bind("SUPER + ALT + V", "Omarchy VM: focus the VM / host shortcuts", "omarchy-vm-focus")
end)
-- <<< Omarchy_Custom_Scripts_OmarchyVm
-- >>> mosquito-audio-plugin-manager-tui-setup >>> one size for every mosquito TUI: width from the
-- column grid at the screen DPI, height from the monitor ratio.
o.window("org.omarchy.mosquito-audio-plugin-manager-tui", {
  float = true,
  center = true,
  size = { 920, "920 * monitor_h / monitor_w" },
})
-- <<< mosquito-audio-plugin-manager-tui-setup <<<
-- >>> mosquito-dialogs-betterbird >>> betterbird: every window floats, centered at ~80%
-- of the screen (monitor-relative size, so it follows resolution and ratio);
-- nothing tiles. Same shape as the KeePassXC rule.
o.window({ class = "^(?i)eu\\.betterbird\\.Betterbird$|^(?i)betterbird$" }, { float = true, center = true, size = { "monitor_w*0.78", "monitor_h*0.83" } })
-- <<< mosquito-dialogs-betterbird <<<
-- >>> keepassxc-window-setup >>> KeePassXC is a fixed-size password window:
-- float and center it instead of tiling it. Matches the native Wayland app-id
-- and the XWayland class (StartupWMClass=keepassxc). Monitor-relative size, so
-- the panel keeps its footprint on a laptop and on a 4K screen. Managed by the
-- keepassxc module — no separate tweak to apply.
o.window("org.keepassxc.KeePassXC", { float = true, center = true, size = { "monitor_w*0.65", "monitor_h*0.73" } })
o.window({ class = "(?i)^keepassxc$" }, { float = true, center = true, size = { "monitor_w*0.65", "monitor_h*0.73" } })
-- <<< keepassxc-window-setup <<<
-- >>> extracto-setup >>> Archive manager window. file-roller is a GTK4 dialog
-- (and its "Create archive" sheet is a second window): float + center it so an
-- archive is not squeezed into a tiled slot, exempt it from the default window
-- opacity so contents stay legible over other windows, and no blur (the dialog
-- draws its own drop area). This is a per-class rule; nothing else is forced.
o.window({ class = "^(File-roller|file-roller|org.gnome.FileRoller)$" }, { tag = "-default-opacity", float = true, center = true, size = { "monitor_w*0.59", "monitor_h*0.65" }, opaque = true, no_blur = true })
-- <<< extracto-setup <<<
-- >>> live-mode-tui-floating >>> one size for every mosquito TUI: width from the
-- column grid at the screen DPI, height from the monitor ratio.
o.window("org.omarchy.mosquito-live-mode-tui", {
  float = true,
  center = true,
  size = { 920, "920 * monitor_h / monitor_w" },
})
-- <<< live-mode-tui-floating <<<
-- >>> guitarpro-tiling >>> tile Guitar Pro 8 (overrides the generic .exe float: later rules win).
o.window({ class = "^guitarpro\\.exe$" }, { float = false, tile = true })
o.window({ class = "^guitarpro\\.exe$" }, { focus_on_activate = false })
-- <<< guitarpro-tiling <<<
-- >>> mosquito-dialogs-guitarpro.exe >>> float guitarpro.exe's dialog windows (titles) at the
-- pointer, no initial focus; the main window is left to its own tiling rule.
-- Matching the known dialog titles is the only signal Hyprland has for an
-- XWayland dialog: it shares its main window's class. See code/lib/
-- hypr-dialogs.sh for the full rationale and the word list.
o.window({ class = "^(?i)guitarpro.exe.*$", title = "^(?i)(^save\\b|^save as\\b|^open\\b|^import\\b|^export\\b|^print\\b|^options\\b|^preferences\\b|^settings\\b|^properties\\b|^rename\\b|^confirm\\b|^error\\b|^warning\\b|^choose\\b|^choosefolder\\b|^browse\\b|^select\\b|^select folder\\b|^select file\\b|^select device\\b|^select destination\\b|^progress\\b|^please wait\\b|^are you sure\\b|^question\\b|^information\\b|^alert\\b|^dialog\\b)" }, { float = true, no_initial_focus = true, move = { "cursor_x-(window_w*0.5)", "cursor_y-(window_h*0.5)" } })
-- <<< mosquito-dialogs-guitarpro.exe <<<
-- >>> mosquitomarchy-tui-floating >>> one size for every mosquito TUI: width from the
-- column grid at the screen DPI, height from the monitor ratio.
o.window("org.omarchy.mosquitomarchy-tui", {
  float = true,
  center = true,
  size = { 920, "920 * monitor_h / monitor_w" },
})
-- <<< mosquitomarchy-tui-floating <<<
-- >>> mosquito-mixbay-tui-setup >>> float mosquito-mixbay-tui
-- One size for every mosquito TUI (code/lib/hypr-tui.sh): width from the
-- column grid at the screen DPI, height from the monitor ratio.
o.window("org.omarchy.mosquito-mixbay-tui", { float = true, center = true, size = { 920, "920 * monitor_h / monitor_w" } })
o.window("org.omarchy.mosquito-mixbay-scratchpad", { float = true, center = true, size = { "monitor_w*0.65", "monitor_h*0.81" } })
-- <<< mosquito-mixbay-tui-setup <<<
-- >>> move-manager-tui-setup >>> one size for every mosquito TUI: width from the
-- column grid at the screen DPI, height from the monitor ratio.
o.window("org.omarchy.mosquito-move-manager-tui", {
  float = true,
  center = true,
  size = { 920, "920 * monitor_h / monitor_w" },
})
-- <<< move-manager-tui-setup <<<
-- >>> move-manager-webapp-setup >>> float & center the Move Manager webapp
-- (a Chromium --app= window titled "Move Manager") instead of tiling it at
-- some small grid fraction. Matches any Chromium class with that page title,
-- so regular Chromium windows are unaffected. Monitor-relative size, so the
-- panel keeps the same footprint on any screen.
o.window({ class = "[cC]hrom.*", title = "^Move Manager" }, { float = true, center = true, size = { "monitor_w*0.72", "monitor_h*0.75" } })
-- <<< move-manager-webapp-setup <<<
-- The Hyprland rules for REAPER.
--
-- This file IS the block. It used to live inside a heredoc in setup-reaper.sh,
-- which made it dangerous to extract: the markers also appear in that script's
-- own `sed -i` line, so a range match printed the surrounding shell too and put
-- `cat >> "$CONF" <<'EOF'` into the user's hyprland.lua -- a Lua syntax error
-- near '>>' that silently killed every rule after it. Nothing here is shell, so
-- there is nothing left to match by accident.
--
-- reaper-apply-block injects it between the >>> / <<< markers. Do not edit the
-- copy in ~/.config/hypr/hyprland.lua: it is overwritten from here.


-- The Hyprland rules for REAPER.
--
-- This file IS the block. It used to live inside a heredoc in setup-reaper.sh,
-- which made it dangerous to extract: the markers also appear in that script's
-- own `sed -i` line, so a range match printed the surrounding shell too and put
-- `cat >> "$CONF" <<'EOF'` into the user's hyprland.lua -- a Lua syntax error
-- near '>>' that silently killed every rule after it. Nothing here is shell, so
-- there is nothing left to match by accident.
--
-- reaper-apply-block injects it between the >>> / <<< markers. Do not edit the
-- copy in ~/.config/hypr/hyprland.lua: it is overwritten from here.


-- >>> mosquito-no-autofocus >>> smart focus: the app you are using keeps it
-- New windows never focus themselves (no_initial_focus) and activation
-- requests are ignored (focus_on_activate); the callbacks hand focus back
-- only to a window of the app already focused — same PID, or same non-empty
-- class (Wine dialogs share the main window's PID/class). Pointer-follow stays
-- at the Omarchy default, and no_warps keeps the pointer where it is when
-- focus changes. Remove with: fix-hyprland-autofocus.sh --remove
hl.config({
  misc = { focus_on_activate = false },
  cursor = { no_warps = true },
})
o.window(".*", { no_initial_focus = true })

local function mosquito_same_app(a, b)
  if not a or not b then return false end
  if a.pid == b.pid then return true end
  return a.class ~= "" and a.class == b.class
end

local function mosquito_focus_if_same_app(w)
  if not w or w.active or not w.mapped then return end
  local focused = hl.get_active_window()
  if not focused or mosquito_same_app(w, focused) then
    hl.dispatch(hl.dsp.focus({ window = "address:" .. w.address }))
  end
end

-- An app explicitly asking for focus: Wine dialogs, save prompts, activation.
hl.on("window.urgent", mosquito_focus_if_same_app)
-- New native Wayland windows. XWayland is skipped: Wine menus and tooltips
-- also arrive as windows; real XWayland dialogs come through `urgent`.
hl.on("window.open", function(w)
  if w.xwayland then return end
  mosquito_focus_if_same_app(w)
end)
-- <<< mosquito-no-autofocus <<<
-- The Hyprland rules for REAPER.
--
-- This file IS the block. It used to live inside a heredoc in setup-reaper.sh,
-- which made it dangerous to extract: the markers also appear in that script's
-- own `sed -i` line, so a range match printed the surrounding shell too and put
-- `cat >> "$CONF" <<'EOF'` into the user's hyprland.lua -- a Lua syntax error
-- near '>>' that silently killed every rule after it. Nothing here is shell, so
-- there is nothing left to match by accident.
--
-- reaper-apply-block injects it between the >>> / <<< markers. Do not edit the
-- copy in ~/.config/hypr/hyprland.lua: it is overwritten from here.

-- The Hyprland rules for REAPER.
--
-- This file IS the block. It used to live inside a heredoc in setup-reaper.sh,
-- which made it dangerous to extract: the markers also appear in that script's
-- own `sed -i` line, so a range match printed the surrounding shell too and put
-- `cat >> "$CONF" <<'EOF'` into the user's hyprland.lua -- a Lua syntax error
-- near '>>' that silently killed every rule after it. Nothing here is shell, so
-- there is nothing left to match by accident.
--
-- reaper-apply-block injects it between the >>> / <<< markers. Do not edit the
-- copy in ~/.config/hypr/hyprland.lua: it is overwritten from here.

-- The Hyprland rules for REAPER.
--
-- This file IS the block. It used to live inside a heredoc in setup-reaper.sh,
-- which made it dangerous to extract: the markers also appear in that script's
-- own `sed -i` line, so a range match printed the surrounding shell too and put
-- `cat >> "$CONF" <<'EOF'` into the user's hyprland.lua -- a Lua syntax error
-- near '>>' that silently killed every rule after it. Nothing here is shell, so
-- there is nothing left to match by accident.
--
-- reaper-apply-block injects it between the >>> / <<< markers. Do not edit the
-- copy in ~/.config/hypr/hyprland.lua: it is overwritten from here.

-- The Hyprland rules for REAPER.
--
-- This file IS the block. It used to live inside a heredoc in setup-reaper.sh,
-- which made it dangerous to extract: the markers also appear in that script's
-- own `sed -i` line, so a range match printed the surrounding shell too and put
-- `cat >> "$CONF" <<'EOF'` into the user's hyprland.lua -- a Lua syntax error
-- near '>>' that silently killed every rule after it. Nothing here is shell, so
-- there is nothing left to match by accident.
--
-- reaper-apply-block injects it between the >>> / <<< markers. Do not edit the
-- copy in ~/.config/hypr/hyprland.lua: it is overwritten from here.

-- own `sed -i '/-- >>> reaper-setup >>>/,/-- <<< reaper-setup <<</d'` line, so a
-- range match printed the surrounding shell too. That put
-- `cat >> "$CONF" <<'EOF'` into the user's hyprland.lua -- a Lua syntax error
-- near '>>' that silently killed every rule after it. Nothing here is shell, so
-- there is nothing left to match by accident.
--
-- reaper-apply-block injects it between the >>> / <<< markers. Do not edit the
-- copy in ~/.config/hypr/hyprland.lua: it is overwritten from here.

-- >>> reaper-setup >>> main window tiled ; every other REAPER-classed window
-- (prefs, save confirmation, media explorer, any dialog) floating, opaque, no
-- blur, exempt from the Omarchy default opacity. REAPER reuses the "REAPER"
-- class for all of its windows, so the main window is told apart by its title,
-- which always contains "REAPER v<version>" (unlike prefs/dialogs).
--
-- WHY center IS NOT FORCED ANY MORE. It used to be on the broad rule, so that
-- REAPER's own dialogs would not open flush against the monitor's top-left
-- corner. That is a cosmetic problem, and it was paid for with a functional
-- one: a VST3 editor window is also classed REAPER, and `center` MOVES it away
-- from the screen origin. Wine's X11 window embedding computes the pointer
-- coordinates a VST editor receives from its own window's position, so under
-- XWayland an editor that is not at (0,0) gets every click offset by that
-- distance -- the window is visible, the knobs highlight, nothing you click
-- does what you aimed at. Reported upstream for exactly this stack
-- (REAPER + yabridge + Wine >= 9.22 + Wayland) in robbert-vdh/yabridge#409,
-- where the documented behaviour is "they do not even register mouse input"
-- and the workaround is to nudge the window by a pixel.
--
-- Letting the editor sit where REAPER puts it keeps REAPER's own placement
-- (the pre-existing behaviour) and, for an editor that happens to open near
-- the origin, the offset stays small. Nothing is forced onto the plugin
-- windows any more.
o.window({ class = "^REAPER$" }, { tag = "-default-opacity", float = true, opaque = true, no_blur = true })
o.window({ class = "^REAPER$", title = ".*REAPER v[0-9].*" }, { float = false, tile = true })
--
-- REAPER's own small modal dialogs -- the unsaved-changes / save confirmation
-- ("REAPER Query") and its error/warning/info boxes ("REAPER Error", ...) --
-- are bare Win32 message boxes (measured: 234x66 and 194x77) that Wine maps at
-- (0,0), so they showed up as tiny boxes glued to the monitor's top-left
-- corner. Matching them by TITLE is what makes this safe: the class is the
-- same "REAPER" as every dialog and as a VST3 editor window, but a plugin
-- editor's title is the plugin's own name ("Serum", "ReaEQ"), never one of
-- these, and the main window's title ("REAPER v7.79 - EVALUATION LICENSE")
-- cannot match "^REAPER " followed by a dialog word. So this rule cannot move
-- an editor and cannot reintroduce the yabridge#409 click-offset bug.
o.window({ class = "^REAPER$", title = "^REAPER (Query|Error|Warning|Info|Message|MsgBox|Confirm)$" }, { float = true, no_initial_focus = true, size = { 440, 200 }, move = { "cursor_x-(window_w*0.5)", "cursor_y-(window_h*0.5)" } })
--
-- There is deliberately NO keybinding here for the UI scale. It was tried, and
-- it was the wrong shape: REAPER reads ui_scale once at startup and writes its
-- own value back to reaper.ini on exit, so the only moment the value can be
-- set is before the process exists -- which means a keypress could never be
-- correct, only "run it before you launch REAPER and remember".
--
-- Instead the launcher does it. ~/.local/bin/reaper-launch runs reaper-ui-scale
-- before exec, so launching REAPER from the Omarchy menu, from the desktop
-- entry or from a shell all produce the right DPI with nothing to remember.
-- The launcher is generated by code/lib/wine-runtime-daw.bash, which is
-- where that hook lives; run setup after changing either side.
-- <<< reaper-setup <<<
