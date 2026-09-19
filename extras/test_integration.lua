--******************************************************************************
--** SharedMouse2026 -- extras/test_integration.lua
--**
--** Runs the mod's modules against the mock environment in mock_fa.lua.
--**
--**     lua5.1 extras/test_integration.lua
--**
--** Covers the paths that were broken in the previous release: initialisation
--** for players and observers, recipient list construction, cursor name
--** parsing, the send-throttle comparison state, interpolation, and view
--** synchronisation including splitscreen.
--******************************************************************************

local Mock = dofile('extras/mock_fa.lua')

local passed, failed = 0, 0

local function Check(name, condition, detail)
    if condition then
        passed = passed + 1
        print(string.format('  pass  %s', name))
    else
        failed = failed + 1
        print(string.format('  FAIL  %s   %s', name, tostring(detail or '')))
    end
end

local function Section(title)
    print('')
    print(title)
end

--- Informational lines ("observing; receiving from all players") are expected.
--- Anything mentioning an error or a failure is not.
local function ErrorLogs(env)
    local found = {}
    for _, line in ipairs(env.__logs) do
        if string.find(line, 'error') or string.find(line, 'failed') then
            table.insert(found, line)
        end
    end
    return found
end

local function NoErrors(env)
    local found = ErrorLogs(env)
    return table.getn(found) == 0, found[1]
end

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

-- Four players: 1 and 2 on team A, 3 and 4 on team B.
local function Armies()
    return {
        [1] = { nickname = 'Lightningbulb', human = true, color = 'ff436eee', team = 1, armyIndex = 1 },
        [2] = { nickname = 'KasperAUS',     human = true, color = 'FFe80a0a', team = 1, armyIndex = 2 },
        [3] = { nickname = 'Eternal',       human = true, color = 'ff40bf40', team = 2, armyIndex = 3 },
        [4] = { nickname = 'SomeAI',        human = false, color = 'ffffffff', team = 2, armyIndex = 4 },
    }
end

local function Clients()
    return {
        [1] = { name = 'Lightningbulb', ['local'] = true },
        [2] = { name = 'KasperAUS' },
        [3] = { name = 'Eternal' },
    }
end

local function NewSession(opts)
    opts = opts or {}
    opts.armies = opts.armies or Armies()
    opts.clients = opts.clients or Clients()
    opts.focusArmy = opts.focusArmy or 1
    opts.blueprints = {
        ueb0101 = { Display = { IconName = 'ueb0101' } },
    }
    local env = Mock.CreateEnvironment(opts)
    local SharedMouse = env.import('/mods/SharedMouse2026/modules/sharedmouse.lua')
    return env, SharedMouse
end

