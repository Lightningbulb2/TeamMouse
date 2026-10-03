--******************************************************************************
--** TeamMouse -- modules/version.lua
--**
--** Which version of TeamMouse each player is on, for the version column of
--** the player panel (panel.lua): theirs, "old" for a teammate on the older
--** SharedMouse, "none" for a teammate who never answered.
--**
--** Each player sends its version once, on the mod's own chat channel, to the
--** same recipients as the cursor data (teammates and observers), and records
--** it into the replay when recording one. It is handled before the
--** wire-format check, so a teammate on an incompatible build still shows --
--** which is exactly when it matters.
--**
--** (This used to post lines in chat as well. The panel says it now.)
--******************************************************************************

local Config = import(_G.TeamMousePath .. '/modules/config.lua')

local state = {
    started = false,   -- Start has been called this session
    announced = false, -- our version sent
    checked = false,   -- VersionReport.CheckDelay has passed: silence means "none"
    startT = 0,
    expect = {},       -- names of the teammates we expect to hear from
    legacy = {},       -- name -> true: SharedMouse packets seen from them
    send = false,      -- function(msg): sends to our recipients
    seen = {},         -- name -> version, from anyone (observers and replays too)
    record = false,    -- function(msg): records our version into the replay (SetRecorder)
    recorded = false,
}

--- Colours for the panel's version column.
local SAME_COLOR = 'ff8fd18f'
local OTHER_COLOR = 'ffffb040'
local NONE_COLOR = 'ffcc6666'
local UNKNOWN_COLOR = 'ff808080'

--- Begin: who to expect, and how to reach them.
---@param expect string[]   # teammates' names (not our own)
---@param send function     # send(msg) to our recipients
---@param now number
function Start(expect, send, now)
    Reset()
    state.started = true
    state.startT = now
    state.send = send
    for _, name in ipairs(expect) do
        state.expect[name] = true
    end
end

--- Called every beat. Sends our version on the first (and records it into
--- the replay), and notes when CheckDelay has passed.
---@param now number
function Tick(now)
    if state.record and not state.recorded then
        state.recorded = true
        pcall(state.record, { Identifier = Config.ChatIdentifier, tmv = Config.ModVersion })
    end

    if not state.started then
        return
    end

    if not state.announced then
        state.announced = true
        pcall(state.send, { Identifier = Config.ChatIdentifier, tmv = Config.ModVersion })
    end

    if not state.checked and (now - state.startT) >= Config.VersionReport.CheckDelay then
        state.checked = true
    end
end

--- A player's version arrived (a teammate, or anyone, for an observer).
---@param sender string
---@param version any   # off the wire
function Heard(sender, version)
    if type(sender) ~= 'string' or type(version) ~= 'number'
        or version ~= version or version < 0 or version > 1e6 then
        return
    end
    state.seen[sender] = math.floor(version)
end

--- SharedMouse packets came from this player.
---@param sender string
function NoteLegacy(sender)
    if type(sender) == 'string' then
        state.legacy[sender] = true
    end
end

--- Record our version into the replay as well (once, on the next Tick).
---@param fn function   # fn(msg)
function SetRecorder(fn)
    state.record = fn or false
    state.recorded = false
end

--- What the panel shows for a player: their version, or why there is none.
---@param name string
---@return string text
---@return string color
function Describe(name)
    local v = state.seen[name]
    if v then
        return 'v' .. v, (v == Config.ModVersion) and SAME_COLOR or OTHER_COLOR
    end
    if state.legacy[name] then
        return 'old', OTHER_COLOR
    end
    if state.checked and state.expect[name] then
        return 'none', NONE_COLOR
    end
    return '?', UNKNOWN_COLOR
end

function Reset()
    state.started = false
    state.announced = false
    state.checked = false
    state.startT = 0
    state.expect = {}
    state.legacy = {}
    state.send = false
    state.seen = {}
    state.record = false
    state.recorded = false
end
