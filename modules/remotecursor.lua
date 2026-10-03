--******************************************************************************
--** TeamMouse -- modules/remotecursor.lua
--**
--** One of these exists per remote player per world view. It owns the arrow,
--** the name label, the build ghost, and the HUD ghost.
--**
--** It does NOT drive itself. teammouse.lua runs a single frame callback that
--** advances every player's interpolated position once, then calls UpdateFrame
--** on each visual with pre-read view state. That keeps us to one engine frame
--** callback for the whole mod, and means view bounds, camera zoom and the
--** local mouse position are read once per frame rather than once per cursor.
--**
--** Performance notes, since the previous version was the source of the
--** reported slowdown:
--**
--**  * The group is an anchor pinned to the projected hotspot. Children are
--**    laid out relative to it ONCE at construction. Per frame we write two
--**    lazy vars and let the dependency graph move everything else.
--**    Calling LayoutHelpers.AtLeftTopIn every frame -- as the old code did --
--**    rebuilds closures on each call and is the expensive path.
--**  * Icon scale is quantised, so a slow camera zoom re-lays-out a handful of
--**    times instead of on all sixty frames.
--**  * Textures and alphas are only pushed when they actually change.
--******************************************************************************

local Config = import(_G.TeamMousePath .. '/modules/config.lua')
local CursorData = import(_G.TeamMousePath .. '/modules/cursordata.lua')
local Actions = import(_G.TeamMousePath .. '/modules/actions.lua')
local HudGhost = import(_G.TeamMousePath .. '/modules/hudghost.lua').HudGhost

