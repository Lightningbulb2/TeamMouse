--******************************************************************************
--** TeamMouse -- extras/test_fuzz.lua
--**
--**     lua5.1 extras/test_fuzz.lua [seed] [iterations]
--**
--** Hammers the mod with randomised input: malformed packets, view swaps,
--** layout churn, zoom extremes, degenerate mouse positions, build modes,
--** and drag events, interleaved with frame ticks.
--**
--** Nothing here checks behaviour. The only assertion is that the mod never
--** raises and never logs an error, under any ordering. Reasoning about a
--** render loop this stateful only gets you so far; this covers the orderings
--** nobody thought to write a case for.
--******************************************************************************

local Mock = dofile('extras/mock_fa.lua')

local seed = tonumber(arg and arg[1]) or 20260919
local iterations = tonumber(arg and arg[2]) or 4000

math.randomseed(seed)

--------------------------------------------------------------------------------

local function Armies()
    return {
        [1] = { nickname = 'Lightningbulb', human = true, color = 'ff436eee', team = 1 },
        [2] = { nickname = 'KasperAUS',     human = true, color = 'FFe80a0a', team = 1 },
        [3] = { nickname = 'Eternal',       human = true, color = 'RoyalBlue', team = 1 },
        [4] = { nickname = 'Opponent',      human = true, color = 'NotAColour', team = 2 },
        [5] = { nickname = 'SomeAI',        human = false, color = 'ffffffff', team = 2 },
    }
end

local function Clients()
    return {
        [1] = { name = 'Lightningbulb', ['local'] = true },
        [2] = { name = 'KasperAUS' },
        [3] = { name = 'Eternal' },
        [4] = { name = 'Opponent' },
        [5] = { name = 'Caster' },
    }
end

local senders = { 'KasperAUS', 'Eternal', 'Opponent', 'Stranger', '' }

--- Values chosen to poke at the edges rather than the middle.
local function WeirdNumber()
    local r = math.random(12)
    if r == 1 then return 0 / 0 end
    if r == 2 then return 1e40 end
    if r == 3 then return -1e40 end
    if r == 4 then return 0 end
    if r == 5 then return -1 end
    if r == 6 then return 1e-30 end
    if r == 7 then return 99999 end
    if r == 8 then return -99999 end
    return math.random() * 1000 - 200
end

local function WeirdValue()
    local r = math.random(8)
    if r == 1 then return nil end
    if r == 2 then return 'a string' end
    if r == 3 then return {} end
    if r == 4 then return true end
    if r == 5 then return false end
    return WeirdNumber()
end

--- An extras / orders array of the right stride, mostly plausible, sometimes not.
local function RandomArray(stride, maxItems)
    if math.random(6) == 1 then return WeirdValue() end
    local t = {}
    for i = 1, math.random(0, maxItems) * stride do
        if math.random(8) == 1 then
            t[i] = WeirdValue()
        elseif math.random(2) == 1 then
            t[i] = math.random() * 0.6
        else
            t[i] = math.random() * 900
        end
    end
    return t
end

--- The compact codec (wirecodec.lua), for making compact packets to send in.
local Codec = Mock.CreateEnvironment({ armies = {}, clients = {} }).import(_G.TeamMousePath .. '/modules/wirecodec.lua')

--- A compact packet ({ TeamMouse = string }): whole, cut short, with a
--- character changed, or just noise.
local function RandomCompact()
    local m = { v = 1, a = math.random(1, 5),
        p = { math.random(0, 9000) / 10, math.random(0, 500) / 10, math.random(0, 9000) / 10 },
        o = math.random(0, 50) }
    if math.random(2) == 1 then m.z = math.random(1, 400) end
    if math.random(3) == 1 then m.w = false; m.hx = math.random(0, 1000) / 1000; m.hy = math.random(0, 1000) / 1000 end
    if math.random(3) == 1 then m.s = true; m.bx = math.random(0, 9000) / 10; m.bz = math.random(0, 9000) / 10 end
    if math.random(3) == 1 then m.mo = { 0, m.p[1], m.p[2], m.p[3], m.p[1], m.p[3], math.random(0, 9) } end
    if math.random(3) == 1 then m.ac = { math.random(1, 8) } end
    if math.random(4) == 1 then m.vp = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } end
    local s = Codec.Encode(m) or ''
    local how = math.random(4)
    if how == 2 and string.len(s) > 0 then
        s = string.sub(s, 1, math.random(string.len(s)))
    elseif how == 3 and string.len(s) > 0 then
        local at = math.random(string.len(s))
        s = string.sub(s, 1, at - 1) .. string.char(math.random(33, 126)) .. string.sub(s, at + 1)
    elseif how == 4 then
        local parts = {}
        for i = 1, math.random(0, 40) do parts[i] = string.char(math.random(33, 126)) end
        s = table.concat(parts)
    end
    if math.random(8) == 1 then
        return { TeamMouse = WeirdValue() }
    end
    return { TeamMouse = s }
