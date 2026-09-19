--******************************************************************************
--** SharedMouse2026 -- modules/sharedmouse.lua
--**
--** Shares your mouse position, cursor state and build selection with your
--** team, and draws theirs on your map.
--**
--** Structure:
--**   config.lua       every tunable and feature flag
--**   cursordata.lua   cursor name <-> wire index <-> texture, army colours
--**   remotecursor.lua the visual for one player in one view
--**   hudghost.lua     the stylised panel shown when a teammate is on their UI
--**   replaycodec.lua  optional zero-width encoding for replay playback
--**   sharedmouse.lua  this file: session setup, send, receive, view sync
--**
--** Data flow:
--**   OnBeat (10/s)  -> read local state -> SessionSendChatMessage to allies
--**   OnReceive      -> push a timestamped sample into that player's buffer
--**   OnFrame (60/s) -> interpolate every buffer, then place every visual
--**
--** The frame driver is deliberately singular. Reading view bounds, camera
--** zoom and the local mouse position once per frame and handing them to each
--** visual is much cheaper than each of a dozen visuals asking the engine
--** independently.
--******************************************************************************

local Config = import('/mods/SharedMouse2026/modules/config.lua')
local CursorData = import('/mods/SharedMouse2026/modules/cursordata.lua')
local RemoteCursor = import('/mods/SharedMouse2026/modules/remotecursor.lua').RemoteCursor
local ReplayCodec = import('/mods/SharedMouse2026/modules/replaycodec.lua')

local WorldViewManager = import('/lua/ui/game/worldview.lua')
local CommandMode = import('/lua/ui/game/commandmode.lua')
local Group = import('/lua/maui/group.lua').Group

local MathFloor = math.floor
local MathAbs = math.abs
local TableGetN = table.getn

--------------------------------------------------------------------------------
-- Session state
--------------------------------------------------------------------------------

--- nickname -> record. One entry per remote human we are allowed to see.
local peers = {}

--- army index -> record, for resolving senders whose name we can't match.
local peersByArmy = {}

--- Client indices we transmit to, as a dense array for SessionSendChatMessage.
local recipients = {}

local myArmy = -1
local myName = ''
local isObserver = false
local isReplay = false
local initialised = false

local cursor = false
local frameDriver = false

--- Error counters, so a persistent fault logs a handful of times instead of
--- sixty times a second.
local frameErrors = 0
local receiveErrors = 0
local lastFrameErrorLog = 0

--- Cached so we can tell when the engine has replaced a view wholesale, which
--- happens on every layout change.
local knownViews = {}

--- Set by the world view event hook while a selection box is being dragged.
local localSelecting = false
local selectingSince = 0

--- Last position we were genuinely over the world, reused while the local
--- mouse is on the HUD so peers see where we were last working.
local lastWorldPos = { 0, 0, 0 }
local haveWorldPos = false
local lastWorldZoom = 0

--- Send-loop state. These live at file scope on purpose: the previous version
--- declared them inside the beat callback, so they reset every call and the
--- "has the mouse moved" check always compared against the origin, meaning it
--- transmitted on every single beat regardless of movement.
local lastSent = { 0, 0, 0 }
local lastSentOrder = -1
local lastSentTime = 0
local lastSentHud = false
local lastSentSelecting = false

--- Reused to avoid allocating a table per send.
local outgoing = {
    Identifier = Config.ChatIdentifier,
    v = Config.Protocol,
    a = 0,
    p = { 0, 0, 0 },
    o = 0,
    z = 0,
    w = true,
    s = false,
    b = false,
    hx = 0,
    hy = 0,
}

--- Forward declarations. These are referenced by functions defined earlier in
--- the file than their own bodies, and a `local function` declared later would
--- not be in lexical scope at that point -- it would silently resolve to a nil
--- global instead.
local CreateFrameDriver
local VerifyViews

local function Log(msg)
    LOG('SharedMouse2026: ' .. tostring(msg))
end

local function Debug(msg)
    if Config.Debug then
        Log(msg)
    end
end

