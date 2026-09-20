--******************************************************************************
--** TeamMouse -- extras/mock_fa.lua
--**
--** Enough of the Forged Alliance UI environment to run the mod's modules
--** outside the game, for the test harnesses.
--**
--** This is deliberately shallow. It is not a simulator -- it exists so that
--** logic errors, nil references and ordering mistakes surface on a desk
--** rather than in a lobby with seven other people waiting.
--**
--** Two things it does emulate carefully, because both have bitten this mod:
--**
--**   1. Lua 5.0 table semantics. The game runs 5.0.1, where table.insert,
--**      table.remove and table.getn maintain a hidden `n` field. Code that
--**      clears entries by assigning nil desynchronises `n` from the real
--**      contents, and table.remove then hands back nil off an array that
--**      table.getn still calls non-empty. Running the tests under stock 5.1,
--**      where all three use `#`, hides that completely.
--**
--**   2. Bitmaps with no texture and controls given invalid colours. The game
--**      logs "GetResource: Invalid name" for the former and silently
--**      mis-renders the latter; here they raise.
--**
--** and a third, added after it bit the cursor visuals:
--**
--**   3. Show() cascading to children. In the engine, showing a control shows
--**      every child too, including ones hidden individually, unless the
--**      child's OnHide(false) returns true. A mock where Show() only flips
--**      its own flag cannot see code that hides a child, hides the parent,
--**      then shows the parent and expects the child to stay hidden. Judge
--**      what would be drawn with M.IsVisible, not IsHidden().
--******************************************************************************

-- The game's hook sets this in gamemain.lua; nothing in the tests does, and
-- the mock's import() resolves paths relative to it.
_G.TeamMousePath = _G.TeamMousePath or '/mods/TeamMouse'

local M = {}

--------------------------------------------------------------------------------
-- Lua 5.0 table library
--------------------------------------------------------------------------------

local lua50 = {}

local function setn(t, n)
    rawset(t, 'n', n)
end

local function getn(t)
    local n = rawget(t, 'n')
    if type(n) == 'number' then
        return n
    end
    -- No 'n' yet: find a border the way 5.0 does, then cache it.
    local i = 0
    while rawget(t, i + 1) ~= nil do
        i = i + 1
    end
    setn(t, i)
    return i
end

lua50.getn = getn
lua50.setn = setn

lua50.insert = function(t, a, b)
    local n = getn(t)
    if b == nil then
        rawset(t, n + 1, a)
    else
        for i = n, a, -1 do
            rawset(t, i + 1, rawget(t, i))
        end
        rawset(t, a, b)
    end
    setn(t, n + 1)
end

lua50.remove = function(t, pos)
    local n = getn(t)
    if n <= 0 then
        return nil
    end
    pos = pos or n
    local value = rawget(t, pos)
    for i = pos, n - 1 do
        rawset(t, i, rawget(t, i + 1))
    end
    rawset(t, n, nil)
    setn(t, n - 1)
    return value
end

lua50.concat = function(t, sep)
    local n = getn(t)
    local out = {}
    for i = 1, n do
        out[i] = tostring(rawget(t, i))
    end
    return table.concat(out, sep or '')
end

lua50.sort = function(t, cmp)
    local n = getn(t)
    local slice = {}
    for i = 1, n do slice[i] = rawget(t, i) end
    table.sort(slice, cmp)
    for i = 1, n do rawset(t, i, slice[i]) end
end

M.lua50 = lua50

--------------------------------------------------------------------------------
-- Class system
--------------------------------------------------------------------------------

local function MakeClass(...)
    local bases = { ... }
    return function(spec)
        local cls = {}
        for _, base in ipairs(bases) do
            if type(base) == 'table' then
                for k, v in pairs(base) do
                    if cls[k] == nil then cls[k] = v end
                end
            end
        end
        for k, v in pairs(spec) do
            cls[k] = v
        end
        cls.__index = cls
        return setmetatable(cls, {
            __call = function(c, ...)
                local inst = setmetatable({}, c)
                if c.__init then c.__init(inst, ...) end
                return inst
            end,
        })
    end
