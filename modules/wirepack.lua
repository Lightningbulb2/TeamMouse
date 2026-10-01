--******************************************************************************
--** TeamMouse -- modules/wirepack.lua
--**
--** Packs the extra samples (see Config.Network.ExtraSamples) into one short
--** string instead of a table of numbers. A table costs every number AND its
--** index on the wire; three samples of nine numbers each came to ~270 bytes a
--** packet. As a string they are ~30.
--**
--** Each sample, in order, all digits in a 64-character alphabet of plain
--** printable characters, most significant first:
--**
--**   age    2 digits   milliseconds before the packet, / 2   (0 .. 8.19 s)
--**   flags  1 digit    the state flags number                (0 .. 63)
--**   dx dz  3 each     offset from the packet's own position, tenths of a
--**                     world unit, + 131072                  (+/- 13107 units)
--**   hx hy  2 each     position on the interface * 1000      only if on the HUD
--**   bx bz  3 each     a drag's live end, offset as dx/dz    only while dragging
--**
--** Height is the packet's own. Pure string work, Lua 5.0 safe (no bit
--** operations); decoding stops at the first thing that isn't a whole sample.
--******************************************************************************

local ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'

local DIGIT = {}   -- character code -> value
local CHAR = {}    -- value -> character
for i = 1, 64 do
    DIGIT[string.byte(ALPHABET, i)] = i - 1
    CHAR[i - 1] = string.sub(ALPHABET, i, i)
end

--- 64 ^ width, for the widths used.
local SPAN = { 64, 4096, 262144 }

local OFFSET = 131072   -- 64^3 / 2
local FLAG_HUD = 1
local DRAG_FLAGS = 2 + 4 + 8 + 16 + 32

--- Write `v` as `width` digits, most significant first. No table for the
--- digits: this runs for every number of every packet, sent and received,
--- and garbage costs frame time in Lua 5.0. (Powers of 64 divide exactly,
--- even in 32-bit floats.)
local function Put(parts, v, width)
    local max = SPAN[width]
    v = math.floor(v + 0.5)
    if v < 0 then v = 0 end
    if v > max - 1 then v = max - 1 end
    local div = max / 64
    for _ = 1, width do
        local d = math.floor(v / div)
        table.insert(parts, CHAR[d])
        v = v - d * div
        div = div / 64
    end
end

--- Read `width` digits at `at`; nil if they aren't all digits.
local function Get(s, at, width)
    local v = 0
    for i = at, at + width - 1 do
        local d = DIGIT[string.byte(s, i) or -1]
        if not d then return nil end
        v = v * 64 + d
    end
    return v
end

---@param f number
---@return boolean, boolean   # on the HUD, dragging
local function Parts(f)
    local hud = math.mod(f, 2) == 1
    local drag = math.floor(f / 2) > 0
    return hud, drag
end

--- Pack samples. Each is { age, x, z, hx, hy, bx, bz, flags }.
---@param samples table[]
---@param count number
---@param px number   # the packet's own position
---@param pz number
---@return string
function PackSamples(samples, count, px, pz)
    local parts = {}
    for i = 1, count do
        local s = samples[i]
        local hud, drag = Parts(s.flags)
        Put(parts, s.age * 500, 2)
        Put(parts, s.flags, 1)
        Put(parts, (s.x - px) * 10 + OFFSET, 3)
        Put(parts, (s.z - pz) * 10 + OFFSET, 3)
        if hud then
            Put(parts, s.hx * 1000, 2)
            Put(parts, s.hy * 1000, 2)
        end
        if drag then
            Put(parts, (s.bx - px) * 10 + OFFSET, 3)
            Put(parts, (s.bz - pz) * 10 + OFFSET, 3)
        end
    end
    return table.concat(parts)
end