--- True only if all three components are real, finite numbers.
--- Note that the NaN test relies on NaN comparing unequal to itself, which is
--- the only portable way to spot it in Lua 5.0.
---@param v any
---@return boolean
local function IsFiniteVector(v)
    if type(v) ~= 'table' then
        return false
    end
    for i = 1, 3 do
        local n = v[i]
        if type(n) ~= 'number' or n ~= n or n > 1e30 or n < -1e30 then
            return false
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- Peer records
--------------------------------------------------------------------------------

---@param name string
---@param armyIndex number
---@param color string
---@return table
local function CreateRecord(name, armyIndex, color)
    return {
        name = name,
        army = armyIndex,
        color = color,

        -- Timestamped samples, oldest first, valid for indices 1..sampleCount.
        -- Managed by PushSample with an explicit count; see the note there for
        -- why table.insert / table.getn must not be used on this.
        samples = {},
        sampleCount = 0,

        -- Interpolated position handed to the visuals each frame.
        render = { 0, 0, 0 },

        hasData = false,
        lastUpdate = 0,

        orderIndex = 0,
        zoom = 0,
        onHud = false,
        selecting = false,
        buildId = false,
        hudX = 0.5,
        hudY = 0.9,

        -- Eased 0..1 used to crossfade state changes.
        fade = 0,

        -- viewKey -> RemoteCursor
        visuals = {},
    }
end

--- Drop a sample into a player's buffer, reusing the evicted table so the
--- steady state allocates nothing.
---@param record table
---@param x number
---@param y number
---@param z number
---@param now number
--
-- IMPORTANT: this buffer is managed with an explicit count and direct
-- indexing, never with table.insert / table.remove / table.getn.
--
-- Forged Alliance runs Lua 5.0, where those three maintain a hidden `n` field
-- on the table. Clearing entries by assigning nil -- as the first version of
-- this function did on a large jump -- leaves `n` pointing past the end of the
-- real data. table.getn then reports a count larger than the array, and
-- table.remove(samples, 1) hands back nil, which is exactly the
-- "Attempt to set attribute 't' on nil" crash.
--
-- LuaPlus compounds it: reading an attribute off nil returns nil rather than
-- raising, so a hole propagates silently until it reaches arithmetic, which is
-- why the same root cause also surfaced as "arithmetic on field 't'" inside
-- Interpolate rather than as an obvious nil index.
--
-- Slots are reused rather than reallocated, so the steady state allocates
-- nothing and a reset costs a single assignment.
--
local function PushSample(record, x, y, z, now)
    local samples = record.samples
    local capacity = Config.Smoothing.BufferSize
    local count = record.sampleCount

    -- A large jump is a camera cut or a cursor reappearing elsewhere, not
    -- movement. Drop the history so it snaps instead of sliding across the
    -- map. Resetting the count is enough; the slot tables stay for reuse.
    if count > 0 then
        local last = samples[count]
        local dx, dy, dz = x - last.x, y - last.y, z - last.z
        if (dx * dx + dy * dy + dz * dz) >
            (Config.Smoothing.SnapDistance * Config.Smoothing.SnapDistance) then
            count = 0
        end
    end

    -- Full: slide the window down one, moving the evicted slot to the end so
    -- it can be written over.
    if count >= capacity then
        local evicted = samples[1]
        for i = 1, capacity - 1 do
            samples[i] = samples[i + 1]
        end
        samples[capacity] = evicted
        count = capacity - 1
    end

    count = count + 1

    local slot = samples[count]
    if not slot then
        slot = {}
        samples[count] = slot
    end

    slot.t = now
    slot.x = x
    slot.y = y
    slot.z = z

    record.sampleCount = count
end