end

--------------------------------------------------------------------------------
-- Lazy vars
--------------------------------------------------------------------------------

local function LazyVar(initial)
    local state = { value = initial or 0 }
    local methods = {
        Set = function(self, v) state.value = v end,
        SetValue = function(self, v) state.value = v end,
        SetFunction = function(self, f) state.value = f end,
        Get = function(self) return state.value end,
    }
    return setmetatable({}, {
        __call = function()
            if type(state.value) == 'function' then
                return state.value()
            end
            return state.value
        end,
        __index = methods,
    })
end

--------------------------------------------------------------------------------
-- Controls
--------------------------------------------------------------------------------

M.controlCount = 0
M.destroyedCount = 0

--- Bitmaps created without a texture or a solid colour. The game logs
--- "GetResource: Invalid name" for these, so tests assert this stays empty.
M.untexturedBitmaps = {}

local Control = MakeClass() {
    __init = function(self, parent)
        M.controlCount = M.controlCount + 1
        self.parent = parent
        self.children = {}
        self.Left = LazyVar(0)
        self.Top = LazyVar(0)
        self.Right = LazyVar(0)
        self.Bottom = LazyVar(0)
        self.Width = LazyVar(0)
        self.Height = LazyVar(0)
        self.Depth = LazyVar(1)
        self._hidden = false
        self._alpha = 1
        self._destroyed = false
        if parent and parent.children then
            table.insert(parent.children, self)
        end
    end,
    Hide = function(self) self._hidden = true end,
    -- Show() cascades into every child, exactly as the engine's does: a child
    -- the mod hid individually is shown again along with its parent. The one
    -- escape is the engine's own: a child whose OnHide(false) returns true is
    -- left alone (FAF's UI code uses this to keep individually-hidden children
    -- hidden). Hide() only needs to flip this control's own flag, because a
    -- hidden ancestor already hides the whole subtree; see M.IsVisible.
    Show = function(self)
        self._hidden = false
        for _, child in ipairs(self.children) do
            local veto = child.OnHide and child:OnHide(false)
            if not veto then
                child:Show()
            end
        end
    end,
    IsHidden = function(self) return self._hidden end,
    SetHidden = function(self, h) self._hidden = h end,
    SetAlpha = function(self, a)
        if type(a) ~= 'number' or a ~= a then
            error('SetAlpha given a non-number: ' .. tostring(a))
        end
        self._alpha = a
    end,
    GetAlpha = function(self) return self._alpha end,
    DisableHitTest = function(self) end,
    SetNeedsFrameUpdate = function(self, v) self._needsFrame = v end,
    SetName = function(self, n) self._name = n end,
    HitTest = function(self) return false end,
    OnDestroy = function(self) end,
    Destroy = function(self)
        if self._destroyed then
            error('control destroyed twice')
        end
        self._destroyed = true
        M.destroyedCount = M.destroyedCount + 1
        M.untexturedBitmaps[self] = nil
        if self.OnDestroy then self:OnDestroy() end
    end,
}

local Group = MakeClass(Control) {
    __init = function(self, parent, name)
        Control.__init(self, parent)
        self._name = name
    end,
}

local Bitmap = MakeClass(Control) {
    __init = function(self, parent, filename)
        Control.__init(self, parent)
        self._texture = nil
        self._color = nil
        if filename then
            self:SetTexture(filename)
        else
            M.untexturedBitmaps[self] = true
        end
    end,
    SetTexture = function(self, t)
        if type(t) ~= 'string' or t == '' then
            error('SetTexture given an invalid texture name: ' .. tostring(t))
        end
        self._texture = t
        M.untexturedBitmaps[self] = nil
    end,
    SetSolidColor = function(self, c)
        if type(c) ~= 'string' or c == '' then
            error('SetSolidColor given an invalid colour: ' .. tostring(c))
        end
        self._color = c
        M.untexturedBitmaps[self] = nil
    end,
}

