--******************************************************************************
--** TeamMouse -- extras/bandwidth_report.lua
--**
--** Measures what TeamMouse sends, in mock sessions playing out ordinary
--** situations: a mouse at rest, sweeping the map, on the interface, panning the
--** camera, box-dragging, changing selection, giving orders, and the replay
--** copy. Prints bytes per second to each teammate, by field.
--**
--**     lua5.1 extras/bandwidth_report.lua
--**
--** Two size models, since FA's own serialisation isn't documented:
--**   A  extras/wire_size.lua: a type byte per value, 4-byte numbers
--**   B  the same with 8-byte numbers, as FAF's own painting code budgets
--**      for chat messages (PaintingCanvasAdapter.SplitBrushStrokes)
--** Use them to compare layouts; the absolute numbers are an estimate.
--******************************************************************************

local Mock = dofile('extras/mock_fa.lua')

local function SizeWith(numberBytes)
    local function Size(v)
        local t = type(v)
        if t == 'nil' then return 1 end
        if t == 'boolean' then return 2 end
        if t == 'number' then return 1 + numberBytes end
        if t == 'string' then return 3 + string.len(v) end
        if t == 'table' then
            local n = 2
            for k, x in pairs(v) do n = n + Size(k) + Size(x) end
            return n
        end
        return 1
    end
    return Size
end
local SizeA, SizeB = SizeWith(4), SizeWith(8)

local function Armies()
    return {
        [1] = { nickname = 'Lightningbulb', human = true, color = 'ff436eee', team = 1, armyIndex = 1 },
        [2] = { nickname = 'KasperAUS',     human = true, color = 'FFe80a0a', team = 1, armyIndex = 2 },
        [3] = { nickname = 'Eternal',       human = true, color = 'ff40bf40', team = 2, armyIndex = 3 },
    }
end

local function Clients()
    return {
        [1] = { name = 'Lightningbulb', ['local'] = true },
        [2] = { name = 'KasperAUS' },
        [3] = { name = 'Eternal' },
    }
end

local function NewSession(lobby)
    local env = Mock.CreateEnvironment({ armies = Armies(), clients = Clients(), focusArmy = 1,
        blueprints = { ueb0101 = { Display = { IconName = 'ueb0101' } } } })
    if lobby then env.__scenario.Options.TeamMouseReplay = lobby end
    local SM = env.import('/mods/TeamMouse/modules/teammouse.lua')
    SM.InitTeamMouse(false)
    -- Teammates on this version say they read the compact format (a build
    -- without it ignores this).
    if env.__chatFuncs['TeamMouse'] and not PLAIN_PEERS then
        env.__chatFuncs['TeamMouse']('KasperAUS', { Identifier = 'TeamMouse', tmc = 1 })
    end
    local view = env.__views['WorldCamera']
    view:HandleEvent({ Type = 'MouseEnter', MouseX = 100, MouseY = 100, Modifiers = {} })
    -- A camera a bit closer than the mock's default: a view a few hundred
    -- world units across, as at a middling zoom. `pan` moves it.
    env.__pan = { 0, 0 }
    env.UnProject = function(_, point)
        return { 300 + env.__pan[1] + point[1] / 4, 12.3, 200 + env.__pan[2] + point[2] / 4 }
    end
    env.__setZoom(120)
    -- Settle: calibrate the pointer map on a resting pointer.
    env.__mouseWorld = { 325, 12.3, 225 }
    Mock.HoverWorld(env, 100, 100)
    for _ = 1, 3 do
        env.__clock.t = env.__clock.t + 0.1
        SM.OnBeat()
    end
    return env, SM, view, Mock.FindDriver(env)
end

local function Unit(id, x, z)
    return {
        GetEntityId = function() return id end,
        GetPosition = function() return { x, 12.3, z } end,
        GetBlueprint = function() return { Physics = { SkirtSizeX = 1, SkirtSizeZ = 1 }, SizeX = 0.8, SizeZ = 0.9 } end,
        IsInCategory = function() return false end,
        IsDead = function() return false end,
    }
end

--- Run `seconds` of frames at 60/s with a beat every 6th, `step(t, i)` before each.
local function Run(env, SM, driver, seconds, step)
    local frames = math.floor(seconds * 60 + 0.5)
    for i = 1, frames do
        env.__clock.t = env.__clock.t + 1 / 60
        if step then step(env.__clock.t, i) end
        driver:OnFrame(1 / 60)
        if math.mod(i, 6) == 0 then SM.OnBeat() end
    end
end

local function Sweep(env, view, t, sx0, sy0)
    local sx = sx0 + 300 * math.cos(t * 2)
    local sy = sy0 + 200 * math.sin(t * 3)
    env.__mouseWorld = { 300 + env.__pan[1] + sx / 4, 12.3, 200 + env.__pan[2] + sy / 4 }
    env.__mouseScreen = { sx, sy }
    view:HandleEvent({ Type = 'MouseMotion', MouseX = sx, MouseY = sy, Modifiers = {} })
end

local scenarios = {}

scenarios[1] = { 'mouse at rest', function(env, SM, view, driver)
    Run(env, SM, driver, 10)
end }

scenarios[2] = { 'sweeping the map', function(env, SM, view, driver)
    Run(env, SM, driver, 10, function(t) Sweep(env, view, t, 480, 300) end)
end }

scenarios[3] = { 'on the interface', function(env, SM, view, driver)
    Run(env, SM, driver, 10, function(t)
        Mock.HoverHud(env, 400 + 200 * math.cos(t * 2), 980 + 40 * math.sin(t * 3))
    end)
end }