local UIUtil = import('/lua/ui/uiutil.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Group = import('/lua/maui/group.lua').Group

local GameCommon = import('/lua/ui/game/gamecommon.lua')


--- bpId -> icon path. Resolving an icon costs several DiskGetFileInfo calls,
--- and a teammate cycling through a build menu would otherwise repeat them.
local buildIconCache = {}

---@param bpId string
---@return string | nil
local function ResolveBuildIcon(bpId)
    local cached = buildIconCache[bpId]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    local ok, icon = pcall(function()
        local bp = __blueprints[bpId]
        if not bp or not bp.Display or not bp.Display.IconName then
            return nil
        end
        local name = GameCommon.GetUnitIconFileNames(bp)
        return name
    end)

    if not ok or not icon then
        buildIconCache[bpId] = false
        return nil
    end

    buildIconCache[bpId] = icon
    return icon
end

--------------------------------------------------------------------------------
-- Dotted lines
--------------------------------------------------------------------------------
--
-- There is no rotated-bitmap primitive, so a line is a row of small squares. A
-- straight line in the world is a straight line on screen, so the dots are
-- spread evenly between the two projected end points. The pool is built once,
-- on first use, and each frame only moves dots that are in use.

---@param parent Control
---@param color string
---@param maxDots number
---@param size number
---@return table
local function CreateDotLine(parent, color, maxDots, size)
    local line = { dots = {}, max = maxDots, size = size, shown = 0, alpha = -1 }
    for i = 1, maxDots do
        local dot = Bitmap(parent)
        dot:SetSolidColor(color)
        dot:DisableHitTest(true)
        LayoutHelpers.SetDimensions(dot, size, size)
        -- Both pinned to real numbers, so the layout has a base case; see
        -- "The circular-dependency-in-lazy-evaluation trap" in engine-gotchas.
        dot.Left:SetValue(0)
        dot.Top:SetValue(0)
        dot:Hide()
        line.dots[i] = dot
    end
    return line
end

--- Lay the dots along (x1,y1) -> (x2,y2), screen coordinates. Uses as many as
--- the spacing asks for, up to the pool size, spread over the whole length.
---@param line table
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param spacing number
local function SetDotLine(line, x1, y1, x2, y2, spacing)
    local dx, dy = x2 - x1, y2 - y1
    local length = math.sqrt(dx * dx + dy * dy)

    local wanted = math.floor(length / spacing) + 1
    if wanted < 2 then wanted = 2 end
    if wanted > line.max then wanted = line.max end

    local half = line.size * 0.5
    for i = 1, wanted do
        local f = (i - 1) / (wanted - 1)
        local dot = line.dots[i]
        dot.Left:SetValue(x1 + dx * f - half)
        dot.Top:SetValue(y1 + dy * f - half)
        if i > line.shown then
            dot:Show()
        end
    end
    for i = wanted + 1, line.shown do
        line.dots[i]:Hide()
    end
    line.shown = wanted
end

---@param line table
local function HideDotLine(line)
    for i = 1, line.shown do
        line.dots[i]:Hide()
    end
    line.shown = 0
end

--- Lay the dots along a path of screen points, one every `spacing` pixels
--- along it. Spacing widens if the whole path would not fit in the pool, so it
--- is the end of the path that stays marked and not merely the start. Dots
--- that fall outside the view are left out; a path shorter than minLength is a
--- click, and shows nothing.
---@param line table
---@param xs table
---@param ys table
---@param n number
---@param spacing number
---@param minLength number
---@param viewInfo table
local function SetDotPath(line, xs, ys, n, spacing, minLength, viewInfo)
    local total = 0
    for i = 2, n do
        local dx, dy = xs[i] - xs[i - 1], ys[i] - ys[i - 1]
        total = total + math.sqrt(dx * dx + dy * dy)
    end

    if n < 2 or total < minLength then
        HideDotLine(line)
        return
    end

    if total / spacing > line.max - 1 then
        spacing = total / (line.max - 1)
    end

    local half = line.size * 0.5
    local used = 0
    local nextAt = 0     -- distance along the path of the next dot
    local walked = 0
    local left, top = viewInfo.left, viewInfo.top
    local right, bottom = viewInfo.right, viewInfo.bottom

    for i = 2, n do
        local x1, y1, x2, y2 = xs[i - 1], ys[i - 1], xs[i], ys[i]
        local dx, dy = x2 - x1, y2 - y1
        local len = math.sqrt(dx * dx + dy * dy)
        while nextAt <= walked + len and used < line.max do
            local f = 0
            if len > 0 then f = (nextAt - walked) / len end
            local px, py = x1 + dx * f, y1 + dy * f
            if px >= left and px <= right and py >= top and py <= bottom then
                used = used + 1
                local dot = line.dots[used]
                dot.Left:SetValue(px - half)
                dot.Top:SetValue(py - half)
                if used > line.shown then
                    dot:Show()
                end
            end
            nextAt = nextAt + spacing
        end
        walked = walked + len
    end

    for i = used + 1, line.shown do
        line.dots[i]:Hide()
    end
    line.shown = used
end

---@param line table
---@param alpha number
local function SetDotLineAlpha(line, alpha)
    if math.abs(alpha - line.alpha) < Config.Appearance.AlphaEpsilon then
        return
    end
    line.alpha = alpha
    for i = 1, line.max do
        line.dots[i]:SetAlpha(alpha)
    end
end

--- A parent's Show() shows every child, including the ones this line hid
--- individually. Put the unused ones back.
---@param line table
---@param hidden boolean   # the whole line is meant to be hidden
local function ResyncDotLine(line, hidden)
    for i = 1, line.max do
        line.dots[i]:SetHidden(hidden or i > line.shown)
    end
end

--------------------------------------------------------------------------------
-- Rows of structures
--------------------------------------------------------------------------------
--
-- A build drag lays a row out the way the game does: one structure per skirt
-- along whichever axis the drag covers more of, the other axis following in
-- whole skirt steps (the staircase a diagonal row makes).

--- bpId -> { skirtX, skirtZ }. Read once per blueprint.
local spacingCache = {}

--- How far apart the game packs a row of this structure, in world units: its
--- skirt (walls 1, a T1 power generator 2, ...), else its footprint, else 1.
---@param bpId string
---@return number, number
local function StructureSpacing(bpId)
    local cached = spacingCache[bpId]
    if cached then
        return cached[1], cached[2]
    end
    local sx, sz = 1, 1
    pcall(function()
        local bp = __blueprints[bpId]
        if not bp then return end
        local ph, fp = bp.Physics, bp.Footprint
        local x = (ph and ph.SkirtSizeX) or (fp and fp.SizeX) or bp.SizeX
        local z = (ph and ph.SkirtSizeZ) or (fp and fp.SizeZ) or bp.SizeZ
        if type(x) == 'number' and x > 0 then sx = x end
        if type(z) == 'number' and z > 0 then sz = z end
    end)
    spacingCache[bpId] = { sx, sz }
    return sx, sz
end

--- World X/Z of each structure a row from (x1, z1) towards (x2, z2) holds,
--- into xs/zs from index 1. Returns how many were written: every structure,
--- or `max` of them spread from the first to the last when there are more.
---
--- A drag in progress (exact false) only gains a structure at the far end
--- once the pointer has reached that structure's centre -- the midpoint of
--- its width -- as the game does. A placed row (exact true) runs between two
--- real structure centres, so its length is a whole number of skirts give or
--- take rounding on the wire, and is rounded.
---@param bpId string
---@param x1 number
---@param z1 number
---@param x2 number
---@param z2 number
---@param max number
---@param xs table
---@param zs table
---@return number
---@param exact? boolean
local function LayStructures(bpId, x1, z1, x2, z2, max, xs, zs, exact)
    local sx, sz = StructureSpacing(bpId)
    local dx, dz = x2 - x1, z2 - z1
    local ax, az = math.abs(dx) / sx, math.abs(dz) / sz
    local alongX = ax >= az
    local along = alongX and ax or az
    local steps
    if exact then
        steps = math.floor(along + 0.5)
    else
        -- The small allowance keeps a pointer sitting exactly on a centre
        -- from missing it to floating-point error.
        steps = math.floor(along + 1e-6)
    end

    local n = steps + 1
    if n > max then n = max end
    if n < 1 then n = 1 end

    for i = 1, n do
        -- Which structure of the row this icon stands for.
        local k = 0
        if n > 1 then
            k = math.floor((i - 1) * steps / (n - 1) + 0.5)
        end
        local t = 0
        if steps > 0 then t = k / steps end
        if alongX then
            local sign = 1
            if dx < 0 then sign = -1 end
            xs[i] = x1 + sign * k * sx
            zs[i] = z1 + math.floor(dz * t / sz + 0.5) * sz
        else
            local sign = 1
            if dz < 0 then sign = -1 end
            zs[i] = z1 + sign * k * sz
            xs[i] = x1 + math.floor(dx * t / sx + 0.5) * sx
        end
    end
    return n
end

--- Icon size for a row whose icons sit at these screen points: the configured
--- size, shrunk to the closest pair's spacing so neighbours don't pile up on
--- each other, but never below Line.MinStructureIcon.
---@param xs table
---@param ys table
---@param n number
---@param size number
---@return number
local function RowIconSize(xs, ys, n, size)
    local closest = false
    for i = 2, n do
        local dx, dy = xs[i] - xs[i - 1], ys[i] - ys[i - 1]
        local d = math.sqrt(dx * dx + dy * dy)
        if not closest or d < closest then closest = d end
    end
    if closest and closest - 2 < size then
        size = math.floor(closest - 2)
    end
    local floor = Config.Line.MinStructureIcon
    if size < floor then size = floor end
    return size
end

--- A pool of framed structure icons, built as far as it's needed, reused.
---@param parent Control
---@param color string
---@return table
local function CreateIconRow(parent, color)
    -- px/py/vis: each icon's centre and visibility as last set, so a row
    -- that has not moved costs no writes at all.
    return { parent = parent, color = color, frames = {}, icons = {}, made = 0, shown = 0,
        texture = false, size = -1, pad = -1, iconAlpha = 1, frameAlpha = 1,
        px = {}, py = {}, vis = {} }
end

--- Show `n` framed icons centred on the screen points xs[from..from+n-1],
--- ys[...]; hide the rest of the pool.
---@param row table
---@param texture string
---@param xs table
---@param ys table
---@param from number
---@param n number
---@param size number
---@param pad number   # frame thickness
local function SetIconRow(row, texture, xs, ys, from, n, size, pad)
    local parent = row.parent
    local resize = size ~= row.size or pad ~= row.pad
    for i = row.made + 1, n do
        local frame = Bitmap(parent)
        frame:SetSolidColor(row.color)
        frame:DisableHitTest(true)
        frame.Left:SetValue(0)
        frame.Top:SetValue(0)
        frame.Depth:Set(function() return parent.Depth() + 2 end)
        frame:SetAlpha(row.frameAlpha)
        LayoutHelpers.SetDimensions(frame, size + pad * 2, size + pad * 2)

        local icon = Bitmap(parent, texture)
        icon:DisableHitTest(true)
        icon.Left:SetValue(0)
        icon.Top:SetValue(0)
        icon.Depth:Set(function() return parent.Depth() + 3 end)
        icon:SetAlpha(row.iconAlpha)
        LayoutHelpers.SetDimensions(icon, size, size)

        row.frames[i], row.icons[i] = frame, icon
        row.px[i], row.py[i], row.vis[i] = false, false, true
        row.made = i
    end
    if texture ~= row.texture then
        row.texture = texture
        for i = 1, row.made do
            row.icons[i]:SetTexture(texture)
        end
    end
    if resize then
        row.size, row.pad = size, pad
        for i = 1, row.made do
            LayoutHelpers.SetDimensions(row.frames[i], size + pad * 2, size + pad * 2)
            LayoutHelpers.SetDimensions(row.icons[i], size, size)
            row.px[i] = false   -- placed for the old size: place again
        end
    end

    -- Only what changed: a row standing still (the camera and the drag both
    -- at rest) writes nothing.
    local half = size * 0.5
    local px, py, vis = row.px, row.py, row.vis
    for i = 1, n do
        local x, y = xs[from + i - 1], ys[from + i - 1]
        local frame, icon = row.frames[i], row.icons[i]
        if x ~= px[i] or y ~= py[i] then
            px[i], py[i] = x, y
            frame.Left:SetValue(x - half - pad)
            frame.Top:SetValue(y - half - pad)
            icon.Left:SetValue(x - half)
            icon.Top:SetValue(y - half)
        end
        if not vis[i] then
            vis[i] = true
            frame:SetHidden(false)
            icon:SetHidden(false)
        end
    end
    -- The spare ones every time: a parent's Show() re-shows every child,
    -- these included, without telling us.
    for i = n + 1, row.made do
        row.frames[i]:SetHidden(true)
        row.icons[i]:SetHidden(true)
        vis[i] = false
    end
    row.shown = n
end

---@param row table
local function HideIconRow(row)
    for i = 1, row.made do
        row.frames[i]:SetHidden(true)
        row.icons[i]:SetHidden(true)
        row.vis[i] = false
    end
    row.shown = 0
end

---@param row table
---@param iconAlpha number
---@param frameAlpha number
local function SetIconRowAlpha(row, iconAlpha, frameAlpha)
    row.iconAlpha, row.frameAlpha = iconAlpha, frameAlpha
    for i = 1, row.made do
        row.icons[i]:SetAlpha(iconAlpha)
        row.frames[i]:SetAlpha(frameAlpha)
    end
end

--- A parent's Show() shows every child, the unused ones included.
---@param row table
---@param hidden boolean   # the whole row is meant to be hidden
local function ResyncIconRow(row, hidden)
    for i = 1, row.made do
        local hide = hidden or i > row.shown
        row.frames[i]:SetHidden(hide)
        row.icons[i]:SetHidden(hide)
        row.vis[i] = not hide
    end
end

--- What to draw for a drag kind, given what is switched on: 'box', 'line',
--- 'follow' (nothing between the ends, the arrow just travels) or false.
---@param drag number   # 0 none, 1 box, 2 line, 3 order, 4 draw, 5 follow
---@return string | boolean
local function DragShape(drag)
    if drag == 0 then
        return false
    end
    if drag == 1 then
        -- Not showing their boxes: the arrow still rides the drag's live end
        -- (it used to freeze at the press and jump at the release).
        return (Config.Selection.Enabled and Config.Selection.ShowBox) and 'box' or 'follow'
    end
    if drag == 2 then
        return Config.Line.Enabled and 'line' or 'follow'
    end
    if drag == 3 and Config.Orders.Enabled and Config.Orders.ShowLiveLine then
        return 'line'
    end
    -- An order whose line is off, a drawing (whose trail is drawn by
    -- ApplyTrail), a Shift-drag or a waypoint being moved.
    return 'follow'
end

--------------------------------------------------------------------------------
-- A white stroke around text
--------------------------------------------------------------------------------
--
-- For names and indicators (an action, TEMPLATE), so they read over busy
-- ground and each other. Text in this game has no outline -- only a drop
-- shadow, and a black one -- so the stroke is eight copies of the text in the
-- stroke colour, one step off in each direction, drawn just under it. The
-- copies follow the text's position by themselves (lazy Left/Top); only their
-- words, opacity and visibility are set.

local STROKE_DX = { -1, 0, 1, -1, 1, -1, 0, 1 }
local STROKE_DY = { -1, -1, -1, 0, 0, 1, 1, 1 }

--- A stroke around `text` (which says `words`, at font size `size`), or false
--- with Appearance.TextStroke off. Starts hidden.
---@param parent Control
---@param text Control
---@param words string
---@param size number
---@return table | false
local function CreateTextStroke(parent, text, words, size, font)
    local cfg = Config.Appearance

    if not font then
        font = UIUtil.bodyFont
    end
    if not cfg.TextStroke then
        return false
    end
    local w = cfg.TextStrokeWidth
    local copies = {}
    for i = 1, 8 do
        local dx, dy = STROKE_DX[i] * w, STROKE_DY[i] * w
        local copy = UIUtil.CreateText(parent, words, size, font, false)
        copy:SetText(words)
        copy:SetColor(cfg.TextStrokeColor)
        copy:DisableHitTest(true)
        copy.Left:Set(function() return text.Left() + dx end)
        copy.Top:Set(function() return text.Top() + dy end)
        copy.Depth:Set(function() return parent.Depth() + 4 end)
        copy:SetHidden(true)
        copies[i] = copy
    end
    -- The text over its stroke, and without its black shadow, which would
    -- muddy the stroke.
    text.Depth:Set(function() return parent.Depth() + 5 end)
    pcall(text.SetDropShadow, text, false)
    return { copies = copies, words = words, alpha = -1, hidden = true }
end

---@param stroke table | false
---@param words string
local function SetStrokeText(stroke, words)
    if stroke and stroke.words ~= words then
        stroke.words = words
        for i = 1, 8 do
            stroke.copies[i]:SetText(words)
        end
    end
end

--- Visible, at `alpha` (its text's) times Appearance.TextStrokeAlpha.
---@param stroke table | false
---@param alpha number
local function ShowStroke(stroke, alpha)
    if not stroke then
        return
    end
    local a = alpha * Config.Appearance.TextStrokeAlpha
    if math.abs(a - stroke.alpha) >= Config.Appearance.AlphaEpsilon then
        stroke.alpha = a
        for i = 1, 8 do
            stroke.copies[i]:SetAlpha(a)
        end
    end
    if stroke.hidden then
        stroke.hidden = false
        for i = 1, 8 do
            stroke.copies[i]:SetHidden(false)
        end
    end
end

---@param stroke table | false
local function HideStroke(stroke)
    if stroke and not stroke.hidden then
        stroke.hidden = true
        for i = 1, 8 do
            stroke.copies[i]:SetHidden(true)
        end
    end
end

--- Put its copies back as they should be after a parent's Show() showed them.
---@param stroke table | false
---@param hidden boolean
local function ResyncStroke(stroke, hidden)
    if stroke then
        stroke.hidden = hidden
        for i = 1, 8 do
            stroke.copies[i]:SetHidden(hidden)
        end
    end
end

--------------------------------------------------------------------------------
-- Teammates' views, drawn in the world
--------------------------------------------------------------------------------
--
-- UI_DrawLine draws a line between two world points, but only from within a
-- world view's OnRenderWorld. FAF's world views take "shapes" for that
-- (WorldViewShapeComponent: AddShape / RemoveShape; each shape's Render is
-- called every frame). Each cursor registers one, once, and shows or hides it.
-- UpdateFrame works out where the lines go; Render only draws them.

--- Logged once if a view cannot take shapes (a game without FAF's
--- WorldViewShapeComponent): no outlines then.
local shapesMissingLogged = false

--- `color` ('AARRGGBB') with its alpha replaced by `alpha` (0..1).
---@param color string
---@param alpha number
---@return string
--- WithAlpha's answers, by colour and alpha byte: the line shapes ask every
--- frame, mostly for the same few colours, and building the string anew each
--- time made garbage. At most 256 per colour.
local alphaCache = {}

local function WithAlpha(color, alpha)
    if alpha < 0 then alpha = 0 end
    if alpha > 1 then alpha = 1 end
    local byte = math.floor(alpha * 255 + 0.5)
    local known = alphaCache[color]
    if not known then
        known = {}
        alphaCache[color] = known
    end
    local out = known[byte]
    if not out then
        out = string.format('%02x', byte) .. string.sub(color, 3)
        known[byte] = out
    end
    return out
end

--- A colour's own alpha, 0..1 (its first two hex digits), remembered.
local baseAlphaCache = {}
local function BaseAlpha(color)
    local a = baseAlphaCache[color]
    if not a then
        a = tonumber(string.sub(color, 1, 2), 16) / 255
        baseAlphaCache[color] = a
    end
    return a
end

--- A shape for one teammate's click pulses: up to six rings.
---@return table
local function NewPulseShape()
    local shape = { Hidden = true, n = 0, rings = {} }
    for i = 1, 6 do
        shape.rings[i] = { pos = { 0, 0, 0 }, r = 0, color = 'ffffffff', thick = 0 }
    end
    shape.OnRender = function(self, delta)
        for i = 1, self.n do
            local ring = self.rings[i]
            UI_DrawCircle(ring.pos, ring.r, ring.color, ring.thick)
        end
    end
    shape.Render = function(self, delta)
        if not self.Hidden and self.n > 0 then
            self:OnRender(delta)
        end
    end
    shape.Destroy = function(self) end
    return shape
end

--- A shape for one teammate's selection: a box on each unit (UI_DrawRect).
---@return table
local function NewSelectionShape()
    -- boxes[i]: where UI_DrawRect is given it; sizes[i]: its side.
    local shape = { Hidden = true, n = 0, boxes = {}, sizes = {}, color = 'ffffffff', thick = 0 }
    shape.OnRender = function(self, delta)
        for i = 1, self.n do
            UI_DrawRect(self.boxes[i], self.sizes[i], self.color, self.thick)
        end
    end
    shape.Render = function(self, delta)
        if not self.Hidden and self.n > 0 then
            self:OnRender(delta)
        end
    end
    shape.Destroy = function(self) end
    return shape
end

--- A shape for one teammate's selection rectangles (more selected than they
--- send ids for): four lines each.
---@return table
local function NewRectShape()
    local shape = { Hidden = true, n = 0, a = {}, b = {}, color = 'ffffffff', thick = 0 }
    shape.OnRender = function(self, delta)
        for i = 1, self.n do
            UI_DrawLine(self.a[i], self.b[i], self.color, self.thick)
        end
    end
    shape.Render = function(self, delta)
        if not self.Hidden and self.n > 0 then
            self:OnRender(delta)
        end
    end
    shape.Destroy = function(self) end
    return shape
end

--- Line `n + 1` of a rectangle shape: from (ax, az) to (bx, bz) at height y,
--- written into the shape's own endpoint tables (made once, reused every
--- frame after). Returns the new line count. Called per edge, per frame, so
--- it makes no garbage: Lua 5.0's collector stops the game to clean up.
---@return number
local function PutRectEdge(shape, n, ax, az, bx, bz, y)
    n = n + 1
    local a, b = shape.a[n], shape.b[n]
    if not a then
        a, b = { 0, 0, 0 }, { 0, 0, 0 }
        shape.a[n], shape.b[n] = a, b
    end
    a[1], a[2], a[3] = ax, y, az
    b[1], b[2], b[3] = bx, y, bz
    return n
end

