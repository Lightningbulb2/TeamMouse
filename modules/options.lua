--******************************************************************************
--** TeamMouse -- modules/options.lua
--**
--** The settings ReUI can change (ReUI.Options), as one list: what each is
--** called, its tooltip, what kind of control it gets, and which field of
--** config.lua it sets. Main.lua and Options.lua at the mod's root are ReUI's
--** entry points and only go through this file; optionswindow.lua draws the
--** window (tooltips, scrollbar).
--**
--** ReUI is optional. Without it nothing here runs and config.lua's own values
--** stand. With it, its saved values are written into Config when it loads us,
--** and every change after that is written straight in too -- the rest of the
--** mod reads Config as it goes, so most take effect at once. Those read only
--** when a cursor is made (names, their size, the zoom bar) rebuild every
--** cursor, through _G.TeamMouseRebuild (set by teammouse.lua for the length of
--** a game; nothing to rebuild outside one).
--**
--** Every setting here is about what YOU are shown. None changes what you
--** send: teammates (and the replay) always get everything, and each of them
--** picks what they show with their own settings. Network and Protocol must
--** match between players and are not offered.
--**
--** ReUI's own option values (ReUI.Options.Opt -> OptionVar, the current
--** ReUI: read by calling it, :Set, OnChange, :Save/:Reset) and the older shape
--** some mods were written against (OptionValue: :Get, OnChanged:Add) are both
--** understood.
--**
--** No imports but config.lua: ReUI may load this before the game's interface
--** (and teammouse.lua) exists.
--******************************************************************************

local Config = import((rawget(_G, 'TeamMousePath') or '/mods/TeamMouse') .. '/modules/config.lua')

--- ReUI's name for the mod's options (also /mods/<name>/Options.lua).
MOD_KEY = 'TeamMouse'
TITLE = 'TeamMouse'