--- The digits of a packed string as whole numbers, exactly as written (offsets
--- and all), for wirecodec.lua to repack: per sample age, flags, dx, dz, then
--- hx, hy when on the HUD and bx, bz when dragging. Nil unless `s` is nothing
--- but whole samples. JoinSamples(SplitSamples(s)) == s.
---@param s string
---@return number[] | nil, number   # the numbers, and how many samples
function SplitSamples(s)
    if type(s) ~= 'string' then
        return nil, 0
    end
    local out, n, samples = {}, 0, 0
    local at, len = 1, string.len(s)
    while at <= len do
        local age, flags = Get(s, at, 2), Get(s, at + 2, 1)
        local dx, dz = Get(s, at + 3, 3), Get(s, at + 6, 3)
        if not (age and flags and dx and dz) or at + 8 > len then return nil, 0 end
        out[n + 1], out[n + 2], out[n + 3], out[n + 4] = age, flags, dx, dz
        n = n + 4
        at = at + 9
        local hud, drag = Parts(flags)
        if hud then
            local a, b = Get(s, at, 2), Get(s, at + 2, 2)
            if not (a and b) or at + 3 > len then return nil, 0 end
            out[n + 1], out[n + 2] = a, b
            n = n + 2
            at = at + 4
        end
        if drag then
            local a, b = Get(s, at, 3), Get(s, at + 3, 3)
            if not (a and b) or at + 5 > len then return nil, 0 end
            out[n + 1], out[n + 2] = a, b
            n = n + 2
            at = at + 6
        end
        samples = samples + 1
    end
    return out, samples
end

--- Put `v` as `width` digits, which it must fit exactly.
local function Exact(parts, v, width)
    if type(v) ~= 'number' or v < 0 or v >= SPAN[width] or math.floor(v) ~= v then
        error('sample digit out of range')
    end
    Put(parts, v, width)
end

--- The reverse of SplitSamples. Errors on a number that does not fit its
--- digits (only a corrupt packet has one).
---@param list number[]
---@param samples number
---@return string
function JoinSamples(list, samples)
    local parts, i = {}, 1
    for _ = 1, samples do
        local flags = list[i + 1]
        Exact(parts, list[i], 2)
        Exact(parts, flags, 1)
        Exact(parts, list[i + 2], 3)
        Exact(parts, list[i + 3], 3)
        i = i + 4
        local hud, drag = Parts(flags)
        if hud then
            Exact(parts, list[i], 2)
            Exact(parts, list[i + 1], 2)
            i = i + 2
        end
        if drag then
            Exact(parts, list[i], 3)
            Exact(parts, list[i + 1], 3)
            i = i + 2
        end
    end
    return table.concat(parts)
end

--- Unpack samples, calling `fn(age, x, z, hx, hy, bx, bz, flags, ctx)` for
--- each, oldest first. Stops at the first incomplete or malformed sample, or
--- after `max` samples. `ctx` is handed through, so a caller can pass one
--- function made once instead of a new closure per packet.
---@param s any   # off the wire
---@param px number
---@param pz number
---@param max number
---@param fn function
---@param ctx? any
function UnpackSamples(s, px, pz, max, fn, ctx)
    if type(s) ~= 'string' then
        return
    end
    local at, len, n = 1, string.len(s), 0
    while at <= len and n < max do
        local age = Get(s, at, 2)
        local flags = Get(s, at + 2, 1)
        local dx = Get(s, at + 3, 3)
        local dz = Get(s, at + 6, 3)
        if not (age and flags and dx and dz) then return end
        at = at + 9
        local x = px + (dx - OFFSET) / 10
        local z = pz + (dz - OFFSET) / 10
        local hud, drag = Parts(flags)
        local hx, hy, bx, bz = 0.5, 0.9, x, z
        if hud then
            local a, b = Get(s, at, 2), Get(s, at + 2, 2)
            if not (a and b) then return end
            hx, hy = a / 1000, b / 1000
            at = at + 4
        end
        if drag then
            local a, b = Get(s, at, 3), Get(s, at + 3, 3)
            if not (a and b) then return end
            bx, bz = px + (a - OFFSET) / 10, pz + (b - OFFSET) / 10
            at = at + 6
        end
        n = n + 1
        fn(age / 500, x, z, hx, hy, bx, bz, flags, ctx)
    end
end