--- Advance a record's render position to (now - InterpolationDelay) by
--- interpolating between the two samples that bracket it.
---@param record table
---@param now number
local function Interpolate(record, now)
    local samples = record.samples
    local count = record.sampleCount
    if count == nil or count < 1 then
        return
    end

    local render = record.render
    local target = now - Config.Smoothing.InterpolationDelay

    if count == 1 or target <= samples[1].t then
        local s = samples[1]
        render[1], render[2], render[3] = s.x, s.y, s.z
        return
    end

    local newest = samples[count]
    if target >= newest.t then
        -- Ahead of the buffer: hold at the newest sample rather than
        -- extrapolating, which would overshoot on every direction change.
        render[1], render[2], render[3] = newest.x, newest.y, newest.z
        return
    end

    for i = 1, count - 1 do
        local a = samples[i]
        local b = samples[i + 1]
        if target >= a.t and target <= b.t then
            local span = b.t - a.t
            local f = 0
            if span > 0 then
                f = (target - a.t) / span
            end
            render[1] = a.x + (b.x - a.x) * f
            render[2] = a.y + (b.y - a.y) * f
            render[3] = a.z + (b.z - a.z) * f
            return
        end
    end
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

--- Coerce a wire value to a number within bounds, or return the fallback.
--- Everything arriving here came off the network, so nothing is trusted: a
--- single bad field must not be able to poison the render loop.
---@param value any
---@param fallback number
---@param low number
---@param high number
---@return number
local function SafeNumber(value, fallback, low, high)
    if type(value) ~= 'number' then
        return fallback
    end
    -- Rejects NaN, which compares false against itself and would otherwise
    -- propagate through interpolation into the layout.
    if value ~= value then
        return fallback
    end
    if value < low or value > high then
        return fallback
    end
    return value
end

local function ProcessMessage(sender, msg)
    if type(msg) ~= 'table' or msg.v ~= Config.Protocol then
        -- A teammate on a different version of the mod. Ignore quietly rather
        -- than mis-parsing their payload every beat.
        return
    end

    -- The engine gives us the raw account name. Prefer matching on that; fall
    -- back to the army index the sender claims, which covers the case where
    -- the "show player names" option has rewritten nicknames locally.
    local record = peers[sender]
    if not record and type(msg.a) == 'number' then
        record = peersByArmy[msg.a]
    end
    if not record then
        return
    end

    local pos = msg.p
    if type(pos) ~= 'table' then
        return
    end

    local x = SafeNumber(pos[1], nil, -100000, 100000)
    local y = SafeNumber(pos[2], 0, -100000, 100000)
    local z = SafeNumber(pos[3], nil, -100000, 100000)
    if x == nil or z == nil then
        return
    end

    local now = GetSystemTimeSeconds()

    PushSample(record, x, y, z, now)

    record.lastUpdate = now
    record.orderIndex = MathFloor(SafeNumber(msg.o, 0, 0, 1000))
    record.zoom = SafeNumber(msg.z, 0, 0, 100000)
    record.onHud = (msg.w == false)
    record.selecting = (msg.s == true)
    record.hudX = SafeNumber(msg.hx, 0.5, 0, 1)
    record.hudY = SafeNumber(msg.hy, 0.9, 0, 1)

    if type(msg.b) == 'string' and string.len(msg.b) > 0 and string.len(msg.b) < 64 then
        record.buildId = msg.b
    else
        record.buildId = false
    end

    if not record.hasData then
        -- First packet: seed the render position so the cursor appears where
        -- they are instead of flying in from the map origin.
        record.render[1], record.render[2], record.render[3] = x, y, z
        record.hasData = true
    end
end

--- Registered with gamemain.RegisterChatFunc.
---
--- gamemain.ReceiveChat does not guard the handlers it dispatches to, so an
--- error raised in here surfaces as "Error running ReceiveChat" and aborts the
--- rest of that chat message's processing -- potentially other mods' handlers
--- too. Keep the pcall.
---@param sender string
---@param msg table
local function OnReceive(sender, msg)
    local ok, err = pcall(ProcessMessage, sender, msg)
    if not ok then
        receiveErrors = receiveErrors + 1
        if receiveErrors <= 3 then
            Log('receive error: ' .. tostring(err))
        end
    end
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

