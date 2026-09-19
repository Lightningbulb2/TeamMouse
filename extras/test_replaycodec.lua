--******************************************************************************
--** SharedMouse2026 -- extras/test_replaycodec.lua
--**
--** Round-trip test for the zero-width codec. Runs outside the game:
--**
--**     lua5.1 extras/test_replaycodec.lua
--**
--** The codec is pure string manipulation, so it can be exercised without the
--** engine. Everything below the encode/decode pair in replaycodec.lua needs
--** UserUnit and is stubbed out here.
--******************************************************************************

local Mock = dofile('extras/mock_fa.lua')

-- Minimal stand-ins for the pieces of the game environment the module touches
-- at load time. The table library is the Lua 5.0 one from the mock, because
-- the codec uses table.insert, table.concat, table.sort and table.getn, and
-- those behave differently under 5.0 than under the 5.1 this runs on.
local stubs = {
    table = {
        insert = Mock.lua50.insert,
        remove = Mock.lua50.remove,
        getn = Mock.lua50.getn,
        setn = Mock.lua50.setn,
        concat = Mock.lua50.concat,
        sort = Mock.lua50.sort,
    },
    import = function()
        return {
            ReplayCodec = {
                Enabled = true,
                Write = true,
                Read = true,
                Marker = 'SM:',
                PollInterval = 0.1,
                WriteInterval = 0.25,
            },
        }
    end,
    GetArmyAvatars = function() return nil end,
    GetFocusArmy = function() return 1 end,
}

local env = setmetatable(stubs, { __index = _G })

local chunk = assert(loadfile('modules/replaycodec.lua'))
setfenv(chunk, env)
chunk()

local Encode = env.EncodeValues
local Decode = env.DecodeValues

-- Decoded results come back built with the 5.0 table library, so measure them
-- with the same getn the module used.
local getn = Mock.lua50.getn

--------------------------------------------------------------------------------

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

local function RoundTrip(name, values, precision)
    local encoded = Encode(values, precision)
    local decoded = Decode(encoded)

    if getn(decoded) ~= table.getn(values) then
        Check(name, false, string.format('expected %d values, got %d',
            table.getn(values), getn(decoded)))
        return
    end

    local tolerance = 1 / (10 ^ (precision or 1))
    for i, expected in ipairs(values) do
        local actual = decoded[i]
        if math.abs(actual - expected) > tolerance then
            Check(name, false, string.format('index %d: expected %s, got %s',
                i, tostring(expected), tostring(actual)))
            return
        end
    end

    Check(name, true)
end

print('replaycodec round-trip')
print('')

RoundTrip('single integer',            { 42 })
RoundTrip('single zero',               { 0 })
RoundTrip('one decimal place',         { 123.4 })
RoundTrip('typical map coordinates',   { 256.3, 411.9 })
RoundTrip('three values',              { 12.5, 0, 33.1 })
RoundTrip('large coordinates',         { 1024.0, 2047.9 })

-- The bug this codec was rewritten for: the old encoder wrote a minus sign as
-- two soft hyphens, but soft hyphen is also the digit 6, so -12.5 came back
-- as 6612.5.
RoundTrip('negative value',            { -12.5 })
RoundTrip('negative and positive',     { -8.1, 64.2 })
RoundTrip('both negative',             { -1.5, -99.9 })
RoundTrip('negative zero-ish',         { -0.1 })

RoundTrip('higher precision',          { 1.25, -3.75 }, 2)
RoundTrip('order index payload',       { 128.5, 340.2, 23 })

-- Decoding must tolerate junk around the payload, since a custom name is a
-- free text field that anything could have written to.
local withNoise = 'ACU' .. Encode({ 10.5, 20.5 }) .. 'tail'
local noiseDecoded = Decode(withNoise)
Check('ignores surrounding plain text',
    getn(noiseDecoded) == 2
        and math.abs(noiseDecoded[1] - 10.5) < 0.05
        and math.abs(noiseDecoded[2] - 20.5) < 0.05,
    'got ' .. getn(noiseDecoded) .. ' values')

-- A name with no payload at all must decode to nothing rather than garbage.
Check('plain name decodes to nothing',
    getn(Decode('Lightningbulb')) == 0)

Check('empty string decodes to nothing',
    getn(Decode('')) == 0)

Check('nil is handled',
    getn(Decode(nil)) == 0)

-- The payload must contain no printable characters, or it would show up in the
-- green custom-name text above the commander.
local payload = Encode({ 256.3, 411.9 })
local printable = string.find(payload, '[%w%p ]')
Check('payload contains nothing printable', printable == nil,
    printable and ('printable byte at ' .. printable) or '')

-- Size sanity: custom names are not unbounded, and this runs at the send rate.
print('')
print(string.format('  payload for two coordinates: %d bytes', string.len(payload)))
print(string.format('  payload with order index:    %d bytes',
    string.len(Encode({ 256.3, 411.9, 23 }))))

print('')
print(string.format('%d passed, %d failed', passed, failed))

if failed > 0 then
    os.exit(1)
end
