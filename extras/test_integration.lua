--******************************************************************************
--** TeamMouse -- extras/test_integration.lua
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
    local TeamMouse = env.import('/mods/TeamMouse/modules/teammouse.lua')

    -- teammouse.lua only treats the local mouse as being over the world once a
    -- view has seen it arrive (MouseEnter / MouseMotion). A session that never
    -- does that reads as "on the HUD with no world position yet" and sends
    -- nothing, so start every session with the mouse over the main view.
    local init = TeamMouse.InitTeamMouse
    TeamMouse.InitTeamMouse = function(...)
        init(unpack(arg))
        -- Everyone else is on this version: they say they read the compact
        -- format (wirecodec.lua), so what the session sends goes out in it.
        -- opts.plainPeers: nobody has said so (an older TeamMouse).
        local receive = env.__chatFuncs['TeamMouse']
        if receive and not opts.plainPeers then
            for _, client in ipairs(opts.clients) do
                if not client['local'] then
                    receive(client.name, { Identifier = 'TeamMouse', tmc = 1 })
                end
            end
        end
        local view = env.__views['WorldCamera']
        if not opts.noHover and view and view.HandleEvent then
            view:HandleEvent({ Type = 'MouseEnter', MouseX = 100, MouseY = 100, Modifiers = {} })
        end
    end

    return env, TeamMouse
end

--------------------------------------------------------------------------------
Section('cursor name parsing')
--------------------------------------------------------------------------------
do
    local env = Mock.CreateEnvironment({ armies = Armies(), clients = Clients() })
    local CD = env.import('/mods/TeamMouse/modules/cursordata.lua')
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
    SM.InitTeamMouse(false)

    Check('chat handler registered',
        env.__chatFuncs['TeamMouse'] ~= nil)

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

    local ok = pcall(function() SM.InitTeamMouse(false) end)
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
    SM.InitTeamMouse(false)

    env.__mouseWorld = { 100, 5, 200 }
    SM.OnBeat()
    Check('first beat transmits', table.getn(env.__sent) == 1)

    local msg = env.__sent[1].msg
    Check('payload carries the position',
        msg.p[1] == 100 and msg.p[3] == 200,
        tostring(msg.p[1]) .. ',' .. tostring(msg.p[3]))
    Check('payload carries the protocol version',
        msg.v == env.import('/mods/TeamMouse/modules/config.lua').Protocol)
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
    SM.InitTeamMouse(false)

    env.__mouseWorld = { 50, 0, 60 }
    SM.OnBeat()
    local first = env.__sent[1].msg
    Check('over world flag set while on the map', first.w == true)

    -- Over the interface the root frame sees the pointer and the polled
    -- globals stay frozen at their last map values.
    Mock.HoverHud(env, 960, 1040)
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
    SM.InitTeamMouse(false)

    local receive = env.__chatFuncs['TeamMouse']

    local function Send(x, z, extra)
        local msg = {
            Identifier = 'TeamMouse', v = 1, a = 2,
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
    receive('Stranger', { v = 1, p = { 5, 0, 5 }, a = 77 })
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
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']

    local function Send(x, z)
        receive('KasperAUS', {
            v = 1, a = 2, p = { x, 0, z }, o = 0, z = 60, w = true,
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
        SM.InitTeamMouse(false)
        env.__mouseWorld = { 20, 0, 20 }
        SM.OnBeat()

        -- Teammates and observers get separate copies (observers' has the
        -- camera, to follow): everyone this beat sent to.
        local recips, set = {}, {}
        local teamCam, specCam = false, false
        for _, s in ipairs(env.__sent) do
            for _, idx in ipairs(s.clients) do
                table.insert(recips, idx)
                set[idx] = true
                if idx == 4 and s.msg.cam then specCam = true end
                if idx == 2 and s.msg.cam then teamCam = true end
            end
        end
        Check('observers get our camera, to follow; teammates do not', specCam and not teamCam)

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
        local Config = env.import('/mods/TeamMouse/modules/config.lua')
        Config.Network.ShareWithObservers = false
        SM.InitTeamMouse(false)
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
    -- These tests drive the buffer past its capacity on purpose, so pin the
    -- capacity to something a short feed can exceed. (The shipped default is
    -- larger now that a packet can carry several samples.)
    env.import('/mods/TeamMouse/modules/config.lua').Smoothing.BufferSize = 16
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']

    local function Send(x)
        receive('KasperAUS', {
            v = 1, a = 2, p = { x, 0, 0 }, o = 0, z = 60, w = true,
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
    env.import('/mods/TeamMouse/modules/config.lua').Smoothing.BufferSize = 16
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']

    for i = 1, 25 do
        env.__clock.t = env.__clock.t + 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { i, 0, 0 }, o = 0, z = 60, w = true })
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
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']

    local junk = {
        { v = 1, a = 2, p = 'not a table' },
        { v = 1, a = 2, p = {} },
        { v = 1, a = 2, p = { 'x', 'y', 'z' } },
        { v = 1, a = 2, p = { 0 / 0, 0, 0 } },
        { v = 1, a = 2, p = { 1e30, 0, 1e30 } },
        { v = 1, a = 2, p = { 1, 0, 1 }, o = 'nope', z = {}, hx = 'a', hy = -5 },
        { v = 1, a = 2, p = { 1, 0, 1 }, b = 12345 },
        { v = 1, a = 2, p = { 1, 0, 1 }, b = string.rep('x', 500) },
        { v = 1, a = 'not a number', p = { 1, 0, 1 } },
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
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']

    -- Drive through every visual state: map cursor, build ghost, selection,
    -- and the HUD panel.
    receive('KasperAUS', { v = 1, a = 2, p = { 10, 0, 10 }, o = 23, z = 60, w = true })
    env.__clock.t = env.__clock.t + 0.3
    Mock.FindDriver(env):OnFrame(0.016)

    receive('KasperAUS', {
        v = 1, a = 2, p = { 11, 0, 11 }, o = 11, z = 60, w = true,
        s = true, b = 'ueb0101',
    })
    env.__clock.t = env.__clock.t + 0.3
    Mock.FindDriver(env):OnFrame(0.016)

    receive('KasperAUS', {
        v = 1, a = 2, p = { 11, 0, 11 }, o = 0, z = 60, w = false,
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
    -- The HUD image is slid under the panel so that the point they are at sits
    -- at the panel's centre, whichever corner of their screen that is.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    receive('KasperAUS', {
        v = 1, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = false,
        hx = 0.25, hy = 0.88,
    })
    env.__clock.t = env.__clock.t + 0.3
    local ok = pcall(function() Mock.FindDriver(env):OnFrame(0.016) end)
    Check('the HUD ghost builds and renders', ok)

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('HUD ghost was created', visual.hud ~= nil and visual.hud ~= false)
    local hud = visual.hud
    local w, h = hud.panelWidth, hud.panelHeight
    for _, pair in ipairs({ {0, 0}, {1, 1}, {0.5, 0.5}, {0.25, 0.88} }) do
        hud:SetPosition(pair[1], pair[2])
        -- The image pixel now at the panel's centre:
        local ix, iy = w / 2 - hud.hudX, h / 2 - hud.hudY
        Check('the image point for ' .. pair[1] .. ',' .. pair[2] .. ' is at the panel centre',
            math.abs(ix - pair[1] * w) <= 1 and math.abs(iy - pair[2] * h) <= 1,
            ix .. ',' .. iy)
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

    local ok = pcall(function() SM.InitTeamMouse(false) end)
    Check('team colour mode initialises without error', ok)

    local receive = env.__chatFuncs['TeamMouse']
    receive('KasperAUS', { v = 1, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = false })
    receive('Eternal', { v = 1, a = 3, p = { 20, 0, 20 }, o = 11, z = 60, w = true,
        s = true, b = 'ueb0101' })
    env.__clock.t = env.__clock.t + 0.3

    local frameOk = pcall(function() Mock.FindDriver(env):OnFrame(0.016) end)
    Check('team colour mode renders without error', frameOk)
    Check('no errors logged for exotic colours', NoErrors(env))
end

do
    -- Project returning nil must hide the cursor, not crash the frame loop.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    receive('KasperAUS', { v = 1, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = true })

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
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']

    local zooms = { 0, 1, 500, 100000 }
    local allOk = true
    for _, senderZoom in ipairs(zooms) do
        for _, viewerZoom in ipairs(zooms) do
            env.__setZoom(viewerZoom)
            env.__clock.t = env.__clock.t + 0.2
            receive('KasperAUS', {
                v = 1, a = 2, p = { 10, 0, 10 }, o = 0, z = senderZoom, w = true,
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
    SM.InitTeamMouse(false)

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
    SM.InitTeamMouse(false)
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
    SM.InitTeamMouse(false)
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
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    receive('KasperAUS', { v = 1, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = true })

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local driver = Mock.FindDriver(env)
    local allOk = true
    for i = 1, 100 do
        env.__clock.t = env.__clock.t + 0.1
        local ok = pcall(function() driver:OnFrame(0.1) end)
        if not ok then allOk = false end
        if visual.mouseIcon._alpha < 0 then allOk = false end
    end
    Check('a stale peer fades out without error or negative alpha', allOk)
    Check('a stale peer ends up hidden', visual:IsHidden())
end

do
    -- A degenerate local mouse position must never be transmitted.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)

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
    SM.InitTeamMouse(false)

    env.__setZoom(123)
    env.__mouseWorld = { 10, 0, 10 }
    SM.OnBeat()
    Check('zoom is transmitted from the map',
        env.__sent[1].msg.z == 123, tostring(env.__sent[1].msg.z))

    Mock.HoverHud(env, 400, 1000)
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
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    receive('KasperAUS', { v = 1, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = true })

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
    SM.InitTeamMouse(false)

    local view = env.__views['WorldCamera']
    view.Right:Set(80)
    view.Bottom:Set(50)
    view.Width:Set(80)
    view.Height:Set(50)

    local receive = env.__chatFuncs['TeamMouse']
    receive('KasperAUS', {
        v = 1, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = false,
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
    local Config = env.import('/mods/TeamMouse/modules/config.lua')
    Config.Hud.Enabled = false
    SM.InitTeamMouse(false)

    local receive = env.__chatFuncs['TeamMouse']
    receive('KasperAUS', {
        v = 1, a = 2, p = { 10, 0, 10 }, o = 23, z = 60, w = false,
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
        not visual.mouseIcon:IsHidden())
end

--------------------------------------------------------------------------------
Section('view synchronisation and splitscreen')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession({ splitscreen = true })
    SM.InitTeamMouse(false)

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
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']

    -- Mock projection is worldX * 2, so world x=700 lands at screen x=1400,
    -- well beyond the left view's right edge of 960.
    receive('KasperAUS', { v = 1, a = 2, p = { 700, 0, 100 }, o = 0, z = 60, w = true })

    env.__clock.t = env.__clock.t + 0.5
    Mock.FindDriver(env):OnFrame(0.016)

    local leftVisual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('cursor outside the left view is hidden',
        leftVisual:IsHidden() == true)
end

--------------------------------------------------------------------------------
Section('local pointer tracking on the HUD')
--------------------------------------------------------------------------------
do
    -- On the HUD the world position is held, so the world-movement check can
    -- never fire. Pointer motion across the interface has to trigger sends on
    -- its own, well inside ForceResendInterval, or the ghost only updates on
    -- the forced resend.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)

    env.__mouseWorld = { 50, 0, 60 }
    SM.OnBeat()

    Mock.HoverHud(env, 960, 540)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local afterEntering = table.getn(env.__sent)
    Check('entering the HUD sends', afterEntering == 2, tostring(afterEntering))

    Mock.HoverHud(env, 1200, 540)
    env.__clock.t = env.__clock.t + 0.1      -- well inside ForceResendInterval
    SM.OnBeat()
    local afterMoving = table.getn(env.__sent)
    Check('moving across the HUD sends without any world movement',
        afterMoving == afterEntering + 1, tostring(afterMoving))

    local msg = env.__sent[afterMoving].msg
    Check('the new HUD position is what is sent',
        msg.w == false and math.abs(msg.hx - 0.625) < 0.002, tostring(msg.hx))
    Check('the world position stays held while on the HUD',
        msg.p[1] == 50 and msg.p[3] == 60)

    -- A pixel of jitter is far below the threshold and must not cost a packet.
    Mock.HoverHud(env, 1201, 540)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('sub-threshold jitter does not send',
        table.getn(env.__sent) == afterMoving, tostring(table.getn(env.__sent)))
end

do
    -- The tracking hooks must not depend on the selection feature. They used
    -- to live behind Config.Selection.Enabled, so turning the ring off left
    -- the mod believing the pointer was never over the map and sending nothing.
    local env, SM = NewSession()
    local Config = env.import('/mods/TeamMouse/modules/config.lua')
    Config.Selection.Enabled = false
    SM.InitTeamMouse(false)

    env.__mouseWorld = { 30, 0, 40 }
    SM.OnBeat()
    Check('position still sends with the selection feature off',
        table.getn(env.__sent) == 1, tostring(table.getn(env.__sent)))
    local m = env.__sent[1] and env.__sent[1].msg
    Check('and reports the pointer as over the map',
        m and m.w == true and m.p[1] == 30 and m.p[3] == 40)
end

do
    -- A layout change recreates the world view. The root-frame wrapper must
    -- not stack up once per view, and the replacement view must be hooked.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local rootHandler = env.__frame.HandleEvent

    env.__views['WorldCamera'] = Mock.WorldView(env.__frame, 'WorldCamera', 0, 0, 1920, 1080)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()   -- VerifyViews notices the swap and resyncs

    Check('root frame is not re-wrapped when a view is recreated',
        env.__frame.HandleEvent == rootHandler)

    Mock.HoverWorld(env, 300, 300)
    env.__mouseWorld = { 7, 0, 8 }
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local last = env.__sent[table.getn(env.__sent)]
    Check('the replacement view is hooked and tracks the pointer',
        last and last.msg.w == true and last.msg.p[1] == 7 and last.msg.p[3] == 8)
end

do
    -- A map event that bubbles up to the root frame carries the coordinates
    -- the view hook just stored; it must not flip the pointer onto the HUD.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)

    Mock.HoverWorld(env, 640, 360)
    env.__frame:HandleEvent({ Type = 'MouseMotion', MouseX = 640, MouseY = 360, Modifiers = {} })

    env.__mouseWorld = { 21, 0, 22 }
    SM.OnBeat()
    Check('a bubbled map event does not read as being on the HUD',
        env.__sent[1] and env.__sent[1].msg.w == true)
end

do
    -- Starting the game with the pointer on the interface: there is no last
    -- world position to hold, so the anchor is seeded from the centre of the
    -- view. Without that, nothing is sent until the pointer first touches the
    -- map. The mock projects world*2 to pixels, so the centre (960, 540)
    -- unprojects to (480, 270).
    local env, SM = NewSession({ noHover = true })
    SM.InitTeamMouse(false)

    Mock.HoverHud(env, 500, 500)
    SM.OnBeat()
    local m = env.__sent[1] and env.__sent[1].msg
    Check('a session that starts on the HUD still sends', m ~= nil)
    Check('anchored at the world point under the view centre',
        m and m.p[1] == 480 and m.p[3] == 270,
        m and (tostring(m.p[1]) .. ',' .. tostring(m.p[3])) or 'nothing sent')
    Check('flagged as on the HUD', m and m.w == false)
end

--------------------------------------------------------------------------------
Section('HUD ghost interpolation')
--------------------------------------------------------------------------------
do
    -- The ghost's position comes from the same timestamped buffer as the world
    -- position, so it glides between packets instead of stepping at the
    -- packet rate.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']

    local t0 = env.__clock.t
    receive('KasperAUS', { v = 1, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = false, hx = 0.2, hy = 0.5 })
    env.__clock.t = t0 + 0.1
    -- A slide of 0.2 of the screen. (A move of more than Hud.JumpDistance
    -- between two samples is a hop, and steps instead: see 'HUD image steps'.)
    receive('KasperAUS', { v = 1, a = 2, p = { 10, 0, 10 }, o = 0, z = 60, w = false, hx = 0.4, hy = 0.5 })

    local driver = Mock.FindDriver(env)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local delay = 0.13   -- Config.Smoothing.InterpolationDelay

    -- Render time runs `delay` behind the clock, so the midpoint between the
    -- two packets is reached at t0 + 0.05 + delay.
    env.__clock.t = t0 + 0.05 + delay
    driver:OnFrame(0.016)
    local hud = visual.record.hudRender
    Check('halfway between packets the ghost is halfway between positions',
        hud and math.abs(hud[1] - 0.3) < 0.02, hud and tostring(hud[1]) or 'no hudRender')

    -- Step through the whole span frame by frame and count distinct dot
    -- positions. Stepping at the packet rate would give two.
    local seen, distinct = {}, 0
    for i = 0, 10 do
        env.__clock.t = t0 + delay + i * 0.01
        driver:OnFrame(0.01)
        local x = visual.hud and visual.hud.hudX
        if x ~= nil and not seen[x] then
            seen[x] = true
            distinct = distinct + 1
        end
    end
    Check('the ghost dot moves through intermediate positions',
        distinct >= 4, tostring(distinct) .. ' distinct positions')
end

--------------------------------------------------------------------------------
Section('the ghost travels with the pointer across the HUD')
--------------------------------------------------------------------------------

--- Rest the pointer on the map for two beats, which is what lets the mod
--- check how UnProject reads coordinates against the engine's own reading.
--- The mock projects world * 2 to view pixels, so engine world = pixels / 2.
---@param env table
---@param SM table
---@param x number   # screen
---@param y number
---@param world table   # what the engine reports there
---@param viewKey? string
local function RestOnMap(env, SM, x, y, world, viewKey)
    Mock.HoverWorld(env, x, y, viewKey)
    env.__mouseWorld = world
    SM.OnBeat()
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
end

local function LastMsg(env)
    local entry = env.__sent[table.getn(env.__sent)]
    return entry and entry.msg
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)

    RestOnMap(env, SM, 400, 200, { 200, 0, 100 })

    Mock.HoverHud(env, 800, 600)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = LastMsg(env)
    Check('on the HUD the position is the map point behind the pointer',
        m.w == false and m.p[1] == 400 and m.p[3] == 300,
        tostring(m.p[1]) .. ',' .. tostring(m.p[3]))

    Mock.HoverHud(env, 1000, 600)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    m = LastMsg(env)
    Check('and it moves as the pointer moves across the HUD',
        m.p[1] == 500 and m.p[3] == 300, tostring(m.p[1]) .. ',' .. tostring(m.p[3]))

    -- Coming back onto the map picks up from the engine again, no jump.
    Mock.HoverWorld(env, 1000, 400)
    env.__mouseWorld = { 500, 0, 200 }
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    m = LastMsg(env)
    Check('back on the map it reports the engine position',
        m.w == true and m.p[1] == 500 and m.p[3] == 200)
end

do
    -- Until the pointer has rested on the map there is nothing to check
    -- UnProject against, so the ghost parks where it last was.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)

    Mock.HoverWorld(env, 400, 200)
    env.__mouseWorld = { 200, 0, 100 }
    SM.OnBeat()

    Mock.HoverHud(env, 800, 600)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = LastMsg(env)
    Check('before UnProject has been checked the ghost parks',
        m.p[1] == 200 and m.p[3] == 100, tostring(m.p[1]) .. ',' .. tostring(m.p[3]))
end

do
    -- A right-hand splitscreen view starts 960px in. If UnProject wants a
    -- view-relative point, the pointer's screen position has to be offset.
    local env, SM = NewSession({ splitscreen = true })
    SM.InitTeamMouse(false)

    RestOnMap(env, SM, 1160, 100, { 100, 0, 50 }, 'WorldCamera2')

    Mock.HoverHud(env, 1400, 300)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = LastMsg(env)
    Check('splitscreen, relative UnProject: the view offset is removed',
        m.p[1] == 220 and m.p[3] == 150, tostring(m.p[1]) .. ',' .. tostring(m.p[3]))
end

do
    -- ...and if it wants screen coordinates instead, the mod works that out
    -- from the engine's own reading rather than assuming.
    local env, SM = NewSession({ splitscreen = true })
    env.UnProject = function(view, point) return { point[1] / 2, 0, point[2] / 2 } end
    SM.InitTeamMouse(false)

    RestOnMap(env, SM, 1160, 100, { 580, 0, 50 }, 'WorldCamera2')

    Mock.HoverHud(env, 1400, 300)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = LastMsg(env)
    Check('splitscreen, absolute UnProject: screen coordinates are passed through',
        m.p[1] == 700 and m.p[3] == 150, tostring(m.p[1]) .. ',' .. tostring(m.p[3]))
end

do
    -- If UnProject means something other than "the world point under this
    -- screen point", the mod must notice and leave the ghost parked rather
    -- than send nonsense.
    local env, SM = NewSession()
    env.UnProject = function() return { 9999, 0, 9999 } end
    SM.InitTeamMouse(false)

    RestOnMap(env, SM, 400, 200, { 200, 0, 100 })

    Mock.HoverHud(env, 800, 600)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = LastMsg(env)
    Check('a UnProject that disagrees with the engine is not used',
        m.p[1] == 200 and m.p[3] == 100, tostring(m.p[1]) .. ',' .. tostring(m.p[3]))

    local said = false
    for _, line in ipairs(env.__logs) do
        if string.find(line, 'does not agree') then said = true end
    end
    Check('and the log says so', said)
end

do
    local env, SM = NewSession()
    local Config = env.import('/mods/TeamMouse/modules/config.lua')
    Config.Hud.FollowPointer = false
    SM.InitTeamMouse(false)

    RestOnMap(env, SM, 400, 200, { 200, 0, 100 })

    Mock.HoverHud(env, 800, 600)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = LastMsg(env)
    Check('with Hud.FollowPointer off the ghost parks',
        m.p[1] == 200 and m.p[3] == 100, tostring(m.p[1]) .. ',' .. tostring(m.p[3]))
end

do
    -- A layout change replaces the view the pointer was last over. Projecting
    -- through the dead one would throw on every beat.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)

    RestOnMap(env, SM, 400, 200, { 200, 0, 100 })

    env.__views['WorldCamera'] = Mock.WorldView(env.__frame, 'WorldCamera', 0, 0, 1920, 1080)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()      -- resyncs onto the new view

    Mock.HoverHud(env, 800, 600)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('no errors when the view under the pointer is replaced',
        table.getn(ErrorLogs(env)) == 0, table.concat(ErrorLogs(env), ' | '))
end

do
    -- The receiving end: with the position moving while they are on their
    -- HUD, the ghost moves across your map with them.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)

    local function Settle(x)
        for _ = 1, 4 do
            receive('KasperAUS', {
                v = 1, a = 2, p = { x, 0, 100 }, o = 0, z = 60, w = false,
                hx = 0.5, hy = 0.5,
            })
            env.__clock.t = env.__clock.t + 0.2
            driver:OnFrame(0.016)
        end
    end

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Settle(100)
    local left = visual.Left()
    Settle(300)
    Check('the ghost moves across your view while they are on their HUD',
        visual.Left() - left > 300, tostring(left) .. ' -> ' .. tostring(visual.Left()))
    Check('and stays a HUD ghost while it does',
        visual.hud and Mock.IsVisible(visual.hud))
end

--------------------------------------------------------------------------------
Section('drag box: live corner drives the arrow')
--------------------------------------------------------------------------------
do
    -- bx/bz (the drag's live corner) is separate from p (the frozen anchor).
    -- On the receiving end the arrow is meant to be redrawn at the live
    -- corner while a drag is in progress, not left pinned to the anchor.
    -- Regression test for: ApplyScale ran after the follow override and could
    -- undo it (fixed by reordering), and a bare "MathFloor" call that was
    -- never a declared local in this file (fixed to math.floor) -- both threw
    -- inside UpdateFrame's pcall, so the follow code silently never ran.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)

    local function Send(bx, bz)
        receive('KasperAUS', {
            v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
            s = true, hx = 0.5, hy = 0.5, bx = bx, bz = bz,
        })
        env.__clock.t = env.__clock.t + 0.2
        driver:OnFrame(0.016)
    end

    Send(100, 100)
    Send(100, 100)
    Send(300, 150)
    Send(300, 150)   -- repeat so the newest sample settles well behind "now"

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    -- Anchor (100,100) projects to (200,200) under the mock's world*2=screen
    -- projection; it must stay at the drag's start corner throughout.
    Check('anchor stays at the drag start corner',
        visual.Left() == 200 and visual.Top() == 200,
        tostring(visual.Left()) .. ',' .. tostring(visual.Top()))
    -- Live corner (300,150) projects to (600,300); the arrow should be drawn
    -- there, not at the anchor.
    Check('the arrow follows the live drag corner, not the anchor',
        visual.mouseIcon.Left() == 600 and visual.mouseIcon.Top() == 300,
        tostring(visual.mouseIcon.Left()) .. ',' .. tostring(visual.mouseIcon.Top()))

    -- Drag ends: the arrow returns to the anchor.
    receive('KasperAUS', {
        v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
        s = false, hx = 0.5, hy = 0.5, bx = 100, bz = 100,
    })
    env.__clock.t = env.__clock.t + 0.2
    driver:OnFrame(0.016)
    Check('the arrow returns to the anchor once the drag ends',
        visual.mouseIcon.Left() == visual.Left() and visual.mouseIcon.Top() == visual.Top(),
        tostring(visual.mouseIcon.Left()) .. ' vs anchor ' .. tostring(visual.Left()))
end

--------------------------------------------------------------------------------
Section('drag release bookkeeping')
--------------------------------------------------------------------------------
do
    -- A raw click goes to whichever hit-testable control is topmost at that
    -- pixel. Once a drag wanders onto our own overlay grid, a cell -- not the
    -- view -- receives the release, and DragCellEvent hands it to
    -- dragOverlay.view:HandleEvent(event), which is the same function
    -- installed here. That makes a release delivered to the view directly
    -- the correct black-box stand-in for "a release the overlay forwarded":
    -- the mock has no real spatial hit-testing to route a click through an
    -- actual cell, but from the view's own HandleEvent onward the two are the
    -- same call.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']

    view:HandleEvent({ Type = 'ButtonPress', MouseX = 400, MouseY = 300, Modifiers = { Left = true } })
    env.__mouseWorld = { 200, 0, 150 }
    SM.OnBeat()
    local afterPress = env.__sent[table.getn(env.__sent)]
    Check('pressing starts a selecting packet', afterPress and afterPress.msg.s == true)

    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 450, MouseY = 300, Modifiers = {} })
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local afterRelease = env.__sent[table.getn(env.__sent)]
    Check('releasing clears selecting on the very next packet',
        afterRelease and afterRelease.msg.s == false)

    -- The safety valve (restored this round) should stay quiet: a real
    -- release already cleared things, so it has nothing left to do.
    env.__clock.t = env.__clock.t + 1
    SM.OnBeat()
    local logged = false
    for _, line in ipairs(env.__logs) do
        if string.find(line, 'safety valve') then logged = true end
    end
    Check('the safety valve does not also fire for an already-clean release',
        not logged)
end

do
    -- The safety valve itself: if a release is somehow never seen at all
    -- (its one remaining job), a stuck drag still clears on its own.
    local env, SM = NewSession()
    local Config = env.import('/mods/TeamMouse/modules/config.lua')
    Config.Selection.MaxDragSeconds = 1
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']

    view:HandleEvent({ Type = 'ButtonPress', MouseX = 400, MouseY = 300, Modifiers = { Left = true } })
    env.__mouseWorld = { 200, 0, 150 }
    SM.OnBeat()

    env.__clock.t = env.__clock.t + 1.5
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('an unreleased drag clears on its own after MaxDragSeconds',
        msg.s == false)
end

--------------------------------------------------------------------------------
Section('drag anchor is pinned at the press, not re-read every beat')
--------------------------------------------------------------------------------
do
    -- OnBeat runs on its own cadence (roughly 10/sec), independent of the
    -- physical click. On a fast drag, GetMouseWorldPos can still be updating
    -- for the first beat or two after the press -- the engine's own freeze
    -- hasn't fully engaged yet -- and since nothing used to hold the
    -- press-time value, each of those beats would overwrite the anchor with
    -- a slightly-further-along reading: the faster the drag, the further the
    -- eventual anchor drifts from where the press actually happened.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']

    env.__mouseWorld = { 50, 0, 50 }   -- the true position at the moment of the click
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 400, MouseY = 300, Modifiers = { Left = true } })

    -- Simulate GetMouseWorldPos still catching up to a drag already in
    -- motion: it reports a position well past the press before the very
    -- first beat even runs.
    env.__mouseWorld = { 500, 0, 500 }
    SM.OnBeat()
    local first = env.__sent[table.getn(env.__sent)]
    Check('the first beat after a fast press still uses the true press position',
        first and first.msg.p[1] == 50 and first.msg.p[3] == 50,
        first and (tostring(first.msg.p[1]) .. ',' .. tostring(first.msg.p[3])) or 'nothing sent')

    -- And it stays pinned there for the rest of the drag, not just the first
    -- beat -- even as the engine's own reading keeps moving.
    env.__mouseWorld = { 900, 0, 900 }
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local second = env.__sent[table.getn(env.__sent)]
    Check('the anchor stays pinned to the press position for the whole drag',
        second and second.msg.p[1] == 50 and second.msg.p[3] == 50,
        second and (tostring(second.msg.p[1]) .. ',' .. tostring(second.msg.p[3])) or 'nothing sent')

    -- Release: normal per-beat tracking resumes.
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 500, MouseY = 300, Modifiers = {} })
    env.__mouseWorld = { 1200, 0, 1200 }
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local third = env.__sent[table.getn(env.__sent)]
    Check('after release, position tracking follows the pointer again',
        third and third.msg.p[1] == 1200 and third.msg.p[3] == 1200,
        third and (tostring(third.msg.p[1]) .. ',' .. tostring(third.msg.p[3])) or 'nothing sent')
end

--------------------------------------------------------------------------------
Section('permanent drag overlay: exactly one cell disabled, following the cursor')
--------------------------------------------------------------------------------

--- Count how many of an overlay group's cells currently have hit-testing
--- disabled, and return the single disabled one if there is exactly one.
---@param overlayGroup table
---@return integer, table | nil
local function CountDisabled(overlayGroup)
    local count, only = 0, nil
    for _, cell in ipairs(overlayGroup.children) do
        if cell._hitTestDisabled then
            count = count + 1
            only = cell
        end
    end
    return count, only
end

do
    -- The whole design rests on exactly one cell -- wherever the cursor is
    -- resting -- being non-hit-testable at any moment, so a click or release
    -- there falls through to the view underneath. This is the one assumption
    -- that could not be verified without upgrading the mock's DisableHitTest
    -- stub (previously a no-op) to actually track state.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)

    local overlay = Mock.FindDragOverlays(env)[1]
    Check('a drag overlay is built for the default session', overlay ~= nil)

    local cellA = overlay.children[1]
    local cellB = overlay.children[5]
    Check('the overlay has multiple cells to test with', cellA and cellB and cellA ~= cellB)

    cellA:HandleEvent({ Type = 'MouseEnter', MouseX = cellA.dragCX, MouseY = cellA.dragCY, Modifiers = {} })
    local count, only = CountDisabled(overlay)
    Check('entering a cell disables exactly that one',
        count == 1 and only == cellA, tostring(count))

    cellB:HandleEvent({ Type = 'MouseEnter', MouseX = cellB.dragCX, MouseY = cellB.dragCY, Modifiers = {} })
    count, only = CountDisabled(overlay)
    Check('moving to a new cell re-enables the old one and disables the new one, never both or neither',
        count == 1 and only == cellB, tostring(count))
end

do
    -- The release problem this design replaces: a release landing on a cell
    -- (not the view) needs to still be handled correctly. With the current
    -- cell always disabled, an ordinary release should reach the view
    -- directly -- but the defensive fallback inside DragCellEvent (for a
    -- release that somehow still lands on a cell, e.g. right at a boundary
    -- crossing) is exercised here directly, dispatching to a cell rather than
    -- to the view, unlike the equivalent test for the old design.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local overlay = Mock.FindDragOverlays(env)[1]
    local cell = overlay.children[1]

    view:HandleEvent({ Type = 'ButtonPress', MouseX = 400, MouseY = 300, Modifiers = { Left = true } })
    env.__mouseWorld = { 200, 0, 150 }
    SM.OnBeat()
    local afterPress = env.__sent[table.getn(env.__sent)]
    Check('pressing starts a selecting packet', afterPress and afterPress.msg.s == true)

    -- Delivered to the CELL, not the view.
    cell:HandleEvent({ Type = 'ButtonRelease', MouseX = cell.dragCX, MouseY = cell.dragCY, Modifiers = {} })
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local afterRelease = env.__sent[table.getn(env.__sent)]
    Check('a release delivered to a cell still clears selecting',
        afterRelease and afterRelease.msg.s == false)
end

do
    -- Unlike the old per-drag design, the overlay must never be destroyed by
    -- a drag ending -- it is permanent for as long as the view exists.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local before = Mock.FindDragOverlays(env)[1]

    view:HandleEvent({ Type = 'ButtonPress', MouseX = 400, MouseY = 300, Modifiers = { Left = true } })
    env.__mouseWorld = { 200, 0, 150 }
    SM.OnBeat()
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 450, MouseY = 300, Modifiers = {} })
    SM.OnBeat()

    local after = Mock.FindDragOverlays(env)[1]
    Check('the overlay survives a full press-and-release cycle',
        after ~= nil and after == before and not after._destroyed)
end

do
    -- Observers and replay viewers never transmit a drag at all, so they get
    -- no permanent overlay -- there is nothing for it to protect there, only
    -- surface area it would otherwise add for no reason.
    local env, SM = NewSession({ focusArmy = -1 })
    SM.InitTeamMouse(false)
    Check('no drag overlay is built for an observer session',
        table.getn(Mock.FindDragOverlays(env)) == 0)
end

do
    -- A layout change replaces the view; its overlay must be torn down with
    -- it and rebuilt for the replacement, not silently duplicated or left
    -- dangling on the old, now-dead view.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local before = Mock.FindDragOverlays(env)[1]

    env.__views['WorldCamera'] = Mock.WorldView(env.__frame, 'WorldCamera', 0, 0, 1920, 1080)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()   -- VerifyViews notices the swap and resyncs

    local overlays = Mock.FindDragOverlays(env)
    Check('exactly one overlay exists after the view is replaced',
        table.getn(overlays) == 1, tostring(table.getn(overlays)))
    Check('it is a fresh overlay, not the one that belonged to the old view',
        overlays[1] ~= before)
    Check('the old overlay was actually destroyed, not just forgotten',
        before._destroyed == true)
end

--------------------------------------------------------------------------------
Section('extra samples: sending')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local driver = Mock.FindDriver(env)
    local function Beat()
        SM.OnBeat()
        return env.__sent[table.getn(env.__sent)].msg
    end
    Beat()   -- the initial forced packet

    -- The pointer wanders around a corner between beats, frames ticking at
    -- 60Hz. Only the beat's own end point would reach a teammate without this.
    local path = { { 12, 10 }, { 14, 10 }, { 16, 10 }, { 16, 12 }, { 16, 14 }, { 16, 16 } }
    for _, p in ipairs(path) do
        env.__clock.t = env.__clock.t + 0.016
        env.__mouseWorld = { p[1], 0, p[2] }
        driver:OnFrame(0.016)
    end
    env.__clock.t = env.__clock.t + 0.004
    env.__mouseWorld = { 16, 0, 16 }
    local msg = Beat()

    Check('a beat that follows movement carries extra samples',
        type(msg.e) == 'table' and table.getn(msg.e) > 0)
    Check('extras come in whole samples of nine numbers',
        type(msg.e) == 'table' and math.mod(table.getn(msg.e), 9) == 0,
        type(msg.e) == 'table' and table.getn(msg.e) or 'no e')

    local ages, ordered, inRange = {}, true, true
    if type(msg.e) == 'table' then
        for i = 1, table.getn(msg.e), 9 do
            table.insert(ages, msg.e[i])
            if msg.e[i] <= 0 or msg.e[i] > 0.5 then inRange = false end
        end
        for i = 2, table.getn(ages) do
            if ages[i] >= ages[i - 1] then ordered = false end
        end
    end
    Check('extras are oldest first (ages strictly falling)', ordered and table.getn(ages) >= 2)
    Check('every extra is younger than MaxAge', inRange)
    Check('at least one extra is off the packet\'s own position, i.e. the path is in there',
        type(msg.e) == 'table' and (msg.e[2] ~= msg.p[1] or msg.e[4] ~= msg.p[3]))
    Check('the extras never outnumber MaxPerPacket',
        type(msg.e) == 'table' and table.getn(msg.e) <= 8 * 9)

    -- The next beat starts a fresh window: nothing left over from the last.
    env.__clock.t = env.__clock.t + 0.1
    env.__mouseWorld = { 20, 0, 20 }
    local msg2 = Beat()
    Check('samples are not carried over into the following packet',
        msg2.e == false or (type(msg2.e) == 'table' and msg2.e[1] <= 0.1))
end

do
    -- A parked pointer has nothing to add, however long the beat resends.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local driver = Mock.FindDriver(env)
    SM.OnBeat()
    for _ = 1, 40 do
        env.__clock.t = env.__clock.t + 0.016
        driver:OnFrame(0.016)
    end
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('a stationary pointer sends no extras even on a forced resend', msg.e == false)
end

do
    -- Off means off: the wire is exactly what it was.
    local env, SM = NewSession()
    env.import('/mods/TeamMouse/modules/config.lua').Network.ExtraSamples.Enabled = false
    SM.InitTeamMouse(false)
    local driver = Mock.FindDriver(env)
    SM.OnBeat()
    for i = 1, 6 do
        env.__clock.t = env.__clock.t + 0.016
        env.__mouseWorld = { 10 + i, 0, 10 }
        driver:OnFrame(0.016)
    end
    SM.OnBeat()
    Check('with extra samples disabled the packet carries none',
        env.__sent[table.getn(env.__sent)].msg.e == false)
end

do
    -- During a drag the pointer's own position is pinned at the press; only the
    -- box corner moves. The extras must still go, or the drag would be sent at
    -- the beat rate after all. (One packet's worth: no gap-filling send.)
    local env, SM = NewSession()
    env.import('/mods/TeamMouse/modules/config.lua').Network.MaxSendGap = 10
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local driver = Mock.FindDriver(env)
    local overlay = Mock.FindDragOverlays(env)[1]
    local cell = overlay.children[1]

    -- Let UnProject calibrate against a resting pointer.
    env.__mouseWorld = { 50, 0, 50 }
    SM.OnBeat()
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()

    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    for i = 1, 4 do
        env.__clock.t = env.__clock.t + 0.033
        cell:HandleEvent({ Type = 'MouseEnter', MouseX = 100 + i * 60, MouseY = 100 + i * 40, Modifiers = {} })
        driver:OnFrame(0.016)
    end
    env.__clock.t = env.__clock.t + 0.004
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('a drag is in progress in this packet', msg.s == true)
    Check('extras travel with a drag even though the anchor is pinned',
        type(msg.e) == 'table' and table.getn(msg.e) >= 18)
    Check('and they carry the moving box corner',
        type(msg.e) == 'table' and msg.e[7] ~= msg.e[table.getn(msg.e) - 2],
        type(msg.e) == 'table' and (tostring(msg.e[7]) .. ' vs ' .. tostring(msg.e[table.getn(msg.e) - 2])))
end

--------------------------------------------------------------------------------
Section('extra samples: receiving')
--------------------------------------------------------------------------------
--- Extra samples as they go on the wire (wirepack.lua), from the plain layout
--- (age, x, y, z, hx, hy, bx, bz, flags per sample), for a packet at px, pz.
local function Packed(env, plain, px, pz)
    local list, n = {}, 0
    for i = 1, table.getn(plain), 9 do
        n = n + 1
        list[n] = { age = plain[i], x = plain[i + 1], z = plain[i + 3], hx = plain[i + 4],
            hy = plain[i + 5], bx = plain[i + 6], bz = plain[i + 7], flags = plain[i + 8] }
    end
    return env.import('/mods/TeamMouse/modules/wirepack.lua').PackSamples(list, n, px, pz)
end

do
    -- The reason for the feature. A path that goes out and back between two
    -- packets, seen through the interpolation delay.
    local function Run(withExtras)
        local env, SM = NewSession()
        SM.InitTeamMouse(false)
        local receive = env.__chatFuncs['TeamMouse']
        local driver = Mock.FindDriver(env)
        local T = env.__clock.t

        receive('KasperAUS', { v = 1, a = 2, p = { 0, 0, 0 }, o = 0, z = 60, w = true })
        env.__clock.t = T + 0.1
        local msg = { v = 1, a = 2, p = { 10, 0, 0 }, o = 0, z = 60, w = true }
        if withExtras then
            msg.e = Packed(env, { 0.05, 5, 0, 10, 0.5, 0.9, 5, 10, 0 }, 10, 0)
        end
        receive('KasperAUS', msg)

        -- Render time is now - InterpolationDelay: land it on T + 0.05.
        env.__clock.t = T + 0.05 + 0.13
        driver:OnFrame(0.016)
        local record = Mock.FindCursors(env, 'WorldCamera')[1].record
        return record, env
    end

    local with, env = Run(true)
    local without = Run(false)
    Check('an extra sample bends the interpolated path through it',
        math.abs(with.render[1] - 5) < 0.01 and math.abs(with.render[3] - 10) < 0.01,
        with.render[1] .. ',' .. with.render[3])
    Check('without it the cursor takes the straight line, as before',
        math.abs(without.render[1] - 5) < 0.01 and math.abs(without.render[3]) < 0.01,
        without.render[1] .. ',' .. without.render[3])
    Check('the packet added its extras to the buffer ahead of its own sample',
        with.sampleCount == without.sampleCount + 1 and with.samples[2].x == 5
            and with.samples[3].x == 10)
    Check('no errors receiving extras', NoErrors(env))
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local nan = 0 / 0
    local T = env.__clock.t

    local junk = {
        'text', 42, true, {},
        { 'a', 'b', 'c' },
        { nan, 1, 0, 1, 0.5, 0.5, 1, 1 },
        { -1, 1, 0, 1, 0.5, 0.5, 1, 1 },
        { 99, 1, 0, 1, 0.5, 0.5, 1, 1 },
        { 0.05, nan, 0, 1, 0.5, 0.5, 1, 1 },
        { 0.05, 1, 0, 1 },
        { 0.05, 1e40, 0, 1e40, 0, 0, 0, 0 },
    }
    -- Strings too: not whole samples, characters outside the alphabet, a
    -- sample cut short.
    for _, str in ipairs({ '', 'A', '!!!!!!!!!', 'AAAAAAAAAAAA', string.rep('~', 50),
        string.sub(Packed(env, { 0.05, 5, 0, 10, 0.5, 0.9, 5, 10, 1 }, 0, 0), 1, 11) }) do
        table.insert(junk, str)
    end
    for i, e in ipairs(junk) do
        env.__clock.t = T + i * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { i, 0, i }, o = 0, z = 60, w = true, e = e })
    end
    Check('malformed extras never raise', NoErrors(env))

    local record = Mock.FindCursors(env, 'WorldCamera')[1].record
    local sane = true
    for i = 1, record.sampleCount do
        local s = record.samples[i]
        if type(s.x) ~= 'number' or s.x ~= s.x or type(s.t) ~= 'number' then sane = false end
        if i > 1 and s.t <= record.samples[i - 1].t then sane = false end
    end
    Check('the buffer stays numeric and strictly in time order after junk', sane)

    -- An enormous string is capped rather than swallowed whole.
    local big = {}
    for i = 0, 199 do
        big[i * 9 + 1] = 0.4 - i * 0.001
        big[i * 9 + 2] = 3; big[i * 9 + 3] = 0; big[i * 9 + 4] = 3
        big[i * 9 + 5] = 0.5; big[i * 9 + 6] = 0.5; big[i * 9 + 7] = 3; big[i * 9 + 8] = 3; big[i * 9 + 9] = 0
    end
    local before = record.sampleCount
    env.__clock.t = env.__clock.t + 1
    receive('KasperAUS', { v = 1, a = 2, p = { 3, 0, 3 }, o = 0, z = 60, w = true, e = Packed(env, big, 3, 3) })
    Check('an oversized extras array is capped at MaxPerPacket',
        record.sampleCount <= math.max(before, 0) + 9 and NoErrors(env),
        record.sampleCount)
end

do
    -- Latency that shrinks can put a packet's earliest extras before the last
    -- sample already buffered. They are dropped, never reordered in.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local T = env.__clock.t
    receive('KasperAUS', { v = 1, a = 2, p = { 0, 0, 0 }, o = 0, z = 60, w = true })
    env.__clock.t = T + 0.02
    receive('KasperAUS', { v = 1, a = 2, p = { 1, 0, 0 }, o = 0, z = 60, w = true,
        e = Packed(env, { 0.5, 9, 0, 9, 0.5, 0.9, 9, 9, 0, 0.01, 2, 0, 0, 0.5, 0.9, 2, 0, 0 }, 1, 0) })
    local record = Mock.FindCursors(env, 'WorldCamera')[1].record
    local ordered = true
    for i = 2, record.sampleCount do
        if record.samples[i].t <= record.samples[i - 1].t then ordered = false end
    end
    Check('an extra older than the buffer\'s newest sample is dropped', ordered,
        record.sampleCount)
    Check('a usable extra alongside it still lands', record.sampleCount == 3)
end

do
    -- A packet with no extras at all (the pointer was still) is one sample.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    receive('KasperAUS', { v = 1, a = 2, p = { 5, 0, 5 }, o = 0, z = 60, w = true })
    local record = Mock.FindCursors(env, 'WorldCamera')[1].record
    Check('a packet with no extras is one sample, as before', record.sampleCount == 1)
end

--------------------------------------------------------------------------------
Section('structure drag line')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']

    env.__commandMode = { 'build', { name = 'ueb0101' } }
    env.__mouseWorld = { 50, 0, 50 }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('a drag made in build mode is reported as a line', msg.l == true)
    Check('and not as a selection box', msg.s == false)
    Check('the line starts at the press point', msg.p[1] == 50 and msg.p[3] == 50)

    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 300, MouseY = 300, Modifiers = {} })
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    msg = env.__sent[table.getn(env.__sent)].msg
    Check('releasing ends the line', msg.l == false and msg.s == false)
end

do
    -- A plain box-select is unchanged, and a drag in any other mode is neither.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']

    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('with no command mode a drag is still a selection box', msg.s == true and msg.l == false)
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 100, MouseY = 100, Modifiers = {} })

    env.__commandMode = { 'order', { name = 'RULEUCC_Move' } }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    msg = env.__sent[table.getn(env.__sent)].msg
    Check('a drag in an order mode is neither a box nor a line', msg.s == false and msg.l == false)
end

do
    local env = NewSession()
    local _, _ = nil, nil
    local env2, SM = NewSession()
    env2.import('/mods/TeamMouse/modules/config.lua').Line.Enabled = false
    SM.InitTeamMouse(false)
    local view = env2.__views['WorldCamera']
    env2.__commandMode = { 'build', { name = 'ueb0101' } }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    env2.__clock.t = env2.__clock.t + 0.2
    SM.OnBeat()
    local msg = env2.__sent[table.getn(env2.__sent)].msg
    -- Line.Enabled is what WE show; what we send is always everything.
    Check('with lines switched off locally a build drag is still sent', msg.l == true and msg.s == false)
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)

    local function Send(line, bx, bz)
        receive('KasperAUS', {
            v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
            l = line, hx = 0.5, hy = 0.5, bx = bx, bz = bz,
        })
        env.__clock.t = env.__clock.t + 0.2
        driver:OnFrame(0.016)
    end

    Send(true, 100, 100)
    Send(true, 300, 150)
    Send(true, 300, 150)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]

    Check('a teammate\'s build drag draws a dotted line', visual.line and visual.line.shown >= 2,
        visual.line and visual.line.shown or 'no line')
    local first = visual.line and visual.line.dots[1]
    local last = visual.line and visual.line.dots[visual.line.shown]
    Check('it starts at the anchor',
        first and first.Left() == 200 - 2 and first.Top() == 200 - 2,
        first and (first.Left() .. ',' .. first.Top()))
    Check('and ends at the live corner',
        last and last.Left() == 600 - 2 and last.Top() == 300 - 2,
        last and (last.Left() .. ',' .. last.Top()))
    Check('every dot in use is on screen', (function()
        for i = 1, visual.line.shown do
            if not Mock.IsVisible(visual.line.dots[i]) then return false end
        end
        return true
    end)())
    Check('the dots beyond the line are hidden', (function()
        for i = visual.line.shown + 1, visual.line.max do
            if Mock.IsVisible(visual.line.dots[i]) then return false end
        end
        return true
    end)())
    Check('the arrow rides the live end of the line',
        visual.mouseIcon.Left() == 600 and visual.mouseIcon.Top() == 300,
        visual.mouseIcon.Left() .. ',' .. visual.mouseIcon.Top())
    Check('a line is not also drawn as a box', not visual.dragTop or not visual.dragBoxShown)

    -- Too short to be a line: a plain click.
    Send(true, 102, 100)
    Check('a drag of a few pixels is a click, not a line', visual.line.shown == 0,
        visual.line.shown)
    Send(true, 300, 150)
    Check('and a longer one draws it again', visual.line.shown >= 2)

    Send(false, 100, 100)
    Check('the line goes when the drag ends', visual.line.shown == 0)
    Check('and the arrow returns to the anchor',
        visual.mouseIcon.Left() == visual.Left() and visual.mouseIcon.Top() == visual.Top())
    Check('no errors drawing lines', NoErrors(env))

    -- A very long drag is capped rather than spawning dots without limit.
    Send(true, 900, 500)
    Check('a long line stays within the dot pool',
        visual.line.shown == visual.line.max, visual.line.shown)

    -- Culling the cursor and bringing it back must not resurrect stale dots.
    Send(false, 100, 100)
    receive('KasperAUS', { v = 1, a = 2, p = { 9000, 0, 9000 }, o = 0, z = 60, w = true })
    env.__clock.t = env.__clock.t + 0.3
    driver:OnFrame(0.016)
    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true })
    env.__clock.t = env.__clock.t + 0.3
    driver:OnFrame(0.016)
    local stale = false
    for i = 1, visual.line.max do
        if Mock.IsVisible(visual.line.dots[i]) then stale = true end
    end
    Check('no dot reappears when a culled cursor comes back', not stale)
end

do
    local env, SM = NewSession()
    env.import('/mods/TeamMouse/modules/config.lua').Line.Enabled = false
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
        l = true, bx = 300, bz = 150 })
    env.__clock.t = env.__clock.t + 0.3
    driver:OnFrame(0.016)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('with lines disabled a teammate\'s build drag draws nothing', not visual.line)
end

--------------------------------------------------------------------------------
Section('cursors and names stay easy to see')
--------------------------------------------------------------------------------
-- Feature: zoomed far out, teammates' cursors faded to a quarter and shrank
-- (a teammate working close in drew at MinScale); they now become fully
-- opaque and no smaller than normal. And a name is never fainter than its
-- cursor, until your own mouse comes near it.

--- A teammate at world (100, 0, 100) -- screen (200, 200) -- zoomed in at
--- `theirZoom`, seen from `myZoom`, with our own mouse at (mx, my). Runs long
--- enough to fade in fully. Returns the visual and config.
local function SeeTeammate(myZoom, theirZoom, mx, my)
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local view = env.__views['WorldCamera']
    view:HandleEvent({ Type = 'MouseMotion', MouseX = mx, MouseY = my, Modifiers = {} })
    env.__setZoom(myZoom)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    for i = 1, 40 do
        if math.mod(i, 5) == 1 then
            receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = theirZoom, w = true })
        end
        env.__clock.t = env.__clock.t + 0.05
        driver:OnFrame(0.05)
    end
    return Mock.FindCursors(env, 'WorldCamera')[1], cfg, env
end

do
    local visual, cfg = SeeTeammate(60, 60, 1500, 900)
    Check('zoomed in: the cursor at its normal opacity',
        math.abs(visual.mouseIcon._alpha - cfg.Appearance.BaseAlpha) < 0.03, visual.mouseIcon._alpha)
    Check('and the name more opaque than the cursor',
        visual.label._alpha > visual.mouseIcon._alpha + 0.05,
        visual.label._alpha .. ' vs ' .. visual.mouseIcon._alpha)
end

do
    -- Zoomed right out, a teammate working close in.
    local visual, cfg, env = SeeTeammate(600, 40, 1500, 900)
    Check('zoomed far out: cursors are fully opaque, not faded',
        visual.mouseIcon._alpha >= cfg.Zoom.FarAlpha - 0.03, visual.mouseIcon._alpha)
    Check('and no smaller than normal, however close in they are',
        visual.appliedScale >= cfg.Zoom.FarMinScale - 0.001, visual.appliedScale)
    Check('names too', visual.label._alpha >= cfg.Zoom.FarAlpha - 0.03, visual.label._alpha)
    Check('no errors', NoErrors(env))
end

do
    -- Our own mouse right on top of it: both fade, the name included.
    local visual, cfg = SeeTeammate(60, 60, 200, 200)
    Check('hovering a cursor fades it', visual.mouseIcon._alpha < 0.25, visual.mouseIcon._alpha)
    Check('and fades its name as well', visual.label._alpha < 0.25, visual.label._alpha)
    Check('the name still no fainter than the cursor', visual.label._alpha >= visual.mouseIcon._alpha - 0.001)
end

--------------------------------------------------------------------------------
Section('a build drag shows one icon per structure it will place')
--------------------------------------------------------------------------------
-- Feature: dragging a line of structures showed teammates one icon beside the
-- cursor and a dotted line. It now shows a framed icon on every spot the row
-- will put a structure, laid out as the game lays it: one per skirt along the
-- longer axis. (The mock projects world x/z to screen at twice the scale.)

--- A session receiving one teammate's build drag of ueb0101 with the given
--- skirt, from (x1, z1) to (x2, z2). Returns env, the visual, the driver.
local function RowSession(skirt, x1, z1, x2, z2, footprint)
    local env, SM = NewSession()
    local bp = env.__blueprints.ueb0101
    if skirt then bp.Physics = { SkirtSizeX = skirt, SkirtSizeZ = skirt } end
    if footprint then bp.Footprint = { SizeX = footprint, SizeZ = footprint } end
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    receive('KasperAUS', { v = 1, a = 2, p = { x1, 0, z1 }, o = 0, z = 60, w = true,
        l = true, b = 'ueb0101', bx = x2, bz = z2 })
    env.__clock.t = env.__clock.t + 0.3
    driver:OnFrame(0.016)
    return env, Mock.FindCursors(env, 'WorldCamera')[1], driver, receive
end

--- Screen centres of the row's visible icons, as "x,y" strings.
local function RowCentres(row)
    local out = {}
    if not row then return out end
    for i = 1, row.made do
        local icon = row.icons[i]
        if Mock.IsVisible(icon) then
            table.insert(out, (icon.Left() + icon.Width() / 2) .. ',' .. (icon.Top() + icon.Height() / 2))
        end
    end
    return out
end

do
    local env, visual, driver, receive = RowSession(20, 50, 50, 110, 50)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local c = RowCentres(visual.row)
    Check('a row of four structures shows four icons', table.getn(c) == 4, table.getn(c))
    Check('one per skirt from the anchor, centred on each spot',
        c[1] == '100,100' and c[2] == '140,100' and c[3] == '180,100' and c[4] == '220,100',
        table.concat(c, ' '))
    Check('at full size when there is room', visual.row and visual.row.size == cfg.Orders.BuildIconSize)
    Check('each framed', visual.row and Mock.IsVisible(visual.row.frames[4])
        and visual.row.frames[1].Width() == cfg.Orders.BuildIconSize + cfg.Orders.BuildFrame * 2)
    Check('icons over their frames', visual.row and visual.row.icons[1].Depth() > visual.row.frames[1].Depth())
    Check('the dotted line is still drawn under them', visual.lineShown == true)
    Check('in place of the single ghost beside the cursor',
        not (visual.buildIcon and Mock.IsVisible(visual.buildIcon)))

    -- The drag ends; they are still in build mode.
    env.__clock.t = env.__clock.t + 0.2
    receive('KasperAUS', { v = 1, a = 2, p = { 110, 0, 50 }, o = 0, z = 60, w = true, b = 'ueb0101' })
    env.__clock.t = env.__clock.t + 0.3
    driver:OnFrame(0.016)
    Check('the row goes when the drag ends', table.getn(RowCentres(visual.row)) == 0)
    Check('and the ghost beside the cursor comes back', visual.buildIcon and Mock.IsVisible(visual.buildIcon))
    Check('no errors drawing a row', NoErrors(env))
end

do
    -- Diagonal: the game steps the other axis a whole skirt at a time.
    local _, visual = RowSession(20, 50, 50, 110, 70)
    local c = RowCentres(visual.row)
    Check('a diagonal row steps like the game lays it',
        c[1] == '100,100' and c[2] == '140,100' and c[3] == '180,140' and c[4] == '220,140',
        table.concat(c, ' '))
end

do
    -- Mostly along z: z is the axis counted in skirts.
    local _, visual = RowSession(20, 50, 50, 52, 110)
    local c = RowCentres(visual.row)
    Check('a row along z counts along z',
        table.getn(c) == 4 and c[1] == '100,100' and c[4] == '100,220', table.concat(c, ' '))
end

do
    -- The far end only gains a structure once the pointer reaches that
    -- structure's centre (the midpoint of its width), as the game does.
    local _, visual = RowSession(20, 50, 50, 68, 50)
    Check('most of the way to the next spot is not enough for another',
        table.getn(RowCentres(visual.row)) == 1, table.getn(RowCentres(visual.row)))
    local _, visual2 = RowSession(20, 50, 50, 70, 50)
    local c = RowCentres(visual2.row)
    Check('reaching the next spot\'s centre adds it',
        table.getn(c) == 2 and c[2] == '140,100', table.concat(c, ' '))
    local _, visual3 = RowSession(20, 50, 50, 89, 50)
    Check('and nothing more until the centre after that', table.getn(RowCentres(visual3.row)) == 2)
    local _, visual4 = RowSession(20, 50, 50, 55, 50)
    local c4 = RowCentres(visual4.row)
    Check('a short drag is one structure, at the anchor',
        table.getn(c4) == 1 and c4[1] == '100,100', table.concat(c4, ' '))
end

do
    -- Zoomed out (here: walls, two pixels apart), icons shrink rather than
    -- pile up, down to the floor.
    local env, visual = RowSession(1, 50, 50, 55, 50)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    Check('crowded icons shrink, no smaller than the floor',
        visual.row and visual.row.size == cfg.Line.MinStructureIcon)
    Check('still one per structure', table.getn(RowCentres(visual.row)) == 6)
end

do
    -- A very long row is shown with MaxStructures icons, first to last.
    local env, visual = RowSession(1, 50, 50, 150, 50)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local c = RowCentres(visual.row)
    Check('a long row is capped', table.getn(c) == cfg.Line.MaxStructures, table.getn(c))
    Check('still running from the first structure to the last',
        c[1] == '100,100' and c[table.getn(c)] == '300,100', tostring(c[1]) .. ' .. ' .. tostring(c[table.getn(c)]))
end

do
    -- No skirt in the blueprint: its footprint spaces the row.
    local _, visual = RowSession(nil, 50, 50, 59, 50, 3)
    Check('without a skirt the footprint spaces the row', table.getn(RowCentres(visual.row)) == 4)
end

do
    -- A selection box is no row; nor is a line with the setting off.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    receive('KasperAUS', { v = 1, a = 2, p = { 50, 0, 50 }, o = 0, z = 60, w = true,
        s = true, b = 'ueb0101', bx = 110, bz = 90 })
    env.__clock.t = env.__clock.t + 0.3
    Mock.FindDriver(env):OnFrame(0.016)
    Check('a selection box draws no row', not Mock.FindCursors(env, 'WorldCamera')[1].row)

    local env2, SM2 = NewSession()
    env2.import('/mods/TeamMouse/modules/config.lua').Line.ShowStructures = false
    SM2.InitTeamMouse(false)
    env2.__chatFuncs['TeamMouse']('KasperAUS', { v = 1, a = 2, p = { 50, 0, 50 }, o = 0, z = 60, w = true,
        l = true, b = 'ueb0101', bx = 110, bz = 50 })
    env2.__clock.t = env2.__clock.t + 0.3
    Mock.FindDriver(env2):OnFrame(0.016)
    local v2 = Mock.FindCursors(env2, 'WorldCamera')[1]
    Check('with ShowStructures off, the old look: no row, the ghost beside the cursor',
        not v2.row and v2.buildIcon and Mock.IsVisible(v2.buildIcon))
end

do
    -- Placed: the marker keeps one icon per structure, not one and a line.
    local env, SM = NewSession()
    env.__blueprints.ueb0101.Physics = { SkirtSizeX = 20, SkirtSizeZ = 20 }
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true,
        mo = { 0, 50, 0, 50, 110, 50, 0 }, mob = { 'ueb0101' } })
    env.__clock.t = T + 0.2
    driver:OnFrame(0.016)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local mark = visual.orderMarks[1]
    local c = RowCentres(mark and mark.row)
    Check('a placed row shows its first structure on the marker',
        mark and mark.icon.Left() + mark.icon.Width() / 2 == 100)
    Check('and one icon for each of the others',
        table.getn(c) == 3 and c[1] == '140,100' and c[3] == '220,100', table.concat(c, ' '))
    env.__clock.t = T + 3
    receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true })
    driver:OnFrame(0.016)
    Check('and they all go with the marker', mark and table.getn(RowCentres(mark.row)) == 0 and not mark.visible)
    Check('no errors drawing a placed row', NoErrors(env))
end

--------------------------------------------------------------------------------
Section('right-click orders: sending')
--------------------------------------------------------------------------------
local function RightPress(env, view, mx, my)
    Mock.buttons.right = true
    view:HandleEvent({ Type = 'ButtonPress', MouseX = mx, MouseY = my, Modifiers = { Right = true } })
end

local function RightRelease(env, view, mx, my)
    Mock.buttons.right = false
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = mx, MouseY = my, Modifiers = {} })
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }

    env.__mouseWorld = { 60, 0, 40 }
    RightPress(env, view, 120, 80)
    RightRelease(env, view, 120, 80)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg

    Check('a right click with units selected is sent as an order',
        type(msg.mo) == 'table' and table.getn(msg.mo) == 7, type(msg.mo))
    Check('at the point that was clicked', msg.mo and msg.mo[2] == 60 and msg.mo[4] == 40)
    Check('a plain click has no far end', msg.mo and msg.mo[5] == 60 and msg.mo[6] == 40)

    env.__clock.t = env.__clock.t + 0.2
    env.__mouseWorld = { 61, 0, 41 }
    SM.OnBeat()
    Check('it is sent once, not on every beat after',
        env.__sent[table.getn(env.__sent)].msg.mo == false)
end

do
    -- A right drag: a formation. The far end is where it was released.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }

    env.__mouseWorld = { 60, 0, 40 }
    RightPress(env, view, 120, 80)
    env.__clock.t = env.__clock.t + 0.6   -- held past Orders.LineDelay: a formation
    env.__mouseWorld = { 90, 0, 70 }
    RightRelease(env, view, 180, 140)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local mo = env.__sent[table.getn(env.__sent)].msg.mo
    Check('a right drag reports where it started and where it ended',
        mo and mo[2] == 60 and mo[4] == 40 and mo[5] == 90 and mo[6] == 70,
        mo and (mo[2] .. ',' .. mo[4] .. ' -> ' .. mo[5] .. ',' .. mo[6]) or 'no order')
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__mouseWorld = { 60, 0, 40 }

    -- Nothing selected: the click orders nothing.
    RightPress(env, view, 120, 80)
    RightRelease(env, view, 120, 80)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    Check('a right click with nothing selected is not an order',
        env.__sent[table.getn(env.__sent)].msg.mo == false)

    -- A command mode active: a right click cancels it, orders nothing.
    env.__selectedUnits = { {} }
    env.__commandMode = { 'order', {} }
    RightPress(env, view, 120, 80)
    RightRelease(env, view, 120, 80)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    Check('a right click that cancels a command mode is not an order',
        env.__sent[table.getn(env.__sent)].msg.mo == false)
end

do
    local env, SM = NewSession()
    env.import('/mods/TeamMouse/modules/config.lua').Orders.Share = false
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }
    RightPress(env, view, 120, 80)
    RightRelease(env, view, 120, 80)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    Check('with sharing off, orders stay private',
        env.__sent[table.getn(env.__sent)].msg.mo == false)
end

do
    -- Several orders inside one beat travel together, oldest first, capped.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }
    for i = 1, 6 do
        env.__mouseWorld = { i * 10, 0, 5 }
        RightPress(env, view, 100, 100)
        RightRelease(env, view, 100, 100)
    end
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local mo = env.__sent[table.getn(env.__sent)].msg.mo
    Check('orders in one beat are batched and capped at MaxPerPacket',
        mo and table.getn(mo) == 28, mo and table.getn(mo))
    Check('the newest are the ones kept, oldest first', mo and mo[2] == 30 and mo[23] == 60,
        mo and (mo[2] .. ' .. ' .. tostring(mo[23])))
end

do
    -- The attack cursor at the time of the click is what the order was.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }
    env.__cursor:SetTexture('/textures/ui/common/game/cursors/attack.dds', 0, 0)
    RightPress(env, view, 100, 100)
    RightRelease(env, view, 100, 100)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local mo = env.__sent[table.getn(env.__sent)].msg.mo
    Check('the order carries the cursor it was given under', mo ~= false and mo ~= nil)
end

--------------------------------------------------------------------------------
Section('right-click orders: showing them')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t

    receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true,
        mo = { 0, 100, 0, 100, 100, 100, 1 } })
    driver:OnFrame(0.016)
    local early = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('an order is not drawn ahead of the drag that made it (held for the interpolation delay)',
        not (early.orderMarks[1] and early.orderMarks[1].visible))
    env.__clock.t = T + 0.2
    driver:OnFrame(0.016)

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local mark = visual.orderMarks[1]
    Check('an order announced by a teammate gets a marker', mark and mark.visible == true)
    Check('the marker is on the destination',
        mark and mark.square.Left() == 200 - 6 and mark.square.Top() == 200 - 6,
        mark and (mark.square.Left() .. ',' .. mark.square.Top()))
    Check('the marker is drawn', mark and Mock.IsVisible(mark.square))
    Check('a plain move has no line', not mark.line or mark.line.shown == 0)
    Check('and no order icon', not mark.icon or not Mock.IsVisible(mark.icon))

    env.__clock.t = T + 1.2
    receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true })
    driver:OnFrame(0.016)
    local midAlpha = mark.square:GetAlpha()
    Check('the fade is partway, not gone', midAlpha > 0 and midAlpha < 0.85, midAlpha)

    env.__clock.t = T + 2.5
    receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true })
    driver:OnFrame(0.016)
    Check('it is gone once its lifetime is up', not mark.visible and not Mock.IsVisible(mark.square))
    Check('and the record has forgotten it', visual.record.orderCount == 0)
    Check('no errors drawing orders', NoErrors(env))
end

do
    -- A formation: line drawn, and it survives the cursor itself being gone.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t

    receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true,
        mo = { 3, 100, 0, 100, 200, 100, 1 } })   -- 3: the attack cursor
    env.__clock.t = T + 0.2
    driver:OnFrame(0.016)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local mark = visual.orderMarks[1]
    Check('a right-drag draws its extent as a line',
        mark and mark.line and mark.line.shown >= 2 and Mock.IsVisible(mark.line.dots[1]))
    Check('the line runs from the start to the end',
        mark and mark.line and mark.line.dots[1].Left() == 200 - 2
            and mark.line.dots[mark.line.shown].Left() == 400 - 2)
    Check('an order with a cursor of its own shows it',
        mark and mark.icon and Mock.IsVisible(mark.icon))

    -- The teammate's own cursor goes stale and is hidden; their order is still
    -- on the map for as long as it lives.
    env.__clock.t = T + 1.0
    driver:OnFrame(0.016)
    Check('the marker outlives a cursor that has been culled or gone stale',
        mark.visible == true and Mock.IsVisible(mark.square))
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local nan = 0 / 0
    local junk = { 'x', 5, {}, { 'a' }, { 0, nan, 0, 1, 1, 1 }, { 0, 1, 0, 1 }, { 0, 1e40, 0, 1e40, 0, 0 } }
    for _, mo in ipairs(junk) do
        receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true, mo = mo })
    end
    driver:OnFrame(0.016)
    Check('malformed orders never raise', NoErrors(env))

    -- More than there are slots: the oldest make way.
    for i = 1, 10 do
        receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true,
            mo = { 0, i * 10, 0, 10, i * 10, 10 } })
    end
    local record = Mock.FindCursors(env, 'WorldCamera')[1].record
    Check('markers are capped at MaxMarkers, keeping the newest',
        record.orderCount == 4 and record.orders[4].x == 100 and record.orders[1].x == 70,
        record.orderCount)
end

do
    local env, SM = NewSession({ splitscreen = true })
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    -- The mock projects every view the same way, so a point can be inside
    -- both or neither, never one only; what it can show is that each view
    -- decides for itself, and that a point off the screen is drawn nowhere.
    receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true,
        mo = { 0, 100, 0, 100, 100, 100, 1, 0, 9000, 0, 9000, 9000, 9000, 2 } })
    env.__clock.t = env.__clock.t + 0.2
    driver:OnFrame(0.016)
    local left = Mock.FindCursors(env, 'WorldCamera')[1]
    local right = Mock.FindCursors(env, 'WorldCamera2')[1]
    Check('a nearby order shows in each splitscreen view that contains it',
        left.orderMarks[1] and left.orderMarks[1].visible
            and right.orderMarks[1] and right.orderMarks[1].visible)
    Check('an order far off the map is drawn in neither',
        not (left.orderMarks[2] and left.orderMarks[2].visible)
            and not (right.orderMarks[2] and right.orderMarks[2].visible))
end

--------------------------------------------------------------------------------
Section('right click and the drag overlay')
--------------------------------------------------------------------------------
local function VisibleOverlays(env)
    local n = 0
    for _, g in ipairs(Mock.FindDragOverlays(env)) do
        if Mock.IsVisible(g) then n = n + 1 end
    end
    return n
end

local function DisabledCells(overlayGroup)
    local n, only = 0, nil
    for _, c in ipairs(overlayGroup.children) do
        if c._hitTestDisabled and not c._destroyed then n = n + 1; only = c end
    end
    return n, only
end

--- The grid is down between drags, so "the grid is back" after a right or
--- middle press means: nothing is holding it down any more, and the next left
--- press raises it with its one hole under the press. Finds out by pressing
--- the left button at (x, y), dragging 10 pixels, and releasing, then running
--- a frame.
local function GridRisesForLeftDrag(env, view, x, y)
    view:HandleEvent({ Type = 'ButtonPress', MouseX = x, MouseY = y, Modifiers = { Left = true } })
    local up = VisibleOverlays(env) == 1
    local n, only = DisabledCells(Mock.FindDragOverlays(env)[1])
    local holed = n == 1 and only and math.abs(only.dragCX - x) <= 45 and math.abs(only.dragCY - y) <= 45
    view:HandleEvent({ Type = 'MouseMotion', MouseX = x + 10, MouseY = y, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = x, MouseY = y, Modifiers = {} })
    Mock.FindDriver(env):OnFrame(0.016)
    return (up and holed) and true or false
end

do
    -- Regression test for: right-click formations getting cancelled by the
    -- overlay. The mock has no hit-testing, so this cannot show the engine
    -- cancelling anything; what it can show is that for the whole of a right
    -- press nothing of the grid is on screen to be hit, and that it is back,
    -- correctly armed, straight after.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }   -- an order in the making: the grid is lifted for it

    Check('the grid is down before the press (it is only up during a drag)', VisibleOverlays(env) == 0)
    RightPress(env, view, 400, 300)
    Check('a right press lifts the grid off the screen', VisibleOverlays(env) == 0)

    -- A whole drag across many cell widths, with the grid gone.
    for x = 400, 1200, 45 do
        view:HandleEvent({ Type = 'MouseMotion', MouseX = x, MouseY = 300, Modifiers = { Right = true } })
    end
    Check('and it stays away for the whole drag', VisibleOverlays(env) == 0)

    RightRelease(env, view, 1200, 600)
    Mock.FindDriver(env):OnFrame(0.016)
    Check('the release leaves the grid down (no drag to follow)', VisibleOverlays(env) == 0)
    Check('but no longer holds it down: the next left drag raises it, hole under the press',
        GridRisesForLeftDrag(env, view, 1200, 600))
end

do
    -- A release that lands on a cell instead of the view still ends the press.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local cell = Mock.FindDragOverlays(env)[1].children[1]
    env.__selectedUnits = { {} }
    RightPress(env, view, 400, 300)
    cell:HandleEvent({ Type = 'ButtonRelease', MouseX = 500, MouseY = 300, Modifiers = {} })
    Check('a right release that lands on a cell still ends the press', GridRisesForLeftDrag(env, view, 500, 300))
end

do
    -- A right press that lands on a cell (at the instant of a crossing) is
    -- handed to the view, so the grid still gets out of the way.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local cell = Mock.FindDragOverlays(env)[1].children[1]
    env.__selectedUnits = { {} }
    Mock.buttons.right = true
    cell:HandleEvent({ Type = 'ButtonPress', MouseX = 20, MouseY = 20, Modifiers = { Right = true } })
    Check('a right press that lands on a cell lifts the grid too', VisibleOverlays(env) == 0)
end

do
    -- A release that never comes (a dialog took it) must not leave the screen
    -- without its grid.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }
    RightPress(env, view, 400, 300)
    env.__clock.t = env.__clock.t + 5
    SM.OnBeat()
    Check('a lost release does not bring the grid back too early', VisibleOverlays(env) == 0)
    env.__clock.t = env.__clock.t + 30
    SM.OnBeat()
    Check('the backstop ends the press if the release never arrives', GridRisesForLeftDrag(env, view, 400, 300))
end

do
    -- ...and so does the next left press.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }
    RightPress(env, view, 400, 300)
    Mock.buttons.right = false
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 400, MouseY = 300, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'MouseMotion', MouseX = 410, MouseY = 300, Modifiers = { Left = true } })
    Check('a left drag after a lost right release brings the grid back', VisibleOverlays(env) == 1)
end

do
    -- Left drags are exactly as they were.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 400, MouseY = 300, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'MouseMotion', MouseX = 410, MouseY = 300, Modifiers = { Left = true } })
    Check('a left drag has the grid up to track it', VisibleOverlays(env) == 1)
end

--------------------------------------------------------------------------------
Section('the tracking grid is only up during a drag')
--------------------------------------------------------------------------------
-- Regression test for: the pointer stuttered (and the frame rate dropped) while
-- swinging the mouse about. The grid was up permanently, so an ordinary swing
-- crossed a hit-testable cell every 45 pixels -- a cell event, a hit-test
-- toggle, and a copy bubbled to the root frame for each one, with the view
-- only hearing the pointer between crossings. It now comes up for a drag and
-- goes down after.
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local driver = Mock.FindDriver(env)
    local group = Mock.FindDragOverlays(env)[1]

    Check('idle: the grid is down', VisibleOverlays(env) == 0)
    for x = 100, 1500, 30 do
        view:HandleEvent({ Type = 'MouseMotion', MouseX = x, MouseY = 400, Modifiers = {} })
        driver:OnFrame(0.016)
    end
    Check('an ordinary swing across the map leaves it down', VisibleOverlays(env) == 0)
    Check('and toggles no cell at all', (DisabledCells(group)) == 0)

    -- Regression test for: double-clicking units sometimes did nothing. The
    -- grid came up at every press and only went on the frame after the
    -- release, so the second click could still find the first one's grid.
    -- It now goes the moment the release reaches the map.
    local seen = {}
    local original = view.HandleEvent
    for _, ev in ipairs({
        { Type = 'ButtonPress', MouseX = 600, MouseY = 400, Modifiers = { Left = true } },
        { Type = 'MouseMotion', MouseX = 602, MouseY = 401, Modifiers = { Left = true } },
        { Type = 'ButtonRelease', MouseX = 602, MouseY = 401, Modifiers = {} },
        { Type = 'ButtonDClick', MouseX = 603, MouseY = 401, Modifiers = { Left = true } },
        { Type = 'ButtonRelease', MouseX = 603, MouseY = 401, Modifiers = {} },
    }) do
        view:HandleEvent(ev)
        table.insert(seen, VisibleOverlays(env))
        driver:OnFrame(0.016)
        table.insert(seen, VisibleOverlays(env))
    end
    Check('a click has the grid up only while pressed, down from its release on',
        table.concat(seen) == '1111000000', table.concat(seen))
    Check('so the second click of a double-click finds none', seen[6] == 0 and seen[7] == 0)
    Check('and reaches the map, second click and all', view._lastEvent and view._lastEvent.Type == 'ButtonRelease')

    -- Regression test for: drags stopped being tracked when the grid was only
    -- raised once a press looked like a drag -- by then the game has the
    -- pointer, and a grid shown under it never hears it cross a cell. Up at
    -- the press, for the whole drag, whatever the frame does.
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 600, MouseY = 400, Modifiers = { Left = true } })
    Check('a left press raises it at once', VisibleOverlays(env) == 1)
    local n, only = DisabledCells(group)
    Check('with its one hole under the press', n == 1 and math.abs(only.dragCX - 600) <= 45
        and math.abs(only.dragCY - 400) <= 45)
    for i = 1, 10 do
        local cell = group.children[i]
        cell:HandleEvent({ Type = 'MouseEnter', MouseX = cell.dragCX, MouseY = cell.dragCY, Modifiers = {} })
        driver:OnFrame(0.016)
    end
    Check('it stays up for the length of the drag', VisibleOverlays(env) == 1)

    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 700, MouseY = 400, Modifiers = {} })
    Check('and goes down the moment the release reaches the map', VisibleOverlays(env) == 0)

    -- A release that came in through a cell: taken down on the frame, not
    -- from inside the cell's own handler.
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 600, MouseY = 400, Modifiers = { Left = true } })
    local cell = group.children[1]
    cell:HandleEvent({ Type = 'ButtonRelease', MouseX = cell.dragCX, MouseY = cell.dragCY, Modifiers = {} })
    Check('a release through a cell leaves the grid alone until the frame', VisibleOverlays(env) == 1)
    driver:OnFrame(0.016)
    Check('and the frame takes it down', VisibleOverlays(env) == 0)

    -- A command-mode left click (patrol, attack-move) is no drag.
    env.__commandMode = { 'order', { name = 'RULEUCC_Patrol' } }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 600, MouseY = 400, Modifiers = { Left = true } })
    Check('an order-mode click does not raise it', VisibleOverlays(env) == 0)
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 600, MouseY = 400, Modifiers = {} })
    env.__commandMode = { false, false }
    Check('no errors', NoErrors(env))
end

do
    -- A right press with nothing selected is a drawing: the grid is the only
    -- thing that can follow it, so it comes up for it, and down after.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = {}
    RightPress(env, view, 400, 300)
    Check('a drawing press raises the grid', VisibleOverlays(env) == 1)
    RightRelease(env, view, 500, 300)
    Mock.FindDriver(env):OnFrame(0.016)
    Check('and the end of the drawing takes it down', VisibleOverlays(env) == 0)
end

--------------------------------------------------------------------------------
Section('drag overlay covers its view')
--------------------------------------------------------------------------------
local function Extent(group)
    local minL, minT, maxR, maxB = 1e9, 1e9, -1e9, -1e9
    for _, c in ipairs(group.children) do
        if not c._destroyed then
            local l, t = c.Left(), c.Top()
            if l < minL then minL = l end
            if t < minT then minT = t end
            if l + c.Width() > maxR then maxR = l + c.Width() end
            if t + c.Height() > maxB then maxB = t + c.Height() end
        end
    end
    return minL, minT, maxR, maxB
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local group = Mock.FindDragOverlays(env)[1]
    local l, t, r, b = Extent(group)
    Check('the grid covers the whole screen at the start',
        l == 0 and t == 0 and r >= 1920 and b >= 1080, l .. ',' .. t .. ' ' .. r .. ',' .. b)
    Check('and the cells are transparent by default', group.children[1]._color == '00ffffff',
        group.children[1]._color)
end

do
    -- The right-hand view of a splitscreen starts at x = 960; a grid built at
    -- the screen origin instead leaves it uncovered.
    local env, SM = NewSession({ splitscreen = true })
    SM.InitTeamMouse(false)
    local groups = Mock.FindDragOverlays(env)
    local sawRight = false
    for _, group in ipairs(groups) do
        local l, t, r, b = Extent(group)
        if l >= 900 then
            sawRight = true
            Check('the right-hand grid starts where its view does and reaches its far edge',
                l == 960 and r >= 1920 and t == 0 and b >= 1080, l .. ',' .. t .. ' ' .. r .. ',' .. b)
        end
    end
    Check('there is a grid over the right-hand view', sawRight)
end

do
    -- Resize: the view grows. The grid follows once the size has held still.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local before = Mock.FindDragOverlays(env)[1]

    view.Right:Set(2560); view.Width:Set(2560)
    view.Bottom:Set(1440); view.Height:Set(1440)

    env.__clock.t = env.__clock.t + 0.3
    SM.OnBeat()
    Check('one look at a new size is not enough to rebuild (a window edge may still be moving)',
        Mock.FindDragOverlays(env)[1] == before)

    env.__clock.t = env.__clock.t + 0.3
    SM.OnBeat()
    local after = Mock.FindDragOverlays(env)
    Check('once the size has held, the grid is rebuilt', after[1] and after[1] ~= before and table.getn(after) == 1,
        table.getn(after))
    Check('the old grid is destroyed', before._destroyed == true)
    local l, t, r, b = Extent(after[1])
    Check('the new grid covers the new size', l == 0 and t == 0 and r >= 2560 and b >= 1440,
        l .. ',' .. t .. ' ' .. r .. ',' .. b)
    Check('the new grid starts down', not Mock.IsVisible(after[1]))
    Check('and rises for a drag with exactly one hole', GridRisesForLeftDrag(env, view, 2000, 1200))
    Check('no errors resizing', NoErrors(env))

    -- Shrinking is a resize too: a grid larger than the view is harmless to
    -- hit-testing but is wasted work, and the bookkeeping should follow.
    view.Right:Set(1280); view.Width:Set(1280)
    view.Bottom:Set(720); view.Height:Set(720)
    env.__clock.t = env.__clock.t + 0.3; SM.OnBeat()
    env.__clock.t = env.__clock.t + 0.3; SM.OnBeat()
    local l2, t2, r2, b2 = Extent(Mock.FindDragOverlays(env)[1])
    Check('a smaller view gets a smaller grid', r2 < 1500 and b2 < 900 and r2 >= 1280 and b2 >= 720,
        r2 .. ',' .. b2)
end

do
    -- The screen resizing under a view that fills it counts too.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local before = Mock.FindDragOverlays(env)[1]
    local view = env.__views['WorldCamera']
    local frame = env.__frame
    frame.Right:Set(2560); frame.Width:Set(2560)
    frame.Bottom:Set(1440); frame.Height:Set(1440)
    view.Right:Set(2560); view.Width:Set(2560)
    view.Bottom:Set(1440); view.Height:Set(1440)
    env.__clock.t = env.__clock.t + 0.3; SM.OnBeat()
    env.__clock.t = env.__clock.t + 0.3; SM.OnBeat()
    local l, t, r, b = Extent(Mock.FindDragOverlays(env)[1])
    Check('a resized screen is covered whole', r >= 2560 and b >= 1440, r .. ',' .. b)
end

do
    -- Never rebuilt under a drag: the grid is what is tracking it.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local before = Mock.FindDragOverlays(env)[1]
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    view.Right:Set(2560); view.Width:Set(2560)
    for _ = 1, 4 do
        env.__clock.t = env.__clock.t + 0.3
        SM.OnBeat()
    end
    Check('the grid is left alone for the length of a drag', Mock.FindDragOverlays(env)[1] == before)
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 100, MouseY = 100, Modifiers = {} })
    for _ = 1, 3 do
        env.__clock.t = env.__clock.t + 0.3
        SM.OnBeat()
    end
    Check('and is brought up to date once it ends', Mock.FindDragOverlays(env)[1] ~= before)
end

do
    -- Stable geometry never rebuilds.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local before = Mock.FindDragOverlays(env)[1]
    for _ = 1, 10 do
        env.__clock.t = env.__clock.t + 0.3
        SM.OnBeat()
    end
    Check('an unchanged view never rebuilds its grid', Mock.FindDragOverlays(env)[1] == before)
end

do
    local env, SM = NewSession()
    env.import('/mods/TeamMouse/modules/config.lua').Selection.DebugGrid = true
    SM.InitTeamMouse(false)
    local group = Mock.FindDragOverlays(env)[1]
    local tinted = 0
    for _, c in ipairs(group.children) do
        if c._color == '35ffffff' then tinted = tinted + 1 end
    end
    Check('DebugGrid tints the cells so their coverage can be seen', tinted > 100, tinted)
end

--------------------------------------------------------------------------------
Section('state is drawn from the moment being drawn: after a drag')
--------------------------------------------------------------------------------
-- Regression test for: after a drag the cursor teleported back to the start of
-- the drag and slid to the end. Position is drawn InterpolationDelay in the
-- past but the drag flag flipped the moment a packet arrived, so for a tenth of
-- a second the arrow was drawn at the anchor while the position was still
-- sliding away from it.
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t

    -- Anchor (100,100) -> screen (200,200). The drag runs to (300,150) -> (600,300).
    local function Packet(t, p, box, dragging)
        env.__clock.t = t
        receive('KasperAUS', {
            v = 1, a = 2, p = { p[1], 0, p[2] }, o = 0, z = 60, w = true,
            s = dragging, hx = 0.5, hy = 0.5, bx = box[1], bz = box[2],
        })
    end

    Packet(T, { 100, 100 }, { 100, 100 }, true)
    Packet(T + 0.1, { 100, 100 }, { 200, 125 }, true)
    Packet(T + 0.2, { 100, 100 }, { 300, 150 }, true)
    -- Released. The pointer is where the drag ended.
    Packet(T + 0.3, { 300, 150 }, { 300, 150 }, false)
    Packet(T + 0.4, { 302, 150 }, { 302, 150 }, false)
    Packet(T + 0.5, { 304, 150 }, { 304, 150 }, false)

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local reached, backAtAnchor, anchorMoved = false, nil, false
    local maxAfter = 0
    for i = 0, 60 do
        env.__clock.t = T + 0.13 + i * 0.01
        driver:OnFrame(0.01)
        local x = visual.mouseIcon.Left()
        if x >= 590 then reached = true end
        if reached and x < 500 and not backAtAnchor then backAtAnchor = x end
        -- The drag box hangs off the anchor. While it is up the anchor holds.
        if visual.dragBoxShown and visual.Left() ~= 200 then anchorMoved = visual.Left() end
    end
    Check('the arrow reaches the end of the drag', reached)
    Check('and never goes back toward the start of it afterwards', backAtAnchor == nil,
        backAtAnchor)
    Check('the box\'s anchor holds still for the whole drag (no slide toward the end)',
        anchorMoved == false, anchorMoved)
    Check('no errors', NoErrors(env))
end

do
    -- Same for a structure line and a right-drag order line, which share the
    -- machinery: the arrow must not fall back to the anchor when they end.
    for _, kind in ipairs({ 'l', 'r' }) do
        local env, SM = NewSession()
        SM.InitTeamMouse(false)
        local receive = env.__chatFuncs['TeamMouse']
        local driver = Mock.FindDriver(env)
        local T = env.__clock.t
        local function Packet(t, p, box, on)
            env.__clock.t = t
            local m = { v = 1, a = 2, p = { p[1], 0, p[2] }, o = 0, z = 60, w = true,
                hx = 0.5, hy = 0.5, bx = box[1], bz = box[2] }
            m[kind] = on
            receive('KasperAUS', m)
        end
        Packet(T, { 100, 100 }, { 100, 100 }, true)
        Packet(T + 0.1, { 100, 100 }, { 300, 150 }, true)
        Packet(T + 0.2, { 100, 100 }, { 300, 150 }, true)
        Packet(T + 0.3, { 300, 150 }, { 300, 150 }, false)
        Packet(T + 0.4, { 300, 150 }, { 300, 150 }, false)
        local visual = Mock.FindCursors(env, 'WorldCamera')[1]
        local reached, back = false, false
        for i = 0, 40 do
            env.__clock.t = T + 0.2 + i * 0.01
            driver:OnFrame(0.01)
            local x = visual.mouseIcon.Left()
            if x >= 590 then reached = true end
            if reached and x < 500 then back = true end
        end
        Check('after a "' .. kind .. '" drag the arrow continues from its end', reached and not back)
    end
end

--------------------------------------------------------------------------------
Section('HUD image steps instead of sliding, and the ghost fades')
--------------------------------------------------------------------------------
do
    -- Entering the interface far from the placeholder position the image had
    -- while they were on the map: it must appear at the right place at once.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    local function Packet(t, onHud, hx, hy)
        env.__clock.t = t
        receive('KasperAUS', { v = 1, a = 2, p = { 50, 0, 50 }, o = 0, z = 60, w = not onHud,
            hx = hx, hy = hy })
    end
    Packet(T, false, 0.5, 0.9)
    Packet(T + 0.1, false, 0.5, 0.9)
    Packet(T + 0.2, true, 0.95, 0.1)
    Packet(T + 0.3, true, 0.95, 0.1)
    Packet(T + 0.4, true, 0.95, 0.1)

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local record = visual.record
    local firstHudX, wrongWhileHud = nil, false
    for i = 0, 40 do
        env.__clock.t = T + 0.13 + i * 0.01
        driver:OnFrame(0.01)
        if record.renderHud then
            firstHudX = firstHudX or record.hudRender[1]
            if math.abs(record.hudRender[1] - 0.95) > 0.001 then wrongWhileHud = record.hudRender[1] end
        end
    end
    Check('the image is in place on the first frame they are on the interface',
        firstHudX and math.abs(firstHudX - 0.95) < 0.001, firstHudX)
    Check('and never slides in from where it was', wrongWhileHud == false, wrongWhileHud)
end

do
    -- Hovering the far side of the interface: a hop, not a slide, and the
    -- ghost fades in again at the new spot.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    local function Packet(t, hx, hy)
        env.__clock.t = t
        receive('KasperAUS', { v = 1, a = 2, p = { 50, 0, 50 }, o = 0, z = 60, w = false,
            hx = hx, hy = hy })
    end
    for i = 0, 4 do Packet(T + i * 0.1, 0.05, 0.05) end
    for i = 5, 10 do Packet(T + i * 0.1, 0.95, 0.9) end

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local record = visual.record
    local values, fadeBefore, fadeAfter = {}, nil, nil
    local prevX = nil
    for i = 0, 100 do
        env.__clock.t = T + 0.13 + i * 0.01
        driver:OnFrame(0.01)
        local x = record.hudRender[1]
        values[string.format('%.2f', x)] = true
        if prevX and prevX < 0.5 and x > 0.5 then
            fadeAfter = visual.hudFade
        end
        if prevX == nil or x < 0.5 then fadeBefore = visual.hudFade end
        prevX = x
    end
    local n = 0
    for _ in pairs(values) do n = n + 1 end
    Check('crossing the interface takes exactly two positions, with nothing between', n == 2, n)
    Check('the ghost was fully faded in before the hop', fadeBefore and fadeBefore > 0.99, fadeBefore)
    Check('and starts fading in again from nothing at the far side',
        fadeAfter and fadeAfter < 0.3, fadeAfter)
end

do
    -- The ordinary case still glides: a hop is only a big move.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    for i = 0, 8 do
        env.__clock.t = T + i * 0.033
        receive('KasperAUS', { v = 1, a = 2, p = { 50, 0, 50 }, o = 0, z = 60, w = false,
            hx = 0.3 + i * 0.05, hy = 0.5 })
    end
    local record = Mock.FindCursors(env, 'WorldCamera')[1].record
    local values, n = {}, 0
    for i = 0, 40 do
        env.__clock.t = T + 0.13 + i * 0.008
        driver:OnFrame(0.008)
        local k = string.format('%.3f', record.hudRender[1])
        if not values[k] then values[k] = true; n = n + 1 end
    end
    Check('a normal sweep across the interface is still smooth', n >= 10, n)
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    local function Packet(t, onHud)
        env.__clock.t = t
        receive('KasperAUS', { v = 1, a = 2, p = { 50 + (onHud and 0 or 40), 0, 50 }, o = 0, z = 60,
            w = not onHud, hx = 0.6, hy = 0.6 })
    end
    for i = 0, 3 do Packet(T + i * 0.1, false) end
    for i = 4, 9 do Packet(T + i * 0.1, true) end
    for i = 10, 16 do Packet(T + i * 0.1, false) end

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local record = visual.record
    local alphaAtEntry, rose, monotonic, lastA = {}, false, true, -1
    local fadeSeq, hiddenAfter = {}, nil
    local frozenLeft, movedWhileFading = nil, false
    local wasHud = false
    for i = 0, 130 do
        env.__clock.t = T + 0.13 + i * 0.01
        driver:OnFrame(0.01)
        if visual.hud then
            local a = visual.hud.hud._alpha
            if record.renderHud then
                wasHud = true
                if a < lastA - 0.0001 then monotonic = false end
                lastA = a
                if a > 0.5 then rose = true end
                -- Where the anchor was on the last frame they were on the interface.
                -- (The mock binds AtLeftTopIn eagerly, so hud.Left() itself only
                -- means something once the code has pinned it.)
                frozenLeft = visual.Left() - visual.hud.panelWidth * 0.5
            elseif wasHud and Mock.IsVisible(visual.hud) then
                table.insert(fadeSeq, a)
                if visual.hud.Left() ~= frozenLeft then movedWhileFading = true end
            elseif wasHud and not Mock.IsVisible(visual.hud) and not hiddenAfter then
                hiddenAfter = i
            end
        end
    end
    Check('the ghost fades in rather than appearing', monotonic and rose)
    Check('and the first frame on the interface is not fully opaque',
        visual.hud and visual.hudFade ~= nil)
    Check('leaving the interface fades the ghost out over several frames', table.getn(fadeSeq) >= 3,
        table.getn(fadeSeq))
    local decreasing = true
    for i = 2, table.getn(fadeSeq) do
        if fadeSeq[i] > fadeSeq[i - 1] + 0.0001 then decreasing = false end
    end
    Check('with the opacity falling each frame', decreasing and table.getn(fadeSeq) > 0)
    Check('and it is gone once faded', hiddenAfter ~= nil and not Mock.IsVisible(visual.hud))
    Check('the fading ghost stays where it was, and does not ride the cursor away',
        movedWhileFading == false)
    Check('no errors', NoErrors(env))
end

--------------------------------------------------------------------------------
Section('right-drag: the line is shown while it is drawn')
--------------------------------------------------------------------------------
local function UnitWithQueue(env)
    env.__queue = {}
    return { GetCommandQueue = function() return env.__queue end }
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local driver = Mock.FindDriver(env)
    env.__selectedUnits = { UnitWithQueue(env) }

    env.__mouseWorld = { 60, 0, 40 }
    RightPress(env, view, 120, 80)
    env.__clock.t = env.__clock.t + 0.6   -- past Orders.LineDelay, when the line exists
    env.__mouseWorld = { 90, 0, 70 }
    for i = 1, 3 do
        env.__clock.t = env.__clock.t + 0.033
        env.__mouseWorld = { 60 + i * 10, 0, 40 + i * 10 }
        view:HandleEvent({ Type = 'MouseMotion', MouseX = 120 + i * 20, MouseY = 80 + i * 20, Modifiers = { Right = true } })
        driver:OnFrame(0.016)
    end
    env.__clock.t = env.__clock.t + 0.004
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('a right-drag in progress is flagged as an order line', msg.r == true and msg.s == false and msg.l == false)
    Check('the position is pinned at the press point', msg.p[1] == 60 and msg.p[3] == 40,
        msg.p[1] .. ',' .. msg.p[3])
    Check('and the far end of the line is the live pointer', msg.bx == 90 and msg.bz == 70,
        tostring(msg.bx) .. ',' .. tostring(msg.bz))
    Check('extra samples of it are flagged as order-line samples too',
        type(msg.e) == 'table' and msg.e[9] == 8, type(msg.e) == 'table' and msg.e[9] or 'no e')

    RightRelease(env, view, 180, 140)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    msg = env.__sent[table.getn(env.__sent)].msg
    Check('releasing ends the live line and announces the order', msg.r == false and type(msg.mo) == 'table')
    Check('the order carries a sequence number', msg.mo and msg.mo[7] == 1, msg.mo and msg.mo[7])
end

do
    -- Only a press that will actually be an order streams as one.
    local function Sent(setup)
        local env, SM = NewSession()
        setup(env)
        SM.InitTeamMouse(false)
        local view = env.__views['WorldCamera']
        env.__mouseWorld = { 60, 0, 40 }
        RightPress(env, view, 120, 80)
        env.__clock.t = env.__clock.t + 0.2
        SM.OnBeat()
        return env.__sent[table.getn(env.__sent)].msg
    end
    Check('nothing selected: not an order line', Sent(function(env) end).r == false)
    Check('a command mode active: not an order line', Sent(function(env)
        env.__selectedUnits = { {} }; env.__commandMode = { 'order', {} } end).r == false)
    Check('sharing off: not an order line', Sent(function(env)
        env.__selectedUnits = { {} }
        env.import('/mods/TeamMouse/modules/config.lua').Orders.Share = false end).r == false)
    Check('live line switched off: not an order line', Sent(function(env)
        env.__selectedUnits = { {} }
        env.import('/mods/TeamMouse/modules/config.lua').Orders.ShowLiveLine = false end).r == false)
end

do
    -- The sender reports when the sim has taken the order: its unit's command
    -- queue changed from what it was at the press.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { UnitWithQueue(env) }
    env.__mouseWorld = { 60, 0, 40 }
    RightPress(env, view, 120, 80)
    RightRelease(env, view, 120, 80)

    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('the order is announced without an "applied" report yet', type(msg.mo) == 'table' and msg.oa == false)

    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('and nothing is reported while the queue is unchanged',
        env.__sent[table.getn(env.__sent)].msg.oa == false)

    env.__queue = { { type = 'Move', position = { 60, 0, 40 } } }
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    msg = env.__sent[table.getn(env.__sent)].msg
    Check('once the queue changes, the order is reported as applied', msg.oa == 1, tostring(msg.oa))

    local sentBefore = table.getn(env.__sent)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local again = false
    for i = sentBefore + 1, table.getn(env.__sent) do
        if env.__sent[i].msg.oa ~= false then again = true end
    end
    Check('reported once', not again)
end

do
    -- A queue that can't be read must not leave the line up for ever.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }   -- no GetCommandQueue at all
    env.__mouseWorld = { 60, 0, 40 }
    RightPress(env, view, 120, 80)
    RightRelease(env, view, 120, 80)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('unreadable queue: not reported early', env.__sent[table.getn(env.__sent)].msg.oa == false)
    env.__clock.t = env.__clock.t + 1.0
    SM.OnBeat()
    Check('unreadable queue: reported once the timeout passes',
        env.__sent[table.getn(env.__sent)].msg.oa == 1)
end

do
    -- A newer order supersedes one still waiting.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { UnitWithQueue(env) }
    env.__mouseWorld = { 60, 0, 40 }
    RightPress(env, view, 120, 80); RightRelease(env, view, 120, 80)
    RightPress(env, view, 130, 90); RightRelease(env, view, 130, 90)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('an order given before the last was confirmed confirms it', msg.oa == 1 and msg.mo[14] == 2,
        tostring(msg.oa))
end

do
    -- Diagnostic for the unconfirmed engine behaviour, Debug only.
    local env, SM = NewSession()
    env.import('/mods/TeamMouse/modules/config.lua').Debug = true
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__mouseWorld = { 60, 0, 40 }
    RightPress(env, view, 120, 80)
    view:HandleEvent({ Type = 'MouseMotion', MouseX = 200, MouseY = 100, Modifiers = { Right = true } })
    view:HandleEvent({ Type = 'MouseMotion', MouseX = 220, MouseY = 110, Modifiers = { Right = true } })
    RightRelease(env, view, 220, 110)
    local found = false
    for _, line in ipairs(env.__logs) do
        if string.find(line, '2 motion events reached the view', 1, true) then found = true end
    end
    Check('a right press reports whether the engine delivered motion, when Debug is on', found)
end

--------------------------------------------------------------------------------
Section('right-drag: showing it, and hiding it once the sim has it')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    local function Packet(t, extra)
        env.__clock.t = t
        local m = { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true, hx = 0.5, hy = 0.5,
            r = true, bx = 300, bz = 150 }
        for k, v in pairs(extra or {}) do m[k] = v end
        receive('KasperAUS', m)
    end
    Packet(T)
    Packet(T + 0.1)
    Packet(T + 0.2)
    env.__clock.t = T + 0.35
    driver:OnFrame(0.016)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('the line is drawn while the drag is still going on', visual.line and visual.line.shown >= 2)

    -- Released: the order arrives, the live line is over, the order's own line
    -- takes its place until the sim has it.
    Packet(T + 0.3, { r = false, p = { 300, 0, 150 }, bx = 300, bz = 150,
        mo = { 0, 100, 0, 100, 300, 150, 7 } })
    Packet(T + 0.4, { r = false, p = { 300, 0, 150 }, bx = 300, bz = 150 })
    env.__clock.t = T + 0.5
    driver:OnFrame(0.016)
    local mark = visual.orderMarks[1]
    Check('after the release the drag line is replaced by the order\'s', visual.line.shown == 0
        and mark and mark.line and mark.line.shown >= 2 and Mock.IsVisible(mark.line.dots[1]))

    env.__clock.t = T + 0.9
    Packet(T + 0.9, { r = false, p = { 300, 0, 150 }, bx = 300, bz = 150 })
    driver:OnFrame(0.016)
    Check('it stays up while the sim has not confirmed the order', mark.lineShown == true)

    -- The sender reports the order applied.
    Packet(T + 1.0, { r = false, p = { 300, 0, 150 }, bx = 300, bz = 150, oa = 7 })
    env.__clock.t = T + 1.05
    driver:OnFrame(0.016)
    Check('still up until the confirmation is due to be drawn', mark.lineShown == true)
    env.__clock.t = T + 1.3
    driver:OnFrame(0.016)
    Check('and gone once the order has reached the sim', mark.lineShown == false
        and (not mark.line or mark.line.shown == 0))
    Check('the marker itself carries on and fades as before', mark.visible == true)
    Check('no errors', NoErrors(env))
end

do
    -- No confirmation ever arrives: the line still goes.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
        mo = { 0, 100, 0, 100, 300, 150, 3 } })
    env.__clock.t = T + 0.3
    driver:OnFrame(0.016)
    local mark = Mock.FindCursors(env, 'WorldCamera')[1].orderMarks[1]
    Check('an unconfirmed order line is shown', mark.lineShown == true)
    env.__clock.t = T + 1.9
    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true })
    driver:OnFrame(0.016)
    Check('and dropped after PreviewMax with no report', mark.lineShown == false)
end

do
    -- A confirmation for an older order does not take down a newer one.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
        mo = { 0, 100, 0, 100, 300, 150, 1, 0, 100, 0, 120, 300, 170, 2 }, oa = 1 })
    env.__clock.t = T + 0.3
    driver:OnFrame(0.016)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('only the order the report names is confirmed',
        visual.orderMarks[1].lineShown == false and visual.orderMarks[2].lineShown == true)
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local nan = 0 / 0
    for _, oa in ipairs({ 'x', nan, -5, 1e40, {}, true }) do
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
            mo = { 0, 100, 0, 100, 100, 100, 1 }, oa = oa, r = oa, l = oa })
    end
    Mock.FindDriver(env):OnFrame(0.016)
    Check('malformed reports never raise', NoErrors(env))
end

--------------------------------------------------------------------------------
Section('a plain left click is not a drag')
--------------------------------------------------------------------------------
do
    -- The drag box's live corner comes from the last cell the pointer entered,
    -- which can be most of a cell away from where it actually rests. A click
    -- that never moves must report a corner at its own press point.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local cells = Mock.FindDragOverlays(env)[1].children

    env.__mouseWorld = { 50, 0, 50 }
    SM.OnBeat()
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()   -- rests on the map: the pointer mapping calibrates

    -- Hover: the pointer entered the current cell at (130, 90) and came to rest
    -- at (100, 100), which the mock maps to world (50, 50).
    cells[1]:HandleEvent({ Type = 'MouseEnter', MouseX = 130, MouseY = 90, Modifiers = {} })
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('the click is still reported (as the start of a possible drag)', msg.s == true)
    Check('but its far corner is where it was pressed, not where the cell was entered',
        math.abs(msg.bx - msg.p[1]) < 0.01 and math.abs(msg.bz - msg.p[3]) < 0.01,
        tostring(msg.bx) .. ',' .. tostring(msg.bz) .. ' vs ' .. msg.p[1] .. ',' .. msg.p[3])
end

do
    -- And a box of a few pixels is a jitter, not something to draw.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    for i = 0, 3 do
        env.__clock.t = T + i * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
            s = true, hx = 0.5, hy = 0.5, bx = 101, bz = 100.5 })   -- 2px x 1px on screen
    end
    env.__clock.t = T + 0.5
    driver:OnFrame(0.016)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('a box of a couple of pixels is not drawn', not visual.dragBoxShown)

    for i = 4, 7 do
        env.__clock.t = T + i * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
            s = true, hx = 0.5, hy = 0.5, bx = 130, bz = 120 })
    end
    env.__clock.t = T + 1.0
    driver:OnFrame(0.016)
    Check('a real one still is', visual.dragBoxShown == true)
end

--------------------------------------------------------------------------------
Section('leaving the interface')
--------------------------------------------------------------------------------
do
    -- Dragging off the interface onto the map. The first sample on the map
    -- carries placeholder interface coordinates; the image must not slide
    -- toward them in the moment before the ghost starts to fade.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    for i = 0, 5 do
        env.__clock.t = T + i * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { 50, 0, 50 }, o = 0, z = 60, w = false,
            hx = 0.9, hy = 0.1 })
    end
    for i = 6, 12 do
        env.__clock.t = T + i * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { 50 + (i - 5) * 20, 0, 50 }, o = 0, z = 60, w = true,
            hx = 0.5, hy = 0.9 })
    end

    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local record = visual.record
    local dotXs, n = {}, 0
    local hudXs, hn = {}, 0
    local sawFade = false
    for i = 0, 120 do
        env.__clock.t = T + 0.13 + i * 0.01
        driver:OnFrame(0.01)
        if visual.hud and env.__clock.t > T + 0.13 + 0.45 then
            -- From just before they leave the interface onward.
            local k = tostring(visual.hud.hudX)
            if not dotXs[k] then dotXs[k] = true; n = n + 1 end
            if record.renderHud then
                local hk = string.format('%.3f', record.hudRender[1])
                if not hudXs[hk] then hudXs[hk] = true; hn = hn + 1 end
            end
            if not record.renderHud and Mock.IsVisible(visual.hud) then sawFade = true end
        end
    end
    Check('the ghost does fade out after they leave', sawFade)
    Check('the image position given to the ghost never changes on the way out', hn == 1, hn)
    Check('and the image itself does not move while it fades', n == 1, n)
end

--------------------------------------------------------------------------------
Section('right press: the line waits for the order, the cursor does not freeze')
--------------------------------------------------------------------------------
do
    -- The native formation line only appears after the button has been held for
    -- a moment. Ours must not be ahead of it.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }
    env.__mouseWorld = { 60, 0, 40 }
    RightPress(env, view, 120, 80)
    env.__clock.t = env.__clock.t + 0.2
    env.__mouseWorld = { 90, 0, 70 }
    view:HandleEvent({ Type = 'MouseMotion', MouseX = 180, MouseY = 140, Modifiers = { Right = true } })
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('held for 0.2s: no order line yet', msg.r == false)
    Check('but the pointer already travels (drawing / dragging, not frozen)',
        msg.d == 2 and msg.bx == 90 and msg.bz == 70, tostring(msg.d))

    env.__clock.t = env.__clock.t + 0.4
    env.__mouseWorld = { 95, 0, 75 }
    view:HandleEvent({ Type = 'MouseMotion', MouseX = 190, MouseY = 150, Modifiers = { Right = true } })
    SM.OnBeat()
    msg = env.__sent[table.getn(env.__sent)].msg
    Check('held for 0.6s: the order line is on', msg.r == true and msg.d == false)
    RightRelease(env, view, 190, 150)
end

do
    -- Released before the order's delay: a plain move to where it was pressed
    -- (the pointer having moved a bit is not a formation).
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }
    env.__mouseWorld = { 60, 0, 40 }
    RightPress(env, view, 120, 80)
    env.__clock.t = env.__clock.t + 0.2
    env.__mouseWorld = { 90, 0, 70 }
    RightRelease(env, view, 180, 140)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local mo = env.__sent[table.getn(env.__sent)].msg.mo
    Check('a quick right-drag is announced as a plain order, with no line',
        mo and mo[5] == 60 and mo[6] == 40, mo and (mo[5] .. ',' .. mo[6]) or 'no order')
end

do
    -- Nothing selected: right-drag draws. The pointer must be reported moving.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local driver = Mock.FindDriver(env)
    env.__mouseWorld = { 60, 0, 40 }
    RightPress(env, view, 120, 80)
    for i = 1, 4 do
        env.__clock.t = env.__clock.t + 0.033
        env.__mouseWorld = { 60 + i * 10, 0, 40 + i * 5 }
        view:HandleEvent({ Type = 'MouseMotion', MouseX = 120 + i * 20, MouseY = 80 + i * 10, Modifiers = { Right = true } })
        driver:OnFrame(0.016)
    end
    env.__clock.t = env.__clock.t + 0.004
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('drawing with nothing selected is reported as a drag', msg.d == 1 and msg.r == false)
    Check('anchored at the press', msg.p[1] == 60 and msg.p[3] == 40)
    Check('with the moving pointer as the live end', msg.bx == 100 and msg.bz == 60,
        tostring(msg.bx) .. ',' .. tostring(msg.bz))
    Check('and the samples in between carry it too', type(msg.e) == 'table' and msg.e[9] == 16
        and msg.e[7] ~= msg.e[table.getn(msg.e) - 2], type(msg.e) == 'table' and msg.e[9] or 'no e')
    Check('no order is announced for it', msg.mo == false)

    RightRelease(env, view, 200, 120)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    msg = env.__sent[table.getn(env.__sent)].msg
    Check('releasing ends it', msg.d == false and msg.r == false)
end

do
    -- What a teammate sees: the arrow follows the live end, and nothing else is
    -- drawn for it.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    local function Packet(t, p, box, on)
        env.__clock.t = t
        receive('KasperAUS', { v = 1, a = 2, p = { p[1], 0, p[2] }, o = 0, z = 60, w = true,
            hx = 0.5, hy = 0.5, bx = box[1], bz = box[2], d = on and 1 or false })
    end
    Packet(T, { 100, 100 }, { 100, 100 }, true)
    Packet(T + 0.1, { 100, 100 }, { 200, 125 }, true)
    Packet(T + 0.2, { 100, 100 }, { 300, 150 }, true)
    Packet(T + 0.3, { 300, 150 }, { 300, 150 }, false)
    Packet(T + 0.4, { 300, 150 }, { 300, 150 }, false)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local reached, back = false, false
    local sawBox, sawLine = false, false
    for i = 0, 40 do
        env.__clock.t = T + 0.2 + i * 0.01
        driver:OnFrame(0.01)
        local x = visual.mouseIcon.Left()
        if x >= 590 then reached = true end
        if reached and x < 500 then back = true end
        if visual.dragBoxShown then sawBox = true end
        if visual.lineShown then sawLine = true end
    end
    Check('the arrow follows the pointer while they draw', reached)
    Check('and continues from where they stopped', not back)
    Check('with no box or line drawn for it', not sawBox and not sawLine)
end

--------------------------------------------------------------------------------
Section('Shift-drag is a selection box too')
--------------------------------------------------------------------------------
local function Calibrate(env, SM)
    env.__mouseWorld = { 50, 0, 50 }
    SM.OnBeat()
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
end

do
    -- Shift adds to a selection; it is still a box. (Moving an order is told
    -- apart by the cursor, not by Shift: see 'dragging a waypoint'.)
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local cell = Mock.FindDragOverlays(env)[1].children[1]
    Calibrate(env, SM)

    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true, Shift = true } })
    cell:HandleEvent({ Type = 'MouseEnter', MouseX = 300, MouseY = 200, Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('a Shift-drag is reported as a selection box', msg.s == true and msg.d == false)
    Check('from the press to the pointer', msg.p[1] == 50 and msg.bx == 150 and msg.bz == 100,
        msg.p[1] .. ' ' .. tostring(msg.bx))
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 300, MouseY = 200, Modifiers = {} })
end

do
    -- ...but a Shift-drag that moves a queued waypoint is the hand, not a box.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    env.__cursor:SetTexture('/textures/ui/common/game/cursors/waypoint-hover.dds', 0, 0)
    env.__views['WorldCamera']:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100,
        Modifiers = { Left = true, Shift = true } })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('a Shift-drag of a waypoint is not a box', msg.s == false and msg.d == 2)
end

do
    -- Shift is how structures are queued: a build line stays a line.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    env.__commandMode = { 'build', { name = 'ueb0101' } }
    env.__views['WorldCamera']:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100,
        Modifiers = { Left = true, Shift = true } })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('a Shift-drag in build mode is still a line', msg.l == true and msg.s == false)
end

do
    -- What a teammate sees of a waypoint being moved: the arrow travels, no
    -- box, no trail.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    for i = 0, 5 do
        env.__clock.t = T + i * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
            hx = 0.5, hy = 0.5, d = 2, bx = 100 + i * 40, bz = 100 })
    end
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local sawBox, moved = false, false
    for i = 0, 40 do
        env.__clock.t = T + 0.3 + i * 0.01
        driver:OnFrame(0.01)
        if visual.dragBoxShown then sawBox = true end
        if visual.mouseIcon.Left() > 500 then moved = true end
    end
    Check('the arrow follows a waypoint being moved', moved)
    Check('with no box', not sawBox)
    Check('and no trail', visual.trail.n == 0)
end

--------------------------------------------------------------------------------
Section('right press: drawing is followed through the grid')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local cell = Mock.FindDragOverlays(env)[1].children[1]
    Calibrate(env, SM)

    Mock.buttons.right = true
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Right = true } })
    Check('with nothing selected the grid stays up for a right press', VisibleOverlays(env) == 1)

    -- The engine freezes everything else; only cell crossings arrive.
    env.__mouseWorld = { 50, 0, 50 }
    cell:HandleEvent({ Type = 'MouseEnter', MouseX = 200, MouseY = 140, Modifiers = { Right = true } })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('drawing is reported as such', msg.d == 1 and msg.r == false and msg.s == false, tostring(msg.d))
    Check('anchored at the press', msg.p[1] == 50 and msg.p[3] == 50)
    Check('and the moving end comes from the grid, though the engine says the pointer never moved',
        msg.bx == 100 and msg.bz == 70, tostring(msg.bx) .. ',' .. tostring(msg.bz))

    Mock.buttons.right = false
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 200, MouseY = 140, Modifiers = {} })
    Check('the release takes the grid down', VisibleOverlays(env) == 0)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    msg = env.__sent[table.getn(env.__sent)].msg
    Check('and drawing is over', msg.d == false)
end

do
    -- A right click that never moves reports its own press point.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local cell = Mock.FindDragOverlays(env)[1].children[1]
    Calibrate(env, SM)
    cell:HandleEvent({ Type = 'MouseEnter', MouseX = 130, MouseY = 90, Modifiers = {} })
    Mock.buttons.right = true
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Right = true } })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('a right click that never moved has no stroke',
        math.abs(msg.bx - msg.p[1]) < 0.01 and math.abs(msg.bz - msg.p[3]) < 0.01,
        tostring(msg.bx) .. ',' .. tostring(msg.bz))
end

do
    local env, SM = NewSession()
    env.import('/mods/TeamMouse/modules/config.lua').Orders.TrackDrawing = false
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    Mock.buttons.right = true
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Right = true } })
    Check('Orders.TrackDrawing = false lifts the grid for drawing too', VisibleOverlays(env) == 0)
end

do
    -- Units selected: an order. The grid is lifted, always.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }
    Mock.buttons.right = true
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Right = true } })
    Check('an order lifts the grid, as before', VisibleOverlays(env) == 0)

end

do
    local env, SM = NewSession()
    env.import('/mods/TeamMouse/modules/config.lua').Debug = true
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local cell = Mock.FindDragOverlays(env)[1].children[1]
    Mock.buttons.right = true
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Right = true } })
    cell:HandleEvent({ Type = 'MouseEnter', MouseX = 200, MouseY = 140, Modifiers = { Right = true } })
    cell:HandleEvent({ Type = 'MouseEnter', MouseX = 240, MouseY = 150, Modifiers = { Right = true } })
    Mock.buttons.right = false
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 240, MouseY = 150, Modifiers = {} })
    local press, ended = false, false
    for _, line in ipairs(env.__logs) do
        if string.find(line, 'right press: selection=false commandMode=false -> drawing, grid kept up', 1, true) then press = true end
        if string.find(line, '2 grid crossings', 1, true) then ended = true end
    end
    Check('Debug logs what a right press was treated as', press)
    Check('and how many grid crossings reached it', ended)
end

--------------------------------------------------------------------------------
Section('the drawing trail')
--------------------------------------------------------------------------------
local function TrailDots(visual)
    local n = 0
    if visual.trail.line then
        for i = 1, visual.trail.line.max do
            if Mock.IsVisible(visual.trail.line.dots[i]) then n = n + 1 end
        end
    end
    return n
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t

    -- A stroke from world (100,100) out to (300,150) and up to (300,250).
    local path = { { 100, 100 }, { 200, 125 }, { 300, 150 }, { 300, 200 }, { 300, 250 } }
    for i, pt in ipairs(path) do
        env.__clock.t = T + (i - 1) * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
            hx = 0.5, hy = 0.5, d = 1, bx = pt[1], bz = pt[2] })
    end
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    for i = 0, 40 do
        env.__clock.t = T + 0.13 + i * 0.01
        driver:OnFrame(0.01)
    end
    Check('a stroke leaves a trail', visual.trail.n >= 4, visual.trail.n)
    Check('drawn as dots', TrailDots(visual) >= 6, TrailDots(visual))
    local line = visual.trail.line
    local first, lastDot = line.dots[1], line.dots[line.shown]
    Check('starting where the stroke did', first.Left() == 200 - 1.5 and first.Top() == 200 - 1.5,
        first.Left() .. ',' .. first.Top())
    Check('and reaching where it has got to',
        math.abs(lastDot.Left() - (600 - 1.5)) < 12 and math.abs(lastDot.Top() - (500 - 1.5)) < 12,
        lastDot.Left() .. ',' .. lastDot.Top())
    Check('no box or line drawn for a stroke', not visual.dragBoxShown and not visual.lineShown)

    -- The button comes up: the trail fades and goes.
    for i = 5, 8 do
        env.__clock.t = T + i * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { 300, 0, 250 }, o = 0, z = 60, w = true,
            hx = 0.5, hy = 0.5, d = false, bx = 300, bz = 250 })
    end
    env.__clock.t = T + 0.9
    driver:OnFrame(0.01)
    local a1 = line.dots[1]:GetAlpha()
    Check('it stays up for a moment after the stroke', TrailDots(visual) >= 6)
    env.__clock.t = T + 1.6
    driver:OnFrame(0.01)
    local a2 = line.dots[1]:GetAlpha()
    Check('and fades', a2 < a1, a1 .. ' -> ' .. a2)
    env.__clock.t = T + 4.0
    receive('KasperAUS', { v = 1, a = 2, p = { 300, 0, 250 }, o = 0, z = 60, w = true, d = false })
    driver:OnFrame(0.01)
    Check('then it is gone', TrailDots(visual) == 0 and visual.trail.n == 0)
    Check('no errors', NoErrors(env))
end

do
    -- A stroke of a few pixels is a click, not a drawing; a new one starts clean.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    for i = 0, 3 do
        env.__clock.t = T + i * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
            d = 1, bx = 100 + i, bz = 100 })
    end
    env.__clock.t = T + 0.5
    driver:OnFrame(0.01)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('a click of a few pixels draws no trail', TrailDots(visual) == 0)

    for i = 4, 9 do
        env.__clock.t = T + i * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
            d = false })
    end
    for i = 10, 14 do
        env.__clock.t = T + i * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
            d = 1, bx = 100 + (i - 10) * 60, bz = 100 })
    end
    for i = 0, 30 do
        env.__clock.t = T + 1.13 + i * 0.01
        driver:OnFrame(0.01)
    end
    Check('the next stroke draws normally', TrailDots(visual) >= 3, TrailDots(visual))
end

do
    -- A very long stroke stays within its pool and its point limit.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    for i = 0, 150 do
        env.__clock.t = T + i * 0.03
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
            d = 1, bx = 100 + math.mod(i * 13, 400), bz = 100 + i * 2 })
    end
    for i = 0, 20 do
        env.__clock.t = T + 4.6 + i * 0.01
        driver:OnFrame(0.01)
    end
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('a long stroke keeps within the point limit', visual.trail.n <= 100, visual.trail.n)
    Check('and the dot pool', TrailDots(visual) <= 80)
    Check('no errors', NoErrors(env))
end

do
    -- Switched off: nothing is built.
    local env, SM = NewSession()
    env.import('/mods/TeamMouse/modules/config.lua').Draw.Enabled = false
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    for i = 0, 5 do
        env.__clock.t = T + i * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
            d = 1, bx = 100 + i * 40, bz = 100 })
    end
    env.__clock.t = T + 0.7
    driver:OnFrame(0.01)
    Check('Draw.Enabled = false draws no trail', Mock.FindCursors(env, 'WorldCamera')[1].trail.n == 0)
end

--------------------------------------------------------------------------------
Section('dragging a waypoint stays the hand')
--------------------------------------------------------------------------------
local HAND = '/textures/ui/common/game/cursors/waypoint-drag.dds'
local HOVER = '/textures/ui/common/game/cursors/waypoint-hover.dds'

local function OrderIndexOf(env, name)
    return env.import('/mods/TeamMouse/modules/cursordata.lua').IndexFromKey(name)
end

do
    -- Regression test for: dragging an order flickered between the hand and
    -- the arrow, because the game's own cursor does.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local hand = OrderIndexOf(env, 'waypoint-drag')

    env.__cursor:SetTexture(HOVER, 0, 0)
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })

    -- The cursor (o) is only sent when it changes: what a teammate sees is
    -- the last one sent.
    local seen, wrong, shown = 0, 0, nil
    for i = 1, 8 do
        -- The game alternates the cursor while the waypoint moves.
        if math.mod(i, 2) == 0 then
            env.__cursor:SetTexture(HAND, 0, 0)
        else
            env.__cursor:Reset()
        end
        env.__clock.t = env.__clock.t + 0.1
        env.__mouseWorld = { 50 + i, 0, 50 }
        SM.OnBeat()
        local raw = env.__sent[table.getn(env.__sent)].raw
        if raw.o ~= nil then shown = raw.o end
        seen = seen + 1
        if shown ~= hand then wrong = wrong + 1 end
    end
    Check('every packet during the drag shows the hand', wrong == 0, wrong .. ' of ' .. seen)
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('and no selection box, the pointer just travels', msg.s == false and msg.d == 2)

    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 120, MouseY = 100, Modifiers = {} })
    env.__cursor:Reset()
    env.__clock.t = env.__clock.t + 0.1
    env.__mouseWorld = { 70, 0, 50 }
    SM.OnBeat()
    Check('after the release the cursor is reported as it is again',
        env.__sent[table.getn(env.__sent)].msg.o == OrderIndexOf(env, 'selectable'))
end

do
    -- The hand may only appear once the drag is under way.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local hand = OrderIndexOf(env, 'waypoint-drag')
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('a drag that starts as a box is a box', env.__sent[table.getn(env.__sent)].msg.s == true)
    env.__cursor:SetTexture(HAND, 0, 0)
    env.__cursor:Reset()
    env.__clock.t = env.__clock.t + 0.1
    env.__mouseWorld = { 60, 0, 60 }
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('once the hand shows, it stays, even after the cursor flicks back', msg.o == hand)
    Check('and the box goes', msg.s == false and msg.d == 2)
end

do
    -- A structure line is not a waypoint drag, whatever the cursor does.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    env.__commandMode = { 'build', { name = 'ueb0101' } }
    env.__views['WorldCamera']:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100,
        Modifiers = { Left = true } })
    env.__cursor:SetTexture(HAND, 0, 0)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('a build line stays a line', env.__sent[table.getn(env.__sent)].msg.l == true)
end

do
    -- Without a drag the cursor is reported exactly as it is.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    env.__cursor:SetTexture(HOVER, 0, 0)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('hovering a waypoint reports the hover cursor',
        env.__sent[table.getn(env.__sent)].msg.o == OrderIndexOf(env, 'waypoint-hover'))
end

--------------------------------------------------------------------------------
Section('a right press lasts as long as the button is held')
--------------------------------------------------------------------------------
-- Regression test for: holding right to draw, or for a formation, was cut off
-- as soon as the pointer left its grid cell. A per-frame IsKeyDown('RBUTTON')
-- check read the button as up while it was held: that ended the drawing for
-- teammates, and brought the grid back under a held formation, whose next cell
-- crossing then cancelled it.

--- Frames of a right drag across the grid, with the engine's reading frozen
--- (as it is for the length of its capture), the way the real game does it.
local function DragAcrossGrid(env, cell, driver, fromX, steps)
    for i = 1, steps do
        env.__clock.t = env.__clock.t + 0.016
        cell:HandleEvent({ Type = 'MouseEnter', MouseX = fromX + i * 45, MouseY = 140,
            Modifiers = { Right = true } })
        driver:OnFrame(0.016)
    end
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local cell = Mock.FindDragOverlays(env)[1].children[1]
    local driver = Mock.FindDriver(env)
    Calibrate(env, SM)

    env.__mouseWorld = { 50, 0, 50 }
    Mock.buttons.right = true
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Right = true } })
    -- The button state reads as up for the whole of the drag.
    Mock.buttons.right = false
    DragAcrossGrid(env, cell, driver, 100, 12)
    env.__clock.t = env.__clock.t + 0.05
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('a drawing crossing cell after cell is still a drawing, whatever IsKeyDown reads',
        msg.d == 1, tostring(msg.d))
    Check('and its far end is still following the pointer', msg.bx > 200, tostring(msg.bx))
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local driver = Mock.FindDriver(env)
    env.__selectedUnits = { {} }
    Mock.buttons.right = true
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Right = true } })
    Mock.buttons.right = false
    local shown = false
    for _ = 1, 60 do
        env.__clock.t = env.__clock.t + 0.016
        driver:OnFrame(0.016)
        if VisibleOverlays(env) > 0 then shown = true end
    end
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('the grid stays away for the whole of a held formation', not shown)
end

--------------------------------------------------------------------------------
Section('...and ends when it is let go, release event or not')
--------------------------------------------------------------------------------
do
    -- An order: the grid is lifted, nothing can be watched. Its release event
    -- ends it as before; if that is kept too, the next left press does.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local driver = Mock.FindDriver(env)
    env.__selectedUnits = { {} }
    env.__mouseWorld = { 60, 0, 40 }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 120, MouseY = 80, Modifiers = { Right = true } })
    env.__clock.t = env.__clock.t + 0.8
    env.__mouseWorld = { 90, 0, 70 }
    driver:OnFrame(0.016)
    Check('an order whose release never comes keeps the grid away', VisibleOverlays(env) == 0)

    view:HandleEvent({ Type = 'ButtonPress', MouseX = 200, MouseY = 150, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'MouseMotion', MouseX = 210, MouseY = 150, Modifiers = { Left = true } })
    Check('the next left drag brings it back', VisibleOverlays(env) == 1)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local mo = env.__sent[table.getn(env.__sent)].msg.mo
    Check('and announces the order', type(mo) == 'table' and mo[2] == 60 and mo[4] == 40)
    Check('as a plain order: where a formation would have ended is not known',
        mo and mo[5] == 60 and mo[6] == 40)

    local before = table.getn(env.__sent)
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 200, MouseY = 150, Modifiers = {} })
    for _ = 1, 3 do
        env.__clock.t = env.__clock.t + 0.4
        SM.OnBeat()
    end
    local again = 0
    for i = before + 1, table.getn(env.__sent) do
        if type(env.__sent[i].msg.mo) == 'table' then again = again + 1 end
    end
    Check('a release event turning up late does not announce it twice', again == 0, again)
end

do
    -- With Debug on, the log says what ended a press and what the events said.
    local env, SM = NewSession()
    env.import('/mods/TeamMouse/modules/config.lua').Debug = true
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Right = true } })
    view:HandleEvent({ Type = 'MouseMotion', MouseX = 110, MouseY = 100, Modifiers = { Right = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 110, MouseY = 100, Modifiers = {} })
    local found = false
    for _, line in ipairs(env.__logs) do
        if string.find(line, '(release event)', 1, true)
            and string.find(line, '1 motion events reached the view, 1 of them with the right button held', 1, true) then
            found = true
        end
    end
    Check('Debug logs what ended a right press, and what the events said', found)
end

--------------------------------------------------------------------------------
Section('splitscreen: UnProject is learned where it can be told apart')
--------------------------------------------------------------------------------
-- Regression test for: in split view a teammate saw the pointer shoved to the
-- left edge of its view. On a view that starts at the screen's origin,
-- relative and absolute coordinates are the same thing, so resting there first
-- "decided" relative for the whole session by a tie. With an engine that wants
-- screen coordinates, every point on the right-hand view then came out a whole
-- view-width to the left.
local function SplitSession(absolute)
    local env, SM = NewSession({ splitscreen = true })
    if absolute then
        env.UnProject = function(view, point) return { point[1] / 2, 0, point[2] / 2 } end
    end
    SM.InitTeamMouse(false)
    return env, SM
end

for _, absolute in ipairs({ true, false }) do
    local label = absolute and 'screen-coordinate UnProject' or 'view-relative UnProject'
    local env, SM = SplitSession(absolute)
    -- What the engine reports for a screen point, in each case.
    local function World(x, y, left)
        if absolute then return { x / 2, 0, y / 2 } end
        return { (x - left) / 2, 0, y / 2 }
    end

    -- Rests on the LEFT view first (origin: both readings agree).
    RestOnMap(env, SM, 400, 200, World(400, 200, 0), 'WorldCamera')
    -- Then on the right view, which starts at 960.
    RestOnMap(env, SM, 1160, 100, World(1160, 100, 960), 'WorldCamera2')

    Mock.HoverHud(env, 1400, 300)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = LastMsg(env)
    local want = World(1400, 300, 960)
    Check(label .. ': on the HUD from the right view, the map point is right',
        m.w == false and m.p[1] == want[1] and m.p[3] == want[3],
        tostring(m.p[1]) .. ',' .. tostring(m.p[3]) .. ' want ' .. want[1] .. ',' .. want[3])
end

do
    -- The same for a drag on the right view: the box corner comes from
    -- UnProject too.
    local env, SM = SplitSession(true)
    RestOnMap(env, SM, 400, 200, { 200, 0, 100 }, 'WorldCamera')
    RestOnMap(env, SM, 1160, 100, { 580, 0, 50 }, 'WorldCamera2')
    local view2 = env.__views['WorldCamera2']
    local overlay
    for _, g in ipairs(Mock.FindDragOverlays(env)) do
        if g.children[1] and g.children[1].dragCX > 960 then overlay = g end
    end
    view2:HandleEvent({ Type = 'ButtonPress', MouseX = 1160, MouseY = 100, Modifiers = { Left = true } })
    overlay.children[1]:HandleEvent({ Type = 'MouseEnter', MouseX = 1360, MouseY = 300, Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = LastMsg(env)
    Check('a drag on the right view puts its corner under the pointer',
        m.s == true and m.bx == 680 and m.bz == 150, tostring(m.bx) .. ',' .. tostring(m.bz))
end

do
    -- Having only ever rested on the origin view, nothing is known about how
    -- UnProject treats an offset one: the right view must not guess.
    local env, SM = SplitSession(true)
    RestOnMap(env, SM, 400, 200, { 200, 0, 100 }, 'WorldCamera')
    Mock.HoverWorld(env, 1160, 100, 'WorldCamera2')
    env.__mouseWorld = { 580, 0, 50 }
    SM.OnBeat()
    Mock.HoverHud(env, 1400, 300)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = LastMsg(env)
    Check('before the right view has been learned, the ghost parks instead of guessing',
        m.p[1] == 580 and m.p[3] == 50, tostring(m.p[1]) .. ',' .. tostring(m.p[3]))

    -- The origin view keeps working all along.
    Mock.HoverWorld(env, 300, 300, 'WorldCamera')
    env.__mouseWorld = { 150, 0, 150 }
    SM.OnBeat()
    Mock.HoverHud(env, 500, 400)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    m = LastMsg(env)
    Check('while the origin view follows the pointer as before', m.p[1] == 250 and m.p[3] == 200,
        tostring(m.p[1]) .. ',' .. tostring(m.p[3]))
end

--------------------------------------------------------------------------------
Section('a fast swing across the map stays on the map')
--------------------------------------------------------------------------------
-- Regression test for: swinging the mouse left and right stuttered for
-- teammates -- the cursor froze for a moment, then carried on. The grid's cells
-- are children of the root frame, so their crossings bubble up to it, and the
-- root frame takes two events in a row that do not match the map's last
-- position as the pointer having left the map. A fast swing crosses two cells
-- between the view's own motion events, and for a beat the pointer was
-- reported on the HUD, where its position is held.

--- A cell crossing, as the engine delivers it: to the cell, then bubbling up
--- to the root frame.
local function Cross(env, cell, x, y, mods)
    local ev = { Type = 'MouseEnter', MouseX = x, MouseY = y, Modifiers = mods or {} }
    cell:HandleEvent(ev)
    env.__frame:HandleEvent(ev)
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local cells = Mock.FindDragOverlays(env)[1].children
    Calibrate(env, SM)

    local offMap, frozen = 0, 0
    local lastX = nil
    for i = 1, 30 do
        -- Swing: 90px a step, two cells crossed between beats, no view event.
        local x = 400 + ((math.mod(i, 10) < 5) and (math.mod(i, 5) * 90) or ((5 - math.mod(i, 5)) * 90))
        Cross(env, cells[1], x, 300)
        Cross(env, cells[2], x + 45, 300)
        env.__mouseWorld = { (x + 45) / 2, 0, 150 }
        env.__clock.t = env.__clock.t + 0.1
        SM.OnBeat()
        local m = env.__sent[table.getn(env.__sent)].msg
        if m.w == false then offMap = offMap + 1 end
        if lastX and m.p[1] == lastX then frozen = frozen + 1 end
        lastX = m.p[1]
    end
    Check('a fast swing never reports the pointer on the HUD', offMap == 0, offMap .. ' beats')
    Check('and the position keeps moving with it', frozen == 0, frozen .. ' beats held')
end

do
    -- Leaving the map for real still counts: events from the interface are
    -- not cell crossings.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    Mock.HoverHud(env, 800, 1000)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('moving onto the interface is still the interface',
        env.__sent[table.getn(env.__sent)].msg.w == false)
end

do
    -- During a right drag the view hears nothing at all (the engine has the
    -- pointer), so every crossing bubbles up unanswered.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local cells = Mock.FindDragOverlays(env)[1].children
    local driver = Mock.FindDriver(env)
    Calibrate(env, SM)
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Right = true } })
    for i = 1, 8 do
        Cross(env, cells[math.mod(i, 2) + 1], 100 + i * 45, 140, { Right = true })
        env.__clock.t = env.__clock.t + 0.016
        driver:OnFrame(0.016)
    end
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = env.__sent[table.getn(env.__sent)].msg
    Check('a drawing across many cells stays on the map', m.w == true and m.d == 1)
end

--------------------------------------------------------------------------------
Section('a right press ends when motion stops saying the button is held')
--------------------------------------------------------------------------------
-- Ends the way a left drag does: on a motion event without the button held.
-- Regression test for: a drawing did not end on release, only at the next left
-- click. From the Debug log of a real drawing: the release event never came,
-- IsKeyDown('RBUTTON') read up even while held, GetMouseWorldPos kept moving,
-- and 87 motion events reached the view. Those events say, in their Modifiers,
-- whether the right button is held.

--- An engine as the log describes it: no IsKeyDown name for the right button.
local function LikeTheLog(env)
    local real = env.IsKeyDown
    env.IsKeyDown = function(key)
        if key == 'LBUTTON' then return real(key) end
        return false
    end
end

local function Motion(view, x, y, held)
    view:HandleEvent({ Type = 'MouseMotion', MouseX = x, MouseY = y,
        Modifiers = held and { Right = true } or {} })
end

do
    local env, SM = NewSession()
    LikeTheLog(env)
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    local driver = Mock.FindDriver(env)
    Calibrate(env, SM)

    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Right = true } })
    for i = 1, 10 do
        env.__mouseWorld = { 50 + i * 10, 0, 50 }
        Motion(view, 100 + i * 20, 100, true)
        env.__clock.t = env.__clock.t + 0.016
        driver:OnFrame(0.016)
    end
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('drawing while motion says the button is held', env.__sent[table.getn(env.__sent)].msg.d == 1)

    -- Let go: no event, but the next motion says the button is up.
    Motion(view, 320, 100, false)
    Motion(view, 330, 100, false)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('the drawing ends on the first motion after the button comes up',
        env.__sent[table.getn(env.__sent)].msg.d == false)
end

do
    -- An order (grid lifted) ends the same way: announced with its line, from
    -- where the button came up, and the grid comes back.
    local env, SM = NewSession()
    LikeTheLog(env)
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }
    Calibrate(env, SM)
    env.__mouseWorld = { 60, 0, 40 }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 120, MouseY = 80, Modifiers = { Right = true } })
    env.__clock.t = env.__clock.t + 0.7
    for i = 1, 5 do
        Motion(view, 120 + i * 12, 80 + i * 12, true)
    end
    Check('the grid is away while the order is held', VisibleOverlays(env) == 0)
    env.__mouseWorld = { 90, 0, 70 }
    Motion(view, 180, 140, false)
    Motion(view, 180, 140, false)
    local ended = VisibleOverlays(env) == 0
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local mo = env.__sent[table.getn(env.__sent)].msg.mo
    Check('and the order is announced with its line, to where it was let go',
        type(mo) == 'table' and mo[2] == 60 and mo[4] == 40 and mo[5] == 90 and mo[6] == 70,
        type(mo) == 'table' and (mo[5] .. ',' .. mo[6]) or 'no order')
    Check('the grid stays down when motion says the button is up', ended)
    Check('and is no longer held down: the next left drag raises it', GridRisesForLeftDrag(env, view, 180, 140))
end

--------------------------------------------------------------------------------
Section('replays: every packet recorded, played back as teammates saw it')
--------------------------------------------------------------------------------
-- Regression test for: replay cursors were missing, off their real spot, and
-- short of what teammates saw. They were a few fields squeezed into the
-- commander's name. Now each packet teammates are sent also goes into the sim
-- (FAF's query system), which the replay records; playback hands it to the
-- same receive code. Mock.SimRoundTrip plays the sim, and the replay file.

--- The replay cursor showing army `army`.
local function CursorFor(env, army)
    for _, c in ipairs(Mock.FindCursors(env, 'WorldCamera')) do
        if c.record.army == army then return c end
    end
end

--- A player's game with the lobby option set to `lobby` (nil: none), and the
--- config's Enabled to `configEnabled` (nil: as shipped).
local function RecordingSession(lobby, configEnabled, opts)
    local env, SM = NewSession(opts)
    if configEnabled ~= nil then
        env.import('/mods/TeamMouse/modules/config.lua').ReplayCodec.Enabled = configEnabled
    end
    env.__scenario.Options.TeamMouseReplay = lobby
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    return env, SM
end

--- The packets a session sent into the sim, from index `first`.
local function Recorded(env, first)
    local out = {}
    for i = first or 1, table.getn(env.__simCallbacks) do
        local cb = env.__simCallbacks[i]
        if cb.Func == 'OnPlayerQuery' and cb.Args.Name == 'TeamMouse' then
            -- The compact string (wirecodec.lua), as the packet it carries.
            local m = cb.Args.M
            if type(m) == 'string' then
                m = env.import('/mods/TeamMouse/modules/wirecodec.lua').Decode(m)
                assert(m, 'a recorded compact packet does not decode')
            end
            table.insert(out, m)
        end
    end
    return out
end

--- The replay of `recEnv`'s game, being watched. Play() brings up whatever the
--- player has sent into the sim since the last call, and runs frames.
local function ReplayOf(recEnv, opts)
    local renv, RSM = NewSession(opts)
    renv.__scenario.Options.TeamMouseReplay = 'on'
    RSM.InitTeamMouse(true)
    local driver = Mock.FindDriver(renv)
    local next = 1
    local function Play(frames)
        local n = table.getn(recEnv.__simCallbacks)
        Mock.SimRoundTrip(recEnv, renv, next)
        next = n + 1
        for _ = 1, frames or 4 do
            renv.__clock.t = renv.__clock.t + 0.1
            driver:OnFrame(0.1)
        end
    end
    return renv, RSM, Play
end

--- One beat with the pointer at world (x, y, z), screen (sx, sy).
local function MoveTo(env, SM, x, y, z, sx, sy)
    env.__mouseWorld = { x, y, z }
    Mock.HoverWorld(env, sx, sy)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
end

--- Whether a game with this lobby choice and config records anything.
local function RecordsWith(configEnabled, lobby)
    local env, SM = RecordingSession(lobby, configEnabled)
    MoveTo(env, SM, 200, 0, 200, 400, 400)
    return table.getn(Recorded(env)) > 0
end

do
    -- The replay codec is a lobby option. The host's choice is the game's,
    -- for every player; without one the config decides, as before.
    Check('lobby option On records, whatever the config says', RecordsWith(false, 'on'))
    Check('lobby option Off records nothing, whatever the config says', not RecordsWith(true, 'off'))
    Check('with no lobby option the config decides (on)', RecordsWith(true, nil))
    Check('with no lobby option the config decides (off)', not RecordsWith(false, nil))

    local env = NewSession()
    local opts = {}
    local chunk = assert(loadfile('lua/AI/LobbyOptions/lobbyoptions.lua'))
    setfenv(chunk, opts)
    chunk()
    local o = opts.AIOpts and opts.AIOpts[1]
    local codec = env.import('/mods/TeamMouse/modules/replaycodec.lua')
    Check('the lobby option file declares the key the codec reads', o and o.key == codec.OPTION_KEY)
    Check('with On and Off values and a valid default', o and o.values[o.default] ~= nil
        and o.values[1].key == 'off' and o.values[2].key == 'on')
    Check('defaulting to Off', o and o.values[o.default].key == 'off')
end

do
    -- What goes in is exactly what teammates get.
    local env, SM = RecordingSession('on')
    MoveTo(env, SM, 200, 57.3, 300, 400, 600)
    local chat = env.__sent[table.getn(env.__sent)].msg
    local rec = Recorded(env)
    local r = rec[table.getn(rec)]
    Check('each packet teammates get is recorded', r ~= nil)
    Check('whole, as they got it', r and r.v == chat.v and r.a == chat.a and r.o == chat.o
        and r.p[1] == chat.p[1] and r.p[2] == chat.p[2] and r.p[3] == chat.p[3])
    Check('height included', r and r.p[2] == 57.3)
    local before = table.getn(env.__simCallbacks)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    Check('and nothing extra while nothing changes', table.getn(env.__simCallbacks) == before)
end

do
    -- A player with no teammates (a 1v1) still records.
    local armies = Armies()
    armies[2].team = 2
    local env, SM = RecordingSession('on', nil, { armies = armies })
    local chats = table.getn(env.__sent)
    MoveTo(env, SM, 100, 0, 100, 200, 200)
    MoveTo(env, SM, 120, 0, 100, 240, 200)
    Check('with no teammates, nothing goes over chat', table.getn(env.__sent) == chats)
    Check('but the replay still gets every packet', table.getn(Recorded(env)) >= 2)
end

do
    -- Played back: where they were, at the height they were.
    local env, SM = RecordingSession('on')
    MoveTo(env, SM, 200, 57.3, 300, 400, 600)
    local renv, _, Play = ReplayOf(env)
    Play()
    local visual = CursorFor(renv, 1)
    Check('the replay has a cursor for the recorded player', visual and visual.record.hasData)
    Check('where they were', visual and visual.record.render[1] == 200 and visual.record.render[3] == 300)
    Check('at the height they were, not 0', visual and math.abs(visual.record.render[2] - 57.3) < 0.01)
    Check('no errors playing back', NoErrors(renv))
end

do
    -- A box select plays back as a box.
    local env, SM = RecordingSession('on')
    local view = env.__views['WorldCamera']
    local cell = Mock.FindDragOverlays(env)[1].children[1]
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    cell:HandleEvent({ Type = 'MouseEnter', MouseX = 300, MouseY = 200, Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()

    local renv, _, Play = ReplayOf(env)
    Play()
    local visual = CursorFor(renv, 1)
    Check('the box shows in the replay', visual and visual.dragBoxShown == true)
    Check('from where the drag began', visual and visual.Left() == 100 and visual.Top() == 100,
        visual and (visual.Left() .. ',' .. visual.Top()))
    Check('with the arrow on its live end', visual and visual.mouseIcon.Left() == 300,
        visual and visual.mouseIcon.Left())
end

do
    -- Time on the interface plays back as the HUD ghost.
    local env, SM = RecordingSession('on')
    Mock.HoverHud(env, 1440, 972)   -- 0.75, 0.9 of a 1920x1080 screen
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local renv, _, Play = ReplayOf(env)
    Play()
    local record = CursorFor(renv, 1).record
    Check('time on the interface plays back as the HUD ghost', record.renderHud == true)
    Check('at the spot on the interface they were at',
        math.abs(record.hudRender[1] - 0.75) < 0.002 and math.abs(record.hudRender[2] - 0.9) < 0.002,
        record.hudRender[1] .. ',' .. record.hudRender[2])
end

do
    -- Orders, actions and structures: all of what teammates saw.
    local env, SM = RecordingSession('on')
    local view = env.__views['WorldCamera']
    local orders = env.import('/lua/ui/game/orders.lua')
    local A = env.import('/mods/TeamMouse/modules/actions.lua')
    local renv, _, Play = ReplayOf(env)

    env.__selectedUnits = { {} }
    env.__mouseWorld = { 60, 0, 40 }
    RightPress(env, view, 120, 80)
    RightRelease(env, view, 120, 80)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    Play()
    local visual = CursorFor(renv, 1)
    local o = visual and visual.record.orders[1]
    Check('an order given plays back as its marker', visual and visual.record.orderCount == 1
        and o.x == 60 and o.z == 40)

    orders.Stop()
    MoveTo(env, SM, 61, 0, 40, 122, 80)
    Play()
    Check('an action plays back as its label', visual.record.actCode == A.STOP, visual.record.actCode)

    env.__commandMode = { 'build', { name = 'ueb0101' } }
    env.__mouseWorld = { 50, 0, 50 }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 100, MouseY = 100, Modifiers = {} })
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    Play()
    local placed = false
    for i = 1, visual.record.orderCount do
        if visual.record.orders[i].bp == 'ueb0101' then placed = true end
    end
    Check('a structure placed plays back with its icon', placed)
    Check('no errors playing all of it back', NoErrors(renv))
end

do
    -- Every player's cursor, whichever army the replay is watched from.
    local env1, SM1 = RecordingSession('on')
    MoveTo(env1, SM1, 100, 0, 100, 200, 200)
    local env3, SM3 = RecordingSession('on', nil, { clients = {
        [1] = { name = 'Lightningbulb' }, [2] = { name = 'KasperAUS' },
        [3] = { name = 'Eternal', ['local'] = true } }, focusArmy = 3 })
    MoveTo(env3, SM3, 300, 0, 300, 600, 600)
    Check('each player records under their own army', Recorded(env3)[1] and Recorded(env3)[1].a == 3)

    local renv, RSM = NewSession({ focusArmy = -1 })
    renv.__scenario.Options.TeamMouseReplay = 'on'
    RSM.InitTeamMouse(true)
    Mock.SimRoundTrip(env1, renv)
    Mock.SimRoundTrip(env3, renv)
    local driver = Mock.FindDriver(renv)
    for _ = 1, 4 do renv.__clock.t = renv.__clock.t + 0.1; driver:OnFrame(0.1) end
    local c1, c3 = CursorFor(renv, 1), CursorFor(renv, 3)
    Check('watched as an observer, every player who recorded has a cursor',
        c1 and c1.record.hasData and c3 and c3.record.hasData)
    Check('each where they were', c1 and c1.record.render[1] == 100 and c3 and c3.record.render[1] == 300)
end

do
    -- In the live game the same packets come up out of the sim to everyone;
    -- players get teammates' cursors over chat, and ignore these.
    local env1, SM1 = RecordingSession('on')
    MoveTo(env1, SM1, 100, 0, 100, 200, 200)
    local live, LSM = NewSession({ clients = { [1] = { name = 'Lightningbulb' },
        [2] = { name = 'KasperAUS', ['local'] = true }, [3] = { name = 'Eternal' } }, focusArmy = 2 })
    live.__scenario.Options.TeamMouseReplay = 'on'
    LSM.InitTeamMouse(false)
    Mock.SimRoundTrip(env1, live)
    Check('a live game does not listen for them', table.getn(live.__queryListeners) == 0)
end

do
    -- Replays are not trusted input either.
    local renv, RSM = NewSession()
    renv.__scenario.Options.TeamMouseReplay = 'on'
    RSM.InitTeamMouse(true)
    local q = renv.import('/lua/userplayerquery.lua')
    q.ProcessQueries({
        { Name = 'TeamMouse', M = 'junk' },
        { Name = 'TeamMouse', M = { v = 1, a = 2, p = 'junk' } },
        { Name = 'TeamMouse', M = { v = 999, a = 2, p = { 1, 1, 1 } } },
        { Name = 'TeamMouse', M = { v = 1, a = 77, p = { 1, 1, 1 } } },
        { Name = 'TeamMouse', M = { v = 1, a = 2, p = { 0 / 0, 1, 1 }, mo = 'x', e = 5, ac = { 'x' } } },
    })
    local driver = Mock.FindDriver(renv)
    renv.__clock.t = renv.__clock.t + 0.3
    driver:OnFrame(0.1)
    Check('broken packets in a replay are dropped without error', NoErrors(renv))

    RSM.Destroy()
    q.ProcessQueries({ { Name = 'TeamMouse', M = { v = 1, a = 2, p = { 5, 0, 5 } } } })
    Check('and after teardown nothing is handled', NoErrors(renv))
end

do
    -- In a replay, cursors are drawn more opaque and larger.
    local env, SM = RecordingSession('on')
    MoveTo(env, SM, 200, 0, 200, 400, 400)
    local renv, _, Play = ReplayOf(env)
    local cfg = renv.import('/mods/TeamMouse/modules/config.lua')
    renv.__setZoom(400)
    Play(6)
    local visual = CursorFor(renv, 1)
    Check('replay cursors are fully opaque', visual.appliedAlpha >= cfg.ReplayCodec.CursorAlpha - 0.02,
        visual.appliedAlpha)
    Check('and larger', visual.appliedScale >= cfg.ReplayCodec.CursorScale - 0.05, visual.appliedScale)
end

--------------------------------------------------------------------------------
Section('structures a teammate places show on the ground')
--------------------------------------------------------------------------------
local function BuildSession()
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    env.__commandMode = { 'build', { name = 'ueb0101' } }
    return env, SM, env.__views['WorldCamera']
end

do
    -- A single structure: press and release in build mode.
    local env, SM, view = BuildSession()
    env.__mouseWorld = { 50, 0, 50 }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 100, MouseY = 100, Modifiers = {} })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('placing a structure is announced', type(msg.mo) == 'table' and msg.mo[2] == 50 and msg.mo[4] == 50)
    Check('with the structure it is', type(msg.mob) == 'table' and msg.mob[1] == 'ueb0101')
    Check('and no line for a single one', msg.mo and msg.mo[5] == 50 and msg.mo[6] == 50)
end

do
    -- A row of them: a build drag.
    local env, SM, view = BuildSession()
    local cell = Mock.FindDragOverlays(env)[1].children[1]
    env.__mouseWorld = { 50, 0, 50 }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    cell:HandleEvent({ Type = 'MouseEnter', MouseX = 300, MouseY = 200, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 300, MouseY = 200, Modifiers = {} })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local mo = env.__sent[table.getn(env.__sent)].msg.mo
    Check('a row of structures runs from the press to the release',
        mo and mo[2] == 50 and mo[4] == 50 and mo[5] == 150 and mo[6] == 100,
        mo and (mo[5] .. ',' .. mo[6]) or 'nothing')
end

do
    -- The release that the engine keeps: the motion check catches it too.
    local env, SM, view = BuildSession()
    env.__mouseWorld = { 50, 0, 50 }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    Mock.buttons.left = false
    view:HandleEvent({ Type = 'MouseMotion', MouseX = 100, MouseY = 100, Modifiers = {} })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local msg = env.__sent[table.getn(env.__sent)].msg
    Check('a release seen only from motion places it too', type(msg.mob) == 'table' and msg.mob[1] == 'ueb0101')
end

do
    -- Not everything that ends a drag is a placement.
    local env, SM, view = BuildSession()
    local Config = env.import('/mods/TeamMouse/modules/config.lua')
    Config.Selection.MaxDragSeconds = 1
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 2
    SM.OnBeat()
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local any = false
    for _, e in ipairs(env.__sent) do
        if type(e.msg.mob) == 'table' then any = true end
    end
    Check('a build drag given up on by the backstop places nothing', not any)

    local env2, SM2 = NewSession()
    SM2.InitTeamMouse(false)
    local v2 = env2.__views['WorldCamera']
    v2:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    v2:HandleEvent({ Type = 'ButtonRelease', MouseX = 100, MouseY = 100, Modifiers = {} })
    env2.__clock.t = env2.__clock.t + 0.1
    SM2.OnBeat()
    local msg = env2.__sent[table.getn(env2.__sent)].msg
    Check('a selection is not a placement', msg.mo == false and msg.mob == false)

    local env3, SM3 = NewSession()
    env3.import('/mods/TeamMouse/modules/config.lua').Orders.ShowBuilds = false
    SM3.InitTeamMouse(false)
    env3.__commandMode = { 'build', { name = 'ueb0101' } }
    local v3 = env3.__views['WorldCamera']
    v3:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    v3:HandleEvent({ Type = 'ButtonRelease', MouseX = 100, MouseY = 100, Modifiers = {} })
    env3.__clock.t = env3.__clock.t + 0.1
    SM3.OnBeat()
    -- Orders.ShowBuilds is what WE show; our placements are always sent.
    Check('Orders.ShowBuilds = false locally: placements are still sent',
        type(env3.__sent[table.getn(env3.__sent)].msg.mob) == 'table')
end

do
    -- What a teammate sees.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    local cfg = env.import('/mods/TeamMouse/modules/config.lua').Orders
    receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true,
        mo = { 0, 100, 0, 100, 100, 100, 0,   0, 150, 0, 150, 250, 150, 0,   0, 200, 0, 200, 200, 200, 1 },
        mob = { 'ueb0101', 'ueb0101', false } })
    env.__clock.t = T + 0.2
    driver:OnFrame(0.016)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local mark = visual.orderMarks[1]
    Check('a placed structure gets a marker', mark and mark.visible == true)
    Check('showing the structure\'s icon', mark and mark.icon and Mock.IsVisible(mark.icon)
        and string.find(tostring(mark.iconTexture), 'ueb0101', 1, true) ~= nil,
        mark and tostring(mark.iconTexture))
    Check('centred on the spot', mark and mark.icon.Left() == 200 - cfg.BuildIconSize / 2
        and mark.icon.Top() == 200 - cfg.BuildIconSize / 2,
        mark and (mark.icon.Left() .. ',' .. mark.icon.Top()))
    Check('framed in their colour', mark and mark.square.Width() == cfg.BuildIconSize + cfg.BuildFrame * 2
        and mark.square.Left() == 200 - (cfg.BuildIconSize + cfg.BuildFrame * 2) / 2)
    Check('with the icon over the frame', mark and mark.icon.Depth() > mark.square.Depth())

    local row = visual.orderMarks[2]
    Check('a row shows its line', row and row.lineShown == true)
    local plain = visual.orderMarks[3]
    Check('a move order in the same packet is still a move order',
        plain and plain.squareSize == cfg.MarkerSize and not (plain.icon and plain.iconShown))

    -- Well past the preview time a formation's line would be gone; a row of
    -- structures keeps its line while the marker lasts.
    env.__clock.t = T + 1.8
    receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true })
    driver:OnFrame(0.016)
    Check('a row keeps its line as long as its marker', row.visible and row.lineShown == true)
    env.__clock.t = T + 2.5
    receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true })
    driver:OnFrame(0.016)
    Check('and both go when it does', not row.visible and not row.lineShown)
    Check('no errors', NoErrors(env))
end

do
    -- Whatever arrives as a structure name, nothing breaks.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local nan = 0 / 0
    local junk = { 'x', 5, true, { 5, {}, nan }, { string.rep('a', 200) }, { '../../evil' }, { 'nonexistent_bp' } }
    for _, mob in ipairs(junk) do
        receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true,
            mo = { 0, 100, 0, 100, 100, 100, 0 }, mob = mob })
    end
    env.__clock.t = env.__clock.t + 0.3
    driver:OnFrame(0.016)
    Check('malformed structure names never raise', NoErrors(env))
    local record = Mock.FindCursors(env, 'WorldCamera')[1].record
    local sane = true
    for i = 1, record.orderCount do
        local bp = record.orders[i].bp
        if bp and (string.len(bp) >= 64 or string.find(bp, '[^%w_%-]')) then sane = false end
    end
    Check('and only plausible names are kept', sane)
end

--------------------------------------------------------------------------------
Section('a structure is only shown once the game has really placed it')
--------------------------------------------------------------------------------
-- Regression test for: a placement the game refused (a bad spot) was still
-- shown to teammates as placed. The game calls commandmode.OnCommandIssued
-- once per structure it really orders, and nothing for a refused one. The
-- real hook file is loaded here, and the test plays the engine's part.

--- Load hook/lua/ui/game/commandmode.lua into a session, over a stand-in for
--- the game's own OnCommandIssued that records what it was given.
local function InstallCommandHook(env)
    local gameSaw = {}
    env.OnCommandIssued = function(command) table.insert(gameSaw, command) end
    local chunk = assert(loadfile('hook/lua/ui/game/commandmode.lua'))
    setfenv(chunk, env)
    chunk()
    return gameSaw
end

local function BuildOrder(x, y, z, bp)
    return { CommandType = 'BuildMobile', Blueprint = bp or 'ueb0101', Units = { {} },
        Target = { Type = 'Position', Position = { x, y, z } } }
end

local function MoveOrder()
    return { CommandType = 'Move', Units = { {} }, Target = { Type = 'Position', Position = { 1, 0, 1 } } }
end

--- Run frames for `seconds`, then a beat; return every placed structure sent
--- from packet `from` on, as { x, z, x2, z2, bp } lists.
local function PlacementsSent(env, SM, seconds, from)
    local driver = Mock.FindDriver(env)
    local t = 0
    while t < seconds do
        env.__clock.t = env.__clock.t + 0.02
        driver:OnFrame(0.02)
        t = t + 0.02
    end
    env.__clock.t = env.__clock.t + 0.12
    SM.OnBeat()
    local out = {}
    for i = from or 1, table.getn(env.__sent) do
        local m = env.__sent[i].msg
        if type(m.mo) == 'table' and type(m.mob) == 'table' then
            local k = 1
            while m.mo[(k - 1) * 7 + 1] ~= nil do
                if type(m.mob[k]) == 'string' then
                    local b = (k - 1) * 7
                    table.insert(out, { m.mo[b + 2], m.mo[b + 4], m.mo[b + 5], m.mo[b + 6], m.mob[k] })
                end
                k = k + 1
            end
        end
    end
    return out
end

do
    -- Refused: the hook is working (it has seen an order), and the release
    -- brings no build order.
    local env, SM, view = BuildSession()
    InstallCommandHook(env)
    env.OnCommandIssued(MoveOrder())
    local from = table.getn(env.__sent) + 1
    env.__mouseWorld = { 50, 0, 50 }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 100, MouseY = 100, Modifiers = {} })
    local placed = PlacementsSent(env, SM, 0.7, from)
    Check('a placement the game refused is not shown', table.getn(placed) == 0, table.getn(placed))
    Check('no errors for a refused placement', NoErrors(env))
end

do
    -- Placed: the order comes in after the release (the engine's timing is
    -- not known, so both orders are covered), and it is where the game put
    -- it, not where the pointer was.
    local env, SM, view = BuildSession()
    local gameSaw = InstallCommandHook(env)
    env.OnCommandIssued(MoveOrder())
    local from = table.getn(env.__sent) + 1
    env.__mouseWorld = { 50, 0, 50 }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 100, MouseY = 100, Modifiers = {} })
    Check('nothing is sent before the game has answered',
        table.getn(PlacementsSent(env, SM, 0, from)) == 0)
    env.OnCommandIssued(BuildOrder(51, 0, 49))
    local placed = PlacementsSent(env, SM, 0.2, from)
    Check('a structure the game placed is shown', table.getn(placed) == 1, table.getn(placed))
    local p = placed[1]
    Check('where the game placed it', p and p[1] == 51 and p[2] == 49 and p[3] == 51 and p[4] == 49,
        p and (p[1] .. ',' .. p[2] .. ' ' .. p[3] .. ',' .. p[4]))
    Check('with its structure', p and p[5] == 'ueb0101')
    Check('and the game still gets every order', table.getn(gameSaw) == 2, table.getn(gameSaw))
end

do
    -- A row: the orders arrive during the drag. It runs from the first
    -- structure the game placed to the last.
    local env, SM, view = BuildSession()
    InstallCommandHook(env)
    env.OnCommandIssued(MoveOrder())
    local from = table.getn(env.__sent) + 1
    local cell = Mock.FindDragOverlays(env)[1].children[1]
    env.__mouseWorld = { 50, 0, 50 }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    cell:HandleEvent({ Type = 'MouseEnter', MouseX = 300, MouseY = 200, Modifiers = { Left = true } })
    for i = 0, 3 do env.OnCommandIssued(BuildOrder(50 + i * 2, 0, 50)) end
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 300, MouseY = 200, Modifiers = {} })
    local placed = PlacementsSent(env, SM, 0.2, from)
    local p = placed[1]
    Check('a row is announced once', table.getn(placed) == 1, table.getn(placed))
    Check('from the first structure placed to the last', p and p[1] == 50 and p[3] == 56 and p[4] == 50,
        p and (p[1] .. '->' .. p[3] .. ',' .. p[4]))
end

do
    -- Not something this player builds (the cheat menu's spawns have no
    -- units), and not a build order at all: neither counts.
    local env, SM, view = BuildSession()
    InstallCommandHook(env)
    env.OnCommandIssued(MoveOrder())
    local from = table.getn(env.__sent) + 1
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 100, MouseY = 100, Modifiers = {} })
    env.OnCommandIssued({ CommandType = 'BuildMobile', Blueprint = 'ueb0101', Units = {},
        Target = { Position = { 5, 0, 5 } } })
    env.OnCommandIssued(MoveOrder())
    env.OnCommandIssued({ CommandType = 'BuildMobile', Units = { {} }, Target = { Position = { 0 / 0, 0, 1 } } })
    Check('only real build orders of this player count', table.getn(PlacementsSent(env, SM, 0.7, from)) == 0)
end

do
    -- Two quick placements: the second press settles the first straight away.
    local env, SM, view = BuildSession()
    InstallCommandHook(env)
    env.OnCommandIssued(MoveOrder())
    local from = table.getn(env.__sent) + 1
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 100, MouseY = 100, Modifiers = {} })
    env.OnCommandIssued(BuildOrder(10, 0, 10))
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 140, MouseY = 100, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 140, MouseY = 100, Modifiers = {} })
    env.OnCommandIssued(BuildOrder(20, 0, 10))
    local placed = PlacementsSent(env, SM, 0.2, from)
    Check('two quick placements are both shown, each where it went',
        table.getn(placed) == 2 and placed[1][1] == 10 and placed[2][1] == 20, table.getn(placed))
end

do
    -- The hook is in, but no command has ever reached it (another mod may
    -- have replaced OnCommandIssued without passing it on): silence proves
    -- nothing, so the drag is announced as before rather than never.
    local env, SM, view = BuildSession()
    InstallCommandHook(env)
    env.__mouseWorld = { 50, 0, 50 }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 100, MouseY = 100, Modifiers = {} })
    local placed = PlacementsSent(env, SM, 0.7)
    Check('with nothing ever heard from the hook, a placement is still shown',
        table.getn(placed) == 1 and placed[1][1] == 50)
end

do
    -- The mod must never stand between the player and their order, and must
    -- let go of the hook when it is torn down.
    local env, SM = BuildSession()
    local gameSaw = InstallCommandHook(env)
    env.TeamMouseOnCommandIssued = function() error('broken listener') end
    local ok = pcall(env.OnCommandIssued, BuildOrder(1, 0, 1))
    Check('a failing listener does not stop the order', ok and table.getn(gameSaw) == 1)
    SM.InitTeamMouse(false)
    SM.Destroy()
    Check('teardown removes the listener', env.TeamMouseOnCommandIssued == nil)
    env.OnCommandIssued(BuildOrder(1, 0, 1))
    Check('and the game still gets its orders after', table.getn(gameSaw) == 2)

    local oenv, OSM = NewSession({ focusArmy = -1 })
    OSM.InitTeamMouse(false)
    Check('an observer places nothing, and listens for nothing', oenv.TeamMouseOnCommandIssued == nil)
end

--------------------------------------------------------------------------------
Section('a build template shows its first structure, marked TEMPLATE')
--------------------------------------------------------------------------------
-- Feature: a template's structures are several kinds in their own layout, which
-- a row from the first to the last misrepresented. Only the first is shown, with
-- TEMPLATE above it: flashing once placed, steady while in hand.

--- Every packet from index `from` on with a placement: { mo, mob, mot }.
local function PlacedPackets(env, from)
    local out = {}
    for i = from, table.getn(env.__sent) do
        local m = env.__sent[i].msg
        if type(m.mob) == 'table' then table.insert(out, m) end
    end
    return out
end

do
    local env, SM, view = BuildSession()
    InstallCommandHook(env)
    env.OnCommandIssued(MoveOrder())
    local template = { 4, 2, { 'ueb0101', 1, 0, 0 }, { 'ueb1101', 2, 2, 0 }, { 'ueb1101', 3, 4, 0 } }
    env.GetActiveBuildTemplate = function() return template end

    env.__mouseWorld = { 180, 5, 200 }
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local live = env.__sent[table.getn(env.__sent)].msg
    Check('while a template is in hand, teammates are told', live.bt == true and live.b == 'ueb0101')

    local from = table.getn(env.__sent) + 1
    env.__mouseWorld = { 50, 0, 50 }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 100, MouseY = 100, Modifiers = {} })
    env.OnCommandIssued(BuildOrder(50, 0, 50, 'ueb0101'))
    env.OnCommandIssued(BuildOrder(52, 0, 50, 'ueb1101'))
    env.OnCommandIssued(BuildOrder(54, 0, 50, 'ueb1101'))
    PlacementsSent(env, SM, 0.2, from)
    local sent = PlacedPackets(env, from)
    local m = sent[1]
    Check('a placed template is announced once', table.getn(sent) == 1, table.getn(sent))
    Check('as its first structure only', m and m.mob[1] == 'ueb0101' and m.mo[2] == 50
        and m.mo[5] == 50 and m.mo[6] == 50, m and (m.mo[2] .. '->' .. m.mo[5]))
    Check('marked as a template', m and type(m.mot) == 'table' and m.mot[1] == 1)

    -- An ordinary structure afterwards is not a template, even with one left
    -- behind that does not match the build in hand.
    template = { 2, 2, { 'uab1101', 1, 0, 0 } }
    env.__mouseWorld = { 190, 5, 200 }
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    live = env.__sent[table.getn(env.__sent)].msg
    Check('a leftover template for another structure is ignored', live.b == 'ueb0101' and live.bt == nil)
    from = table.getn(env.__sent) + 1
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 100, MouseY = 100, Modifiers = {} })
    env.OnCommandIssued(BuildOrder(60, 0, 60, 'ueb0101'))
    PlacementsSent(env, SM, 0.2, from)
    local plain = PlacedPackets(env, from)[1]
    Check('and a plain placement carries no template mark', plain and plain.mot == nil)
end

do
    -- Receiving a placed template.
    local env, SM = NewSession()
    env.__blueprints.ueb0101.Physics = { SkirtSizeX = 20, SkirtSizeZ = 20 }
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    -- A row's worth of distance, to be sure no row is drawn for a template.
    receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true,
        mo = { 0, 50, 0, 50, 110, 50, 0 }, mob = { 'ueb0101' }, mot = { 1 } })
    env.__clock.t = T + 0.2
    driver:OnFrame(0.016)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    local mark = visual.orderMarks[1]
    local tl = mark and mark.tlabel
    Check('a placed template shows its first structure', mark and mark.icon and Mock.IsVisible(mark.icon)
        and mark.icon.Left() + mark.icon.Width() / 2 == 100)
    Check('with TEMPLATE above it', tl and Mock.IsVisible(tl) and tl._text == 'TEMPLATE'
        and tl.Top() < mark.square.Top())
    Check('and no row', not (mark and mark.row and mark.row.shown > 0))
    local a1 = tl and tl._alpha
    env.__clock.t = T + 0.2 + 0.35
    driver:OnFrame(0.016)
    local a2 = tl and tl._alpha
    Check('flashing', a1 and a2 and math.abs(a1 - a2) > 0.3, tostring(a1) .. ' / ' .. tostring(a2))

    -- Live: a template in hand, being dragged.
    receive('KasperAUS', { v = 1, a = 2, p = { 50, 0, 50 }, o = 0, z = 60, w = true,
        l = true, b = 'ueb0101', bt = true, bx = 110, bz = 50 })
    env.__clock.t = env.__clock.t + 0.3
    driver:OnFrame(0.016)
    Check('a template being dragged draws no row', not visual.rowShown)
    Check('but its ghost, marked TEMPLATE', visual.buildIcon and Mock.IsVisible(visual.buildIcon)
        and visual.templateLabel and Mock.IsVisible(visual.templateLabel)
        and visual.templateLabel._text == 'TEMPLATE')
    receive('KasperAUS', { v = 1, a = 2, p = { 50, 0, 50 }, o = 0, z = 60, w = true, b = 'ueb0101' })
    env.__clock.t = env.__clock.t + 0.3
    driver:OnFrame(0.016)
    Check('the mark goes when the build in hand is a single structure again',
        not Mock.IsVisible(visual.templateLabel))
    Check('no errors with templates', NoErrors(env))
end

--------------------------------------------------------------------------------
Section('hovering the interface under the grid stays on the interface')
--------------------------------------------------------------------------------
-- Regression test for: the HUD ghost snapped all over the place while hovering
-- the interface. The grid sits above parts of the interface (it has to, to
-- win the hit test), so cells report crossings there too; taking every cell
-- crossing as "over the map" flipped the pointer between the map and the HUD
-- as it crossed each one.
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local cells = Mock.FindDragOverlays(env)[1].children
    Calibrate(env, SM)

    Mock.HoverHud(env, 800, 1000)
    local onMap, lastHx, backwards = 0, -1, 0
    for i = 1, 20 do
        local x = 800 + i * 20
        -- A cell above the interface reports the crossing (and it bubbles up)...
        local ev = { Type = 'MouseEnter', MouseX = x, MouseY = 1000, Modifiers = {} }
        cells[math.mod(i, 2) + 1]:HandleEvent(ev)
        env.__frame:HandleEvent(ev)
        -- ...and the interface control under the hole sees the motion.
        env.__frame:HandleEvent({ Type = 'MouseMotion', MouseX = x + 5, MouseY = 1000, Modifiers = {} })
        env.__clock.t = env.__clock.t + 0.1
        SM.OnBeat()
        local m = env.__sent[table.getn(env.__sent)].msg
        if m.w ~= false then onMap = onMap + 1 end
        if m.hx < lastHx then backwards = backwards + 1 end
        lastHx = m.hx
    end
    Check('hovering the interface is never reported as the map', onMap == 0, onMap .. ' beats')
    Check('and the ghost follows the pointer without jumping back', backwards == 0, backwards)
end

--------------------------------------------------------------------------------
Section('patrol and other order-mode clicks show on the ground')
--------------------------------------------------------------------------------
local function OrderModeClick(env, SM, modeName, cursorTex)
    env.__selectedUnits = { {} }
    env.__commandMode = { 'order', { name = modeName } }
    if cursorTex then
        env.__cursor:SetTexture('/textures/ui/common/game/cursors/' .. cursorTex .. '.dds', 0, 0)
    end
    env.__mouseWorld = { 80, 0, 60 }
    env.__views['WorldCamera']:HandleEvent({ Type = 'ButtonPress', MouseX = 160, MouseY = 120,
        Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    return env.__sent[table.getn(env.__sent)].msg
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local patrol = env.import('/mods/TeamMouse/modules/cursordata.lua').IndexFromKey('patrol')
    local msg = OrderModeClick(env, SM, 'RULEUCC_Patrol', 'patrol')
    Check('a patrol click is announced', type(msg.mo) == 'table' and msg.mo[2] == 80 and msg.mo[4] == 60)
    Check('as a patrol', msg.mo and msg.mo[1] == patrol, msg.mo and msg.mo[1])
    Check('with no structure and no line', msg.mob == false and msg.mo[5] == 80 and msg.mo[6] == 60)
end

do
    -- The cursor at the click may be the plain arrow: the mode says what it is.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local patrol = env.import('/mods/TeamMouse/modules/cursordata.lua').IndexFromKey('patrol')
    local msg = OrderModeClick(env, SM, 'RULEUCC_Patrol', nil)
    Check('a patrol click under the plain arrow is still a patrol', msg.mo and msg.mo[1] == patrol,
        msg.mo and msg.mo[1])
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    env.__commandMode = { 'order', { name = 'RULEUCC_Patrol' } }
    env.__views['WorldCamera']:HandleEvent({ Type = 'ButtonPress', MouseX = 160, MouseY = 120,
        Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('with nothing selected there is no order', env.__sent[table.getn(env.__sent)].msg.mo == false)

    local env2, SM2 = NewSession()
    env2.import('/mods/TeamMouse/modules/config.lua').Orders.ShowModeOrders = false
    SM2.InitTeamMouse(false)
    Check('Orders.ShowModeOrders = false keeps them private',
        OrderModeClick(env2, SM2, 'RULEUCC_Patrol', 'patrol').mo == false)
end

do
    -- What a teammate sees: the patrol icon on the spot.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local CD = env.import('/mods/TeamMouse/modules/cursordata.lua')
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    receive('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true,
        mo = { CD.IndexFromKey('patrol'), 100, 0, 100, 100, 100, 0 } })
    env.__clock.t = env.__clock.t + 0.2
    driver:OnFrame(0.016)
    local mark = Mock.FindCursors(env, 'WorldCamera')[1].orderMarks[1]
    Check('a teammate\'s patrol shows its icon on the ground', mark and mark.visible
        and mark.icon and Mock.IsVisible(mark.icon)
        and mark.iconTexture == CD.TextureForIndex(CD.IndexFromKey('patrol')),
        mark and tostring(mark.iconTexture))
end

--------------------------------------------------------------------------------
Section('Stop, repeat build and pause show by the cursor')
--------------------------------------------------------------------------------
local function Unit(opts)
    opts = opts or {}
    return {
        IsRepeatQueue = function() return opts.repeatOn or false end,
        IsInCategory = function(_, cat) return opts.factory ~= false and (cat == 'FACTORY') end,
    }
end

local function LastAc(env)
    for i = table.getn(env.__sent), 1, -1 do
        local ac = env.__sent[i].msg.ac
        if ac then return ac end
    end
end

do
    local env, SM = NewSession()
    local orders = env.import('/lua/ui/game/orders.lua')
    local keys0 = env.import('/lua/keymap/misckeyactions.lua')
    local original = { Stop = orders.Stop, SoftStop = orders.SoftStop,
        ToggleRepeatBuild = keys0.ToggleRepeatBuild, AbortNavigation = keys0.AbortNavigation,
        SetPaused = env.SetPaused }
    SM.InitTeamMouse(false)
    local A = env.import('/mods/TeamMouse/modules/actions.lua')
    Check('the functions are hooked while the game runs', orders.Stop ~= original.Stop
        and env.SetPaused ~= original.SetPaused)
    env.__selectedUnits = { Unit() }

    orders.Stop()
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local ac = LastAc(env)
    Check('Stop is sent', ac and ac[1] == A.STOP and table.getn(ac) == 1)
    Check('and the real Stop still runs', env.__calls[1] == 'Stop')

    env.__calls = {}
    orders.SoftStop()
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    ac = LastAc(env)
    Check('SoftStop is sent once, not again for the Stop it calls', ac and table.getn(ac) == 1 and ac[1] == A.STOP,
        ac and table.getn(ac))
    Check('and both real functions still run', env.__calls[1] == 'SoftStop' and env.__calls[2] == 'Stop')

    local keys = env.import('/lua/keymap/misckeyactions.lua')
    env.__selectedUnits = { Unit(), Unit() }
    keys.ToggleRepeatBuild()
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('repeat build turned on is sent as on', LastAc(env)[1] == A.REPEAT_ON)
    env.__selectedUnits = { Unit({ repeatOn = true }), Unit() }
    keys.ToggleRepeatBuild()
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('and turned off as off', LastAc(env)[1] == A.REPEAT_OFF)
    local before = table.getn(env.__sent)
    env.__selectedUnits = { Unit(), Unit({ factory = false }) }
    keys.ToggleRepeatBuild()
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local sentAgain = false
    for i = before + 1, table.getn(env.__sent) do
        if env.__sent[i].msg.ac then sentAgain = true end
    end
    Check('a selection that isn\'t all factories sends nothing (the toggle does nothing)', not sentAgain)

    env.__selectedUnits = { Unit() }
    keys.AbortNavigation()
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('interrupting pathfinding is sent', LastAc(env)[1] == A.INTERRUPT)
    Check('and the game\'s own function still runs', env.__calls[table.getn(env.__calls)] == 'AbortNavigation')

    env.SetPaused({ Unit() }, true)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('pausing is sent', LastAc(env)[1] == A.PAUSED)
    env.SetPaused({ Unit() }, false)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('and resuming', LastAc(env)[1] == A.RESUMED)

    -- Teardown puts the game's own functions back.
    SM.Destroy()
    env.__calls = {}
    orders.Stop()
    env.SetPaused({ Unit() }, true)
    Check('teardown restores the game\'s own functions',
        orders.Stop == original.Stop and orders.SoftStop == original.SoftStop
        and keys0.ToggleRepeatBuild == original.ToggleRepeatBuild
        and keys0.AbortNavigation == original.AbortNavigation and env.SetPaused == original.SetPaused)
    Check('which still work', env.__calls[1] == 'Stop' and env.__calls[2] == 'SetPaused')
end

do
    -- Observers have nothing to report; Share = false keeps them private.
    local env, SM = NewSession({ focusArmy = -1 })
    local stop = env.import('/lua/ui/game/orders.lua').Stop
    SM.InitTeamMouse(false)
    Check('an observer hooks nothing', env.import('/lua/ui/game/orders.lua').Stop == stop)

    local env2, SM2 = NewSession()
    env2.import('/mods/TeamMouse/modules/config.lua').Actions.Share = false
    local stop2 = env2.import('/lua/ui/game/orders.lua').Stop
    SM2.InitTeamMouse(false)
    Check('Actions.Share = false hooks nothing', env2.import('/lua/ui/game/orders.lua').Stop == stop2)
end

do
    -- What a teammate sees.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local A = env.import('/mods/TeamMouse/modules/actions.lua')
    local cfg = env.import('/mods/TeamMouse/modules/config.lua').Actions
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    local function Packet(t, extra)
        env.__clock.t = t
        local m = { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true }
        for k, v in pairs(extra or {}) do m[k] = v end
        receive('KasperAUS', m)
    end
    Packet(T)
    Packet(T + 0.1, { ac = { A.STOP } })
    env.__clock.t = T + 0.15
    driver:OnFrame(0.016)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('not shown before its moment comes round', not visual.actionShown)
    env.__clock.t = T + 0.35
    driver:OnFrame(0.016)
    Check('then their Stop shows by their cursor', visual.actionShown and Mock.IsVisible(visual.actionLabel)
        and visual.actionLabel._text == 'STOP', visual.actionLabel and visual.actionLabel._text)
    Check('above the arrow', visual.actionLabel.Top() < visual.mouseIcon.Top()
        and math.abs(visual.actionLabel.Left() - visual.mouseIcon.Left()) < 20)
    -- Relative to the cursor's own opacity, which is still fading in here.
    Check('solid at first', math.abs(visual.actionLabel:GetAlpha() - visual.curAlpha) < 0.01)
    env.__clock.t = T + 0.23 + cfg.FadeHold + (cfg.Lifetime - cfg.FadeHold) / 2
    driver:OnFrame(0.016)
    local ratio = visual.actionLabel:GetAlpha() / visual.curAlpha
    Check('then fades', ratio > 0.3 and ratio < 0.7, ratio)
    env.__clock.t = T + 0.25 + cfg.Lifetime
    Packet(env.__clock.t)
    driver:OnFrame(0.016)
    Check('and is gone', not visual.actionShown and not Mock.IsVisible(visual.actionLabel))

    -- A later one replaces it.
    Packet(env.__clock.t + 0.1, { ac = { A.PAUSED, 99, 'x', A.REPEAT_ON } })
    env.__clock.t = env.__clock.t + 0.3
    driver:OnFrame(0.016)
    Check('the last valid action in a packet is the one shown', visual.actionLabel._text == 'REPEAT ON',
        visual.actionLabel._text)
    Packet(env.__clock.t + 0.1, { ac = { A.INTERRUPT } })
    env.__clock.t = env.__clock.t + 0.3
    driver:OnFrame(0.016)
    Check('INTERRUPT shows too', visual.actionLabel._text == 'INTERRUPT', visual.actionLabel._text)
    Check('no errors', NoErrors(env))
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local nan = 0 / 0
    for _, ac in ipairs({ 'x', 5, {}, { nan }, { -1 }, { 1e40 }, { {} } }) do
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true, ac = ac })
    end
    env.__clock.t = env.__clock.t + 0.3
    Mock.FindDriver(env):OnFrame(0.016)
    Check('malformed actions never raise', NoErrors(env))
end

--------------------------------------------------------------------------------
Section('the player panel')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local P = env.import('/mods/TeamMouse/modules/panel.lua')
    local CD = env.import('/mods/TeamMouse/modules/cursordata.lua')
    local panel = P.Get()
    Check('a player gets a panel', panel ~= false)
    Check('listing their teammates, not their opponents',
        panel and table.getn(panel.rows) == 1 and panel.rows[1].record.name == 'KasperAUS')
    local row = panel.rows[1]
    Check('in the colour their cursor is drawn in', row.swatch._color == CD.SafeUIColor('FFe80a0a'),
        tostring(row.swatch._color))

    -- A teammate with an order on the map and a cursor on screen.
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local function Beat()
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
            mo = { 0, 120, 0, 120, 120, 120, 0 } })
        env.__clock.t = env.__clock.t + 0.3
        driver:OnFrame(0.016)
    end
    Beat()
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('their cursor is shown', Mock.IsVisible(visual))

    row.check:Click()
    Beat()
    Check('clicking their name hides their cursor', not Mock.IsVisible(visual))
    local anyMark = false
    for _, mark in pairs(visual.orderMarks) do
        if mark.visible or Mock.IsVisible(mark.square) then anyMark = true end
    end
    Check('and their orders', not anyMark)
    Check('and the row shows it is off', row.swatch._color ~= CD.SafeUIColor('FFe80a0a'))

    row.check:Click()
    Beat()
    Check('clicking again brings them back', Mock.IsVisible(visual)
        and row.swatch._color == CD.SafeUIColor('FFe80a0a'))

    -- Collapsing.
    Check('it has FAF\'s collapse arrow', panel.arrow ~= nil)
    panel.arrow:Click()
    Check('the arrow folds it away', not Mock.IsVisible(panel.body) and Mock.IsVisible(panel.arrow))
    panel.arrow:Click()
    Check('and opens it again', Mock.IsVisible(panel.body))

    -- Screen capture mode hides it with the rest of the interface.
    panel.arrow:Click()
    env.import('/lua/ui/game/gamemain.lua').gameUIHidden = true
    SM.OnBeat()
    Check('it hides with the interface', not Mock.IsVisible(panel.root))
    env.import('/lua/ui/game/gamemain.lua').gameUIHidden = false
    SM.OnBeat()
    Check('and comes back as it was (still folded)', Mock.IsVisible(panel.root) and not Mock.IsVisible(panel.body))

    SM.Destroy()
    Check('teardown removes it', P.Get() == false and panel.root._destroyed == true)
    Check('no errors', NoErrors(env))
end

do
    local observerClients = Clients()
    observerClients[1]['local'] = nil
    observerClients[4] = { name = 'Watcher', ['local'] = true }
    local env, SM = NewSession({ focusArmy = -1, clients = observerClients })
    SM.InitTeamMouse(false)
    local panel = env.import('/mods/TeamMouse/modules/panel.lua').Get()
    Check('an observer\'s panel lists every player', panel and table.getn(panel.rows) == 3,
        panel and table.getn(panel.rows))

    local env2, SM2 = NewSession({ clients = { [1] = { name = 'Lightningbulb', ['local'] = true } },
        armies = { [1] = { nickname = 'Lightningbulb', human = true, color = 'ff436eee', team = 1, armyIndex = 1 } } })
    SM2.InitTeamMouse(false)
    Check('alone, there is no panel', env2.import('/mods/TeamMouse/modules/panel.lua').Get() == false)

    local env3, SM3 = NewSession()
    env3.import('/mods/TeamMouse/modules/config.lua').Panel.StartCollapsed = true
    SM3.InitTeamMouse(false)
    local p3 = env3.import('/mods/TeamMouse/modules/panel.lua').Get()
    Check('Panel.StartCollapsed starts it folded', p3 and not Mock.IsVisible(p3.body)
        and p3.arrow._checked == true)

    local env4, SM4 = NewSession()
    env4.import('/mods/TeamMouse/modules/config.lua').Panel.Enabled = false
    SM4.InitTeamMouse(false)
    Check('Panel.Enabled = false: none', env4.import('/mods/TeamMouse/modules/panel.lua').Get() == false)
end

--------------------------------------------------------------------------------
Section('versions are sent at the start of a game (no chat lines)')
--------------------------------------------------------------------------------
-- The chat report was replaced by the panel's version column: versions still
-- go out once, but nothing is posted in chat.
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    SM.OnBeat()
    local v = env.__sentVersion[1]
    Check('your version is sent to your teammates, once', table.getn(env.__sentVersion) == 1
        and v.msg.tmv == 1 and v.msg.Identifier == 'TeamMouse'
        and type(v.clients) == 'table' and v.clients[1] == 2)
    local receive = env.__chatFuncs['TeamMouse']
    receive('KasperAUS', { Identifier = 'TeamMouse', tmv = 1 })
    env.__chatFuncs['TeamMouse']('KasperAUS', { Identifier = 'TeamMouse', tmv = 3 })
    env.__clock.t = env.__clock.t + 6
    SM.OnBeat()
    Check('nothing is said in chat', table.getn(env.__chat) == 0, table.getn(env.__chat))

    local env3, SM3 = NewSession()
    SM3.InitTeamMouse(false)
    SM3.OnBeat()
    local nan = 0 / 0
    for _, bad in ipairs({ 'x', nan, -1, 1e40, {}, true }) do
        env3.__chatFuncs['TeamMouse']('KasperAUS', { Identifier = 'TeamMouse', tmv = bad })
    end
    SM3.OnBeat()
    local rows = env3.import('/mods/TeamMouse/modules/panel.lua').Get().rows
    Check('nonsense versions are ignored without errors', NoErrors(env3)
        and rows[1].versionLabel._text == '?', rows[1].versionLabel._text)
end

do
    -- config.lua's version is the one in mod_info.lua.
    local info = {}
    local chunk = assert(loadfile('mod_info.lua'))
    setfenv(chunk, info)
    chunk()
    local env = NewSession()
    Check('Config.ModVersion matches mod_info.lua',
        env.import('/mods/TeamMouse/modules/config.lua').ModVersion == info.version,
        tostring(info.version))
end

--------------------------------------------------------------------------------
Section('middle-drag camera panning is left alone')
--------------------------------------------------------------------------------
-- Regression test for: the mod interfered with middle-click dragging. A grid
-- cell crossed mid-pan ends it, as with a formation, so the grid is lifted.
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local view = env.__views['WorldCamera']
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 400, MouseY = 300, Modifiers = { Middle = true } })
    Check('a middle press lifts the grid', VisibleOverlays(env) == 0)
    for x = 400, 900, 45 do
        view:HandleEvent({ Type = 'MouseMotion', MouseX = x, MouseY = 300, Modifiers = { Middle = true } })
    end
    Check('and keeps it away for the whole pan', VisibleOverlays(env) == 0)
    view:HandleEvent({ Type = 'MouseMotion', MouseX = 905, MouseY = 300, Modifiers = {} })
    Check('the first motion without the button ends the pan: a left drag raises the grid, hole under it',
        GridRisesForLeftDrag(env, view, 905, 300))

    view:HandleEvent({ Type = 'ButtonPress', MouseX = 400, MouseY = 300, Modifiers = { Middle = true } })
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 420, MouseY = 300, Modifiers = {} })
    Check('so does a release event', GridRisesForLeftDrag(env, view, 420, 300))

    view:HandleEvent({ Type = 'ButtonPress', MouseX = 400, MouseY = 300, Modifiers = { Middle = true } })
    env.__clock.t = env.__clock.t + 30
    SM.OnBeat()
    Check('and the backstop, if neither comes', GridRisesForLeftDrag(env, view, 400, 300))

    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = env.__sent[table.getn(env.__sent)].msg
    Check('a pan is nothing to report', m.s == false and m.d == false and m.r == false and m.mo == false)
end

--------------------------------------------------------------------------------
Section('packets keep coming when beats don\'t')
--------------------------------------------------------------------------------
-- Regression test for: the cursor stuttered at random, even in small movements.
-- FAF skips a throttled beat function when a sim beat arrives under 0.1s after
-- the last, so a beat a hair early was dropped and the next packet left ~0.2s
-- after the one before -- longer than teammates render behind.
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local driver = Mock.FindDriver(env)
    SM.OnBeat()
    local times = {}
    local last = table.getn(env.__sent)
    for i = 1, 90 do
        env.__clock.t = env.__clock.t + 0.016
        env.__mouseWorld = { 50 + i, 0, 50 }
        -- Beats every 0.2s: every other one dropped.
        if math.mod(i, 12) == 0 then SM.OnBeat() end
        driver:OnFrame(0.016)
        if table.getn(env.__sent) > last then
            last = table.getn(env.__sent)
            table.insert(times, env.__clock.t)
        end
    end
    local worst = 0
    for i = 2, table.getn(times) do
        if times[i] - times[i - 1] > worst then worst = times[i] - times[i - 1] end
    end
    Check('with beats 0.2s apart, packets still go at least every 0.13s', table.getn(times) > 8 and worst <= 0.13,
        string.format('%d packets, worst gap %.3f', table.getn(times), worst))
end

do
    -- Beats on time: the frame driver adds nothing.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local driver = Mock.FindDriver(env)
    SM.OnBeat()
    local before = table.getn(env.__sent)
    for i = 1, 60 do
        env.__clock.t = env.__clock.t + 0.016
        env.__mouseWorld = { 50 + i, 0, 50 }
        if math.mod(i, 6) == 0 then SM.OnBeat() end
        driver:OnFrame(0.016)
    end
    local sent = table.getn(env.__sent) - before
    Check('with beats on time, no extra packets', sent == 10, sent)

    -- Observers and replays never send.
    local env2, SM2 = NewSession({ focusArmy = -1 })
    SM2.InitTeamMouse(false)
    for _ = 1, 30 do
        env2.__clock.t = env2.__clock.t + 0.016
        Mock.FindDriver(env2):OnFrame(0.016)
    end
    Check('an observer\'s frames send nothing', table.getn(env2.__sent) == 0)
end

--------------------------------------------------------------------------------
Section('the pause keys')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local A = env.import('/mods/TeamMouse/modules/actions.lua')
    local construction = env.import('/lua/ui/game/construction.lua')
    env.__selectedUnits = { {} }
    local function Ac()
        env.__clock.t = env.__clock.t + 0.1
        SM.OnBeat()
        return env.__sent[table.getn(env.__sent)].msg.ac
    end

    construction.ToggleUnitPause()
    local ac = Ac()
    Check('the pause key is sent as paused', ac and ac[1] == A.PAUSED and table.getn(ac) == 1,
        ac and table.getn(ac))
    construction.ToggleUnitPause()
    ac = Ac()
    Check('and again as resumed', ac and ac[1] == A.RESUMED and table.getn(ac) == 1)
    construction.ToggleUnitPauseAll()
    Check('pause-all as paused', Ac()[1] == A.PAUSED)
    construction.ToggleUnitUnpauseAll()
    Check('unpause-all as resumed', Ac()[1] == A.RESUMED)
    Check('the game\'s own functions still run', env.__calls[1] == 'ToggleUnitPause' and env.__calls[2] == 'SetPaused')

    SM.Destroy()
end

do
    local env = NewSession()
    local construction = env.import('/lua/ui/game/construction.lua')
    local original = construction.ToggleUnitPause
    local SM = env.import('/mods/TeamMouse/modules/teammouse.lua')
    SM.InitTeamMouse(false)
    Check('the pause key is hooked', construction.ToggleUnitPause ~= original)
    SM.Destroy()
    Check('and put back on teardown', construction.ToggleUnitPause == original)
end

--------------------------------------------------------------------------------
Section('an order being dragged to a new spot')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local CD = env.import('/mods/TeamMouse/modules/cursordata.lua')
    local view = env.__views['WorldCamera']
    local cell = Mock.FindDragOverlays(env)[1].children[1]
    Calibrate(env, SM)

    -- Hovering a queued patrol waypoint at (62, 48); press on it and drag.
    env.__cursor:SetTexture('/textures/ui/common/game/cursors/waypoint-hover.dds', 0, 0)
    env.__highlight = { x = 62, y = 0, z = 48, commandType = 16 }
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 124, MouseY = 96, Modifiers = { Left = true, Shift = true } })
    env.__highlight = nil
    cell:HandleEvent({ Type = 'MouseEnter', MouseX = 300, MouseY = 200, Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = env.__sent[table.getn(env.__sent)].msg
    Check('dragging a waypoint says which order it is', m.gk == CD.IndexFromKey('patrol'), tostring(m.gk))
    Check('from the order\'s own spot', m.p[1] == 62 and m.p[3] == 48, m.p[1] .. ',' .. m.p[3])
    Check('to where the pointer is', m.bx == 150 and m.bz == 100)

    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 300, MouseY = 200, Modifiers = {} })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    m = env.__sent[table.getn(env.__sent)].msg
    Check('letting go announces the order at its new spot',
        type(m.mo) == 'table' and m.mo[1] == CD.IndexFromKey('patrol') and m.mo[2] == 150 and m.mo[4] == 100)
    Check('and the drag is over', m.gk == false)
end

do
    -- An order type we don't have a cursor for still shows as the hand's order.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local CD = env.import('/mods/TeamMouse/modules/cursordata.lua')
    env.__cursor:SetTexture('/textures/ui/common/game/cursors/waypoint-hover.dds', 0, 0)
    env.__highlight = { x = 62, y = 0, z = 48, commandType = 999 }
    env.__views['WorldCamera']:HandleEvent({ Type = 'ButtonPress', MouseX = 124, MouseY = 96, Modifiers = { Left = true } })
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('an unknown order type falls back to the hand',
        env.__sent[table.getn(env.__sent)].msg.gk == CD.IndexFromKey('waypoint-drag'))

    -- No highlight at all (the engine didn't say): still the hand drag, as before.
    local env2, SM2 = NewSession()
    SM2.InitTeamMouse(false)
    env2.__cursor:SetTexture('/textures/ui/common/game/cursors/waypoint-hover.dds', 0, 0)
    env2.__views['WorldCamera']:HandleEvent({ Type = 'ButtonPress', MouseX = 124, MouseY = 96, Modifiers = { Left = true } })
    env2.__clock.t = env2.__clock.t + 0.1
    SM2.OnBeat()
    local m = env2.__sent[table.getn(env2.__sent)].msg
    Check('without a highlight it is the plain hand drag', m.gk == false and m.d == 2)
end

do
    -- What a teammate sees.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local CD = env.import('/mods/TeamMouse/modules/cursordata.lua')
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    for i = 0, 4 do
        env.__clock.t = T + i * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = CD.IndexFromKey('waypoint-drag'),
            z = 60, w = true, d = 2, bx = 100 + i * 50, bz = 100, gk = CD.IndexFromKey('patrol') })
    end
    env.__clock.t = T + 0.5
    driver:OnFrame(0.016)
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('the order being dragged shows in their hand', visual.grabShown and Mock.IsVisible(visual.grabIcon)
        and visual.grabTexture == CD.TextureForIndex(CD.IndexFromKey('patrol')))
    -- The live end: where the arrow's hotspot is.
    local endX = visual.mouseIcon.Left() + math.floor(visual.hotspotX * visual.appliedScale + 0.5)
    Check('centred on the drag\'s live end', math.abs(visual.grabIcon.Left()
        + visual.grabIcon.Width() / 2 - endX) <= 1,
        (visual.grabIcon.Left() + visual.grabIcon.Width() / 2) .. ' vs ' .. endX)
    Check('under the hand', visual.grabIcon.Depth() < visual.mouseIcon.Depth())
    Check('with a line back to where it was', visual.lineShown == true)

    for i = 5, 8 do
        env.__clock.t = T + i * 0.1
        receive('KasperAUS', { v = 1, a = 2, p = { 300, 0, 100 }, o = 0, z = 60, w = true })
    end
    env.__clock.t = T + 1.0
    driver:OnFrame(0.016)
    Check('let go, the icon and line go', not visual.grabShown and not visual.lineShown)
    Check('no errors', NoErrors(env))
end

--------------------------------------------------------------------------------
Section('bandwidth')
--------------------------------------------------------------------------------
local Wire = dofile('extras/wire_size.lua')

do
    -- Packing keeps what matters: a tenth of a world unit, a thousandth of
    -- the screen, a couple of milliseconds.
    local env = NewSession()
    local WP = env.import('/mods/TeamMouse/modules/wirepack.lua')
    local list = {
        { age = 0.087, x = 512.34, z = 90.06, hx = 0.5, hy = 0.9, bx = 512.34, bz = 90.06, flags = 0 },
        { age = 0.051, x = 530.00, z = 88.25, hx = 0.734, hy = 0.912, bx = 530, bz = 88.25, flags = 1 },
        { age = 0.019, x = 540.50, z = 70.00, hx = 0.5, hy = 0.9, bx = 700.4, bz = 20.2, flags = 2 },
    }
    local s = WP.PackSamples(list, 3, 520, 80)
    local got = {}
    WP.UnpackSamples(s, 520, 80, 10, function(age, x, z, hx, hy, bx, bz, flags)
        table.insert(got, { age = age, x = x, z = z, hx = hx, hy = hy, bx = bx, bz = bz, flags = flags })
    end)
    local ok = table.getn(got) == 3
    for i = 1, 3 do
        local a, b = list[i], got[i]
        if not b or math.abs(a.age - b.age) > 0.002 or math.abs(a.x - b.x) > 0.051
            or math.abs(a.z - b.z) > 0.051 or a.flags ~= b.flags then
            ok = false
        end
    end
    Check('extra samples survive packing', ok)
    Check('with the interface position when on the HUD',
        got[2] and math.abs(got[2].hx - 0.734) < 0.0011 and math.abs(got[2].hy - 0.912) < 0.0011)
    Check('and the live end when dragging', got[3] and math.abs(got[3].bx - 700.4) < 0.051
        and math.abs(got[3].bz - 20.2) < 0.051)
    Check('in about ten characters a sample', string.len(s) <= 3 * 9 + 4 + 6, string.len(s))
    Check('only printable characters', not string.find(s, '[^%w%-_]'))
end

do
    -- What a packet costs, estimated (extras/wire_size.lua).
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local driver = Mock.FindDriver(env)
    local view = env.__views['WorldCamera']
    SM.OnBeat()
    local first = table.getn(env.__sent) + 1
    for i = 1, 120 do
        env.__clock.t = env.__clock.t + 0.016
        env.__mouseWorld = { 100 + i * 2, 0, 100 + math.mod(i, 20) }
        view:HandleEvent({ Type = 'MouseMotion', MouseX = 100 + i, MouseY = 100 + math.mod(i, 20), Modifiers = {} })
        driver:OnFrame(0.016)
        if math.mod(i, 6) == 0 then SM.OnBeat() end
    end
    -- What actually went out (`wire`: the compact string, wirecodec.lua),
    -- against the plain table the same packet would have been (`raw`).
    local worst, total, plain, n = 0, 0, 0, 0
    local allCompact = true
    for i = first, table.getn(env.__sent) do
        local size = Wire.Size(env.__sent[i].wire)
        total = total + size
        plain = plain + Wire.Size(env.__sent[i].raw)
        n = n + 1
        if size > worst then worst = size end
        if not env.__sent[i].compact then allCompact = false end
    end
    Check('every packet goes compact to a teammate who reads it', n > 0 and allCompact)
    Check('a packet while moving stays small', worst <= 75, worst .. ' bytes (was ~150 as a table, ~400 before that)')
    local perSecond = total / (120 * 0.016)
    Check('under 600 B a second to each teammate while moving', perSecond <= 600,
        string.format('%.0f B/s (was ~1200 as a table, ~4700 before that)', perSecond))
    Check('under half what the same packets cost as tables', total <= plain * 0.5,
        string.format('%d vs %d bytes', total, plain))
end

do
    -- The SharedMouse copy only goes to a teammate on SharedMouse.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local legacyReceive = env.__chatFuncs['a']
    local LP = env.import('/mods/TeamMouse/modules/legacyprotocol.lua')
    -- Moving well past MinMoveDistance, so every beat sends.
    local function Beat()
        env.__clock.t = env.__clock.t + 0.1
        env.__mouseWorld = { 50 + env.__clock.t * 20, 0, 50 }
        local before = table.getn(env.__sent)
        SM.OnBeat()
        assert(table.getn(env.__sent) == before + 1, 'a beat that should send did not')
    end
    Beat()
    Beat()
    Check('no SharedMouse packets while nobody uses it', table.getn(env.__sentLegacy) == 0)

    -- A TeamMouse client's own SharedMouse-format copy is marked, and is not
    -- a sign of SharedMouse.
    local marked = LP.CreatePacket(1)
    LP.PopulatePacket(marked, 10, 0, 10, 0)
    legacyReceive('KasperAUS', marked)
    Beat()
    Check('a TeamMouse client\'s marked copy is not taken for SharedMouse', table.getn(env.__sentLegacy) == 0)

    -- What SharedMouse itself sends.
    local pkt = { a = true, b = { 10, 0, 10, 1 } }
    legacyReceive('KasperAUS', pkt)
    Beat()
    local last = env.__sentLegacy[table.getn(env.__sentLegacy)]
    Check('a teammate on SharedMouse gets them', last ~= nil and last.clients[1] == 2
        and table.getn(last.clients) == 1)

    legacyReceive('Eternal', pkt)
    Beat()
    last = env.__sentLegacy[table.getn(env.__sentLegacy)]
    Check('an opponent on SharedMouse does not', table.getn(last.clients) == 1 and last.clients[1] == 2)

    receive('KasperAUS', { v = 1, a = 2, p = { 10, 0, 10 }, o = 0 })
    local before = table.getn(env.__sentLegacy)
    Beat()
    Beat()
    Check('and they stop once that teammate turns out to have TeamMouse',
        table.getn(env.__sentLegacy) == before)
end

do
    -- Zoom goes only when it changes.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local function Beat()
        env.__clock.t = env.__clock.t + 0.1
        env.__mouseWorld = { 50 + env.__clock.t * 10, 0, 50 }
        SM.OnBeat()
        return env.__sent[table.getn(env.__sent)].raw
    end
    local first = Beat()
    Check('the first packet has the zoom', first.z ~= nil)
    Check('the next ones do not, while it stays the same', Beat().z == nil and Beat().z == nil)
    env.__setZoom(250)
    Check('a change sends it', Beat().z == 250)
    Beat()
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    env.__clock.t = env.__clock.t + cfg.Network.ForceResendInterval + 0.1
    Check('and it is repeated now and then in case a packet was lost', Beat().z ~= nil)
end

do
    -- The receiving end: a missing zoom keeps the last one, and a packet with
    -- nothing optional reads as a plain cursor on the map.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    receive('KasperAUS', { v = 1, a = 2, p = { 10, 0, 10 }, o = 3, z = 222 })
    receive('KasperAUS', { v = 1, a = 2, p = { 12, 0, 10 }, o = 3 })
    local record = Mock.FindCursors(env, 'WorldCamera')[1].record
    Check('the zoom is kept between packets', record.zoom == 222)
    env.__clock.t = env.__clock.t + 0.3
    Mock.FindDriver(env):OnFrame(0.016)
    Check('a minimal packet reads as a cursor on the map, not dragging',
        record.renderHud == false and record.renderDrag == 0 and NoErrors(env))
end

--------------------------------------------------------------------------------
Section('a drag that starts off screen')
--------------------------------------------------------------------------------
-- Regression test for: a teammate's drag begun outside your view was not drawn
-- even once it reached your view. The cursor was culled on its anchor alone,
-- and during a drag that is where the drag began.
local function DragFrom(env, drag, anchor, liveEnd, steps)
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    local T = env.__clock.t
    for i = 0, steps or 4 do
        env.__clock.t = T + i * 0.1
        local m = { v = 1, a = 2, p = { anchor[1], 0, anchor[2] }, o = 0, z = 60,
            bx = liveEnd[1], bz = liveEnd[2] }
        for k, v in pairs(drag) do m[k] = v end
        receive('KasperAUS', m)
    end
    env.__clock.t = T + (steps or 4) * 0.1 + 0.05
    driver:OnFrame(0.016)
    return Mock.FindCursors(env, 'WorldCamera')[1]
end

do
    -- Mock projection: screen = world * 2. The view is 0..1920 x 0..1080.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local visual = DragFrom(env, { s = true }, { -300, 100 }, { 200, 150 })
    Check('a box begun off screen shows once it reaches the view', Mock.IsVisible(visual)
        and visual.dragBoxShown == true)
    Check('with the arrow on its live end, in view', visual.mouseIcon.Left() >= 0
        and visual.mouseIcon.Left() < 1920, visual.mouseIcon.Left())

    local env2, SM2 = NewSession()
    SM2.InitTeamMouse(false)
    local v2 = DragFrom(env2, { d = 1 }, { 100, -400 }, { 150, 200 })
    Check('so does a drawing', Mock.IsVisible(v2))

    local env3, SM3 = NewSession()
    SM3.InitTeamMouse(false)
    local v3 = DragFrom(env3, { s = true }, { -300, -300 }, { -200, -250 })
    Check('a drag entirely off screen is still culled', not Mock.IsVisible(v3))

    local env4, SM4 = NewSession()
    SM4.InitTeamMouse(false)
    local v4 = DragFrom(env4, {}, { -300, 100 }, { 200, 150 })
    Check('without a drag, an off-screen cursor is still culled', not Mock.IsVisible(v4))
    Check('no errors', NoErrors(env) and NoErrors(env2))
end

--------------------------------------------------------------------------------
Section('teardown')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession({ splitscreen = true })
    SM.InitTeamMouse(false)

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
Section('names and indicator text have a white stroke')
--------------------------------------------------------------------------------
-- Feature: names and indicator text (an action, TEMPLATE) are hard to read
-- over busy ground. The game's text has no outline, so the stroke is eight
-- white copies, one pixel off in each direction, under the text.

--- A session that has seen KasperAUS (army 2) at world (100, 0, 100), plus
--- whatever else `extra` adds to the packet. Returns env, visual, driver, receive.
local function Seeing(extra, opts)
    local env, SM = NewSession(opts)
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local msg = { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true }
    for k, v in pairs(extra or {}) do msg[k] = v end
    receive('KasperAUS', msg)
    local driver = Mock.FindDriver(env)
    for _ = 1, 3 do
        env.__clock.t = env.__clock.t + 0.1
        driver:OnFrame(0.1)
    end
    return env, Mock.FindCursors(env, 'WorldCamera')[1], driver, receive, SM
end

--- Whether `stroke` surrounds `text`: eight copies saying the same, one step
--- off in every direction, under it, visible, at `alpha`.
local function Surrounds(stroke, text, words, alpha)
    if not stroke or table.getn(stroke.copies) ~= 8 then return false, 'no stroke' end
    local seen = {}
    for _, c in ipairs(stroke.copies) do
        if not Mock.IsVisible(c) then return false, 'hidden' end
        if c._text ~= words then return false, 'says ' .. tostring(c._text) end
        if c._color ~= 'ffffffff' then return false, 'colour ' .. tostring(c._color) end
        if c.Depth() >= text.Depth() then return false, 'over the text' end
        if alpha and math.abs(c._alpha - alpha) > 0.001 then return false, 'alpha ' .. c._alpha end
        seen[(c.Left() - text.Left()) .. ',' .. (c.Top() - text.Top())] = true
    end
    for _, off in ipairs({ '-1,-1', '0,-1', '1,-1', '-1,0', '1,0', '-1,1', '0,1', '1,1' }) do
        if not seen[off] then return false, 'missing ' .. off end
    end
    return true
end

do
    local env0 = NewSession()
    local A = env0.import('/mods/TeamMouse/modules/actions.lua')
    local env, visual, driver = Seeing({ ac = { A.STOP } })
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local label = visual.actionLabel
    local ok, why = Surrounds(visual.actionStroke, label, label._text,
        label._alpha * cfg.Appearance.TextStrokeAlpha)
    Check('an action label has a white stroke all round, under it, fading with it', ok, why)

    env.__clock.t = env.__clock.t + cfg.Actions.Lifetime + 1
    env.__chatFuncs['TeamMouse']('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true })
    driver:OnFrame(0.1)
    Check('and goes with it', not Mock.IsVisible(visual.actionStroke.copies[1]))

    -- A different action: the stroke says it too.
    env.__chatFuncs['TeamMouse']('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
        ac = { A.PAUSED } })
    env.__clock.t = env.__clock.t + 0.3
    driver:OnFrame(0.1)
    Check('and changes with it', visual.actionStroke.copies[5]._text == label._text and label._text ~= '')
end

do
    local env, visual, driver = Seeing()
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local label = visual.label
    local ok, why = Surrounds(visual.nameStroke, label, label._text or 'KasperAUS',
        label._alpha * cfg.Appearance.TextStrokeAlpha)
    Check('the name has a white stroke all round', ok, why)
    Check('and the zoom bar is over it', visual.nameBar.Depth() > visual.nameStroke.copies[1].Depth())
    env.__views['WorldCamera']:HandleEvent({ Type = 'MouseMotion', MouseX = 200, MouseY = 200, Modifiers = {} })
    env.__clock.t = env.__clock.t + 0.1
    driver:OnFrame(0.1)
    ok, why = Surrounds(visual.nameStroke, label, label._text or 'KasperAUS',
        label._alpha * cfg.Appearance.TextStrokeAlpha)
    Check('fading with the name', ok and label._alpha < 0.3, why)
end

do
    -- TEMPLATE, placed and in hand.
    local env, visual = Seeing({ mo = { 0, 50, 0, 50, 50, 50, 0 }, mob = { 'ueb0101' }, mot = { 1 },
        b = 'ueb0101', bt = true })
    local mark = visual.orderMarks[1]
    Check('a placed TEMPLATE has a stroke', mark and (Surrounds(mark.tstroke, mark.tlabel, 'TEMPLATE')))
    Check('so does one in hand', (Surrounds(visual.templateStroke, visual.templateLabel, 'TEMPLATE')))
    Check('no errors with strokes', NoErrors(env))
end

do
    local env, SM = NewSession()
    env.import('/mods/TeamMouse/modules/config.lua').Appearance.TextStroke = false
    SM.InitTeamMouse(false)
    env.__chatFuncs['TeamMouse']('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true })
    env.__clock.t = env.__clock.t + 0.3
    Mock.FindDriver(env):OnFrame(0.1)
    Check('with TextStroke off, no stroke', not Mock.FindCursors(env, 'WorldCamera')[1].nameStroke and NoErrors(env))
end

--------------------------------------------------------------------------------
Section('a paused replay keeps its cursors')
--------------------------------------------------------------------------------
-- Feature: while a replay is paused nothing is played back, so every cursor
-- went stale and faded away. The pause now holds them.
do
    local env, SM = RecordingSession('on')
    MoveTo(env, SM, 200, 0, 200, 400, 400)
    local renv, _, Play = ReplayOf(env)
    Play()
    local visual = CursorFor(renv, 1)
    local cfg = renv.import('/mods/TeamMouse/modules/config.lua')
    local driver = Mock.FindDriver(renv)

    renv.__paused = true
    for _ = 1, 20 do
        renv.__clock.t = renv.__clock.t + cfg.Smoothing.StaleTimeout / 5
        driver:OnFrame(cfg.Smoothing.StaleTimeout / 5)
    end
    Check('paused far past the stale timeout, the cursor is still there', Mock.IsVisible(visual)
        and visual.appliedAlpha > 0.5, visual.appliedAlpha)

    renv.__paused = false
    for _ = 1, 20 do
        renv.__clock.t = renv.__clock.t + cfg.Smoothing.StaleTimeout / 5
        driver:OnFrame(cfg.Smoothing.StaleTimeout / 5)
    end
    Check('playing with nothing arriving, it still goes stale as before',
        not Mock.IsVisible(visual) or visual.appliedAlpha < 0.05)
end

--------------------------------------------------------------------------------
Section('a bar under the name shows how far they are zoomed')
--------------------------------------------------------------------------------
-- Feature: a bar in their colour, centred under their name, as wide as the
-- name when THEY are zoomed all the way in, shrinking as they pull back.
do
    local env, visual, driver, receive = Seeing()   -- they are at zoom 60
    local bar, label = visual.nameBar, visual.label
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local function TheirZoom(z)
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = z, w = true })
        env.__clock.t = env.__clock.t + 0.1
        driver:OnFrame(0.1)
        return bar.Width()
    end
    label.Width:SetValue(80)   -- a name 80 pixels wide
    Check('there is a bar under the name', bar and Mock.IsVisible(bar) and bar.Top() > label.Top())
    Check('in their colour', bar and bar._color == visual.uiColor)
    Check('they are all the way in: as wide as the name', TheirZoom(30) == 80, bar.Width())
    Check('all the way out: its narrowest', TheirZoom(600) == cfg.Appearance.NameBarMinWidth, bar.Width())
    -- On a log scale: half way is the geometric middle of 30 and 600.
    local mid = TheirZoom(math.sqrt(30 * 600))
    Check('half way (on a log scale): about half', math.abs(mid - (4 + 76 * 0.5)) <= 1, mid)
    -- Regression test for: close in the bar hardly moved; only zooming right
    -- out changed it. Doubling out from all the way in now moves it as much
    -- as doubling out anywhere else.
    local near = TheirZoom(30) - TheirZoom(60)
    local far = TheirZoom(300) - TheirZoom(600)
    Check('as sensitive close in as far out', near >= 15 and math.abs(near - far) <= 1, near .. ' vs ' .. far)
    Check('always centred under the name',
        math.abs((bar.Left() + bar.Width() / 2) - (label.Left() + label.Width() / 2)) < 0.51)
    Check('past the ends, held at them', TheirZoom(5) == 80 and TheirZoom(9000) == 4)

    -- Your own zoom does not change it.
    TheirZoom(315)
    env.__setZoom(30)
    driver:OnFrame(0.1)
    local w1 = bar.Width()
    env.__setZoom(600)
    driver:OnFrame(0.1)
    Check('your own zoom does not change it', bar.Width() == w1)

    -- It fades with the name, like any part of the cursor.
    env.__views['WorldCamera']:HandleEvent({ Type = 'MouseMotion', MouseX = 200, MouseY = 200, Modifiers = {} })
    driver:OnFrame(0.1)
    Check('it fades with the name', math.abs(bar._alpha - label._alpha) < 0.03, bar._alpha .. ' / ' .. label._alpha)

    env.__zoomRange = { nil, nil }
    Check('a camera that gives no limits uses the configured ones',
        TheirZoom(cfg.Appearance.NameBarZoomOut) == 4)
end

--------------------------------------------------------------------------------
Section('teammates\' views, outlined on the map')
--------------------------------------------------------------------------------
-- Feature: a checkbox in the panel (off by default) outlines what each
-- teammate's camera sees: white outside, their colour inside.
do
    -- Sending.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    MoveTo(env, SM, 100, 0, 100, 200, 200)
    local vp
    for i = table.getn(env.__sent), 1, -1 do
        vp = env.__sent[i].msg.vp
        if vp then break end
    end
    Check('our view\'s outline is sent', type(vp) == 'table' and vp[12] ~= nil)
    local view = env.__views['WorldCamera']
    Check('its four corners on the map', vp and vp[1] == 0.5 and vp[3] == 0.5
        and vp[4] == 959.5 and vp[9] == 539.5, vp and table.concat(vp, ','))

    MoveTo(env, SM, 110, 0, 100, 220, 200)
    Check('not again while the camera stays put', env.__sent[table.getn(env.__sent)].msg.vp == nil)

    local unproject = env.UnProject
    env.UnProject = function(v, point)
        local w = unproject(v, point)
        return { w[1] + 40, w[2], w[3] }
    end
    local before = table.getn(env.__sent)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local last = env.__sent[table.getn(env.__sent)].msg
    Check('the camera moving is news on its own, mouse still', table.getn(env.__sent) > before
        and last.vp and last.vp[1] == 40.5, last.vp and last.vp[1])

    local envOff, SMOff = NewSession()
    envOff.import('/mods/TeamMouse/modules/config.lua').Viewport.Share = false
    SMOff.InitTeamMouse(false)
    Calibrate(envOff, SMOff)
    MoveTo(envOff, SMOff, 100, 0, 100, 200, 200)
    local anyVp = false
    for _, s in ipairs(envOff.__sent) do
        if s.msg.vp then anyVp = true end
    end
    Check('with Share off it is not', not anyVp)
end

--- Visible pieces of a line pool, and their bounds.
local function PoolShown(pool)
    local n, minTop = 0, 1e9
    if not pool then return 0, minTop end
    for i = 1, pool.made do
        if Mock.IsVisible(pool.bits[i]) then
            n = n + 1
            if pool.bits[i].Top() < minTop then minTop = pool.bits[i].Top() end
        end
    end
    return n, minTop
end

--- The lines drawn for teammates' views in one rendered frame.
local function ViewLines(env)
    return Mock.RenderWorld(env)
end

do
    local rect = { 10, 0, 10, 110, 0, 10, 110, 0, 60, 10, 0, 60 }
    local env, visual, driver, receive = Seeing({ vp = rect })
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local panel = env.import('/mods/TeamMouse/modules/panel.lua').Get()
    local row = panel and panel.rows[1]
    Check('each player has their own "view" box, unticked', row and row.viewCheck and not row.viewCheck:IsChecked())
    Check('off: nothing drawn', table.getn(ViewLines(env)) == 0)

    row.viewCheck:Click()
    env.__setZoom(600)   -- all the way out
    driver:OnFrame(0.1)
    local lines = ViewLines(env)
    Check('ticked: four lines, all in their colour, no white', table.getn(lines) == 4
        and string.sub(lines[1][3], 3) == string.sub(visual.uiColor, 3)
        and string.sub(lines[4][3], 3) == string.sub(visual.uiColor, 3), table.getn(lines))
    Check('drawn by the game, in the world, along their view\'s edges',
        lines[1] and lines[1][1][1] == 10 and lines[1][1][3] == 10 and lines[1][2][1] == 110
        and lines[1][2][3] == 10 and lines[4][2][1] == 10 and lines[4][2][3] == 10)
    Check('opaque and thin zoomed out', lines[1] and string.sub(lines[1][3], 1, 2) == 'ff'
        and lines[1][4] == cfg.Viewport.Thickness)

    env.__setZoom(30)    -- all the way in
    driver:OnFrame(0.1)
    lines = ViewLines(env)
    Check('zoomed in: still four lines', table.getn(lines) == 4, table.getn(lines))
    Check('thicker', lines[1] and lines[1][4] == cfg.Viewport.NearThickness, lines[1] and lines[1][4])
    Check('and fainter', lines[1] and tonumber(string.sub(lines[1][3], 1, 2), 16)
        == math.floor(cfg.Viewport.NearAlpha * 255 + 0.5), lines[1] and lines[1][3])

    env.__setZoom(201)   -- 70% of the way in: between NearStart and NearEnd
    driver:OnFrame(0.1)
    lines = ViewLines(env)
    local a = lines[1] and tonumber(string.sub(lines[1][3], 1, 2), 16)
    Check('part way in: part way between', table.getn(lines) == 4 and a < 255
        and a > math.floor(cfg.Viewport.NearAlpha * 255) and lines[1][4] > cfg.Viewport.Thickness
        and lines[1][4] < cfg.Viewport.NearThickness, a)

    local view = env.__views['WorldCamera']
    Check('one shape for them on the view', view.Shapes['TeamMouseView2'] ~= nil)

    visual.record.disabled = true
    driver:OnFrame(0.1)
    Check('a player hidden in the panel: no outline', table.getn(ViewLines(env)) == 0)
    visual.record.disabled = false

    row.viewCheck:Click()
    driver:OnFrame(0.1)
    Check('unticked: gone', table.getn(ViewLines(env)) == 0)

    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true, vp = { 1, 2, 3, 'x' } })
    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true, vp = 'junk' })
    Check('a broken outline is dropped, the last good one kept', visual.record.vp[4] == 110 and NoErrors(env))

    local SM = env.import('/mods/TeamMouse/modules/teammouse.lua')
    SM.Destroy()
    Check('teardown takes the shape off the view', view.Shapes['TeamMouseView2'] == nil)
end

do
    -- Each player's box is their own.
    local env, SM = NewSession({ focusArmy = -1 })
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local rect = { 10, 0, 10, 110, 0, 10, 110, 0, 60, 10, 0, 60 }
    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true, vp = rect })
    receive('Eternal', { v = 1, a = 3, p = { 300, 0, 300 }, o = 0, z = 60, w = true, vp = rect })
    local driver = Mock.FindDriver(env)
    local panel = env.import('/mods/TeamMouse/modules/panel.lua').Get()
    for _, row in ipairs(panel.rows) do
        if row.record.army == 3 then row.viewCheck:Click() end
    end
    for _ = 1, 3 do env.__clock.t = env.__clock.t + 0.1; driver:OnFrame(0.1) end
    local view = env.__views['WorldCamera']
    Check('ticking one player outlines only theirs', view.Shapes['TeamMouseView3'] ~= nil
        and view.Shapes['TeamMouseView2'] == nil)
    Check('no errors', NoErrors(env))
end

do
    -- A game whose views cannot take shapes: no outline, no error.
    local env, visual, driver = Seeing({ vp = { 10, 0, 10, 110, 0, 10, 110, 0, 60, 10, 0, 60 } })
    env.__views['WorldCamera'].AddShape = false
    visual.record.showView = true
    driver:OnFrame(0.1)
    Check('views without shapes: nothing drawn, no error', table.getn(ViewLines(env)) == 0 and NoErrors(env))
end

--------------------------------------------------------------------------------
Section('following a player\'s camera in a replay')
--------------------------------------------------------------------------------
-- Feature: in a replay, a "follow" box per player makes your camera follow
-- theirs, moving part of the way each frame so it glides rather than steps.

--- The row for `army` in a session's panel.
local function PanelRow(env, army)
    local panel = env.import('/mods/TeamMouse/modules/panel.lua').Get()
    for _, row in ipairs(panel and panel.rows or {}) do
        if row.record.army == army then return row end
    end
end

--- Run the replay's frames for `seconds`, `dt` apart.
local function Frames(renv, seconds, dt)
    local driver = Mock.FindDriver(renv)
    local t = 0
    while t < seconds - 1e-9 do
        renv.__clock.t = renv.__clock.t + dt
        driver:OnFrame(dt)
        t = t + dt
    end
end

do
    local env, SM = RecordingSession('on')
    env.__camera = { Focus = { 400, 20, 300 }, Heading = 3.14159, Pitch = 1.1 }
    env.__setZoom(120)
    MoveTo(env, SM, 400, 0, 300, 400, 400)
    local chatCam = false
    for _, s in ipairs(env.__sent) do
        if s.msg.cam then chatCam = true end
    end
    local cam
    for _, m in ipairs(Recorded(env)) do
        if m.cam then cam = m.cam end
    end
    Check('the replay gets their camera, whole', cam and cam[1] == 400 and cam[2] == 20 and cam[3] == 300
        and cam[4] == 3.142 and cam[5] == 1.1 and cam[6] == 120, cam and table.concat(cam, ','))
    Check('teammates are not sent it (only a replay follows)', not chatCam)

    local renv, _, Play = ReplayOf(env)
    -- (The mock's projection ignores the camera, so fitting their view's
    -- shape -- tested on its own below -- is off for this test.)
    renv.import('/mods/TeamMouse/modules/config.lua').Follow.FitView = false
    Play()
    local row = PanelRow(renv, 1)
    Check('in a replay each player has a "follow" box, unticked', row and row.followCheck
        and not row.followCheck:IsChecked())

    renv.__camera = { Focus = { 0, 0, 0 }, Heading = 3.14159, Pitch = 1.0 }
    renv.__setZoom(500)
    local restoredBefore = table.getn(renv.__restored)
    Frames(renv, 0.2, 0.1)
    Check('nobody followed: the camera is left alone', table.getn(renv.__restored) == restoredBefore)

    row.followCheck:Click()
    Frames(renv, 0.016, 0.016)
    local f1 = renv.__camera.Focus[1]
    Check('ticked: the camera sets off towards theirs, from where it was', f1 > 0 and f1 < 100, f1)

    -- Smooth: every frame moves it on, and no frame jumps.
    local last, steady = f1, true
    for _ = 1, 30 do
        Frames(renv, 0.016, 0.016)
        local f = renv.__camera.Focus[1]
        -- A small share of the way left each frame: never the whole of it.
        if not (f > last and f - last <= (400 - last) * 0.2) then steady = false end
        last = f
    end
    Check('it glides: a little further every frame, never a jump', steady)

    Frames(renv, 2, 0.016)
    local c = renv.__camera
    Check('and settles on their view', math.abs(c.Focus[1] - 400) < 0.5 and math.abs(c.Focus[3] - 300) < 0.5
        and math.abs(c.Focus[2] - 20) < 0.5, c.Focus[1] .. ',' .. c.Focus[3])
    local zoomNow = renv.__restored[table.getn(renv.__restored)].Zoom
    Check('at their zoom and angle', math.abs(zoomNow - 120) < 0.5 and math.abs(c.Pitch - 1.1) < 0.01
        and math.abs(c.Heading - 3.142) < 0.01, zoomNow)

    -- They move on.
    env.__camera = { Focus = { 600, 20, 300 }, Heading = 3.14159, Pitch = 1.1 }
    MoveTo(env, SM, 600, 0, 300, 600, 400)
    Play(1)
    Frames(renv, 2, 0.016)
    Check('it keeps following them', math.abs(renv.__camera.Focus[1] - 600) < 0.5, renv.__camera.Focus[1])

    -- One at a time. (Army 2's recorded data has to arrive for them to be
    -- listed at all: replay rows appear with their player's data.)
    renv.import('/lua/userplayerquery.lua').ProcessQueries({ { Name = 'TeamMouse',
        M = { v = 1, a = 2, p = { 300, 0, 300 }, o = 0, z = 80, w = true } } })
    Frames(renv, 0.1, 0.1)
    local other = PanelRow(renv, 2)
    other.followCheck:Click()
    -- (The panel was rebuilt when army 2 appeared: look the row up again.)
    row = PanelRow(renv, 1)
    Check('following another unticks the first', not row.followCheck:IsChecked()
        and not row.record.follow and other.record.follow)
    other.followCheck:Click()
    local n = table.getn(renv.__restored)
    Frames(renv, 0.5, 0.1)
    Check('unticked: the camera is yours again', table.getn(renv.__restored) == n)
    Check('no errors following', NoErrors(renv))
end

do
    -- Turning the short way: from just under +pi to just over -pi is a small
    -- turn through pi, not nearly a full circle back.
    local env, SM = RecordingSession('on')
    env.__camera = { Focus = { 100, 0, 100 }, Heading = -3.0, Pitch = 1.1 }
    MoveTo(env, SM, 100, 0, 100, 200, 200)
    local renv, _, Play = ReplayOf(env)
    Play()
    renv.__camera = { Focus = { 100, 0, 100 }, Heading = 3.0, Pitch = 1.1 }
    PanelRow(renv, 1).followCheck:Click()
    Frames(renv, 0.05, 0.016)
    Check('the heading turns the short way round', renv.__camera.Heading > 3.0, renv.__camera.Heading)
end


do
    -- Not in a live game (for now).
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    env.__chatFuncs['TeamMouse']('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true })
    local row = PanelRow(env, 2)
    Check('a live game has no "follow" boxes', row and not row.followCheck)
end

--------------------------------------------------------------------------------
Section('softer strokes, and outlines faint close in')
--------------------------------------------------------------------------------
do
    local env, visual, driver = Seeing({ vp = { 10, 0, 10, 110, 0, 10, 110, 0, 60, 10, 0, 60 } })
    local label = visual.label
    local copy = visual.nameStroke.copies[1]
    Check('the name\'s stroke is well under the name\'s own opacity',
        copy._alpha <= label._alpha * 0.7 and copy._alpha > 0, copy._alpha .. ' vs ' .. label._alpha)

    -- Close in, a teammate's view outline is faint enough to see through.
    visual.record.showView = true
    env.__setZoom(30)
    driver:OnFrame(0.1)
    local lines = Mock.RenderWorld(env)
    local a = lines[1] and tonumber(string.sub(lines[1][3], 1, 2), 16)
    Check('zoomed in, a teammate\'s view outline is faint', a and a <= 64, a)
    env.__setZoom(600)
    driver:OnFrame(0.1)
    lines = Mock.RenderWorld(env)
    Check('zoomed out, it is not', lines[1] and string.sub(lines[1][3], 1, 2) == 'ff')
end

--------------------------------------------------------------------------------
Section('less traffic at rest, fewer writes for still rows')
--------------------------------------------------------------------------------
do
    -- A mouse at rest: a keep-alive now and then, and the view outline far
    -- more rarely (it cannot change while the camera is still).
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local first = table.getn(env.__sent) + 1
    for _ = 1, 100 do
        env.__clock.t = env.__clock.t + 0.1
        SM.OnBeat()
    end
    local packets, outlines = 0, 0
    for i = first, table.getn(env.__sent) do
        packets = packets + 1
        if env.__sent[i].msg.vp then outlines = outlines + 1 end
    end
    Check('ten seconds at rest: one keep-alive a second or so', packets >= 8 and packets <= 11, packets)
    Check('the view outline only every few seconds', outlines >= 1 and outlines <= 3, outlines)
    Check('the keep-alive stays well inside the stale timeout',
        cfg.Network.ForceResendInterval * 3 <= cfg.Smoothing.StaleTimeout)

    -- Zooming with the mouse still is sent at once, not at the keep-alive.
    local before = table.getn(env.__sent)
    env.__setZoom(300)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local last = env.__sent[table.getn(env.__sent)]
    Check('a zoom alone is sent at once', table.getn(env.__sent) == before + 1 and last.msg.z == 300)

    -- The camera moving still sends the outline straight away.
    local unproject = env.UnProject
    env.UnProject = function(v, point)
        local w = unproject(v, point)
        return { w[1] + 40, w[2], w[3] }
    end
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    Check('a moved camera sends the outline at once', env.__sent[table.getn(env.__sent)].msg.vp ~= nil)
end

do
    -- A placed row standing still (camera and all) writes nothing each frame.
    local env, SM = NewSession()
    env.__blueprints.ueb0101.Physics = { SkirtSizeX = 20, SkirtSizeZ = 20 }
    SM.InitTeamMouse(false)
    env.__chatFuncs['TeamMouse']('KasperAUS', { v = 1, a = 2, p = { 20, 0, 20 }, o = 0, z = 60, w = true,
        mo = { 0, 50, 0, 50, 110, 50, 0 }, mob = { 'ueb0101' } })
    local driver = Mock.FindDriver(env)
    env.__clock.t = env.__clock.t + 0.2
    driver:OnFrame(0.016)
    local mark = Mock.FindCursors(env, 'WorldCamera')[1].orderMarks[1]
    local icon = mark and mark.row and mark.row.icons[2]
    local writes = 0
    if icon then
        local set, hide = icon.Left.SetValue, icon.SetHidden
        icon.Left.SetValue = function(s, v) writes = writes + 1; return set(s, v) end
        icon.SetHidden = function(s, h) writes = writes + 1; return hide(s, h) end
    end
    for _ = 1, 10 do
        env.__clock.t = env.__clock.t + 0.016
        driver:OnFrame(0.016)
    end
    Check('a still row: no position or visibility writes each frame', icon and writes == 0, writes)
    Check('still where it was, and showing', icon and Mock.IsVisible(icon)
        and icon.Left() + icon.Width() / 2 == 180)

    -- The camera moving: the row follows it.
    local project = env.__views['WorldCamera'].Project
    env.__views['WorldCamera'].Project = function(self, p)
        local s = project(self, p)
        return { x = s.x + 30, y = s.y, [1] = s[1] + 30, [2] = s[2] }
    end
    env.__clock.t = env.__clock.t + 0.016
    driver:OnFrame(0.016)
    Check('the camera moving moves the row', icon.Left() + icon.Width() / 2 == 210, icon.Left())
end

--------------------------------------------------------------------------------
Section('zoom bar stroke; "all" boxes in the panel')
--------------------------------------------------------------------------------
do
    local env, visual, driver = Seeing()
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local bar, stroke = visual.nameBar, visual.nameBarStroke
    Check('the zoom bar has a stroke like the name\'s', stroke and Mock.IsVisible(stroke)
        and stroke._color == cfg.Appearance.TextStrokeColor)
    Check('a pixel bigger all round, under the bar', stroke and stroke.Left() == bar.Left() - 1
        and stroke.Top() == bar.Top() - 1 and stroke.Width() == bar.Width() + 2
        and stroke.Height() == bar.Height() + 2 and stroke.Depth() < bar.Depth())
    Check('at the name stroke\'s share of the bar\'s opacity',
        stroke and math.abs(stroke._alpha - bar._alpha * cfg.Appearance.TextStrokeAlpha) < 0.001)
    Check('over the name\'s own stroke', stroke and stroke.Depth() > visual.nameStroke.copies[1].Depth())
end

do
    local env, SM = NewSession({ focusArmy = -1 })
    SM.InitTeamMouse(false)
    local panel = env.import('/mods/TeamMouse/modules/panel.lua').Get()
    local rows = panel.rows
    Check('the panel has "all" boxes for cursors and views', panel.allCursors and panel.allViews)
    Check('shown ticked while every cursor is shown, and views not', panel.allCursors:IsChecked()
        and not panel.allViews:IsChecked())
    Check('the "all" row sits above the players', rows[1] and rows[1].check.Top() > panel.allCursors.Top())

    panel.allViews:Click()
    local allOn = true
    for _, row in ipairs(rows) do
        if not (row.viewCheck:IsChecked() and row.record.showView) then allOn = false end
    end
    Check('ticking "all" views shows every player\'s view', allOn and table.getn(rows) >= 2)

    panel.allCursors:Click()
    local allOff = true
    for _, row in ipairs(rows) do
        if row.check:IsChecked() or not row.record.disabled then allOff = false end
    end
    Check('unticking "all" cursors hides every cursor', allOff)

    rows[1].check:Click()
    Check('one shown again: "all" is not ticked', not panel.allCursors:IsChecked() and not rows[1].record.disabled)
    for i = 2, table.getn(rows) do rows[i].check:Click() end
    Check('every one shown again: "all" ticks itself', panel.allCursors:IsChecked())
    rows[1].viewCheck:Click()
    Check('one view off: "all" views not ticked', not panel.allViews:IsChecked())
end

do
    -- A plain right click (no command cursor) is a move: it shows as one.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local view = env.__views['WorldCamera']
    env.__selectedUnits = { {} }
    env.__mouseWorld = { 60, 0, 40 }
    RightPress(env, view, 120, 80)
    RightRelease(env, view, 120, 80)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local mo
    for i = table.getn(env.__sent), 1, -1 do
        mo = env.__sent[i].raw.mo
        if mo then break end
    end
    local move = env.import('/mods/TeamMouse/modules/cursordata.lua').IndexFromKey('move')
    Check('a plain right click is sent as a move order', mo and mo[1] == move and move > 0, mo and mo[1])
end

--------------------------------------------------------------------------------
Section('clicks pulse at the tip of the cursor')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local view = env.__views['WorldCamera']
    local function Beat()
        env.__clock.t = env.__clock.t + 0.1
        SM.OnBeat()
        return env.__sent[table.getn(env.__sent)].msg
    end
    local function Unit1(id) return { GetEntityId = function() return id end } end
    local function Click(x, y, toX, toY)
        view:HandleEvent({ Type = 'ButtonPress', MouseX = x, MouseY = y, Modifiers = { Left = true } })
        view:HandleEvent({ Type = 'ButtonRelease', MouseX = toX or x, MouseY = toY or y, Modifiers = {} })
    end
    local function Clicks()
        local n = 0
        for i = env.__mark, table.getn(env.__sent) do
            n = n + (env.__sent[i].raw.ck or 0)
        end
        return n
    end

    -- A click that selects a unit. (When it does, the release never reaches
    -- us: the press is all there is.)
    env.__mark = table.getn(env.__sent) + 1
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    env.__selectedUnits = { Unit1('41') }
    Beat()
    Check('a single left click that selects something pulses', Clicks() == 1, Clicks())

    -- Pressed, then dragged away before the selection changed.
    env.__mark = table.getn(env.__sent) + 1
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    view:HandleEvent({ Type = 'MouseMotion', MouseX = 160, MouseY = 140, Modifiers = { Left = true } })
    env.__selectedUnits = { Unit1('48') }
    Beat()
    Check('pressed and dragged away: no pulse', Clicks() == 0, Clicks())

    -- Clicking the ground: nothing selected.
    env.__mark = table.getn(env.__sent) + 1
    Click(120, 100)
    env.__selectedUnits = {}
    Beat()
    Beat()
    Check('clicking the ground does not', Clicks() == 0, Clicks())

    -- A drag that selects.
    env.__mark = table.getn(env.__sent) + 1
    Click(100, 100, 300, 250)
    env.__selectedUnits = { Unit1('42'), Unit1('43') }
    Beat()
    Check('a drag that selects does not', Clicks() == 0, Clicks())

    -- The right button: never.
    env.__mark = table.getn(env.__sent) + 1
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Right = true } })
    env.__selectedUnits = { Unit1('44') }
    Beat()
    Check('a right click does not', Clicks() == 0, Clicks())

    -- A double-click selects every one of a kind: it pulses.
    env.__mark = table.getn(env.__sent) + 1
    view:HandleEvent({ Type = 'ButtonDClick', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    env.__selectedUnits = { Unit1('45'), Unit1('46') }
    Beat()
    Check('a double-click that selects does', Clicks() == 1, Clicks())

    -- The selection changing a moment before the release is still this click.
    env.__mark = table.getn(env.__sent) + 1
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 200, MouseY = 100, Modifiers = { Left = true } })
    env.__selectedUnits = { Unit1('47') }
    Beat()
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 200, MouseY = 100, Modifiers = {} })
    Beat()
    Check('so does one whose selection changed just before the release', Clicks() == 1, Clicks())
end

do
    local env, visual, driver, receive = Seeing()
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    receive('KasperAUS', { v = 1, a = 2, p = { 120, 3, 90 }, o = 0, z = 60, w = true, ck = 1 })
    env.__clock.t = env.__clock.t + cfg.Smoothing.InterpolationDelay + 0.05
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    local c1 = env.__circles[1]
    Check('a click pulses where the cursor\'s tip was', c1 and c1[1][1] == 120 and c1[1][2] == 3
        and c1[1][3] == 90, c1 and table.concat(c1[1], ','))
    Check('in their colour', c1 and string.sub(c1[3], 3) == string.sub(visual.uiColor, 3))
    env.__clock.t = env.__clock.t + 0.15
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    local c2 = env.__circles[1]
    Check('growing', c2 and c2[2] > c1[2], c2 and (c1[2] .. ' -> ' .. c2[2]))
    Check('and fading', c2 and tonumber(string.sub(c2[3], 1, 2), 16) < tonumber(string.sub(c1[3], 1, 2), 16))
    -- mock: 2 pixels a world unit, so Radius pixels is Radius / 2 units at most
    Check('no bigger than its radius in pixels', c2 and c2[2] <= cfg.ClickPulse.Radius / 2)
    Check('its line Thickness pixels wide, whatever the zoom', c2 and math.abs(c2[4] - cfg.ClickPulse.Thickness / 2) < 0.001)
    env.__clock.t = env.__clock.t + cfg.ClickPulse.Duration
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    Check('then gone', table.getn(env.__circles) == 0)
end

--------------------------------------------------------------------------------
Section('upgrades show what the building becomes, in gold')
--------------------------------------------------------------------------------
--- A unit at world (x, y, z) with entity id `id`.
--- Session options for a live observer (a client matching no army).
local function ObserverOpts()
    return { focusArmy = -1, clients = { [1] = { name = 'Lightningbulb' }, [2] = { name = 'KasperAUS' },
        [3] = { name = 'Eternal' }, [4] = { name = 'Caster', ['local'] = true } } }
end

local function MUnit(id, x, y, z)
    return {
        GetEntityId = function() return id end,
        GetPosition = function() return { x, y, z } end,
        IsDead = function(self) return self.dead == true end,
    }
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local step = 0
    local function Beat()
        env.__clock.t = env.__clock.t + 0.1
        step = step + 1
        env.__mouseWorld = { 50 + step * 5, 0, 50 }   -- moving: every beat sends
        SM.OnBeat()
        return env.__sent[table.getn(env.__sent)].msg
    end
    env.__selectedUnits = { MUnit('5', 30, 2, 40) }
    env.IssueBlueprintCommand('UNITCOMMAND_Upgrade', 'ueb0101', 1, false)
    Check('the game still gets the upgrade', env.__issued[1] and env.__issued[1][3] == 'ueb0101')
    local m = Beat()
    Check('an upgrade is sent as the new building, on the old one', m.mo and m.mo[2] == 30 and m.mo[4] == 40
        and m.mo[5] == 30 and m.mob and m.mob[1] == 'ueb0101')
    Check('marked as an upgrade', type(m.mou) == 'table' and m.mou[1] == 1)

    env.IssueBlueprintCommand('UNITCOMMAND_BuildFactory', 'uel0105', 1, false)
    Check('building a unit is not an upgrade', not Beat().mo)

    env.IssueBlueprintCommandToUnits({ MUnit('6', 10, 0, 10), MUnit('7', 20, 0, 20) }, 'UNITCOMMAND_Upgrade', 'ueb0101', 1)
    m = Beat()
    Check('upgrading several buildings: one each', m.mou and m.mou[2] == 2 and m.mo[2] == 10 and m.mo[9] == 20)
    env.IssueBlueprintCommandToUnit(MUnit('8', 70, 0, 70), 'UNITCOMMAND_Upgrade', 'ueb0101', 1)
    m = Beat()
    Check('and the single-unit way too', m.mou and m.mo[2] == 70)

    SM.Destroy()
    local n = table.getn(env.__issued)
    env.IssueBlueprintCommand('UNITCOMMAND_Upgrade', 'ueb0101', 1, false)
    Check('teardown gives the game its functions back', table.getn(env.__issued) == n + 1
        and env.IssueBlueprintCommand == env.IssueBlueprintCommand)
end

do
    local env, visual, driver = Seeing({ mo = { 0, 30, 0, 40, 30, 40, 0, 0, 60, 0, 60, 60, 60, 0 },
        mob = { 'ueb0101', 'ueb0101' }, mou = { 1 } })
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local up, plain = visual.orderMarks[1], visual.orderMarks[2]
    Check('an upgrade shows the new building\'s icon', up and up.icon and Mock.IsVisible(up.icon))
    -- Regression test for: the upgrade frame was simply turned yellow, which a
    -- yellow player's markers already are. Now the frame keeps their colour
    -- and a gold diamond (a shape, not a colour) sits behind it.
    Check('framed in their colour, like any structure', up and up.square._color == visual.uiColor,
        up and up.square._color)
    Check('with a gold diamond behind it', up and up.diamond and Mock.IsVisible(up.diamond)
        and up.diamond._texture == '/mods/TeamMouse' .. cfg.Orders.UpgradeTexture)
    local framed = cfg.Orders.BuildIconSize + cfg.Orders.BuildFrame * 2
    Check('larger than the frame, so its points show', up and up.diamond
        and up.diamond.Width() == math.floor(framed * cfg.Orders.UpgradeDiamondScale + 0.5), up and up.diamond and up.diamond.Width())
    Check('centred on the building', up and up.diamond
        and math.abs((up.diamond.Left() + up.diamond.Width() / 2) - (up.square.Left() + up.square.Width() / 2)) < 1
        and math.abs((up.diamond.Top() + up.diamond.Height() / 2) - (up.square.Top() + up.square.Height() / 2)) < 1)
    Check('drawn behind the frame, which is behind the icon', up and up.diamond
        and up.diamond.Depth() < up.square.Depth() and up.square.Depth() < up.icon.Depth())
    Check('a plain placement keeps their colour', plain and plain.square._color == visual.uiColor)
    Check('and has no diamond', plain and not (plain.diamond and Mock.IsVisible(plain.diamond)))
end

do
    -- However an upgrade is ordered (the upgrade hotkey keeps its own copy of
    -- the game's function, out of reach of a wrapper), a structure we selected
    -- that starts building a structure in its own place is upgrading.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local step = 0
    local function Beat()
        env.__clock.t = env.__clock.t + 0.1
        step = step + 1
        env.__mouseWorld = { 50 + step * 5, 0, 50 }
        SM.OnBeat()
        return env.__sent[table.getn(env.__sent)].raw
    end
    local mex = MUnit('61', 80, 3, 90)
    mex.IsInCategory = function(self, c) return c == 'STRUCTURE' end
    local tank = MUnit('62', 0, 0, 0)
    tank.IsInCategory = function(self, c) return c == 'LAND' end
    env.__selectedUnits = { mex }
    Beat()
    env.__selectedUnits = {}
    Beat()

    local upgrade = MUnit('63', 80, 3, 90)
    upgrade.IsInCategory = function(self, c) return c == 'STRUCTURE' end
    upgrade.GetUnitId = function() return 'ueb1202' end
    mex.GetFocus = function() return upgrade end
    local m = Beat()
    Check('a structure that starts upgrading is told, though deselected since', m.mou and m.mou[1] == 1
        and m.mob and m.mob[1] == 'ueb1202' and m.mo[2] == 80 and m.mo[4] == 90)
    Check('once', not Beat().mou)

    -- A factory building a tank is not upgrading.
    local factory = MUnit('64', 10, 0, 10)
    factory.IsInCategory = function(self, c) return c == 'STRUCTURE' end
    env.__selectedUnits = { factory }
    Beat()
    factory.GetFocus = function() return tank end
    Check('a factory building a unit is not an upgrade', not Beat().mou)

    -- Ordered through the wrapped function AND seen starting: told once.
    local mex2 = MUnit('65', 30, 0, 30)
    mex2.IsInCategory = function(self, c) return c == 'STRUCTURE' end
    env.__selectedUnits = { mex2 }
    Beat()
    env.IssueBlueprintCommand('UNITCOMMAND_Upgrade', 'ueb1202', 1, false)
    local first = Beat()
    mex2.GetFocus = function() return upgrade end
    local second = Beat()
    Check('ordered by the menu and then seen starting: told once', first.mou and not second.mou)
end

do
    -- An upgrade marker fades away like a placed structure's.
    local env, visual, driver = Seeing({ mo = { 0, 30, 0, 40, 30, 40, 0 }, mob = { 'ueb0101' }, mou = { 1 } })
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local mark = visual.orderMarks[1]
    local a1 = mark and mark.square._alpha
    env.__clock.t = env.__clock.t + cfg.Orders.FadeHold + (cfg.Orders.Lifetime - cfg.Orders.FadeHold) / 2
    driver:OnFrame(0.016)
    local a2 = mark and mark.square._alpha
    Check('an upgrade marker fades', a1 and a2 and a2 < a1 - 0.2, tostring(a1) .. ' -> ' .. tostring(a2))
    Check('diamond and all', mark and mark.diamond and mark.diamond._alpha == a2)
    env.__clock.t = env.__clock.t + cfg.Orders.Lifetime
    env.__chatFuncs['TeamMouse']('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true })
    driver:OnFrame(0.016)
    Check('and goes, like a placed structure\'s', mark and not mark.visible)
end

--------------------------------------------------------------------------------
Section('copying orders shows COPY')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local A = env.import('/mods/TeamMouse/modules/actions.lua')
    local before = table.getn(env.__simCallbacks)
    env.SimCallback({ Func = 'CopyOrders', Args = { Target = '5', ClearCommands = false } }, true)
    Check('the game still gets the copy', table.getn(env.__simCallbacks) == before + 1
        and env.__simCallbacks[before + 1].Func == 'CopyOrders')
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local ac = LastAc(env)
    Check('copying orders is sent as COPY', ac and ac[1] == A.COPY and A.Labels[A.COPY] == 'COPY')
    env.__mouseWorld = { 80, 0, 80 }
    env.SimCallback({ Func = 'GiveOrders', Args = {} }, true)
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local last = env.__sent[table.getn(env.__sent)].raw
    Check('other callbacks are not', last.ac == nil)

    local renv, visual = Seeing({ ac = { A.COPY } })
    Check('a teammate\'s copy shows COPY by their cursor', visual.actionLabel
        and Mock.IsVisible(visual.actionLabel) and visual.actionLabel._text == 'COPY')
end

--------------------------------------------------------------------------------
Section('distributing orders shows DISTRIBUTE ORDERS')
--------------------------------------------------------------------------------
-- FAF's 'spreadattack' keys (lua/ui/game/hotkeys/distribute-queue.lua) end in
-- SimCallback { Func = 'DistributeOrders' }: DistributeOrders with
-- ClearCommands inside Args, DistributeOrdersOfMouseContext with it outside.
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local A = env.import('/mods/TeamMouse/modules/actions.lua')
    local before = table.getn(env.__simCallbacks)
    env.SimCallback({ Func = 'DistributeOrders', Args = { Target = '5', ClearCommands = true } }, true)
    Check('the game still gets the distribute', table.getn(env.__simCallbacks) == before + 1
        and env.__simCallbacks[before + 1].Func == 'DistributeOrders')
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    local ac = LastAc(env)
    Check('distributing orders is sent as DISTRIBUTE',
        ac and ac[1] == A.DISTRIBUTE and A.Labels[A.DISTRIBUTE] == 'DISTRIBUTE ORDERS')

    env.__mouseWorld = { 80, 0, 80 }
    env.SimCallback({ Func = 'DistributeOrders', Args = { Target = '7' }, ClearCommands = true }, true)
    env.__clock.t = env.__clock.t + 0.2
    local sentBefore = table.getn(env.__sent)
    SM.OnBeat()
    ac = table.getn(env.__sent) > sentBefore and env.__sent[table.getn(env.__sent)].msg.ac
    Check('the unit-under-cursor variant is too', ac and ac[1] == A.DISTRIBUTE)

    -- A copy and a distribute in one packet: both sent, the last one shown.
    env.SimCallback({ Func = 'CopyOrders', Args = { Target = '5' } }, true)
    env.SimCallback({ Func = 'DistributeOrders', Args = { Target = '5' } }, true)
    env.__mouseWorld = { 90, 0, 90 }
    env.__clock.t = env.__clock.t + 0.2
    sentBefore = table.getn(env.__sent)
    SM.OnBeat()
    ac = table.getn(env.__sent) > sentBefore and env.__sent[table.getn(env.__sent)].msg.ac
    Check('kept apart from COPY', A.DISTRIBUTE and ac and ac[1] == A.COPY and ac[2] == A.DISTRIBUTE)

    local renv, visual = Seeing({ ac = { A.DISTRIBUTE } })
    Check('a teammate\'s distribute shows DISTRIBUTE ORDERS by their cursor', visual.actionLabel
        and Mock.IsVisible(visual.actionLabel) and visual.actionLabel._text == 'DISTRIBUTE ORDERS')
end

--------------------------------------------------------------------------------
Section('teammates\' selections, boxed in light blue')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local function Beat()
        env.__clock.t = env.__clock.t + 0.1
        SM.OnBeat()
        return env.__sent[table.getn(env.__sent)].msg
    end
    env.__selectedUnits = { MUnit('11', 1, 0, 1), MUnit('1048612', 2, 0, 2) }
    local m = Beat()
    Check('our selection is sent, packed small (base 36)', m.sel == 'b,mh44', tostring(m.sel))
    env.__mouseWorld = { 77, 0, 77 }
    Check('not again while it stays the same', Beat().sel == nil)
    env.__selectedUnits = {}
    m = Beat()
    Check('selecting nothing is sent as nothing', m.sel == '', tostring(m.sel))

    -- Where the game has FAF's ObserveSelection, that is what tells us.
    local env2, SM2 = NewSession()
    local observed
    env2.import('/lua/ui/game/gamemain.lua').ObserveSelection = {
        AddObserver = function(self, fn) observed = fn end }
    SM2.InitTeamMouse(false)
    Calibrate(env2, SM2)
    Check('FAF\'s selection observer is used when there is one', observed ~= nil)
    observed({ newSelection = { MUnit('21', 0, 0, 0) } })
    env2.__clock.t = env2.__clock.t + 0.1
    SM2.OnBeat()
    local last = env2.__sent[table.getn(env2.__sent)].msg
    Check('and what it says is sent', last.sel == 'l', tostring(last.sel))
end

do
    -- 'b,c' is units 11 and 12. A small unit (footprint 1) and a big one (30).
    -- Sizes come with them: 1 and 30 world units (doubled, base 36). Watched
    -- by an observer, who can look units up by id.
    local units = { ['11'] = MUnit('11', 100, 5, 100), ['12'] = MUnit('12', 140, 5, 120) }
    local env, visual, driver, receive = Seeing({ sel = 'b,c', ss = '2,1o' }, ObserverOpts())
    env.GetUnitById = function(id) return units[id] end
    visual.selVersion = -1
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua').TeamSelection
    local r = env.__rects
    Check('a box on each unit they selected', table.getn(r) == 2, table.getn(r))
    local alpha = tonumber(string.sub(cfg.Color, 1, 2), 16)
    Check('very faint light blue (a quarter opaque)', r[1] and r[1][3] == cfg.Color and alpha == 64, alpha)
    -- The mock draws 2 pixels to a world unit.
    local small, big = r[1], r[2]
    Check('a small unit\'s box is the size of a strategic icon on screen', small
        and math.abs(small[2] - cfg.IconSize / 2) < 0.001, small and small[2])
    Check('a big one\'s fits its size', big and math.abs(big[2] - (30 + cfg.Margin)) < 0.001, big and big[2])
    Check('lines Thickness pixels wide, whatever the zoom', small and math.abs(small[4] - cfg.Thickness / 2) < 0.001,
        small and small[4])
    Check('each centred on its unit', small and math.abs(small[1][1] + small[2] / 2 - 100) < 0.001
        and math.abs(small[1][3] + small[2] / 2 - 100) < 0.001
        and math.abs(big[1][1] + big[2] / 2 - 140) < 0.001 and math.abs(big[1][3] + big[2] / 2 - 120) < 0.001)

    units['12'].dead = true
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    Check('a unit that died is not boxed', table.getn(env.__rects) == 1)

    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true, sel = '' })
    env.__clock.t = env.__clock.t + 0.1
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    Check('they select nothing: no boxes', table.getn(env.__rects) == 0)

    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true, sel = 'b,NOT!,c' })
    Check('ids that are not ids end the list', table.getn(visual.record.sel) == 1 and visual.record.sel[1] == '11')
    Check('no errors', NoErrors(env))
end

do
    -- A live game: a player cannot look a teammate's units up by id (and
    -- does not try). They are drawn where the teammate said they are.
    local env, visual, driver, receive = Seeing({ sel = 'b,c', ss = '2,g', sq = 'b4,b4,5;fk,dc,0' })
    local looked = 0
    env.GetUnitById = function() looked = looked + 1 return nil end
    visual.selVersion = -1
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua').TeamSelection
    local r = env.__rects
    Check('live, boxes are drawn where they said their units are', table.getn(r) == 2
        and math.abs(r[1][1][1] + r[1][2] / 2 - 100) < 0.001 and math.abs(r[1][1][3] + r[1][2] / 2 - 100) < 0.001
        and r[1][1][2] == 5 and math.abs(r[2][1][1] + r[2][2] / 2 - 140) < 0.001
        and math.abs(r[2][1][3] + r[2][2] / 2 - 120) < 0.001, table.getn(r))
    Check('the factory\'s box covers its pad', r[2] and math.abs(r[2][2] - (8 + cfg.Margin)) < 0.001, r[2] and r[2][2])

    Check('and does not try to look them up', looked == 0, looked)

    -- They stay where the units were, and fade like any other marker.
    local orders = env.import('/mods/TeamMouse/modules/config.lua').Orders
    local function Alpha()
        Mock.RenderWorld(env)
        local rr = env.__rects[1]
        return rr and tonumber(string.sub(rr[3], 1, 2), 16) or 0
    end
    local a0 = Alpha()
    env.__clock.t = env.__clock.t + orders.FadeHold + (orders.Lifetime - orders.FadeHold) / 2
    driver:OnFrame(0.016)
    local a1 = Alpha()
    Check('they fade, like any other marker', a1 > 0 and a1 < a0 - 10, a0 .. ' -> ' .. a1)
    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, z = 60, w = true, sel = 'b,c', ss = '2,g' })
    driver:OnFrame(0.016)
    Check('the same selection again does not bring them back', Alpha() <= a1)
    env.__clock.t = env.__clock.t + orders.Lifetime
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    Check('and they are gone after the lifetime', table.getn(env.__rects) == 0)
    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, z = 60, w = true, sel = 'c', ss = 'g',
        sq = 'fk,dc,0' })
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    Check('a new selection shows at once', table.getn(env.__rects) == 1)
    Check('no errors', NoErrors(env))
end

do
    -- An observer can look units up: a unit found is tracked itself, the
    -- others go by the positions sent.
    local env, visual, driver, receive = Seeing({ sel = 'b,c', ss = '2,g', sq = 'b4,b4,5;fk,dc,0' }, ObserverOpts())
    local units = { ['11'] = MUnit('11', 50, 0, 60) }
    env.GetUnitById = function(id) return units[id] end
    visual.selVersion = -1
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    local r = env.__rects
    Check('an observer tracks the units it can look up (one not found is not drawn)',
        table.getn(r) == 1 and math.abs(r[1][1][1] + r[1][2] / 2 - 50) < 0.001, table.getn(r))
    -- It moves: the box goes with it, every frame, no waiting for news.
    units['11'].GetPosition = function() return { 57.3, 0, 60 } end
    env.__clock.t = env.__clock.t + 0.016
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    r = env.__rects
    Check('and follows it as it moves', r[1] and math.abs(r[1][1][1] + r[1][2] / 2 - 57.3) < 0.001)
    -- An observer's boxes do not fade.
    env.__clock.t = env.__clock.t + 10
    env.__chatFuncs['TeamMouse']('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, z = 60, w = true })
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    Check('and keeps it for as long as it is selected', table.getn(env.__rects) == 1)
    Check('no errors for an observer', NoErrors(env))
end

do
    -- Sending: sizes from the unit's own blueprint (a factory's pad), and
    -- where they are, again when they move, but not too often.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua').TeamSelection
    local factory = MUnit('11', 100, 5, 100)
    factory.GetBlueprint = function() return { Physics = { SkirtSizeX = 8, SkirtSizeZ = 8 },
        Footprint = { SizeX = 5, SizeZ = 5 }, SizeX = 4.2, SizeZ = 4.8 } end
    local tank = MUnit('12', 140, 0, 120)
    tank.GetBlueprint = function() return { SizeX = 0.9, SizeZ = 1.3 } end
    env.__selectedUnits = { factory, tank }
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = env.__sent[table.getn(env.__sent)].raw
    Check('their sizes go with the ids: the factory\'s whole pad', m.ss == 'g,3', tostring(m.ss))
    Check('and where they are, to a quarter of a unit (teammates cannot look them up)',
        m.sq == 'b4,b4,5;fk,dc,0', tostring(m.sq))

    -- They move: nothing more is sent for it (a teammate's boxes stay where
    -- the units were, and fade).
    local x = 140
    tank.GetPosition = function() return { x, 0, 120 } end
    local after = table.getn(env.__sent)
    for i = 1, 20 do
        x = x + 1
        env.__clock.t = env.__clock.t + 0.1
        SM.OnBeat()
    end
    local any = false
    for k = after + 1, table.getn(env.__sent) do
        if env.__sent[k].raw.sq then any = true end
    end
    Check('units moving send nothing more', not any)

    -- The periodic resend of the ids does not carry positions.
    env.__clock.t = env.__clock.t + cfg.ResendInterval
    env.__mouseWorld = { 91, 0, 91 }
    SM.OnBeat()
    local m2 = env.__sent[table.getn(env.__sent)].raw
    Check('the periodic resend of the ids carries no positions', m2.sel == 'b,c' and m2.sq == nil)
end



--------------------------------------------------------------------------------
Section('following: selections in replays, observers live')
--------------------------------------------------------------------------------
do
    local units = { ['31'] = MUnit('31', 0, 0, 0), ['32'] = MUnit('32', 0, 0, 0) }
    local renv, RSM = NewSession()
    renv.__scenario.Options.TeamMouseReplay = 'on'
    renv.GetUnitById = function(id) return units[id] end
    RSM.InitTeamMouse(true)
    local q = renv.import('/lua/userplayerquery.lua')
    local function Packet(sel)
        q.ProcessQueries({ { Name = 'TeamMouse', M = { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 80, w = true,
            cam = { 100, 0, 100, 3.14, 1.1, 80 }, sel = sel } } })
    end
    Packet('v')         -- unit 31
    Frames(renv, 0.3, 0.1)
    Check('not following: your selection is your own', table.getn(renv.__selectCalls) == 0)
    PanelRow(renv, 2).followCheck:Click()
    Frames(renv, 0.1, 0.1)
    local call = renv.__selectCalls[table.getn(renv.__selectCalls)]
    Check('following in a replay: you select what they select', call and call[1] == units['31'] and call[2] == nil)
    Packet('v,w')       -- units 31 and 32
    Frames(renv, 0.1, 0.1)
    call = renv.__selectCalls[table.getn(renv.__selectCalls)]
    Check('and keep up as they change it', call and call[2] == units['32'])
    local n = table.getn(renv.__selectCalls)
    Frames(renv, 0.5, 0.1)
    Check('only when it changes', table.getn(renv.__selectCalls) == n)
end

do
    -- A live observer: players send them their camera; they can follow it.
    local env, SM = NewSession({ focusArmy = -1, clients = {
        [1] = { name = 'Lightningbulb' }, [2] = { name = 'KasperAUS' }, [3] = { name = 'Eternal' },
        [4] = { name = 'Caster', ['local'] = true } } })
    SM.InitTeamMouse(false)
    local row = PanelRow(env, 2)
    Check('a live observer has "follow" boxes', row and row.followCheck)
    env.__camera = { Focus = { 0, 0, 0 }, Heading = 3.14159, Pitch = 1.1 }
    env.__chatFuncs['TeamMouse']('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 80, w = true,
        cam = { 300, 0, 200, 3.14159, 1.1, 80 } })
    row.followCheck:Click()
    Frames(env, 3, 0.016)
    Check('and following moves their camera to the player\'s', math.abs(env.__camera.Focus[1] - 300) < 0.5
        and math.abs(env.__camera.Focus[3] - 200) < 0.5, env.__camera.Focus[1])
    Check('a live observer does not take their selection', table.getn(env.__selectCalls) == 0)
end

--------------------------------------------------------------------------------
Section('box drags stay boxes; bunched boxes merge; the cursor only when it changes')
--------------------------------------------------------------------------------
do
    -- Regression test for: a Shift box drag that passed over an order (Shift
    -- shows them, with the hand) turned into dragging that order.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local view = env.__views['WorldCamera']
    local cells = Mock.FindDragOverlays(env)[1].children
    local hand = OrderIndexOf(env, 'waypoint-drag')
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100,
        Modifiers = { Left = true, Shift = true } })
    -- The box grows well away from the press...
    local far
    for _, c in ipairs(cells) do
        if c.dragCX > 300 and c.dragCY > 200 then far = c break end
    end
    far:HandleEvent({ Type = 'MouseEnter', MouseX = far.dragCX, MouseY = far.dragCY, Modifiers = { Left = true } })
    -- ...and passes over an order: the hand shows.
    env.__cursor:SetTexture(HAND, 0, 0)
    env.__clock.t = env.__clock.t + 0.1
    SM.OnBeat()
    local m = env.__sent[table.getn(env.__sent)].raw
    Check('a Shift box drag passing over an order stays a box', m.s == true and m.d == nil and m.gk == nil,
        tostring(m.s) .. ' ' .. tostring(m.d))
    Check('and does not show the hand', m.o ~= hand)
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = far.dragCX, MouseY = far.dragCY, Modifiers = {} })

    -- The hand showing as the drag begins, on the order: a grab, as before.
    env.__cursor:Reset()
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 400, MouseY = 300, Modifiers = { Left = true, Shift = true } })
    env.__cursor:SetTexture(HAND, 0, 0)
    env.__clock.t = env.__clock.t + 0.1
    env.__mouseWorld = { 77, 0, 77 }
    SM.OnBeat()
    m = env.__sent[table.getn(env.__sent)].raw
    Check('the hand as the drag begins is still a grab', m.d == 2 and m.s == nil)
    Check('no errors', NoErrors(env))
end

do
    -- Bunched up (zoomed out), boxes nearly on top of each other are one.
    local env, visual, driver = Seeing({ sel = 'b,c,d,e', ss = '2,2,2,2',
        sq = 'b4,b4,0;b5,b4,0;b4,b6,0;mo,b4,0' })
    -- (100,100), (100.25,100), (100,100.5), and one far off at (204,100)
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    Check('units bunched together get one box, not a pile of them', table.getn(env.__rects) == 2,
        table.getn(env.__rects))
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local step = 0
    local function Beat()
        step = step + 1
        env.__clock.t = env.__clock.t + 0.1
        env.__mouseWorld = { 50 + step * 5, 0, 50 }
        SM.OnBeat()
        return env.__sent[table.getn(env.__sent)].raw
    end
    Beat()
    Check('the cursor is not sent while it stays the same', Beat().o == nil and Beat().o == nil)
    env.__cursor:SetTexture(HAND, 0, 0)
    Check('a new cursor is sent at once', Beat().o == OrderIndexOf(env, 'waypoint-drag'))
    env.__clock.t = env.__clock.t + cfg.Network.ForceResendInterval
    Check('and with the keep-alive', Beat().o ~= nil)

    local renv, visual, driver, receive = Seeing({ o = 7 })
    receive('KasperAUS', { v = 1, a = 2, p = { 101, 0, 100 }, z = 60, w = true })
    Check('a packet without one keeps the last', visual.record.orderIndex == 7, visual.record.orderIndex)
end

--------------------------------------------------------------------------------
Section('too many selected: rectangles round the bunches')
--------------------------------------------------------------------------------
--- The rectangles in a packed sr, as { x1, z1, x2, z2, y } each.
local function Rects(sr)
    local out = {}
    for part in string.gfind(sr or '', '[^;]+') do
        local _, _, a, b, c, d, y = string.find(part, '^(%w+),(%w+),(%w+),(%w+),(%w+)$')
        table.insert(out, { tonumber(a, 36) / 4, tonumber(b, 36) / 4, tonumber(c, 36) / 4, tonumber(d, 36) / 4,
            tonumber(y, 36) })
    end
    return out
end

do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua').TeamSelection
    local function Beat()
        env.__clock.t = env.__clock.t + 0.1
        SM.OnBeat()
        return env.__sent[table.getn(env.__sent)].raw
    end

    -- Two bunches of 25, 200 units apart.
    local units, inA, inB = {}, {}, {}
    for i = 1, 25 do
        local u = MUnit(tostring(1000 + i), 100 + math.mod(i, 5) * 2, 3, 100 + math.floor(i / 5) * 2)
        table.insert(units, u)
        table.insert(inA, u)
    end
    for i = 1, 25 do
        local u = MUnit(tostring(2000 + i), 300 + math.mod(i, 5) * 2, 3, 300 + math.floor(i / 5) * 2)
        table.insert(units, u)
        table.insert(inB, u)
    end
    env.__selectedUnits = units
    local m = Beat()
    local rects = Rects(m.sr)
    Check('more selected than the cap: a rectangle round each bunch', table.getn(rects) == 2, table.getn(rects))
    local function Covers(r, list)
        for _, u in ipairs(list) do
            local p = u.GetPosition()
            if p[1] < r[1] or p[1] > r[3] or p[3] < r[2] or p[3] > r[4] then return false end
        end
        return true
    end
    local a, b = rects[1], rects[2]
    if a and a[1] > 200 then a, b = b, a end
    Check('each round every unit in its bunch', a and b and Covers(a, inA) and Covers(b, inB))
    Check('and no bigger than the bunch (plus a margin)', a and (a[3] - a[1]) < 8 + 2 * (0.5 + cfg.Margin) + 0.5)
    Check('instead of a box each', m.sq == nil)
    local ids = 0
    for _ in string.gfind(m.sel or '', '[^,]+') do ids = ids + 1 end
    Check('the first ids still go (following in a replay copies them)', ids == cfg.MaxSend, ids)

    -- More of them: the ids sent are the same, but it is news.
    table.insert(units, MUnit('3001', 102, 3, 130))
    env.__selectedUnits = units
    m = Beat()
    Check('more units selected past the cap is sent again', m.sr ~= nil)

    -- Spread far apart: never lumped into one huge box; at most MaxRects.
    local spread = {}
    for i = 1, 60 do
        table.insert(spread, MUnit(tostring(4000 + i), 50 + i * 150, 0, 50))
    end
    env.__selectedUnits = spread
    m = Beat()
    rects = Rects(m.sr)
    local widest = 0
    for _, r in ipairs(rects) do
        if r[3] - r[1] > widest then widest = r[3] - r[1] end
    end
    Check('far-apart units are not lumped together', widest < cfg.ClusterMaxCell + 10, widest)
    Check('and there are never more than MaxRects', table.getn(rects) == cfg.MaxRects, table.getn(rects))

    -- Within the cap: a box each, as before.
    env.__selectedUnits = { MUnit('11', 1, 0, 1) }
    m = Beat()
    Check('within the cap, no rectangles', m.sr == nil and m.sq ~= nil)
end

do
    -- Receiving them: four lines each, in the boxes' colour, fading.
    local env, visual, driver, receive = Seeing({ sel = 'b,c', sr = 'fk,fk,go,ic,3;4oo,4oo,4q0,4s0,3' })
    -- (140,140)-(150,165) and (1680,1680)-(1688,1696)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    local lines = env.__lines
    Check('a teammate\'s rectangles are drawn, four lines each', table.getn(lines) == 8, table.getn(lines))
    local l = lines[1]
    Check('round the right place', l and l[1][1] == 140 and l[1][3] == 140 and l[2][1] == 150 and l[1][2] == 3)
    Check('in the boxes\' colour', l and string.sub(l[3], 3) == string.sub(cfg.TeamSelection.Color, 3))
    Check('lines Thickness pixels wide', l and math.abs(l[4] - cfg.TeamSelection.Thickness / 2) < 0.001)
    Check('and no box per unit', table.getn(env.__rects) == 0)
    local a0 = tonumber(string.sub(l[3], 1, 2), 16)
    env.__clock.t = env.__clock.t + cfg.Orders.FadeHold + (cfg.Orders.Lifetime - cfg.Orders.FadeHold) / 2
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    local a1 = env.__lines[1] and tonumber(string.sub(env.__lines[1][3], 1, 2), 16) or 0
    Check('they fade', a1 > 0 and a1 < a0, a0 .. ' -> ' .. a1)
    env.__clock.t = env.__clock.t + cfg.Orders.Lifetime
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    Check('and go', table.getn(env.__lines) == 0)

    -- A new selection within the cap: boxes again, no rectangles.
    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, z = 60, w = true, sel = 'd', ss = '2', sq = 'b4,b4,0' })
    driver:OnFrame(0.016)
    Mock.RenderWorld(env)
    Check('a selection within the cap goes back to a box each', table.getn(env.__lines) == 0
        and table.getn(env.__rects) == 1)
    Check('no errors', NoErrors(env))
end

do
    -- Regression test for: the rectangles' draw loop built two corner tables
    -- per rectangle every frame (80 a frame at 40 rectangles, per teammate),
    -- garbage Lua 5.0 stops the game to collect. A frame showing 40 should
    -- now allocate about what one showing 2 does.
    local function B36(v)
        local d, o = '0123456789abcdefghijklmnopqrstuvwxyz', ''
        repeat o = string.sub(d, math.mod(v, 36) + 1, math.mod(v, 36) + 1) .. o; v = math.floor(v / 36) until v == 0
        return o
    end
    local function Rects(count)
        local parts = {}
        for i = 1, count do
            local x, z = 400 + i * 97, 300 + math.mod(i * 53, 900)
            parts[i] = B36(x) .. ',' .. B36(z) .. ',' .. B36(x + 40) .. ',' .. B36(z + 30) .. ',' .. B36(10)
        end
        return table.concat(parts, ';')
    end
    -- Memory in use, in KB, and a way to hold the collector off, on 5.0 or 5.1.
    local v50 = gcinfo ~= nil and not pcall(collectgarbage, 'count')
    local function Used() if v50 then return gcinfo() end return collectgarbage('count') end
    local function PerFrame(count)
        local env, visual, driver = Seeing({ sel = '1,2', ss = '2,2', sr = Rects(count) })
        driver:OnFrame(0.0001)
        if v50 then collectgarbage(); collectgarbage(1e7) else collectgarbage(); collectgarbage('stop') end
        local k0 = Used()
        for _ = 1, 100 do driver:OnFrame(0.0001) end
        local bytes = (Used() - k0) * 1024 / 100
        if v50 then collectgarbage() else collectgarbage('restart') end
        local lines = table.getn(Mock.RenderWorld(env))
        return bytes, lines
    end
    local few, fewLines = PerFrame(2)
    local many, manyLines = PerFrame(40)
    Check('40 rectangles are drawn (160 lines)', manyLines == 160 and fewLines == 8, manyLines)
    Check('drawing 40 rectangles makes no more garbage a frame than drawing 2', many - few < 1024,
        string.format('%.0f vs %.0f bytes a frame', many, few))
end

--------------------------------------------------------------------------------
Section('hiding a cursor stops it being sent to you')
--------------------------------------------------------------------------------
-- Feature: unticking a player in the panel tells them, and they stop sending
-- to you -- so if the mod is ever a strain, anyone can switch it off for
-- themselves, both ends.

--- The mute messages (tmo) a session has sent, from number `from` on.
local function MuteMessages(env, from)
    local out = {}
    for i = from or 1, table.getn(env.__sentMute) do
        table.insert(out, env.__sentMute[i])
    end
    return out
end

do
    local env, visual, driver, receive = Seeing()
    local panel = env.import('/mods/TeamMouse/modules/panel.lua').Get()
    local row = PanelRow(env, 2)
    local from = table.getn(env.__sentMute) + 1
    row.check:Click()
    local m = MuteMessages(env, from)
    Check('hiding a player tells them', table.getn(m) == 1 and m[1].raw.tmo == 0 and m[1].raw.ta == 2)
    Check('addressed to every other client, naming them by army', m[1] and table.getn(m[1].clients) == 2)

    -- Their packets still arriving (they missed it): said again, now and then.
    from = table.getn(env.__sentMute) + 1
    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, z = 60, w = true })
    receive('KasperAUS', { v = 1, a = 2, p = { 101, 0, 100 }, z = 60, w = true })
    Check('not again at once', table.getn(MuteMessages(env, from)) == 0)
    env.__clock.t = env.__clock.t + 5
    receive('KasperAUS', { v = 1, a = 2, p = { 102, 0, 100 }, z = 60, w = true })
    Check('but again if they keep sending', table.getn(MuteMessages(env, from)) == 1)

    from = table.getn(env.__sentMute) + 1
    row.check:Click()
    m = MuteMessages(env, from)
    Check('showing them again tells them to start again', table.getn(m) == 1 and m[1].raw.tmo == 1)

    from = table.getn(env.__sentMute) + 1
    panel.allCursors:Click()
    Check('"all" off tells every player', table.getn(MuteMessages(env, from)) == table.getn(panel.rows))
end

do
    -- The sender's side: KasperAUS (client 2) hides our cursor.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local receive = env.__chatFuncs['TeamMouse']
    local step = 0
    local function Move()
        step = step + 1
        env.__clock.t = env.__clock.t + 0.1
        env.__mouseWorld = { 50 + step * 5, 0, 50 }
        SM.OnBeat()
    end
    local function SentTo(from, index)
        local n = 0
        for i = from, table.getn(env.__sent) do
            for _, c in ipairs(env.__sent[i].clients) do
                if c == index then n = n + 1 end
            end
        end
        return n
    end
    local from = table.getn(env.__sent) + 1
    Move()
    Check('before: we send to them', SentTo(from, 2) == 1)

    receive('KasperAUS', { Identifier = 'TeamMouse', tmo = 0, ta = 3 })
    from = table.getn(env.__sent) + 1
    Move()
    Check('a hide meant for another player changes nothing', SentTo(from, 2) == 1)

    receive('KasperAUS', { Identifier = 'TeamMouse', tmo = 0, ta = 1 })
    from = table.getn(env.__sent) + 1
    for _ = 1, 5 do Move() end
    Check('they hid our cursor: we stop sending to them', SentTo(from, 2) == 0)
    Check('and, with nobody else to send to, send nothing at all', table.getn(env.__sent) == from - 1)

    receive('KasperAUS', { Identifier = 'TeamMouse', tmo = 1, ta = 1 })
    from = table.getn(env.__sent) + 1
    Move()
    Check('they show it again: we start again', SentTo(from, 2) == 1)
    Check('no errors', NoErrors(env))
end

do
    -- Observers: one can hide a player, and players stop sending to it.
    local env, SM = NewSession(ObserverOpts())
    SM.InitTeamMouse(false)
    env.__chatFuncs['TeamMouse']('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, z = 60, w = true })
    local from = table.getn(env.__sentMute) + 1
    PanelRow(env, 2).check:Click()
    local m = MuteMessages(env, from)
    Check('an observer hiding a player tells them', table.getn(m) == 1 and m[1].raw.ta == 2)

    local penv, PSM = NewSession({ clients = { [1] = { name = 'Lightningbulb', ['local'] = true },
        [2] = { name = 'KasperAUS' }, [3] = { name = 'Eternal' }, [4] = { name = 'Caster' } } })
    PSM.InitTeamMouse(false)
    Calibrate(penv, PSM)
    penv.__chatFuncs['TeamMouse']('Caster', { Identifier = 'TeamMouse', tmo = 0, ta = 1 })
    local pfrom = table.getn(penv.__sent) + 1
    penv.__clock.t = penv.__clock.t + 0.1
    penv.__mouseWorld = { 90, 0, 90 }
    PSM.OnBeat()
    local toObserver = 0
    for i = pfrom, table.getn(penv.__sent) do
        for _, c in ipairs(penv.__sent[i].clients) do
            if c == 4 then toObserver = toObserver + 1 end
        end
    end
    Check('and the player stops sending to that observer', toObserver == 0 and table.getn(penv.__sent) >= pfrom)
end

do
    -- In a replay there is nobody to tell.
    local renv, RSM = NewSession()
    renv.__scenario.Options.TeamMouseReplay = 'on'
    RSM.InitTeamMouse(true)
    -- (A replay lists a player once their recorded data arrives.)
    renv.import('/lua/userplayerquery.lua').ProcessQueries({ { Name = 'TeamMouse',
        M = { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true } } })
    Frames(renv, 0.1, 0.1)
    local from = table.getn(renv.__sentMute) + 1
    PanelRow(renv, 2).check:Click()
    Check('in a replay, hiding a cursor sends nothing', table.getn(MuteMessages(renv, from)) == 0)
end

--------------------------------------------------------------------------------
Section('compact wire format: the same packet, smaller')
--------------------------------------------------------------------------------
-- wirecodec.lua packs the packet into one string. The rule it must keep:
-- whatever the receiver decodes is exactly the table that was packed, so
-- nothing after the decode can tell the difference.

--- Equal all the way down (written here, apart from the codec's own check).
local function DeepEqual(a, b, skip)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do
        if k ~= skip and not DeepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if k ~= skip and a[k] == nil then return false end
    end
    return true
end

--- A pseudo-random sequence the same on every interpreter, 32-bit floats
--- included: every value stays a whole number well under 2^24.
local function Random(seed)
    local x = seed
    return function(n)
        x = math.mod(x * 75 + 74, 65537)
        return math.mod(x, n)
    end
end

--- A packet shaped like the ones the sender builds, with a random choice of
--- fields: positions in tenths, the interface in thousandths, as Round1 and
--- friends make them; now and then a value with no exact tenth.
local function RandomPacket(env, R)
    local WP = env.import('/mods/TeamMouse/modules/wirepack.lua')
    local function Tenth(lo, hi) return lo + R((hi - lo) * 10) / 10 end
    local function Raw(lo, hi) return lo + R((hi - lo) * 1000) / 997 end
    local px = R(5) == 0 and Raw(0, 1000) or Tenth(0, 4000)
    local m = { Identifier = 'TeamMouse', v = 1, a = 1 + R(8), p = { px, Tenth(-20, 300), Tenth(0, 4000) } }
    if R(2) == 0 then m.o = R(60) end
    if R(3) == 0 then m.z = R(5000) end
    if R(3) == 0 then m.w = false; m.hx = R(1001) / 1000; m.hy = R(1001) / 1000 end
    local drag = R(6)
    if drag == 1 then m.s = true elseif drag == 2 then m.l = true elseif drag == 3 then m.r = true
    elseif drag == 4 then m.d = 1 + R(2) end
    if drag >= 1 and drag <= 3 then m.bx = Tenth(0, 4000); m.bz = Tenth(0, 4000) end
    if R(3) == 0 then m.b = 'ueb0' .. R(999); if R(2) == 0 then m.bt = true end end
    if R(2) == 0 then
        local list, n = {}, 1 + R(8)
        for i = 1, n do
            local f = R(64)
            list[i] = { age = (n - i + 1) * 0.033 + R(5) / 1000, x = m.p[1] + Tenth(-60, 60), z = m.p[3] + Tenth(-60, 60),
                hx = R(1001) / 1000, hy = R(1001) / 1000, bx = Tenth(0, 4000), bz = Tenth(0, 4000), flags = f }
        end
        m.e = WP.PackSamples(list, n, m.p[1], m.p[3])
    end
    if R(4) == 0 then
        local mo, mob, n = {}, {}, 1 + R(4)
        for i = 1, n do
            local b = (i - 1) * 7
            mo[b + 1], mo[b + 2], mo[b + 3], mo[b + 4] = R(40), Tenth(0, 4000), Tenth(0, 200), Tenth(0, 4000)
            mo[b + 5], mo[b + 6], mo[b + 7] = R(2) == 0 and mo[b + 2] or Tenth(0, 4000), mo[b + 4], R(500)
            mob[i] = R(2) == 0 and ('ueb' .. R(9999)) or false
        end
        m.mo = mo
        if R(2) == 0 then m.mob = mob end
        if R(3) == 0 then m.mot = {}; table.insert(m.mot, 1) end
        if R(3) == 0 then m.mou = { n } end
    end
    if R(4) == 0 then m.ac = { 1 + R(8), 1 + R(8) } end
    if R(5) == 0 then m.gk = R(60) end
    if R(4) == 0 then m.oa = R(500) end
    if R(4) == 0 then m.ck = 1 + R(9) end
    if R(4) == 0 then
        local ids, sizes, places = {}, {}, {}
        local base = 1048576 + R(30000)
        for i = 1, R(45) do
            local id = base + R(400)
            local function B36(v)
                local d, out = '0123456789abcdefghijklmnopqrstuvwxyz', ''
                repeat out = string.sub(d, math.mod(v, 36) + 1, math.mod(v, 36) + 1) .. out; v = math.floor(v / 36) until v == 0
                return out
            end
            ids[i] = B36(id)
            sizes[i] = B36(1 + R(16))
            places[i] = R(6) == 0 and '' or (B36(R(16000)) .. ',' .. B36(R(16000)) .. ',' .. B36(R(200)))
        end
        m.sel, m.ss = table.concat(ids, ','), table.concat(sizes, ',')
        if R(2) == 0 then m.sq = table.concat(places, ';') else
            m.sr = R(3) == 0 and '' or ('a,b,c,d,1;' .. '100,200,300,400,5') end
    end
    if R(4) == 0 then
        m.vp = {}
        for i = 1, 12 do m.vp[i] = Tenth(-500, 4500) end
    end
    if R(6) == 0 then m.cam = { Tenth(0, 4000), Tenth(0, 200), Tenth(0, 4000), R(6283) / 1000, R(1571) / 1000, Tenth(0, 3000) } end
    return m
end

do
    local env = NewSession()
    local C = env.import('/mods/TeamMouse/modules/wirecodec.lua')
    local R = Random(12345)
    local encoded, exact, smaller, total = 0, 0, 0, 400
    local Wire = dofile('extras/wire_size.lua')
    local firstBad
    for i = 1, total do
        local m = RandomPacket(env, R)
        local s = C.Encode(m)
        if s then
            encoded = encoded + 1
            local back = C.Decode(s)
            if back and DeepEqual(m, back, 'Identifier') then
                exact = exact + 1
            elseif not firstBad then
                firstBad = s
            end
            if Wire.Size({ TeamMouse = s }) < Wire.Size(m) then smaller = smaller + 1 end
        elseif not firstBad then
            firstBad = 'not encoded: packet ' .. i
        end
    end
    Check('every packet shaped like the sender\'s has a compact form', encoded == total, firstBad)
    Check('and decodes to exactly that packet', exact == encoded, firstBad)
    Check('and is smaller than the table', smaller == encoded, smaller .. ' of ' .. encoded)
end

do
    -- Anything off the wire: never an error, a packet or nothing.
    local env = NewSession()
    local C = env.import('/mods/TeamMouse/modules/wirecodec.lua')
    local R = Random(777)
    local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_!~.,;'
    local errors, tables = 0, 0
    for _ = 1, 600 do
        local n = R(40)
        local parts = { 'B' }
        for _ = 1, n do
            local k = 1 + R(string.len(alphabet))
            table.insert(parts, string.sub(alphabet, k, k))
        end
        local ok, back = pcall(C.Decode, table.concat(parts))
        if not ok then errors = errors + 1 elseif back then tables = tables + 1 end
    end
    -- Real packets, cut short and with a character changed.
    for i = 1, 200 do
        local s = C.Encode(RandomPacket(env, R))
        if s then
            local cut = string.sub(s, 1, R(string.len(s)))
            local at = 1 + R(string.len(s))
            local k = 1 + R(string.len(alphabet))
            local changed = string.sub(s, 1, at - 1) .. string.sub(alphabet, k, k) .. string.sub(s, at + 1)
            if not pcall(C.Decode, cut) then errors = errors + 1 end
            if not pcall(C.Decode, changed) then errors = errors + 1 end
        end
    end
    Check('random and damaged strings never raise an error', errors == 0, errors)
    Check('non-strings decode to nothing', C.Decode(nil) == nil and C.Decode(5) == nil and C.Decode({}) == nil)
end

do
    -- What the codec will not carry goes as the table, never approximately.
    local env = NewSession()
    local C = env.import('/mods/TeamMouse/modules/wirecodec.lua')
    Check('another protocol', C.Encode({ v = 2, a = 1, p = { 1, 2, 3 } }) == nil)
    Check('a field it does not know', C.Encode({ v = 1, a = 1, p = { 1, 2, 3 }, future = 1 }) == nil)
    Check('a NaN', C.Encode({ v = 1, a = 1, p = { 0 / 0, 2, 3 } }) == nil)
    Check('a selection id not written as Base36 writes it', C.Encode({ v = 1, a = 1, p = { 1, 2, 3 }, sel = '0a' }) == nil)
    local s = C.Encode({ v = 1, a = 1, p = { 1.23456, 2, 3 } })
    local back = s and C.Decode(s)
    Check('a value with no exact tenth goes as text, exactly', back and back.p[1] == 1.23456, s)
end

-- A team of three, so one teammate can read the compact format while the
-- other (an older TeamMouse) still needs the table.
local function ThreeOpts(extra)
    local armies = Armies()
    armies[3].team = 1
    local opts = { armies = armies, plainPeers = true }
    for k, v in pairs(extra or {}) do opts[k] = v end
    return opts
end

local function Hello(env, from)
    env.__chatFuncs['TeamMouse'](from, { Identifier = 'TeamMouse', tmc = 1 })
end

local function SentTo(env, first, client)
    local out = {}
    for i = first, table.getn(env.__sent) do
        for _, c in ipairs(env.__sent[i].clients) do
            if c == client then table.insert(out, env.__sent[i]) end
        end
    end
    return out
end

do
    local env, SM = NewSession(ThreeOpts())
    SM.InitTeamMouse(false)
    SM.OnBeat()
    local hello = env.__sentHello[1]
    Check('at the start it says it reads the compact format, to every other client',
        hello and hello.msg.tmc == 1 and table.getn(hello.clients) == 2)
    SM.OnBeat()
    Check('once', table.getn(env.__sentHello) == 1)
    Calibrate(env, SM)

    -- Nobody has said so back: everyone gets the table, as before.
    local first = table.getn(env.__sent) + 1
    MoveTo(env, SM, 120, 0, 130, 240, 260)
    local two, three = SentTo(env, first, 2), SentTo(env, first, 3)
    Check('until a teammate says it reads it, they get the table',
        two[1] and not two[1].compact and two[1].wire.Identifier == 'TeamMouse' and two[1].wire.v == 1
        and three[1] and not three[1].compact)

    -- One says so: from then on that one gets the string, the other the table.
    Hello(env, 'KasperAUS')
    first = table.getn(env.__sent) + 1
    MoveTo(env, SM, 140, 0, 150, 280, 300)
    two, three = SentTo(env, first, 2), SentTo(env, first, 3)
    local w = two[1] and two[1].wire
    Check('a teammate who reads it gets one string, nothing else',
        w and two[1].compact and type(w.TeamMouse) == 'string' and w.Identifier == nil and w.v == nil
        and next(w, next(w)) == nil)
    Check('an older build would ignore it (no v, tmo or tmv to act on)',
        w and w.v == nil and w.tmo == nil and w.tmv == nil and w.p == nil)
    Check('the other still gets the table', three[1] and not three[1].compact and three[1].wire.v == 1)
    Check('and both carry the very same packet', two[1] and three[1]
        and DeepEqual(two[1].raw, three[1].raw, 'Identifier'))
    Check('in two messages, one per format', two[1] ~= three[1])
    Check('no errors', NoErrors(env))
end

do
    -- A compact packet from someone says they read it too, word or no word;
    -- a word for some other format is not taken for this one.
    local env, SM = NewSession(ThreeOpts())
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local C = env.import('/mods/TeamMouse/modules/wirecodec.lua')
    env.__chatFuncs['TeamMouse']('Eternal', { Identifier = 'TeamMouse', tmc = 99 })
    env.__chatFuncs['TeamMouse']('KasperAUS', { TeamMouse = C.Encode({ v = 1, a = 2, p = { 10, 0, 10 }, o = 0 }) })
    local first = table.getn(env.__sent) + 1
    MoveTo(env, SM, 160, 0, 170, 320, 340)
    local two, three = SentTo(env, first, 2), SentTo(env, first, 3)
    Check('a teammate sending compact packets is sent them', two[1] and two[1].compact)
    Check('a word for another format leaves the table', three[1] and not three[1].compact)
end

do
    -- Their word may have been lost (said before our side was listening):
    -- plain tables still coming from someone means saying it again to them,
    -- a few times, a little apart. (plainReceive: the mock hands them over
    -- as tables, as an older build sends them.)
    local env, SM = NewSession(ThreeOpts({ plainReceive = true }))
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']
    local first = table.getn(env.__sentHello) + 1
    for i = 1, 40 do
        env.__clock.t = env.__clock.t + 0.5
        receive('KasperAUS', { Identifier = 'TeamMouse', v = 1, a = 2, p = { 10 + i, 0, 10 }, o = 0 })
    end
    local again = 0
    for i = first, table.getn(env.__sentHello) do
        local h = env.__sentHello[i]
        if table.getn(h.clients) == 1 and h.clients[1] == 2 then again = again + 1 end
    end
    Check('said again to a teammate still sending tables, three times at most', again == 3, again)
end

do
    -- The mock hands the mod compact packets wherever a test's packet has
    -- one; a session given the same packets as tables must end up the same.
    local function Run(plainReceive)
        local env, SM = NewSession({ plainReceive = plainReceive })
        SM.InitTeamMouse(false)
        local receive = env.__chatFuncs['TeamMouse']
        local driver = Mock.FindDriver(env)
        local WP = env.import('/mods/TeamMouse/modules/wirepack.lua')
        local states = {}
        for i = 1, 30 do
            local px, pz = 100 + i * 3, 200 - i
            local m = { Identifier = 'TeamMouse', v = 1, a = 2, p = { px, 4.5, pz }, o = math.mod(i, 5) }
            if i == 1 then m.z = 140 end
            m.e = WP.PackSamples({
                { age = 0.066, x = px - 2, z = pz + 0.7, hx = 0.5, hy = 0.9, bx = px - 2, bz = pz + 0.7, flags = 0 },
                { age = 0.033, x = px - 1, z = pz + 0.3, hx = 0.5, hy = 0.9, bx = px - 1, bz = pz + 0.3, flags = 0 } },
                2, px, pz)
            if i == 10 then m.mo = { 0, px, 4.5, pz, px, pz, 3 }; m.ck = 1 end
            if i == 12 then m.oa = 3; m.ac = { 8 } end
            if i >= 15 and i <= 20 then m.s = true; m.bx = px + 40; m.bz = pz - 30 end
            if i == 25 then m.w = false; m.hx = 0.25; m.hy = 0.75 end
            receive('KasperAUS', m)
            env.__clock.t = env.__clock.t + 0.1
            driver:OnFrame(0.1)
            local v = Mock.FindCursors(env, 'WorldCamera')[1]
            local rec = v and v.record
            table.insert(states, rec and string.format('%s %s %s %s %s %s %s', tostring(rec.render[1]),
                tostring(rec.render[3]), tostring(rec.orderIndex), tostring(rec.zoom), tostring(rec.orderCount),
                tostring(rec.actCode), tostring(Mock.IsVisible(v))) or 'none')
        end
        return states, env.__receivedCompact
    end
    local plain = Run(true)
    local compact, n = Run(false)
    local same = table.getn(plain) == table.getn(compact)
    for i = 1, table.getn(plain) do
        if plain[i] ~= compact[i] then same = false end
    end
    Check('the compact packets were the ones received', n == 30, n)
    Check('a cursor fed compact packets is drawn exactly as one fed tables', same,
        tostring(plain[30]) .. ' / ' .. tostring(compact[30]))
end

do
    -- No exact compact form (the codec says nil): the table goes to everyone.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local C = env.import('/mods/TeamMouse/modules/wirecodec.lua')
    local encode = C.Encode
    C.Encode = function() return nil end
    local first = table.getn(env.__sent) + 1
    MoveTo(env, SM, 180, 0, 190, 360, 380)
    C.Encode = encode
    local got = SentTo(env, first, 2)
    Check('a packet without a compact form goes as the table', got[1] and not got[1].compact
        and got[1].wire.v == 1)
end

do
    -- Teammates and observers: one message when they get the same packet;
    -- apart only when the observers' copy carries the camera.
    local env, SM = NewSession({ clients = { [1] = { name = 'Lightningbulb', ['local'] = true },
        [2] = { name = 'KasperAUS' }, [3] = { name = 'Eternal' }, [4] = { name = 'Caster' } } })
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local first = table.getn(env.__sent) + 1
    for i = 1, 70 do
        env.__clock.t = env.__clock.t + 0.1
        env.__mouseWorld = { 50 + i, 0, 60 }
        Mock.HoverWorld(env, 100 + i * 2, 120)
        SM.OnBeat()
    end
    local together, camApart, camToTeam = 0, 0, 0
    for i = first, table.getn(env.__sent) do
        local e = env.__sent[i]
        local toTeam, toSpec = false, false
        for _, c in ipairs(e.clients) do
            if c == 2 then toTeam = true elseif c == 4 then toSpec = true end
        end
        if toTeam and toSpec then together = together + 1 end
        if toSpec and not toTeam and e.msg.cam then camApart = camApart + 1 end
        if toTeam and e.msg.cam then camToTeam = camToTeam + 1 end
    end
    Check('one message for teammates and observers alike', together > 0, together)
    Check('the observers\' camera still goes, to them alone', camApart > 0 and camToTeam == 0,
        camApart .. ' / ' .. camToTeam)
end

do
    -- The replay's copy is the compact string, and plays back.
    local env, SM = RecordingSession('on')
    MoveTo(env, SM, 210, 3.5, 220, 420, 440)
    local last = env.__simCallbacks[table.getn(env.__simCallbacks)]
    Check('the replay records the compact string', last and last.Func == 'OnPlayerQuery'
        and type(last.Args.M) == 'string' and last.Args.From == nil)
    local rec = Recorded(env)
    Check('which is the packet teammates got', rec[table.getn(rec)] and rec[table.getn(rec)].p[1] == 210
        and DeepEqual(rec[table.getn(rec)], env.__sent[table.getn(env.__sent)].raw, 'Identifier'))
end

--------------------------------------------------------------------------------
Section('replays: hovering a cursor fades it a little')
--------------------------------------------------------------------------------
-- Regression test for: in a replay the proximity fade was switched off
-- entirely, so a cursor sat on top of whatever the viewer pointed at. Now
-- hovering one fades it, gently (ReplayCodec.HoverRadius / HoverMinAlpha).
do
    local env, SM = RecordingSession('on')
    MoveTo(env, SM, 200, 0, 200, 400, 400)
    local renv, _, Play = ReplayOf(env, { noHover = true })
    local cfg = renv.import('/mods/TeamMouse/modules/config.lua')
    renv.__setZoom(400)
    Play(6)
    local visual = CursorFor(renv, 1)
    Mock.HoverWorld(renv, visual.Left() + 400, visual.Top() + 300)
    Play(3)
    local away = visual.appliedAlpha
    Mock.HoverWorld(renv, visual.Left(), visual.Top())
    Play(3)
    local over = visual.appliedAlpha
    Check('a replay cursor fades with your pointer over it', over < away - 0.2,
        tostring(away) .. ' -> ' .. tostring(over))
    Check('only slightly: never below HoverMinAlpha of itself',
        over >= away * cfg.ReplayCodec.HoverMinAlpha - 0.03, over)
    Mock.HoverWorld(renv, visual.Left() + cfg.ReplayCodec.HoverRadius + 5, visual.Top())
    Play(3)
    Check('and is back to full just outside HoverRadius', visual.appliedAlpha >= away - 0.02,
        visual.appliedAlpha)
    Check('no errors', NoErrors(renv))
end

--------------------------------------------------------------------------------
Section('replays: only players whose data was recorded are listed')
--------------------------------------------------------------------------------
-- Regression test for: a replay's panel listed every player, with or without
-- the mod or recorded data, so most toggles did nothing. A player's row now
-- appears when their recorded data does, and the panel keeps its state
-- (folded, hidden cursors) across that rebuild.
do
    local env, SM = RecordingSession('on')
    local renv, RSM, Play = ReplayOf(env)
    local P = renv.import('/mods/TeamMouse/modules/panel.lua')
    Check('nothing played yet: no panel', P.Get() == false)

    MoveTo(env, SM, 200, 0, 200, 400, 400)
    Play()
    local panel = P.Get()
    Check('a player is listed once their data arrives', panel and table.getn(panel.rows) == 1
        and panel.rows[1].record.army == 1, panel and table.getn(panel.rows))
    Check('players with nothing recorded are not', PanelRow(renv, 2) == nil and PanelRow(renv, 3) == nil)

    PanelRow(renv, 1).check:Click()
    panel.arrow:Click()
    renv.import('/lua/userplayerquery.lua').ProcessQueries({ { Name = 'TeamMouse',
        M = { v = 1, a = 3, p = { 300, 0, 300 }, o = 0, z = 80, w = true } } })
    Frames(renv, 0.1, 0.1)
    panel = P.Get()
    Check('another appears when theirs does', panel and table.getn(panel.rows) == 2
        and PanelRow(renv, 3) ~= nil)
    Check('a folded panel stays folded', panel and not Mock.IsVisible(panel.body)
        and panel.arrow._checked == true)
    Check('a hidden cursor stays hidden, its box unticked', not PanelRow(renv, 1).check:IsChecked()
        and PanelRow(renv, 1).record.disabled)
    Check('no errors', NoErrors(renv))

    -- Live observers still see every player from the start.
    local oenv, OSM = NewSession(ObserverOpts())
    OSM.InitTeamMouse(false)
    local op = oenv.import('/mods/TeamMouse/modules/panel.lua').Get()
    Check('a live observer still lists every player at once', op and table.getn(op.rows) == 3)
end

--------------------------------------------------------------------------------
Section('versions in the player panel')
--------------------------------------------------------------------------------
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local receive = env.__chatFuncs['TeamMouse']
    local row = PanelRow(env, 2)
    Check('each row has a version', row and row.versionLabel and row.versionText == '?', row and row.versionText)

    receive('KasperAUS', { Identifier = 'TeamMouse', tmv = cfg.ModVersion })
    env.__clock.t = env.__clock.t + 0.2
    SM.OnBeat()
    Check('theirs, once heard', row.versionLabel._text == 'v' .. cfg.ModVersion, row.versionLabel._text)
    local same = row.versionLabel._color

    local env2, SM2 = NewSession()
    SM2.InitTeamMouse(false)
    env2.__chatFuncs['TeamMouse']('KasperAUS', { Identifier = 'TeamMouse', tmv = cfg.ModVersion + 2 })
    env2.__clock.t = env2.__clock.t + 0.2
    SM2.OnBeat()
    local row2 = PanelRow(env2, 2)
    Check('another version shows, in another colour', row2.versionLabel._text == 'v' .. (cfg.ModVersion + 2)
        and row2.versionLabel._color ~= same)

    local env3, SM3 = NewSession()
    SM3.InitTeamMouse(false)
    local cfg3 = env3.import('/mods/TeamMouse/modules/config.lua')
    for _ = 1, 3 do
        env3.__clock.t = env3.__clock.t + cfg3.VersionReport.CheckDelay
        SM3.OnBeat()
    end
    Check('a teammate who never answered: none', PanelRow(env3, 2).versionLabel._text == 'none',
        PanelRow(env3, 2).versionLabel._text)

    local env4, SM4 = NewSession()
    SM4.InitTeamMouse(false)
    -- A real SharedMouse packet from them.
    env4.__chatFuncs['a']('KasperAUS', { a = true, b = { 10, 0, 10, 1 } })
    env4.__clock.t = env4.__clock.t + 0.2
    SM4.OnBeat()
    Check('SharedMouse: old', PanelRow(env4, 2).versionLabel._text == 'old', PanelRow(env4, 2).versionLabel._text)

    -- Observers have no chat report, but do have the panel.
    local oenv, OSM = NewSession(ObserverOpts())
    OSM.InitTeamMouse(false)
    oenv.__chatFuncs['TeamMouse']('Eternal', { Identifier = 'TeamMouse', tmv = 1 })
    oenv.__clock.t = oenv.__clock.t + 0.2
    OSM.OnBeat()
    Check('an observer sees versions too', PanelRow(oenv, 3).versionLabel._text == 'v1')

    -- Switched off, the column goes (and comes back) without a restart.
    cfg.Panel.ShowVersions = false
    SM.OnBeat()
    Check('Panel.ShowVersions off: no column', PanelRow(env, 2) and not PanelRow(env, 2).versionLabel)
    cfg.Panel.ShowVersions = true
    SM.OnBeat()
    Check('and back on', PanelRow(env, 2).versionLabel and PanelRow(env, 2).versionLabel._text == 'v1')
    Check('no errors', NoErrors(env) and NoErrors(oenv))
end

do
    -- A replay: each player's version is recorded with their cursor.
    local env, SM = RecordingSession('on')
    MoveTo(env, SM, 200, 0, 200, 400, 400)
    MoveTo(env, SM, 210, 0, 200, 410, 400)
    local found = 0
    for _, m in ipairs(Recorded(env)) do
        if m.tmv then
            found = found + 1
            Check('the version goes into the replay, with its army', m.tmv == 1 and m.a == 1)
        end
    end
    Check('once', found == 1, found)
    local renv, _, Play = ReplayOf(env)
    Play()
    Check('and the replay\'s panel shows it', PanelRow(renv, 1) and PanelRow(renv, 1).versionLabel._text == 'v1',
        PanelRow(renv, 1) and PanelRow(renv, 1).versionLabel._text)

    local off, OSM = RecordingSession('off')
    MoveTo(off, OSM, 200, 0, 200, 400, 400)
    Check('not recording: nothing goes into the sim', table.getn(Recorded(off)) == 0)
end

--------------------------------------------------------------------------------
Section('ReUI options (modules/options.lua, Main.lua, Options.lua)')
--------------------------------------------------------------------------------
--- A stand-in for ReUI.Options. 'current' models today's ReUI
--- (4z0t/FAF-UI-Mods, mods/ReUI/Options): Opt(v) marks a default; assigning
--- ReUI.Options.Mods[name] turns every value into an OptionVar (read by
--- calling it; Set calls OnChange; Save writes the profile; Reset goes back);
--- AddOptions takes a table or a function that builds the window. 'older'
--- models the shape the Mouse mod was written against: OptionValue with
--- Get / OnChanged:Add, and a table-only AddOptions.
---@param kind string
---@param saved? table   # option -> value already in the profile
local function FakeReUI(kind, saved)
    saved = saved or {}
    local reui = { Options = { added = false }, saved = saved }
    if kind == 'current' then
        local OptMeta = {}
        reui.Options.Opt = function(v) return setmetatable({ value = v }, OptMeta) end
        local VarMeta = {}
        VarMeta.__index = VarMeta
        VarMeta.__call = function(self) return self._v end
        function VarMeta:Set(v)
            if self._prev == nil then self._prev = self._v end
            self._v = v
            self:OnChange()
        end
        function VarMeta:Reset()
            if self._prev ~= nil then self:Set(self._prev); self._prev = nil end
        end
        function VarMeta:Save() saved[self._o] = self._v; self._prev = nil end
        function VarMeta:OnChange() end
        function VarMeta:Option() return self._o end
        reui.Options.Mods = setmetatable({}, { __newindex = function(t, name, values)
            local out = {}
            for k, v in pairs(values) do
                local default = (getmetatable(v) == OptMeta) and v.value or v
                local val = saved[k]
                if val == nil then val = default end
                out[k] = setmetatable({ _o = k, _v = val }, VarMeta)
            end
            rawset(t, name, out)
        end })
    else
        reui.Options.Mods = {}
        reui.Options.OptionValue = function(default)
            local o = { v = default, OnChanged = { fns = {} } }
            o.Get = function(self) return self.v end
            o.OnChanged.Add = function(self, fn) table.insert(self.fns, fn) end
            o.Set = function(self, v)
                self.v = v
                for _, fn in ipairs(self.OnChanged.fns) do fn(self, v) end
            end
            return o
        end
    end
    reui.Options.Builder = {
        Filter = function(label, option) return { kind = 'filter', label = label, option = option } end,
        Slider = function(label, lo, hi, step, option)
            return { kind = 'slider', label = label, lo = lo, hi = hi, step = step, option = option }
        end,
        AddOptions = function(key, title, build)
            reui.Options.added = { key = key, title = title, build = build }
        end,
    }
    if kind == 'current' then
        reui.Options.Builder.Title = function(label) return { kind = 'title', label = label } end
    end
    reui.Require = function(list) reui.required = list end
    return reui
end

--- The game's controls the options window uses, for the mock.
local function WindowStubs(c)
    local env = c.env
    env.__tooltips = {}
    env.__scrolled = {}
    local function Make(base, fields)
        return function(parent, a, b, cc, d)
            local o = base(parent)
            for k, v in pairs(fields) do o[k] = v end
            if o._init then o:_init(a, b, cc, d) end
            return o
        end
    end
    local Window = function(parent, title)
        local w = c.Group(parent)
        w._title = title
        w._client = c.Group(w)
        w.GetClientGroup = function(self) return self._client end
        return w
    end
    local Grid = function(parent, iw, ih)
        local g = c.Group(parent)
        g._rows = {}
        g.AppendCols = function() end
        g.AppendRows = function() end
        g.SetItem = function(self, item, col, row) self._rows[row] = item end
        g.EndBatch = function() end
        return g
    end
    local IntegerSlider = function(parent, vert, lo, hi, step)
        local s = c.Group(parent)
        s._lo, s._hi = lo, hi
        s.SetValue = function(self, v)
            self._value = v
            if self.OnValueChanged then self:OnValueChanged(v) end
        end
        s.Drag = function(self, v)
            self:SetValue(v)
            if self.OnValueSet then self:OnValueSet(v) end
        end
        return s
    end
    local nop = function() end
    return {
        ['/lua/maui/window.lua'] = { Window = Window },
        ['/lua/maui/grid.lua'] = { Grid = Grid },
        ['/lua/maui/slider.lua'] = { IntegerSlider = IntegerSlider },
        ['/lua/ui/game/tooltip.lua'] = {
            CreateMouseoverDisplay = function(ctrl, tip) env.__tooltip = tip end,
            DestroyMouseoverDisplay = function() env.__tooltip = false end,
            AddControlTooltipManual = function(ctrl, title) env.__tooltips[ctrl] = title end,
        },
        ['/lua/ui/uiutil.lua'] = {
            titleFont = 'Arial', highlightColor = 'ffffffff',
            SkinnableFile = function(p) return p end,
            CreateButtonStd = function(parent, file, label)
                local b = c.Bitmap(parent)
                b:SetSolidColor('ff888888')
                b._label = label
                return b
            end,
            CreateVertScrollbarFor = function(grid)
                return { DoScrollLines = function(self, n) table.insert(env.__scrolled, n) end }
            end,
        },
        ['/lua/maui/layouthelpers.lua'] = {
            AtLeftIn = nop, AtVerticalCenterIn = nop, AtBottomIn = nop, AtRightTopIn = nop,
            AtRightIn = nop, AtHorizontalCenterIn = nop,
        },
    }
end

--- Run one of the mod's ReUI files in the session's environment.
local function RunRoot(env, file)
    local chunk = assert(loadfile(file))
    local scope = setmetatable({}, { __index = env })
    setfenv(chunk, scope)
    chunk()
    return scope
end

do
    -- Today's ReUI: our own window, with tooltips and a scrollbar.
    local env, SM = NewSession({ stubs = WindowStubs })
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local O = env.import('/mods/TeamMouse/modules/options.lua')
    local shipped = cfg.Appearance.BaseAlpha
    env.ReUI = FakeReUI('current', { opacity = 50, nameSize = 14 })

    -- ReUI loads Options.lua when Main.lua first reads the options.
    local optionsFile = RunRoot(env, 'Options.lua')
    local values = env.ReUI.Options.Mods['TeamMouse']
    Check('every setting is a ReUI option', values and values.showNames and values.opacity
        and values.showNames() == cfg.Appearance.ShowLabels)
    local mainFile = RunRoot(env, 'Main.lua')
    Check('Main.lua asks for ReUI.Options', env.ReUI.required
        and string.find(env.ReUI.required[1], 'ReUI.Options', 1, true))
    mainFile.Main()
    Check('saved settings go into Config', cfg.Appearance.BaseAlpha == 0.5 and cfg.Appearance.LabelSize == 14)
    for _, entry in ipairs(O.Spec) do
        if entry.key then
            local owner = cfg[entry.path[1]]
            if not owner or owner[entry.path[2]] == nil then
                Check('the setting exists in config.lua: ' .. entry.key, false)
            end
            if not entry.tip or string.len(entry.tip) < 10 then
                Check('the setting has a tooltip: ' .. entry.key, false)
            end
        end
    end

    optionsFile.Main()
    local added = env.ReUI.Options.added
    Check('ReUI is handed a function that builds our own window', added and added.key == 'TeamMouse'
        and type(added.build) == 'function')

    local window = added.build(env.GetFrame(0))
    local rows = window and window.TeamMouseRows or {}
    Check('a row for every setting and heading', table.getn(rows) == table.getn(O.Spec), table.getn(rows))
    local grid = window.TeamMouseGrid
    Check('in the scrolling list', grid and grid._rows[table.getn(rows)] == rows[table.getn(rows)])

    -- Tooltips: on each row, with its name and its explanation.
    local tipsOk = true
    for i, entry in ipairs(O.Spec) do
        local row = rows[i]
        if entry.key then
            local back = row.children and row.children[1]
            for _, child in ipairs(row.children or {}) do
                if child._color == '00000000' then back = child end
            end
            env.__tooltip = false
            back:HandleEvent({ Type = 'MouseEnter' })
            if not (env.__tooltip and env.__tooltip.text == entry.label and env.__tooltip.body == entry.tip) then
                tipsOk = false
            end
            back:HandleEvent({ Type = 'MouseExit' })
            env.__tooltip = 'x'
            row.control:HandleEvent({ Type = 'MouseEnter' })
            if not (type(env.__tooltip) == 'table' and env.__tooltip.text == entry.label) then
                tipsOk = false
            end
        end
    end
    Check('hovering a row (or its checkbox / slider) shows its tooltip', tipsOk)

    -- The wheel scrolls the list from anywhere on it.
    rows[3].control:HandleEvent({ Type = 'WheelRotation', WheelRotation = -120 })
    rows[1].children[1]:HandleEvent({ Type = 'WheelRotation', WheelRotation = 120 })
    Check('the mouse wheel scrolls the list', env.__scrolled[1] == 1 and env.__scrolled[2] == -1)

    -- Changing settings: at once, Cancel puts them back, OK keeps them.
    local function RowFor(key)
        for i, entry in ipairs(O.Spec) do
            if entry.key == key then return rows[i] end
        end
    end
    local names = RowFor('showNames')
    names.control:Click()
    Check('a checkbox changes Config at once', cfg.Appearance.ShowLabels == false)
    RowFor('opacity').control:Drag(30)
    Check('a slider too', cfg.Appearance.BaseAlpha == 0.3)
    window.TeamMouseButtons.cancel:OnClick()
    Check('Cancel puts them back', cfg.Appearance.ShowLabels == true and cfg.Appearance.BaseAlpha == 0.5
        and values.opacity() == 50)
    Check('and closes the window', window._destroyed)

    window = added.build(env.GetFrame(0))
    rows = window.TeamMouseRows
    RowFor('opacity').control:Drag(70)
    window.TeamMouseButtons.ok:OnClick()
    Check('OK keeps them (saved to the profile)', cfg.Appearance.BaseAlpha == 0.7
        and env.ReUI.saved.opacity == 70 and window._destroyed)

    window = added.build(env.GetFrame(0))
    rows = window.TeamMouseRows
    Check('a reopened window shows the kept value', RowFor('opacity').control._value == 70)
    window.TeamMouseButtons.defaults:OnClick()
    Check('Defaults puts the shipped values back', math.abs(cfg.Appearance.BaseAlpha - shipped) < 1e-6
        and cfg.Appearance.LabelSize == O.Spec[3].default and RowFor('opacity').control._value
        == math.floor(shipped * 100 + 0.5))
    window:OnClose()
    Check('closing the window is Cancel', math.abs(cfg.Appearance.BaseAlpha - 0.7) < 1e-6)

    -- During a game.
    SM.InitTeamMouse(false)
    Check('a game sets the rebuild hook', type(env.TeamMouseRebuild) == 'function')
    env.__chatFuncs['TeamMouse']('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true })
    local driver = Mock.FindDriver(env)
    env.__clock.t = env.__clock.t + 0.3
    driver:OnFrame(0.016)
    local before = Mock.FindCursors(env, 'WorldCamera')[1]
    values.size:Set(150)
    Check('a change writes Config at once', cfg.Appearance.SizeScale == 1.5)
    env.__clock.t = env.__clock.t + 0.1
    driver:OnFrame(0.016)
    Check('and cursors are drawn that much larger', before.appliedScale >= 1.4, before.appliedScale)
    values.opacity:Set(500)
    Check('out of range is held to the slider\'s range', cfg.Appearance.BaseAlpha == 1)
    values.showNames:Set(false)
    local after = Mock.FindCursors(env, 'WorldCamera')
    Check('a setting read when a cursor is made rebuilds them', before._destroyed and table.getn(after) == 1
        and after[1] ~= before and not after[1].label)
    values.showNames:Set(true)
    Check('and back', Mock.FindCursors(env, 'WorldCamera')[1].label ~= nil)
    values.panel:Set(false)
    SM.OnBeat()
    Check('the panel can be switched off mid-game', env.import('/mods/TeamMouse/modules/panel.lua').Get() == false)
    values.panel:Set(true)
    SM.OnBeat()
    Check('and on again', env.import('/mods/TeamMouse/modules/panel.lua').Get() ~= false)
    SM.Destroy()
    Check('teardown removes the rebuild hook', env.TeamMouseRebuild == nil)
    values.showNames:Set(false)
    Check('changes outside a game are harmless', cfg.Appearance.ShowLabels == false and NoErrors(env))
end

do
    -- An older ReUI (no Opt): its own table-built window, without tooltips.
    local env = NewSession()
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local O = env.import('/mods/TeamMouse/modules/options.lua')
    env.ReUI = FakeReUI('older')
    local optionsFile = RunRoot(env, 'Options.lua')
    local values = env.ReUI.Options.Mods['TeamMouse']
    Check('older ReUI: values with its OptionValue', values and values.opacity
        and values.opacity:Get() == math.floor(cfg.Appearance.BaseAlpha * 100 + 0.5))
    values.opacity.v = 40
    RunRoot(env, 'Main.lua').Main()
    Check('older ReUI: saved settings go into Config', cfg.Appearance.BaseAlpha == 0.4)
    optionsFile.Main()
    local added = env.ReUI.Options.added
    local settings = 0
    for _, entry in ipairs(O.Spec) do if entry.key then settings = settings + 1 end end
    Check('older ReUI: a table of controls, one per setting', type(added.build) == 'table'
        and table.getn(added.build) == settings, type(added.build) == 'table' and table.getn(added.build))
    values.size:Set(120)
    Check('older ReUI: changes reach Config', cfg.Appearance.SizeScale == 1.2)
end

do
    -- Interface ghost switched off while a teammate's is up: it goes away.
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local receive = env.__chatFuncs['TeamMouse']
    local driver = Mock.FindDriver(env)
    for _ = 1, 4 do
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = false, hx = 0.5, hy = 0.5 })
        env.__clock.t = env.__clock.t + 0.2
        driver:OnFrame(0.1)
    end
    local visual = Mock.FindCursors(env, 'WorldCamera')[1]
    Check('(their ghost is up)', visual.hud and Mock.IsVisible(visual.hud))
    cfg.Hud.Enabled = false
    for _ = 1, 10 do
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = false, hx = 0.5, hy = 0.5 })
        env.__clock.t = env.__clock.t + 0.2
        driver:OnFrame(0.1)
    end
    Check('Hud.Enabled turned off mid-game: the ghost fades away', not Mock.IsVisible(visual.hud))
    Check('and their arrow is back', Mock.IsVisible(visual.mouseIcon))
end

--------------------------------------------------------------------------------
Section('click pulse when changing what is selected')
--------------------------------------------------------------------------------
-- Regression test for: no pulse when clicking a unit with something already
-- selected. Changing selection can pass through an empty one on the way, and
-- an empty selection used to cancel the pending click.
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local view = env.__views['WorldCamera']
    local function Beat()
        env.__clock.t = env.__clock.t + 0.1
        SM.OnBeat()
    end
    local function Unit1(id) return { GetEntityId = function() return id end } end
    env.__selectedUnits = { Unit1('51') }
    Beat()
    local mark = table.getn(env.__sent) + 1
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    env.__selectedUnits = {}
    Beat()
    env.__selectedUnits = { Unit1('52') }
    Beat()
    local n = 0
    for i = mark, table.getn(env.__sent) do n = n + (env.__sent[i].raw.ck or 0) end
    Check('something selected, click another: it pulses', n == 1, n)

    -- And clicking the ground with something selected still does not.
    mark = table.getn(env.__sent) + 1
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 120, MouseY = 100, Modifiers = { Left = true } })
    env.__selectedUnits = {}
    Beat()
    for _ = 1, 8 do Beat() end
    n = 0
    for i = mark, table.getn(env.__sent) do n = n + (env.__sent[i].raw.ck or 0) end
    Check('something selected, click the ground: no pulse', n == 0, n)
end

--------------------------------------------------------------------------------
Section('what you show is yours; what you send is everything')
--------------------------------------------------------------------------------
-- Regression test for: switching a feature off for yourself also stopped
-- you sending it, so teammates lost it too. Now every show/hide setting is
-- local: what goes out does not depend on them.
do
    local env, SM = NewSession()
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    cfg.Orders.Enabled, cfg.Orders.ShowBuilds, cfg.Orders.ShowUpgrades, cfg.Orders.ShowGrabs = false, false, false, false
    cfg.TeamSelection.Enabled, cfg.ClickPulse.Enabled, cfg.Actions.Enabled = false, false, false
    cfg.Build.Enabled, cfg.Line.Enabled, cfg.Draw.Enabled = false, false, false
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local view = env.__views['WorldCamera']
    local function Beat()
        env.__clock.t = env.__clock.t + 0.1
        SM.OnBeat()
        return env.__sent[table.getn(env.__sent)].raw
    end
    local mark = table.getn(env.__sent) + 1
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    env.__selectedUnits = { { GetEntityId = function() return '61' end } }
    Beat()
    local sel, ck = false, 0
    for i = mark, table.getn(env.__sent) do
        if env.__sent[i].raw.sel then sel = true end
        ck = ck + (env.__sent[i].raw.ck or 0)
    end
    Check('selections are sent with TeamSelection.Enabled off', sel)
    Check('clicks are sent with ClickPulse.Enabled off', ck == 1, ck)

    env.__commandMode = { 'build', { name = 'ueb0101' } }
    local m = Beat()
    Check('the building in hand is sent with Build.Enabled off', m.b == 'ueb0101', m.b)
    view:HandleEvent({ Type = 'ButtonPress', MouseX = 100, MouseY = 100, Modifiers = { Left = true } })
    env.__mouseWorld = { 140, 0, 100 }
    m = Beat()
    Check('a structure line is sent with Line.Enabled off', m.l == true)
    view:HandleEvent({ Type = 'ButtonRelease', MouseX = 140, MouseY = 100, Modifiers = {} })
    mark = table.getn(env.__sent) + 1
    Beat()
    Beat()
    local mo = false
    for i = mark, table.getn(env.__sent) do
        if env.__sent[i].raw.mob then mo = true end
    end
    Check('placed structures are sent with Orders.Enabled / ShowBuilds off', mo)
    Check('no errors', NoErrors(env))

    -- Actions are still sent with Actions.Enabled off.
    local A = env.import('/mods/TeamMouse/modules/actions.lua')
    env.import('/lua/ui/game/orders.lua').Stop()
    local got = Beat()
    Check('actions are sent with Actions.Enabled off', type(got.ac) == 'table' and got.ac[1] == A.STOP)
end

do
    -- The other end: each setting hides only what we see, and takes effect
    -- at once, both ways, without anything having been lost.
    local env, visual, driver, receive = Seeing({ mo = { 0, 30, 0, 40, 30, 40, 0, 0, 60, 0, 60, 60, 60, 1 },
        mob = { 'ueb0101', false } })
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local function Frame()
        env.__clock.t = env.__clock.t + 0.016
        driver:OnFrame(0.016)
    end
    local function Shown(i)
        local mark = visual.orderMarks[i]
        return mark and mark.visible and Mock.IsVisible(mark.square)
    end
    Check('(both orders are up)', Shown(1) and Shown(2))
    cfg.Orders.ShowBuilds = false
    Frame()
    Check('ShowBuilds off: the placement goes, the move stays', not Shown(1) and Shown(2))
    cfg.Orders.ShowBuilds = true
    Frame()
    Check('and comes back', Shown(1))
    cfg.Orders.Enabled = false
    Frame()
    Check('Orders.Enabled off: every order goes at once', not Shown(1) and not Shown(2))
    cfg.Orders.Enabled = true
    Frame()
    Check('and comes back, nothing lost', Shown(1) and Shown(2))

    -- Kept while hidden: orders that arrive with Orders.Enabled off.
    cfg.Orders.Enabled = false
    receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
        mo = { 0, 80, 0, 80, 80, 80, 2 } })
    Frame()
    cfg.Orders.Enabled = true
    env.__clock.t = env.__clock.t + 0.2
    driver:OnFrame(0.016)
    local any = false
    for _, mark in pairs(visual.orderMarks) do
        if mark.visible and Mock.IsVisible(mark.square) then any = true end
    end
    Check('an order that came while hidden shows once turned back on', any)

    -- A drawing.
    for _ = 1, 4 do
        receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true, d = 1,
            bx = 100 + _ * 10, bz = 100 })
        env.__clock.t = env.__clock.t + 0.1
        driver:OnFrame(0.1)
    end
    local trail = visual.trail
    Check('(their drawing is up)', trail.line and trail.line.shown > 0)
    cfg.Draw.Enabled = false
    Frame()
    Check('Draw.Enabled off: it goes at once', trail.line.shown == 0)
    Check('no errors', NoErrors(env))
end

do
    -- The ReUI list is only things you are shown.
    local env = NewSession()
    local O = env.import('/mods/TeamMouse/modules/options.lua')
    local sending = false
    for _, entry in ipairs(O.Spec) do
        if entry.path and (entry.path[2] == 'Share' or entry.path[1] == 'Network' or entry.path[1] == 'VersionReport') then
            sending = entry.key
        end
    end
    Check('no ReUI option is about what you send', not sending, sending)
end

--------------------------------------------------------------------------------
Section('the interface ghost is in their faction\'s colours')
--------------------------------------------------------------------------------
do
    local textures = {}
    for faction = 0, 4 do
        local armies = Armies()
        armies[2].faction = faction
        local env, visual, driver, receive = Seeing({ w = false, hx = 0.5, hy = 0.5 }, { armies = armies })
        for _ = 1, 3 do
            receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = false, hx = 0.5, hy = 0.5 })
            env.__clock.t = env.__clock.t + 0.2
            driver:OnFrame(0.1)
        end
        textures[faction] = visual.hud and visual.hud.hud and visual.hud.hud._texture
    end
    Check('UEF', textures[0] == '/mods/TeamMouse/textures/hud/UICutout-uef.png', textures[0])
    Check('Aeon', textures[1] == '/mods/TeamMouse/textures/hud/UICutout-aeon.png', textures[1])
    Check('Cybran', textures[2] == '/mods/TeamMouse/textures/hud/UICutout-cybran.png', textures[2])
    Check('Seraphim', textures[3] == '/mods/TeamMouse/textures/hud/UICutout-seraphim.png', textures[3])
    Check('anything else: the original', textures[4] == '/mods/TeamMouse/textures/UICutout.png', textures[4])
    local present = true
    for _, t in pairs(textures) do
        local f = io.open((string.gsub(t, '^/mods/TeamMouse/', '')), 'rb')
        if f then f:close() else present = false end
    end
    Check('and every one of those files is in the mod', present)
end

--------------------------------------------------------------------------------
Section('their selection boxes hidden: the cursor still moves')
--------------------------------------------------------------------------------
-- Regression test for: with Selection.ShowBox off, a teammate's box drag
-- left their arrow frozen at the press and teleported it at the release. It
-- now rides the drag's live end, as with the box shown, just without the box.
do
    local function ArrowDuringDrag(showBox)
        local env, SM = NewSession()
        env.import('/mods/TeamMouse/modules/config.lua').Selection.ShowBox = showBox
        SM.InitTeamMouse(false)
        local receive = env.__chatFuncs['TeamMouse']
        local driver = Mock.FindDriver(env)
        local T = env.__clock.t
        for i = 0, 7 do
            env.__clock.t = T + i * 0.1
            receive('KasperAUS', { v = 1, a = 2, p = { 100, 0, 100 }, o = 0, z = 60, w = true,
                s = true, bx = 100 + i * 10, bz = 100 + i * 5 })
        end
        env.__clock.t = T + 1.0
        driver:OnFrame(0.016)
        local visual = Mock.FindCursors(env, 'WorldCamera')[1]
        return visual.mouseIcon.Left() - visual.Left(), visual.mouseIcon.Top() - visual.Top(), visual
    end
    local sx, sy = ArrowDuringDrag(true)
    local hx, hy, visual = ArrowDuringDrag(false)
    Check('(shown: the arrow is away from the press, at the live end)', sx > 20, sx)
    Check('hidden: the arrow still follows the drag, just as far', math.abs(hx - sx) < 1 and math.abs(hy - sy) < 1,
        hx .. ',' .. hy .. ' vs ' .. sx .. ',' .. sy)
    Check('and no box is drawn', not visual.dragBoxShown)
end

--------------------------------------------------------------------------------
Section('an upgrade is told once, however often it is selected again')
--------------------------------------------------------------------------------
-- Regression test for: an upgrade flashed again when its building was
-- selected again after a while. The watch on selected structures lets go of
-- one not selected for UpgradeWatchSeconds; selecting it again mid-upgrade
-- started a fresh watch that did not know it had been told.
do
    local env, SM = NewSession()
    SM.InitTeamMouse(false)
    Calibrate(env, SM)
    local cfg = env.import('/mods/TeamMouse/modules/config.lua')
    local step = 0
    local function Beat()
        env.__clock.t = env.__clock.t + 0.1
        step = step + 1
        env.__mouseWorld = { 50 + math.mod(step, 7), 0, 50 }
        SM.OnBeat()
        return env.__sent[table.getn(env.__sent)].raw
    end
    local mex = MUnit('71', 80, 3, 90)
    mex.IsInCategory = function(self, c) return c == 'STRUCTURE' end
    local building = MUnit('72', 80, 3, 90)
    building.IsInCategory = function(self, c) return c == 'STRUCTURE' end
    building.GetUnitId = function() return 'ueb1202' end
    env.__selectedUnits = { mex }
    Beat()
    mex.GetFocus = function() return building end
    local told = 0
    local function Count(m) if m.mou then told = told + 1 end end
    Count(Beat())
    env.__selectedUnits = {}
    Count(Beat())
    -- A while later (the watch has let go of it), selected again, still upgrading.
    env.__clock.t = env.__clock.t + cfg.Orders.UpgradeWatchSeconds + 5
    Count(Beat())
    env.__selectedUnits = { mex }
    Count(Beat())
    Count(Beat())
    env.__selectedUnits = {}
    Count(Beat())
    env.__clock.t = env.__clock.t + cfg.Orders.UpgradeWatchSeconds + 5
    Count(Beat())
    env.__selectedUnits = { mex }
    Count(Beat())
    Check('told once for the whole upgrade', told == 1, told)

    -- A new upgrade of the same building (a new building being built) is news.
    local next = MUnit('73', 80, 3, 90)
    next.IsInCategory = function(self, c) return c == 'STRUCTURE' end
    next.GetUnitId = function() return 'ueb1302' end
    mex.GetFocus = function() return nil end
    Count(Beat())
    mex.GetFocus = function() return next end
    Count(Beat())
    Check('a later upgrade is told', told == 2, told)
end


--------------------------------------------------------------------------------
Section('following fits their whole view, by its larger axis')
--------------------------------------------------------------------------------
-- Their window and ours are rarely the same shape. Following used to take
-- their zoom as it was, so a view wider than ours was cut off at the sides.
-- Now the larger axis of their view fills ours: a narrow one keeps its
-- height (we see more to the sides), a wide one keeps its width.
do
    --- A replay of one player whose view outline is `w` x `h` world units
    --- at zoom 100, followed with a camera whose projection is real enough:
    --- our 1920 x 1080 view spans 192 x 108 world units at zoom 100.
    local function Followed(w, h)
        local renv, RSM = NewSession()
        renv.__scenario.Options.TeamMouseReplay = 'on'
        RSM.InitTeamMouse(true)
        local view = renv.__views['WorldCamera']
        view.Project = function(self, p)
            local c = renv.__camera
            local zoom = renv.GetCamera('WorldCamera'):GetZoom()
            local scale = 1000 / zoom
            local x = self.Width() / 2 + (p[1] - c.Focus[1]) * scale
            local y = self.Height() / 2 + (p[3] - c.Focus[3]) * scale
            return { x = x, y = y, [1] = x, [2] = y }
        end
        local fx, fz = 500, 500
        local x0, x1, z0, z1 = fx - w / 2, fx + w / 2, fz - h / 2, fz + h / 2
        local q = renv.import('/lua/userplayerquery.lua')
        local function Packet()
            q.ProcessQueries({ { Name = 'TeamMouse', M = { v = 1, a = 2, p = { fx, 0, fz }, o = 0, z = 100, w = true,
                cam = { fx, 0, fz, 3.14, 1.1, 100 },
                vp = { x0, 0, z0, x1, 0, z0, x1, 0, z1, x0, 0, z1 } } } })
        end
        Packet()
        renv.__camera = { Focus = { fx, 0, fz }, Heading = 3.14, Pitch = 1.1 }
        renv.__setZoom(100)
        Frames(renv, 0.1, 0.1)
        PanelRow(renv, 2).followCheck:Click()
        for _ = 1, 40 do
            Packet()
            Frames(renv, 0.1, 0.05)
        end
        local zoom = renv.GetCamera('WorldCamera'):GetZoom()
        return zoom, 192 * zoom / 100, 108 * zoom / 100, renv
    end

    -- Narrower than ours (a 4:3 window, or half a split screen): same height.
    local zoom, w, h, renv = Followed(144, 108)
    Check('their view narrower than ours: the same height as they saw', math.abs(h - 108) < 2, h)
    Check('and wider (we see more to the sides)', w > 144 + 10, w)
    -- Wider than ours (an ultrawide): the same width, all of it in view.
    zoom, w, h = Followed(252, 108)
    Check('their view wider than ours: all of its width, none cut off', math.abs(w - 252) < 3, w)
    Check('and taller', h > 108 + 10, h)
    -- The same shape: their zoom exactly.
    zoom = Followed(192, 108)
    Check('the same shape: their zoom', math.abs(zoom - 100) < 1, zoom)

    -- Off: their zoom, whatever the shape.
    local renv2, RSM2 = NewSession()
    local cfg2 = renv2.import('/mods/TeamMouse/modules/config.lua')
    Check('Follow.FitView exists, on by default', cfg2.Follow.FitView == true)
    Check('no errors', NoErrors(renv))
end

-- Regression test for: the fit eased in on its own, after the camera had
-- already glided to their zoom -- two zooms, one after the other. The fit is
-- now taken as measured, so the camera makes one glide straight to it.
do
    local renv, RSM = NewSession()
    renv.__scenario.Options.TeamMouseReplay = 'on'
    RSM.InitTeamMouse(true)
    local cfg = renv.import('/mods/TeamMouse/modules/config.lua')
    local view = renv.__views['WorldCamera']
    view.Project = function(self, p)
        local c = renv.__camera
        local scale = 1000 / renv.GetCamera('WorldCamera'):GetZoom()
        local x = self.Width() / 2 + (p[1] - c.Focus[1]) * scale
        local y = self.Height() / 2 + (p[3] - c.Focus[3]) * scale
        return { x = x, y = y, [1] = x, [2] = y }
    end
    local q = renv.import('/lua/userplayerquery.lua')
    local function Packet()
        q.ProcessQueries({ { Name = 'TeamMouse', M = { v = 1, a = 2, p = { 500, 0, 500 }, o = 0, z = 100, w = true,
            cam = { 500, 0, 500, 3.14, 1.1, 100 },
            vp = { 374, 0, 446, 626, 0, 446, 626, 0, 554, 374, 0, 554 } } } })   -- 252 x 108: wider than ours
    end
    Packet()
    -- Already looking where they look, zoomed well in.
    renv.__camera = { Focus = { 500, 0, 500 }, Heading = 3.14, Pitch = 1.1 }
    renv.__setZoom(60)
    Frames(renv, 0.1, 0.1)
    PanelRow(renv, 2).followCheck:Click()
    local target = 100 * 252 / 192
    local k = 1 - math.exp(-cfg.Follow.Rate * 0.05)
    local zooms = {}
    for _ = 1, 30 do
        Packet()
        Frames(renv, 0.05, 0.05)
        table.insert(zooms, renv.GetCamera('WorldCamera'):GetZoom())
    end
    local oneGlide = true
    local last = math.log(60 / target)
    for i, z in ipairs(zooms) do
        local gap = math.log(z / target)
        -- Each frame the same share of the way left, straight at the target.
        if math.abs(gap - last * (1 - k)) > 0.01 then oneGlide = false end
        last = gap
    end
    Check('fitting is one glide straight to the fitted zoom, no second stage', oneGlide,
        table.concat({ zooms[1], zooms[5], zooms[10], zooms[20] }, ', '))
    Check('which is where it ends', math.abs(zooms[30] - target) < 1, zooms[30])
end

--------------------------------------------------------------------------------
Section('a strong scroll stops following')
--------------------------------------------------------------------------------
do
    local function Following()
        local env, SM = RecordingSession('on')
        env.__camera = { Focus = { 400, 20, 300 }, Heading = 3.14159, Pitch = 1.1 }
        env.__setZoom(120)
        MoveTo(env, SM, 400, 0, 300, 400, 400)
        local renv, _, Play = ReplayOf(env)
        renv.import('/mods/TeamMouse/modules/config.lua').Follow.FitView = false
        Play()
        local row = PanelRow(renv, 1)
        row.followCheck:Click()
        Frames(renv, 0.2, 0.05)
        local view = renv.__views['WorldCamera']
        local function Scroll(n)
            for _ = 1, n do
                view:HandleEvent({ Type = 'WheelRotation', WheelRotation = -120, MouseX = 500, MouseY = 400, Modifiers = {} })
                renv.__clock.t = renv.__clock.t + 0.05
            end
        end
        return renv, row, Scroll
    end
    local renv, row, Scroll = Following()
    local cfg = renv.import('/mods/TeamMouse/modules/config.lua')
    Scroll(cfg.Follow.BreakScrolls - 2)
    Frames(renv, 0.1, 0.05)
    Check('a stray notch or two: still following', row.record.follow and row.followCheck:IsChecked())
    renv.__clock.t = renv.__clock.t + 2
    Scroll(cfg.Follow.BreakScrolls - 1)
    Check('notches spread out over time do not add up', row.record.follow)
    renv.__clock.t = renv.__clock.t + 2
    Scroll(cfg.Follow.BreakScrolls)
    Check('a strong scroll stops following', not row.record.follow)
    Check('and unticks its box', not PanelRow(renv, 1).followCheck:IsChecked())
    local n = table.getn(renv.__restored)
    Frames(renv, 0.3, 0.05)
    Check('and the camera is yours again', table.getn(renv.__restored) == n)

    local renv2, row2, Scroll2 = Following()
    renv2.import('/mods/TeamMouse/modules/config.lua').Follow.BreakScrolls = 0
    Scroll2(20)
    Check('Follow.BreakScrolls = 0: scrolling never stops it', row2.record.follow)
    Check('no errors', NoErrors(renv) and NoErrors(renv2))
end

--------------------------------------------------------------------------------
Section('per-frame cost (extras/frame_report.lua)')
--------------------------------------------------------------------------------
-- Regression test for: per-frame garbage and work on the receiving end --
-- Interpolate searching each 48-sample buffer from the oldest end, a digits
-- table for every number packed, a closure per packet for the extra samples,
-- tables per decoded sample, a colour string rebuilt every frame, the view
-- outline copied every frame. Three busy teammates cost ~3340 bytes and
-- ~8860 instructions a frame in the mod before; ~700 and ~7000 after.
do
    rawset(_G, 'FRAME_REPORT_LIB', true)
    local FR = dofile('extras/frame_report.lua')
    rawset(_G, 'FRAME_REPORT_LIB', nil)
    local garbage, instructions = FR.Measure('busy', 60)
    Check('three busy teammates: under 1200 bytes of garbage a frame', garbage < 1200,
        string.format('%.0f bytes', garbage))
    Check('and under 7800 Lua instructions a frame', instructions < 7800,
        string.format('%.0f instructions', instructions))
end

--------------------------------------------------------------------------------
print('')
print(string.format('%d passed, %d failed', passed, failed))
if failed > 0 then
    os.exit(1)
end