--- A shape for one teammate's view outline: four lines in their colour.
---@return table
local function NewViewShape()
    local function Points()
        return { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
    end
    local shape = {
        Hidden = true,
        color = 'ffffffff', thick = 0,
        a = Points(), b = Points(),     -- each edge's two ends
    }
    shape.OnRender = function(self, delta)
        for i = 1, 4 do
            UI_DrawLine(self.a[i], self.b[i], self.color, self.thick)
        end
    end
    shape.Render = function(self, delta)
        if not self.Hidden then
            self:OnRender(delta)
        end
    end
    shape.Destroy = function(self) end
    return shape
end

--- Shown above a template's first structure.
TEMPLATE_TEXT = 'TEMPLATE'

--- Brightness of a flashing TEMPLATE, `t` seconds after it appeared: on and
--- off, Build.TemplateFlashPeriod per cycle, never quite out.
---@param t number
---@return number
local function TemplateFlash(t)
    local period = Config.Build.TemplateFlashPeriod
    if period <= 0 then
        return 1
    end
    local phase = math.mod(t, period) / period
    if phase < 0.6 then
        return 1
    end
    return 0.25
end

--- How far the local camera has pulled back into "far" territory: 0 up to
--- Zoom.FarStartZoom, 1 from Zoom.FarEndZoom on. Out there cursors are made
--- easier to see, not harder (see Zoom in config.lua).
---@param viewInfo table
---@return number
local function FarFactor(viewInfo)
    local cfg = Config.Zoom
    if not cfg.Enabled or not viewInfo.zoom then
        return 0
    end
    local z0, z1 = cfg.FarStartZoom, cfg.FarEndZoom
    if viewInfo.zoom <= z0 then
        return 0
    end
    if z1 <= z0 or viewInfo.zoom >= z1 then
        return 1
    end
    return (viewInfo.zoom - z0) / (z1 - z0)
end

---@class RemoteCursor : Group
RemoteCursor = Class(Group) {

    ---@param self RemoteCursor
    ---@param view WorldView        # the world view this cursor is drawn in
    ---@param record table          # shared per-player state from teammouse.lua
    __init = function(self, view, record)
        Group.__init(self, view, 'TeamMouseCursor')

        self.view = view
        self.record = record

        -- The anchor is a 1x1 point. Everything else hangs off it.
        self.Width:Set(1)
        self.Height:Set(1)
        self:DisableHitTest(true)

        -- Cached render state, so we only touch the engine on real changes.
        self.appliedScale = -1
        self.appliedOrder = -1
        self.appliedAlpha = -1
        self.appliedLabelAlpha = -1
        self.appliedBuild = false
        self.hidden = true
        self.buildShown = false
        self.hudShown = false
        self.hotspotX = Config.Appearance.ArrowHotspotX
        self.hotspotY = Config.Appearance.ArrowHotspotY

        self.followingDragBox = false
        self.showingOrderIcon = false

        -- Structure drag line, built on first use.
        self.line = false
        self.lineShown = false

        -- One framed icon per structure a build drag's row will hold, built
        -- on first use. rowX/rowZ: their world spots; rowSX/rowSY: projected
        -- (reused each frame, and by ApplyOrders for placed rows).
        self.row = false
        self.rowShown = false
        self.rowX, self.rowZ, self.rowSX, self.rowSY = {}, {}, {}, {}

        -- Right-click order markers. They belong to the player rather than to
        -- their cursor -- an order stays put on the map after the cursor has
        -- moved on, or been culled -- so they hang off a group of their own on
        -- the view. Built on first use.
        self.orderRoot = false
        self.orderMarks = {}
        self.orderShown = 0

        -- The icon of an order they are dragging; built on first use.
        self.grabIcon = false
        self.grabShown = false
        self.grabTexture = false

        -- The label for their last action; built on first use.
        self.actionLabel = false
        self.templateLabel = false
        self.templateStroke = false
        self.templateShown = false
        self.actionStroke = false
        self.actionShown = false
        self.actionCode = false
        -- The drawing trail. pts: world points (reused tables), n how many are
        -- in use, endT when the button came up (it then fades), line its dots
        -- (built on first use), xs/ys the projected path, reused each frame.
        self.trail = { pts = {}, n = 0, endT = false, line = false, xs = {}, ys = {} }
        self.projIn = { 0, 0, 0 }
        self.projIn2 = { 0, 0, 0 }
        -- The drag's live end, projected every frame of a drag: reused.
        self.projBox = { 0, 0, 0 }

        self.arrowTexture = CursorData.ArrowForColor(record.color)
        self.uiColor = CursorData.SafeUIColor(record.color)

        -- Build ghost controls are created on first use rather than up front.
        -- A Bitmap with no texture assigned produces "GetResource: Invalid
        -- name" warnings when the engine tries to resolve it, and most cursors
        -- never enter build mode at all.
        self.buildIcon = false
        self.buildFrame = false

        -- The cursor itself.
        self.mouseIcon = Bitmap(self, self.arrowTexture)
        self.mouseIcon:DisableHitTest(true)

        -- Name label.
        if Config.Appearance.ShowLabels then
            self.label = UIUtil.CreateText(self, record.name or '?',
                Config.Appearance.LabelSize, "Arial Bold", true)
            self.label:SetColor(self.uiColor)
            self.label:DisableHitTest(true)
        end

        -- A white stroke around the name, so it reads over busy ground. It
        -- follows the name; its opacity is the name's (ApplyAlpha).
        self.nameStroke = false
        if self.label then
            self.nameStroke = CreateTextStroke(self, self.label, record.name or '?',
                Config.Appearance.LabelSize, "Arial Bold")
        end

        -- A bar in their colour under their name, as wide as THEIR zoom says
        -- (ApplyNameBar): the name's width zoomed all the way in, shrinking
        -- as they pull back. Tied to the label, and kept centred under it.
        self.nameBar = false
        self.nameBarShown = false
        self.nameBarWidth = -1
        self.nameBarAlpha = -1
        if self.label and Config.Appearance.NameBar then
            local bar = Bitmap(self)
            bar:SetSolidColor(self.uiColor)
            bar:DisableHitTest(true)
            local label = self.label
            bar.Width:SetValue(0)
            bar.Left:Set(function() return label.Left() + (label.Width() - bar.Width()) * 0.5 end)
            bar.Top:Set(function() return label.Top() + label.Height() + 1 end)
            bar.Height:SetValue(Config.Appearance.NameBarHeight)
            bar:SetHidden(true)
            -- Over the name's stroke, which reaches a pixel below the name.
            bar.Depth:Set(function() return self.Depth() + 7 end)
            self.nameBar = bar

            -- The same stroke as the name's: a rectangle in the stroke colour,
            -- TextStrokeWidth bigger all round, just under the bar.
            self.nameBarStroke = false
            if Config.Appearance.TextStroke then
                local w = Config.Appearance.TextStrokeWidth
                local stroke = Bitmap(self)
                stroke:SetSolidColor(Config.Appearance.TextStrokeColor)
                stroke:DisableHitTest(true)
                stroke.Left:Set(function() return bar.Left() - w end)
                stroke.Top:Set(function() return bar.Top() - w end)
                stroke.Width:Set(function() return bar.Width() + w * 2 end)
                stroke.Height:Set(function() return bar.Height() + w * 2 end)
                stroke.Depth:Set(function() return self.Depth() + 6 end)
                stroke:SetHidden(true)
                self.nameBarStroke = stroke
            end
        end

        -- Their view's outline (Viewport), a shape drawn by the view itself:
        -- it stays while their pointer is on their interface.
        self.viewShape = false
        self.pulseShape = false
        self.rectShape = false
        self.selShape = false
        self.selUnits = {}
        self.selVersion = -1
        self.selMissing = 0
        self.selLookT = 0
        self.shapeIds = false

        -- HUD ghost, created lazily -- most cursors never need one, and the
        -- 'full' silhouette is a fair number of bitmaps to build up front.
        self.hud = false
        -- The ghost fades in on reaching their interface and out on leaving it.
        -- hudShown says they ARE on it; hudVisible says the ghost is still on
        -- screen, which it is for a moment after they leave.
        self.hudFade = 0
        self.hudVisible = false
        self.appliedHudAlpha = -1
        self.curAlpha = 0
        self.lastNow = false

        self:ApplyScale(1.0, true)
        self:Hide()
    end,

    --- Lay the icon and label out for a given scale factor. Only called when
    --- the quantised scale or the cursor's hotspot actually changes.
    ---@param self RemoteCursor
    ---@param scale number
    ---@param force boolean
    ApplyScale = function(self, scale, force)
        if not force and scale == self.appliedScale then
            return
        end
        self.appliedScale = scale

        local size = self.showingOrderIcon
            and Config.Appearance.OrderIconSize
            or Config.Appearance.ArrowSize

        local drawSize = math.floor(size * scale + 0.5)
        if drawSize < 6 then drawSize = 6 end

        local hx = math.floor(self.hotspotX * scale + 0.5)
        local hy = math.floor(self.hotspotY * scale + 0.5)

        LayoutHelpers.SetDimensions(self.mouseIcon, drawSize, drawSize)
        LayoutHelpers.AtLeftTopIn(self.mouseIcon, self, -hx, -hy)

        if self.label then
            LayoutHelpers.CenteredBelow(self.label, self.mouseIcon, Config.Appearance.LabelOffset)
        end
    end,

    --- Swap the cursor texture when the remote player's order changes.
    ---@param self RemoteCursor
    ---@param orderIndex number
    -- ApplyOrder
    ApplyOrder = function(self, orderIndex)
        if orderIndex == self.appliedOrder then
            return
        end
        self.appliedOrder = orderIndex

        local texture = CursorData.TextureForIndex(orderIndex)
        if texture then
            self.mouseIcon:SetTexture(texture)
            self.hotspotX, self.hotspotY = CursorData.HotspotForIndex(orderIndex)
            self.showingOrderIcon = true
        else
            -- Unknown order, or the texture is missing from this skin.
            self.mouseIcon:SetTexture(self.arrowTexture)
            self.hotspotX = Config.Appearance.ArrowHotspotX
            self.hotspotY = Config.Appearance.ArrowHotspotY
            self.showingOrderIcon = false
        end

        -- Size and hotspot both changed, so re-lay-out at the current scale.
        self:ApplyScale(self.appliedScale, true)
    end,

    --- Build the ghost controls. Deferred until a teammate actually enters
    --- build mode, because a Bitmap with no texture yet assigned makes the
    --- engine complain, and most cursors never need these at all.
    ---@param self RemoteCursor
    ---@param icon string
    CreateBuildGhost = function(self, icon)
        local size = Config.Build.IconSize
        local pad = Config.Build.FrameThickness

        self.buildFrame = Bitmap(self)
        self.buildFrame:SetSolidColor(self.uiColor)
        LayoutHelpers.SetDimensions(self.buildFrame, size + pad * 2, size + pad * 2)
        LayoutHelpers.AtLeftTopIn(self.buildFrame, self,
            Config.Build.OffsetX - pad, Config.Build.OffsetY - pad)
        self.buildFrame:DisableHitTest(true)
        self.buildFrame:Hide()

        self.buildIcon = Bitmap(self, icon)
        LayoutHelpers.SetDimensions(self.buildIcon, size, size)
        LayoutHelpers.AtLeftTopIn(self.buildIcon, self,
            Config.Build.OffsetX, Config.Build.OffsetY)
        self.buildIcon:DisableHitTest(true)
        self.buildIcon:Hide()

        -- Alpha is only pushed on change, so a ghost created after the cursor
        -- has settled would otherwise stay at full opacity until the next
        -- alpha change. Force one.
        self.appliedAlpha = -1
    end,

    --- Show or hide the build ghost.
    ---@param self RemoteCursor
    ---@param bpId string | false
    ApplyBuild = function(self, bpId)
        if not Config.Build.Enabled then
            return
        end

        if bpId == self.appliedBuild then
            return
        end
        self.appliedBuild = bpId

        local icon = bpId and ResolveBuildIcon(bpId)

        if icon then
            if not self.buildIcon then
                self:CreateBuildGhost(icon)
            else
                self.buildIcon:SetTexture(icon)
            end
            if not self.buildShown then
                self.buildIcon:Show()
                self.buildFrame:Show()
                self.buildShown = true
            end
        elseif self.buildShown and self.buildIcon then
            self.buildIcon:Hide()
            self.buildFrame:Hide()
            self.buildShown = false
        end
    end,

        --- Build the four border strips of the drag-box outline. Deferred until a
    --- teammate actually drags something -- same reasoning as the build
    --- ghost: most cursors never need this at all.
    ---@param self RemoteCursor
    CreateDragBox = function(self)
        self.dragTop = Bitmap(self)
        self.dragBottom = Bitmap(self)
        self.dragLeft = Bitmap(self)
        self.dragRight = Bitmap(self)
        for _, edge in ipairs({ self.dragTop, self.dragBottom, self.dragLeft, self.dragRight }) do
            edge:SetSolidColor(self.uiColor)
            edge:DisableHitTest(true)
            edge:Hide()
        end
        -- Same reasoning as CreateBuildGhost: force the next alpha push.
        self.appliedAlpha = -1
    end,

    --- Show, hide, or reposition the drag-box outline. Corner 1 is always the
    --- anchor itself (0,0 in this group's own coordinates -- the cursor's own
    --- position IS the drag's start corner by construction); dx,dy is the
    --- live corner, anchor-relative, already projected by UpdateFrame.
    ---@param self RemoteCursor
    ---@param showing boolean
    ---@param dx? number
    ---@param dy? number
    ApplyDragBox = function(self, showing, dx, dy)
        if not showing then
            if self.dragBoxShown then
                self.dragTop:Hide()
                self.dragBottom:Hide()
                self.dragLeft:Hide()
                self.dragRight:Hide()
                self.dragBoxShown = false
            end
            return
        end
        if not self.dragTop then
            self:CreateDragBox()
        end

        local thickness = Config.Selection.BoxThickness
        local left = math.min(0, dx)
        local right = math.max(0, dx)
        local top = math.min(0, dy)
        local bottom = math.max(0, dy)
        local width = right - left
        local height = bottom - top

        LayoutHelpers.SetDimensions(self.dragTop, width + thickness, thickness)
        LayoutHelpers.AtLeftTopIn(self.dragTop, self, left - thickness * 0.5, top - thickness * 0.5)

        LayoutHelpers.SetDimensions(self.dragBottom, width + thickness, thickness)
        LayoutHelpers.AtLeftTopIn(self.dragBottom, self, left - thickness * 0.5, bottom - thickness * 0.5)

        LayoutHelpers.SetDimensions(self.dragLeft, thickness, height + thickness)
        LayoutHelpers.AtLeftTopIn(self.dragLeft, self, left - thickness * 0.5, top - thickness * 0.5)

        LayoutHelpers.SetDimensions(self.dragRight, thickness, height + thickness)
        LayoutHelpers.AtLeftTopIn(self.dragRight, self, right - thickness * 0.5, top - thickness * 0.5)

        if not self.dragBoxShown then
            self.dragTop:Show()
            self.dragBottom:Show()
            self.dragLeft:Show()
            self.dragRight:Show()
            self.dragBoxShown = true
        end
    end,

    --- Show, hide or reposition the structure drag line. Same convention as
    --- ApplyDragBox: it starts at the anchor and ends dx,dy away from it.
    ---@param self RemoteCursor
    ---@param showing boolean
    ---@param dx? number
    ---@param dy? number
    ApplyDragLine = function(self, showing, dx, dy)
        if showing then
            local minLength = Config.Line.MinLength
            if dx * dx + dy * dy < minLength * minLength then
                showing = false
            end
        end

        if not showing then
            if self.lineShown then
                HideDotLine(self.line)
                self.lineShown = false
            end
            return
        end

        if not self.line then
            self.line = CreateDotLine(self, self.uiColor, Config.Line.MaxDots, Config.Line.DotSize)
            self.appliedAlpha = -1
        end

        SetDotLine(self.line, self.Left(), self.Top(),
            self.Left() + dx, self.Top() + dy, Config.Line.DotSpacing)
        self.lineShown = true
    end,

    --- Project the row of structures from world spots rowX/rowZ[1..n] at
    --- height y into rowSX/rowSY. False if any of them can't be projected.
    ---@param self RemoteCursor
    ---@param viewInfo table
    ---@param n number
    ---@param y number
    ---@return boolean
    ProjectRow = function(self, viewInfo, n, y)
        local p = self.projIn2
        for i = 1, n do
            p[1], p[2], p[3] = self.rowX[i], y, self.rowZ[i]
            local proj = self.view:Project(p)
            if not proj or not proj.x then
                return false
            end
            self.rowSX[i] = viewInfo.left + proj.x
            self.rowSY[i] = viewInfo.top + proj.y
        end
        return true
    end,

    --- A build drag in progress: one framed icon on each spot the row will
    --- put a structure, from the anchor towards the live end. Takes the place
    --- of the single build ghost beside the cursor (see UpdateFrame).
    ---@param self RemoteCursor
    ---@param bpId string | boolean   # false to hide
    ---@param viewInfo? table
    ApplyLineStructures = function(self, bpId, viewInfo)
        local texture = bpId and ResolveBuildIcon(bpId)
        local n = 0
        if texture then
            local record = self.record
            n = LayStructures(bpId, record.render[1], record.render[3],
                record.boxRender[1], record.boxRender[2], Config.Line.MaxStructures, self.rowX, self.rowZ)
            if not self:ProjectRow(viewInfo, n, record.render[2]) then
                n = 0
            end
        end

        if n == 0 then
            if self.rowShown then
                HideIconRow(self.row)
                self.rowShown = false
            end
            return
        end

        if not self.row then
            self.row = CreateIconRow(self, self.uiColor)
            self.appliedAlpha = -1   -- push the cursor's alpha to it
        end
        local size = RowIconSize(self.rowSX, self.rowSY, n, Config.Orders.BuildIconSize)
        SetIconRow(self.row, texture, self.rowSX, self.rowSY, 1, n, size, Config.Orders.BuildFrame)
        self.rowShown = true
    end,

    --- Hide the cursor and everything drawn for this player on the map.
    ---@param self RemoteCursor
    HideEverything = function(self)
        self:SetVisible(false)
        if self.viewShape then
            self.viewShape.Hidden = true
        end
        if self.pulseShape then
            self.pulseShape.Hidden = true
        end
        if self.selShape then
            self.selShape.Hidden = true
        end
        if self.rectShape then
            self.rectShape.Hidden = true
        end
        for _, mark in pairs(self.orderMarks) do
            self:HideOrderMark(mark)
        end
        self.orderShown = 0
        local trail = self.trail
        if trail.line and trail.line.shown > 0 then
            HideDotLine(trail.line)
        end
        trail.n = 0
        trail.endT = false
    end,

    --- Whether a drag in progress, from the anchor at (ax, ay) to its live end,
    --- overlaps this view.
    ---@param self RemoteCursor
    ---@param viewInfo table
    ---@param ax number
    ---@param ay number
    ---@param m number   # cull margin
    ---@return boolean
    DragReachesView = function(self, viewInfo, ax, ay, m)
        local record = self.record
        if record.renderDrag == 0 then
            return false
        end
        local p = self.projIn2
        p[1], p[2], p[3] = record.boxRender[1], record.render[2], record.boxRender[2]
        local proj = self.view:Project(p)
        if not proj or not proj.x then
            return false
        end
        local ex, ey = viewInfo.left + proj.x, viewInfo.top + proj.y
        local minX, maxX = math.min(ax, ex), math.max(ax, ex)
        local minY, maxY = math.min(ay, ey), math.max(ay, ey)
        return maxX >= viewInfo.left - m and minX <= viewInfo.right + m
            and maxY >= viewInfo.top - m and minY <= viewInfo.bottom + m
    end,

    --- No drag: no box, no line, arrow on the anchor.
    ---@param self RemoteCursor
    ClearDrag = function(self)
        self:ApplyDragBox(false)
        self:ApplyDragLine(false)
        self:ApplyLineStructures(false)
        self:ApplyGrabIcon(false)
        self:StopFollowing()
    end,

    --- The icon of an order being dragged, centred on the drag's live end,
    --- under the hand.
    ---@param self RemoteCursor
    ---@param kind number | boolean   # cursor index of the order, or false for none
    ---@param dx? number
    ---@param dy? number
    ApplyGrabIcon = function(self, kind, dx, dy)
        local texture = kind and CursorData.TextureForIndex(kind)
        if not texture then
            if self.grabIcon and self.grabShown then
                self.grabIcon:Hide()
                self.grabShown = false
            end
            return
        end

        local size = Config.Orders.IconSize
        if not self.grabIcon then
            self.grabIcon = Bitmap(self, texture)
            self.grabTexture = texture
            self.grabIcon:DisableHitTest(true)
            LayoutHelpers.SetDimensions(self.grabIcon, size, size)
            self.grabIcon.Left:SetValue(0)
            self.grabIcon.Top:SetValue(0)
            self.grabIcon.Depth:Set(function() return self.mouseIcon.Depth() - 1 end)
            self.appliedAlpha = -1
        elseif self.grabTexture ~= texture then
            self.grabIcon:SetTexture(texture)
            self.grabTexture = texture
        end
        self.grabIcon.Left:SetValue(self.Left() + dx - size * 0.5)
        self.grabIcon.Top:SetValue(self.Top() + dy - size * 0.5)
        if not self.grabShown then
            self.grabIcon:Show()
            self.grabShown = true
        end
    end,

    --- Stop the arrow following a drag's live end and put it back on the anchor.
    ---@param self RemoteCursor
    StopFollowing = function(self)
        if self.followingDragBox then
            self.followingDragBox = false
            self:ApplyScale(self.appliedScale, true)   -- rebinds mouseIcon to self via AtLeftTopIn
        end
    end,

    --------------------------------------------------------------------------
    -- Right-click orders
    --------------------------------------------------------------------------

    --- The group everything pinned to the map hangs off: orders, the trail.
    --- Belongs to the view, not the cursor, because these stay put after the
    --- cursor has moved on or been culled.
    ---@param self RemoteCursor
    ---@return Group
    GetMapRoot = function(self)
        if not self.orderRoot then
            local root = Group(self.view, 'TeamMouseOrders')
            root.Left:SetValue(0)
            root.Top:SetValue(0)
            root.Width:Set(1)
            root.Height:Set(1)
            root:DisableHitTest(true)
            self.orderRoot = root
        end
        return self.orderRoot
    end,

    --- The path of the pointer while they draw. Points are kept in world
    --- coordinates, so the trail stays on the map as the camera moves, and
    --- dotted along at a fixed screen spacing. Fades once the button is up.
    ---@param self RemoteCursor
    ---@param viewInfo table
    ---@param now number
    ApplyTrail = function(self, viewInfo, now)
        local record = self.record
        local cfg = Config.Draw
        local trail = self.trail

        if not cfg.Enabled then
            if trail.n > 0 then
                trail.n = 0
                trail.endT = false
            end
            if trail.line and trail.line.shown > 0 then
                HideDotLine(trail.line)
            end
            return
        end

        if record.renderDrag == 4 and not viewInfo.hidden then
            -- A new stroke starts from nothing.
            if trail.endT then
                trail.n = 0
                trail.endT = false
            end

            local bx, bz = record.boxRender[1], record.boxRender[2]
            local n = trail.n
            local last = trail.pts[n]
            if not last then
                -- The stroke starts where it was pressed.
                n = 1
                local p = trail.pts[1] or {}
                trail.pts[1] = p
                p[1], p[2], p[3] = record.render[1], record.render[2], record.render[3]
                last = p
            end
            local dx, dz = bx - last[1], bz - last[3]
            if dx * dx + dz * dz >= cfg.MinStep * cfg.MinStep then
                if n >= cfg.MaxPoints then
                    -- Full: drop the oldest, reusing its table for the newest.
                    local oldest = trail.pts[1]
                    for i = 1, n - 1 do
                        trail.pts[i] = trail.pts[i + 1]
                    end
                    trail.pts[n] = oldest
                else
                    n = n + 1
                    trail.pts[n] = trail.pts[n] or {}
                end
                local p = trail.pts[n]
                p[1], p[2], p[3] = bx, record.render[2], bz
            end
            trail.n = n
        elseif trail.n > 0 and not trail.endT then
            trail.endT = now
        end

        if trail.n < 2 then
            if trail.line and trail.line.shown > 0 then
                HideDotLine(trail.line)
            end
            if trail.endT then trail.n = 0; trail.endT = false end
            return
        end

        local fade = 1
        if trail.endT then
            fade = 1 - (now - trail.endT) / cfg.FadeTime
            if fade <= 0 then
                trail.n = 0
                trail.endT = false
                if trail.line then HideDotLine(trail.line) end
                return
            end
        end

        if viewInfo.hidden then
            if trail.line and trail.line.shown > 0 then
                HideDotLine(trail.line)
            end
            return
        end

        -- Project the points, and lay dots along the path between them.
        local xs, ys = trail.xs, trail.ys
        local count = 0
        local pin = self.projIn
        for i = 1, trail.n do
            local p = trail.pts[i]
            pin[1], pin[2], pin[3] = p[1], p[2], p[3]
            local proj = self.view:Project(pin)
            if proj and proj.x then
                count = count + 1
                xs[count] = viewInfo.left + proj.x
                ys[count] = viewInfo.top + proj.y
            end
        end

        if not trail.line then
            trail.line = CreateDotLine(self:GetMapRoot(), self.uiColor, cfg.MaxDots, cfg.DotSize)
        end
        SetDotPath(trail.line, xs, ys, count, cfg.DotSpacing, cfg.MinLength, viewInfo)
        SetDotLineAlpha(trail.line, Config.Appearance.BaseAlpha * Config.Line.Alpha * fade)
        ResyncDotLine(trail.line, false)
    end,

    --- One marker: a square on the destination in the player's colour, the
    --- order's own cursor icon beside it when it is something other than a
    --- plain move, and a dotted line to where a right-drag ended.
    ---@param self RemoteCursor
    ---@param i number
    ---@return table
    GetOrderMark = function(self, i)
        local mark = self.orderMarks[i]
        if mark then
            return mark
        end

        local size = Config.Orders.MarkerSize
        local square = Bitmap(self:GetMapRoot())
        square:SetSolidColor(self.uiColor)
        square:DisableHitTest(true)
        LayoutHelpers.SetDimensions(square, size, size)
        square.Left:SetValue(0)
        square.Top:SetValue(0)
        square:Hide()

        mark = { square = square, squareColor = self.uiColor, icon = false, iconTexture = false, line = false,
            alpha = -1, visible = false, iconShown = false, lineShown = false,
            row = false, rowShown = false, tlabel = false, tstroke = false, tlabelShown = false,
            diamond = false, diamondShown = false, diamondSize = -1 }
        self.orderMarks[i] = mark
        return mark
    end,

    --- An upgrade's gold diamond, behind the marker's frame: built on first
    --- use, sized from the frame (Orders.UpgradeDiamondScale), hidden for any
    --- other kind of marker.
    ---@param self RemoteCursor
    ---@param mark table
    ---@param show boolean
    ---@param ax number
    ---@param ay number
    ---@param squareSize number
    ApplyUpgradeDiamond = function(self, mark, show, ax, ay, squareSize)
        if not show then
            if mark.diamond and mark.diamondShown then
                mark.diamond:Hide()
                mark.diamondShown = false
            end
            return
        end
        if not mark.diamond then
            local diamond = Bitmap(self:GetMapRoot(), _G.TeamMousePath .. Config.Orders.UpgradeTexture)
            diamond:DisableHitTest(true)
            diamond.Left:SetValue(0)
            diamond.Top:SetValue(0)
            -- Behind the frame, which is behind the icon.
            mark.square.Depth:Set(diamond.Depth() + 1)
            mark.diamond = diamond
            mark.alpha = -1
        end
        local size = math.floor(squareSize * Config.Orders.UpgradeDiamondScale + 0.5)
        if mark.diamondSize ~= size then
            mark.diamondSize = size
            LayoutHelpers.SetDimensions(mark.diamond, size, size)
        end
        mark.diamond.Left:SetValue(ax - size * 0.5)
        mark.diamond.Top:SetValue(ay - size * 0.5)
        mark.diamond:SetHidden(false)
        mark.diamondShown = true
    end,

    ---@param self RemoteCursor
    ---@param mark table
    HideOrderMark = function(self, mark)
        if not mark.visible then
            return
        end
        mark.visible = false
        mark.square:Hide()
        if mark.diamond and mark.diamondShown then
            mark.diamond:Hide()
            mark.diamondShown = false
        end
        if mark.icon and mark.iconShown then
            mark.icon:Hide()
            mark.iconShown = false
        end
        if mark.line and mark.lineShown then
            HideDotLine(mark.line)
            mark.lineShown = false
        end
        if mark.row and mark.rowShown then
            HideIconRow(mark.row)
            mark.rowShown = false
        end
        if mark.tlabel and mark.tlabelShown then
            mark.tlabel:Hide()
            HideStroke(mark.tstroke)
            mark.tlabelShown = false
        end
    end,

    --- Place every live order of this player on this view. Runs every frame
    --- but costs nothing while there are none and none are showing.
    ---@param self RemoteCursor
    ---@param viewInfo table
    ---@param now number
    ApplyOrders = function(self, viewInfo, now)
        local record = self.record
        local cfg = Config.Orders
        -- Not shown at all: as if there were none (any up are hidden below).
        local count = cfg.Enabled and record.orderCount or 0
        if count == 0 and self.orderShown == 0 then
            return
        end

        local margin = Config.Appearance.CullMargin

        for i = 1, count do
            local order = record.orders[i]
            local mark = nil
            local age = now - order.t

            local proj = nil
            -- A kind we do not show: placed structures (ShowBuilds), upgrades
            -- (ShowUpgrades). Sent regardless; the choice is ours.
            local shown = true
            if order.upgrade then
                shown = cfg.ShowUpgrades
            elseif order.bp then
                shown = cfg.ShowBuilds
            end
            -- Not yet due: its release has not been drawn yet.
            if shown and not viewInfo.hidden and age >= 0 then
                local p = self.projIn
                p[1], p[2], p[3] = order.x, order.y, order.z
                proj = self.view:Project(p)
            end

            if proj and proj.x then
                local ax = viewInfo.left + proj.x
                local ay = viewInfo.top + proj.y
                if ax >= viewInfo.left - margin and ax <= viewInfo.right + margin
                    and ay >= viewInfo.top - margin and ay <= viewInfo.bottom + margin then
                    mark = self:GetOrderMark(i)

                    local fade = 1
                    if age > cfg.FadeHold then
                        fade = 1 - (age - cfg.FadeHold) / (cfg.Lifetime - cfg.FadeHold)
                        if fade < 0 then fade = 0 end
                    end
                    local alpha = Config.Appearance.BaseAlpha * fade

                    -- Explicit, every frame: a shown view re-shows all of its
                    -- children, this one included.
                    mark.square:SetHidden(false)
                    mark.visible = true

                    -- A structure placed: its icon on the spot, framed in the
                    -- player's colour. Any other order: a square on the spot,
                    -- with the order's own cursor beside it if it has one.
                    local buildIcon = order.bp and ResolveBuildIcon(order.bp)
                    local texture, iconSize, squareSize

                    -- A row of them: one icon per structure, the first being
                    -- this mark's own, the rest from its row pool.
                    local rowN = 0
                    if buildIcon and Config.Line.ShowStructures and not order.template
                        and (order.x2 ~= order.x or order.z2 ~= order.z) then
                        rowN = LayStructures(order.bp, order.x, order.z, order.x2, order.z2,
                            Config.Line.MaxStructures, self.rowX, self.rowZ, true)
                        if not self:ProjectRow(viewInfo, rowN, order.y) then
                            rowN = 0
                        end
                    end

                    -- An upgrade: a gold diamond behind the frame (which
                    -- stays in their colour, like any structure's), so it
                    -- reads as "this building is becoming that" by its shape
                    -- -- a yellow player's frame is near gold already.
                    local upgrade = buildIcon and order.upgrade and true or false

                    if buildIcon then
                        texture = buildIcon
                        iconSize = cfg.BuildIconSize
                        if rowN >= 2 then
                            iconSize = RowIconSize(self.rowSX, self.rowSY, rowN, iconSize)
                        end
                        squareSize = iconSize + cfg.BuildFrame * 2
                    else
                        texture = CursorData.TextureForIndex(order.kind)
                        iconSize = cfg.IconSize
                        squareSize = cfg.MarkerSize
                    end
                    if mark.squareSize ~= squareSize then
                        mark.squareSize = squareSize
                        LayoutHelpers.SetDimensions(mark.square, squareSize, squareSize)
                    end
                    local half = squareSize * 0.5
                    mark.square.Left:SetValue(ax - half)
                    mark.square.Top:SetValue(ay - half)
                    self:ApplyUpgradeDiamond(mark, upgrade, ax, ay, squareSize)

                    if texture then
                        if not mark.icon then
                            mark.icon = Bitmap(self.orderRoot, texture)
                            mark.iconTexture = texture
                            mark.icon:DisableHitTest(true)
                            mark.icon.Left:SetValue(0)
                            mark.icon.Top:SetValue(0)
                            mark.alpha = -1
                        elseif mark.iconTexture ~= texture then
                            mark.icon:SetTexture(texture)
                            mark.iconTexture = texture
                        end
                        if mark.iconSize ~= iconSize then
                            mark.iconSize = iconSize
                            LayoutHelpers.SetDimensions(mark.icon, iconSize, iconSize)
                        end
                        if buildIcon then
                            mark.icon.Left:SetValue(ax - iconSize * 0.5)
                        else
                            mark.icon.Left:SetValue(ax + half + 2)
                        end
                        mark.icon.Top:SetValue(ay - iconSize * 0.5)
                        -- Above the frame, whichever was made first.
                        mark.icon.Depth:Set(mark.square.Depth() + 1)
                        mark.icon:SetHidden(false)
                        mark.iconShown = true
                    elseif mark.icon and mark.iconShown then
                        mark.icon:Hide()
                        mark.iconShown = false
                    end

                    if rowN >= 2 then
                        if not mark.row then
                            mark.row = CreateIconRow(self.orderRoot, self.uiColor)
                            mark.alpha = -1
                        end
                        SetIconRow(mark.row, buildIcon, self.rowSX, self.rowSY, 2, rowN - 1,
                            iconSize, cfg.BuildFrame)
                        mark.rowShown = true
                    elseif mark.row and mark.rowShown then
                        HideIconRow(mark.row)
                        mark.rowShown = false
                    end

                    -- A right-drag laid out a formation: show its extent. Kept
                    -- up until the order has reached the sim, and no longer:
                    -- from then on the game's own feedback shows it. A row of
                    -- structures keeps its line for as long as its marker.
                    local ex, ez = order.x2 - order.x, order.z2 - order.z
                    local lined = false
                    local lineDue = order.bp
                        or ((not order.applied or now < order.appliedT) and age <= cfg.PreviewMax)
                    if lineDue and ex * ex + ez * ez > 0 then
                        local p2 = self.projIn2
                        p2[1], p2[2], p2[3] = order.x2, order.y, order.z2
                        local proj2 = self.view:Project(p2)
                        if proj2 and proj2.x then
                            if not mark.line then
                                mark.line = CreateDotLine(self.orderRoot, self.uiColor,
                                    cfg.MaxLineDots, Config.Line.DotSize)
                                mark.alpha = -1
                            end
                            SetDotLine(mark.line, ax, ay,
                                viewInfo.left + proj2.x, viewInfo.top + proj2.y,
                                Config.Line.DotSpacing)
                            lined = true
                            mark.lineShown = true
                        end
                    end
                    if not lined and mark.line and mark.lineShown then
                        HideDotLine(mark.line)
                        mark.lineShown = false
                    end

                    -- A template: only its first structure is shown, with
                    -- TEMPLATE flashing above it to say there is more.
                    if order.template and buildIcon then
                        if not mark.tlabel then
                            mark.tlabel = UIUtil.CreateText(self.orderRoot, TEMPLATE_TEXT,
                                Config.Build.TemplateFontSize, UIUtil.bodyFont, true)
                            mark.tlabel:SetText(TEMPLATE_TEXT)
                            mark.tlabel:SetColor(self.uiColor)
                            mark.tlabel:DisableHitTest(true)
                            mark.tstroke = CreateTextStroke(self.orderRoot, mark.tlabel, TEMPLATE_TEXT,
                                Config.Build.TemplateFontSize)
                        end
                        local tl = mark.tlabel
                        tl.Left:SetValue(ax - tl.Width() * 0.5)
                        tl.Top:SetValue(ay - half - Config.Build.TemplateFontSize - 4)
                        local flash = alpha * TemplateFlash(age)
                        tl:SetAlpha(flash)
                        tl:SetHidden(false)
                        ShowStroke(mark.tstroke, flash)
                        mark.tlabelShown = true
                    elseif mark.tlabel and mark.tlabelShown then
                        mark.tlabel:Hide()
                        HideStroke(mark.tstroke)
                        mark.tlabelShown = false
                    end

                    if math.abs(alpha - mark.alpha) >= Config.Appearance.AlphaEpsilon then
                        mark.alpha = alpha
                        mark.square:SetAlpha(alpha)
                        if mark.diamond then mark.diamond:SetAlpha(alpha) end
                        if mark.icon then mark.icon:SetAlpha(alpha) end
                        if mark.line then SetDotLineAlpha(mark.line, alpha) end
                        if mark.row then SetIconRowAlpha(mark.row, alpha, alpha) end
                    end
                end
            end

            -- Off this view, or the view is hidden: nothing to show for it.
            if not mark and self.orderMarks[i] then
                self:HideOrderMark(self.orderMarks[i])
            end
        end

        -- Anything past the live orders is finished with.
        for i = count + 1, self.orderShown do
            local mark = self.orderMarks[i]
            if mark then
                self:HideOrderMark(mark)
            end
        end
        self.orderShown = count
    end,

    --- Push the ghost's opacity: the cursor's own, scaled by how far the fade
    --- has got. Separate from ApplyAlpha's other pieces because it changes on
    --- its own, every frame of a fade, with the cursor's alpha standing still.
    ---@param self RemoteCursor
    PushHudAlpha = function(self)
        if not self.hud then
            return
        end
        local a = self.curAlpha * self.hudFade
        if a ~= 0 and math.abs(a - self.appliedHudAlpha) < Config.Appearance.AlphaEpsilon then
            return
        end
        if a == self.appliedHudAlpha then
            return
        end
        self.appliedHudAlpha = a
        self.hud:ApplyAlpha(a)
    end,

    --- Switch between the map cursor and the HUD ghost.
    ---@param self RemoteCursor
    ---@param onHud boolean
    ---@param nx number
    ---@param ny number
    ---@param dt? number   # seconds since the last frame; without it the fade holds
    ApplyHud = function(self, onHud, nx, ny, dt)
        -- Switched off (it can be, mid-game, from ReUI): never on the
        -- interface, so a ghost already up fades out like any other time.
        if not Config.Hud.Enabled then
            onHud = false
        end

        if onHud and not self.hud then
            self.hud = HudGhost(self, self.record.faction)
            self.hudFade = 0
            self.appliedHudAlpha = -1
            self.hudBound = false
        end

        local hud = self.hud

        if hud then
            if onHud then
                -- Centred on the anchor, so it sits over the spot the player
                -- was last working on. Bound only while they are on the
                -- interface; see below for what happens on leaving.
                if not self.hudBound then
                    LayoutHelpers.AtLeftTopIn(hud, self,
                        math.floor(-hud.panelWidth * 0.5 + 0.5),
                        math.floor(-hud.panelHeight * 0.5 + 0.5))
                    self.hudBound = true
                end

                -- Which part of the interface they are pointing at. A far jump
                -- from where the image was (hovering the other side of the
                -- screen) starts the fade over, so it arrives already there
                -- instead of crossing the panel.
                if hud:SetPosition(nx, ny) then
                    self.hudFade = 0
                end
            end

            local target = onHud and 1 or 0
            if dt then
                local step = Config.Hud.FadeSpeed * dt
                if self.hudFade < target then
                    self.hudFade = math.min(target, self.hudFade + step)
                else
                    self.hudFade = math.max(target, self.hudFade - step)
                end
            end
            self:PushHudAlpha()

            local visible = onHud or self.hudFade > 0
            if visible ~= self.hudVisible then
                self.hudVisible = visible
                if visible then hud:Show() else hud:Hide() end
            end
        end

        if onHud == self.hudShown then
            return
        end
        self.hudShown = onHud

        if onHud then
            self:ApplyOrder(0)
            self.appliedOrder = -1
            if self.buildIcon and self.buildShown then
                self.buildIcon:Hide()
                self.buildFrame:Hide()
            end
        else
            -- They have left the interface, and the anchor is about to go back
            -- to where the pointer really is on the map. The ghost is on its
            -- way out; let it fade where it was rather than ride the anchor
            -- across the screen. (Bound again on the next visit.)
            if hud and self.hudBound then
                hud.Left:SetValue(self.Left() - hud.panelWidth * 0.5)
                hud.Top:SetValue(self.Top() - hud.panelHeight * 0.5)
                self.hudBound = false
            end

            if self.buildIcon and self.buildShown then
                self.buildIcon:Show()
                self.buildFrame:Show()
            end
        end
    end,

    --- Push an opacity to every piece. Skipped for changes below the epsilon.
    ---@param self RemoteCursor
    ---@param alpha number
    ---@param labelAlpha? number   # the name label's own; the cursor's if not given
    ApplyAlpha = function(self, alpha, labelAlpha)
        self.curAlpha = alpha
        self:PushHudAlpha()

        labelAlpha = labelAlpha or alpha
        if self.label and math.abs(labelAlpha - self.appliedLabelAlpha) >= Config.Appearance.AlphaEpsilon then
            self.appliedLabelAlpha = labelAlpha
            self.label:SetAlpha(labelAlpha)
            ShowStroke(self.nameStroke, labelAlpha)
        end

        if math.abs(alpha - self.appliedAlpha) < Config.Appearance.AlphaEpsilon then
            return
        end
        self.appliedAlpha = alpha

        self.mouseIcon:SetAlpha(alpha)
        if self.buildIcon then
            self.buildIcon:SetAlpha(alpha * Config.Build.GhostAlpha)
            self.buildFrame:SetAlpha(alpha * Config.Build.FrameAlpha)
        end
        if self.dragTop then
            self.dragTop:SetAlpha(alpha)
            self.dragBottom:SetAlpha(alpha)
            self.dragLeft:SetAlpha(alpha)
            self.dragRight:SetAlpha(alpha)
        end
        if self.line then
            SetDotLineAlpha(self.line, alpha * Config.Line.Alpha)
        end
        if self.row then
            SetIconRowAlpha(self.row, alpha * Config.Build.GhostAlpha, alpha * Config.Build.FrameAlpha)
        end
        if self.grabIcon then
            self.grabIcon:SetAlpha(alpha)
        end
    end,

    ---@param self RemoteCursor
    ---@param visible boolean
    SetVisible = function(self, visible)
        if visible == (not self.hidden) then return end
        self.hidden = not visible
        if visible then
            self:Show()
            self:ResyncChildren()
        else
            self:Hide()
        end
    end,

    ResyncChildren = function(self)
        local onHud = self.hudShown

        -- The arrow is drawn on the HUD ghost as well as on the map (ApplyHud
        -- deliberately leaves it up), so HUD state never hides it. This used
        -- to say SetHidden(onHud). With hudShown stale -- which it is whenever
        -- a cursor is culled straight after leaving the HUD -- that hid the
        -- arrow on re-entering the view, and ApplyHud, which no longer shows
        -- it again, left it hidden: the build ghost drew, the cursor did not.
        self.mouseIcon:SetHidden(false)

        if self.hud then self.hud:SetHidden(not self.hudVisible) end
        if self.buildIcon then
            local hide = onHud or not self.buildShown
            self.buildIcon:SetHidden(hide)
            self.buildFrame:SetHidden(hide)
        end
        if self.dragTop then
            local hide = onHud or not self.dragBoxShown
            self.dragTop:SetHidden(hide)
            self.dragBottom:SetHidden(hide)
            self.dragLeft:SetHidden(hide)
            self.dragRight:SetHidden(hide)
        end
        if self.line then
            ResyncDotLine(self.line, onHud or not self.lineShown)
        end
        if self.row then
            ResyncIconRow(self.row, onHud or not self.rowShown)
        end
        if self.templateLabel then
            self.templateLabel:SetHidden(onHud or not self.templateShown)
            ResyncStroke(self.templateStroke, onHud or not self.templateShown)
        end
        if self.actionLabel then
            self.actionLabel:SetHidden(not self.actionShown)
            ResyncStroke(self.actionStroke, not self.actionShown)
        end
        if self.nameBar then
            self.nameBar:SetHidden(not self.nameBarShown)
            if self.nameBarStroke then
                self.nameBarStroke:SetHidden(not self.nameBarShown)
            end
        end
        if self.grabIcon then
            self.grabIcon:SetHidden(onHud or not self.grabShown)
        end
    end,

    --------------------------------------------------------------------------
    -- Per-frame update, called by the driver in teammouse.lua
    --------------------------------------------------------------------------
    ---@param self RemoteCursor
    ---@param viewInfo table    # { left, top, right, bottom, zoom, mouseX, mouseY, hidden }
    ---@param now number
    UpdateFrame = function(self, viewInfo, now)
        local record = self.record

        -- Hidden from the panel: nothing of theirs at all.
        if record.disabled then
            self:HideEverything()
            return
        end

        -- Orders first, and unconditionally: they are pinned to the map, not to
        -- the cursor, and outlive it being culled or gone stale.
        -- Each decides for itself whether it is shown (Orders.Enabled,
        -- Draw.Enabled, ...): switched off mid-game, what is up goes away.
        self:ApplyOrders(viewInfo, now)
        self:ApplyViewport(viewInfo)
        self:ApplyClickPulses(now)
        self:ApplySelection(now, viewInfo)
        self:ApplyTrail(viewInfo, now)

        if viewInfo.hidden or not record.hasData then
            self:SetVisible(false)
            return
        end

        -- Stale peers fade out rather than hanging around forever.
        local age = now - record.lastUpdate
        if age > Config.Smoothing.StaleTimeout then
            self:SetVisible(false)
            return
        end

        local render = record.render
        local proj = self.view:Project(render)
        if not proj or not proj.x then
            self:SetVisible(false)
            return
        end

        local absX = viewInfo.left + proj.x
        local absY = viewInfo.top + proj.y

        -- While on the HUD the panel is centred on the anchor, so keep the
        -- anchor far enough inside the view that the panel stays readable.
        local onHudPanel = record.renderHud and Config.Hud.Enabled

        local dt = 0
        if self.lastNow then
            dt = now - self.lastNow
            if dt < 0 then dt = 0 end
            if dt > 0.1 then dt = 0.1 end
        end
        self.lastNow = now

        -- Bring the cached HUD flag up to date before the map-mode cull below
        -- can return early. Otherwise a teammate who leaves the HUD while
        -- outside this view keeps hudShown = true for as long as they stay
        -- culled, and everything that trusts it (ResyncChildren) is working
        -- from a state that ended some time ago.
        if not onHudPanel and self.hudShown then
            self:ApplyHud(false)
        end

        if onHudPanel then
            local halfW = Config.Hud.Width * 0.5 + Config.Hud.EdgePadding
            local halfH = Config.Hud.Width * Config.Hud.AspectRatio * 0.5 + Config.Hud.EdgePadding

            -- If the view is narrower or shorter than the panel the two clamps
            -- would fight and push it off the edge, so just centre it.
            if (viewInfo.right - viewInfo.left) < halfW * 2 then
                absX = (viewInfo.left + viewInfo.right) * 0.5
            else
                if absX < viewInfo.left + halfW then absX = viewInfo.left + halfW end
                if absX > viewInfo.right - halfW then absX = viewInfo.right - halfW end
            end

            if (viewInfo.bottom - viewInfo.top) < halfH * 2 then
                absY = (viewInfo.top + viewInfo.bottom) * 0.5
            else
                if absY < viewInfo.top + halfH then absY = viewInfo.top + halfH end
                if absY > viewInfo.bottom - halfH then absY = viewInfo.bottom - halfH end
            end
        else
            -- Cull to this view's bounds. Without this, cursors from the left
            -- view bleed across the divider into the right view in splitscreen.
            local m = Config.Appearance.CullMargin
            if absX < viewInfo.left - m or absX > viewInfo.right + m
                or absY < viewInfo.top - m or absY > viewInfo.bottom + m then
                -- During a drag the anchor is where it began, which can be off
                -- this view while the rest of it -- and the arrow, at its live
                -- end -- is on it. Cull only if all of it is off.
                if not self:DragReachesView(viewInfo, absX, absY, m) then
                    self:SetVisible(false)
                    return
                end
            end
        end

        self:SetVisible(true)

        self.Left:SetValue(absX)
        self.Top:SetValue(absY)

        -- Mode and decoration. When the HUD panel is switched off entirely we
        -- keep drawing the normal cursor rather than freezing it half-updated,
        -- so disabling the feature falls back to plain behaviour.
        self:ApplyHud(onHudPanel, record.hudRender[1], record.hudRender[2], dt)

        if not onHudPanel then
            self:ApplyOrder(record.orderIndex)

            ------------------------------------------------------------------
            -- Scale
            ------------------------------------------------------------------
            -- Deliberately ahead of the drag-box/follow block below: ApplyScale
            -- rebinds mouseIcon's position via AtLeftTopIn whenever the
            -- quantised scale actually changes. Running it after the follow
            -- override used to let it silently undo that override on any
            -- frame the two coincided; running it first means the follow
            -- override -- which always runs last for this cursor, every frame
            -- -- is the one thing that gets the final say on mouseIcon's
            -- position.
            local scale = 1.0
            if Config.Zoom.Enabled and viewInfo.zoom and viewInfo.zoom > 0
                and record.zoom and record.zoom > 0 then
                -- A teammate zoomed further out than you is working over a
                -- wider area than your view shows, so their cursor draws
                -- larger.
                local ratio = record.zoom / viewInfo.zoom
                scale = math.pow(ratio, Config.Zoom.Exponent)
                -- Zoomed far out yourself, a teammate working close in would
                -- otherwise shrink to a speck: the floor rises to FarMinScale.
                local minScale = Config.Zoom.MinScale
                local far = FarFactor(viewInfo)
                if far > 0 and Config.Zoom.FarMinScale > minScale then
                    minScale = minScale + (Config.Zoom.FarMinScale - minScale) * far
                end
                if scale < minScale then scale = minScale end
                if scale > Config.Zoom.MaxScale then scale = Config.Zoom.MaxScale end
            end

            if viewInfo.replay then
                scale = scale * Config.ReplayCodec.CursorScale
            end
            scale = scale * (Config.Appearance.SizeScale or 1)

            -- Quantise so a smooth zoom doesn't re-layout on every frame.
            local q = Config.Appearance.ScaleQuantum
            scale = math.floor(scale / q + 0.5) * q
            self:ApplyScale(scale, false)

            -- A build drag shows its row, one icon per structure, instead of
            -- the single ghost beside the cursor.
            -- A template is several kinds of structure in its own layout, not
            -- a row: it keeps the single ghost (its first structure), marked.
            local rowBp = Config.Line.ShowStructures and Config.Line.Enabled
                and record.renderDrag == 2 and not record.buildTemplate and record.buildId
            self:ApplyBuild(not rowBp and record.buildId)
            self:ApplyTemplateLabel(record.buildTemplate and self.buildShown)

            -- A drag in progress on their end, as of the moment being drawn
            -- (record.renderDrag, not their last packet: see CreateRecord).
            -- Every kind runs from the anchor to the live end; DragShape says
            -- what, if anything, to draw between them.
            local shape = DragShape(record.renderDrag)
            local boxProj = nil
            if shape then
                local pb = self.projBox
                pb[1], pb[2], pb[3] = record.boxRender[1], render[2], record.boxRender[2]
                boxProj = self.view:Project(pb)
            end
            if boxProj and boxProj.x then
                local dx = (viewInfo.left + boxProj.x) - absX
                local dy = (viewInfo.top + boxProj.y) - absY

                -- An order being dragged to a new spot: its icon in the
                -- hand, and a line back to where it was.
                local grabbing = shape == 'follow' and record.grabKind > 0 and Config.Orders.ShowGrabs

                -- A box of a few pixels is a click with a little jitter.
                local min = Config.Selection.MinBoxSize
                self:ApplyDragBox(shape == 'box' and (math.abs(dx) >= min or math.abs(dy) >= min), dx, dy)
                self:ApplyDragLine(shape == 'line' or grabbing, dx, dy)
                self:ApplyLineStructures(shape == 'line' and rowBp, viewInfo)
                self:ApplyGrabIcon(grabbing and record.grabKind, dx, dy)

                -- The arrow rides the live end rather than the anchor (this
                -- cursor's own position). Last, after ApplyScale above, so
                -- nothing else in this function can move it back.
                self.followingDragBox = true
                local hx = math.floor(self.hotspotX * self.appliedScale + 0.5)
                local hy = math.floor(self.hotspotY * self.appliedScale + 0.5)
                self.mouseIcon.Left:SetValue(self.Left() + dx - hx)
                self.mouseIcon.Top:SetValue(self.Top() + dy - hy)
            else
                self:ClearDrag()
            end
        else
            self:ClearDrag()
        end

        ------------------------------------------------------------------
        -- Opacity
        ------------------------------------------------------------------
        -- The cursor's own opacity, before anything fades it.
        local alpha = Config.Appearance.BaseAlpha
        if viewInfo.replay then
            alpha = Config.ReplayCodec.CursorAlpha
        end

        -- Zoomed far out, cursors are what you are looking for: they get
        -- more opaque towards FarAlpha rather than fading away.
        local far = FarFactor(viewInfo)
        if far > 0 and Config.Zoom.FarAlpha > alpha then
            alpha = alpha + (Config.Zoom.FarAlpha - alpha) * far
        end

        -- The name is never fainter than the cursor it names.
        local labelAlpha = Config.Appearance.LabelAlpha
        if labelAlpha < alpha then labelAlpha = alpha end

        -- What fades both alike: fading in on arrival, fading out when
        -- stale, and your own mouse coming near (so a teammate's cursor --
        -- name and all -- never sits on top of what you are trying to click).
        local shared = record.fade

        -- In a replay nothing is being clicked, so only a gentle fade, and
        -- only right over the cursor (ReplayCodec.HoverRadius / HoverMinAlpha).
        if Config.Proximity.Enabled and viewInfo.mouseX then
            local dx = viewInfo.mouseX - absX
            local dy = viewInfo.mouseY - absY
            local dist = math.sqrt(dx * dx + dy * dy)
            local r, minAlpha = Config.Proximity.FadeRadius, Config.Proximity.MinAlpha
            if viewInfo.replay then
                r, minAlpha = Config.ReplayCodec.HoverRadius, Config.ReplayCodec.HoverMinAlpha
            end
            if dist < r then
                local t = dist / r
                shared = shared * (minAlpha + t * (1 - minAlpha))
            end
        end

        -- Stale peers fade out over the last second before the timeout.
        local fadeWindow = 1.0
        if age > Config.Smoothing.StaleTimeout - fadeWindow then
            local t = (Config.Smoothing.StaleTimeout - age) / fadeWindow
            if t < 0 then t = 0 end
            shared = shared * t
        end

        alpha = alpha * shared
        self:ApplyAlpha(alpha, labelAlpha * shared)
        self:ApplyNameBar(viewInfo, labelAlpha * shared)
        self:ApplyAction(now, alpha)
    end,

    --- The label for their last action (Stop, repeat build, pause), above the
    --- arrow's tip, while it lasts: solid, then fading out.
    ---@param self RemoteCursor
    ---@param now number
    ---@param alpha number   # the cursor's own opacity
    ApplyAction = function(self, now, alpha)
        local record = self.record
        local cfg = Config.Actions
        local age = now - record.actT
        local showing = cfg.Enabled and record.actCode > 0 and age >= 0 and age < cfg.Lifetime
            and self.mouseIcon and not self.hudShown

        if not showing then
            if self.actionLabel and self.actionShown then
                self.actionLabel:Hide()
                HideStroke(self.actionStroke)
                self.actionShown = false
            end
            return
        end

        if not self.actionLabel then
            self.actionLabel = UIUtil.CreateText(self, '', cfg.FontSize, "Arial Bold", true)
            self.actionLabel:SetColor(self.uiColor)
            self.actionLabel:DisableHitTest(true)
            self.actionStroke = CreateTextStroke(self, self.actionLabel, '', cfg.FontSize, "Arial Bold")
            self.actionCode = false
        end
        local label = self.actionLabel
        if self.actionCode ~= record.actCode then
            self.actionCode = record.actCode
            label:SetText(Actions.Labels[record.actCode] or '')
            SetStrokeText(self.actionStroke, Actions.Labels[record.actCode] or '')
        end

        -- Every frame: the arrow moves, on its own when following a drag.
        label.Left:SetValue(self.mouseIcon.Left() + 4)
        label.Top:SetValue(self.mouseIcon.Top() - cfg.OffsetY)

        local fade = 1
        if age > cfg.FadeHold then
            fade = 1 - (age - cfg.FadeHold) / (cfg.Lifetime - cfg.FadeHold)
        end
        label:SetAlpha(alpha * fade)
        label:SetHidden(false)
        ShowStroke(self.actionStroke, alpha * fade)
        self.actionShown = true
    end,

    --- The bar under the name: how far in THEY are zoomed, at a glance. As
    --- wide as the name when they are zoomed all the way in, shrinking to
    --- NameBarMinWidth all the way out -- on a log scale, so it moves as much
    --- close in as far out -- always centred under the name. The
    --- range is your own camera's (the same map, so the same limits), or
    --- NameBarZoomIn/Out if that cannot be read. It fades with the name.
    ---@param self RemoteCursor
    ---@param viewInfo table
    ---@param alpha number   # the name's
    ApplyNameBar = function(self, viewInfo, alpha)
        local bar = self.nameBar
        if not bar then
            return
        end
        local record = self.record
        local showing = self.label and not self.label:IsHidden() and record.zoom and record.zoom > 0
        local stroke = self.nameBarStroke
        if not showing then
            if self.nameBarShown then
                bar:SetHidden(true)
                if stroke then stroke:SetHidden(true) end
                self.nameBarShown = false
            end
            return
        end
        local cfg = Config.Appearance
        local zIn, zOut = viewInfo.minZoom, viewInfo.maxZoom
        if not zIn then
            zIn, zOut = cfg.NameBarZoomIn, cfg.NameBarZoomOut
        end
        -- On a log scale: zooming feels proportional (each step in looks as
        -- big as the last), and a straight line put most of the change at the
        -- far end -- close in, the bar hardly moved.
        -- (Worked out again only when their zoom or our range changes: three
        -- logarithms per cursor per view, every frame, otherwise.)
        local f = self.nameBarF
        if record.zoom ~= self.nameBarZ or zIn ~= self.nameBarIn or zOut ~= self.nameBarOut then
            f = 1
            if zOut > zIn and zIn > 0 then
                local z = record.zoom
                if z < zIn then z = zIn end
                if z > zOut then z = zOut end
                f = (math.log(zOut) - math.log(z)) / (math.log(zOut) - math.log(zIn))
            end
            self.nameBarF, self.nameBarZ, self.nameBarIn, self.nameBarOut = f, record.zoom, zIn, zOut
        end
        local full = self.label.Width()
        local least = cfg.NameBarMinWidth
        if least > full then least = full end
        local width = math.floor(least + (full - least) * f + 0.5)
        if width ~= self.nameBarWidth then
            self.nameBarWidth = width
            bar.Width:SetValue(width)
        end
        if math.abs(alpha - self.nameBarAlpha) >= cfg.AlphaEpsilon then
            self.nameBarAlpha = alpha
            bar:SetAlpha(alpha)
            if stroke then stroke:SetAlpha(alpha * cfg.TextStrokeAlpha) end
        end
        if not self.nameBarShown then
            bar:SetHidden(false)
            if stroke then stroke:SetHidden(false) end
            self.nameBarShown = true
        end
    end,

    --- Rings pulsing out from where they clicked: growing to ClickPulse.Radius
    --- pixels (converted to world units at each spot, so they are the same
    --- size at any zoom) and fading as they go.
    ---@param self RemoteCursor
    ---@param now number
    ApplyClickPulses = function(self, now)
        local cfg = Config.ClickPulse
        local record = self.record
        local shape = self.pulseShape
        local n = 0
        if cfg.Enabled and record.hasData and not record.disabled then
            local p = self.projIn2
            for i = 1, 6 do
                local pulse = record.pulses[i]
                local age = pulse and (now - pulse.t)
                if age and age >= 0 and age < cfg.Duration then
                    -- Pixels to world units here: how far one world unit
                    -- across is on screen.
                    p[1], p[2], p[3] = pulse.x, pulse.y, pulse.z
                    local a = self.view:Project(p)
                    p[1] = pulse.x + 1
                    local b = self.view:Project(p)
                    local perUnit = a and b and a.x and b.x and math.abs(b.x - a.x) or 0
                    if perUnit > 0.001 then
                        if not shape then
                            shape = self:MakeShape('pulseShape', 'TeamMouseClick', NewPulseShape)
                            if not shape then return end
                        end
                        n = n + 1
                        local ring = shape.rings[n]
                        local t = age / cfg.Duration
                        ring.pos[1], ring.pos[2], ring.pos[3] = pulse.x, pulse.y, pulse.z
                        ring.r = (cfg.Radius * t) / perUnit
                        ring.thick = cfg.Thickness / perUnit   -- world units, as it takes them
                        ring.color = WithAlpha(self.uiColor, 1 - t)
                    end
                end
            end
        end
        if shape then
            shape.n = n
            shape.Hidden = n == 0
        end
    end,

    --- A light blue box on each unit they have selected, very faint, centred
    --- on it, its line TeamSelection.Thickness pixels wide: as big as the unit
    --- (the size they sent: skirt, footprint or body), but never smaller on
    --- screen than a strategic icon, so zoomed out the boxes stay icon sized.
    --- An observer, or a replay, looks each unit up by id and tracks it. A
    --- player in a live game cannot (an engine rule): the boxes go where the
    --- units were when selected, and fade like any other marker.
    ---@param self RemoteCursor
    ---@param now number
    ---@param viewInfo table
    ApplySelection = function(self, now, viewInfo)
        local cfg = Config.TeamSelection
        local record = self.record
        local shape = self.selShape
        local ids = record.sel
        if not (cfg.Enabled and record.hasData and not record.disabled and table.getn(ids) > 0) then
            if shape then shape.Hidden = true end
            if self.rectShape then self.rectShape.Hidden = true end
            return
        end
        -- Too many selected for a box each: rectangles round the bunches.
        if table.getn(record.selRects) > 0 then
            if shape then shape.Hidden = true end
            self:ApplySelectionRects(now)
            return
        elseif self.rectShape then
            self.rectShape.Hidden = true
        end
        -- Looked up again when the list changes, and those not found once a
        -- second (a unit can come into view).
        local units = self.selUnits
        local fresh = self.selVersion ~= record.selVersion
        -- Only an observer (or a replay) can look a player's units up by id;
        -- a player in a live game cannot, and goes by the positions sent.
        local canLook = viewInfo.replay or viewInfo.observer

        -- Live, the boxes are where the units were when selected, so they fade
        -- like any other marker: solid for Orders.FadeHold, gone by Lifetime.
        local fade = 1
        if not canLook then
            local orders = Config.Orders
            local age = now - record.selT
            if age >= orders.Lifetime then
                if shape then shape.Hidden = true end
                return
            end
            if age > orders.FadeHold then
                fade = 1 - (age - orders.FadeHold) / (orders.Lifetime - orders.FadeHold)
            end
        end

        if fresh and not canLook then
            self.selVersion = record.selVersion
            for i = table.getn(units), 1, -1 do units[i] = nil end
        elseif canLook and (fresh or (self.selMissing > 0 and now - self.selLookT >= 1)) then
            self.selVersion = record.selVersion
            self.selLookT = now
            local missing = 0
            for i, id in ipairs(ids) do
                if fresh or not units[i] then
                    local ok, unit = pcall(GetUnitById, id)
                    units[i] = ok and unit or false
                end
                if not units[i] then missing = missing + 1 end
            end
            for i = table.getn(ids) + 1, table.getn(units) do units[i] = nil end
            self.selMissing = missing
            if fresh and Config.Debug then
                LOG('TeamMouse: ' .. tostring(record.name) .. ' selected ' .. table.getn(ids) .. ' units: '
                    .. (table.getn(ids) - missing) .. ' found by id, the rest placed where they said')
            end
        end
        if not shape then
            shape = self:MakeShape('selShape', 'TeamMouseSelection', NewSelectionShape)
            if not shape then return end
        end

        local perUnit = 0
        local n = 0
        local p = self.projIn2
        for i = 1, table.getn(ids) do
            local x, y, z
            local unit = units[i]
            if unit then
                local ok, pos = pcall(unit.GetPosition, unit)
                local okDead, dead = pcall(unit.IsDead, unit)
                if ok and type(pos) == 'table' and not (okDead and dead) then
                    x, y, z = pos[1], pos[2], pos[3]
                end
            elseif not canLook then
                -- Live: where it was when they selected it.
                local sent = record.selPos[i]
                if sent and sent.ok then
                    x, y, z = sent[1], sent[2], sent[3]
                end
            end
            if x then
                -- Pixels to world units, where the first of them is (the view
                -- is near enough top-down that it holds across the screen).
                if n == 0 then
                    p[1], p[2], p[3] = x, y, z
                    local a = self.view:Project(p)
                    p[1] = x + 1
                    local b = self.view:Project(p)
                    perUnit = a and b and a.x and b.x and math.abs(b.x - a.x) or 0
                    if perUnit <= 0.001 then
                        break
                    end
                end
                local size = (record.selSize[i] or 1) + cfg.Margin
                local least = cfg.IconSize / perUnit
                if size < least then size = least end
                -- Units bunched up (zoomed out, their boxes are icon sized and
                -- pile on each other, the faint lines adding up to a solid
                -- block): one box where another is nearly the same.
                local shift = cfg.RectAnchoredAtCorner and size * 0.5 or 0
                local dup = false
                for k = 1, n do
                    local other, otherSize = shape.boxes[k], shape.sizes[k]
                    local otherShift = cfg.RectAnchoredAtCorner and otherSize * 0.5 or 0
                    local dx = (other[1] + otherShift) - x
                    local dz = (other[3] + otherShift) - z
                    local near = cfg.MergeWithin * math.max(size, otherSize)
                    if dx * dx + dz * dz < near * near then
                        dup = true
                        break
                    end
                end
                if not dup then
                    n = n + 1
                    local box = shape.boxes[n]
                    if not box then
                        box = { 0, 0, 0 }
                        shape.boxes[n] = box
                    end
                    box[1], box[2], box[3] = x - shift, y, z - shift
                    shape.sizes[n] = size
                end
            end
        end
        shape.color = WithAlpha(cfg.Color, BaseAlpha(cfg.Color) * fade)
        shape.thick = perUnit > 0.001 and cfg.Thickness / perUnit or 0
        shape.n = n
        shape.Hidden = n == 0
    end,

    --- Rectangles round bunches of a teammate's selection, when they selected
    --- more than they send ids for. Where the units were when selected, so
    --- they fade like any other marker, for everyone (observers too).
    ---@param self RemoteCursor
    ---@param now number
    ApplySelectionRects = function(self, now)
        local cfg = Config.TeamSelection
        local orders = Config.Orders
        local record = self.record
        local shape = self.rectShape
        local age = now - record.selT
        if age >= orders.Lifetime then
            if shape then shape.Hidden = true end
            return
        end
        local fade = 1
        if age > orders.FadeHold then
            fade = 1 - (age - orders.FadeHold) / (orders.Lifetime - orders.FadeHold)
        end
        if not shape then
            shape = self:MakeShape('rectShape', 'TeamMouseSelectionRects', NewRectShape)
            if not shape then return end
        end

        -- Pixels to world units, at the first of them.
        local first = record.selRects[1]
        local p = self.projIn2
        p[1], p[2], p[3] = first[1], first[5], first[2]
        local pa = self.view:Project(p)
        p[1] = first[1] + 1
        local pb = self.view:Project(p)
        local perUnit = pa and pb and pa.x and pb.x and math.abs(pb.x - pa.x) or 0
        if perUnit <= 0.001 then
            shape.Hidden = true
            return
        end

        local n = 0
        for _, r in ipairs(record.selRects) do
            local x1, z1, x2, z2, y = r[1], r[2], r[3], r[4], r[5]
            -- Round the rectangle, each edge from one corner to the next.
            -- (No corner tables: this runs every frame.)
            n = PutRectEdge(shape, n, x1, z1, x2, z1, y)
            n = PutRectEdge(shape, n, x2, z1, x2, z2, y)
            n = PutRectEdge(shape, n, x2, z2, x1, z2, y)
            n = PutRectEdge(shape, n, x1, z2, x1, z1, y)
        end
        shape.color = WithAlpha(cfg.Color, BaseAlpha(cfg.Color) * fade)
        shape.thick = cfg.Thickness / perUnit
        shape.n = n
        shape.Hidden = n == 0
    end,

    --- Add a shape to our view, once (see "Teammates' views, drawn in the
    --- world"), as self[field]. False if the view cannot take shapes.
    ---@param self RemoteCursor
    ---@param field string
    ---@param prefix string
    ---@param make function
    ---@return table | false
    MakeShape = function(self, field, prefix, make)
        local view = self.view
        if not view.AddShape then
            if not shapesMissingLogged then
                shapesMissingLogged = true
                LOG('TeamMouse: this game\'s world views cannot draw shapes; no outlines or pulses')
            end
            return false
        end
        local shape = make()
        local id = prefix .. tostring(self.record.army)
        if not pcall(view.AddShape, view, shape, id) then
            return false
        end
        self[field] = shape
        self.shapeIds = self.shapeIds or {}
        self.shapeIds[id] = true
        return shape
    end,

    --- Their view's outline, when their "view" box is ticked in the panel:
    --- four lines in their colour. Zooming in (Viewport.Near*), they thicken
    --- and fade a little.
    ---@param self RemoteCursor
    ---@param viewInfo table
    ApplyViewport = function(self, viewInfo)
        local record = self.record
        local cfg = Config.Viewport
        local vp = record.vp
        local shape = self.viewShape
        if not (record.showView and vp and record.hasData) then
            if shape then
                shape.Hidden = true
            end
            return
        end

        if not shape then
            shape = self:MakeShape('viewShape', 'TeamMouseView', NewViewShape)
            if not shape then
                return
            end
            self.vpDrawn = nil
        end

        -- How far in you are: 0 until NearStart of the way in, 1 from NearEnd.
        local near = 0
        local zIn, zOut = viewInfo.minZoom, viewInfo.maxZoom
        if not zIn then
            zIn, zOut = Config.Appearance.NameBarZoomIn, Config.Appearance.NameBarZoomOut
        end
        if viewInfo.zoom and zOut > zIn and cfg.NearEnd > cfg.NearStart then
            local f = (zOut - viewInfo.zoom) / (zOut - zIn)
            near = (f - cfg.NearStart) / (cfg.NearEnd - cfg.NearStart)
            if near < 0 then near = 0 end
            if near > 1 then near = 1 end
        end
        shape.color = WithAlpha(self.uiColor, 1 + (cfg.NearAlpha - 1) * near)
        shape.thick = cfg.Thickness + (cfg.NearThickness - cfg.Thickness) * near

        -- The corners only change when a new outline arrives (vpVersion, bumped
        -- by ProcessMessage): no copying them every frame in between.
        local version = record.vpVersion or 0
        if self.vpDrawn ~= version then
            self.vpDrawn = version
            for i = 1, 4 do
                local j = math.mod(i, 4) + 1
                local a, b = shape.a[i], shape.b[i]
                a[1], a[2], a[3] = vp[i * 3 - 2], vp[i * 3 - 1], vp[i * 3]
                b[1], b[2], b[3] = vp[j * 3 - 2], vp[j * 3 - 1], vp[j * 3]
            end
        end
        shape.Hidden = false
    end,

    --- TEMPLATE above the build ghost while the build in hand is a template.
    ---@param self RemoteCursor
    ---@param showing boolean
    ApplyTemplateLabel = function(self, showing)
        if not showing then
            if self.templateLabel and self.templateShown then
                self.templateLabel:Hide()
                HideStroke(self.templateStroke)
                self.templateShown = false
            end
            return
        end
        if not self.templateLabel then
            self.templateLabel = UIUtil.CreateText(self, TEMPLATE_TEXT, Config.Build.TemplateFontSize,
                UIUtil.bodyFont, true)
            self.templateLabel:SetText(TEMPLATE_TEXT)
            self.templateLabel:SetColor(self.uiColor)
            self.templateLabel:DisableHitTest(true)
            self.templateStroke = CreateTextStroke(self, self.templateLabel, TEMPLATE_TEXT,
                Config.Build.TemplateFontSize)
        end
        local label = self.templateLabel
        label.Left:SetValue(self.buildFrame.Left())
        label.Top:SetValue(self.buildFrame.Top() - Config.Build.TemplateFontSize - 3)
        label:SetAlpha(self.curAlpha or 1)
        label:SetHidden(false)
        ShowStroke(self.templateStroke, self.curAlpha or 1)
        self.templateShown = true
    end,

    ---@param self RemoteCursor
    OnDestroy = function(self)
        -- Not one of our children, so it will not go with us. If the view was
        -- destroyed first it is gone already; either way is fine.
        if self.orderRoot then
            pcall(function() self.orderRoot:Destroy() end)
            self.orderRoot = false
        end
        -- Outlines and pulses are the view's, not ours: take them back.
        if self.shapeIds and self.view and self.view.RemoveShape then
            for id in pairs(self.shapeIds) do
                pcall(self.view.RemoveShape, self.view, id)
            end
        end
        self.shapeIds = false
        self.viewShape = false
        self.pulseShape = false
        self.orderMarks = {}
        self.record = nil
        self.view = nil
        self.hud = false
        if Group.OnDestroy then
            Group.OnDestroy(self)
        end
    end,
}
