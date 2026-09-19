--******************************************************************************
--** SharedMouse2026 -- modules/cursordata.lua
--**
--** Maps between the cursor textures the game sets locally, a compact integer
--** for the wire, and a texture we can actually draw for a remote player.
--**
--** All of this is derived from lua/skins/skins.lua, which is the game's own
--** cursor definition table. The format there is:
--**     { texture, hotspotX, hotspotY, [numFrames], [fps] }
--**
--** The naming rule that makes this tractable: an animated cursor is declared
--** with a trailing dash, e.g. '/textures/.../move-.dds', and maui/cursor.lua
--** formats frame files off it as ("%s%02d.dds"):format(base, frame). So a
--** trailing dash in the filename handed to SetTexture *is* the marker for an
--** animated cursor, and stripping it yields a stable name.
--**
--** The previous version used string.sub(filename, 34, extensionPos - 2), which
--** correctly stripped that dash on animated cursors but ate a real character
--** on static ones ('move_window' -> 'move_windo'). It also used
--** string.find(filename, ".dds") where the dot is a pattern wildcard.
--******************************************************************************

local Config = import('/mods/SharedMouse2026/modules/config.lua')
local Color = import('/lua/shared/color.lua')

--- Where the stock cursor textures live.
CursorRoot = '/textures/ui/common/game/cursors/'

--------------------------------------------------------------------------------
-- Wire indices
--------------------------------------------------------------------------------
-- Index 0 (or anything unrecognised) means "no specific order" and falls back
-- to the player's plain coloured arrow. Appending to the END of this list is
-- backwards compatible within a protocol version; reordering it is not.

OrderNames = {
    'selectable',                   -- 1
    'selectable-invalid',           -- 2
    'attack',                       -- 3
    'attack-invalid',               -- 4
    'attack_coordinated',           -- 5
    'attack-coordinated',           -- 6
    'attack-coordinated-invalid',   -- 7
    'attack_move',                  -- 8
    'capture',                      -- 9
    'capture-invalid',              -- 10
    'construct',                    -- 11
    'construct-invalid',            -- 12
    'construct02',                  -- 13
    'ferry',                        -- 14
    'ferry-invalid',                -- 15
    'guard',                        -- 16
    'guard-invalid',                -- 17
    'launch',                       -- 18
    'launch-invalid',               -- 19
    'load',                         -- 20
    'load-invalid',                 -- 21
    'message',                      -- 22
    'move',                         -- 23
    'move-invalid',                 -- 24
    'move_window',                  -- 25
    'n_s',                          -- 26
    'ne_sw',                        -- 27
    'nw_se',                        -- 28
    'w_e',                          -- 29
    'overcharge',                   -- 30
    'overcharge_grey',              -- 31
    'overcharge_orange',            -- 32
    'patrol',                       -- 33
    'patrol-invalid',               -- 34
    'reclaim',                      -- 35
    'reclaim02',                    -- 36
    'reclaim-invalid',              -- 37
    'reclaim-disabled',             -- 38
    'repair',                       -- 39
    'repair-invalid',               -- 40
    'sacrifice',                    -- 41
    'transport',                    -- 42
    'transport-invalid',            -- 43
    'unload',                       -- 44
    'unload-invalid',               -- 45
    'waypoint-drag',                -- 46
    'waypoint-hover',               -- 47
}

--- name -> index, built from the list above.
OrderIndices = {}
for index, name in ipairs(OrderNames) do
    OrderIndices[name] = index
end

--------------------------------------------------------------------------------
-- Display textures
--------------------------------------------------------------------------------
-- Most names have a matching static .dds we can draw directly. These are the
-- ones that don't, either because only animated frames exist or because the
-- static file is under a different name.

local DisplayOverride = {
    -- Animated-only: the game ships <name>-01.dds through <name>-NN.dds but no
    -- bare <name>.dds. Frame 1 is a fine still image.
    ['message']             = 'message-01.dds',
    ['overcharge']          = 'overcharge-01.dds',
    ['overcharge_grey']     = 'overcharge_grey-01.dds',
    ['overcharge_orange']   = 'overcharge_orange-01.dds',
    ['attack_move']         = 'attack_move-01.dds',

    -- Animated variants whose static sibling lives under the base name.
    ['reclaim02']           = 'reclaim.dds',
    ['construct02']         = 'construct.dds',

    -- The only cursor in the game that isn't a .dds.
    ['reclaim-disabled']    = 'reclaim-disabled.tga',
}