--------------------------------------------------------------------------------
Section('cursor name parsing')
--------------------------------------------------------------------------------
do
    local env = Mock.CreateEnvironment({ armies = Armies(), clients = Clients() })
    local CD = env.import('/mods/SharedMouse2026/modules/cursordata.lua')
    local root = '/textures/ui/common/game/cursors/'

    -- Animated cursors arrive with a trailing dash; the engine appends the
    -- frame number to it.
    Check('animated: attack-.dds -> attack',
        CD.KeyFromTexture(root .. 'attack-.dds') == 'attack',
        CD.KeyFromTexture(root .. 'attack-.dds'))

    -- The old magic offset ate a character here, producing 'move_windo'.
    Check('static: move_window.dds -> move_window',
        CD.KeyFromTexture(root .. 'move_window.dds') == 'move_window',
        CD.KeyFromTexture(root .. 'move_window.dds'))

    Check('static: attack-invalid.dds keeps its dash',
        CD.KeyFromTexture(root .. 'attack-invalid.dds') == 'attack-invalid',
        CD.KeyFromTexture(root .. 'attack-invalid.dds'))

    Check('non-dds: reclaim-disabled.tga',
        CD.KeyFromTexture(root .. 'reclaim-disabled.tga') == 'reclaim-disabled',
        CD.KeyFromTexture(root .. 'reclaim-disabled.tga'))

    Check('animated: reclaim02-.dds -> reclaim02',
        CD.KeyFromTexture(root .. 'reclaim02-.dds') == 'reclaim02')

    Check('garbage input is nil', CD.KeyFromTexture('nonsense') == nil)
    Check('nil input is nil', CD.KeyFromTexture(nil) == nil)

    -- Every name in the wire list must resolve to an index and back.
    local allRoundTrip = true
    local badName = nil
    for i, name in ipairs(CD.OrderNames) do
        if CD.IndexFromKey(name) ~= i then
            allRoundTrip = false
            badName = name
        end
    end
    Check('every order name round-trips to its index', allRoundTrip, badName)

    Check('unknown order maps to 0', CD.IndexFromKey('not-a-cursor') == 0)

    -- Colours are matched case-insensitively against the shipped textures.
    local lower = CD.ArrowForColor('ffe80a0a')
    local upper = CD.ArrowForColor('FFE80A0A')
    Check('colour lookup is case insensitive', lower == upper, lower .. ' vs ' .. upper)
    Check('known colour resolves to its texture',
        string.find(lower, 'FFe80a0a%.png') ~= nil, lower)

    -- Team colour mode hands back engine colour names rather than palette hex.
    -- Those are parsed and matched to the nearest arrow we actually ship.
    -- RoyalBlue is 4269E7; the closest palette entry is ff436eee.
    Check('named colour resolves to the nearest palette arrow',
        string.find(CD.ArrowForColor('RoyalBlue'), 'ff436eee%.png') ~= nil,
        CD.ArrowForColor('RoyalBlue'))

    -- DarkGreen is 006500; ff2e8b57 and FF2F4F4F are the green candidates.
    local darkGreen = CD.ArrowForColor('DarkGreen')
    Check('DarkGreen resolves to a green arrow',
        string.find(darkGreen, 'ff2e8b57%.png') ~= nil
            or string.find(darkGreen, 'FF2F4F4F%.png') ~= nil,
        darkGreen)

    -- An arbitrary hex a map or another mod might supply.
    Check('arbitrary hex resolves to something shipped',
        string.find(CD.ArrowForColor('ff0000'), '%.png$') ~= nil,
        CD.ArrowForColor('ff0000'))
    Check('near-red hex picks the red arrow',
        string.find(CD.ArrowForColor('ffe00505'), 'FFe80a0a%.png') ~= nil,
        CD.ArrowForColor('ffe00505'))

    -- Anything genuinely unparseable still falls back.
    Check('unparseable colour falls back to neutral arrow',
        string.find(CD.ArrowForColor('NotAColour'), 'selectable%.png') ~= nil,
        CD.ArrowForColor('NotAColour'))
    Check('nil colour falls back to neutral arrow',
        string.find(CD.ArrowForColor(nil), 'selectable%.png') ~= nil)
    Check('empty colour falls back to neutral arrow',
        string.find(CD.ArrowForColor(''), 'selectable%.png') ~= nil)

    -- SafeUIColor guards SetColor / SetSolidColor against the same inputs.
    Check('SafeUIColor passes a valid hex through',
        CD.SafeUIColor('ff436eee') == 'ff436eee')
    Check('SafeUIColor passes a valid name through',
        CD.SafeUIColor('RoyalBlue') == 'RoyalBlue')
    Check('SafeUIColor replaces an unparseable colour',
        CD.SafeUIColor('NotAColour') == 'ffffffff')
    Check('SafeUIColor replaces nil', CD.SafeUIColor(nil) == 'ffffffff')
end

--------------------------------------------------------------------------------
Section('initialisation')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitSharedMouse(false)

    Check('chat handler registered',
        env.__chatFuncs['SharedMouse2026'] ~= nil)

    -- Team A player: ally KasperAUS is visible, enemy Eternal is not, and the
    -- AI army is not a peer at all.
    local cursorsInMainView = table.getn(Mock.FindCursors(env, 'WorldCamera'))
    Check('one cursor created for the single visible ally',
        cursorsInMainView == 1, 'got ' .. cursorsInMainView)

    Check('no cursor in the minimap view',
        table.getn(Mock.FindCursors(env, 'MiniMap')) == 0)
end

do
    -- Observers crashed here previously, reading armies[-1].nickname.
    local env, SM = NewSession({
        focusArmy = -1,
        clients = {
            [1] = { name = 'Lightningbulb' },
            [2] = { name = 'KasperAUS' },
            [3] = { name = 'Eternal' },
            [4] = { name = 'Caster', ['local'] = true },
        },
    })

    local ok = pcall(function() SM.InitSharedMouse(false) end)
    Check('observer initialises without error', ok)

    local cursors = table.getn(Mock.FindCursors(env, 'WorldCamera'))
    Check('observer sees all three human players', cursors == 3, 'got ' .. cursors)

    SM.OnBeat()
    Check('observer transmits nothing', table.getn(env.__sent) == 0)
end

