--******************************************************************************
--** TeamMouse -- Options.lua (ReUI's options window)
--**
--** The settings, their tooltips and defaults come from modules/options.lua,
--** which takes the defaults from config.lua. The window itself, with
--** tooltips and a scrollbar, is modules/optionswindow.lua.
--******************************************************************************

local TeamMouseOptions = import('/mods/TeamMouse/modules/options.lua')

-- Current ReUI: Opt. An older one: OptionValue. Either way ReUI turns these
-- into saved options when they are assigned here.
local Make = ReUI.Options.Opt or ReUI.Options.OptionValue
ReUI.Options.Mods[TeamMouseOptions.MOD_KEY] = TeamMouseOptions.MakeValues(Make)

function Main()
    local values = ReUI.Options.Mods[TeamMouseOptions.MOD_KEY]
    -- Our own window needs ReUI's OptionVar (Opt); an older ReUI gets its own
    -- table-built window, without tooltips.
    TeamMouseOptions.Register(ReUI.Options.Builder, values, ReUI.Options.Opt ~= nil)
end
