--******************************************************************************
--** TeamMouse -- modules/wirecodec.lua
--**
--** The compact wire format: the cursor packet teammouse.lua builds (the
--** table described under "Wire format" in engine-gotchas.md) as one short
--** string, sent as `{ TeamMouse = <string> }`.
--**
--** Why: a table costs its key, a type and a value for every field, and every
--** number in it is a full number on the wire; the version, the army and the
--** chat identifier rode along in every packet. As a string the same packet is
--** about a third of the size (extras/bandwidth_report.lua).
--**
--** The rule that makes it safe: Decode(Encode(packet)) is the packet, exactly.
--** Encode checks this itself before handing anything out, and returns nil for
--** any packet it cannot carry exactly (a value it has no exact form for, an
--** unexpected field); the sender then sends the plain table, as before. So
--** the receiver ends up with the very same table either way, and everything
--** after the decode is unchanged.
--**
--** Layout. Every number is written in the 64-character alphabet below, as a
--** varint: base 32, most significant digit first; a digit with 32 added says
--** another follows. Signed values are zigzagged (0, -1, 1, -2 ... as 0, 1, 2,
--** 3 ...). A real number goes as a whole number of its unit (a tenth of a
--** world unit, a thousandth of the screen, ...), and, where something close
--** by is already known, as the difference from it; one that is not an exact
--** multiple of its unit goes as text, '!' .. %.17g .. '~'. Strings go as their
--** length and then themselves.
--**
--**   format version, army, position x y z      always
--**   then fields, each a tag character and its value, in any order
--**
--** The strings that are already packed in the table (extra samples `e`, the
--** selection `sel` `ss` `sq` `sr`) are read apart and written as differences
--** from one entry to the next, and put back together character for character
--** on the way in.
--**
--** Pure string work, Lua 5.0 safe.
--******************************************************************************

local Config = import(_G.TeamMousePath .. '/modules/config.lua')
local WirePack = import(_G.TeamMousePath .. '/modules/wirepack.lua')

--- This layout's version, the first thing in the string.
FORMAT = 1

local ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
local CHAR = {}    -- value -> character
local DIGIT = {}   -- character code -> value
for i = 1, 64 do
    CHAR[i - 1] = string.sub(ALPHABET, i, i)
    DIGIT[string.byte(ALPHABET, i)] = i - 1
end
local LITERAL_OPEN = string.byte('!')

--- Whole numbers past this are written as text: FA's numbers are 32-bit
--- floats, exact only up to 2^24, and a zigzagged value doubles.
local LIMIT = 8388608

--- The offset wirepack.lua writes sample positions with.
local OFFSET = 131072

--- An age step between extra samples is written less this: samples are taken
--- every ~1/30 s, 16 or 17 in the packed age's 2 ms units, so a step is
--- usually written as 0 or -1, one character.
local AGE_STEP = 17

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

local function PutUint(parts, u)
    if u < 0 or u >= 2 * LIMIT or math.floor(u) ~= u then
        error('varint out of range')
    end
    -- Most significant digit first, without a table for the digits (this
    -- runs for every number of every packet; garbage is frame time in 5.0).
    -- Powers of 32 divide exactly, even in 32-bit floats.
    local div = 1
    while u >= div * 32 do
        div = div * 32
    end
    while div > 1 do
        local d = math.floor(u / div)
        table.insert(parts, CHAR[d + 32])
        u = u - d * div
        div = div / 32
    end
    table.insert(parts, CHAR[u])
end

local function PutInt(parts, n)
    if n >= 0 then
        PutUint(parts, n * 2)
    else
        PutUint(parts, -n * 2 - 1)
    end
end

--- `v` in units of 1/scale: the whole number, or nil if it is not one.
local function Whole(v, scale)
    if type(v) ~= 'number' or v ~= v then
        return nil
    end
    local n = math.floor(v * scale + 0.5)
    if n / scale == v and n < LIMIT and n > -LIMIT then
        return n
    end
    return nil
