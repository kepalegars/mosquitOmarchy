-- Start script: Loop & record color (Reapertips)
local loop_color_cmd_name = '_RSc563f21d6168a434599c8616442bc055d465ae46'
reaper.Main_OnCommand(reaper.NamedCommandLookup(loop_color_cmd_name), 0)

-- Start script: Project Launcher
reaper.SetExtState('RTIPS.ProjectLauncher', 'startup', '1', false)
local launcher_cmd_name = '_RS7df81f4a0eea01208f22396bdf933be8c6a3fa28'
-- reaper.Main_OnCommand(reaper.NamedCommandLookup(launcher_cmd_name), 0)

