--******************************************************************************
--** TeamMouse -- modules/version.lua
--**
--** Says in chat, at the start of a game, which version of TeamMouse you and
--** each of your teammates are on, and which teammates don't have it (or only
--** have the old SharedMouse). Local chat lines only; nothing is posted to
--** anyone else.
--**
--** Each client sends its version once, on the mod's own chat channel, to the
--** same recipients as the cursor data. It is handled before the wire-format
--** check, so a teammate on an incompatible build is still reported -- which is
--** exactly when it matters.
--******************************************************************************

local Config = import(_G.TeamMousePath .. '/modules/config.lua')

local state = {
    started = false,   -- Start has been called this session
    announced = false, -- our own line posted and our version sent
    checked = false,   -- the missing ones reported
    startT = 0,
    expect = {},       -- names of the teammates we expect to hear from
    heard = {},        -- name -> version
    legacy = {},       -- name -> true: SharedMouse packets seen from them
    send = false,      -- function(msg): sends to our recipients
}

--- A line in the local chat, from "TeamMouse".
---@param text string
local function Say(text)
    local ok, Chat = pcall(import, '/lua/ui/game/chat/ChatController.lua')
    if ok and type(Chat) == 'table' and Chat.AppendEntry then
        local posted = pcall(Chat.AppendEntry, {
            Name = 'TeamMouse:',
            Text = text,
            Color = 'ffffffff',
            BodyColor = 'ffffffff',
            ArmyID = 0,
            Recipient = GetFocusArmy(),
        })
        if posted then
            return
        end
    end
    -- An older FAF without ChatController: the plain on-screen print.
    pcall(print, 'TeamMouse: ' .. text)
end

--- Begin: who to expect, and how to reach them.
---@param expect string[]   # teammates' names (not our own)
---@param send function     # send(msg) to our recipients
---@param now number
function Start(expect, send, now)
    Reset()
    if not Config.VersionReport.Enabled then
        return
    end
    state.started = true
    state.startT = now
    state.send = send
    for _, name in ipairs(expect) do
        state.expect[name] = true
    end
end

--- Called every beat. Posts our own line and sends our version on the first,
--- and reports who hasn't answered once CheckDelay has passed.
---@param now number
function Tick(now)
    if not state.started then
        return
    end

    if not state.announced then
        state.announced = true
        if next(state.expect) then
            Say(string.format('You are on version %d', Config.ModVersion))
        end
        pcall(state.send, { Identifier = Config.ChatIdentifier, tmv = Config.ModVersion })
    end

    if not state.checked and (now - state.startT) >= Config.VersionReport.CheckDelay then
        state.checked = true
        local names = {}
        for name in pairs(state.expect) do
            if not state.heard[name] then
                table.insert(names, name)
            end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            if state.legacy[name] then
                Say(string.format('%s is using SharedMouse', name))
            else
                Say(string.format('%s does not have TeamMouse', name))
            end
        end
    end
end

--- A teammate's version arrived.
---@param sender string
---@param version any   # off the wire
function Heard(sender, version)
    if not state.started or type(sender) ~= 'string' or type(version) ~= 'number'
        or version ~= version or version < 0 or version > 1e6 or state.heard[sender] then
        return
    end
    version = math.floor(version)
    state.heard[sender] = version
    if version == Config.ModVersion then
        Say(string.format('%s is on version %d', sender, version))
    else
        Say(string.format('%s is on version %d (you are on %d)', sender, version, Config.ModVersion))
    end
end

--- SharedMouse packets came from this teammate.
---@param sender string
function NoteLegacy(sender)
    if type(sender) == 'string' then
        state.legacy[sender] = true
    end
end

function Reset()
    state.started = false
    state.announced = false
    state.checked = false
    state.startT = 0
    state.expect = {}
    state.heard = {}
    state.legacy = {}
    state.send = false
end