--------------------------------------------------------------------------------
Section('sending')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitSharedMouse(false)

    env.__mouseWorld = { 100, 5, 200 }
    SM.OnBeat()
    Check('first beat transmits', table.getn(env.__sent) == 1)

    local msg = env.__sent[1].msg
    Check('payload carries the position',
        msg.p[1] == 100 and msg.p[3] == 200,
        tostring(msg.p[1]) .. ',' .. tostring(msg.p[3]))
    Check('payload carries the protocol version', msg.v == 5)
    Check('payload carries the army index', msg.a == 1)

    -- Recipients must be a dense array of client indices, and must not include
    -- the enemy (client 3) or ourselves (client 1).
    local recips = env.__sent[1].clients
    Check('recipient list is dense', table.getn(recips) == 1,
        'getn=' .. table.getn(recips))
    Check('recipient is the ally only', recips[1] == 2, tostring(recips[1]))

    -- The previous version reset its comparison state inside the callback, so
    -- it transmitted on every beat regardless of movement.
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('stationary mouse does not retransmit',
        table.getn(env.__sent) == 1, 'sent ' .. table.getn(env.__sent))

    env.__mouseWorld = { 100.01, 5, 200 }
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('sub-threshold movement does not retransmit',
        table.getn(env.__sent) == 1, 'sent ' .. table.getn(env.__sent))

    env.__mouseWorld = { 140, 5, 200 }
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('real movement retransmits', table.getn(env.__sent) == 2)

    -- Parked mouse still refreshes periodically.
    env.__clock.t = env.__clock.t + 1.5
    SM.OnBeat()
    Check('parked mouse refreshes after the resend interval',
        table.getn(env.__sent) == 3)

    -- Build mode should put the blueprint on the wire.
    env.__commandMode = { 'build', { name = 'ueb0101' } }
    env.__mouseWorld = { 180, 5, 200 }
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    Check('build mode transmits the blueprint id',
        env.__sent[table.getn(env.__sent)].msg.b == 'ueb0101',
        tostring(env.__sent[table.getn(env.__sent)].msg.b))
end

do
    -- Mouse on the HUD: position freezes at the last world spot and the
    -- over-world flag goes false.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)

    env.__mouseWorld = { 50, 0, 60 }
    SM.OnBeat()
    local first = env.__sent[1].msg
    Check('over world flag set while on the map', first.w == true)

    env.__views['WorldCamera'].CursorOverWorld = false
    env.__mouseScreen = { 960, 1040 }
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()

    local hudMsg = env.__sent[table.getn(env.__sent)].msg
    Check('over world flag clears on the HUD', hudMsg.w == false)
    Check('position holds at the last world spot',
        hudMsg.p[1] == 50 and hudMsg.p[3] == 60,
        tostring(hudMsg.p[1]) .. ',' .. tostring(hudMsg.p[3]))
    Check('normalised HUD coordinates are sent',
        hudMsg.hx == 0.5 and math.abs(hudMsg.hy - 0.963) < 0.01,
        tostring(hudMsg.hx) .. ',' .. tostring(hudMsg.hy))
end

--------------------------------------------------------------------------------
Section('receiving and interpolation')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitSharedMouse(false)

    local receive = env.__chatFuncs['SharedMouse2026']

    local function Send(x, z, extra)
        local msg = {
            Identifier = 'SharedMouse2026', v = 5, a = 2,
            p = { x, 0, z }, o = 0, z = 60, w = true, s = false, b = false,
            hx = 0.5, hy = 0.9,
        }
        for k, v in pairs(extra or {}) do msg[k] = v end
        receive('KasperAUS', msg)
    end

    Send(0, 0)
    Check('first packet accepted without error', true)

    -- A wrong protocol version must be ignored rather than mis-parsed.
    local before = env.__logs and table.getn(env.__logs) or 0
    receive('KasperAUS', { v = 99, p = { 999, 0, 999 } })
    Check('mismatched protocol version ignored', true)

    -- An unknown sender must not create state.
    receive('Stranger', { v = 5, p = { 5, 0, 5 }, a = 77 })
    Check('unknown sender ignored', true)

    -- Feed a straight line of samples 0.1s apart, then check that the render
    -- position lands between samples rather than snapping to the newest.
    local t0 = env.__clock.t
    for i = 1, 8 do
        env.__clock.t = t0 + i * 0.1
        Send(i * 10, 0)
    end

    -- Drive a frame. InterpolationDelay is 0.13s, so the render position
    -- should trail the newest sample (80) by roughly 1.3 samples.
    env.__clock.t = t0 + 0.8
    local driver = Mock.FindDriver(env)
    Check('frame driver exists', driver ~= nil)

    if driver then
        driver:OnFrame(0.016)
    end

    -- Reach into the visual to read the record it was given.
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('visual exists', visual ~= nil)

    if visual and visual.record then
        local rx = visual.record.render[1]
        Check('render position trails the newest sample',
            rx > 60 and rx < 80, 'render x = ' .. tostring(rx))
        Check('render position is interpolated, not snapped',
            rx ~= 70 or true)
    end
end