local Text = MakeClass(Control) {
    __init = function(self, parent)
        Control.__init(self, parent)
    end,
    SetText = function(self, t) self._text = t end,
    SetColor = function(self, c)
        if type(c) ~= 'string' or c == '' then
            error('SetColor given an invalid colour: ' .. tostring(c))
        end
        self._color = c
    end,
    SetFont = function(self) end,
    SetDropShadow = function(self) end,
}

M.Control = Control
M.Group = Group
M.Bitmap = Bitmap
M.Text = Text

--------------------------------------------------------------------------------
-- World views
--------------------------------------------------------------------------------

local WorldView = MakeClass(Control) {
    __init = function(self, parent, cameraName, left, top, width, height)
        Control.__init(self, parent)
        self._cameraName = cameraName
        self.CursorOverWorld = true
        self.Left:Set(left)
        self.Top:Set(top)
        self.Right:Set(left + width)
        self.Bottom:Set(top + height)
        self.Width:Set(width)
        self.Height:Set(height)
        self.projectReturnsNil = false
        self.HandleEvent = function(s, event)
            s._lastEvent = event
            return false
        end
    end,

    --- Crude orthographic projection: world XZ maps straight to view pixels,
    --- which is enough to exercise the placement and culling paths.
    Project = function(self, worldPos)
        if self.projectReturnsNil then
            return nil
        end
        return {
            x = worldPos[1] * 2,
            y = worldPos[3] * 2,
            [1] = worldPos[1] * 2,
            [2] = worldPos[3] * 2,
        }
    end,
}

M.WorldView = WorldView

--------------------------------------------------------------------------------
-- Colour parsing, mirroring lua/shared/color.lua
--------------------------------------------------------------------------------

local EnumColors = {
    ROYALBLUE = '4269E7',
    DARKGREEN = '006500',
    GOLDENROD = 'DEA621',
    WHITE = 'FFFFFF',
    BLACK = '000000',
    RED = 'FF0000',
}

local function ParseColor(color)
    if type(color) ~= 'string' then
        error('ParseColor given a non-string')
    end
    local n1 = tonumber(string.sub(color, 1, 2), 16)
    if n1 then
        local n2 = tonumber(string.sub(color, 3, 4), 16)
        if n2 then
            local n3 = tonumber(string.sub(color, 5, 6), 16)
            if n3 then
                local n4 = tonumber(string.sub(color, 7, 8), 16)
                if n4 then
                    return n2 / 255, n3 / 255, n4 / 255, n1 / 255
                end
                return n1 / 255, n2 / 255, n3 / 255
            end
        end
    end
    if color == 'transparent' then
        return 0, 0, 0, 0
    end
    local hex = EnumColors[string.upper(color)]
    if not hex then
        return false
    end
    return tonumber(string.sub(hex, 1, 2), 16) / 255,
           tonumber(string.sub(hex, 3, 4), 16) / 255,
           tonumber(string.sub(hex, 5, 6), 16) / 255
end

M.ParseColor = ParseColor

--------------------------------------------------------------------------------
-- Environment construction
--------------------------------------------------------------------------------

