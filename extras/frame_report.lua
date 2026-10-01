--******************************************************************************
--** TeamMouse -- extras/frame_report.lua
--**
--** What the mod costs per frame on the receiving end, in mock sessions: three
--** teammates' cursors at rest, moving, and busy (orders, a selection, a box
--** drag, the HUD ghost, actions, a build), and the busy case in splitscreen.
--** Our own pointer moves too, so our sending is counted.
--**
--**     lua5.1 extras/frame_report.lua            the table
--**     lua5.1 extras/frame_report.lua busy 20    plus the top 20 functions
--**
--** Two numbers, both only for the mod's own files (the mock's stand-ins for
--** engine calls are left out):
--**   garbage       bytes allocated per frame, with the collector held off.
--**                 Lua 5.0's collector stops the game to clean up, so this
--**                 is what turns into hitches.
--**   instructions  Lua instructions executed per frame (the debug hook's
--**                 count): steadier than timing, and comparable run to run.
--** Teammates' packets are built (as compact strings) before measuring, so
--** making them is not counted. Engine calls cost nothing here; the real
--** game's frame also pays for those.
--******************************************************************************

local Mock = dofile('extras/mock_fa.lua')

local v51 = pcall(collectgarbage, 'count')
local function Used() if v51 then return collectgarbage('count') end return gcinfo() end
local function GCStop() collectgarbage(); if v51 then collectgarbage('stop') else collectgarbage(1e7) end end
local function GCGo() if v51 then collectgarbage('restart') else collectgarbage() end end

local function Armies()
    return {
        [1] = { nickname = 'Lightningbulb', human = true, color = 'ff436eee', team = 1, armyIndex = 1 },
        [2] = { nickname = 'KasperAUS', human = true, color = 'FFe80a0a', team = 1, armyIndex = 2 },
        [3] = { nickname = 'Hawk', human = true, color = 'ff40bf40', team = 1, armyIndex = 3 },
        [4] = { nickname = 'Owl', human = true, color = 'ffffff00', team = 1, armyIndex = 4 },
        [5] = { nickname = 'Enemy', human = true, color = 'ff888888', team = 2, armyIndex = 5 },
    }
end
local function Clients()
    return { [1] = { name = 'Lightningbulb', ['local'] = true }, [2] = { name = 'KasperAUS' },
        [3] = { name = 'Hawk' }, [4] = { name = 'Owl' }, [5] = { name = 'Enemy' } }
end
local peers = { { 'KasperAUS', 2 }, { 'Hawk', 3 }, { 'Owl', 4 } }

--- A session playing `scenario`; returns a function running n frames.
local function Session(scenario)
    local env = Mock.CreateEnvironment({ armies = Armies(), clients = Clients(), focusArmy = 1, plainReceive = true,
        splitscreen = (scenario == 'split'), blueprints = { ueb0101 = { Display = { IconName = 'ueb0101' } } } })
    env.import('/mods/TeamMouse/modules/config.lua').Viewport.Show = true
    local SM = env.import('/mods/TeamMouse/modules/teammouse.lua')
    local WP = env.import('/mods/TeamMouse/modules/wirepack.lua')
    local C = env.import('/mods/TeamMouse/modules/wirecodec.lua')
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    for _, p in ipairs(peers) do receive(p[1], { Identifier = 'TeamMouse', tmc = 1 }) end
    local view = env.__views['WorldCamera']
    view:HandleEvent({ Type = 'MouseEnter', MouseX = 100, MouseY = 100, Modifiers = {} })
    local driver = Mock.FindDriver(env)
    env.__mouseWorld = { 300, 10, 300 }
    Mock.HoverWorld(env, 600, 300)
    for _ = 1, 3 do env.__clock.t = env.__clock.t + 0.1; SM.OnBeat() end

    -- Every teammate packet for the run, made now.
    local busy = scenario == 'busy' or scenario == 'split'
    local moving = scenario ~= 'idle'
    local prepared = {}
    for tick = 0, 400 do
        prepared[tick] = {}
        local t = tick * 0.1
        for k = 1, 3 do
            local px = 200 + k * 60 + (moving and 40 * math.cos(t + k) or 0)
            local pz = 250 + k * 30 + (moving and 30 * math.sin(t * 1.3 + k) or 0)
            px, pz = math.floor(px * 10 + 0.5) / 10, math.floor(pz * 10 + 0.5) / 10
            local m = { Identifier = 'TeamMouse', v = 1, a = peers[k][2], p = { px, 10, pz }, o = 0 }
            if tick < 3 or (moving and math.mod(tick, 5) == 0) then
                m.z = 150
                m.vp = { px - 80, 10, pz - 50, px + 80, 10, pz - 50, px + 80, 10, pz + 50, px - 80, 10, pz + 50 }
            end
            if moving then
                m.e = WP.PackSamples({
                    { age = 0.066, x = px - 1.5, z = pz + 0.6, hx = 0.5, hy = 0.9, bx = px, bz = pz, flags = 0 },
                    { age = 0.033, x = px - 0.7, z = pz + 0.3, hx = 0.5, hy = 0.9, bx = px, bz = pz, flags = 0 } },
                    2, px, pz)
            end
            if busy then
                if k == 1 and math.mod(tick, 7) == 0 then m.mo = { 0, px, 10, pz, px, pz, tick }; m.ck = 1 end
                if k == 2 and math.mod(tick, 20) == 0 then
                    m.sel = '1,2,3,4,5,6'; m.ss = '2,2,2,2,2,2'
                    m.sq = '4a0,4a0,a;4a4,4a0,a;4a8,4a0,a;4ac,4a0,a;4ag,4a0,a;4ak,4a0,a'
                end
                if k == 3 and math.mod(tick, 30) < 10 then m.s = true; m.bx = px + 30; m.bz = pz + 20 end
                if k == 3 and math.mod(tick, 30) >= 20 then m.w = false; m.hx = 0.3 + 0.1 * math.sin(t); m.hy = 0.85 end
                if k == 1 and math.mod(tick, 25) == 3 then m.ac = { 1 } end
                if k == 2 and math.mod(tick, 40) == 10 then m.b = 'ueb0101' end
            end
            local s = C.Encode(m)
            prepared[tick][k] = s and { TeamMouse = s } or m
        end
    end

    local tick, frame = 0, 0
    return function(n)
        for _ = 1, n do
            frame = frame + 1
            env.__clock.t = env.__clock.t + 1 / 60
            local t = env.__clock.t
            if moving then
                local sx, sy = 600 + 300 * math.cos(t * 2), 400 + 200 * math.sin(t * 3)
                env.__mouseWorld = { 300 + sx / 8, 10, 200 + sy / 8 }
                env.__mouseScreen = { sx, sy }
                view:HandleEvent({ Type = 'MouseMotion', MouseX = sx, MouseY = sy, Modifiers = {} })
            end
            if math.mod(frame, 6) == 0 then
                tick = tick + 1
                for k = 1, 3 do receive(peers[k][1], prepared[tick][k]) end
                SM.OnBeat()
            end
            driver:OnFrame(1 / 60)
            Mock.RenderWorld(env)
        end
    end
