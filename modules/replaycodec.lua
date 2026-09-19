--******************************************************************************
--** SharedMouse2026 -- modules/replaycodec.lua
--**
--** Encodes numbers as zero-width Unicode characters so they can be hidden in
--** a unit's custom name.
--**
--** Why: mouse data travels over SessionSendChatMessage, which is explicitly
--** not recorded into the replay file. Custom unit names go through the sim,
--** which is. Hiding coordinates in the commander's name therefore makes mouse
--** activity survive into replays, and costs replay size only for the players
--** actually running the mod rather than imposing overhead on everyone.
--**
--** This module is pure string manipulation with no engine dependencies beyond
--** the commander helpers at the bottom, so it can be round-trip tested off
--** the game. See Config.ReplayCodec for the flags that gate it; it is off by
--** default and the caveats are documented there.
--**
--** Fixes against the previous draft:
--**   * A minus sign was encoded as two soft hyphens, but soft hyphen is also
--**     the digit 6, so -12.5 decoded as 6612.5. There is now a dedicated
--**     sign character.
--**   * Decoding matched characters in pairs() order with variable byte
--**     lengths. Now sorted longest-first and deterministic.
--**   * The read path could not tell our payload from an ordinary custom name,
--**     including the nickname the base game writes to the ACU on startup.
--**     There is now a marker and validation.
--**   * FindCommander logged raw engine objects. The author's own notes record
--**     that LOG-repr of a C++ object hangs the game; those calls are gone.
--******************************************************************************

local Config = import('/mods/SharedMouse2026/modules/config.lua')

--------------------------------------------------------------------------------
-- Alphabet
--------------------------------------------------------------------------------
-- Thirteen characters: digits 0-9, a decimal point, a value separator and a
-- sign marker. All are zero-width or otherwise non-rendering, written as raw
-- UTF-8 byte sequences because the Lua here is 5.0 and has no \u escape.

local CHARS = {
    [0]  = '\226\128\139',  -- U+200B  zero width space
    [1]  = '\226\128\140',  -- U+200C  zero width non-joiner
    [2]  = '\226\128\141',  -- U+200D  zero width joiner
    [3]  = '\226\129\160',  -- U+2060  word joiner
    [4]  = '\239\187\191',  -- U+FEFF  zero width no-break space
    [5]  = '\225\160\142',  -- U+180E  mongolian vowel separator
    [6]  = '\194\173',      -- U+00AD  soft hyphen
    [7]  = '\205\143',      -- U+034F  combining grapheme joiner
    [8]  = '\225\158\180',  -- U+17B4  khmer vowel inherent aq
    [9]  = '\225\158\181',  -- U+17B5  khmer vowel inherent aa
    [10] = '\226\129\161',  -- U+2061  function application  -> decimal point
    [11] = '\226\129\162',  -- U+2062  invisible times       -> separator
    [12] = '\226\129\163',  -- U+2063  invisible separator   -> minus sign
}

local DECIMAL   = CHARS[10]
local SEPARATOR = CHARS[11]
local MINUS     = CHARS[12]

--- Longest-first list of (char, value) so that matching is deterministic and
--- a shorter sequence can never shadow a longer one.
local ORDERED = {}
for value, char in pairs(CHARS) do
    table.insert(ORDERED, { char = char, value = value, len = string.len(char) })
end
table.sort(ORDERED, function(a, b)
    if a.len ~= b.len then
        return a.len > b.len
    end
    return a.value < b.value
end)

local ORDERED_COUNT = table.getn(ORDERED)

--- Longest character length, so callers know how far to look ahead.
local MAX_CHAR_LEN = ORDERED[1] and ORDERED[1].len or 3

--------------------------------------------------------------------------------
-- Encoding
--------------------------------------------------------------------------------

--- Encode one number. Precision is capped so we don't emit a sixteen digit
--- float expansion into a unit name.
---@param n number
---@param precision number
---@return string
local function EncodeNumber(n, precision)
    local parts = {}

    if n < 0 then
        table.insert(parts, MINUS)
        n = -n
    end

    local str = string.format('%.' .. tostring(precision) .. 'f', n)

    -- Trim trailing zeros and a bare trailing point, purely to keep the
    -- payload short.
    str = string.gsub(str, '0+$', '')
    str = string.gsub(str, '%.$', '')
    if str == '' then str = '0' end

    for i = 1, string.len(str) do
        local c = string.sub(str, i, i)
        if c == '.' then
            table.insert(parts, DECIMAL)
        else
            local digit = tonumber(c)
            if digit and CHARS[digit] then
                table.insert(parts, CHARS[digit])
            end
        end
    end

    return table.concat(parts)
end