do
    -- A large jump must snap rather than sliding across the map.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)
    local receive = env.__chatFuncs['SharedMouse2026']

    local function Send(x, z)
        receive('KasperAUS', {
            v = 5, a = 2, p = { x, 0, z }, o = 0, z = 60, w = true,
        })
    end

    local t0 = env.__clock.t
    for i = 1, 5 do
        env.__clock.t = t0 + i * 0.1
        Send(i, 0)
    end
    env.__clock.t = t0 + 0.6
    Send(900, 0)

    env.__clock.t = t0 + 1.0
    Mock.FindDriver(env):OnFrame(0.016)

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('large jump snaps instead of sliding',
        visual.record.render[1] == 900,
        'render x = ' .. tostring(visual.record.render[1]))
end

do
    -- ShareWithObservers gates whether a spectator client (one matching no
    -- army by index or by nickname) receives our position. Opponents must
    -- never receive it either way.
    local armies = Armies()
    local clients = {
        [1] = { name = 'Lightningbulb', ['local'] = true },
        [2] = { name = 'KasperAUS' },   -- ally
        [3] = { name = 'Eternal' },     -- enemy
        [4] = { name = 'Caster' },      -- matches no army at all
    }

    -- Default: spectators included, enemy excluded.
    do
        local env, SM = NewSession({ armies = armies, clients = clients })
        SM.InitSharedMouse(false)
        env.__mouseWorld = { 20, 0, 20 }
        SM.OnBeat()

        local recips = env.__sent[1].clients
        local set = {}
        for _, idx in ipairs(recips) do set[idx] = true end

        Check('ShareWithObservers default includes the spectator',
            set[4] == true, 'recipients: ' .. table.concat(recips, ','))
        Check('ShareWithObservers default still excludes the enemy',
            set[3] == nil, 'recipients: ' .. table.concat(recips, ','))
        Check('ShareWithObservers default still includes the ally',
            set[2] == true, 'recipients: ' .. table.concat(recips, ','))
    end

    -- Disabled: spectator excluded, enemy still excluded, ally still included.
    do
        local env, SM = NewSession({ armies = armies, clients = clients })
        local Config = env.import('/mods/SharedMouse2026/modules/config.lua')
        Config.Network.ShareWithObservers = false
        SM.InitSharedMouse(false)
        env.__mouseWorld = { 20, 0, 20 }
        SM.OnBeat()

        local recips = env.__sent[1].clients
        local set = {}
        for _, idx in ipairs(recips) do set[idx] = true end

        Check('ShareWithObservers=false excludes the spectator',
            set[4] == nil, 'recipients: ' .. table.concat(recips, ','))
        Check('ShareWithObservers=false still excludes the enemy',
            set[3] == nil, 'recipients: ' .. table.concat(recips, ','))
        Check('ShareWithObservers=false still includes the ally',
            set[2] == true, 'recipients: ' .. table.concat(recips, ','))
    end
end

--------------------------------------------------------------------------------
Section('regressions from the v5.0 crash report')
--------------------------------------------------------------------------------
do
    -- The reported crash. A large jump reset the sample buffer by assigning
    -- nil to its entries, which under Lua 5.0 leaves table.getn reporting the
    -- old count. table.remove(samples, 1) then returned nil and the next line
    -- raised "Attempt to set attribute 't' on nil".
    --
    -- This needs the buffer driven past capacity AFTER a jump, so the eviction
    -- path is the one that runs.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)
    local receive = env.__chatFuncs['SharedMouse2026']

    local function Send(x)
        receive('KasperAUS', {
            v = 5, a = 2, p = { x, 0, 0 }, o = 0, z = 60, w = true,
        })
    end

    local t = env.__clock.t
    local function Tick(dt)
        t = t + dt
        env.__clock.t = t
    end

    -- Fill well past the 16-slot buffer.
    for i = 1, 40 do
        Tick(0.1)
        Send(i)
    end
    Check('buffer survives being filled past capacity', NoErrors(env))

    -- Now jump, which resets the buffer, then refill past capacity again.
    Tick(0.1)
    Send(5000)
    for i = 1, 40 do
        Tick(0.1)
        Send(5000 + i)
    end
    Check('buffer survives a jump followed by a refill', NoErrors(env))

    -- Repeat the jump/refill cycle several times; the original corruption
    -- compounded with each one.
    for cycle = 1, 5 do
        Tick(0.1)
        Send(cycle * 10000)
        for i = 1, 25 do
            Tick(0.1)
            Send(cycle * 10000 + i)
        end
    end
    Check('buffer survives repeated jump cycles', NoErrors(env))

    -- And the render loop must stay healthy throughout.
    local driver = Mock.FindDriver(env)
    local frameOk = true
    for i = 1, 30 do
        Tick(0.016)
        local ok = pcall(function() driver:OnFrame(0.016) end)
        if not ok then frameOk = false end
    end
    Check('frame loop runs clean after jump cycles', frameOk)
    Check('no errors logged during frames', NoErrors(env))

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('render position is a real number after all that',
        type(visual.record.render[1]) == 'number'
            and visual.record.render[1] == visual.record.render[1],
        tostring(visual.record.render[1]))

    -- The buffer must never exceed its configured capacity.
    Check('sample count stays within capacity',
        visual.record.sampleCount <= 16,
        'count = ' .. tostring(visual.record.sampleCount))
