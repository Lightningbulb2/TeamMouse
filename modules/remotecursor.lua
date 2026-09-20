--******************************************************************************
--** TeamMouse -- modules/remotecursor.lua
--**
--** One of these exists per remote player per world view. It owns the arrow,
--** the name label, the build ghost, the selection ring and the HUD ghost.
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
local HudGhost = import(_G.TeamMousePath .. '/modules/hudghost.lua').HudGhost

local UIUtil = import('/lua/ui/uiutil.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Group = import('/lua/maui/group.lua').Group

local GameCommon = import('/lua/ui/game/gamecommon.lua')

local MathFloor = math.floor
local MathSqrt = math.sqrt
local MathPow = math.pow
local MathSin = math.sin
local MathAbs = math.abs

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
        self.appliedBuild = false
        self.hidden = true
        self.ringShown = false
        self.buildShown = false
        self.hudShown = false
        self.hotspotX = Config.Appearance.ArrowHotspotX
        self.hotspotY = Config.Appearance.ArrowHotspotY

        self.arrowTexture = CursorData.ArrowForColor(record.color)
        self.uiColor = CursorData.SafeUIColor(record.color)

        -- Selection ring, behind the cursor.
        if Config.Selection.Enabled then
            self.ring = Bitmap(self, CursorData.SelectionRingTexture())
            LayoutHelpers.SetDimensions(self.ring, Config.Selection.RingSize, Config.Selection.RingSize)
            self.ring:DisableHitTest(true)
            self.ring:Hide()
        end

        -- Build ghost controls are created on first use rather than up front.
        -- A Bitmap with no texture assigned produces "GetResource: Invalid
        -- name" warnings when the engine tries to resolve it, and most cursors
        -- never enter build mode at all.
        self.buildIcon = false
        self.buildFrame = false

        -- The cursor itself.
        self.icon = Bitmap(self, self.arrowTexture)
        self.icon:DisableHitTest(true)

        -- Name label.
        if Config.Appearance.ShowLabels then
            self.label = UIUtil.CreateText(self, record.name or '?',
                Config.Appearance.LabelSize, UIUtil.bodyFont, true)
            self.label:SetColor(self.uiColor)
            self.label:DisableHitTest(true)
        end

        -- HUD ghost, created lazily -- most cursors never need one, and the
        -- 'full' silhouette is a fair number of bitmaps to build up front.
        self.hud = false

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

        local size = self.appliedOrder > 0
            and Config.Appearance.OrderIconSize
            or Config.Appearance.ArrowSize

        local drawSize = MathFloor(size * scale + 0.5)
        if drawSize < 6 then drawSize = 6 end

        local hx = MathFloor(self.hotspotX * scale + 0.5)
        local hy = MathFloor(self.hotspotY * scale + 0.5)

        LayoutHelpers.SetDimensions(self.icon, drawSize, drawSize)
        LayoutHelpers.AtLeftTopIn(self.icon, self, -hx, -hy)

        if self.ring then
            local ringSize = MathFloor(Config.Selection.RingSize * scale + 0.5)
            LayoutHelpers.SetDimensions(self.ring, ringSize, ringSize)
            LayoutHelpers.AtLeftTopIn(self.ring, self,
                MathFloor(-ringSize * 0.5 + 0.5), MathFloor(-ringSize * 0.5 + 0.5))
        end

        if self.label then
            LayoutHelpers.CenteredBelow(self.label, self.icon, Config.Appearance.LabelOffset)
        end
    end,

    --- Swap the cursor texture when the remote player's order changes.
    ---@param self RemoteCursor
    ---@param orderIndex number
    ApplyOrder = function(self, orderIndex)
        if orderIndex == self.appliedOrder then
            return
        end

        local texture = CursorData.TextureForIndex(orderIndex)
        if texture then
            self.icon:SetTexture(texture)
            self.hotspotX, self.hotspotY = CursorData.HotspotForIndex(orderIndex)
            self.appliedOrder = orderIndex
        else
            -- Unknown order, or the texture is missing from this skin.
            self.icon:SetTexture(self.arrowTexture)
            self.hotspotX = Config.Appearance.ArrowHotspotX
            self.hotspotY = Config.Appearance.ArrowHotspotY
            self.appliedOrder = 0
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

    --- Show or hide the selection ring.
    ---@param self RemoteCursor
    ---@param selecting boolean
    ApplyRing = function(self, selecting)
        if not self.ring or selecting == self.ringShown then
            return
        end
        self.ringShown = selecting
        if selecting then
            self.ring:Show()
        else
            self.ring:Hide()
        end
    end,

    --- Switch between the map cursor and the HUD ghost.
    ---@param self RemoteCursor
    ---@param onHud boolean
    ---@param nx number
    ---@param ny number
    ApplyHud = function(self, onHud, nx, ny)
        if not Config.Hud.Enabled then
            return
        end

        if onHud and not self.hud then
            self.hud = HudGhost(self, self.uiColor)
            -- Force the next alpha push, since it is skipped when unchanged
            -- and the panel has just appeared at whatever default it built at.
            self.appliedAlpha = -1
            -- Centre the panel on the anchor so it sits over the spot the
            -- player was last working on.
            LayoutHelpers.AtLeftTopIn(self.hud, self,
                MathFloor(-self.hud.panelWidth * 0.5 + 0.5),
                MathFloor(-self.hud.panelHeight * 0.5 + 0.5))
        end

        if onHud and self.hud then
            self.hud:SetPosition(nx, ny)
        end

        if onHud == self.hudShown then
            return
        end
        self.hudShown = onHud

        if onHud then
            if self.hud then self.hud:Show() end
            self.icon:Hide()
            if self.ring then self.ring:Hide() end
            if self.buildIcon and self.buildShown then
                self.buildIcon:Hide()
                self.buildFrame:Hide()
            end
        else
            if self.hud then self.hud:Hide() end
            self.icon:Show()
            if self.ring and self.ringShown then self.ring:Show() end
            if self.buildIcon and self.buildShown then
                self.buildIcon:Show()
                self.buildFrame:Show()
            end
        end
    end,

    --- Push an opacity to every piece. Skipped for changes below the epsilon.
    ---@param self RemoteCursor
    ---@param alpha number
    ---@param ringAlpha number
    ApplyAlpha = function(self, alpha, ringAlpha)
        if MathAbs(alpha - self.appliedAlpha) < Config.Appearance.AlphaEpsilon then
            return
        end
        self.appliedAlpha = alpha

        self.icon:SetAlpha(alpha)

        if self.label then
            self.label:SetAlpha(alpha)
        end
        if self.ring then
            self.ring:SetAlpha(alpha * ringAlpha)
        end
        if self.buildIcon then
            self.buildIcon:SetAlpha(alpha * Config.Build.GhostAlpha)
            self.buildFrame:SetAlpha(alpha * Config.Build.FrameAlpha)
        end
        if self.hud then
            self.hud:ApplyAlpha(alpha)
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
        self.icon:SetHidden(onHud)
        if self.ring then self.ring:SetHidden(onHud or not self.ringShown) end
        if self.hud then self.hud:SetHidden(not onHud) end
        if self.buildIcon then
            local hide = onHud or not self.buildShown
            self.buildIcon:SetHidden(hide)
            self.buildFrame:SetHidden(hide)
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
        local onHudPanel = record.onHud and Config.Hud.Enabled
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
                self:SetVisible(false)
                return
            end
        end

        self:SetVisible(true)

        self.Left:SetValue(absX)
        self.Top:SetValue(absY)

        -- Mode and decoration. When the HUD panel is switched off entirely we
        -- keep drawing the normal cursor rather than freezing it half-updated,
        -- so disabling the feature falls back to plain behaviour.
        self:ApplyHud(onHudPanel, record.hudX, record.hudY)

        if not onHudPanel then
            self:ApplyOrder(record.orderIndex)
            self:ApplyBuild(record.buildId)
            self:ApplyRing(record.selecting)
        end

        ------------------------------------------------------------------
        -- Scale
        ------------------------------------------------------------------
        local scale = 1.0
        if Config.Zoom.Enabled and viewInfo.zoom and viewInfo.zoom > 0
            and record.zoom and record.zoom > 0 then
            -- A teammate zoomed further out than you is working over a wider
            -- area than your view shows, so their cursor draws larger.
            local ratio = record.zoom / viewInfo.zoom
            scale = MathPow(ratio, Config.Zoom.Exponent)
            if scale < Config.Zoom.MinScale then scale = Config.Zoom.MinScale end
            if scale > Config.Zoom.MaxScale then scale = Config.Zoom.MaxScale end
        end

        -- Quantise so a smooth zoom doesn't re-layout on every frame.
        local q = Config.Appearance.ScaleQuantum
        scale = MathFloor(scale / q + 0.5) * q
        self:ApplyScale(scale, false)

        ------------------------------------------------------------------
        -- Opacity
        ------------------------------------------------------------------
        local alpha = Config.Appearance.BaseAlpha * record.fade

        -- Fade out as the local camera pulls back, so a strategic-zoom view
        -- doesn't fill up with teammate cursors.
        if Config.Zoom.Enabled and viewInfo.zoom then
            local z0 = Config.Zoom.FadeStartZoom
            local z1 = Config.Zoom.FadeEndZoom
            if viewInfo.zoom > z0 and z1 > z0 then
                local t = (viewInfo.zoom - z0) / (z1 - z0)
                if t > 1 then t = 1 end
                alpha = alpha * (1 - t * (1 - Config.Zoom.MinZoomAlpha))
            end
        end

        -- Fade out when the local mouse is near, so a teammate's cursor never
        -- sits on top of what you are trying to click.
        if Config.Proximity.Enabled and viewInfo.mouseX then
            local dx = viewInfo.mouseX - absX
            local dy = viewInfo.mouseY - absY
            local dist = MathSqrt(dx * dx + dy * dy)
            local r = Config.Proximity.FadeRadius
            if dist < r then
                local t = dist / r
                alpha = alpha * (Config.Proximity.MinAlpha
                    + t * (1 - Config.Proximity.MinAlpha))
            end
        end

        -- Stale peers fade out over the last second before the timeout.
        local fadeWindow = 1.0
        if age > Config.Smoothing.StaleTimeout - fadeWindow then
            local t = (Config.Smoothing.StaleTimeout - age) / fadeWindow
            if t < 0 then t = 0 end
            alpha = alpha * t
        end

        local ringAlpha = Config.Selection.RingAlpha
        if self.ringShown and Config.Selection.PulseRate > 0 then
            ringAlpha = ringAlpha * (1 - Config.Selection.PulseDepth
                + Config.Selection.PulseDepth
                * MathSin(now * Config.Selection.PulseRate * 6.2831853))
        end

        self:ApplyAlpha(alpha, ringAlpha)
    end,

    ---@param self RemoteCursor
    OnDestroy = function(self)
        self.record = nil
        self.view = nil
        self.hud = false
        if Group.OnDestroy then
            Group.OnDestroy(self)
        end
    end,
}