--- Work out where the local mouse is and what it's doing.
---@return table
local function ReadLocalState()
    local state = {
        overWorld = false,
        zoom = 0,
        hudX = 0.5,
        hudY = 0.9,
    }

    local screen = GetMouseScreenPos()
    if not screen or not screen[1] then
        return state
    end

    local view = WorldViewManager.GetTopmostWorldViewAt(screen[1], screen[2])

    -- The minimap is registered as a world view, but pointing at it is HUD
    -- activity and GetMouseWorldPos is not meaningful over it.
    if view and view._cameraName ~= 'MiniMap' and view.CursorOverWorld then
        state.overWorld = true
        local camera = GetCamera(view._cameraName)
        if camera then
            state.zoom = camera:GetZoom()
        end
    end

    if not state.overWorld then
        local frame = GetFrame(0)
        if frame then
            local w = frame.Width()
            local h = frame.Height()
            if w > 0 and h > 0 then
                state.hudX = screen[1] / w
                state.hudY = screen[2] / h
                if state.hudX < 0 then state.hudX = 0 end
                if state.hudX > 1 then state.hudX = 1 end
                if state.hudY < 0 then state.hudY = 0 end
                if state.hudY > 1 then state.hudY = 1 end
            end
        end
    end

    return state
end

--- Cheap safety net: gamemain.SetLayout reaches world view recreation through
--- borders.SetLayout, and our hook covers that, but anything else that swaps a
--- view out would leave cursors parented to a dead control until the next
--- layout change. Comparing two or three table identities ten times a second
--- costs nothing and makes the whole thing self-healing.
VerifyViews = function()
    local views = WorldViewManager.GetWorldViews()

    for viewKey, view in pairs(views) do
        if viewKey ~= 'MiniMap' and view and knownViews[viewKey] ~= view then
            Debug('world view ' .. tostring(viewKey) .. ' changed, resyncing')
            SyncViews()
            return
        end
    end

    for viewKey, _ in pairs(knownViews) do
        if not views[viewKey] then
            Debug('world view ' .. tostring(viewKey) .. ' gone, resyncing')
            SyncViews()
            return
        end
    end

    if not frameDriver then
        CreateFrameDriver()
    end
end