end

local function RandomMessage()
    if math.random(5) == 1 then
        return RandomCompact()
    end
    local r = math.random(10)

    -- Mostly well-formed, so the interesting code paths actually get reached.
    if r <= 6 then
        return {
            Identifier = 'TeamMouse',
            v = 1,
            a = math.random(1, 5),
            p = { math.random() * 900, math.random() * 50, math.random() * 900 },
            o = math.random(0, 50),
            z = math.random(1, 400),
            w = math.random(2) == 1,
            s = math.random(4) == 1,
            b = (math.random(4) == 1) and 'ueb0101' or false,
            hx = math.random(),
            hy = math.random(),
            l = math.random(4) == 1,
            r = math.random(4) == 1,
            d = ({ false, 1, 2, true })[math.random(4)],
            oa = math.random(0, 5),
            e = ({ RandomArray(9, 10), string.rep('AbC-_9', math.random(0, 8)), 'A', WeirdValue() })[math.random(4)],
            mo = RandomArray(7, 6),
            ac = RandomArray(1, 5),
            gk = ({ false, 16, 46, WeirdValue() })[math.random(4)],
            tmv = ({ nil, 1, WeirdValue() })[math.random(3)],
            mob = ({ false, { 'ueb0101', false }, { WeirdValue(), 'x' }, WeirdValue() })[math.random(4)],
        }
    end

    if r == 7 then
        -- Valid shape, hostile values.
        return {
            Identifier = 'TeamMouse',
            v = 1,
            a = WeirdValue(),
            p = { WeirdNumber(), WeirdNumber(), WeirdNumber() },
            o = WeirdValue(),
            z = WeirdValue(),
            w = WeirdValue(),
            s = WeirdValue(),
            b = WeirdValue(),
            hx = WeirdValue(),
            hy = WeirdValue(),
            l = WeirdValue(),
            r = WeirdValue(),
            d = WeirdValue(),
            oa = WeirdValue(),
            e = ({ RandomArray(9, 10), string.rep('AbC-_9', math.random(0, 8)), 'A', WeirdValue() })[math.random(4)],
            mo = RandomArray(7, 6),
            ac = RandomArray(1, 5),
            gk = ({ false, 16, 46, WeirdValue() })[math.random(4)],
            tmv = ({ nil, 1, WeirdValue() })[math.random(3)],
            mob = ({ false, { 'ueb0101', false }, { WeirdValue(), 'x' }, WeirdValue() })[math.random(4)],
        }
    end

    if r == 8 then
        return { v = 1, a = 2, p = WeirdValue() }
    end

    if r == 9 then
        return { v = WeirdValue() }
    end

    return WeirdValue()
end

--------------------------------------------------------------------------------