end

--- Write a real number in units of 1/scale, as the difference from `base`
--- when there is one. Returns what the next value can be written against: the
--- whole number written, or nil when it had to go as text.
local function PutReal(parts, v, scale, base)
    local n = Whole(v, scale)
    if n then
        if base then
            PutInt(parts, n - base)
        else
            PutInt(parts, n)
        end
        return n
    end
    if type(v) ~= 'number' then
        error('not a number')
    end
    -- The shortest text that reads back as exactly this number: at most 9
    -- digits for FA's 32-bit floats, up to 17 for a double.
    local text
    for digits = 6, 17 do
        text = string.format('%.' .. digits .. 'g', v)
        if tonumber(text) == v then break end
    end
    table.insert(parts, '!' .. text .. '~')
    return nil
end

local function PutStr(parts, s)
    PutUint(parts, string.len(s))
    table.insert(parts, s)
end

--------------------------------------------------------------------------------
-- Reading (errors on anything malformed; Decode turns that into nil)
--------------------------------------------------------------------------------

local function GetUint(r)
    local u, digits = 0, 0
    while true do
        local d = DIGIT[string.byte(r.s, r.at) or -1]
        if not d then error('bad digit') end
        r.at = r.at + 1
        digits = digits + 1
        if digits > 6 then error('varint too long') end
        if d >= 32 then
            u = u * 32 + (d - 32)
        else
            return u * 32 + d
        end
    end
end

local function GetInt(r)
    local u = GetUint(r)
    if math.mod(u, 2) == 0 then
        return u / 2
    end
    return -(u + 1) / 2
end

--- Returns the value and what the next can be read against (see PutReal).
local function GetReal(r, scale, base)
    if string.byte(r.s, r.at) == LITERAL_OPEN then
        local close = string.find(r.s, '~', r.at + 1, true)
        if not close then error('unterminated literal') end
        local v = tonumber(string.sub(r.s, r.at + 1, close - 1))
        if not v then error('bad literal') end
        r.at = close + 1
        return v, nil
    end
    local n = GetInt(r)
    if base then
        n = n + base
    end
    return n / scale, n
end

local function GetStr(r)
    local len = GetUint(r)
    if r.at + len - 1 > r.len then error('string past the end') end
    local s = string.sub(r.s, r.at, r.at + len - 1)
    r.at = r.at + len
    return s
end

--- A count of things to follow, each at least one character.
local function GetCount(r)
    local n = GetUint(r)
    if n > r.len - r.at + 1 then error('count past the end') end
    return n
end

--------------------------------------------------------------------------------
-- The strings already packed in the table
--------------------------------------------------------------------------------

local BASE36 = '0123456789abcdefghijklmnopqrstuvwxyz'

local function Base36(n)
    local s = ''
    repeat
        local d = math.mod(n, 36)
        s = string.sub(BASE36, d + 1, d + 1) .. s
        n = math.floor(n / 36)
    until n == 0
    return s
end

--- A base-36 word as its number, only if writing the number back gives the
--- very same word.
local function Word36(word)
    if not string.find(word, '^[0-9a-z]+$') then error('not base 36') end
    local n = tonumber(word, 36)
    if not n or Base36(n) ~= word then error('not canonical') end
    return n
end

--- `s` cut at every `sep` (a single character), empty pieces kept.
local function Cut(s, sep)
    local out = {}
    local from = 1
    while true do
        local at = string.find(s, sep, from, true)
        if not at then
            table.insert(out, string.sub(s, from))
            return out
        end
        table.insert(out, string.sub(s, from, at - 1))
        from = at + 1
    end
end

--- Numbers from a comma-separated base-36 list; `want` of them if given.
local function Words(s, want)
    local out = {}
    for i, word in ipairs(Cut(s, ',')) do
        out[i] = Word36(word)
    end
    if want and table.getn(out) ~= want then error('wrong count') end
    return out
