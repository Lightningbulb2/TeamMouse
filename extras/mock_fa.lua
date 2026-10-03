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

-- Stock Lua 5.0 has no string.match; FAF adds one in lua/system/utils.lua,
-- which the mod relies on. The same implementation, so the tests can run on
-- the game's own Lua version (5.0) as well as on 5.1.
if not string.match then
    rawset(string, 'match', function(input, exp, init)
        local match
        string.gsub(string.sub(input, init or 1), exp, function(...) match = arg end, 1)
        if match then
            return unpack(match)
        end
    end)
    rawset(string, 'gmatch', string.gfind)
end

-- Varargs as Lua 5.0 has them (the implicit `arg`), so this file runs on the
-- game's own Lua version as well as 5.1.
local function MakeClass(...)
    local bases = arg
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
                if c.__init then c.__init(inst, unpack(arg)) end
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

--- Tracks whether the left mouse button is currently held, for
--- env.IsKeyDown('LBUTTON'). Deliberately module-level rather than per
--- environment: the two places that need to update it (WorldView's and the
--- root frame's own default HandleEvent) are shared class/constructor code,
--- not per-environment closures, and CreateEnvironment resets it at the start
--- of every session, which is enough for this suite's sequential sessions.
local sharedButtonState = { left = false, right = false }
M.buttons = sharedButtonState   -- tests may set these directly

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
    DisableHitTest = function(self, disabled)
        if disabled == nil then disabled = true end
        self._hitTestDisabled = disabled
    end,
    -- The engine's counterpart to DisableHitTest; the drag overlay uses it to
    -- switch the previous cell back on when the hole moves.
    EnableHitTest = function(self, enabled)
        if enabled == nil then enabled = true end
        self._hitTestDisabled = not enabled
    end,
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
        -- FAF's WorldViewShapeComponent: shapes drawn each frame from
        -- OnRenderWorld (M.RenderWorld plays the engine's part).
        self.Shapes = {}
        self.customRender = false
        self.HandleEvent = function(s, event)
            s._lastEvent = event
            if event.Type == 'ButtonPress' and event.Modifiers and event.Modifiers.Left then
                sharedButtonState.left = true
            elseif event.Type == 'ButtonPress' and event.Modifiers and event.Modifiers.Right then
                sharedButtonState.right = true
            elseif event.Type == 'ButtonRelease' then
                sharedButtonState.left = false
                sharedButtonState.right = false
            end
            return false
        end
    end,

    --- Crude orthographic projection: world XZ maps straight to view pixels,
    --- which is enough to exercise the placement and culling paths.
    AddShape = function(self, shape, id)
        self.Shapes[id] = shape
        self.customRender = true
    end,
    RemoveShape = function(self, id)
        self.Shapes[id] = nil
        if next(self.Shapes) == nil then self.customRender = false end
    end,
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
    -- The engine's root frame has a HandleEvent; teammouse.lua wraps it.
    frame.HandleEvent = function(s, event)
        s._lastEvent = event
        if event.Type == 'ButtonPress' and event.Modifiers and event.Modifiers.Left then
            sharedButtonState.left = true
        elseif event.Type == 'ButtonPress' and event.Modifiers and event.Modifiers.Right then
            sharedButtonState.right = true
        elseif event.Type == 'ButtonRelease' then
            sharedButtonState.left = false
            sharedButtonState.right = false
        end
        return false
    end

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
    env.__receivedCompact = 0

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
    env.__calls = {}
    env.__chat = {}
    -- The order under the pointer, as GetHighlightCommand reports it.
    env.__highlight = nil
    env.GetHighlightCommand = function() return env.__highlight end
    env.__paused = false
    env.SetPaused = function(units, paused)
        table.insert(env.__calls, 'SetPaused')
        env.__paused = paused and true or false
    end
    env.GetIsPaused = function(units) return env.__paused end

    env.IsAlly = function(a, b)
        if a == nil or a < 1 then return false end
        local armies = opts.armies
        if not armies[a] or not armies[b] then return false end
        return armies[a].team == armies[b].team
    end
    env.IsEnemy = function(a, b) return not env.IsAlly(a, b) end

    sharedButtonState.left = false   -- a fresh session starts with nothing held
    sharedButtonState.right = false
    env.IsKeyDown = function(key)
        if key == 'LBUTTON' or key == 'Left' then
            return sharedButtonState.left
        end
        if key == 'RBUTTON' then
            return sharedButtonState.right
        end
        return false
    end

    -- Units currently selected. Empty by default; a test that wants a right
    -- click to count as an order puts something in it.
    env.__selectedUnits = {}
    env.GetSelectedUnits = function() return env.__selectedUnits end
    -- The game's blueprint commands (upgrades go through these), recorded.
    env.__issued = {}
    env.IssueBlueprintCommand = function(command, bp, count, clear)
        table.insert(env.__issued, { 'IssueBlueprintCommand', command, bp })
    end
    env.IssueBlueprintCommandToUnits = function(units, command, bp, count, clear)
        table.insert(env.__issued, { 'IssueBlueprintCommandToUnits', command, bp })
    end
    env.IssueBlueprintCommandToUnit = function(unit, command, bp, count, clear)
        table.insert(env.__issued, { 'IssueBlueprintCommandToUnit', command, bp })
    end
    -- SelectUnits: each call's units kept in env.__selectCalls.
    env.__selectCalls = {}
    env.SelectUnits = function(units) table.insert(env.__selectCalls, units) end

    env.GetCursor = function() return cursorObj end
    env.GetMouseWorldPos = function() return env.__mouseWorld end
    env.GetMouseScreenPos = function() return env.__mouseScreen end
    env.GetFrame = function() return frame end

    -- Global in the real engine: UnProject(view, point) -> world Vector.
    -- Inverse of the mock WorldView.Project.
    env.UnProject = function(view, point)
        return { point[1] / 2, 0, point[2] / 2 }
    end

    -- The camera's full state, as SaveSettings / RestoreSettings see it.
    -- RestoreSettings calls are kept in env.__restored.
    env.__camera = { Focus = { 100, 0, 100 }, Heading = 3.14159, Pitch = 1.2 }
    env.__restored = {}
    env.GetCamera = function(name)
        return {
            SaveSettings = function()
                local c = env.__camera
                return { Focus = { c.Focus[1], c.Focus[2], c.Focus[3] }, Heading = c.Heading,
                    Pitch = c.Pitch, Zoom = cameraZoom }
            end,
            RestoreSettings = function(self, s)
                table.insert(env.__restored, s)
                env.__camera.Focus = { s.Focus[1], s.Focus[2], s.Focus[3] }
                env.__camera.Heading, env.__camera.Pitch = s.Heading, s.Pitch
                cameraZoom = s.Zoom
            end,
            GetZoom = function() return cameraZoom end,
            GetTargetZoom = function() return cameraZoom end,
            GetFocusPosition = function() return { 0, 0, 0 } end,
            -- How far in and out the camera goes; the far end is the map's.
            GetMinZoom = function() return env.__zoomRange[1] end,
            GetMaxZoom = function() return env.__zoomRange[2] end,
        }
    end
    env.__setZoom = function(z) cameraZoom = z end
    env.__zoomRange = { 30, 600 }

    env.__circles, env.__rects = {}, {}
    env.UI_DrawCircle = function(pos, size, color, thickness)
        table.insert(env.__circles, { { pos[1], pos[2], pos[3] }, size, color, thickness, env.__drawingView })
    end
    env.UI_DrawRect = function(pos, size, color, thickness)
        table.insert(env.__rects, { { pos[1], pos[2], pos[3] }, size, color, thickness, env.__drawingView })
    end
    env.__lines = {}
    env.UI_DrawLine = function(p1, p2, color, thickness)
        table.insert(env.__lines, { { p1[1], p1[2], p1[3] }, { p2[1], p2[2], p2[3] }, color, thickness,
            env.__drawingView })
    end

    -- Whether the (replayed) game is paused.
    env.__paused = false
    env.SessionIsPaused = function() return env.__paused end

    env.__sentLegacy = {}
    env.__sentVersion = {}
    env.__sentMute = {}
    env.__sentHello = {}
    local function DeepCopy(t)
        if type(t) ~= 'table' then return t end
        local out = {}
        for k, v in pairs(t) do out[k] = DeepCopy(v) end
        return out
    end
    env.SessionSendChatMessage = function(clients, msg)
        -- The version announcement (version.lua), once a game: kept apart so
        -- "the first/last packet sent" still means cursor data.
        if msg.tmv ~= nil then
            table.insert(env.__sentVersion, { clients = clients, msg = msg })
            return
        end
        -- "I read the compact format" (tmc): kept apart too.
        if msg.tmc ~= nil then
            table.insert(env.__sentHello, { clients = clients, msg = DeepCopy(msg) })
            return
        end
        -- The compact format (wirecodec.lua): decoded with the mod's own
        -- decoder, so everything below sees the packet the receiver gets.
        -- `wire` is what actually went out; `compact` says which format.
        local wire = DeepCopy(msg)
        local compact = false
        if type(msg.TeamMouse) == 'string' then
            local decoded = env.import('/mods/TeamMouse/modules/wirecodec.lua').Decode(msg.TeamMouse)
            assert(decoded, 'mock: a compact packet that does not decode was sent')
            msg = decoded
            compact = true
        end
        -- "Stop / start sending to me" (tmo): kept apart too.
        if msg.tmo ~= nil then
            table.insert(env.__sentMute, { clients = clients, raw = msg })
            return
        end
        -- Each beat also sends the SharedMouse v2 compatibility packet
        -- ({ a = true, b = { x, y, z, order } }). Keep those apart, so tests
        -- about the current protocol still see one message per send.
        if msg.p == nil then
            local b = msg.b or {}
            table.insert(env.__sentLegacy, {
                clients = clients,
                msg = { a = msg.a, b = { b[1], b[2], b[3], b[4] } },
            })
            return
        end

        -- Deep copy, because the mod reuses its outgoing table on purpose.
        -- `raw` is exactly what went on the wire. `msg` is the packet as a
        -- receiver reads it: fields left out mean their default, zoom is the
        -- last one sent, and the packed extra samples are unpacked into the
        -- plain layout (age, x, y, z, hx, hy, bx, bz, flags per sample), so
        -- tests can talk about what arrives rather than how it's squeezed.
        local raw = { p = {} }
        for k, v in pairs(msg) do
            if k ~= 'p' then raw[k] = v end
        end
        for i = 1, 3 do raw.p[i] = msg.p[i] end

        local copy = { p = { raw.p[1], raw.p[2], raw.p[3] } }
        for k, v in pairs(raw) do
            if k ~= 'p' then copy[k] = v end
        end
        if copy.w == nil then copy.w = true end
        for _, key in ipairs({ 's', 'l', 'r', 'd', 'b', 'e', 'mo', 'mob', 'ac', 'gk', 'oa' }) do
            if copy[key] == nil then copy[key] = false end
        end
        if raw.z ~= nil then env.__lastZoom = raw.z end
        copy.z = env.__lastZoom
        if copy.hx == nil then copy.hx, copy.hy = 0.5, 0.9 end
        if copy.bx == nil then copy.bx, copy.bz = raw.p[1], raw.p[3] end
        if type(raw.e) == 'string' then
            -- Filled with table.insert, which counts correctly on both 5.0
            -- (hidden 'n') and 5.1.
            local e = {}
            env.import('/mods/TeamMouse/modules/wirepack.lua').UnpackSamples(raw.e, raw.p[1], raw.p[3], 1000,
                function(age, x, z, hx, hy, bx, bz, flags)
                    for _, v in ipairs({ age, x, raw.p[2], z, hx, hy, bx, bz, flags }) do
                        table.insert(e, v)
                    end
                end)
            copy.e = e
        end
        table.insert(env.__sent, { clients = clients, msg = copy, raw = raw, wire = wire, compact = compact })
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

    -- The game's options as the lobby left them. Tests set
    -- env.__scenario.Options[...] before anything reads them.
    env.__scenario = opts.scenario or { Options = {} }
    env.SessionGetScenarioInfo = function() return env.__scenario end

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

    -- The query system's user side (FAF /lua/userplayerquery.lua): listeners
    -- by name, and ProcessQueries, which the game's sync calls with whatever
    -- queries the sim passed up this tick.
    local queryListeners = {}
    env.__queryListeners = queryListeners
    local userPlayerQuery = {
        AddQueryListener = function(name, callback)
            table.insert(queryListeners, { Name = name, Callback = callback })
        end,
        ProcessQueries = function(queries)
            for _, q in ipairs(queries) do
                for _, l in ipairs(queryListeners) do
                    if l.Name == q.Name then l.Callback(q) end
                end
            end
        end,
    }

    -- SimCallback: what a player sends into the sim (and so into the replay).
    -- Kept in env.__simCallbacks; M.SimRoundTrip plays the sim's part.
    env.__simCallbacks = {}
    env.SimCallback = function(callback, addSelection)
        table.insert(env.__simCallbacks, callback)
    end

    local stubs = {
        ['/lua/userplayerquery.lua'] = userPlayerQuery,
        ['/lua/maui/group.lua'] = { Group = Group },
        ['/lua/maui/bitmap.lua'] = { Bitmap = Bitmap },
        ['/lua/maui/control.lua'] = { Control = Control },
        ['/lua/shared/color.lua'] = { ParseColor = ParseColor },
        ['/lua/ui/uiutil.lua'] = {
            bodyFont = 'Arial',
            CreateText = function(parent) return Text(parent) end,
            UIFile = function(p) return p end,
            -- FAF's checkbox: SetCheck(checked, skipEvent), IsChecked, OnCheck.
            -- Click() is what a real mouse click does.
            CreateCheckbox = function(parent, texturePath)
                local box = Bitmap(parent)
                box:SetSolidColor('ff888888')
                box._checked = false
                box.SetCheck = function(self, checked, skipEvent)
                    self._checked = checked and true or false
                    if not skipEvent and self.OnCheck then self:OnCheck(self._checked) end
                end
                box.IsChecked = function(self) return self._checked end
                box.Click = function(self) self:SetCheck(not self._checked) end
                return box
            end,
            -- A Checkbox in the game: checked means collapsed.
            CreateCollapseArrow = function(parent, position)
                if position ~= 't' and position ~= 'r' and position ~= 'l' then
                    error("Collapse arrow position must be one of: 'l', 't', 'r'", 2)
                end
                local arrow = Bitmap(parent)
                arrow:SetSolidColor('ff888888')
                arrow._checked = false
                arrow.SetCheck = function(self, checked, skipEvent)
                    self._checked = checked
                    if not skipEvent and self.OnCheck then self:OnCheck(checked) end
                end
                arrow.Click = function(self) self:SetCheck(not self._checked) end
                return arrow
            end,
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
        -- Where FAF's key actions end up (lua/keymap/keyactions.lua). Each
        -- records its calls, so tests can check the real function still ran.
        ['/lua/ui/game/orders.lua'] = {
            Stop = function(units) table.insert(env.__calls, 'Stop') end,
            SoftStop = function(units)
                table.insert(env.__calls, 'SoftStop')
                -- As the real one does: ends by calling Stop.
                env.import('/lua/ui/game/orders.lua').Stop({})
            end,
        },
        ['/lua/ui/game/construction.lua'] = {
            -- As the real ones: all end in SetPaused.
            ToggleUnitPause = function()
                table.insert(env.__calls, 'ToggleUnitPause')
                env.SetPaused(env.__selectedUnits, not env.GetIsPaused(env.__selectedUnits))
            end,
            ToggleUnitPauseAll = function()
                table.insert(env.__calls, 'ToggleUnitPauseAll')
                env.SetPaused(env.__selectedUnits, true)
            end,
            ToggleUnitUnpauseAll = function()
                table.insert(env.__calls, 'ToggleUnitUnpauseAll')
                env.SetPaused(env.__selectedUnits, false)
            end,
        },
        ['/lua/keymap/misckeyactions.lua'] = {
            ToggleRepeatBuild = function() table.insert(env.__calls, 'ToggleRepeatBuild') end,
            AbortNavigation = function() table.insert(env.__calls, 'AbortNavigation') end,
        },
        ['/lua/ui/game/chat/ChatController.lua'] = {
            AppendEntry = function(entry) table.insert(env.__chat, entry) end,
        },
        ['/lua/ui/game/gamemain.lua'] = {
            -- A cursor packet a test hands the mod goes in as the compact
            -- string when it has one (as a TeamMouse sender would send it),
            -- so receiving is tested through the decoder; opts.plainReceive
            -- hands them over as they are. env.__receivedCompact counts.
            RegisterChatFunc = function(fn, id)
                if id ~= 'TeamMouse' then
                    env.__chatFuncs[id] = fn
                    return
                end
                env.__chatFuncs[id] = function(sender, msg)
                    if not opts.plainReceive and type(msg) == 'table' and msg.p ~= nil
                        and msg.tmo == nil and msg.tmv == nil and msg.tmc == nil then
                        local s = env.import('/mods/TeamMouse/modules/wirecodec.lua').Encode(msg)
                        if s then
                            env.__receivedCompact = env.__receivedCompact + 1
                            return fn(sender, { TeamMouse = s })
                        end
                    end
                    return fn(sender, msg)
                end
            end,
            AddBeatFunction = function() end,
            RemoveBeatFunction = function() end,
            AddOnUIDestroyedFunction = function() end,
        },
    }

    -- A test's own stubs: opts.stubs(classes) -> { path = table }. A table
    -- for a path the mock already stubs is merged into it (adds functions).
    if type(opts.stubs) == 'function' then
        local extra = opts.stubs({ Group = Group, Bitmap = Bitmap, Text = Text, Control = Control, env = env })
        for path, stub in pairs(extra) do
            if stubs[path] then
                for k, v in pairs(stub) do stubs[path][k] = v end
            else
                stubs[path] = stub
            end
        end
    end

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

--- Move the local pointer over a world view, the way the engine reports it:
--- the view receives a MouseMotion carrying screen coordinates. Also updates
--- the polled globals, which are only trustworthy in this situation.
---@param env table
---@param x number
---@param y number
---@param viewKey? string
--- Play the sim's part for the query system: take every OnPlayerQuery that
--- `fromEnv`'s player sent into the sim (from index `first`), and hand it up to
--- `toEnv`'s interface as the game's sync would -- in the same game, or in a
--- replay of it. Returns how many were delivered.
function M.SimRoundTrip(fromEnv, toEnv, first, commandSource)
    local queries = {}
    for i = first or 1, table.getn(fromEnv.__simCallbacks) do
        local cb = fromEnv.__simCallbacks[i]
        if type(cb) == 'table' and cb.Func == 'OnPlayerQuery' and type(cb.Args) == 'table' then
            -- What the sim adds (SimPlayerQuery.OnPlayerQuery).
            cb.Args.FromCommandSource = commandSource or 0
            table.insert(queries, cb.Args)
        end
    end
    toEnv.import('/lua/userplayerquery.lua').ProcessQueries(queries)
    return table.getn(queries)
end

--- One frame of the engine rendering the world: every shape on every view
--- that has custom rendering on is rendered. UI_DrawLine calls are recorded
--- in env.__lines (cleared first) as { p1, p2, color, thickness, view }.
function M.RenderWorld(env)
    env.__lines, env.__circles, env.__rects = {}, {}, {}
    for key, view in pairs(env.__views) do
        if view.customRender then
            env.__drawingView = key
            for _, shape in pairs(view.Shapes) do
                shape:Render(0.016)
            end
        end
    end
    return env.__lines
end

function M.HoverWorld(env, x, y, viewKey)
    local view = env.__views[viewKey or 'WorldCamera']
    env.__mouseScreen = { x, y }
    return view:HandleEvent({ Type = 'MouseMotion', MouseX = x, MouseY = y, Modifiers = {} })
end

--- Move the local pointer over the interface. The root frame sees the events
--- and the polled globals are left frozen, as they are in the real game.
---
--- Two motion events, a pixel apart, ending at x, y: the mod only believes the
--- pointer has left the map on the second of two root-frame events in a row
--- (localMouse.pendingHud), and real movement always produces a stream of them.
---@param env table
---@param x number
---@param y number
function M.HoverHud(env, x, y)
    env.__frame:HandleEvent({ Type = 'MouseMotion', MouseX = x - 1, MouseY = y, Modifiers = {} })
    return env.__frame:HandleEvent({ Type = 'MouseMotion', MouseX = x, MouseY = y, Modifiers = {} })
end

--- Convenience: find the mod's frame driver under the root frame.
function M.FindDriver(env)
    for _, child in ipairs(env.__frame.children) do
        -- Destroy() marks a control destroyed but does not remove it from its
        -- parent's own children list (this mock does not model that, and it
        -- may not be true of the real engine either) -- skip anything already
        -- gone so a destroy-and-recreate cycle doesn't look like duplicates.
        if child._name == 'TeamMouseDriver' and not child._destroyed then
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
        if child._name == 'TeamMouseCursor' and not child._destroyed then
            table.insert(found, child)
        end
    end
    return found
end

function M.FindDragOverlays(env)
    local found = {}
    for _, child in ipairs(env.__frame.children) do
        if child._name == 'TeamMouseDragOverlay' and not child._destroyed then
            table.insert(found, child)
        end
    end
    return found
end

return M
