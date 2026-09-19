--******************************************************************************
--** TeamMouse -- modules/hudghost.lua
--**
--** A small stylised panel shown in place of a teammate's cursor while their
--** mouse is on their own interface rather than the map.
--**
--** This is an impression of a HUD, not a picture of one. We have no access to
--** another client's framebuffer and shipping one over the wire would be
--** ridiculous, so instead we draw a recognisable silhouette of the Supreme
--** Commander interface and put a dot where their cursor is, normalised to
--** their screen. That is enough to read "they're clicking buttons, not
--** looking at the map", which is the whole point.
--**
--** Config.Hud.Detail switches between:
--**   'simple' -- outline, resource strip, command band, minimap, cursor dot
--**   'full'   -- adds build grid, order row, score panel and side rails
--******************************************************************************

local Config = import(_G.TeamMousePath .. '/modules/config.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Group = import('/lua/maui/group.lua').Group

--- Creates a solid coloured rectangle laid out in fractional coordinates of
--- the parent panel, so the silhouette scales with Config.Hud.Width.
---@param parent Control
---@param color string
---@param fx number   # left, 0..1 of panel width
---@param fy number   # top, 0..1 of panel height
---@param fw number   # width, 0..1 of panel width
---@param fh number   # height, 0..1 of panel height
---@param panelW number
---@param panelH number
---@return Bitmap
local function Rect(parent, color, fx, fy, fw, fh, panelW, panelH)
    local bmp = Bitmap(parent)
    bmp:SetSolidColor(color)
    LayoutHelpers.SetDimensions(bmp,
        math.max(1, math.floor(fw * panelW + 0.5)),
        math.max(1, math.floor(fh * panelH + 0.5)))
    LayoutHelpers.AtLeftTopIn(bmp, parent,
        math.floor(fx * panelW + 0.5),
        math.floor(fy * panelH + 0.5))
    bmp:DisableHitTest(true)
    return bmp
end

---@class HudGhost : Group
HudGhost = Class(Group) {

    ---@param self HudGhost
    ---@param parent Control
    ---@param playerColor string
    __init = function(self, parent, playerColor)
        Group.__init(self, parent, 'TeamMouseHudGhost')

        local hud = Config.Hud
        local w = hud.Width
        local h = math.floor(w * hud.AspectRatio + 0.5)

        self.panelWidth = w
        self.panelHeight = h
        self.parts = {}

        LayoutHelpers.SetDimensions(self, w, h)
        self:DisableHitTest(true)

        -- Screen body.
        self.back = Bitmap(self)
        self.back:SetSolidColor(hud.BackColor)
        LayoutHelpers.FillParent(self.back, self)
        self.back:DisableHitTest(true)
        table.insert(self.parts, self.back)

        self:BuildEdges(hud.EdgeColor, w, h)
        self:BuildChrome(hud, w, h)

        -- The cursor dot, in the player's own colour so teammates stay
        -- distinguishable even when they're all sat in their interfaces.
        self.dot = Bitmap(self)
        self.dot:SetSolidColor(playerColor or 'ffffffff')
        LayoutHelpers.SetDimensions(self.dot, hud.DotSize, hud.DotSize)
        LayoutHelpers.AtLeftTopIn(self.dot, self, 0, 0)
        self.dot:DisableHitTest(true)
        self.dot.Depth:Set(function() return self.Depth() + 10 end)
        table.insert(self.parts, self.dot)

        self.dotX = -1
        self.dotY = -1
        self:SetPosition(0.5, 0.9)

        self:Hide()
    end,

    --- Thin outline so the panel reads as a screen rather than a blob.
    ---@param self HudGhost
    BuildEdges = function(self, color, w, h)
        local t = 1 / h
        local tw = 1 / w
        table.insert(self.parts, Rect(self, color, 0, 0, 1, t, w, h))
        table.insert(self.parts, Rect(self, color, 0, 1 - t, 1, t, w, h))
        table.insert(self.parts, Rect(self, color, 0, 0, tw, 1, w, h))
        table.insert(self.parts, Rect(self, color, 1 - tw, 0, tw, 1, w, h))
    end,

    --- The fake HUD visual
    ---@param self HudGhost
    BuildChrome = function(self, hud, w, h)
        local panel = hud.PanelColor
        local parts = self.parts

        -- Resource bars along the top left.
        table.insert(parts, Rect(self, panel, 0.03, 0.05, 0.34, 0.075, w, h))

        -- Main command band across the bottom.
        table.insert(parts, Rect(self, panel, 0.00, 0.76, 1.00, 0.24, w, h))

        -- Minimap, bottom left.
        table.insert(parts, Rect(self, hud.EdgeColor, 0.025, 0.795, 0.165, 0.175, w, h))

        if hud.Detail ~= 'full' then
            return
        end

        -- Everything below is the 'full' silhouette.

        -- Build grid, centre of the command band.
        local gx, gy = 0.40, 0.815
        local cw, ch = 0.043, 0.055
        local gapX, gapY = 0.010, 0.017
        for row = 0, 1 do
            for col = 0, 4 do
                table.insert(parts, Rect(self, hud.EdgeColor,
                    gx + col * (cw + gapX),
                    gy + row * (ch + gapY),
                    cw, ch, w, h))
            end
        end

        -- Order button row, left of the build grid.
        for col = 0, 2 do
            table.insert(parts, Rect(self, hud.EdgeColor,
                0.215 + col * 0.050, 0.815, 0.040, 0.055, w, h))
        end

        -- Selection / unit info block, right of the build grid.
        table.insert(parts, Rect(self, hud.EdgeColor, 0.735, 0.805, 0.135, 0.155, w, h))

        -- Score and avatars, top right.
        table.insert(parts, Rect(self, panel, 0.74, 0.04, 0.22, 0.10, w, h))

        -- Side rail, right edge.
        table.insert(parts, Rect(self, panel, 0.955, 0.20, 0.035, 0.42, w, h))
    end,

    --- Move the dot. Coordinates are 0..1 across the sender's own screen.
    ---@param self HudGhost
    ---@param nx number
    ---@param ny number
    SetPosition = function(self, nx, ny)
        if not nx or not ny then
            return
        end

        -- Quantise to whole pixels; sub-pixel updates would re-layout every
        -- frame for no visible gain.
        local px = math.floor(nx * (self.panelWidth - Config.Hud.DotSize) + 0.5)
        local py = math.floor(ny * (self.panelHeight - Config.Hud.DotSize) + 0.5)

        if px < 0 then px = 0 end
        if py < 0 then py = 0 end

        if px == self.dotX and py == self.dotY then
            return
        end

        self.dotX = px
        self.dotY = py
        LayoutHelpers.AtLeftTopIn(self.dot, self, px, py)
    end,

    ---@param self HudGhost
    ---@param alpha number
    ApplyAlpha = function(self, alpha)
        local a = alpha * Config.Hud.Alpha
        for _, part in ipairs(self.parts) do
            part:SetAlpha(a)
        end
    end,
}