end

--- Where position-like lists start from: the packet's own position, in the
--- list's own units. Any whole numbers both ends agree on would do; near the
--- pointer keeps the first difference short.
local function Origin(p, scale)
    return math.floor(p[1] * scale + 0.5), math.floor(p[2] + 0.5), math.floor(p[3] * scale + 0.5)
end

-- sel: unit ids, base 36, comma-separated.
local function PutIds(parts, s)
    if s == '' then PutUint(parts, 0) return end
    local ids = Words(s)
    PutUint(parts, table.getn(ids))
    local prev = 0
    for _, n in ipairs(ids) do
        PutInt(parts, n - prev)
        prev = n
    end
end

local function GetIds(r)
    local count = GetCount(r)
    local words, prev = {}, 0
    for i = 1, count do
        prev = prev + GetInt(r)
        if prev < 0 then error('negative id') end
        words[i] = Base36(prev)
    end
    return table.concat(words, ',')
end

-- ss: sizes, base 36, comma-separated.
local function PutSizes(parts, s)
    if s == '' then PutUint(parts, 0) return end
    local sizes = Words(s)
    PutUint(parts, table.getn(sizes))
    for _, n in ipairs(sizes) do
        PutUint(parts, n)
    end
end

local function GetSizes(r)
    local count = GetCount(r)
    local words = {}
    for i = 1, count do
        words[i] = Base36(GetUint(r))
    end
    return table.concat(words, ',')
end

-- sq: "x,z,y" per unit (quarter units, base 36), ';' between, empty where
-- unknown. Each against the last one known, the first against the pointer.
local function PutPlaces(parts, s, p)
    if s == '' then PutUint(parts, 0) return end
    local list = Cut(s, ';')
    PutUint(parts, table.getn(list))
    local px, py, pz = Origin(p, 4)
    for _, entry in ipairs(list) do
        if entry == '' then
            PutUint(parts, 0)
        else
            local v = Words(entry, 3)
            local dx = v[1] - px
            PutUint(parts, (dx >= 0 and dx * 2 or -dx * 2 - 1) + 1)
            PutInt(parts, v[2] - pz)
            PutInt(parts, v[3] - py)
            px, pz, py = v[1], v[2], v[3]
        end
    end
end

local function GetPlaces(r, p)
    local count = GetCount(r)
    local out = {}
    local px, py, pz = Origin(p, 4)
    for i = 1, count do
        local head = GetUint(r)
        if head == 0 then
            out[i] = ''
        else
            local u = head - 1
            local dx = math.mod(u, 2) == 0 and u / 2 or -(u + 1) / 2
            px = px + dx
            pz = pz + GetInt(r)
            py = py + GetInt(r)
            if px < 0 or pz < 0 or py < 0 then error('negative place') end
            out[i] = Base36(px) .. ',' .. Base36(pz) .. ',' .. Base36(py)
        end
    end
    return table.concat(out, ';')
end

-- sr: "x1,z1,x2,z2,y" per rectangle (quarter units, base 36), ';' between.
local function PutRects(parts, s, p)
    if s == '' then PutUint(parts, 0) return end
    local list = Cut(s, ';')
    PutUint(parts, table.getn(list))
    local px, py, pz = Origin(p, 4)
    for _, entry in ipairs(list) do
        local v = Words(entry, 5)
        PutInt(parts, v[1] - px)
        PutInt(parts, v[2] - pz)
        PutInt(parts, v[3] - v[1])
        PutInt(parts, v[4] - v[2])
        PutInt(parts, v[5] - py)
        px, pz, py = v[1], v[2], v[5]
    end
end

