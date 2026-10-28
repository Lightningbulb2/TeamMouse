--******************************************************************************
--** TeamMouse -- Options.lua (ReUI's options window)
--**
--** The settings, their tooltips and defaults come from modules/options.lua,
--** which takes the defaults from config.lua. The window itself, with
--** tooltips and a scrollbar, is modules/optionswindow.lua.
--******************************************************************************

local TeamMouseOptions = import('/mods/TeamMouse/modules/options.lua')

-- ReUI turns these into saved options (ReactiveOption) when they are assigned here.
ReUI.Options.Mods[TeamMouseOptions.MOD_KEY] = TeamMouseOptions.MakeValues(ReUI.Options.OptionValue)

function Main()
    TeamMouseOptions.Register(ReUI.Options, ReUI.Options.Mods[TeamMouseOptions.MOD_KEY])
end