function OnBeat()
    if not initialised then
        return
    end

    -- Observers and replay viewers still need this, even though they never
    -- transmit -- they have cursors to keep parented to live views.
    local viewsOk, viewsErr = pcall(VerifyViews)
    if not viewsOk then
        Log('view check error: ' .. tostring(viewsErr))
    end

    if isObserver or isReplay then
        return
    end

    local ok, err = pcall(function()
        local now = GetSystemTimeSeconds()
        local state = ReadLocalState()

        -- Safety valve. The drag flag is cleared by ButtonRelease, but that
        -- event can be consumed before it reaches our hook -- by a dialog
        -- opening over the view, for instance. Without this the selection ring
        -- would stay on a teammate's screen indefinitely, and the streaming
        -- send path would never go quiet again.
        if localSelecting then
            if (now - selectingSince) > Config.Selection.MaxDragSeconds
                or not state.overWorld then
                localSelecting = false
            end
        end

        -- Position: while on the HUD we keep sending the last place we were
        -- genuinely over the world, so teammates see where we were working
        -- rather than a stale projection under their interface.
        local x, y, z
        if state.overWorld then
            local mouse = GetMouseWorldPos()
            -- Validate all three components. The engine can hand back a
            -- partially populated vector during camera transitions, and a NaN
            -- sent from here would propagate into every teammate's
            -- interpolation and out into their layout.
            if IsFiniteVector(mouse) then
                local p = 10
                if Config.Network.PositionPrecision == 0 then p = 1 end
                x = MathFloor(mouse[1] * p + 0.5) / p
                y = MathFloor(mouse[2] * p + 0.5) / p
                z = MathFloor(mouse[3] * p + 0.5) / p
                lastWorldPos[1], lastWorldPos[2], lastWorldPos[3] = x, y, z
                haveWorldPos = true
            end
        end

        if not x then
            if not haveWorldPos then
                return
            end
            x, y, z = lastWorldPos[1], lastWorldPos[2], lastWorldPos[3]
        end

        -- Zoom is only meaningful while the mouse is over a world view. Hold
        -- the last real value rather than sending zero, so a teammate's
        -- cursor does not snap back to unit scale every time they dip into
        -- their interface.
        if state.zoom > 0 then
            lastWorldZoom = state.zoom
        end

        local orderIndex = CursorData.IndexFromKey(cursor and cursor.sharedMouseOrder)

        -- Build mode: send the blueprint currently on the cursor.
        local buildId = false
        if Config.Build.Enabled then
            local mode, data = unpack(CommandMode.GetCommandMode())
            if mode == 'build' and data and data.name then
                buildId = data.name
            end
        end

        ------------------------------------------------------------------
        -- Should we send?
        ------------------------------------------------------------------
        local dx = x - lastSent[1]
        local dy = y - lastSent[2]
        local dz = z - lastSent[3]
        local moved = (dx * dx + dy * dy + dz * dz) >
            (Config.Network.MinMoveDistance * Config.Network.MinMoveDistance)

        local onHud = not state.overWorld

        local changed = moved
            or orderIndex ~= lastSentOrder
            or onHud ~= lastSentHud
            or localSelecting ~= lastSentSelecting
            -- Keep streaming throughout a drag so the selection stays live
            -- on the other end rather than updating once per second.
            or localSelecting
            or (now - lastSentTime) >= Config.Network.ForceResendInterval

        if not changed then
            return
        end

        lastSent[1], lastSent[2], lastSent[3] = x, y, z
        lastSentOrder = orderIndex
        lastSentHud = onHud
        lastSentSelecting = localSelecting
        lastSentTime = now

        ------------------------------------------------------------------
        -- Transmit
        ------------------------------------------------------------------
        if TableGetN(recipients) > 0 then
            outgoing.a = myArmy
            outgoing.p[1] = x
            outgoing.p[2] = y
            outgoing.p[3] = z
            outgoing.o = orderIndex
            outgoing.z = MathFloor(lastWorldZoom + 0.5)
            outgoing.w = state.overWorld
            outgoing.s = localSelecting
            outgoing.b = buildId
            outgoing.hx = MathFloor(state.hudX * 1000 + 0.5) / 1000
            outgoing.hy = MathFloor(state.hudY * 1000 + 0.5) / 1000

            SessionSendChatMessage(recipients, outgoing)
        end

        ------------------------------------------------------------------
        -- Optional: smuggle the position into the replay
        ------------------------------------------------------------------
        if Config.ReplayCodec.Enabled and Config.ReplayCodec.Write then
            ReplayCodec.WriteToCommander({ x, z, orderIndex }, now)
        end
    end)

    if not ok then
        Log('send error: ' .. tostring(err))
    end
end

--------------------------------------------------------------------------------
-- Frame driver
--------------------------------------------------------------------------------

--- Scratch tables reused every frame.
local viewInfo = {
    left = 0, top = 0, right = 0, bottom = 0,
    zoom = 0, mouseX = false, mouseY = false, hidden = false,
}

local function UpdateFrame(delta)
    local now = GetSystemTimeSeconds()

    local mouseX, mouseY = false, false
    local screen = GetMouseScreenPos()
    if screen and screen[1] then
        mouseX = screen[1]
        mouseY = screen[2]
    end

    -- Advance every peer's interpolated position and crossfade.
    local fadeStep = Config.Smoothing.FadeSpeed * delta
    if fadeStep > 1 then fadeStep = 1 end

    for _, record in pairs(peers) do
        if record.hasData then
            Interpolate(record, now)
            record.fade = record.fade + (1 - record.fade) * fadeStep
        end
    end

    -- Then place the visuals, reading each view's state exactly once.
    local views = WorldViewManager.GetWorldViews()
    for viewKey, view in pairs(views) do
        if viewKey ~= 'MiniMap' and view then
            local hidden = view:IsHidden()

            viewInfo.hidden = hidden
            if not hidden then
                viewInfo.left = view.Left()
                viewInfo.top = view.Top()
                viewInfo.right = view.Right()
                viewInfo.bottom = view.Bottom()
                viewInfo.mouseX = mouseX
                viewInfo.mouseY = mouseY

                viewInfo.zoom = 0
                local camera = GetCamera(view._cameraName)
                if camera then
                    viewInfo.zoom = camera:GetZoom()
                end
            end

            for _, record in pairs(peers) do
                local visual = record.visuals[viewKey]
                -- The identity check closes the window between the engine
                -- replacing a view and the next beat calling SyncViews. Without
                -- it, a visual can spend up to a tenth of a second projecting
                -- against a control that has already been destroyed.
                if visual and visual.view == view then
                    visual:UpdateFrame(viewInfo, now)
                end
            end
        end
    end