end

local MOD_FILES = { 'teammouse.lua', 'remotecursor.lua', 'wirecodec.lua', 'wirepack.lua', 'cursordata.lua',
    'hudghost.lua', 'actions.lua', 'panel.lua', 'version.lua', 'replaycodec.lua', 'legacyprotocol.lua' }
local isMod = {}
for _, f in ipairs(MOD_FILES) do isMod[f] = true end

--- Run `frames` frames of a warmed-up session under the debug hook: the
--- mod's garbage and instructions, in total and by function.
local function Measure(scenario, frames)
    local run = Session(scenario)
    run(240)   -- pools, shapes and buffers all built first
    local short = {}
    local ins, mem, insBy, memBy = 0, 0, {}, {}
    local lastKey, lastMod, lastKB
    GCStop()
    lastKB = Used()
    debug.sethook(function()
        local now = Used()
        if lastMod and now > lastKB then
            mem = mem + (now - lastKB)
            memBy[lastKey] = (memBy[lastKey] or 0) + (now - lastKB)
        end
        lastMod = false
        local info = debug.getinfo(2, 'S')
        if info then
            local src = short[info.short_src]
            if not src then
                src = string.gsub(info.short_src, '^.*/', '')
                short[info.short_src] = src
            end
            if isMod[src] then
                ins = ins + 1
                lastKey = src .. ' (function at line ' .. info.linedefined .. ')'
                insBy[lastKey] = (insBy[lastKey] or 0) + 1
                lastMod = true
            end
        end
        lastKB = Used()
    end, '', 1)
    run(frames)
    debug.sethook()
    GCGo()
    return mem * 1024 / frames, ins / frames, memBy, insBy
end

-- Loaded by a test (FRAME_REPORT_LIB set): just hand over Measure.
if rawget(_G, 'FRAME_REPORT_LIB') then
    return { Measure = Measure }
end

local frames = 120
local detail, top = arg and arg[1], tonumber(arg and arg[2]) or 15

print(string.format('%-28s %16s %22s', 'three teammates, 60 fps', 'garbage B/frame', 'instructions /frame'))
for _, sc in ipairs({ { 'idle', 'at rest' }, { 'moving', 'moving' }, { 'busy', 'busy' },
    { 'split', 'busy, splitscreen' } }) do
    local g, i, memBy, insBy = Measure(sc[1], frames)
    print(string.format('%-28s %16.0f %22.0f', sc[2], g, i))
    if detail == sc[1] then
        local function Top(t, title, scale)
            local list = {}
            for k, v in pairs(t) do table.insert(list, { k, v * scale / frames }) end
            table.sort(list, function(a, b) return a[2] > b[2] end)
            print('  ' .. title)
            for j = 1, math.min(top, table.getn(list)) do
                print(string.format('    %9.0f  %s', list[j][2], list[j][1]))
            end
        end
        Top(memBy, 'garbage per frame, by function:', 1024)
        Top(insBy, 'instructions per frame, by function:', 1)
    end
end