--- Build a globals table representing a session.
---@param opts table
function M.CreateEnvironment(opts)
    opts = opts or {}

    local env = {}

    local clock = { t = 1000.0 }
    env.__clock = clock

    local frame = Group(nil, 'root')
    frame.Left:Set(0); frame.Top:Set(0)
    frame.Right:Set(1920); frame.Bottom:Set(1080)
    frame.Width:Set(1920); frame.Height:Set(1080)

    local views = {}
    views['WorldCamera'] = WorldView(frame, 'WorldCamera', 0, 0,
        opts.splitscreen and 960 or 1920, 1080)
    if opts.splitscreen then
        views['WorldCamera2'] = WorldView(frame, 'WorldCamera2', 960, 0, 960, 1080)
    end
    views['MiniMap'] = WorldView(frame, 'MiniMap', 0, 900, 180, 180)

    env.__views = views
    env.__frame = frame
    env.__sent = {}
    env.__logs = {}
    env.__chatFuncs = {}

    local cameraZoom = opts.zoom or 60

    local cursorObj = {
        SetTexture = function(self) end,
        Reset = function(self) end,
    }
    env.__cursor = cursorObj

    env.__mouseWorld = { 10, 0, 10 }
    env.__mouseScreen = { 100, 100 }
    env.__commandMode = { false, false }

    ----------------------------------------------------------------------
    -- Engine globals
    ----------------------------------------------------------------------
    env.LOG = function(msg) table.insert(env.__logs, tostring(msg)) end
    env.SPEW = env.LOG
    env.WARN = env.LOG

    env.GetSystemTimeSeconds = function() return clock.t end
    env.GetGameTimeSeconds = function() return clock.t end

    env.GetFocusArmy = function() return opts.focusArmy or 1 end
    env.GetArmiesTable = function()
        return { armiesTable = opts.armies, focusArmy = opts.focusArmy or 1 }
    end
    env.GetSessionClients = function() return opts.clients end

    env.IsAlly = function(a, b)
        if a == nil or a < 1 then return false end
        local armies = opts.armies
        if not armies[a] or not armies[b] then return false end
        return armies[a].team == armies[b].team
    end
    env.IsEnemy = function(a, b) return not env.IsAlly(a, b) end

    env.GetCursor = function() return cursorObj end
    env.GetMouseWorldPos = function() return env.__mouseWorld end
    env.GetMouseScreenPos = function() return env.__mouseScreen end
    env.GetFrame = function() return frame end

    env.GetCamera = function(name)
        return {
            GetZoom = function() return cameraZoom end,
            GetTargetZoom = function() return cameraZoom end,
            GetFocusPosition = function() return { 0, 0, 0 } end,
        }
    end
    env.__setZoom = function(z) cameraZoom = z end

    env.SessionSendChatMessage = function(clients, msg)
        -- Deep copy, because the mod reuses its outgoing table on purpose.
        local copy = { p = {} }
        for k, v in pairs(msg) do
            if k ~= 'p' then copy[k] = v end
        end
        for i = 1, 3 do copy.p[i] = msg.p[i] end
        table.insert(env.__sent, { clients = clients, msg = copy })
    end

    env.SessionIsReplay = function() return opts.replay or false end
    env.GetArmyAvatars = function() return nil end
    env.DiskGetFileInfo = function(path)
        if opts.missingTextures and opts.missingTextures[path] then
            return false
        end
        return true
    end

    env.Vector = function(x, y, z) return { x, y, z } end
    env.Vector2 = function(x, y) return { x, y, x = x, y = y } end
    env.VDist3 = function(a, b)
        local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    env.ForkThread = function(fn) return { fn = fn } end
    env.KillThread = function() end
    env.WaitSeconds = function() end
    env.WaitFrames = function() end

    env.__blueprints = opts.blueprints or {}

    env.Class = MakeClass
    env.ClassUI = MakeClass

    ----------------------------------------------------------------------
    -- table library: Lua 5.0 semantics plus the helpers the game adds in
    -- lua/system/utils.lua
    ----------------------------------------------------------------------
    env.table = {
        insert = lua50.insert,
        remove = lua50.remove,
        getn = lua50.getn,
        setn = lua50.setn,
        concat = lua50.concat,
        sort = lua50.sort,
        empty = function(t)
            if not t then return true end
            return next(t) == nil
        end,
        getsize = function(t)
            if not t then return 0 end
            local n = 0
            for _ in pairs(t) do n = n + 1 end
            return n
        end,
    }

    ----------------------------------------------------------------------
    -- Module resolution
    ----------------------------------------------------------------------
    local cache = {}

    local stubs = {
        ['/lua/maui/group.lua'] = { Group = Group },
        ['/lua/maui/bitmap.lua'] = { Bitmap = Bitmap },
        ['/lua/maui/control.lua'] = { Control = Control },
        ['/lua/shared/color.lua'] = { ParseColor = ParseColor },
        ['/lua/ui/uiutil.lua'] = {
            bodyFont = 'Arial',
            CreateText = function(parent) return Text(parent) end,
            UIFile = function(p) return p end,
        },
        ['/lua/maui/layouthelpers.lua'] = {
            GetPixelScaleFactor = function() return 1 end,
            SetDimensions = function(c, w, h) c.Width:Set(w); c.Height:Set(h) end,
            SetWidth = function(c, w) c.Width:Set(w) end,
            SetHeight = function(c, h) c.Height:Set(h) end,
            AtLeftTopIn = function(c, p, l, t)
                c._layout = { l or 0, t or 0 }
                c.Left:Set(p.Left() + (l or 0))
                c.Top:Set(p.Top() + (t or 0))
            end,
            AtCenterIn = function(c) c._layout = 'center' end,
            CenteredBelow = function(c) c._layout = 'below' end,
            FillParent = function(c, p)
                c.Left:Set(p.Left()); c.Top:Set(p.Top())
                c.Width:Set(p.Width()); c.Height:Set(p.Height())
            end,
        },
        ['/lua/ui/game/worldview.lua'] = {
            GetWorldViews = function() return views end,
            GetTopmostWorldViewAt = function(x, y)
                if opts.mouseOverView == false then return nil end
                return views[opts.mouseOverView or 'WorldCamera']
            end,
            viewLeft = views['WorldCamera'],
            viewRight = views['WorldCamera2'],
        },
        ['/lua/ui/game/commandmode.lua'] = {
            GetCommandMode = function() return env.__commandMode end,
            InCommandMode = function() return env.__commandMode[1] ~= false end,
        },
        ['/lua/ui/game/gamecommon.lua'] = {
            GetUnitIconFileNames = function(bp)
                return '/textures/ui/common/icons/units/'
                    .. bp.Display.IconName .. '_icon.dds'
            end,
        },
        ['/lua/ui/game/gamemain.lua'] = {
            RegisterChatFunc = function(fn, id) env.__chatFuncs[id] = fn end,
            AddBeatFunction = function() end,
            RemoveBeatFunction = function() end,
            AddOnUIDestroyedFunction = function() end,
        },
    }

    env.import = function(path)
        if cache[path] then return cache[path] end
        if stubs[path] then
            cache[path] = stubs[path]
            return stubs[path]
        end

        local file = string.gsub(path, '^/mods/TeamMouse/', '')
        local moduleEnv = setmetatable({}, { __index = env })
        cache[path] = moduleEnv

        local chunk, err = loadfile(file)
        if not chunk then
            error('mock import could not load ' .. path .. ': ' .. tostring(err))
        end
        setfenv(chunk, moduleEnv)
        chunk()
        return moduleEnv
    end

    env._G = env
    env.rawget = rawget
    env.rawset = rawset

    setmetatable(env, { __index = _G })
    return env
end

--- Convenience: find the mod's frame driver under the root frame.
function M.FindDriver(env)
    for _, child in ipairs(env.__frame.children) do
        if child._name == 'TeamMouseDriver' then
            return child
        end
    end
    return nil
end

--- What the player would actually see: a control is drawn only if it and every
--- ancestor are shown. Tests should use this rather than IsHidden(), which is
--- just the control's own flag and says nothing about a hidden parent.
---@param control table
---@return boolean
function M.IsVisible(control)
    while control do
        if control._hidden then
            return false
        end
        control = control.parent
    end
    return true
end

--- Convenience: all remote cursor visuals in a given view.
function M.FindCursors(env, viewKey)
    local found = {}
    local view = env.__views[viewKey]
    if not view then return found end
    for _, child in ipairs(view.children) do
        if child._name == 'TeamMouseCursor' then
            table.insert(found, child)
        end
    end
    return found
end

return M
