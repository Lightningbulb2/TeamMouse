--******************************************************************************
--** TeamMouse -- modules/observerteam.lua
--**
--** The host's lobby option "TeamMouse: observers watch" (lobbyoptions.lua):
--** any team, or one team only. With one team, an observer's focus army is
--** kept on that team (never the all-seeing observer view), they list, follow
--** and coach only its players, and players on other teams send them nothing.
--**
--** Teams are numbered as the lobby showed them: ScenarioInfo.ArmySetup's
--** Team (1 is "no team", 2 is team 1, ...), or, without it, the alliances in
--** army order.
--******************************************************************************

--- The lobby option's key (lua/AI/LobbyOptions/lobbyoptions.lua).
OPTION_KEY = 'TeamMouseObserverTeam'

--- The team observers are kept to (1..8), or false for any; read once.
local forced = nil

--- army index -> team number; built once.
local teams = nil

--- The lobby's choice of team, or false for any.
---@return number | false
function Forced()
    if forced == nil then
        forced = false
        local ok, info = pcall(SessionGetScenarioInfo)
        local options = ok and type(info) == 'table' and info.Options
        local n = type(options) == 'table' and tonumber(options[OPTION_KEY])
        if n and n >= 1 and n <= 8 then
            forced = n
        end
    end
    return forced
end

--- Every army's team number (none for a civilian, or a player with no team).
---@return table
function Teams()
    if teams then
        return teams
    end
    teams = {}
    local ok, armies = pcall(function() return GetArmiesTable().armiesTable end)
    if not ok or type(armies) ~= 'table' then
        return teams
    end
    local okInfo, info = pcall(SessionGetScenarioInfo)
    local setup = okInfo and type(info) == 'table' and info.ArmySetup
    if type(setup) == 'table' then
        for index, army in pairs(armies) do
            local entry = army.name and setup[army.name]
            local team = type(entry) == 'table' and tonumber(entry.Team)
            if team and team >= 2 then
                teams[index] = team - 1
            end
        end
        if next(teams) then
            return teams
        end
    end
    -- By alliance: the first army's allies are team 1, and so on.
    local order = {}
    for index, army in pairs(armies) do
        if not army.civilian then
            table.insert(order, index)
        end
    end
    table.sort(order)
    local n = 0
    for _, index in ipairs(order) do
        if not teams[index] then
            n = n + 1
            teams[index] = n
            for _, other in ipairs(order) do
                if not teams[other] and IsAlly(index, other) then
                    teams[other] = n
                end
            end
        end
    end
    return teams
end

--- Whether observers may watch this army.
---@param army number
---@return boolean
function Allowed(army)
    local team = Forced()
    return not team or Teams()[army] == team
end

--- "any", or the team's number: the panel's observers row.
---@return string
function Label()
    local team = Forced()
    return team and tostring(team) or 'any'
end

local lastSet = -1000

--- An observer, each beat: their focus put back on the team when it has
--- left it (the score panel, or the observer view). At most once a second:
--- each request is a moderator event in everyone's log.
---@param now number
function Enforce(now)
    if not Forced() then
        return
    end
    local ok, focus = pcall(GetFocusArmy)
    if ok and focus and focus >= 1 and Allowed(focus) then
        return
    end
    if now - lastSet < 1 then
        return
    end
    -- The team's first army still in the game (any of it, if none is).
    local okA, armies = pcall(function() return GetArmiesTable().armiesTable end)
    if not okA or type(armies) ~= 'table' then
        return
    end
    local pick, fallback = nil, nil
    for index, army in pairs(armies) do
        if Allowed(index) then
            if not army.outOfGame and (not pick or index < pick) then
                pick = index
            end
            if not fallback or index < fallback then
                fallback = index
            end
        end
    end
    pick = pick or fallback
    if pick then
        lastSet = now
        pcall(ConExecute, 'SetFocusArmy ' .. tostring(pick - 1))
    end
end