end

--- Control that exists solely to receive OnFrame. Parented to the root frame
--- so it survives layout changes.
---
--- Deliberately NOT hidden. A Group with no children draws nothing anyway, and
--- the base game's own reclaim code manages frame updates through OnHide --
--- SetNeedsFrameUpdate(not hidden) -- which means hiding a control is entangled
--- with whether it ticks. Leaving it visible-but-empty sidesteps that.
CreateFrameDriver = function()
    if frameDriver then
        return
    end

    local frame = GetFrame(0)
    if not frame then
        return
    end

    frameDriver = Group(frame, 'SharedMouseDriver')
    frameDriver.Width:Set(1)
    frameDriver.Height:Set(1)
    frameDriver:DisableHitTest(true)

    frameDriver.OnFrame = function(self, delta)
        local ok, err = pcall(UpdateFrame, delta)
        if not ok then
            -- Keep running. A fault here is nearly always transient -- a view
            -- being torn down mid-frame, say -- and disabling the callback
            -- would silently kill the mod for the rest of the session with no
            -- way back. Rate limit the log instead.
            frameErrors = frameErrors + 1
            local now = GetSystemTimeSeconds()
            if frameErrors <= 5 or (now - lastFrameErrorLog) > 10 then
                lastFrameErrorLog = now
                Log('frame error (' .. tostring(frameErrors) .. '): ' .. tostring(err))
            end
        end
    end

    frameDriver:SetNeedsFrameUpdate(true)
end

--------------------------------------------------------------------------------
-- View management
--------------------------------------------------------------------------------

--- Watch a world view's events so we know when the local player is dragging a
--- selection box. Idempotent: views are recreated on layout changes and
--- SyncViews re-runs over them.
---@param view WorldView
local function HookViewEvents(view)
    if not Config.Selection.Enabled or isObserver or isReplay then
        return
    end

    -- Marked on the view itself rather than in a module-level table. Views are
    -- destroyed and recreated on every layout change, and a table keyed by the
    -- control would keep dead ones reachable for the rest of the session.
    if view._sharedMouseHooked then
        return
    end
    view._sharedMouseHooked = true

    local originalHandleEvent = view.HandleEvent
    view.HandleEvent = function(self, event)
        -- Never let a fault in here swallow the event: this sits in front of
        -- the game's own camera and order handling.
        pcall(function()
            if event.Type == 'ButtonPress' then
                -- Only a plain left press over the world is a selection drag.
                -- A press in command mode is issuing an order.
                if event.Modifiers and event.Modifiers.Left
                    and not CommandMode.InCommandMode() then
                    localSelecting = true
                    selectingSince = GetSystemTimeSeconds()
                end
            elseif event.Type == 'ButtonRelease' or event.Type == 'MouseExit' then
                localSelecting = false
            end
        end)

        return originalHandleEvent(self, event)
    end
end