--------------------------------------------------------------------------------
-- Hotspots
--------------------------------------------------------------------------------
-- Pixel within the 32x32 cursor texture that sits on the pointed-at location.
-- Straight out of skins.lua. Without these, a remote cursor is drawn up to
-- half an icon away from where the player is actually pointing.

local DefaultHotspotX = 15
local DefaultHotspotY = 15

local Hotspots = {
    ['selectable']          = { 2, 2 },
    ['selectable-invalid']  = { 2, 2 },
    ['waypoint-hover']      = { 7, 7 },
    ['waypoint-drag']       = { 7, 7 },
    ['load']                = { 15, 19 },
    ['load-invalid']        = { 15, 19 },
    ['unload']              = { 15, 3 },
    ['unload-invalid']      = { 15, 3 },
}

--------------------------------------------------------------------------------
-- Army colours
--------------------------------------------------------------------------------
-- lua/GameColors.lua defines nineteen player colours in mixed case. The shipped
-- cursor textures are named after them, also in mixed case. Matching those two
-- directly is asking for trouble, so we normalise to lowercase and look up the
-- filename as it actually exists on disk.
--
-- ArmyInfo.color is NOT always one of these: with team colour mode enabled the
-- game hands back names like 'RoyalBlue' or 'DarkGreen'. Those fall through to
-- the neutral arrow, and the player is still identifiable by their name label.

local ColorTextures = {
    ['ffe80a0a'] = 'FFe80a0a.png',
    ['ff901427'] = 'ff901427.png',
    ['ffff873e'] = 'FFFF873E.png',
    ['ffb76518'] = 'ffb76518.png',
    ['ffa79602'] = 'ffa79602.png',
    ['fffafa00'] = 'fffafa00.png',
    ['ff9fd802'] = 'ff9fd802.png',
    ['ff40bf40'] = 'ff40bf40.png',
    ['ff2e8b57'] = 'ff2e8b57.png',
    ['ff2f4f4f'] = 'FF2F4F4F.png',
    ['ff436eee'] = 'ff436eee.png',
    ['ff2929e1'] = 'FF2929e1.png',
    ['ff5f01a7'] = 'FF5F01A7.png',
    ['ff9161ff'] = 'ff9161ff.png',
    ['ff66ffcc'] = 'ff66ffcc.png',
    ['ffffffff'] = 'ffffffff.png',
    ['ff616d7e'] = 'ff616d7e.png',
    ['ffff88ff'] = 'ffff88ff.png',
    ['ffff32ff'] = 'ffff32ff.png',
}

local NeutralArrow = 'selectable.png'

--------------------------------------------------------------------------------
-- Public helpers
--------------------------------------------------------------------------------

--- Pull a stable cursor name out of the filename the game handed to SetTexture.
--- Returns nil for anything that doesn't look like a cursor path.
---@param filename string
---@return string | nil
function KeyFromTexture(filename)
    if type(filename) ~= 'string' then
        return nil
    end

    -- Everything after the last separator, minus the extension. Note the
    -- escaped dot: an unescaped one is a pattern wildcard.
    local base = string.match(filename, '([^/\\]+)%.%a+$')
    if not base then
        return nil
    end

    -- Trailing dash marks an animated cursor; the frame number goes there.
    return (string.gsub(base, '%-$', ''))
end

--- Wire index for a cursor name. 0 means "not one we know about".
---@param key string | nil
---@return number
function IndexFromKey(key)
    if not key then
        return 0
    end
    return OrderIndices[key] or 0
end

--- Texture path to draw for a wire index, or nil to use the player's arrow.
--- Results are cached; DiskGetFileInfo is not free and this is called whenever
--- a remote player's cursor changes.
local textureCache = {}

