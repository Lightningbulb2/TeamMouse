--******************************************************************************
--** TeamMouse -- extras/test_replaycodec.lua
--**
--** Tests for modules/replaycodec.lua, which records each packet into the
--** replay through the sim (FAF's query system) and hands them back during
--** playback. Runs outside the game:
--**
--**     lua5.1 extras/test_replaycodec.lua
--**
--** The engine calls it makes (SimCallback, SessionGetScenarioInfo, the query
--** system's AddQueryListener) are stubbed below. End-to-end recording and
--** playback is in test_integration.lua.
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
local function Section(name)
    print('')
    print(name)
end

--- A fresh codec with its own config, lobby options and engine stubs.
---@param overrides? table   # ReplayCodec settings to change
---@param options? table     # the game's lobby options
local function NewCodec(overrides, options)
    local cfg = { Enabled = true, Write = true, Read = true }
    for k, v in pairs(overrides or {}) do cfg[k] = v end

    local sent, listeners, scenarioReads = {}, {}, 0
    local query = {
        AddQueryListener = function(name, callback)
            table.insert(listeners, { Name = name, Callback = callback })
        end,
    }
    local env = setmetatable({
        table = {
            insert = Mock.lua50.insert, remove = Mock.lua50.remove,
            getn = Mock.lua50.getn, setn = Mock.lua50.setn,
            concat = Mock.lua50.concat, sort = Mock.lua50.sort,
        },
        import = function(path)
            if path == '/lua/userplayerquery.lua' then return query end
            -- The real compact codec (wirecodec.lua), from a mock session.
            if string.find(path, 'wirecodec.lua', 1, true) then
                return Mock.CreateEnvironment({ armies = {}, clients = {} })
                    .import('/mods/TeamMouse/modules/wirecodec.lua')
            end
            return { ReplayCodec = cfg }
        end,
        SimCallback = function(cb) table.insert(sent, cb) end,
        SessionGetScenarioInfo = function()
            scenarioReads = scenarioReads + 1
            return { Options = options or {} }
        end,
    }, { __index = _G })

    local chunk = assert(loadfile('modules/replaycodec.lua'))
    setfenv(chunk, env)
    chunk()
    local function Deliver(q)
        for _, l in ipairs(listeners) do
            if l.Name == q.Name then l.Callback(q) end
        end
    end
    return env, sent, cfg, Deliver, listeners, function() return scenarioReads end
end

--------------------------------------------------------------------------------
Section('on or off: the lobby option, then the config')
--------------------------------------------------------------------------------
do
    local C = NewCodec({ Enabled = false }, { TeamMouseReplay = 'on' })
    Check('the lobby option On wins over the config', C.IsEnabled() == true)
    C = NewCodec({ Enabled = true }, { TeamMouseReplay = 'off' })
    Check('the lobby option Off wins over the config', C.IsEnabled() == false)
    C = NewCodec({ Enabled = true }, {})
    Check('no lobby option: the config decides (on)', C.IsEnabled() == true)
    C = NewCodec({ Enabled = false }, {})
    Check('no lobby option: the config decides (off)', C.IsEnabled() == false)
    C = NewCodec({ Enabled = true }, { TeamMouseReplay = 'sideways' })
    Check('an unknown option value is ignored', C.IsEnabled() == true)

    local C2, _, _, _, _, reads = NewCodec({}, { TeamMouseReplay = 'on' })
    for _ = 1, 10 do C2.IsEnabled() end
    Check('the game\'s options are read once, not every call', reads() == 1, reads())
    C2.ResetOption()
    C2.IsEnabled()
    Check('and again after a reset', reads() == 2)

    local env = setmetatable({ import = function() return { ReplayCodec = { Enabled = true } } end,
        SessionGetScenarioInfo = function() error('no session') end }, { __index = _G })
    local chunk = assert(loadfile('modules/replaycodec.lua'))
    setfenv(chunk, env)
    chunk()
    Check('no scenario to read: the config decides, no error', env.IsEnabled() == true)
end

--------------------------------------------------------------------------------
Section('recording: the packet into the sim')
--------------------------------------------------------------------------------
do
    local C, sent = NewCodec()
    local packet = { v = 1, a = 2, p = { 10, 5, 20 }, o = 3, s = true,
        mo = { 0, 1, 2, 3, 4, 5, 6 }, mob = { 'ueb0101' }, e = 'ABC' }
    Check('Record says it sent', C.Record(packet, 2) == true)
    local cb = sent[1]
    Check('as the query system\'s sim callback', cb and cb.Func == 'OnPlayerQuery' and type(cb.Args) == 'table')
    local args = cb and cb.Args
    Check('under TeamMouse\'s query name', args and args.Name == C.QUERY_NAME and args.Name == 'TeamMouse')
    -- Nothing reads From or To (the packet names its army), and every byte
    -- of this goes to every player through the sim: they are not sent.
    Check('no From or To: the packet itself names the army', args and args.From == nil and args.To == nil)
    local m = args and args.M
    Check('the whole packet', m and m.v == 1 and m.a == 2 and m.o == 3 and m.s == true and m.e == 'ABC'
        and m.p[1] == 10 and m.p[2] == 5 and m.p[3] == 20 and m.mo[7] == 6 and m.mob[1] == 'ueb0101')

    -- The sender reuses its packet table from beat to beat.
    packet.p[1] = 99
    packet.o = 7
    Check('as it was when sent, not as the table is now', m.p[1] == 10 and m.o == 3)
    C.Record(packet, 2)
    Check('each beat its own copy', sent[2].Args.M.p[1] == 99 and sent[1].Args.M.p[1] == 10)

    -- Only plain data goes into the sim.
    C.Record({ v = 1, f = function() end, u = newproxy and newproxy() or nil,
        deep = { { { { { 'too deep' } } } } } }, 1)
    local junk = sent[3].Args.M
    Check('functions are left out', junk.f == nil)
    Check('nesting is cut off, not followed forever', type(junk.deep) == 'table'
        and (junk.deep[1] == nil or junk.deep[1][1] == nil or junk.deep[1][1][1] == nil))
end

do
    local C, sent = NewCodec({}, { TeamMouseReplay = 'off' })
    Check('nothing is recorded with the option off', C.Record({ v = 1 }, 1) == false and table.getn(sent) == 0)
    C, sent = NewCodec({ Write = false })
    Check('nor with Write off', C.Record({ v = 1 }, 1) == false and table.getn(sent) == 0)
    C, sent = NewCodec()
    Check('nor a packet that is not a table', C.Record(nil, 1) == false and table.getn(sent) == 0)

    local env = NewCodec()
    env.SimCallback = function() error('sim is gone') end
    Check('a SimCallback that fails is reported, not thrown', env.Record({ v = 1 }, 1) == false)
end

--------------------------------------------------------------------------------
Section('playback: the packets back out of the sim')
--------------------------------------------------------------------------------
do
    local C, _, _, Deliver, listeners = NewCodec()
    local got = {}
    Check('Listen reaches the query system', C.Listen(function(m) table.insert(got, m) end) == true)
    Check('and listens under TeamMouse\'s name', table.getn(listeners) == 1 and listeners[1].Name == 'TeamMouse')

    Deliver({ Name = 'TeamMouse', From = 2, To = -1, FromCommandSource = 1, M = { v = 1, a = 2 } })
    Check('each packet is handed on as sent', table.getn(got) == 1 and got[1].a == 2)

    Deliver({ Name = 'TeamMouse', M = 'not a packet' })
    Deliver({ Name = 'TeamMouse' })
    Deliver({ Name = 'SomethingElse', M = { v = 1 } })
    Check('queries that are not packets are dropped', table.getn(got) == 1)

    C.Listen(function(m) table.insert(got, 'second: ' .. tostring(m.a)) end)
    Check('listening again does not add a second listener', table.getn(listeners) == 1)
    Deliver({ Name = 'TeamMouse', M = { v = 1, a = 3 } })
    Check('but the new receiver gets them', got[2] == 'second: 3')

    C.StopListening()
    Deliver({ Name = 'TeamMouse', M = { v = 1, a = 3 } })
    Check('StopListening stops them', table.getn(got) == 2)
end

do
    -- The compact format (wirecodec.lua): recorded as the string, handed on
    -- as the packet it carries; a string that is not one is dropped.
    local C, sent, _, Deliver = NewCodec()
    local W = Mock.CreateEnvironment({ armies = {}, clients = {} }).import('/mods/TeamMouse/modules/wirecodec.lua')
    local packet = { v = 1, a = 2, p = { 10, 5, 20 }, o = 3 }
    local s = W.Encode(packet)
    Check('Record takes the compact string', s and C.Record(s, 2) == true)
    local args = sent[1] and sent[1].Args
    Check('and records it as it is', args and args.M == s and args.Name == 'TeamMouse')
    local got = {}
    C.Listen(function(m) table.insert(got, m) end)
    Deliver({ Name = 'TeamMouse', M = s })
    Check('playback hands on the packet it carries', got[1] and got[1].a == 2 and got[1].o == 3
        and got[1].p[3] == 20)
    Deliver({ Name = 'TeamMouse', M = 'Bnot a packet' })
    Deliver({ Name = 'TeamMouse', M = '' })
    Check('a string that is not a packet is dropped', table.getn(got) == 1)
    Deliver({ Name = 'TeamMouse', M = { v = 1, a = 4 } })
    Check('a table (an older replay) still goes through', got[2] and got[2].a == 4)
end

do
    local env = NewCodec()
    env.import = function() error('no query system') end
    Check('no query system: Listen says so, no error', env.Listen(function() end) == false)
end

print('')
print(string.format('%d passed, %d failed', passed, failed))
if failed > 0 then
    os.exit(1)
end