local function GetRects(r, p)
    local count = GetCount(r)
    local out = {}
    local px, py, pz = Origin(p, 4)
    for i = 1, count do
        local x1 = px + GetInt(r)
        local z1 = pz + GetInt(r)
        local x2 = x1 + GetInt(r)
        local z2 = z1 + GetInt(r)
        local y = py + GetInt(r)
        if x1 < 0 or z1 < 0 or x2 < 0 or z2 < 0 or y < 0 then error('negative rectangle') end
        out[i] = Base36(x1) .. ',' .. Base36(z1) .. ',' .. Base36(x2) .. ',' .. Base36(z2) .. ',' .. Base36(y)
        px, pz, py = x1, z1, y
    end
    return table.concat(out, ';')
end

-- e: the extra samples (wirepack.lua's string), as its own whole numbers,
-- newest first, each against the sample after it; the newest against the
-- packet's own sample (its position, interface position, drag corner and
-- state), which it is closest to.
local function Hud(flags) return math.mod(flags, 2) == 1 end
local function Drag(flags) return math.floor(flags / 2) > 0 end

--- What the packet's own sample says, in the samples' own numbers: where the
--- newest extra sample is written from. Only a starting point (both ends
--- work it out the same way from the fields read so far), so it need not be
--- exact.
local function Predict(msg)
    local p = msg.p
    local hx, hy, bx, bz = 500, 900, OFFSET, OFFSET
    if type(msg.hx) == 'number' then hx = math.floor(msg.hx * 1000 + 0.5) end
    if type(msg.hy) == 'number' then hy = math.floor(msg.hy * 1000 + 0.5) end
    if type(msg.bx) == 'number' then bx = math.floor((msg.bx - p[1]) * 10 + 0.5) + OFFSET end
    if type(msg.bz) == 'number' then bz = math.floor((msg.bz - p[3]) * 10 + 0.5) + OFFSET end
    local flags = 0
    if msg.w == false then flags = flags + 1 end
    if msg.s == true then flags = flags + 2
    elseif msg.l == true then flags = flags + 4
    elseif msg.r == true then flags = flags + 8
    elseif msg.d == 1 then flags = flags + 16
    elseif msg.d == 2 then flags = flags + 32 end
    -- Out of range (a corrupt packet): any whole number will do.
    if hx ~= hx or hx > LIMIT or hx < -LIMIT then hx = 500 end
    if hy ~= hy or hy > LIMIT or hy < -LIMIT then hy = 900 end
    if bx ~= bx or bx > LIMIT or bx < -LIMIT then bx = OFFSET end
    if bz ~= bz or bz > LIMIT or bz < -LIMIT then bz = OFFSET end
    return hx, hy, bx, bz, flags
end

local function PutSamples(parts, s, msg)
    local list, samples = WirePack.SplitSamples(s)
    if not list then error('bad samples') end
    -- Where each sample starts (they differ in length).
    local starts, i = {}, 1
    for k = 1, samples do
        starts[k] = i
        local f = list[i + 1]
        i = i + 4
        if Hud(f) then i = i + 2 end
        if Drag(f) then i = i + 2 end
    end
    PutUint(parts, samples)
    local hx, hy, bx, bz, flags = Predict(msg)
    local age, dx, dz = 0, OFFSET, OFFSET
    for k = samples, 1, -1 do
        i = starts[k]
        local a, f = list[i], list[i + 1]
        local changed = f ~= flags and 1 or 0
        if k == samples then
            PutUint(parts, a * 2 + changed)
        else
            local step = a - age - AGE_STEP
            local z = step >= 0 and step * 2 or -step * 2 - 1
            PutUint(parts, z * 2 + changed)
        end
        if changed == 1 then PutUint(parts, f) end
        age, flags = a, f
        PutInt(parts, list[i + 2] - dx)
        PutInt(parts, list[i + 3] - dz)
        dx, dz = list[i + 2], list[i + 3]
        i = i + 4
        if Hud(f) then
            PutInt(parts, list[i] - hx)
            PutInt(parts, list[i + 1] - hy)
            hx, hy = list[i], list[i + 1]
            i = i + 2
        end
        if Drag(f) then
            PutInt(parts, list[i] - bx)
            PutInt(parts, list[i + 1] - bz)
            bx, bz = list[i], list[i + 1]
        end
    end