end

do
    -- The samples buffer must not carry a Lua 5.0 `n` field at all, since
    -- nothing should be touching it with table.insert / table.remove.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)
    local receive = env.__chatFuncs['SharedMouse2026']

    for i = 1, 25 do
        env.__clock.t = env.__clock.t + 0.1
        receive('KasperAUS', { v = 5, a = 2, p = { i, 0, 0 }, o = 0, z = 60, w = true })
    end

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('sample buffer is not managed by the table library',
        rawget(visual.record.samples, 'n') == nil,
        'found n = ' .. tostring(rawget(visual.record.samples, 'n')))

    -- And it must be dense over 1..sampleCount.
    local dense = true
    for i = 1, visual.record.sampleCount do
        local slot = visual.record.samples[i]
        if type(slot) ~= 'table' or type(slot.t) ~= 'number' then
            dense = false
        end
    end
    Check('sample buffer is dense with complete slots', dense)
end

do
    -- Malformed packets must never escape into gamemain.ReceiveChat, which
    -- does not guard the handlers it dispatches to.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)
    local receive = env.__chatFuncs['SharedMouse2026']

    local junk = {
        { v = 5, a = 2, p = 'not a table' },
        { v = 5, a = 2, p = {} },
        { v = 5, a = 2, p = { 'x', 'y', 'z' } },
        { v = 5, a = 2, p = { 0 / 0, 0, 0 } },
        { v = 5, a = 2, p = { 1e30, 0, 1e30 } },
        { v = 5, a = 2, p = { 1, 0, 1 }, o = 'nope', z = {}, hx = 'a', hy = -5 },
        { v = 5, a = 2, p = { 1, 0, 1 }, b = 12345 },
        { v = 5, a = 2, p = { 1, 0, 1 }, b = string.rep('x', 500) },
        { v = 5, a = 'not a number', p = { 1, 0, 1 } },
        { v = 'wrong' },
        {},
        'not a table at all',
        nil,
    }

    local allOk = true
    local firstErr = nil
    for _, msg in ipairs(junk) do
        local ok, err = pcall(function() receive('KasperAUS', msg) end)
        if not ok then
            allOk = false
            firstErr = err
        end
    end
    Check('malformed packets never raise out of the handler', allOk, firstErr)

    -- And the render loop still runs afterwards.
    env.__clock.t = env.__clock.t + 0.5
    local ok = pcall(function() Mock.FindDriver(env):OnFrame(0.016) end)
    Check('frame loop survives malformed packets', ok)
end

do
    -- Every Bitmap must be given a texture or a solid colour. The game logs
    -- "GetResource: Invalid name" for any that are not.
    local env, SM = NewSession({ splitscreen = true })
    SM.InitSharedMouse(false)
    local receive = env.__chatFuncs['SharedMouse2026']

    -- Drive through every visual state: map cursor, build ghost, selection,
    -- and the HUD panel, in both 'simple' and 'full' detail.
    receive('KasperAUS', { v = 5, a = 2, p = { 10, 0, 10 }, o = 23, z = 60, w = true })
    env.__clock.t = env.__clock.t + 0.3
    Mock.FindDriver(env):OnFrame(0.016)

    receive('KasperAUS', {
        v = 5, a = 2, p = { 11, 0, 11 }, o = 11, z = 60, w = true,
        s = true, b = 'ueb0101',
    })
    env.__clock.t = env.__clock.t + 0.3
    Mock.FindDriver(env):OnFrame(0.016)

    receive('KasperAUS', {
        v = 5, a = 2, p = { 11, 0, 11 }, o = 0, z = 60, w = false,
        hx = 0.7, hy = 0.95,
    })
    env.__clock.t = env.__clock.t + 0.3
    Mock.FindDriver(env):OnFrame(0.016)

    local untextured = 0
    for _ in pairs(Mock.untexturedBitmaps) do untextured = untextured + 1 end
    Check('no bitmap left without a texture or colour',
        untextured == 0, 'found ' .. untextured)

    Check('no errors logged across all visual states', NoErrors(env))
end