scenarios[4] = { 'panning the camera', function(env, SM, view, driver)
    Run(env, SM, driver, 10, function(t)
        env.__pan[1] = t * 40
        env.__pan[2] = 20 * math.sin(t)
        Sweep(env, view, t, 480, 300)
    end)
end }

scenarios[5] = { 'box-dragging', function(env, SM, view, driver)
    local cell = Mock.FindDragOverlays(env)[1].children[1]
    Run(env, SM, driver, 10, function(t, i)
        local phase = math.mod(i, 120)
        if phase == 1 then
            Sweep(env, view, t, 480, 300)
            view:HandleEvent({ Type = 'ButtonPress', MouseX = env.__mouseScreen[1],
                MouseY = env.__mouseScreen[2], Modifiers = { Left = true } })
            env.__keysDown = env.__keysDown or {}
        elseif phase > 1 and phase < 100 then
            cell:HandleEvent({ Type = 'MouseEnter', MouseX = 300 + phase * 4, MouseY = 200 + phase * 2,
                Modifiers = { Left = true } })
        elseif phase == 100 then
            view:HandleEvent({ Type = 'ButtonRelease', MouseX = 700, MouseY = 400, Modifiers = {} })
        else
            Sweep(env, view, t, 480, 300)
        end
    end)
end }

scenarios[6] = { 'reselecting 12 units each second', function(env, SM, view, driver)
    local k = 0
    Run(env, SM, driver, 10, function(t, i)
        Sweep(env, view, t, 480, 300)
        if math.mod(i, 60) == 1 then
            k = k + 1
            local units = {}
            for j = 1, 12 do
                table.insert(units, Unit(tostring(1048576 + k * 37 + j), 310 + j * 1.5 + k, 220 + math.mod(j, 4) * 2))
            end
            env.__selectedUnits = units
        end
    end)
end }

scenarios[7] = { 'reselecting 150 units each 2 s', function(env, SM, view, driver)
    local k = 0
    Run(env, SM, driver, 10, function(t, i)
        Sweep(env, view, t, 480, 300)
        if math.mod(i, 120) == 1 then
            k = k + 1
            local units = {}
            for j = 1, 150 do
                table.insert(units, Unit(tostring(1048576 + k * 300 + j),
                    100 + math.mod(j * 37, 400) + k, 80 + math.mod(j * 53, 300)))
            end
            env.__selectedUnits = units
        end
    end)
end }

scenarios[8] = { 'right-click orders, 3 a second', function(env, SM, view, driver)
    env.__selectedUnits = { Unit('1048600', 320, 230) }
    Run(env, SM, driver, 10, function(t, i)
        Sweep(env, view, t, 480, 300)
        if math.mod(i, 20) == 1 then
            local x, y = env.__mouseScreen[1], env.__mouseScreen[2]
            view:HandleEvent({ Type = 'ButtonPress', MouseX = x, MouseY = y, Modifiers = { Right = true } })
            view:HandleEvent({ Type = 'ButtonRelease', MouseX = x, MouseY = y, Modifiers = {} })
        end
    end)
end }

--- What actually went on the wire for a sent message (the mock keeps it).
local function WireOf(entry)
    return entry.wire or entry.raw
end

local function Measure(name, play, lobby)
    local env, SM, view, driver = NewSession(lobby)
    local firstSent = table.getn(env.__sent) + 1
    local firstSim = table.getn(env.__simCallbacks) + 1
    local t0 = env.__clock.t
    play(env, SM, view, driver)
    local seconds = env.__clock.t - t0

    local totalA, totalB, packets, worst = 0, 0, 0, 0
    local byField = {}
    for i = firstSent, table.getn(env.__sent) do
        local msg = WireOf(env.__sent[i])
        local a, b = SizeA(msg), SizeB(msg)
        totalA, totalB, packets = totalA + a, totalB + b, packets + 1
        if a > worst then worst = a end
        for k, v in pairs(msg) do
            byField[k] = (byField[k] or 0) + SizeA(k) + SizeA(v)
        end
    end
    local simA, simN = 0, 0
    for i = firstSim, table.getn(env.__simCallbacks) do
        local cb = env.__simCallbacks[i]
        if cb.Func == 'OnPlayerQuery' then
            simA = simA + SizeA(cb)
            simN = simN + 1
        end
    end
    return {
        name = name, packets = packets / seconds, a = totalA / seconds, b = totalB / seconds,
        worst = worst, fields = byField, seconds = seconds, simA = simA / seconds, simN = simN / seconds,
    }
end

local results = {}
for _, s in ipairs(scenarios) do
    table.insert(results, Measure(s[1], s[2]))
end
local rec = Measure('replay copy, sweeping the map', scenarios[2][2], 'on')

print(string.format('%-34s %8s %10s %10s %8s', 'scenario', 'pkts/s', 'A B/s', 'B B/s', 'worst A'))
for _, r in ipairs(results) do
    print(string.format('%-34s %8.1f %10.0f %10.0f %8d', r.name, r.packets, r.a, r.b, r.worst))
end
print(string.format('%-34s %8.1f %10.0f %10s', 'replay copy (sim), sweeping', rec.simN, rec.simA, '-'))
print('')
print('By field (model A, B/s), sweeping / panning / 150 units:')
local keys = {}
for _, i in ipairs({ 2, 4, 7 }) do
    for k in pairs(results[i].fields) do keys[k] = true end
end
local list = {}
for k in pairs(keys) do table.insert(list, k) end
table.sort(list)
for _, k in ipairs(list) do
    local function F(i) return (results[i].fields[k] or 0) / results[i].seconds end
    print(string.format('  %-12s %8.0f %8.0f %8.0f', k, F(2), F(4), F(7)))
end