--- kind: 'title' (a heading), 'toggle' (a checkbox, boolean), 'percent' (a
--- slider in percent of a 0..1 or scale value), 'number' (a slider, the value
--- itself). path: the field of Config it sets. tip: the tooltip. rebuild:
--- only read when a cursor is made, so cursors are rebuilt on change.
Spec = {
    { kind = 'title', label = 'Their cursor' },
    { key = 'showNames', label = 'Show player names', kind = 'toggle', path = { 'Appearance', 'ShowLabels' }, rebuild = true,
        tip = 'Each teammate\'s name under their cursor.' },
    { key = 'nameSize', label = 'Name font size', kind = 'number', path = { 'Appearance', 'LabelSize' }, min = 8, max = 20, step = 1, rebuild = true,
        tip = 'How big the names under cursors are.' },
    { key = 'nameBar', label = 'Zoom bar under names', kind = 'toggle', path = { 'Appearance', 'NameBar' }, rebuild = true,
        tip = 'A bar in their colour under their name showing how far THEY are zoomed: as wide as the name zoomed all the way in, a dot zoomed all the way out.' },
    { key = 'opacity', label = 'Cursor opacity', kind = 'percent', path = { 'Appearance', 'BaseAlpha' }, min = 10, max = 100, step = 5,
        tip = 'How opaque teammates\' cursors are before any fading. Zoomed far out they get more opaque so they are easy to find.' },
    { key = 'size', label = 'Cursor size', kind = 'percent', path = { 'Appearance', 'SizeScale' }, min = 50, max = 200, step = 5,
        tip = 'Draw every teammate\'s cursor this much larger or smaller, on top of the zoom scaling.' },
    { key = 'zoomScale', label = 'Scale cursors by teammate zoom', kind = 'toggle', path = { 'Zoom', 'Enabled' },
        tip = 'A teammate zoomed further out than you draws larger (they are working over a wider area), one zoomed in draws smaller.' },
    { key = 'zoomMin', label = 'Smallest zoom scale', kind = 'percent', path = { 'Zoom', 'MinScale' }, min = 30, max = 100, step = 5,
        tip = 'The smallest the zoom scaling may draw a cursor.' },
    { key = 'zoomMax', label = 'Largest zoom scale', kind = 'percent', path = { 'Zoom', 'MaxScale' }, min = 100, max = 250, step = 5,
        tip = 'The largest the zoom scaling may draw a cursor.' },
    { key = 'proximity', label = 'Fade cursors near your mouse', kind = 'toggle', path = { 'Proximity', 'Enabled' },
        tip = 'A teammate\'s cursor fades as your own mouse comes near it, so it won\'t block what you want to click.' },
    { key = 'nearAlpha', label = 'Opacity near your mouse', kind = 'percent', path = { 'Proximity', 'MinAlpha' }, min = 0, max = 100, step = 5,
        tip = 'How faint another cursor gets with your mouse right on it.' },
    { key = 'replayHover', label = 'Replay: opacity when hovered', kind = 'percent', path = { 'ReplayCodec', 'HoverMinAlpha' }, min = 0, max = 100, step = 5,
        tip = 'How faint another cursor gets with your mouse over it while watching a replay.' },
    { key = 'hud', label = 'Interface ghost', kind = 'toggle', path = { 'Hud', 'Enabled' },
        tip = 'While a teammate\'s pointer is on their own interface, show a small picture of it (in their faction\'s colours)' },

    { kind = 'title', label = 'What others are doing' },
    { key = 'build', label = 'Show building in their hand', kind = 'toggle', path = { 'Build', 'Enabled' },
        tip = 'The icon of the structure a teammate is about to place, beside their cursor.' },
    { key = 'lines', label = 'Show structure lines they drag', kind = 'toggle', path = { 'Line', 'Enabled' },
        tip = 'Line of icons when a teammate drags out a row of structures' },
    { key = 'boxes', label = 'Their selection boxes', kind = 'toggle', path = { 'Selection', 'ShowBox' },
        tip = 'The box a teammate drags to select units. Off, their cursor still moves with the drag.' },
    { key = 'drawing', label = 'Their drawings', kind = 'toggle', path = { 'Draw', 'Enabled' },
        tip = 'What a teammate draws on the map (right button held with nothing selected), as a fading trail, before the game shows it.' },
    { key = 'orders', label = 'Their orders', kind = 'toggle', path = { 'Orders', 'Enabled' },
        tip = 'A marker where a teammate orders units (with the order\'s icon), and formation lines. Off hides every kind below too.' },
    { key = 'builds', label = 'Structures they place', kind = 'toggle', path = { 'Orders', 'ShowBuilds' },
        tip = 'The structures a teammate places, on the spot, framed in their colour.' },
    { key = 'upgrades', label = 'Their upgrades', kind = 'toggle', path = { 'Orders', 'ShowUpgrades' },
        tip = 'What a building a teammate upgrades will become, on a gold diamond.' },
    { key = 'grabs', label = 'Orders they drag to a new spot', kind = 'toggle', path = { 'Orders', 'ShowGrabs' },
        tip = 'A teammate moving one of their waypoints: its icon in their hand, with a line back to where it was.' },
    { key = 'selections', label = 'Their selected units', kind = 'toggle', path = { 'TeamSelection', 'Enabled' },
        tip = 'A faint box on each unit a teammate selects.' },
    { key = 'clicks', label = 'Click pulses', kind = 'toggle', path = { 'ClickPulse', 'Enabled' },
        tip = 'A ring from the tip of a teammate\'s cursor when a click of theirs selects something.' },
    { key = 'actions', label = 'Action labels', kind = 'toggle', path = { 'Actions', 'Enabled' },
        tip = 'STOP, PAUSED, REPEAT ON and the like by a teammate\'s cursor when they do one.' },

    { kind = 'title', label = 'Player panel' },
    { key = 'panel', label = 'Player panel', kind = 'toggle', path = { 'Panel', 'Enabled' },
        tip = 'The list of players whose cursors you see, with boxes to hide each one, show their view, or follow them (replays and observers).' },
    { key = 'versions', label = 'Versions in the player panel', kind = 'toggle', path = { 'Panel', 'ShowVersions' },
        tip = 'Which version of TeamMouse each player is on. "old" means SharedMouse; "none", a teammate who never answered.' },
    { key = 'collapsed', label = 'Player panel starts folded', kind = 'toggle', path = { 'Panel', 'StartCollapsed' },
        tip = 'Start each game with the panel folded away to its tab.' },
    { key = 'followFit', label = 'Follow: fit their whole view', kind = 'toggle', path = { 'Follow', 'FitView' },
        tip = 'Following a player (replays, observing): their window is rarely the shape of yours, so fit their view by its larger axis. A narrower view keeps its height and you see more to the sides; a wider one keeps its width.' },
    { key = 'breakScrolls', label = 'Follow: scroll notches to stop', kind = 'number', path = { 'Follow', 'BreakScrolls' }, min = 0, max = 15, step = 1,
        tip = 'While following a player, scrolling the mouse wheel this many notches in quick succession (under a second) takes your camera back and unticks the follow box. Fewer are ignored, so a stray notch does not stop it. 0: scrolling never stops following.' },
    { key = 'views', label = 'View outlines ticked at game start', kind = 'toggle', path = { 'Viewport', 'Show' },
        tip = 'Start each game with every player\'s "view" box ticked: the outline of what their camera sees, on the map.' },
}

--- The table in Config holding an entry's field.
---@param entry table
---@return table | nil
local function Owner(entry)
    return entry.path and Config[entry.path[1]]
end

