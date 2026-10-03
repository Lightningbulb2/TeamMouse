--******************************************************************************
--** TeamMouse -- Main.lua (ReUI entry point)
--**
--** Loaded by ReUI only (see `ReUI` in mod_info.lua); without ReUI this file
--** is never run and TeamMouse uses config.lua as it is. Passes ReUI's saved
--** settings, and every later change, into Config: modules/options.lua.
--******************************************************************************

Version = '1.0.0'

ReUI.Require
{
    'ReUI.Options >= 1.0.0',
}

function Main()
    local Options = import('/mods/TeamMouse/modules/options.lua')
    Options.Bind(ReUI.Options.Mods[Options.MOD_KEY])
end