local function RunSession(label, opts)
    local env = Mock.CreateEnvironment(opts)
    local SM = env.import(_G.TeamMousePath .. '/modules/teammouse.lua')

    local failures = {}

    local function Guard(what, fn)
        local ok, err = pcall(fn)
        if not ok then
            table.insert(failures, what .. ': ' .. tostring(err))
        end
    end

    Guard('init', function() SM.InitTeamMouse(opts.replay or false) end)

    local receive = env.__chatFuncs['TeamMouse']

    -- Half the sessions' peers say they read the compact format
    -- (wirecodec.lua), so both ways of sending get the same beating.
    if receive and math.random(2) == 1 then
        for _, name in ipairs(senders) do
            Guard('hello', function() receive(name, { Identifier = 'TeamMouse', tmc = 1 }) end)
        end
    end

    for step = 1, iterations do
        env.__clock.t = env.__clock.t + math.random() * 0.2

        local action = math.random(12)

        if action <= 4 and receive then
            Guard('receive', function()
                receive(senders[math.random(table.getn(senders))], RandomMessage())
            end)

        elseif action <= 7 then
            local driver = Mock.FindDriver(env)
            if driver then
                Guard('frame', function() driver:OnFrame(math.random() * 0.1) end)
            end

        elseif action == 8 then
            Guard('beat', function() SM.OnBeat() end)

        elseif action == 9 then
            -- Move the local mouse, sometimes to nonsense.
            if math.random(4) == 1 then
                env.__mouseWorld = { WeirdNumber(), WeirdNumber(), WeirdNumber() }
            else
                env.__mouseWorld = {
                    math.random() * 900, math.random() * 50, math.random() * 900,
                }
            end
            env.__setZoom(math.random(1, 500))

            -- Report the pointer the way the engine does: to the map view
            -- when it is over the map, to the root frame when it is not.
            local px, py = math.random(0, 1920), math.random(0, 1080)
            Guard('hover', function()
                if math.random(2) == 1 then
                    Mock.HoverWorld(env, px, py)
                else
                    Mock.HoverHud(env, px, py)
                end
            end)

        elseif action == 10 then
            -- Command mode churn.
            if math.random(2) == 1 then
                env.__commandMode = { 'build', { name = 'ueb0101' } }
            else
                env.__commandMode = { false, false }
            end

        elseif action == 11 then
            -- Mouse events, sometimes unbalanced.
            local view = env.__views['WorldCamera']
            local types = { 'ButtonPress', 'ButtonRelease', 'MouseExit', 'MouseMotion' }
            Guard('event', function()
                local event = {
                    Type = types[math.random(4)],
                    Modifiers = { Left = math.random(2) == 1 },
                }
                -- Real events carry coordinates; keep some without, so the
                -- tracker's handling of a bare event is exercised too.
                if math.random(3) > 1 then
                    event.MouseX, event.MouseY = math.random(0, 1920), math.random(0, 1080)
                end
                view:HandleEvent(event)
            end)

        else
            -- Layout churn: swap, add and remove views the way a layout
            -- change or entering/leaving splitscreen does.
            local r = math.random(4)
            if r == 1 then
                env.__views['WorldCamera'] =
                    Mock.WorldView(env.__frame, 'WorldCamera', 0, 0, 960, 1080)
            elseif r == 2 then
                env.__views['WorldCamera2'] =
                    Mock.WorldView(env.__frame, 'WorldCamera2', 960, 0, 960, 1080)
            elseif r == 3 then
                env.__views['WorldCamera2'] = nil
            else
                env.__views['WorldCamera'].projectReturnsNil = (math.random(2) == 1)
            end
            Guard('syncviews', function() SM.SyncViews() end)
        end
    end

    Guard('teardown', function() SM.Destroy() end)

    -- Anything the mod caught internally still counts as a failure.
    for _, line in ipairs(env.__logs) do
        if string.find(line, 'error') or string.find(line, 'failed') then
            table.insert(failures, 'logged: ' .. line)
        end
    end

    -- Every bitmap must have been given a texture or a colour.
    local untextured = 0
    for _ in pairs(Mock.untexturedBitmaps) do untextured = untextured + 1 end
    if untextured > 0 then
        table.insert(failures, untextured .. ' bitmap(s) left without a texture')
    end

    if table.getn(failures) == 0 then
        print(string.format('  pass  %-28s %d steps clean', label, iterations))
        return 0
    end

    print(string.format('  FAIL  %-28s %d failure(s)', label, table.getn(failures)))
    for i = 1, math.min(5, table.getn(failures)) do
        print('          ' .. failures[i])
    end
    return 1
end

--------------------------------------------------------------------------------

print(string.format('fuzz  seed=%d  iterations=%d', seed, iterations))
print('')

local bad = 0

bad = bad + RunSession('player, single view', {
    armies = Armies(), clients = Clients(), focusArmy = 1,
    blueprints = { ueb0101 = { Display = { IconName = 'ueb0101' } } },
})

bad = bad + RunSession('player, splitscreen', {
    armies = Armies(), clients = Clients(), focusArmy = 1, splitscreen = true,
    blueprints = { ueb0101 = { Display = { IconName = 'ueb0101' } } },
})

bad = bad + RunSession('observer', {
    armies = Armies(), focusArmy = -1,
    clients = {
        [1] = { name = 'Lightningbulb' },
        [2] = { name = 'KasperAUS' },
        [3] = { name = 'Eternal' },
        [4] = { name = 'Opponent' },
        [5] = { name = 'Caster', ['local'] = true },
    },
    blueprints = { ueb0101 = { Display = { IconName = 'ueb0101' } } },
})

bad = bad + RunSession('missing textures', {
    armies = Armies(), clients = Clients(), focusArmy = 1,
    blueprints = {},
    missingTextures = setmetatable({}, { __index = function() return true end }),
})

bad = bad + RunSession('solo, no teammates', {
    armies = { [1] = { nickname = 'Lightningbulb', human = true,
                       color = 'ff436eee', team = 1 } },
    clients = { [1] = { name = 'Lightningbulb', ['local'] = true } },
    focusArmy = 1,
    blueprints = {},
})

print('')
if bad > 0 then
    print(string.format('%d session(s) failed', bad))
    os.exit(1)
end
print('all sessions clean')