end

--- GetSamples' working space, reused from packet to packet (decoding is
--- never re-entered): `each` holds 8 numbers a sample (age, flags, dx, dz,
--- hx, hy, bx, bz) in sample order; `list` the samples laid out for
--- JoinSamples. Only the entries a call writes are read back.
local scratch = { each = {}, list = {} }

local function GetSamples(r, msg)
    local samples = GetCount(r)
    local each = scratch.each
    local hx, hy, bx, bz, flags = Predict(msg)
    local age, dx, dz = 0, OFFSET, OFFSET
    for k = samples, 1, -1 do
        local u = GetUint(r)
        local changed = math.mod(u, 2) == 1
        local z = math.floor(u / 2)
        if k == samples then
            age = z
        else
            local step = math.mod(z, 2) == 0 and z / 2 or -(z + 1) / 2
            age = age + step + AGE_STEP
        end
        if changed then flags = GetUint(r) end
        dx = dx + GetInt(r)
        dz = dz + GetInt(r)
        if Hud(flags) then
            hx = hx + GetInt(r)
            hy = hy + GetInt(r)
        end
        if Drag(flags) then
            bx = bx + GetInt(r)
            bz = bz + GetInt(r)
        end
        local at = (k - 1) * 8
        each[at + 1], each[at + 2], each[at + 3], each[at + 4] = age, flags, dx, dz
        each[at + 5], each[at + 6], each[at + 7], each[at + 8] = hx, hy, bx, bz
    end
    -- Oldest first, each sample only the numbers its flags say it has.
    -- (An explicit count, never table.getn: see engine-gotchas.md.)
    local list, n = scratch.list, 0
    for k = 1, samples do
        local at = (k - 1) * 8
        local f = each[at + 2]
        list[n + 1], list[n + 2], list[n + 3], list[n + 4] = each[at + 1], f, each[at + 3], each[at + 4]
        n = n + 4
        if Hud(f) then
            list[n + 1], list[n + 2] = each[at + 5], each[at + 6]
            n = n + 2
        end
        if Drag(f) then
            list[n + 1], list[n + 2] = each[at + 7], each[at + 8]
            n = n + 2
        end
    end
    return WirePack.JoinSamples(list, samples)
end

--------------------------------------------------------------------------------
-- The fields
--------------------------------------------------------------------------------

--- Numbers per right-click order: kind, x, y, z, endX, endZ, sequence number.
local ORDER_STRIDE = 7

--- How many entries a plain list has (1..n, nothing else), or an error; and
--- whether it also has the `n` field Lua 5.0's table library keeps (a list
--- built with table.insert), which goes along so the copy is exact.
local function Length(t)
    if type(t) ~= 'table' then error('not a list') end
    local n, hasN = 0, false
    for k in pairs(t) do
        if k == 'n' then
            hasN = true
        else
            n = n + 1
        end
    end
    for i = 1, n do
        if t[i] == nil then error('not a plain list') end
    end
    if hasN and t.n ~= n then error('n is not the length') end
    return n, hasN
end

--- A list of `count` numbers (and perhaps its `n`), nothing else, or an
--- error. Returns whether it has `n`.
local function Numbers(t, count)
    local n, hasN = Length(t)
    if n ~= count then error('wrong length') end
    for i = 1, n do
        if type(t[i]) ~= 'number' then error('not a number') end
    end
    return hasN
end

--- A list's length, and whether it has `n`, in one number.
local function PutLength(parts, n, hasN)
    PutUint(parts, n * 2 + (hasN and 1 or 0))
end

