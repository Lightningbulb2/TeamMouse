--******************************************************************************
--** TeamMouse -- modules/replaycodec.lua
--**
--** Records the cursor into the replay, and plays it back.
--**
--** Live, cursors travel over SessionSendChatMessage, which is not recorded.
--** What is recorded is everything that goes through the sim. FAF's query
--** system (/lua/userplayerquery.lua, /lua/simplayerquery.lua) is a way through
--** it for plain Lua data: SimCallback { Func = 'OnPlayerQuery', Args = t }
--** goes into the sim, and the sim hands t back up to every interface by way of
--** the game's sync, to anyone listening for its Name. In a replay the sim runs
--** again, so the same data comes back up to the viewer, at the same moment in
--** the game.
--**
--** So each packet a player sends teammates is also sent into the sim, whole:
--** the replay has everything a teammate saw -- position, drags, the HUD
--** ghost, extra samples, orders, structures, templates, actions. Playback
--** hands it to the same receive code as a live packet.
--**
--** Everything that goes through the sim reaches EVERY player's interface,
--** enemies included: while this is on, a mod on an opponent's side could read
--** the cursor as it happens. That is why it is a lobby option, and off unless
--** the host turns it on.
--******************************************************************************

local Config = import(_G.TeamMousePath .. '/modules/config.lua')
local WireCodec = import(_G.TeamMousePath .. '/modules/wirecodec.lua')

--------------------------------------------------------------------------------
-- On or off
--------------------------------------------------------------------------------

--- The lobby option's key (lua/AI/LobbyOptions/lobbyoptions.lua).
OPTION_KEY = 'TeamMouseReplay'

--- What the lobby said, read once: 'on', 'off', or false for a game without
--- the option (the host did not have TeamMouse, or no lobby at all).
local lobbyChoice = nil

--- Whether cursors go into (and are played back out of) the replay this game.
--- The host's lobby option when the game has one -- the same for every
--- player, and kept in the replay, so playback knows too -- otherwise
--- Config.ReplayCodec.Enabled.
---@return boolean
function IsEnabled()
    if lobbyChoice == nil then
        lobbyChoice = false
        local ok, info = pcall(SessionGetScenarioInfo)
        local options = ok and type(info) == 'table' and info.Options
        local value = type(options) == 'table' and options[OPTION_KEY]
        if value == 'on' or value == 'off' then
            lobbyChoice = value
        end
    end
    if lobbyChoice then
        return lobbyChoice == 'on'
    end
    return Config.ReplayCodec.Enabled and true or false
end

--- Forget the lobby's choice (a new session).
function ResetOption()
    lobbyChoice = nil
end

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------

--- The query name TeamMouse's packets travel under.
QUERY_NAME = 'TeamMouse'

--- A copy of a packet: plain values and nested tables, nothing else. The
--- sender reuses its packet table from one beat to the next.
---@param t table
---@param depth number
---@return table
local function Copy(t, depth)
    local out = {}
    for k, v in pairs(t) do
        local kind = type(v)
        if kind == 'table' then
            if depth < 4 then
                out[k] = Copy(v, depth + 1)
            end
        elseif kind == 'number' or kind == 'string' or kind == 'boolean' then
            out[k] = v
        end
    end
    return out
end

--- Send one packet into the sim, and so into the replay. Normally the
--- compact string (wirecodec.lua), which costs every player in the game a
--- fraction of the table; the table itself for a packet with no exact compact
--- form. Nothing reads From or To (the packet names its army), so they are
--- not sent: every byte here goes to every player, through the sim.
---@param packet table | string   # the packet teammates are sent
---@param army number    # ours (unused: the packet carries it)
---@return boolean       # false if the game would not take it
function Record(packet, army)
    if not IsEnabled() or not Config.ReplayCodec.Write then
        return false
    end
    local m
    if type(packet) == 'string' then
        m = packet
    elseif type(packet) == 'table' then
        m = Copy(packet, 1)
    else
        return false
    end
    local args = { Name = QUERY_NAME, M = m }
    local ok = pcall(SimCallback, { Func = 'OnPlayerQuery', Args = args })
    return ok
end

--------------------------------------------------------------------------------
-- Playback
--------------------------------------------------------------------------------

--- Who gets the packets during playback; false when nobody is listening.
local receiver = false
local registered = false

--- In a replay: hand every recorded packet to `callback(packet)`, as the
--- game's sync brings them up, always as the packet table: a compact string
--- is decoded first (one that does not decode is dropped); a table is a
--- packet with no exact compact form, or from a replay recorded before it. There is no way to take a query listener away
--- again, so StopListening only stops passing packets on.
---@param callback fun(packet: table)
---@return boolean   # false if the query system could not be reached
function Listen(callback)
    receiver = callback
    if registered then
        return true
    end
    local ok = pcall(function()
        import('/lua/userplayerquery.lua').AddQueryListener(QUERY_NAME, function(query)
            if receiver and type(query) == 'table' then
                local m = query.M
                if type(m) == 'string' then
                    m = WireCodec.Decode(m)
                end
                if type(m) == 'table' then
                    receiver(m)
                end
            end
        end)
    end)
    registered = ok
    return ok
end

function StopListening()
    receiver = false
end