--- Create and destroy visuals so that every peer has exactly one cursor in
--- every live world view.
---
--- The previous version returned from inside the inner loop, so only the first
--- view of the first player was ever handled -- that is the splitscreen bug.
--- It also keyed only on presence, so when the engine destroyed and recreated
--- viewLeft on a layout change the old visual survived pointing at a dead
--- parent.
function SyncViews()
    if not initialised then
        return
    end

    local ok, err = pcall(function()
        local views = WorldViewManager.GetWorldViews()

        -- Retire visuals whose view is gone or has been replaced.
        for viewKey, cachedView in pairs(knownViews) do
            local current = views[viewKey]
            if current ~= cachedView then
                for _, record in pairs(peers) do
                    local visual = record.visuals[viewKey]
                    if visual then
                        visual:Destroy()
                        record.visuals[viewKey] = nil
                    end
                end
                knownViews[viewKey] = nil
            end
        end

        -- Create what's missing.
        for viewKey, view in pairs(views) do
            if viewKey ~= 'MiniMap' and view then
                knownViews[viewKey] = view
                HookViewEvents(view)

                for _, record in pairs(peers) do
                    if not record.visuals[viewKey] then
                        record.visuals[viewKey] = RemoteCursor(view, record)
                    end
                end
            end
        end

        CreateFrameDriver()
    end)

    if not ok then
        Log('SyncViews error: ' .. tostring(err))
    end
end

--------------------------------------------------------------------------------
-- Cursor order tracking
--------------------------------------------------------------------------------

--- Wrap the local cursor so we know which order icon the game is showing, and
--- can tell teammates about it.
local function HookCursor()
    cursor = GetCursor()
    if not cursor then
        Log('no cursor available, order icons disabled')
        return
    end

    cursor.sharedMouseOrder = 'selectable'

    local originalSetTexture = cursor.SetTexture
    cursor.SetTexture = function(self, filename, hotspotX, hotspotY, numFrames, fps)
        originalSetTexture(self, filename, hotspotX, hotspotY, numFrames, fps)
        self.sharedMouseOrder = CursorData.KeyFromTexture(filename) or 'selectable'
    end

    local originalReset = cursor.Reset
    cursor.Reset = function(self)
        originalReset(self)
        self.sharedMouseOrder = 'selectable'
    end
end

--------------------------------------------------------------------------------
-- Replay playback
--------------------------------------------------------------------------------

local replayThread = false

--- During replay playback there is no live chat traffic, so the only source of
--- mouse data is whatever was encoded into commander names at record time.
--- Coverage is partial by nature; see the notes in config.lua.
local function StartReplayPlayback()
    if replayThread then
        return
    end

    replayThread = ForkThread(function()
        while true do
            local ok, err = pcall(function()
                local now = GetSystemTimeSeconds()
                for army, record in pairs(peersByArmy) do
                    local values = ReplayCodec.ReadFromCommander(army)
                    if values and values[1] and values[2] then
                        PushSample(record, values[1], 0, values[2], now)
                        record.lastUpdate = now
                        record.orderIndex = values[3] or 0
                        record.onHud = false
                        if not record.hasData then
                            record.render[1] = values[1]
                            record.render[2] = 0
                            record.render[3] = values[2]
                            record.hasData = true
                        end
                    end
                end
            end)

            if not ok then
                Log('replay playback error: ' .. tostring(err))
            end

            WaitSeconds(Config.ReplayCodec.PollInterval)
        end
    end)
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

--- Find our own account name. Reading it from the armies table breaks for
--- observers, whose focus army is -1, and the "show player names" option can
--- rewrite nicknames in that table anyway. The session client list carries a
--- 'local' flag, which is what the base game's own casting code uses.
---@param clients table
---@return string
local function FindLocalName(clients)
    for _, client in pairs(clients) do
        if client['local'] then
            return client.name
        end
    end
    return ''
end