--- The reverse of PutLength: the length (bounded by what is left to read,
--- `each` characters at least per entry) and whether to set `n`.
local function GetLength(r, each)
    local u = GetUint(r)
    local n = math.floor(u / 2)
    if n * (each or 1) > r.len - r.at + 1 then error('count past the end') end
    return n, math.mod(u, 2) == 1
end

-- Each field: key, tag, and how it is written and read. A boolean field has
-- one tag for true and another for false. `ctx` carries the position's whole
-- numbers (px, py, pz; nil where it went as text) and the position itself.
local FIELDS = {}

local function Field(key, tag, put, get)
    table.insert(FIELDS, { key = key, tag = tag, put = put, get = get })
end

local function Flag(key, tagTrue, tagFalse)
    table.insert(FIELDS, { key = key, tag = tagTrue, flag = true })
    table.insert(FIELDS, { key = key, tag = tagFalse, flag = false })
end

local function Scalar(scale)
    return function(parts, v) PutReal(parts, v, scale, nil) end,
        function(r) return (GetReal(r, scale, nil)) end
end

Field('o', 'o', Scalar(1))
Field('z', 'z', Scalar(1))
Field('d', 'd', Scalar(1))
Field('gk', 'g', Scalar(1))
Field('oa', 'A', Scalar(1))
Field('ck', 'c', Scalar(1))
Field('hx', 'x', Scalar(1000))
Field('hy', 'y', Scalar(1000))
Flag('w', 'w', 'W')
Flag('s', 's', 'S')
Flag('l', 'l', 'L')
Flag('r', 'r', 'R')
Flag('bt', 'n', 'N')

Field('bx', 'X',
    function(parts, v, ctx) PutReal(parts, v, 10, ctx.px) end,
    function(r, ctx) return (GetReal(r, 10, ctx.px)) end)
Field('bz', 'Z',
    function(parts, v, ctx) PutReal(parts, v, 10, ctx.pz) end,
    function(r, ctx) return (GetReal(r, 10, ctx.pz)) end)

Field('b', 'b',
    function(parts, v)
        if type(v) ~= 'string' then error('not a string') end
        PutStr(parts, v)
    end,
    function(r) return GetStr(r) end)

Field('e', 'e',
    function(parts, v, ctx) PutSamples(parts, v, ctx.msg) end,
    function(r, ctx) return GetSamples(r, ctx.msg) end)

local function StringField(key, tag, put, get)
    Field(key, tag,
        function(parts, v, ctx)
            if type(v) ~= 'string' then error('not a string') end
            put(parts, v, ctx.p)
        end,
        function(r, ctx) return get(r, ctx.p) end)
end
StringField('sel', 'i', PutIds, GetIds)
StringField('ss', 'j', PutSizes, GetSizes)
StringField('sq', 'k', PutPlaces, GetPlaces)
StringField('sr', 'K', PutRects, GetRects)

-- Integer lists: actions, and which orders were templates / upgrades.
local function IntList(key, tag)
    Field(key, tag,
        function(parts, v)
            local n, hasN = Length(v)
            PutLength(parts, n, hasN)
            for i = 1, n do PutReal(parts, v[i], 1, nil) end
        end,
        function(r)
            local out = {}
            local n, hasN = GetLength(r)
            for i = 1, n do out[i] = (GetReal(r, 1, nil)) end
            if hasN then out.n = n end
            return out
        end)
end
IntList('ac', 'a')
IntList('mot', 't')
IntList('mou', 'u')