--- An entry's value as ReUI shows it, from Config (config.lua's default).
---@param entry table
---@return boolean | number
function Default(entry)
    local owner = Owner(entry)
    local value = owner and owner[entry.path[2]]
    if entry.kind == 'toggle' then
        return value and true or false
    end
    if type(value) ~= 'number' then
        value = entry.min
    end
    if entry.kind == 'percent' then
        value = math.floor(value * 100 + 0.5)
    end
    if value < entry.min then value = entry.min end
    if value > entry.max then value = entry.max end
    return value
end

--- Write a value from ReUI into Config.
---@param entry table
---@param value any
---@return boolean   # whether Config changed
function Apply(entry, value)
    local owner = Owner(entry)
    if type(owner) ~= 'table' then
        return false
    end
    local new
    if entry.kind == 'toggle' then
        new = value and true or false
    else
        if type(value) ~= 'number' or value ~= value then
            return false
        end
        if value < entry.min then value = entry.min end
        if value > entry.max then value = entry.max end
        new = value
        if entry.kind == 'percent' then
            new = value / 100
        end
    end
    if owner[entry.path[2]] == new then
        return false
    end
    owner[entry.path[2]] = new
    return true
end

--- An option's current value, whichever shape ReUI gave it.
---@param option any
---@return any
function Read(option)
    if type(option) == 'table' and type(option.Get) == 'function' then
        return option:Get()
    end
    local ok, value = pcall(option)
    if ok then
        return value
    end
end

--- Call fn(value) whenever an option changes, whichever shape it is.
---@param option table
---@param fn function
local function Watch(option, fn)
    if type(option.OnChanged) == 'table' and type(option.OnChanged.Add) == 'function' then
        option.OnChanged:Add(function(changed, value) fn(value) end)
        return
    end
    -- ReUI's OptionVar: Set calls self:OnChange(). Keep whatever was there.
    local previous = option.OnChange
    option.OnChange = function(self)
        if previous then
            previous(self)
        end
        fn(Read(self))
    end
end

--- Cursors are rebuilt once the change is in, if a game is running.
local function Rebuild()
    local rebuild = rawget(_G, 'TeamMouseRebuild')
    if rebuild then
        pcall(rebuild)
    end
end

--- ReUI's saved values into Config, and every change from now on.
---@param values table   # ReUI.Options.Mods[MOD_KEY]: key -> option
function Bind(values)
    if type(values) ~= 'table' then
        return
    end
    local rebuild = false
    for _, item in ipairs(Spec) do
        -- A local of this iteration's own (Lua 5.0 closures in loops).
        local entry = item
        local option = entry.key and values[entry.key]
        if option then
            if Apply(entry, Read(option)) and entry.rebuild then
                rebuild = true
            end
            Watch(option, function(value)
                if Apply(entry, value) and entry.rebuild then
                    Rebuild()
                end
            end)
        end
    end
    if rebuild then
        Rebuild()
    end
end

--- The controls for ReUI's own (table-built) options window: no tooltips
--- or scrollbar there, but it is what an older ReUI can draw.
---@param Builder table      # ReUI.Options.Builder
---@param values table       # ReUI.Options.Mods[MOD_KEY]
---@return table
function Controls(Builder, values)
    local out = {}
    for _, entry in ipairs(Spec) do
        local option = entry.key and values[entry.key]
        if entry.kind == 'title' then
            if Builder.Title then
                table.insert(out, Builder.Title(entry.label, 14))
            end
        elseif option then
            if entry.kind == 'toggle' then
                table.insert(out, Builder.Filter(entry.label, option))
            else
                table.insert(out, Builder.Slider(entry.label, entry.min, entry.max, entry.step, option))
            end
        end
    end
    return out
end

--- ReUI's option values, with config.lua's values as their defaults.
---@param Make? function   # ReUI.Options.Opt (or the older OptionValue); none: plain values
---@return table
function MakeValues(Make)
    local values = {}
    for _, entry in ipairs(Spec) do
        if entry.key then
            local default = entry.default
            if default == nil then default = Default(entry) end
            values[entry.key] = Make and Make(default) or default
        end
    end
    return values
end

--- Register the options window with ReUI: our own window (tooltips, a
--- scrollbar) where ReUI can take one, its table-built one otherwise.
---@param Builder table   # ReUI.Options.Builder
---@param values table    # ReUI.Options.Mods[MOD_KEY]
---@param ownWindow boolean
function Register(Builder, values, ownWindow)
    if ownWindow then
        Builder.AddOptions(MOD_KEY, TITLE, function(parent)
            local OptionsWindow = import((rawget(_G, 'TeamMousePath') or '/mods/TeamMouse')
                .. '/modules/optionswindow.lua')
            return OptionsWindow.Create(parent, TITLE, Spec, values)
        end)
    else
        Builder.AddOptions(MOD_KEY, TITLE, Controls(Builder, values))
    end
end

-- What config.lua ships, kept before ReUI's saved values are written in: the
-- options window's Defaults button puts these back.
for _, entry in ipairs(Spec) do
    if entry.key then
        entry.default = Default(entry)
    end
end