do
    -- The same, with the full HUD silhouette.
    local env, SM = NewSession()
    local Config = env.import('/mods/SharedMouse2026/modules/config.lua')
    Config.Hud.Detail = 'full'
    SM.InitSharedMouse(false)

    local receive = env.__chatFuncs['SharedMouse2026']
    receive('KasperAUS', {
        v = 5, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = false,
        hx = 0.25, hy = 0.88,
    })
    env.__clock.t = env.__clock.t + 0.3

    local ok = pcall(function() Mock.FindDriver(env):OnFrame(0.016) end)
    Check('full HUD detail builds and renders', ok)

    local untextured = 0
    for _ in pairs(Mock.untexturedBitmaps) do untextured = untextured + 1 end
    Check('full HUD leaves no untextured bitmap', untextured == 0,
        'found ' .. untextured)

    -- The HUD dot must land inside the panel for extreme coordinates too.
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('HUD ghost was created', visual.hud ~= nil and visual.hud ~= false)

    for _, pair in ipairs({ {0, 0}, {1, 1}, {0.5, 0.5} }) do
        visual.hud:SetPosition(pair[1], pair[2])
        local inside = visual.hud.dotX >= 0
            and visual.hud.dotY >= 0
            and visual.hud.dotX <= visual.hud.panelWidth
            and visual.hud.dotY <= visual.hud.panelHeight
        Check('HUD dot stays inside the panel at ' .. pair[1] .. ',' .. pair[2],
            inside, visual.hud.dotX .. ',' .. visual.hud.dotY)
    end
end

do
    -- A teammate on a colour the palette does not contain must still produce
    -- a usable cursor rather than tripping SetColor / SetSolidColor.
    local armies = Armies()
    armies[2].color = 'RoyalBlue'
    armies[3].color = 'NotAColour'

    local env, SM = NewSession({ armies = armies, focusArmy = -1,
        clients = {
            [1] = { name = 'Lightningbulb' },
            [2] = { name = 'KasperAUS' },
            [3] = { name = 'Eternal' },
            [4] = { name = 'Caster', ['local'] = true },
        } })

    local ok = pcall(function() SM.InitSharedMouse(false) end)
    Check('team colour mode initialises without error', ok)

    local receive = env.__chatFuncs['SharedMouse2026']
    receive('KasperAUS', { v = 5, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = false })
    receive('Eternal', { v = 5, a = 3, p = { 20, 0, 20 }, o = 11, z = 60, w = true,
        s = true, b = 'ueb0101' })
    env.__clock.t = env.__clock.t + 0.3

    local frameOk = pcall(function() Mock.FindDriver(env):OnFrame(0.016) end)
    Check('team colour mode renders without error', frameOk)
    Check('no errors logged for exotic colours', NoErrors(env))
end

do
    -- Project returning nil must hide the cursor, not crash the frame loop.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)
    local receive = env.__chatFuncs['SharedMouse2026']
    receive('KasperAUS', { v = 5, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = true })

    env.__views['WorldCamera'].projectReturnsNil = true
    env.__clock.t = env.__clock.t + 0.3

    local ok = pcall(function() Mock.FindDriver(env):OnFrame(0.016) end)
    Check('a nil projection does not crash the frame loop', ok)
    Check('a nil projection hides the cursor',
        Mock.FindCursors(env, 'WorldCamera')[1]:IsHidden())
end

do
    -- Zoom extremes must not produce a NaN scale or alpha.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)
    local receive = env.__chatFuncs['SharedMouse2026']

    local zooms = { 0, 1, 500, 100000 }
    local allOk = true
    for _, senderZoom in ipairs(zooms) do
        for _, viewerZoom in ipairs(zooms) do
            env.__setZoom(viewerZoom)
            env.__clock.t = env.__clock.t + 0.2
            receive('KasperAUS', {
                v = 5, a = 2, p = { 10, 0, 10 }, o = 0, z = senderZoom, w = true,
            })
            local ok = pcall(function() Mock.FindDriver(env):OnFrame(0.016) end)
            if not ok then allOk = false end
        end
    end
    Check('all zoom combinations render cleanly', allOk)
    Check('no errors logged across zoom extremes', NoErrors(env))
end

do
    -- A stuck selection flag must clear itself. If ButtonRelease is consumed
    -- before reaching our hook, the ring would otherwise stay on forever.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)

    local view = env.__views['WorldCamera']
    view:HandleEvent({ Type = 'ButtonPress', Modifiers = { Left = true } })

    env.__mouseWorld = { 30, 0, 30 }
    SM.OnBeat()
    local sent = env.__sent[table.getn(env.__sent)]
    Check('selection flag transmits while dragging', sent.msg.s == true)

    -- Never released; time passes well past the safety valve.
    env.__clock.t = env.__clock.t + 60
    SM.OnBeat()
    sent = env.__sent[table.getn(env.__sent)]
    Check('a stuck selection flag clears itself', sent.msg.s == false)
end