-- Right-click orders: each where it is against the one before (the first
-- against the pointer, where it was most likely given), its end against
-- itself, its sequence number against the one before.
Field('mo', 'm',
    function(parts, v, ctx)
        local n = Length(v)
        if math.mod(n, ORDER_STRIDE) ~= 0 then error('orders: bad length') end
        PutLength(parts, n / ORDER_STRIDE, Numbers(v, n))
        local bx, by, bz, bs = ctx.px, ctx.py, ctx.pz, 0
        for i = 1, n, ORDER_STRIDE do
            PutReal(parts, v[i], 1, nil)
            bx = PutReal(parts, v[i + 1], 10, bx)
            by = PutReal(parts, v[i + 2], 10, by)
            bz = PutReal(parts, v[i + 3], 10, bz)
            PutReal(parts, v[i + 4], 10, bx)
            PutReal(parts, v[i + 5], 10, bz)
            bs = PutReal(parts, v[i + 6], 1, bs)
        end
    end,
    function(r, ctx)
        local out = {}
        local bx, by, bz, bs = ctx.px, ctx.py, ctx.pz, 0
        local i = 0
        local orders, hasN = GetLength(r, ORDER_STRIDE)
        for _ = 1, orders do
            out[i + 1] = (GetReal(r, 1, nil))
            out[i + 2], bx = GetReal(r, 10, bx)
            out[i + 3], by = GetReal(r, 10, by)
            out[i + 4], bz = GetReal(r, 10, bz)
            out[i + 5] = (GetReal(r, 10, bx))
            out[i + 6] = (GetReal(r, 10, bz))
            out[i + 7], bs = GetReal(r, 1, bs)
            i = i + ORDER_STRIDE
        end
        if hasN then out.n = i end
        return out
    end)

-- The structure each order placed, or false.
Field('mob', 'M',
    function(parts, v)
        local n, hasN = Length(v)
        PutLength(parts, n, hasN)
        for i = 1, n do
            local bp = v[i]
            if bp == false then
                PutUint(parts, 0)
            elseif type(bp) == 'string' then
                PutUint(parts, string.len(bp) + 1)
                table.insert(parts, bp)
            else
                error('mob: not a string')
            end
        end
    end,
    function(r)
        local out = {}
        local n, hasN = GetLength(r)
        if hasN then out.n = n end
        for i = 1, n do
            local len = GetUint(r)
            if len == 0 then
                out[i] = false
            else
                if r.at + len - 2 > r.len then error('mob past the end') end
                out[i] = string.sub(r.s, r.at, r.at + len - 2)
                r.at = r.at + len - 1
            end
        end
        return out
    end)

-- Numbers that come in x, y, z threes (view corners, camera focus): each
-- against the one before on the same axis, the first against the pointer.
-- (Three locals, not a table of bases: this runs for every packet.)
local function PutChain(parts, v, from, to, ctx)
    local bx, by, bz = ctx.px, ctx.py, ctx.pz
    for i = from, to, 3 do
        bx = PutReal(parts, v[i], 10, bx)
        by = PutReal(parts, v[i + 1], 10, by)
        bz = PutReal(parts, v[i + 2], 10, bz)
    end
end

local function GetChain(r, out, from, to, ctx)
    local bx, by, bz = ctx.px, ctx.py, ctx.pz
    for i = from, to, 3 do
        out[i], bx = GetReal(r, 10, bx)
        out[i + 1], by = GetReal(r, 10, by)
        out[i + 2], bz = GetReal(r, 10, bz)
    end
end

Field('vp', 'v',
    function(parts, v, ctx)
        if Numbers(v, 12) then error('vp: n') end
        PutChain(parts, v, 1, 12, ctx)
    end,
    function(r, ctx)
        local out = {}
        GetChain(r, out, 1, 12, ctx)
        return out
    end)

-- Camera: focus x, y, z (against the pointer), heading and pitch (radians,
-- thousandths), zoom (tenths).
Field('cam', 'C',
    function(parts, v, ctx)
        if Numbers(v, 6) then error('cam: n') end
        PutChain(parts, v, 1, 3, ctx)
        PutReal(parts, v[4], 1000, nil)
        PutReal(parts, v[5], 1000, nil)
        PutReal(parts, v[6], 10, nil)
    end,
    function(r, ctx)
        local out = {}
        GetChain(r, out, 1, 3, ctx)
        out[4] = (GetReal(r, 1000, nil))
        out[5] = (GetReal(r, 1000, nil))
        out[6] = (GetReal(r, 10, nil))
        return out
    end)