---@param index number
---@return string | nil
function TextureForIndex(index)
    if not index or index < 1 then
        return nil
    end

    local cached = textureCache[index]
    if cached ~= nil then
        -- false is a cached miss, as distinct from nil meaning "not looked up"
        if cached == false then
            return nil
        end
        return cached
    end

    local key = OrderNames[index]
    if not key then
        textureCache[index] = false
        return nil
    end

    local path = CursorRoot .. (DisplayOverride[key] or (key .. '.dds'))

    -- A skin or another mod can replace the cursor set. If the file isn't
    -- there we fall back to the coloured arrow rather than drawing nothing.
    if DiskGetFileInfo(path) == false then
        textureCache[index] = false
        return nil
    end

    textureCache[index] = path
    return path
end

--- Hotspot for a wire index, in texture pixels.
---@param index number
---@return number, number
function HotspotForIndex(index)
    local key = index and OrderNames[index]
    local spot = key and Hotspots[key]
    if spot then
        return spot[1], spot[2]
    end
    return DefaultHotspotX, DefaultHotspotY
end

--- Palette entries pre-parsed to RGB, for nearest-match fallback.
--- Built lazily on first use so that importing this module costs nothing.
local paletteRGB = nil

local function BuildPaletteRGB()
    paletteRGB = {}
    for hex, file in pairs(ColorTextures) do
        local ok, r, g, b = pcall(Color.ParseColor, hex)
        if ok and r then
            table.insert(paletteRGB, { r = r, g = g, b = b, file = file })
        end
    end
end

--- Resolutions are cached per colour string: this is called once per player
--- per view, but the parse and the nearest-match scan are worth doing once.
local arrowCache = {}

--- Coloured arrow texture for an army colour.
---
--- ArmyInfo.color is usually one of the nineteen palette hex strings, in which
--- case this is an exact lookup. It is not always: with team colour mode on,
--- the game hands back engine colour names such as 'RoyalBlue', 'DarkGreen'
--- and 'Goldenrod' instead, and a map or another mod can supply an arbitrary
--- hex value. Those are parsed with the game's own colour parser -- which
--- understands RRGGBB, AARRGGBB and the named enum -- and matched to the
--- closest arrow we actually ship.
---
--- Under team colour mode every ally legitimately resolves to the same arrow;
--- that is the point of the mode, and the name label still tells them apart.
---@param color string | nil
---@return string
function ArrowForColor(color)
    if type(color) ~= 'string' or color == '' then
        return Config.ModPath .. '/textures/cursors/' .. NeutralArrow
    end

    local cached = arrowCache[color]
    if cached then
        return cached
    end

    local file = ColorTextures[string.lower(color)]

    if not file then
        if not paletteRGB then
            BuildPaletteRGB()
        end

        -- ParseColor returns false for anything it cannot make sense of.
        local ok, r, g, b = pcall(Color.ParseColor, color)
        if ok and r and g and b then
            local bestDistance = nil
            -- Weighted so the match tracks perceived colour rather than raw
            -- channel distance; green dominates luminance, blue least.
            for _, entry in ipairs(paletteRGB) do
                local dr = entry.r - r
                local dg = entry.g - g
                local db = entry.b - b
                local distance = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                if bestDistance == nil or distance < bestDistance then
                    bestDistance = distance
                    file = entry.file
                end
            end
        end
    end

    local path = Config.ModPath .. '/textures/cursors/' .. (file or NeutralArrow)
    arrowCache[color] = path
    return path
end

--- A colour string the UI can safely use for text and solid fills. The name
--- label and the HUD dot go through here so that a colour the engine cannot
--- parse never reaches SetColor.
---@param color string | nil
---@return string
function SafeUIColor(color)
    if type(color) ~= 'string' or color == '' then
        return 'ffffffff'
    end
    local ok, r = pcall(Color.ParseColor, color)
    if ok and r then
        return color
    end
    return 'ffffffff'
end

--- Ring texture used to show that a player is dragging a selection box.
---@return string
function SelectionRingTexture()
    return Config.ModPath .. '/textures/focus/original.png'
end