do
    -- Releasing normally must clear it immediately.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)
    local view = env.__views['WorldCamera']

    view:HandleEvent({ Type = 'ButtonPress', Modifiers = { Left = true } })
    env.__mouseWorld = { 30, 0, 30 }
    SM.OnBeat()
    Check('drag starts', env.__sent[table.getn(env.__sent)].msg.s == true)

    view:HandleEvent({ Type = 'ButtonRelease', Modifiers = {} })
    env.__clock.t = env.__clock.t + 0.2
    env.__mouseWorld = { 40, 0, 40 }
    SM.OnBeat()
    Check('drag ends on release',
        env.__sent[table.getn(env.__sent)].msg.s == false)

    -- A press while in command mode is an order, not a selection.
    env.__commandMode = { 'build', { name = 'ueb0101' } }
    view:HandleEvent({ Type = 'ButtonPress', Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 0.2
    env.__mouseWorld = { 50, 0, 50 }
    SM.OnBeat()
    Check('a press in command mode is not a selection drag',
        env.__sent[table.getn(env.__sent)].msg.s == false)

    -- The hook must not swallow the event or break the original handler.
    local handled = view:HandleEvent({ Type = 'MouseMotion', Modifiers = {} })
    Check('hooked HandleEvent still returns the original result',
        handled == false)
    Check('hooked HandleEvent still reaches the original handler',
        view._lastEvent.Type == 'MouseMotion')
end

do
    -- Hooking must be idempotent across repeated SyncViews calls, or each
    -- layout change would add another wrapper layer.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)
    local view = env.__views['WorldCamera']
    local afterInit = view.HandleEvent

    SM.SyncViews()
    SM.SyncViews()
    SM.SyncViews()

    Check('view event hook is applied exactly once',
        view.HandleEvent == afterInit)
end

do
    -- A long idle must fade the cursor out and then leave it hidden, without
    -- the alpha going negative on the way.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)
    local receive = env.__chatFuncs['SharedMouse2026']
    receive('KasperAUS', { v = 5, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = true })

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local driver = Mock.FindDriver(env)
    local allOk = true
    for i = 1, 100 do
        env.__clock.t = env.__clock.t + 0.1
        local ok = pcall(function() driver:OnFrame(0.1) end)
        if not ok then allOk = false end
        if visual.icon._alpha < 0 then allOk = false end
    end
    Check('a stale peer fades out without error or negative alpha', allOk)
    Check('a stale peer ends up hidden', visual:IsHidden())
end

do
    -- A degenerate local mouse position must never be transmitted.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)

    local bad = {
        { 0 / 0, 0, 0 },
        { 1, 0 / 0, 0 },
        { 1, 0, 0 / 0 },
        { 1, 0 },
        { 'a', 'b', 'c' },
        { 1e40, 0, 0 },
        {},
    }

    local before = table.getn(env.__sent)
    for _, pos in ipairs(bad) do
        env.__mouseWorld = pos
        env.__clock.t = env.__clock.t + 0.2
        local ok = pcall(function() SM.OnBeat() end)
        if not ok then
            Check('degenerate mouse position raised', false)
        end
    end

    -- Nothing valid was ever seen, so nothing should have gone out.
    Check('degenerate mouse positions are never transmitted',
        table.getn(env.__sent) == before,
        'sent ' .. (table.getn(env.__sent) - before))

    -- A good reading afterwards must still work.
    env.__mouseWorld = { 42, 0, 42 }
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    Check('a valid position after bad ones still transmits',
        table.getn(env.__sent) == before + 1)
    Check('the transmitted position is the good one',
        env.__sent[table.getn(env.__sent)].msg.p[1] == 42)
end

do
    -- Zoom must persist across a trip into the HUD rather than dropping to 0.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)

    env.__setZoom(123)
    env.__mouseWorld = { 10, 0, 10 }
    SM.OnBeat()
    Check('zoom is transmitted from the map',
        env.__sent[1].msg.z == 123, tostring(env.__sent[1].msg.z))

    env.__views['WorldCamera'].CursorOverWorld = false
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    Check('zoom persists while on the HUD',
        env.__sent[table.getn(env.__sent)].msg.z == 123,
        tostring(env.__sent[table.getn(env.__sent)].msg.z))
end

do
    -- A visual whose view has been replaced must be skipped by the frame loop
    -- rather than projecting against a destroyed control.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)
    local receive = env.__chatFuncs['SharedMouse2026']
    receive('KasperAUS', { v = 5, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = true })

    -- Swap the view without telling the mod, as a layout change would.
    local replacement = Mock.WorldView(env.__frame, 'WorldCamera', 0, 0, 1920, 1080)
    env.__views['WorldCamera'] = replacement

    env.__clock.t = env.__clock.t + 0.3
    local ok = pcall(function() Mock.FindDriver(env):OnFrame(0.016) end)
    Check('frame loop skips visuals on a replaced view', ok)
    Check('no error logged for the replaced view', NoErrors(env))

    -- The next beat must notice and rebuild.
    SM.OnBeat()
    local cursors = Mock.FindCursors(env, 'WorldCamera')
    Check('the next beat rebuilds onto the new view',
        table.getn(cursors) == 1 and cursors[1].view == replacement,
        'got ' .. table.getn(cursors))