local BY_TAG = {}
local KNOWN = { Identifier = true, v = true, a = true, p = true }
for _, f in ipairs(FIELDS) do
    BY_TAG[string.byte(f.tag)] = f
    KNOWN[f.key] = true
end

--------------------------------------------------------------------------------
-- Packets
--------------------------------------------------------------------------------

--- Equal all the way down, as the receiver would see it.
local function Same(a, b)
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= 'table' then
        return a == b
    end
    for k, v in pairs(a) do
        if not Same(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--- Decode's reader and context, reused (decoding is never re-entered).
local decodeR = { s = '', at = 1, len = 0 }
local decodeCtx = { p = false, msg = false, px = nil, py = nil, pz = nil }

local function DecodeUnsafe(s)
    local r = decodeR
    r.s, r.at, r.len = s, 1, string.len(s)
    if GetUint(r) ~= FORMAT then
        error('another format')
    end
    local msg = { v = Config.Protocol }
    msg.a = (GetReal(r, 1, nil))
    local p = {}
    local ctx = decodeCtx
    ctx.p, ctx.msg = p, msg
    p[1], ctx.px = GetReal(r, 10, nil)
    p[2], ctx.py = GetReal(r, 10, nil)
    p[3], ctx.pz = GetReal(r, 10, nil)
    msg.p = p
    while r.at <= r.len do
        local f = BY_TAG[string.byte(r.s, r.at)]
        if not f or msg[f.key] ~= nil then
            error('unknown or repeated field')
        end
        r.at = r.at + 1
        if f.flag ~= nil then
            msg[f.key] = f.flag
        else
            msg[f.key] = f.get(r, ctx)
        end
    end
    return msg
end

--- The packet a string carries, or nil if it is not one.
---@param s any   # off the wire
---@return table | nil
function Decode(s)
    if type(s) ~= 'string' then
        return nil
    end
    local ok, msg = pcall(DecodeUnsafe, s)
    if ok then
        return msg
    end
    return nil
end

local function EncodeUnsafe(msg)
    for k in pairs(msg) do
        if not KNOWN[k] then error('unknown field ' .. tostring(k)) end
    end
    if msg.v ~= Config.Protocol then error('another protocol') end
    if Numbers(msg.p, 3) then error('p: n') end
    local parts = {}
    PutUint(parts, FORMAT)
    PutReal(parts, msg.a, 1, nil)
    local ctx = { p = msg.p, msg = msg }
    ctx.px = PutReal(parts, msg.p[1], 10, nil)
    ctx.py = PutReal(parts, msg.p[2], 10, nil)
    ctx.pz = PutReal(parts, msg.p[3], 10, nil)
    for _, f in ipairs(FIELDS) do
        local v = msg[f.key]
        if v ~= nil then
            if f.flag ~= nil then
                if v == f.flag then
                    table.insert(parts, f.tag)
                elseif type(v) ~= 'boolean' then
                    error('not a boolean')
                end
            else
                table.insert(parts, f.tag)
                f.put(parts, v, ctx)
            end
        end
    end
    return table.concat(parts)
end

--- The packet as a string, or nil if it cannot be carried exactly (then send
--- the table itself). Checked: the string decodes to the packet.
---@param msg table   # the cursor packet (Identifier is not carried)
---@return string | nil
function Encode(msg)
    if type(msg) ~= 'table' then
        return nil
    end
    local ok, s = pcall(EncodeUnsafe, msg)
    if not ok then
        return nil
    end
    local back = Decode(s)
    if not back then
        return nil
    end
    back.Identifier = msg.Identifier
    if not Same(msg, back) then
        return nil
    end
    return s
end