---@param replay boolean
function InitSharedMouse(replay)
    if initialised then
        return
    end

    local ok, err = pcall(function()
        isReplay = replay and true or false

        local armiesInfo = GetArmiesTable()
        local armies = armiesInfo.armiesTable
        local clients = GetSessionClients()

        myArmy = GetFocusArmy()
        isObserver = (myArmy == nil or myArmy < 1)
        myName = FindLocalName(clients)

        ------------------------------------------------------------------
        -- Who can we see?
        ------------------------------------------------------------------
        -- Players see allies. Observers and replay viewers see everyone.
        for index, army in pairs(armies) do
            if army.human and army.nickname ~= myName then
                local visible = isObserver or isReplay or IsAlly(myArmy, index)
                if visible then
                    local record = CreateRecord(army.nickname, index, army.color)
                    peers[army.nickname] = record
                    peersByArmy[index] = record
                end
            end
        end

        ------------------------------------------------------------------
        -- Who do we transmit to?
        ------------------------------------------------------------------
        -- A dense array: SessionSendChatMessage takes number | number[], and
        -- the previous version built a sparse table by assigning
        -- validClients[index] = index while skipping enemies.
        if not isObserver and not isReplay then
            -- Map nicknames to army indices so a client can be resolved by
            -- name as well as by position.
            local armyByName = {}
            for index, army in pairs(armies) do
                if army.nickname then
                    armyByName[army.nickname] = index
                end
            end

            for index, client in ipairs(clients) do
                if client.name ~= myName then
                    -- Two independent ways to work out whether this client is
                    -- an opponent, and a client is excluded if EITHER says so.
                    --
                    -- Client index usually equals army index -- the base game's
                    -- own overrides assume it -- but AI and civilian armies can
                    -- push the two out of step, and the "show player names"
                    -- option can rewrite nicknames on one side. Being
                    -- conservative here costs at worst a missing cursor for an
                    -- observer; being wrong the other way leaks mouse position
                    -- to the enemy team.
                    local hostile = false

                    local byIndex = armies[index]
                    if byIndex and byIndex.human and not IsAlly(myArmy, index) then
                        hostile = true
                    end

                    local namedArmy = armyByName[client.name]
                    if namedArmy and armies[namedArmy].human
                        and not IsAlly(myArmy, namedArmy) then
                        hostile = true
                    end

                    -- A client matching no army at all is an observer.
                    local isSpectator = (not byIndex or not byIndex.human)
                        and not namedArmy
                    if isSpectator and not Config.Network.ShareWithObservers then
                        hostile = true
                    end

                    if not hostile then
                        table.insert(recipients, index)
                    end
                end
            end
        end

        Debug('army ' .. tostring(myArmy) .. ', observer=' .. tostring(isObserver)
            .. ', peers=' .. tostring(table.getsize(peers))
            .. ', recipients=' .. tostring(TableGetN(recipients)))

        ------------------------------------------------------------------
        -- Wire it up
        ------------------------------------------------------------------
        -- RegisterChatFunc lives in the gamemain module table, not in _G.
        -- Calling it bare -- as the previous version did from this file --
        -- resolves to nil and throws.
        import('/lua/ui/game/gamemain.lua').RegisterChatFunc(OnReceive, Config.ChatIdentifier)

        if not isReplay then
            HookCursor()
        end

        initialised = true
        SyncViews()

        if isReplay and Config.ReplayCodec.Enabled and Config.ReplayCodec.Read then
            StartReplayPlayback()
        end

        if isReplay then
            Log('replay session; live sharing unavailable, replay codec '
                .. (Config.ReplayCodec.Enabled and 'enabled' or 'disabled'))
        elseif isObserver then
            Log('observing; receiving from all players')
        elseif TableGetN(recipients) == 0 then
            Log('no teammates to share with; still receiving')
        end
    end)

    if not ok then
        Log('init failed: ' .. tostring(err))
    end
end

--------------------------------------------------------------------------------
-- Teardown
--------------------------------------------------------------------------------

function Destroy()
    initialised = false

    if replayThread then
        KillThread(replayThread)
        replayThread = false
    end

    if frameDriver then
        frameDriver:SetNeedsFrameUpdate(false)
        frameDriver:Destroy()
        frameDriver = false
    end

    for _, record in pairs(peers) do
        for viewKey, visual in pairs(record.visuals) do
            visual:Destroy()
            record.visuals[viewKey] = nil
        end
    end

    peers = {}
    peersByArmy = {}
    recipients = {}
    knownViews = {}

    lastSent[1], lastSent[2], lastSent[3] = 0, 0, 0
    lastSentOrder = -1
    lastSentTime = 0
    lastSentHud = false
    lastSentSelecting = false
    localSelecting = false
    haveWorldPos = false
    lastWorldZoom = 0
    frameErrors = 0
    receiveErrors = 0
end