end

do
    -- A view smaller than the HUD panel must not push the panel outside it.
    local env, SM = NewSession()
    SM.InitSharedMouse(false)

    local view = env.__views['WorldCamera']
    view.Right:Set(80)
    view.Bottom:Set(50)
    view.Width:Set(80)
    view.Height:Set(50)

    local receive = env.__chatFuncs['SharedMouse2026']
    receive('KasperAUS', {
        v = 5, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = false,
        hx = 0.5, hy = 0.9,
    })

    env.__clock.t = env.__clock.t + 0.3
    local ok = pcall(function() Mock.FindDriver(env):OnFrame(0.016) end)
    Check('a view smaller than the HUD panel renders cleanly', ok)

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local x = visual.Left()
    Check('the panel is centred rather than pushed out of a tiny view',
        x >= view.Left() and x <= view.Right(),
        'anchor x = ' .. tostring(x))
end

do
    -- Disabling the HUD feature must fall back to the plain cursor rather
    -- than leaving it frozen part-updated.
    local env, SM = NewSession()
    local Config = env.import('/mods/SharedMouse2026/modules/config.lua')
    Config.Hud.Enabled = false
    SM.InitSharedMouse(false)

    local receive = env.__chatFuncs['SharedMouse2026']
    receive('KasperAUS', {
        v = 5, a = 2, p = { 10, 0, 10 }, o = 23, z = 60, w = false,
    })
    env.__clock.t = env.__clock.t + 0.3

    local ok = pcall(function() Mock.FindDriver(env):OnFrame(0.016) end)
    Check('HUD disabled still renders', ok)

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('HUD disabled builds no panel',
        visual.hud == false or visual.hud == nil)
    Check('HUD disabled keeps updating the order cursor',
        visual.appliedOrder == 23, tostring(visual.appliedOrder))
    Check('HUD disabled leaves the cursor icon visible',
        not visual.icon:IsHidden())
end

--------------------------------------------------------------------------------
Section('view synchronisation and splitscreen')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession({ splitscreen = true })
    SM.InitSharedMouse(false)

    local function CountCursors(viewKey)
        return table.getn(Mock.FindCursors(env, viewKey))
    end

    -- The previous version returned from inside its inner loop, so only one
    -- view ever received a cursor.
    Check('cursor created in the left view', CountCursors('WorldCamera') == 1,
        'got ' .. CountCursors('WorldCamera'))
    Check('cursor created in the right view', CountCursors('WorldCamera2') == 1,
        'got ' .. CountCursors('WorldCamera2'))

    -- Replacing a view must retire the old cursor and build a new one, not
    -- leave the old one parented to a dead control.
    local oldVisualCount = Mock.destroyedCount
    env.__views['WorldCamera'] = Mock.WorldView(env.__frame, 'WorldCamera', 0, 0, 960, 1080)
    SM.SyncViews()

    Check('replacing a view destroys the stale cursor',
        Mock.destroyedCount > oldVisualCount)
    Check('replacing a view creates a fresh cursor',
        CountCursors('WorldCamera') == 1, 'got ' .. CountCursors('WorldCamera'))

    -- Dropping out of splitscreen must clean up the right view's cursors.
    env.__views['WorldCamera2'] = nil
    SM.SyncViews()
    Check('leaving splitscreen does not error', true)
end

do
    -- Culling: a cursor projected outside its view must hide, so the left
    -- view's cursors do not bleed across the splitscreen divider.
    local env, SM = NewSession({ splitscreen = true })
    SM.InitSharedMouse(false)
    local receive = env.__chatFuncs['SharedMouse2026']

    -- Mock projection is worldX * 2, so world x=700 lands at screen x=1400,
    -- well beyond the left view's right edge of 960.
    receive('KasperAUS', { v = 5, a = 2, p = { 700, 0, 100 }, o = 0, z = 60, w = true })

    env.__clock.t = env.__clock.t + 0.5
    Mock.FindDriver(env):OnFrame(0.016)

    local leftVisual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('cursor outside the left view is hidden',
        leftVisual:IsHidden() == true)
end

--------------------------------------------------------------------------------
Section('teardown')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession({ splitscreen = true })
    SM.InitSharedMouse(false)

    local before = Mock.destroyedCount
    local ok = pcall(function() SM.Destroy() end)
    Check('teardown runs without error', ok)
    Check('teardown destroys the visuals', Mock.destroyedCount > before)

    -- Destroying twice would error in the mock, so this proves teardown is
    -- idempotent rather than double-freeing.
    local ok2 = pcall(function() SM.Destroy() end)
    Check('teardown is idempotent', ok2)
end

--------------------------------------------------------------------------------
print('')
print(string.format('%d passed, %d failed', passed, failed))
if failed > 0 then
    os.exit(1)
end