--- Encode an array of numbers into a single invisible string.
---@param values number[]
---@param precision? number
---@return string
function EncodeValues(values, precision)
    precision = precision or 1
    local parts = {}
    for i, v in ipairs(values) do
        if i > 1 then
            table.insert(parts, SEPARATOR)
        end
        table.insert(parts, EncodeNumber(v, precision))
    end
    return table.concat(parts)
end

--------------------------------------------------------------------------------
-- Decoding
--------------------------------------------------------------------------------

--- Read one character at position i. Returns the value and its byte length,
--- or nil if nothing matches.
---@param str string
---@param i number
---@return number | nil, number
local function ReadChar(str, i)
    for k = 1, ORDERED_COUNT do
        local entry = ORDERED[k]
        if string.sub(str, i, i + entry.len - 1) == entry.char then
            return entry.value, entry.len
        end
    end
    return nil, 1
end

--- Decode an invisible string back into an array of numbers. Unrecognised
--- bytes are skipped, so an ordinary name prefix does no harm.
---@param str string
---@return number[]
function DecodeValues(str)
    local values = {}
    if type(str) ~= 'string' then
        return values
    end

    local current = {}
    local negative = false
    local started = false
    local len = string.len(str)
    local i = 1

    local function Flush()
        if not started then
            return
        end
        local text = table.concat(current)
        local n = tonumber(text)
        if n then
            if negative then n = -n end
            table.insert(values, n)
        end
        current = {}
        negative = false
        started = false
    end

    while i <= len do
        local value, size = ReadChar(str, i)
        if value == nil then
            i = i + 1
        else
            if value == 11 then
                Flush()
            elseif value == 12 then
                negative = true
                started = true
            elseif value == 10 then
                table.insert(current, '.')
                started = true
            else
                table.insert(current, tostring(value))
                started = true
            end
            i = i + size
        end
    end

    Flush()
    return values
end

--------------------------------------------------------------------------------
-- Commander read/write
--------------------------------------------------------------------------------

--- Cache of army index -> commander UserUnit, filled by hook/unitview.lua as
--- units are rolled over, and by GetArmyAvatars for the focused army.
---@param armyIndex number
---@return UserUnit | nil
function FindCommander(armyIndex)
    local cache = rawget(_G, 'SharedMouseCommanders')
    if not cache then
        cache = {}
        rawset(_G, 'SharedMouseCommanders', cache)
    end

    -- The focused army's avatar is always reachable. In a replay this is
    -- whichever army you are currently observing, so coverage of other armies
    -- depends on the rollover cache.
    local ok, avatars = pcall(GetArmyAvatars)
    if ok and avatars then
        for _, unit in pairs(avatars) do
            local okArmy, army = pcall(function() return unit:GetArmy() end)
            if okArmy and army then
                cache[army] = unit
            end
        end
    end

    return cache[armyIndex]
end

--- Write values into the focused army's commander name.
--- Rate limited separately from the chat send loop, because this one costs
--- sim bandwidth and replay size rather than chat bandwidth.
local lastWrite = 0

---@param values number[]
---@param now number
---@return boolean   # true if a write actually happened
function WriteToCommander(values, now)
    if not Config.ReplayCodec.Enabled or not Config.ReplayCodec.Write then
        return false
    end

    if now - lastWrite < Config.ReplayCodec.WriteInterval then
        return false
    end

    local commander = FindCommander(GetFocusArmy())
    if not commander then
        return false
    end

    local ok = pcall(function()
        commander:SetCustomName(Config.ReplayCodec.Marker .. EncodeValues(values))
    end)

    if ok then
        lastWrite = now
    end
    return ok
end

--- Read and decode values from an army's commander name.
--- Returns nil when the name is absent, is not ours, or does not decode.
---@param armyIndex number
---@return number[] | nil
function ReadFromCommander(armyIndex)
    if not Config.ReplayCodec.Enabled or not Config.ReplayCodec.Read then
        return nil
    end

    local commander = FindCommander(armyIndex)
    if not commander then
        return nil
    end

    local ok, name = pcall(function() return commander:GetCustomName(nil) end)
    if not ok or type(name) ~= 'string' then
        return nil
    end

    local marker = Config.ReplayCodec.Marker
    local markerLen = string.len(marker)
    if string.sub(name, 1, markerLen) ~= marker then
        -- Somebody's own custom name, or the nickname the base game writes.
        return nil
    end

    local values = DecodeValues(string.sub(name, markerLen + 1))
    if table.getn(values) < 2 then
        return nil
    end

    return values
end

--- Exposed for the round-trip test in extras/test_replaycodec.lua.
MaxCharLength = MAX_CHAR_LEN
