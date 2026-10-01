--******************************************************************************
--** TeamMouse -- modules/hudghost.lua
--**
--** Shown in place of a teammate's cursor while their pointer is on their own
--** interface rather than the map: a picture of the Forged Alliance interface,
--** positioned so that the spot they are pointing at is at its centre. That is
--** enough to read "they're clicking buttons, not looking at the map".
--**
--** The panel is a window of Config.Hud.Width; `self.hud` is the interface
--** image inside it, the same size, and SetPosition slides the image under the
--** window.
--******************************************************************************

local Config = import(_G.TeamMousePath .. '/modules/config.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Group = import('/lua/maui/group.lua').Group

---@class HudGhost : Group
HudGhost = Class(Group) {

    ---@param self HudGhost
    ---@param parent Control
    __init = function(self, parent)
        Group.__init(self, parent, 'TeamMouseHudGhost')

        local w = Config.Hud.Width
        local h = math.floor(w * Config.Hud.AspectRatio + 0.5)
        self.panelWidth = w
        self.panelHeight = h

        LayoutHelpers.SetDimensions(self, w, h)
        self:DisableHitTest(true)

        self.hud = Bitmap(self)
        self.hud:SetTexture("/mods/TeamMouse/textures/UICutout.png")
        LayoutHelpers.SetDimensions(self.hud, w, h)
        LayoutHelpers.AtLeftTopIn(self.hud, self, 0, 0)
        self.hud:DisableHitTest(true)
        self.hud.Depth:Set(function() return self.Depth() + 10 end)

        self.hudX = -1
        self.hudY = -1
        self.lastNX = 0.5
        self.lastNY = 0.9
        self:SetPosition(0.5, 0.9)

        self:Hide()
    end,

    --- Slide the image so that the point they are at is at the panel's centre.
    --- Coordinates are 0..1 across the sender's own screen.
    ---
    --- Returns true when this is a jump rather than a movement -- further from
    --- the last position than Config.Hud.JumpDistance -- so the caller can fade
    --- the ghost in again at the new spot. Nothing here interpolates: the image
    --- goes exactly where it is told, and what smooths (or deliberately does
    --- not) is the sample buffer feeding it.
    ---@param self HudGhost
    ---@param nx number
    ---@param ny number
    ---@return boolean
    SetPosition = function(self, nx, ny)
        if not nx or not ny then
            return false
        end

        local ddx, ddy = nx - self.lastNX, ny - self.lastNY
        local jump = Config.Hud.JumpDistance
        local jumped = (ddx * ddx + ddy * ddy) > (jump * jump)
        self.lastNX, self.lastNY = nx, ny

        -- Whole pixels: sub-pixel moves would re-layout every frame for nothing.
        local px = math.floor(nx * self.panelWidth)
        local py = math.floor(ny * self.panelHeight)
        if px < 0 then px = 0 end
        if py < 0 then py = 0 end
        px = self.panelWidth / 2 - px
        py = self.panelHeight / 2 - py

        if px ~= self.hudX or py ~= self.hudY then
            self.hudX = px
            self.hudY = py
            LayoutHelpers.AtLeftTopIn(self.hud, self, px, py)
        end
        return jumped
    end,

    ---@param self HudGhost
    ---@param alpha number
    ApplyAlpha = function(self, alpha)
        self.hud:SetAlpha(alpha * Config.Hud.Alpha)
    end,
}
