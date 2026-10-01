--******************************************************************************
--** TeamMouse -- modules/teammouse.lua
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
--**   teammouse.lua  this file: session setup, send, receive, view sync
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

local Config = import(_G.TeamMousePath .. '/modules/config.lua')
local CursorData = import(_G.TeamMousePath .. '/modules/cursordata.lua')
local LegacyProtocol = import(_G.TeamMousePath .. '/modules/legacyprotocol.lua')
local RemoteCursor = import(_G.TeamMousePath .. '/modules/remotecursor.lua').RemoteCursor
local ReplayCodec = import(_G.TeamMousePath .. '/modules/replaycodec.lua')
local Actions = import(_G.TeamMousePath .. '/modules/actions.lua')
local Panel = import(_G.TeamMousePath .. '/modules/panel.lua')
local Version = import(_G.TeamMousePath .. '/modules/version.lua')
local WirePack = import(_G.TeamMousePath .. '/modules/wirepack.lua')
local WireCodec = import(_G.TeamMousePath .. '/modules/wirecodec.lua')


local WorldViewManager = import('/lua/ui/game/worldview.lua')
local CommandMode = import('/lua/ui/game/commandmode.lua')
local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')

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
local localMouse = { x = false, y = false, overWorld = false, view = false, pendingHud = false,
    cellX = false, cellY = false }

--- Set by the world view event hook while a selection box is being dragged.
local localSelecting = false
local selectingSince = 0

--- World position captured synchronously at the instant of ButtonPress, or
--- false. See the note above OnBeat's use of it for why this exists: without
--- it, the anchor sent for a drag isn't the true press point, but whatever
--- GetMouseWorldPos happens to read on the first beat or two after the press,
--- while the engine's own freeze is still catching up to a real drag already
--- in motion -- worse the faster the drag starts.
local pinnedAnchor = false

--- Last position we were genuinely over the world, reused while the local
--- mouse is on the HUD so peers see where we were last working.
---
--- Kept in one table rather than three locals on purpose: Lua 5.0 allows a
--- function at most 32 upvalues, and OnBeat has to carry every module-level
--- local that it or anything nested in it touches. Related state is bundled to
--- stay well clear of that. The engine reports "too many upvalues" at load
--- time and the whole mod fails to start.
local worldHold = { pos = { 0, 0, 0 }, have = false, zoom = 0 }

--- Send-loop state.
--- Bundled for the same upvalue-limit reason as worldHold above.
local sendState = {
    pos = { 0, 0, 0 },
    order = -1,
    time = 0,
    hud = false,
    hudX = -1,
    hudY = -1,

    -- True while the drag in progress is a structure line (a drag made in
    -- build mode) rather than a selection box. Both share localSelecting and
    -- everything that tracks it; this only says which one to report.
    line = false,

    -- The state flags in the last packet sent; a change is worth a packet.
    flags = 0,

    -- True for a left drag that is tracked but is not a selection box
    -- (dragging a waypoint). Reported as the pointer travelling and nothing
    -- more.
    plain = false,

    -- The blueprint on the cursor when a build drag began, or false.
    buildBp = false,

    -- When the send logic last ran, from the beat or from the frame driver.
    lastRun = 0,

    -- Zoom as last sent, and when (it is only sent on change).
    sentZoom = -1,
    zoomT = 0,

    -- SharedMouse, on demand. legacyTo: client indices of teammates seen
    -- sending SharedMouse packets and never TeamMouse ones (a dense array, as
    -- SessionSendChatMessage wants). clientByName: name -> client index.
    -- tmSeen / smSeen: names seen sending each.
    legacyTo = {},
    clientByName = {},
    tmSeen = {},
    smSeen = {},

    -- Actions (Stop, repeat build, pause: see actions.lua) waiting for the
    -- next packet, as codes; explicit count, as everywhere else.
    acts = {},
    actCount = 0,

    -- The order being moved, as a cursor index, while a waypoint is dragged
    -- (0 when not known).
    grabKind = 0,

    -- True while the left drag in progress is moving a waypoint (an order
    -- already given). The game's cursor flickers between the hand and the
    -- arrow while it does; the hand is what is reported, throughout.
    waypoint = false,

    -- Right-click orders waiting for the next packet, oldest first, as an
    -- explicit-count array of { kind, x, y, z, x2, z2 } slots (never
    -- table.insert / table.remove; see the note above PushSample).
    ord = {},
    ordCount = 0,

    -- When the drag overlay's geometry was last compared with its view's.
    gridCheck = 0,

    -- Every packet also goes into the replay (ReplayCodec.Record); set once
    -- the session knows whether the codec is on.
    recording = false,

    -- Clicks that selected something, since the last packet (NoteClick); the
    -- last click still waiting for the selection to change, and the last
    -- change of selection still waiting for a click.
    clicks = 0,
    clickT = false,
    clickPressed = false,
    selChangedT = false,

    -- Structures we selected recently, watched for starting an upgrade
    -- however it was ordered (CheckUpgrades): entity id -> { unit, t, announced }.
    watch = {},
    watchCount = 0,

    -- Our selection's unit ids (NoteSelection), whether it changed since it
    -- was last sent, and when that was; whether it is being watched, and
    -- whether by polling.
    sel = {},
    selKey = '',
    -- The selected units' sizes, and where they were when selected, packed
    -- (NoteSelection).
    selSizes = {},
    selPlaces = '',
    -- More selected than MaxSend: rectangles round the bunches (SelectionRects).
    selRects = false,
    -- Where the left drag in progress began (DragStillNear).
    dragX = 0,
    dragY = 0,
    -- The order cursor as last sent (o), and when.
    sentOrder = -1,
    orderT = 0,
    selDue = false,
    selT = false,
    selWatch = false,
    selPoll = false,

    -- Recipients who are observers, not teammates: they also get our camera,
    -- to follow it (Config.Follow). teamTo is everyone else.
    teamTo = {},
    specTo = {},
    -- The same, less anyone who has hidden our cursor (they told us: tmo).
    teamLive = {},
    specLive = {},
    -- Client indices that have hidden our cursor, and every other client
    -- (by name too), for telling a player we hid theirs.
    muted = {},
    everyone = {},
    clientIndex = {},

    -- Our view's outline as last sent, and when (false: never).
    vpSent = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    camSent = { 0, 0, 0, 0, 0, 0 },
    vpT = false,
    vpCornerX = { 0, 0, 0, 0 },
    vpCornerY = { 0, 0, 0, 0 },

    -- The left press in progress: where it was, and whether the tracking grid
    -- is up for it (see RaiseGridForDrag).
    pressX = 0,
    pressY = 0,
    gridUp = false,

    -- The compact wire format (wirecodec.lua). compact: client index -> true
    -- for a client that has said it reads it (tmc) or sent it; everyone else
    -- gets the plain table. hello: client index -> { n, t }, our own word
    -- said again to someone still sending us plain tables. The live lists
    -- split by format, and both kinds of recipient together (one send when
    -- teammates and observers get the same packet). compactOut: the message
    -- the string goes in, reused.
    compact = {},
    hello = {},
    compactStarted = false,

    -- What ReadLocalState fills in for each beat, reused.
    state = {},
    teamC = {}, teamP = {}, specC = {}, specP = {}, allC = {}, allP = {},
    compactOut = {},
}

--- Samples of the local pointer taken between beats, waiting to ride along
--- with the next packet. Explicit count and direct indexing, same discipline
--- as the receive buffer. active is decided once at startup.
local sampleBuf = { active = false, count = 0, lastT = 0, slots = {}, packList = {}, state = {} }

--- The right mouse button, which the drag overlay must stay out of the way of
--- and which is how a player orders their units around.
---   press      a right press is open and its release has not been seen
---   suspended  the drag overlays are hidden for the length of it
---   since      when it began, for the backstop
---   inMode     a command mode was active at the press (a right click then
---              cancels the mode rather than ordering anything)
---   hasSel     units were selected at the press
---   kind       cursor order index at the press: what the click will do
---   sx, sy, sz world point under the pointer at the press
---   startOk    sx..sz are real
local rightClick = {
    press = false, suspended = false, since = 0,
    inMode = false, hasSel = false, kind = 0,
    sx = 0, sy = 0, sz = 0, startOk = false,

    -- live: a right press is open and being streamed as a drag, whatever it
    -- turns out to be (an order, a drawing, or nothing). Like a left drag it
    -- pins the reported position to the press point and reports the pointer
    -- as the far end. order: it is (or may become) an order with a line:
    -- something is selected and there's no command mode to cancel instead.
    live = false,
    order = false,
    -- drawing: nothing selected and no command mode, so the press is a drawing.
    drawing = false,
    -- view: the world view it was pressed on. grid: the tracking grid stayed
    -- up for it, so the pointer can be read from the grid.
    view = false,
    grid = false,
    -- Cell crossings the grid reported during the press (Config.Debug only).
    cellEvents = 0,

    -- Motion events during the press that said the right button was held
    -- (Debug log only).
    heldEvents = 0,

    -- A middle-button drag (panning the camera) is under way; the grid is
    -- lifted for it, as for an order: a grid cell crossed mid-pan ends it.
    middle = false,

    -- Motion events that reached the view during the press (Debug log only).
    motionEvents = 0,

    -- Orders get a sequence number, so "this one has reached the sim" can be
    -- said about one order and not the next. pendSeq is the order awaiting
    -- that (0 for none), pendSince when it was given, pendSig what the first
    -- selected unit's command queue looked like before it, sig0 the same taken
    -- at the press. appliedOut is a sequence number waiting for the next packet.
    seq = 0,
    pendSeq = 0, pendSince = 0, pendSig = false, sig0 = false,
    appliedOut = 0,
}

--- A build-mode left press, and whether the game really placed anything for it.
--- The game calls commandmode.OnCommandIssued once per structure it actually
--- orders (see hook/lua/ui/game/commandmode.lua); a placement it refuses
--- issues nothing. So a build is only announced once its orders are seen.
---   armed      a build press is open: orders from now on belong to it
---   pending    released; waiting (up to BuildConfirmTimeout) for its orders
---   relT       when it was released
---   bp, ax..   the drag's own blueprint and ends, for when the hook is absent
---   n          BuildMobile orders seen since the press
---   fx..       the first one's position, lx/lz the last one's, cbp its blueprint
---   lastT      when the last one came
---   seen       the hook has passed us any command at all this session: until
---              then, silence proves nothing, and the old behaviour stands
local buildWatch = {
    armed = false, pending = false, relT = 0,
    bp = false, ax = 0, ay = 0, az = 0, ex = 0, ez = 0,
    n = 0, fx = 0, fy = 0, fz = 0, lx = 0, lz = 0, cbp = false, lastT = 0,
    seen = false,
}

--- Defined with the right-button handling below; declared here so the
--- beat-time backstop, which comes first, can reach it.
local EndMiddle

--- Smallest pointer movement on the HUD that is worth a packet, as a fraction
--- of the screen (about 4px at 1080p).
local HUD_MIN_MOVE = 0.002

--- Reused to avoid allocating a table per send.
--- The packet, reused. Only the first five fields are always there; every
--- other field is left out (nil) when it has nothing to say, and the receiver
--- reads a missing field as its default -- every key and value costs bytes on
--- every packet, to every teammate. See engine-gotchas.md, "Wire format".
local outgoing = {
    Identifier = Config.ChatIdentifier,
    v = Config.Protocol,
    a = 0,
    p = { 0, 0, 0 },
    o = 0,
}

local legacyOutgoing = LegacyProtocol.CreatePacket(Config.Protocol)

--- Forward declarations. These are referenced by functions defined earlier in
--- the file than their own bodies.
local CreateFrameDriver
local VerifyViews
local CheckSelection
local CheckUpgrades
local CountClick
local NoteClickMove

local function Log(msg)
    LOG('TeamMouse: ' .. tostring(msg))
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
-- Per-sample state flags
--------------------------------------------------------------------------------
-- What a player was doing when a sample was taken, packed into one number so an
-- extra sample costs one more value and not four. Lua 5.0 has no bit operations;
-- these are plain powers of two, taken apart with floor and subtraction.

local FLAG_HUD = 1     -- pointer on their own interface
local FLAG_BOX = 2     -- dragging a selection box
local FLAG_LINE = 4    -- dragging a line of structures
local FLAG_ORDER = 8   -- right-dragging an order (a formation)
local FLAG_DRAW = 16   -- right button held with nothing selected: drawing
local FLAG_FOLLOW = 32   -- dragging something with no shape to show: the pointer just travels

--- Whether bit `bit` (a power of two) is set in `f`.
---@param f number
---@param bit number
---@return boolean
local function HasFlag(f, bit)
    return math.mod(math.floor(f / bit), 2) == 1
end

--- Take a flags number apart. At most one drag kind is ever set; if a
--- malformed number claims several, the first in this order wins.
---@param f number
---@return boolean, number   # onHud, drag kind (0 none, 1 box, 2 line, 3 order, 4 draw, 5 follow)
local function DecodeFlags(f)
    f = math.floor(f)
    local drag = 0
    if HasFlag(f, FLAG_BOX) then drag = 1
    elseif HasFlag(f, FLAG_LINE) then drag = 2
    elseif HasFlag(f, FLAG_ORDER) then drag = 3
    elseif HasFlag(f, FLAG_DRAW) then drag = 4
    elseif HasFlag(f, FLAG_FOLLOW) then drag = 5 end
    return HasFlag(f, FLAG_HUD), drag
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
        buildId = false,
        buildTemplate = false,   -- the build in hand is a template (msg.bt)
        vp = false,              -- their view's outline, 4 corners of x/y/z (msg.vp)
        cam = false,             -- their camera: focus x/y/z, heading, pitch, zoom (msg.cam)
        camIn = {},              -- scratch for reading one in
        follow = false,          -- replays: the viewer's camera follows theirs (panel)
        sel = {},                -- their selected units' ids (msg.sel)
        selText = false,         -- ...as it came, to tell a repeat from a change
        selT = 0,                -- when it last changed (live boxes fade from then)
        selSize = {},            -- and sizes (msg.ss), world units
        selPos = {},             -- and positions (msg.sq): { x, y, z, ok }
        selRects = {},           -- or, past MaxSend, rectangles (msg.sr): { x1, z1, x2, z2, y }
        selVersion = 0,          -- goes up each time sel is replaced
        pulses = {},             -- click pulses: { t, x, y, z } each (msg.ck)
        pulseNext = 1,
        showView = Config.Viewport.Show and true or false,   -- panel's "view" box
        vpIn = {},               -- scratch for reading one in

        -- What they were doing at the moment being drawn (now minus the
        -- interpolation delay), read from the samples by Interpolate. Position
        -- is drawn in the past, so every piece of state that decides HOW to
        -- draw it has to come from the same moment, or the two disagree for
        -- a tenth of a second at every transition: the arrow dropping back to
        -- a drag's anchor while the position is still sliding from it, a HUD
        -- panel appearing before the pointer it belongs to got there.
        --   renderHud   on their interface
        --   renderDrag  0 none, 1 selection box, 2 structure line, 3 order line
        renderHud = false,
        renderDrag = 0,

        -- Right-click orders they have issued, newest last, valid for
        -- 1..orderCount. Expired ones are swapped to the end and dropped from
        -- the count, so their slot tables are reused rather than reallocated.
        orders = {},
        orderCount = 0,

        -- The order they are dragging around, as a cursor index, or 0.
        grabKind = 0,

        -- The last action they took (see actions.lua) and when to show it.
        actCode = 0,
        actT = 0,

        -- Interpolated position of their pointer on their own screen, 0..1,
        -- advanced every frame alongside `render`. Fed from the same sample
        -- buffer so the HUD ghost moves at frame rate, not at the packet rate.
        hudRender = { 0.5, 0.9 },
        -- Interpolated world X/Z of the drag box's live corner, advanced
        -- alongside render/hudRender. Only meaningful during a drag.
        boxRender = { 0, 0 },

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
---@param hx? number   # pointer on their own screen, 0..1; defaults to bottom-centre
---@param hy? number
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
---@param record table
---@param x number
---@param y number
---@param z number
---@param now number
---@param hx number
---@param hy number
---@param bx? number
---@param bz? number
---@param flags? number   # FLAG_HUD + FLAG_BOX / FLAG_LINE / FLAG_ORDER; see DecodeFlags
local function PushSample(record, x, y, z, now, hx, hy, bx, bz, flags)
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

    local prev = false
    if count > 0 then
        prev = samples[count]
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
    slot.hx = hx or 0.5
    slot.hy = hy or 0.9
    -- No box in progress: collapse to the pointer's own position, so an
    -- interpolation spanning the start or end of a drag doesn't sweep the box
    -- toward the world origin.
    slot.bx = bx or x
    slot.bz = bz or z

    local hud, drag = DecodeFlags(flags or 0)
    slot.hud = hud
    slot.drag = drag

    -- Discontinuities. Interpolating across one draws the thing sliding
    -- through places it never was, so the samples say where the interpolation
    -- must not go: it holds the earlier sample until this one's own time and
    -- then steps.
    --   hudSnap  the HUD image steps. Entering the interface (its old spot was
    --            a placeholder, or wherever they last were), or moving the
    --            pointer to somewhere far from where it just was.
    --   posSnap  the position steps. After a drag: the position field meant
    --            "where the drag began" throughout it and means "where the
    --            pointer is" from here on, and the two are not a movement.
    --            Also for a far jump across the interface.
    slot.hudSnap = false
    slot.posSnap = false
    if prev then
        if hud and not prev.hud then
            slot.hudSnap = true
        elseif hud and prev.hud then
            local ddx, ddy = slot.hx - prev.hx, slot.hy - prev.hy
            local jump = Config.Hud.JumpDistance
            if (ddx * ddx + ddy * ddy) > (jump * jump) then
                slot.hudSnap = true
                slot.posSnap = true
            end
        end
        -- Leaving the interface: this sample's interface coordinates are a
        -- placeholder (they mean nothing while the pointer is on the map), and
        -- the image must not slide toward them while the ghost is still on
        -- screen and about to fade.
        if prev.hud and not hud then
            slot.hudSnap = true
        end
        if prev.drag ~= 0 and drag == 0 then
            slot.posSnap = true
        end
    end

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

    local target = now - Config.Smoothing.InterpolationDelay

    -- Find the two samples bracketing the target time. Before the buffer
    -- starts, or with a single sample, hold the oldest. Past the end, hold the
    -- newest rather than extrapolating, which would overshoot on every change
    -- of direction.
    local a, b, f = samples[1], samples[1], 0

    if count > 1 and target > samples[1].t then
        local newest = samples[count]
        if target >= newest.t then
            a, b = newest, newest
        else
            -- From the newest end: the target is InterpolationDelay behind the
            -- clock, so its pair is among the last few of up to BufferSize.
            -- Times never decrease (PushSample and PushExtras only ever add
            -- later ones), so the last sample before the target and the one
            -- after it are exactly the first pair an oldest-first search
            -- finds -- equal times included.
            for i = count - 1, 1, -1 do
                local s0 = samples[i]
                if s0.t < target then
                    local s1 = samples[i + 1]
                    local span = s1.t - s0.t
                    if span > 0 then
                        f = (target - s0.t) / span
                    end
                    a, b = s0, s1
                    break
                end
            end
        end
    end

    -- A sample that begins a discontinuity is not interpolated toward: the
    -- earlier one is held until the moment of this one, then it steps. See
    -- PushSample.
    local fp, fh = f, f
    if b.posSnap then fp = 0 end
    if b.hudSnap then fh = 0 end

    local render = record.render
    render[1] = a.x + (b.x - a.x) * fp
    render[2] = a.y + (b.y - a.y) * fp
    render[3] = a.z + (b.z - a.z) * fp

    local hud = record.hudRender
    hud[1] = a.hx + (b.hx - a.hx) * fh
    hud[2] = a.hy + (b.hy - a.hy) * fh

    local box = record.boxRender
    box[1] = a.bx + (b.bx - a.bx) * f
    box[2] = a.bz + (b.bz - a.bz) * f

    -- State is a step, not a blend: whatever the earlier sample says holds
    -- until the later one's own time.
    record.renderHud = a.hud
    record.renderDrag = a.drag
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

--- Numbers per right-click order on the wire:
--- kind, x, y, z, endX, endZ, sequence number.
local ORDER_STRIDE = 7

--- Loosest age an extra sample may claim, whatever the sender's own limit is.
local EXTRA_MAX_AGE = 2.0

--- Place a packet's extra samples on the local timeline.
---
--- Each one says how long before the packet it was taken. The packet's own
--- arrival time stands in for the moment it was sent, so the two ends' clocks
--- never need to agree; steady latency cancels out, and jitter is what the
--- interpolation delay is there to absorb. Extras go in oldest first, ahead of
--- the packet's own sample, so the buffer stays in time order. Any that would
--- land at or before what is already buffered (a packet that overtook the one
--- before it, or latency that shrank) are dropped rather than reordered.
---@param record table
---@param e any        # msg.e off the wire; nothing about it is trusted
---@param now number   # arrival time of the packet
--- One extra sample (UnpackSamples' callback; made once, not per packet:
--- `ctx` carries the packet's record, arrival time and height).
local function PushExtra(age, x, z, hx, hy, bx, bz, flags, ctx)
    if age < 0.001 or age > EXTRA_MAX_AGE then
        return
    end
    local record = ctx.record
    local t = ctx.now - age
    local count = record.sampleCount
    if count == 0 or t > record.samples[count].t then
        PushSample(record, x, ctx.py, z, t, hx, hy, bx, bz, flags)
    end
end

--- PushExtras' context for PushExtra, reused.
local extraCtx = { record = false, now = 0, py = 0 }

local function PushExtras(record, e, now, px, py, pz)
    extraCtx.record, extraCtx.now, extraCtx.py = record, now, py
    WirePack.UnpackSamples(e, px, pz, Config.Network.ExtraSamples.MaxPerPacket, PushExtra, extraCtx)
    extraCtx.record = false
end

--- Record the right-click orders a packet announces.
---@param record table
---@param mo any       # msg.mo off the wire
---@param now number
---@param mob any      # msg.mob: the structure for each order that placed one
--- A packet's list of order places (mot, mou) as a set; false if none.
---@param list any
---@return table | false
local function IndexSet(list)
    local set = false
    if type(list) == 'table' then
        for j = 1, Config.Orders.MaxPerPacket do
            local k = list[j]
            if type(k) ~= 'number' then break end
            set = set or {}
            set[math.floor(k)] = true
        end
    end
    return set
end

local function AddRemoteOrders(record, mo, now, mob, mot, mou)
    if type(mo) ~= 'table' then
        return
    end

    -- Which orders (by their place in this packet) were templates, and which
    -- were upgrades.
    local templates = IndexSet(mot)
    local upgrades = IndexSet(mou)

    local orders = record.orders
    local capacity = Config.Orders.MaxMarkers
    if type(mob) ~= 'table' then
        mob = false
    end
    local i = 1
    for k = 1, Config.Orders.MaxPerPacket do
        if mo[i] == nil then
            break
        end

        local x = SafeNumber(mo[i + 1], nil, -100000, 100000)
        local y = SafeNumber(mo[i + 2], 0, -100000, 100000)
        local z = SafeNumber(mo[i + 3], nil, -100000, 100000)
        if x and z then
            local count = record.orderCount

            -- Full: the oldest marker makes way, its slot table reused.
            if count >= capacity then
                local evicted = orders[1]
                for j = 1, capacity - 1 do
                    orders[j] = orders[j + 1]
                end
                orders[capacity] = evicted
                count = capacity - 1
            end

            count = count + 1
            local slot = orders[count]
            if not slot then
                slot = {}
                orders[count] = slot
            end

            -- Starts when the samples it belongs with are drawn, not when it
            -- arrived: their release is drawn InterpolationDelay after it
            -- happened, and an order that showed first would be drawn ahead of
            -- the drag that made it.
            slot.t = now + Config.Smoothing.InterpolationDelay
            slot.kind = math.floor(SafeNumber(mo[i], 0, 0, 1000))
            slot.x, slot.y, slot.z = x, y, z
            slot.x2 = SafeNumber(mo[i + 4], x, -100000, 100000)
            slot.z2 = SafeNumber(mo[i + 5], z, -100000, 100000)
            slot.seq = math.floor(SafeNumber(mo[i + 6], 0, 0, 1e9))
            local bp = mob and mob[k]
            if type(bp) == 'string' and string.len(bp) > 0 and string.len(bp) < 64
                and string.find(bp, '^[%w_%-]+$') then
                slot.bp = bp
            else
                slot.bp = false
            end
            slot.template = (slot.bp and templates and templates[k]) and true or false
            slot.upgrade = (slot.bp and upgrades and upgrades[k]) and true or false
            slot.applied = false
            slot.appliedT = 0
            record.orderCount = count
        end

        i = i + ORDER_STRIDE
    end
end

--- The sender says orders up to this sequence number have reached the sim.
---@param record table
---@param upTo any     # msg.oa off the wire
---@param now number
local function MarkOrdersApplied(record, upTo, now)
    local seq = SafeNumber(upTo, 0, 0, 1e9)
    if seq <= 0 then
        return
    end
    for i = 1, record.orderCount do
        local order = record.orders[i]
        if order.seq > 0 and order.seq <= seq and not order.applied then
            order.applied = true
            order.appliedT = now + Config.Smoothing.InterpolationDelay
        end
    end
end

--- Rebuild the list of teammates the SharedMouse packet goes to.
local function RebuildLegacyTargets()
    local to = {}
    for name in pairs(sendState.smSeen) do
        local index = sendState.clientByName[name]
        if index then
            table.insert(to, index)
        end
    end
    table.sort(to)
    sendState.legacyTo = to
end

--- A packet in our own format came from this teammate: they need no
--- SharedMouse copy.
---@param sender string
local function NoteTeamMouse(sender)
    if sendState.tmSeen[sender] then
        return
    end
    sendState.tmSeen[sender] = true
    if sendState.smSeen[sender] then
        sendState.smSeen[sender] = nil
        RebuildLegacyTargets()
    end
end

--- Who our packets go to: teammates and observers, less those who have
--- hidden our cursor.
local function RebuildTargets()
    local muted = sendState.muted
    local function Without(list)
        local out = {}
        for _, index in ipairs(list) do
            if not muted[index] then
                table.insert(out, index)
            end
        end
        return out
    end
    sendState.teamLive = Without(sendState.teamTo)
    sendState.specLive = Without(sendState.specTo)

    -- By format: who reads the compact string, who still needs the table.
    local compact = sendState.compact
    local function Split(list, c, p)
        for _, index in ipairs(list) do
            if compact[index] then table.insert(c, index) else table.insert(p, index) end
        end
    end
    sendState.teamC, sendState.teamP, sendState.specC, sendState.specP = {}, {}, {}, {}
    Split(sendState.teamLive, sendState.teamC, sendState.teamP)
    Split(sendState.specLive, sendState.specC, sendState.specP)
    sendState.allC, sendState.allP = {}, {}
    Split(sendState.teamLive, sendState.allC, sendState.allP)
    Split(sendState.specLive, sendState.allC, sendState.allP)
end

--- Tell clients we read the compact wire format (wirecodec.lua), so they
--- send us that instead of the plain table. Once to everyone at the start;
--- again (a few times at most) to anyone whose plain tables keep coming,
--- since a word sent before their side was listening is lost.
---@param to number[]   # client indices
local function SayCompact(to)
    if table.getn(to) == 0 then
        return
    end
    pcall(SessionSendChatMessage, to, { Identifier = Config.ChatIdentifier, tmc = WireCodec.FORMAT })
end

--- The first beat of a session: sort the recipients by format (everyone
--- gets plain tables until they say they read the compact one) and say that
--- we read it. Live only: nobody hears a replay.
local function StartCompact()
    RebuildTargets()
    if not isReplay then
        SayCompact(sendState.everyone)
    end
end

--- A client reads the compact format: send it that from now on.
---@param sender any
local function NoteCompact(sender)
    local index = sendState.clientIndex[sender]
    if index and not sendState.compact[index] then
        sendState.compact[index] = true
        RebuildTargets()
        Debug(tostring(sender) .. ' reads the compact format')
    end
end

--- A plain-table cursor packet came from this client: perhaps they never
--- heard that we read the compact one. Say it again, now and then, a few times.
---@param sender any
local function MaybeSayCompactAgain(sender)
    local index = sendState.clientIndex[sender]
    if not index or isReplay then
        return
    end
    local now = GetSystemTimeSeconds()
    local h = sendState.hello[index]
    if not h then
        h = { n = 0, t = -1000 }
        sendState.hello[index] = h
    end
    if h.n < 3 and now - h.t >= 2 then
        h.n = h.n + 1
        h.t = now
        SayCompact({ index })
    end
end

--- Tell a player we have hidden their cursor (or shown it again), so they
--- stop sending to us (or start): hiding someone saves both sides the work,
--- which is the point if the mod is ever a strain. Sent to every other client,
--- naming the player by army; only that player acts on it.
---@param record table
---@param hidden boolean
local function NotifyMute(record, hidden)
    record.muteSentT = GetSystemTimeSeconds()
    if table.getn(sendState.everyone) == 0 or type(record.army) ~= 'number' then
        return
    end
    pcall(SessionSendChatMessage, sendState.everyone,
        { Identifier = Config.ChatIdentifier, tmo = hidden and 0 or 1, ta = record.army })
end

--- The panel hid or showed a player's cursor. Live, tell them, so they stop
--- (or start) sending to us.
---@param record table
local function OnPanelToggle(record)
    Debug((record.disabled and 'hiding ' or 'showing ') .. tostring(record.name) .. '\'s cursor')
    if not isReplay then
        NotifyMute(record, record.disabled)
    end
end

local function ProcessMessage(sender, msg)
    -- The compact format (wirecodec.lua): the very table the sender built,
    -- packed into one string, as { TeamMouse = string }. (A replay's copies
    -- are decoded by ReplayCodec.Listen.) Anything that does not decode is
    -- ignored, like any other malformed packet.
    local plain = true
    if type(msg) == 'table' and type(msg[Config.ChatIdentifier]) == 'string' then
        NoteCompact(sender)
        msg = WireCodec.Decode(msg[Config.ChatIdentifier])
        plain = false
    end
    if type(msg) ~= 'table' then
        return
    end

    -- A client saying it reads the compact format.
    if plain and msg.tmc ~= nil then
        if msg.tmc == WireCodec.FORMAT then
            NoteCompact(sender)
        end
        return
    end

    -- Someone has hidden our cursor (tmo 0), or shown it again (tmo 1): stop
    -- sending to them, or start again.
    if type(msg) == 'table' and msg.tmo ~= nil then
        if msg.ta == myArmy then
            local index = sendState.clientIndex[sender]
            if index then
                sendState.muted[index] = msg.tmo == 0 or nil
                RebuildTargets()
                Debug(tostring(sender) .. (msg.tmo == 0 and ' hid' or ' showed') .. ' our cursor')
            end
        end
        return
    end

    -- A teammate saying which version they're on. Before the format check:
    -- a teammate on an incompatible build is exactly who to report.
    if type(msg) == 'table' and msg.tmv ~= nil then
        Version.Heard(sender, msg.tmv)
        NoteTeamMouse(sender)
        return
    end

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
    NoteTeamMouse(sender)
    if plain and sender then
        MaybeSayCompactAgain(sender)
    end

    -- Still hearing from someone whose cursor we hid: they missed our word
    -- (or started after it). Say it again, now and then, and ignore this.
    if record.disabled then
        if GetSystemTimeSeconds() - (record.muteSentT or -1000) >= 5 then
            NotifyMute(record, true)
        end
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

    -- Their selection: unit ids. A list replaces the last one whole (an empty
    -- one means nothing selected); none at all means no change.
    -- A repeat of the same selection (the periodic resend) changes nothing:
    -- in particular it does not bring faded boxes back.
    local sel = msg.sel
    if type(sel) == 'string' and Config.TeamSelection.Enabled and sel ~= record.selText then
        record.selText = sel
        local ids = record.sel
        for i = table.getn(ids), 1, -1 do
            table.remove(ids)
        end
        -- Packed (PackIds): base 36, comma-separated.
        if string.len(sel) <= 16 * Config.TeamSelection.MaxSend then
            for word in string.gfind(sel, '[^,]+') do
                if table.getn(ids) >= Config.TeamSelection.MaxSend then break end
                if not string.find(word, '^[0-9a-z]+$') or string.len(word) > 12 then break end
                local n = tonumber(word, 36)
                if not n then break end
                table.insert(ids, string.format('%d', n))
            end
        end
        record.selVersion = record.selVersion + 1
        record.selT = now
        -- A new list: sizes, places and rectangles are for the old one.
        for i = table.getn(record.selSize), 1, -1 do table.remove(record.selSize) end
        for i = table.getn(record.selPos), 1, -1 do table.remove(record.selPos) end
        for i = table.getn(record.selRects), 1, -1 do table.remove(record.selRects) end
    end

    -- Their sizes (doubled, base 36), one per id.
    if type(msg.ss) == 'string' and string.len(msg.ss) <= 4 * Config.TeamSelection.MaxSend then
        local sizes = record.selSize
        for i = table.getn(sizes), 1, -1 do table.remove(sizes) end
        for word in string.gfind(msg.ss, '[^,]+') do
            if table.getn(sizes) >= Config.TeamSelection.MaxSend then break end
            local n = string.find(word, '^[0-9a-z]+$') and tonumber(word, 36)
            if not n then break end
            table.insert(sizes, n / 2)
        end
    end

    -- Rectangles round bunches of them (more selected than MaxSend):
    -- "x1,z1,x2,z2,y", x and z in quarter units, base 36, ';' between.
    if type(msg.sr) == 'string' and string.len(msg.sr) <= 32 * Config.TeamSelection.MaxRects then
        local list = record.selRects
        for i = table.getn(list), 1, -1 do table.remove(list) end
        for part in string.gfind(msg.sr, '[^;]+') do
            if table.getn(list) >= Config.TeamSelection.MaxRects then break end
            local _, _, a, b, c, d, e = string.find(part,
                '^([0-9a-z]+),([0-9a-z]+),([0-9a-z]+),([0-9a-z]+),([0-9a-z]+)$')
            if not a then break end
            local x1, z1 = tonumber(a, 36) / 4, tonumber(b, 36) / 4
            local x2, z2 = tonumber(c, 36) / 4, tonumber(d, 36) / 4
            if x2 >= x1 and z2 >= z1 then
                table.insert(list, { x1, z1, x2, z2, tonumber(e, 36) })
            end
        end
    end

    -- Where they were when selected: "x,z,y" per unit, base 36, x and z in
    -- quarter units, ';' between, one per id, empty where they could not say.
    local posText = msg.sq
    if type(posText) == 'string' and string.len(posText) <= 24 * Config.TeamSelection.MaxSend then
        local list = record.selPos
        local i = 0
        for part in string.gfind(posText .. ';', '([^;]*);') do
            i = i + 1
            if i > Config.TeamSelection.MaxSend then break end
            local _, _, a, b, c = string.find(part, '^([0-9a-z]+),([0-9a-z]+),([0-9a-z]+)$')
            local slot = list[i]
            if not slot then
                slot = { 0, 0, 0 }
                list[i] = slot
            end
            slot.ok = a and true or false
            if a then
                slot[1], slot[2], slot[3] = tonumber(a, 36) / 4, tonumber(c, 36), tonumber(b, 36) / 4
            end
        end
    end

    -- Clicks: a pulse each at the tip of their cursor, where it is in this
    -- packet, shown when the cursor is (after the interpolation delay).
    local clicks = SafeNumber(msg.ck, 0, 0, 9)
    if clicks >= 1 and Config.ClickPulse.Enabled then
        local pulses = record.pulses
        local at = now + Config.Smoothing.InterpolationDelay
        for i = 1, math.floor(clicks) do
            -- A small ring buffer: the oldest goes if they come too fast.
            local slot = pulses[record.pulseNext]
            if not slot then
                slot = {}
                pulses[record.pulseNext] = slot
            end
            slot.t = at + (i - 1) * Config.ClickPulse.Stagger
            slot.x, slot.y, slot.z = x, y, z
            record.pulseNext = math.mod(record.pulseNext, 6) + 1
        end
    end

    -- Their view's outline: four corners, x/y/z each. All twelve or nothing.
    local vp = msg.vp
    if type(vp) == 'table' then
        local into = record.vpIn
        local whole = true
        for i = 1, 12 do
            local v = SafeNumber(vp[i], nil, -100000, 100000)
            if v == nil then
                whole = false
                break
            end
            into[i] = v
        end
        if whole then
            local keep = record.vp or {}
            for i = 1, 12 do keep[i] = into[i] end
            record.vp = keep
            -- Changed: the visuals copy it into their outlines again.
            record.vpVersion = (record.vpVersion or 0) + 1
        end
    end

    -- Their camera: focus x, y, z, heading, pitch, zoom. All six or nothing.
    local cam = msg.cam
    if type(cam) == 'table' then
        local into = record.camIn
        local whole = true
        for i = 1, 6 do
            local v = SafeNumber(cam[i], nil, -100000, 100000)
            if v == nil then
                whole = false
                break
            end
            into[i] = v
        end
        if whole and into[6] > 0 then
            local keep = record.cam or {}
            for i = 1, 6 do keep[i] = into[i] end
            record.cam = keep
        end
    end

    local hx = SafeNumber(msg.hx, 0.5, 0, 1)
    local hy = SafeNumber(msg.hy, 0.9, 0, 1)
    local bx = SafeNumber(msg.bx, x, -100000, 100000)
    local bz = SafeNumber(msg.bz, z, -100000, 100000)

    -- The samples gathered since their last packet come first: they are all
    -- older than this packet's own.
    if Config.Network.ExtraSamples.Enabled then
        PushExtras(record, msg.e, now, x, y, z)
    end

    local flags = 0
    if msg.w == false then flags = flags + FLAG_HUD end
    if msg.s == true then
        flags = flags + FLAG_BOX
    elseif msg.l == true then
        flags = flags + FLAG_LINE
    elseif msg.r == true and Config.Orders.ShowLiveLine then
        flags = flags + FLAG_ORDER
    elseif msg.d == 1 then
        flags = flags + FLAG_DRAW
    elseif msg.d == 2 then
        flags = flags + FLAG_FOLLOW
    end
    PushSample(record, x, y, z, now, hx, hy, bx, bz, flags)

    record.lastUpdate = now
    -- Sent when it changes (and with the keep-alive): none means unchanged.
    if msg.o ~= nil then
        record.orderIndex = math.floor(SafeNumber(msg.o, 0, 0, 1000))
    end
    -- Zoom only comes when it changes: keep the last one.
    if msg.z ~= nil then
        record.zoom = SafeNumber(msg.z, record.zoom, 0, 100000)
    end

    if Config.Orders.Enabled then
        AddRemoteOrders(record, msg.mo, now, msg.mob, msg.mot, msg.mou)
        MarkOrdersApplied(record, msg.oa, now)
    end

    -- Actions: the last one in the packet is the one shown. Drawn when the
    -- samples it belongs with are, like an order.
    if Config.Actions.Enabled and type(msg.ac) == 'table' then
        local code = false
        for i = 1, Config.Actions.MaxPerPacket do
            local c = SafeNumber(msg.ac[i], nil, 1, table.getn(Actions.Labels))
            if msg.ac[i] == nil then break end
            if c then code = math.floor(c) end
        end
        if code then
            record.actCode = code
            record.actT = now + Config.Smoothing.InterpolationDelay
        end
    end

    -- The order they are dragging, if they are dragging one.
    record.grabKind = math.floor(SafeNumber(msg.gk, 0, 0, 1000))

    if type(msg.b) == 'string' and string.len(msg.b) > 0 and string.len(msg.b) < 64 then
        record.buildId = msg.b
        record.buildTemplate = msg.bt == true
    else
        record.buildId = false
        record.buildTemplate = false
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

---@param sender string
---@param msg table
local function OnLegacyReceive(sender, msg)
    local ok, err = pcall(function()
        local record = peers[sender]
        if not record then
            return
        end
        -- Rejects the SharedMouse-format copies TeamMouse clients send (they
        -- carry a marker): only a real SharedMouse packet gets past this.
        local x, y, z, orderIndex = LegacyProtocol.DecodePacket(msg)
        if not x then
            return
        end

        Version.NoteLegacy(sender)
        -- A teammate on SharedMouse: they need our packets in their format.
        if not sendState.tmSeen[sender] and not sendState.smSeen[sender]
            and sendState.clientByName[sender] then
            sendState.smSeen[sender] = true
            RebuildLegacyTargets()
        end

        local now = GetSystemTimeSeconds()
        PushSample(record, x, y, z, now)
        record.lastUpdate = now
        record.orderIndex = orderIndex
        record.zoom = 0
        record.buildId = false

        if not record.hasData then
            record.render[1], record.render[2], record.render[3] = x, y, z
            record.hasData = true
        end
    end)

    if not ok then
        receiveErrors = receiveErrors + 1
        if receiveErrors <= 3 then
            Log('legacy receive error: ' .. tostring(err))
        end
    end
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

---@param v number
---@return number
local function Clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

--- Work out where the local mouse is and what it's doing.
---
--- The position comes from the two event hooks (HookViewEvents over the map,
--- HookRootFrame over the interface), not from GetMouseScreenPos: the engine
--- stops updating that while the pointer is on the HUD or a drag is running.
---@return table
---@param state table   # filled in and returned: each caller passes its own, reused
local function ReadLocalState(state)
    state.overWorld, state.zoom, state.hudX, state.hudY = false, 0, 0.5, 0.9

    local view = localMouse.view

    if localMouse.overWorld and view and not view:IsHidden() then

        state.overWorld = true
        local camera = GetCamera(view._cameraName)
        if camera then
            state.zoom = camera:GetZoom()
        end
        return state
    end

    local frame = GetFrame(0)
    if frame and localMouse.x then
        local w = frame.Width()
        local h = frame.Height()
        if w > 0 and h > 0 then
            state.hudX = Clamp01(localMouse.x / w)
            state.hudY = Clamp01(localMouse.y / h)
        end
    end
    return state
end

--------------------------------------------------------------------------------
-- World position of the local pointer
--------------------------------------------------------------------------------

--- How UnProject is to be called, learned rather than assumed. The engine docs
--- give its signature (a view and a Vector2) but not whether the point is
--- relative to the view or to the screen. That only matters when a view does
--- not start at the screen's origin (splitscreen), so it is worked out while
--- the pointer rests on the map, where the engine's own GetMouseWorldPos gives
--- the right answer to compare against.
---
--- On a view that starts at the screen's origin the two are the same thing, so
--- a pointer resting there can only confirm that UnProject means what we think
--- (verified); it cannot say which of the two it is. Only a view that does not
--- start at the origin can settle mode. (Settling it by a tie on the origin
--- view is what shoved the pointer a whole view-width to the left in split
--- view.)
---
--- verified: UnProject agrees with the engine on some view. mode: false until
--- an offset view has settled it, then 'relative' or 'absolute'. failed:
--- neither reading ever agreed, and projection stays off for the session.
--- lastX/lastY detect a resting pointer between beats.
local pointerMap = { verified = false, mode = false, failed = false, lastX = -1, lastY = -1 }

--- Largest disagreement, in world units, between UnProject and the engine's own
--- reading for a resting pointer that still counts as agreement. Loose on
--- purpose: it is a sanity gate against UnProject meaning something else
--- entirely, not a precision requirement. The two readings that have to be
--- told apart are a view-width apart, hundreds of units.
local POINTER_MAP_TOLERANCE = 40

--- UnProject a screen position through a view, reading it either way. Nil if
--- it gives nothing usable. For calibration; everything else uses UnProjectAt.
---@param view WorldView
---@param x number   # screen x
---@param y number   # screen y
---@param relative boolean   # true: hand UnProject a view-relative point
---@return table | nil
local function UnProjectRaw(view, x, y, relative)
    if relative then
        x = x - view.Left()
        y = y - view.Top()
    end
    local ok, world = pcall(UnProject, view, { x, y })
    if ok and IsFiniteVector(world) then
        return world
    end
    return nil
end

--- The world point under a screen position on `view`, or nil if that can't be
--- worked out yet: UnProject not verified, or `view` is offset from the origin
--- and nothing has settled how UnProject reads such a view.
---@param view WorldView
---@param x number   # screen x
---@param y number   # screen y
---@return table | nil
local function UnProjectAt(view, x, y)
    if not pointerMap.verified or not view then
        return nil
    end
    local atOrigin = view.Left() == 0 and view.Top() == 0
    if not atOrigin and not pointerMap.mode then
        return nil
    end
    return UnProjectRaw(view, x, y, atOrigin or pointerMap.mode == 'relative')
end

--- World point under the centre of a live view. Used when the pointer has
--- never been over the map yet (game start with the mouse on the HUD) and
--- projection has not been learned, so there is no last-known world position
--- to hold.
---@return number | nil, number | nil, number | nil
local function SeedWorldPos()
    for _, view in pairs(knownViews) do
        if view and not view:IsHidden() then
            local cx = (view.Left() + view.Right()) * 0.5
            local cy = (view.Top() + view.Bottom()) * 0.5
            -- Before anything is known, a guess is all there is: this only
            -- seeds a first position, and is replaced as soon as there's a real one.
            local world = UnProjectAt(view, cx, cy)
                or UnProjectRaw(view, cx, cy, pointerMap.mode ~= 'absolute')
            if world then
                return world[1], world[2], world[3]
            end
        end
    end
    return nil
end

--- Round a world position the way it is sent, remember it as the last good
--- one, and return it. Nil for anything unusable.
---@param v table | nil
---@return number | nil, number | nil, number | nil
local function RememberWorldPos(v)
    -- Validate all three components. The engine can hand back a partially
    -- populated vector during camera transitions, and a NaN sent from here
    -- would propagate into every teammate's interpolation and out into their
    -- layout.
    if not IsFiniteVector(v) then
        return nil
    end

    local p = 10
    if Config.Network.PositionPrecision == 0 then p = 1 end
    local x = math.floor(v[1] * p + 0.5) / p
    local y = math.floor(v[2] * p + 0.5) / p
    local z = math.floor(v[3] * p + 0.5) / p

    worldHold.pos[1], worldHold.pos[2], worldHold.pos[3] = x, y, z
    worldHold.have = true
    return x, y, z
end

--- Decide how to call UnProject. Runs on beats where the pointer is over the
--- map; does nothing once decided. Only a pointer that has not moved since the
--- previous beat is used: then the engine's world position and the pointer's
--- screen position describe the same point, so the two can be compared.
---@param engineWorld table | nil   # GetMouseWorldPos() from this beat
local function CalibratePointerMap(engineWorld)
    if pointerMap.mode or pointerMap.failed then
        return
    end

    -- During a drag the engine's reading is frozen at its start while the
    -- pointer (now tracked by the grid) moves on: the two describe different
    -- points, and comparing them would teach the wrong convention.
    if localSelecting or rightClick.press then
        return
    end

    local view = localMouse.view
    if not view or not localMouse.x or not IsFiniteVector(engineWorld) then
        return
    end

    local still = (localMouse.x == pointerMap.lastX and localMouse.y == pointerMap.lastY)
    pointerMap.lastX, pointerMap.lastY = localMouse.x, localMouse.y
    if not still then
        return
    end

    local atOrigin = view.Left() == 0 and view.Top() == 0
    if atOrigin and pointerMap.verified then
        return   -- nothing more to learn here
    end

    local best, bestError = false, false
    for _, relative in ipairs({ true, false }) do
        local world = UnProjectRaw(view, localMouse.x, localMouse.y, relative)
        if world then
            local dx = world[1] - engineWorld[1]
            local dz = world[3] - engineWorld[3]
            local err = math.sqrt(dx * dx + dz * dz)
            if bestError == false or err < bestError then
                best = relative and 'relative' or 'absolute'
                bestError = err
            end
        end
    end

    if best and bestError <= POINTER_MAP_TOLERANCE then
        pointerMap.verified = true
        if not atOrigin then
            pointerMap.mode = best
            Debug('UnProject reads ' .. best .. ' coordinates (off by '
                .. tostring(math.floor(bestError * 10 + 0.5) / 10) .. ')')
        end
    elseif not pointerMap.verified then
        pointerMap.failed = true
        Log('UnProject does not agree with GetMouseWorldPos; the ghost will park'
            .. ' where the pointer last touched the map')
    end
end

--- The map position behind the pointer while it is on the interface, or nil if
--- that is switched off, not yet learned, or cannot be worked out.
---@return table | nil
local function PointerToWorld()
    if not Config.Hud.FollowPointer or not localMouse.x then
        return nil
    end

    local view = localMouse.view
    if not view or view:IsHidden() then
        return nil
    end

    return UnProjectAt(view, localMouse.x, localMouse.y)
end

--- Where to report the pointer on the map this beat, or nil to say nothing.
---
--- Over the map that is the engine's own reading. On the interface it is the
--- map point behind the pointer, so a teammate's ghost travels with it; when
--- that is unavailable it is the last position they were genuinely at, so
--- peers see where they were working rather than a stale projection.
---@param state table   # from ReadLocalState
---@return number | nil, number | nil, number | nil
local function ResolveWorldPosition(state)
    if localSelecting and pinnedAnchor then
        worldHold.pos[1], worldHold.pos[2], worldHold.pos[3] =
            pinnedAnchor[1], pinnedAnchor[2], pinnedAnchor[3]
        worldHold.have = true
        return pinnedAnchor[1], pinnedAnchor[2], pinnedAnchor[3]
    end

    -- A right drag pins the same way: everything reports the press point, and
    -- the far end of the line travels separately (ResolveDragBox).
    if rightClick.live then
        worldHold.pos[1], worldHold.pos[2], worldHold.pos[3] =
            rightClick.sx, rightClick.sy, rightClick.sz
        worldHold.have = true
        return rightClick.sx, rightClick.sy, rightClick.sz
    end

    local x, y, z
    if state.overWorld then
        local world = GetMouseWorldPos()
        x, y, z = RememberWorldPos(world)
        CalibratePointerMap(world)
    else
        x, y, z = RememberWorldPos(PointerToWorld())
    end

    if x then
        return x, y, z
    end

    if not worldHold.have then
        -- Over the map with an unusable engine reading (camera transition,
        -- NaN): say nothing rather than invent a position. Seeding is only
        -- for a pointer that is on the HUD.
        if state.overWorld then
            return nil
        end
        local sx, sy, sz = SeedWorldPos()
        if not sx then
            return nil
        end
        worldHold.pos[1], worldHold.pos[2], worldHold.pos[3] = sx, sy, sz
        worldHold.have = true
    end

    return worldHold.pos[1], worldHold.pos[2], worldHold.pos[3]
end

--------------------------------------------------------------------------------
-- Drag overlay: tracks the pointer during our own native map drag
--------------------------------------------------------------------------------
--
-- One screen-covering grid of invisible cells per view, built once and kept
-- for as long as the view exists -- not created and destroyed per drag. It is
-- hidden (fully click-through, nothing tracked) except for the length of a
-- drag: see SyncOverlays. Every cell always returns false from HandleEvent, so it never
-- consumes anything and never changes how a click or a drag is processed.
--
-- Exactly one cell -- whichever the pointer is currently resting in -- has its
-- own hit-testing disabled at any moment, so a click or release lands on the
-- view underneath rather than on the overlay. This is the same mechanism that
-- fixed the overlay blocking ordinary clicks when it briefly had a real
-- screen-covering footprint: a hit-testable control intercepts what's beneath
-- it, and a non-hit-testable one doesn't. Making that hole track the cursor,
-- rather than sitting fixed at wherever a drag happened to start, is what
-- lets a release land correctly wherever the drag actually ends -- including
-- on our own grid -- without needing to hand it off to anything, or destroy
-- anything mid-drag.
--
-- view identity -> per-view overlay state.
local dragOverlays = {}

--- The view a drag is currently associated with, or false. Distinct from
--- localMouse.view: that one freezes at whatever it was when a native drag
--- begins (the view stops receiving ordinary motion once its own capture
--- engages), which is exactly why it stays correct for the rest of the drag
--- and is safe to use here to remember which view's overlay to read from.
local activeDragView = false

--- The cursors the game shows over a waypoint and while dragging one.
---@param key string | nil
---@return boolean
local function IsWaypointCursor(key)
    return key == 'waypoint-drag' or key == 'waypoint-hover'
end

--- The cursor for each command type, by the engine's numbering (FAF's
--- UnitQueueDataToCommand in lua/sim/commands/shared.lua).
local COMMAND_CURSORS = {
    [2] = 'move', [4] = 'move',
    [7] = 'construct', [8] = 'construct',
    [9] = 'guard', [15] = 'guard', [29] = 'guard',
    [10] = 'attack', [11] = 'attack',
    [12] = 'launch', [13] = 'launch',
    [16] = 'patrol', [18] = 'patrol',
    [17] = 'ferry',
    [19] = 'reclaim',
    [20] = 'repair',
    [21] = 'capture',
    [22] = 'load', [23] = 'load',
    [24] = 'unload', [25] = 'unload',
    [32] = 'sacrifice',
    [34] = 'overcharge',
    [35] = 'attack_move', [36] = 'attack_move',
}

--- The order under the pointer -- the waypoint about to be dragged -- as a
--- cursor index and its world position, or nil.
---@return number | nil, table | nil
local function GrabbedCommand()
    local ok, hc = pcall(GetHighlightCommand)
    if not ok or type(hc) ~= 'table' then
        return nil
    end
    local key = COMMAND_CURSORS[hc.commandType] or 'waypoint-drag'
    local pos = nil
    if type(hc.x) == 'number' and type(hc.z) == 'number' and hc.x == hc.x and hc.z == hc.z then
        pos = { hc.x, type(hc.y) == 'number' and hc.y or 0, hc.z }
    end
    return CursorData.IndexFromKey(key), pos
end

--- Finish whatever drag is in progress, of either kind. One place, because
--- there are five ways a drag can end (release, a motion event that shows the
--- button is up, the beat's stuck-drag valve, the view being replaced, ...) and
--- they must all clear exactly the same things.
local function EndDrag()
    localSelecting = false
    sendState.gridUp = false
    pinnedAnchor = false
    activeDragView = false
    sendState.line = false
    sendState.plain = false
    sendState.waypoint = false
    sendState.grabKind = 0
    sendState.buildBp = false
end

--- Cell under a screen position, or nil if the position is off this grid.
---@param overlay table
---@param x number
---@param y number
---@return Bitmap | nil
local function CellAt(overlay, x, y)
    local size = Config.Selection.DragCellSize
    local col = math.floor((x - overlay.left) / size)
    local row = math.floor((y - overlay.top) / size)
    local cells = overlay.grid[row]
    return cells and cells[col]
end

--- Make `cell` the one hole in the grid: hit-testing off, so a click lands on
--- the view beneath, and the previous hole switched back on.
---@param overlay table
---@param cell Bitmap
local function SetCurrentCell(overlay, cell)
    local old = overlay.currentCell
    if old == cell then
        return
    end
    if old then
        old:EnableHitTest(true)
        if overlay.debug then
            old:SetSolidColor('35ffffff')
        end
    end
    cell:DisableHitTest(true)
    if overlay.debug then
        cell:SetSolidColor('00ffffff')
    end
    overlay.currentCell = cell
end

--- Shared by every cell so we don't pay for one closure per cell -- a full
--- screen of them can run into the thousands. dragCX/dragCY are the cell's own
--- centre, stashed on it at creation, used only if this particular event
--- didn't carry MouseX/MouseY.
---@param self Bitmap
---@param event table
local function DragCellEvent(self, event)
    local t = event.Type
    local overlay = self.dragOverlayRef

    if t == 'MouseEnter' and rightClick.press then
        rightClick.cellEvents = rightClick.cellEvents + 1
    end

    if t == 'MouseEnter' or t == 'MouseMotion' then
        local x = event.MouseX or self.dragCX
        local y = event.MouseY or self.dragCY
        overlay.liveScreen[1] = x
        overlay.liveScreen[2] = y
        SetCurrentCell(overlay, self)

        -- A cell crossing says nothing about whether the pointer is on the map
        -- or the interface: the grid lies over both (it has to be above the
        -- interface to win the hit test). Note where it was, so the root
        -- frame, which this event bubbles up to next, can tell it apart from
        -- an interface event and ignore it. (Taking it for the interface made
        -- a fast swing stutter; taking it for the map made the HUD ghost snap
        -- about while hovering the interface.)
        localMouse.cellX, localMouse.cellY = x, y
    elseif t == 'ButtonRelease' then
        -- Defensive fallback only: with the current cell always disabled, an
        -- ordinary release should already land on the view directly, the same
        -- as any other click would. This only matters if a release somehow
        -- still reaches a cell anyway -- e.g. exactly at the instant of a
        -- boundary crossing, before the swap above has run for the new cell.
        -- Nothing here destroys anything -- the overlay is permanent -- so
        -- this only needs to hand the view its own bookkeeping.
        if overlay.view then
            overlay.forwarding = true
            local ok, err = pcall(overlay.view.HandleEvent, overlay.view, event)
            overlay.forwarding = false
            if not ok then
                Log('forwarded event error: ' .. tostring(err))
            end
        end
    elseif t == 'ButtonPress' and event.Modifiers and (event.Modifiers.Right or event.Modifiers.Middle) then
        -- A right press that landed on a cell instead of the view, at the
        -- instant of a crossing. The view's hook is what lifts the grid out of
        -- the way of the right button, so give it the press.
        if overlay.view then
            overlay.forwarding = true
            local ok, err = pcall(overlay.view.HandleEvent, overlay.view, event)
            overlay.forwarding = false
            if not ok then
                Log('forwarded event error: ' .. tostring(err))
            end
        end
    end

    return false   -- never consume; this cell only ever observes (or relays)
end

--- What the grid's footprint is compared against to notice a resize: the view's
--- own rectangle, and the screen's. Whole numbers, since a fractional wobble in
--- a lazy layout value is not a resize.
---@param view WorldView
---@return string
local function OverlayGeometryKey(view)
    local frame = GetFrame(0)
    local fw, fh = 0, 0
    if frame then
        fw, fh = frame.Width(), frame.Height()
    end
    return string.format('%d,%d,%d,%d,%d,%d',
        view.Left(), view.Top(), view.Right(), view.Bottom(), fw, fh)
end

--- Build the permanent grid for one view. Called once, the first time a view
--- is seen (from HookViewEvents), and again whenever the view is replaced
--- (SyncViews' own retire/create cycle, same as everything else keyed by
--- view) or resized (RefreshOverlayGeometry).
---
--- Every position here is absolute screen space, like every other Left/Top in
--- this mod, so the cells are offset by the view's own origin. That is nothing
--- when the view starts at 0,0 and the whole grid for the right-hand view of a
--- splitscreen otherwise.
---@param view WorldView
local function CreateDragOverlayForView(view)
    local frame = GetFrame(0)
    if not frame then
        return
    end

    local viewLeft, viewTop = view.Left(), view.Top()
    local viewW = view.Right() - viewLeft
    local viewH = view.Bottom() - viewTop

    local overlay = {
        view = view,
        liveScreen = { 0, 0 },
        currentCell = false,
        -- True while a cell is handing an event on to the view (DragCellEvent),
        -- so the view's handler knows not to change the grid from inside it.
        forwarding = false,
        -- Up (shown, cells hit-testable) only while it is tracking a drag;
        -- see SyncOverlays.
        shown = false,
        left = viewLeft,
        top = viewTop,
        key = OverlayGeometryKey(view),
        pendingKey = false,
        debug = Config.Selection.DebugGrid and true or false,
        grid = {},   -- grid[row][col] -> cell; rows and columns count from 0
    }

    local group = Group(frame, 'TeamMouseDragOverlay')
    group.Left:SetValue(viewLeft)
    group.Top:SetValue(viewTop)
    LayoutHelpers.SetDimensions(group, viewW, viewH)
    group.Depth:Set(Config.Selection.DragOverlayDepth)
    group:DisableHitTest(true)
    overlay.group = group

    local size = Config.Selection.DragCellSize
    local cols = math.ceil(viewW / size)
    local rows = math.ceil(viewH / size)
    local grid = overlay.grid

    -- Fully transparent unless the coverage is being inspected: a bitmap needs
    -- a texture or a colour, but this grid sits over the map permanently and
    -- must never be visible.
    local idleColor = overlay.debug and '35ffffff' or '00ffffff'

    for row = 0, rows - 1 do
        grid[row] = {}
        for col = 0, cols - 1 do
            local cell = Bitmap(group)
            LayoutHelpers.SetDimensions(cell, size, size)
            cell.Left:SetValue(viewLeft + col * size)
            cell.Top:SetValue(viewTop + row * size)
            cell.dragCX = viewLeft + col * size + size * 0.5
            cell.dragCY = viewTop + row * size + size * 0.5
            cell.dragOverlayRef = overlay
            cell.Depth:Set(Config.Selection.DragOverlayDepth)
            cell.HandleEvent = DragCellEvent
            cell:SetSolidColor(idleColor)
            grid[row][col] = cell
        end
    end

    -- Built down. It only comes up for a drag (SyncOverlays), and the hole is
    -- opened under the pointer then.
    group:Hide()

    dragOverlays[view] = overlay
end

--- Whether a view's grid should be up right now: only while it is following a
--- drag on that view -- a left drag, or a right press it stayed up for (a
--- drawing) -- and never while a right or middle press has it lifted.
---@param view WorldView
---@return boolean
local function OverlayWanted(view)
    if rightClick.suspended then
        return false
    end
    if localSelecting and activeDragView == view and sendState.gridUp then
        return true
    end
    return (rightClick.press and rightClick.grid and rightClick.view == view) and true or false
end

--- Bring every grid up or down to match OverlayWanted. Called at a press (to
--- raise it at once, before the pointer moves), and every frame (to take it
--- down after the drag ends, however it ended).
---
--- The grid is NOT left up between drags. Up, every cell but the one under
--- the pointer is hit-testable, so an ordinary swing across the map crosses
--- a cell every 45 pixels: each crossing is a cell event, a hit-test toggle,
--- and a copy bubbled to the root frame, and the view itself only hears the
--- pointer between crossings. That is what stuttered the pointer (and the
--- frame rate) when the mouse was swung about. Outside a drag the view's own
--- motion events, and GetMouseWorldPos, already say where the pointer is.
---
--- Taking it down happens here, on the frame, rather than inside the release
--- handler: a release can arrive through one of the grid's own cells, and
--- changing the grid from inside its own child's handler is the pattern the
--- gotchas warn about.
---@param x? number   # screen position to open the hole at, when raising
---@param y? number
local function SyncOverlays(x, y)
    for view, overlay in pairs(dragOverlays) do
        local want = OverlayWanted(view)
        if want ~= overlay.shown then
            overlay.shown = want
            if want then
                overlay.group:Show()
                local cell = x and y and CellAt(overlay, x, y)
                if cell then
                    SetCurrentCell(overlay, cell)
                end
            else
                overlay.group:Hide()
                -- Nothing bubbles from the grid now; don't let the root frame
                -- mistake a real interface event at the same spot for one.
                localMouse.cellX, localMouse.cellY = false, false
            end
        end
    end
end

--- Tear down one view's overlay. Called when a view is retired.
---@param view WorldView
local function DestroyDragOverlayForView(view)
    local overlay = dragOverlays[view]
    if overlay then
        overlay.group:Destroy()   -- cascades to every cell
        dragOverlays[view] = nil
    end
    if activeDragView == view then
        activeDragView = false
    end
end

--- World X/Z of the drag's live corner this beat, or nil if there is no drag,
--- tracking is off, nothing has been observed yet, or UnProject has not been
--- calibrated yet (see CalibratePointerMap).
---@return number | nil, number | nil
local function ResolveDragBox()
    local overlay, x, y
    if rightClick.live then
        -- The grid, when it stayed up for this press: the same source as a
        -- left drag, and the only one the engine doesn't freeze. Otherwise
        -- whatever the view's events last said, which the engine freezes for
        -- a held button, and then the engine's own (equally frozen) reading.
        overlay = rightClick.grid and dragOverlays[rightClick.view]
        local world
        if overlay then
            world = UnProjectAt(overlay.view, overlay.liveScreen[1], overlay.liveScreen[2])
        elseif localMouse.view and localMouse.x then
            world = UnProjectAt(localMouse.view, localMouse.x, localMouse.y)
        end
        if world then
            return world[1], world[3]
        end
        local ok, engine = pcall(GetMouseWorldPos)
        if ok and IsFiniteVector(engine) then
            return engine[1], engine[3]
        end
        return nil
    end

    overlay = localSelecting and activeDragView and dragOverlays[activeDragView]
    if not overlay then
        return nil
    end
    x, y = overlay.liveScreen[1], overlay.liveScreen[2]
    local world = UnProjectAt(overlay.view, x, y)
    if not world then
        return nil
    end
    return world[1], world[3]
end

--------------------------------------------------------------------------------
-- Keeping the grid the size of its view
--------------------------------------------------------------------------------

--- The grid is built to the view's size at that moment, out of a fixed number of
--- cells, so it does not grow or shrink by itself when the window or the UI is
--- resized: after a resize it covers only part of the screen, or spills past
--- it. Comparing footprints is cheap; rebuilding is not (a cell per 45 pixels),
--- so a rebuild waits until the new footprint has held still for two checks in
--- a row, instead of chasing a window edge while it is being dragged.
---
--- Never while a drag or a right press is open: the grid is what tracks a drag,
--- and rebuilding under one would throw its state away.
---@param now number
local function RefreshOverlayGeometry(now)
    if localSelecting or rightClick.press then
        return
    end
    if (now - sendState.gridCheck) < Config.Selection.GridRecheckInterval then
        return
    end
    sendState.gridCheck = now

    local stale = nil
    for view, overlay in pairs(dragOverlays) do
        local key = OverlayGeometryKey(view)
        if key == overlay.key then
            overlay.pendingKey = false
        elseif overlay.pendingKey == key then
            stale = stale or {}
            stale[view] = true
        else
            overlay.pendingKey = key
        end
    end

    -- Collected first: rebuilding writes to dragOverlays, which must not
    -- happen while it is being walked.
    if stale then
        for view, _ in pairs(stale) do
            Debug('drag overlay no longer matches its view, rebuilding')
            DestroyDragOverlayForView(view)
            CreateDragOverlayForView(view)
        end
    end
end

--------------------------------------------------------------------------------
-- Right mouse button
--------------------------------------------------------------------------------
--
-- Two jobs, one press:
--
--  * Stay out of the way. A right drag is how formations are laid out, and the
--    grid cancelled them: with every cell hit-testable except the one under the
--    pointer, dragging across a cell boundary hands the pointer from the view
--    to a cell mid-gesture, and the release comes back to a cell. The grid only
--    exists to follow a LEFT drag, so it is lifted off the screen entirely
--    between a right press and its release.
--
--  * Notice orders. A right click with units selected is a move (or attack,
--    reclaim, ...). What was clicked, and for a drag where it ended, is queued
--    for the next packet so teammates can see it.

---@return boolean
local function IsBuildMode()
    local ok, mode = pcall(CommandMode.GetCommandMode)
    return ok and type(mode) == 'table' and mode[1] == 'build'
end

--- What the first selected unit's command queue looks like, as a string, or
--- false if that can't be read. Only ever compared with itself: a change means
--- the sim has taken an order from us. (GetCommandQueue's exact shape on this
--- engine is assumed -- a list of commands with a type and a position -- and
--- read defensively; if it isn't that, this stays false and the timeout in
--- Config.Orders.ApplyTimeout decides instead.)
---@return string | boolean
local function QueueSignature()
    local ok, units = pcall(GetSelectedUnits)
    local unit = ok and type(units) == 'table' and units[1]
    if not unit or type(unit.GetCommandQueue) ~= 'function' then
        return false
    end
    local okq, queue = pcall(unit.GetCommandQueue, unit)
    if not okq or type(queue) ~= 'table' then
        return false
    end

    local n = 0
    local last = false
    for _, command in ipairs(queue) do
        n = n + 1
        last = command
    end
    local sig = tostring(n)
    if type(last) == 'table' then
        sig = sig .. ':' .. tostring(last.type)
        local pos = last.position
        if type(pos) == 'table' and type(pos[1]) == 'number' and type(pos[3]) == 'number' then
            sig = sig .. ':' .. tostring(math.floor(pos[1])) .. ',' .. tostring(math.floor(pos[3]))
        end
    end
    return sig
end

---@return boolean
local function HasSelection()
    local ok, units = pcall(GetSelectedUnits)
    return ok and type(units) == 'table' and units[1] ~= nil
end

--- Bring the grid up for a left press, hole under the pointer. At the press
--- itself: once the game has taken a drag over it has the pointer, and a grid
--- that only appears then never hears it cross a cell (tried: drags stopped
--- being tracked).
---@param x? number
---@param y? number
local function RaiseGridForDrag(x, y)
    sendState.gridUp = true
    SyncOverlays(x, y)
end

--- The view heard the pointer move during a left press (in the hole, or
--- before the game takes the drag over): that is the far end too.
---@param view WorldView
---@param event table
local function NoteDragMotion(view, event)
    local overlay = dragOverlays[view]
    if overlay and event.MouseX and activeDragView == view then
        overlay.liveScreen[1] = event.MouseX
        overlay.liveScreen[2] = event.MouseY
    end
end

--- A left press ended, and the view itself heard it: take the grid down now
--- rather than on the next frame. A click leaves the map exactly as it found
--- it, so the second click of a double-click lands on the map, not on a cell
--- of the first click's grid (reported: double-clicking units sometimes did
--- nothing). Not when the release came in through one of the grid's own
--- cells (overlay.forwarding): the grid is not changed from inside its own
--- child's handler, and the frame takes it down instead.
---@param view WorldView
local function LowerGridNow(view)
    local overlay = dragOverlays[view]
    if overlay and overlay.forwarding then
        return
    end
    SyncOverlays()
end

--- Keep every grid down, even one a left drag would want up. The press that got
--- us here is already on its way to the view; nothing after it can land on a
--- cell.
local function SuspendOverlays()
    rightClick.suspended = true
    SyncOverlays()
end

--- Lift the suspension. A grid only comes back if a drag still wants it, and
--- then with the hole already where the pointer is: the pointer moved while it
--- was away, and left alone the cell under it would eat the very next click.
---@param x? number   # screen position to open the hole at
---@param y? number
local function ResumeOverlays(x, y)
    rightClick.suspended = false
    SyncOverlays(x, y)
end

--- Give up on a right press whose release never showed up (a dialog opened over
--- the view and took it, say), so the grid comes back.
local function AbandonRightPress()
    rightClick.press = false
    rightClick.live = false
    rightClick.order = false
    rightClick.drawing = false
    if rightClick.suspended then
        ResumeOverlays(localMouse.x, localMouse.y)
    end
end

--- Beat-time backstop for the above.
---@param now number
local function CheckRightPress(now)
    local rc = rightClick
    if rc.press and (now - rc.since) > Config.Orders.MaxPressSeconds then
        AbandonRightPress()
    end
    if rc.middle and (now - rc.since) > Config.Orders.MaxPressSeconds then
        EndMiddle()
    end

    -- Has the order we gave reached the sim? Its unit's queue no longer looks
    -- as it did before, or long enough has passed that it must have.
    if rc.pendSeq > 0 then
        local sig = rc.pendSig and QueueSignature()
        if (sig and sig ~= rc.pendSig) or (now - rc.pendSince) >= Config.Orders.ApplyTimeout then
            rc.appliedOut = rc.pendSeq
            rc.pendSeq = 0
        end
    end
end

--- One decimal place: all the precision a world position needs on the wire.
---@param v number
---@return number
local function Round1(v)
    return math.floor(v * 10 + 0.5) / 10
end

--- Queue one order for the next packet.
---@param kind number
---@param x number
---@param y number
---@param z number
---@param x2 number
---@param z2 number
---@param seq number
---@param bp? string   # the structure placed, for a build; nil for any other order
---@param template? boolean   # the build was a template: bp is only its first structure
---@param upgrade? boolean    # an upgrade: bp is what the building at x/z becomes
local function QueueOrder(kind, x, y, z, x2, z2, seq, bp, template, upgrade)
    local ord = sendState.ord
    local capacity = Config.Orders.MaxPerPacket
    local count = sendState.ordCount

    if count >= capacity then
        local evicted = ord[1]
        for i = 1, capacity - 1 do
            ord[i] = ord[i + 1]
        end
        ord[capacity] = evicted
        count = capacity - 1
    end

    count = count + 1
    local slot = ord[count]
    if not slot then
        slot = {}
        ord[count] = slot
    end
    slot[1], slot[2], slot[3], slot[4], slot[5], slot[6], slot[7] = kind, x, y, z, x2, z2, seq
    slot[8] = bp or false
    slot[9] = (bp and template) and true or false
    slot[10] = (bp and upgrade) and true or false
    sendState.ordCount = count
end

--- World point where a right press ended: the given screen position through the
--- calibrated UnProject, else the engine's own reading (which is live again by
--- the time the button is up).
---@param view? WorldView   # the view the position is on
---@param mx? number
---@param my? number
---@return number | nil, number | nil
local function ReleaseWorldPoint(view, mx, my)
    if mx and my and view then
        local world = UnProjectAt(view, mx, my)
        if world then
            return world[1], world[3]
        end
    end
    local ok, world = pcall(GetMouseWorldPos)
    if ok and IsFiniteVector(world) then
        return world[1], world[3]
    end
    return nil, nil
end

--- End the open right press: announce the order it gave, if it gave one, and
--- put the grid back if it was lifted. Called from the release event when one
--- arrives, from a left press, and from the view's hook on a motion event
--- without the right button held -- which is how a right-drag drawing ends:
--- the engine keeps its release to itself.
---@param mx? number   # screen position it ended at, if known
---@param my? number
---@param how string   # what noticed it, for the Debug log
---@param endKnown boolean   # where it ended is known: a formation's far end can be sent
local function FinishRightPress(mx, my, how, endKnown)
    local rc = rightClick
    if not rc.press then
        return
    end

    -- Where the pointer was when it ended. The grid knew it all along; failing
    -- that, the caller's position, then the engine's.
    local overlay = rc.grid and dragOverlays[rc.view]
    if overlay then
        mx, my = overlay.liveScreen[1], overlay.liveScreen[2]
    end

    rc.press = false
    rc.live = false
    rc.drawing = false
    local held = GetSystemTimeSeconds() - rc.since

    if Config.Debug then
        local ok, world = pcall(GetMouseWorldPos)
        local moved = ok and IsFiniteVector(world) and rc.startOk
            and ((world[1] - rc.sx) ~= 0 or (world[3] - rc.sz) ~= 0)
        Log('right press ended (' .. how .. ') after ' .. string.format('%.2f', held) .. 's: '
            .. tostring(rc.motionEvents) .. ' motion events reached the view, '
            .. tostring(rc.heldEvents) .. ' of them with the right button held;'
            .. ' ' .. tostring(rc.cellEvents) .. ' grid crossings;'
            .. ' GetMouseWorldPos ' .. (moved and 'moved' or 'did NOT move'))
    end

    if rc.order then
        local ex, ez = ReleaseWorldPoint(rc.view or localMouse.view, mx, my)
        local x, y, z = rc.sx, rc.sy, rc.sz
        local x2, z2 = x, z
        -- Only a button held past the delay is a formation; before that it
        -- is an ordinary order to the point that was pressed.
        if endKnown and ex and held >= Config.Orders.LineDelay then
            local ddx, ddz = ex - x, ez - z
            local minDrag = Config.Orders.MinDragWorld
            if (ddx * ddx + ddz * ddz) > (minDrag * minDrag) then
                x2, z2 = ex, ez
            end
        end

        -- A newer order supersedes one still waiting to be reported: the queue
        -- it was watching has moved on, so call the old one applied.
        if rc.pendSeq > 0 then
            rc.appliedOut = rc.pendSeq
        end
        rc.seq = rc.seq + 1
        QueueOrder(rc.kind, Round1(x), Round1(y), Round1(z), Round1(x2), Round1(z2), rc.seq)
        rc.pendSeq = rc.seq
        rc.pendSince = GetSystemTimeSeconds()
        rc.pendSig = rc.sig0
    end
    rc.order = false

    -- Put the grid back. Only ever reached with the button known to be up (a
    -- release event, a left press, the capture seen to end): a grid shown
    -- under a held right button cancels the formation being drawn.
    if rc.suspended then
        ResumeOverlays(mx or localMouse.x, my or localMouse.y)
    end
end

--- The middle button is up: put the grid back.
---@param mx? number
---@param my? number
EndMiddle = function(mx, my)
    local rc = rightClick
    if not rc.middle then
        return
    end
    rc.middle = false
    if rc.suspended and not rc.press then
        ResumeOverlays(mx or localMouse.x, my or localMouse.y)
    end
end

--- Called from the view's hook (and the root frame's, for a release that lands
--- elsewhere) for every button press and release.
---
--- rc.order: the press is an order that will be announced on release --
--- something selected, no command mode to cancel instead, sharing on.
---@param t string       # 'ButtonPress' or 'ButtonRelease'
---@param event table
---@param t string
---@param event table
---@param view? WorldView   # the view it came through; nil from the root frame
local function HandleRightButton(t, event, view)
    local rc = rightClick

    if t == 'ButtonPress' then
        if event.Modifiers and event.Modifiers.Left then
            -- A left press means whatever right press was open is over, even
            -- if its release went missing: the order it gave is announced
            -- (without a formation line: where it ended is not known) and the
            -- grid comes back for this one.
            if rc.press then
                FinishRightPress(event.MouseX, event.MouseY, 'left press', false)
            end
            EndMiddle(event.MouseX, event.MouseY)
            return
        end

        if event.Modifiers and event.Modifiers.Middle then
            -- Panning the camera. Nothing to report; just keep out of its way.
            rc.middle = true
            rc.since = GetSystemTimeSeconds()
            if next(dragOverlays) and not rc.suspended then
                SuspendOverlays()
            end
            return
        end

        if not (event.Modifiers and event.Modifiers.Right) then
            return
        end

        rc.press = true
        rc.since = GetSystemTimeSeconds()
        rc.inMode = CommandMode.InCommandMode() and true or false
        rc.hasSel = HasSelection()
        rc.kind = CursorData.IndexFromKey(cursor and cursor.TeamMouseOrder)
        -- No command cursor (the plain pointer, or the one over a unit you
        -- could select): a plain right click, which is a move.
        if rc.kind == 0 or rc.kind == CursorData.IndexFromKey('selectable')
            or rc.kind == CursorData.IndexFromKey('selectable-invalid') then
            rc.kind = CursorData.IndexFromKey('move')
        end
        rc.motionEvents = 0

        local ok, world = pcall(GetMouseWorldPos)
        rc.startOk = ok and IsFiniteVector(world)
        if rc.startOk then
            rc.sx, rc.sy, rc.sz = world[1], world[2], world[3]
        end

        -- Streamed as a drag from the press: with nothing selected it is a
        -- drawing.
        rc.live = rc.startOk
        rc.order = rc.startOk and rc.hasSel and not rc.inMode
            and Config.Orders.Enabled and Config.Orders.Share
        rc.drawing = rc.startOk and not rc.hasSel and not rc.inMode and Config.Draw.Enabled
        rc.sig0 = (rc.hasSel and not rc.inMode) and QueueSignature() or false
        rc.view = view or rc.view
        rc.cellEvents = 0
        rc.heldEvents = 0

        -- Keep the tracking grid up, so the pointer can be followed? It is the
        -- only thing that reports while the engine freezes the rest, and it
        -- cancels a held formation the moment the pointer crosses a cell.
        -- Drawing has no formation to cancel. Anything else (an order, a right
        -- click that cancels a command mode) gets the grid lifted.
        local overlay = view and dragOverlays[view]
        local keep = overlay and rc.drawing and Config.Orders.TrackDrawing
        rc.grid = keep and true or false

        if keep then
            -- The far end starts at the press, or a click that never moves
            -- would report wherever the pointer entered its cell.
            overlay.liveScreen[1] = event.MouseX or localMouse.x or overlay.liveScreen[1]
            overlay.liveScreen[2] = event.MouseY or localMouse.y or overlay.liveScreen[2]
            -- Up for the length of the drawing, hole under the press.
            SyncOverlays(overlay.liveScreen[1], overlay.liveScreen[2])
        elseif next(dragOverlays) then
            SuspendOverlays()
        end

        if Config.Debug then
            Log('right press: selection=' .. tostring(rc.hasSel) .. ' commandMode=' .. tostring(rc.inMode)
                .. ' -> ' .. (rc.drawing and 'drawing' or (rc.order and 'order' or 'other'))
                .. ', grid ' .. (rc.grid and 'kept up (pointer followed through it)' or 'lifted'))
        end

    elseif t == 'ButtonRelease' then
        EndMiddle(event.MouseX, event.MouseY)
        -- Any release ends it, like the left-button bookkeeping. The cost is a
        -- chorded release of some other button ending an order early.
        if rc.press then
            FinishRightPress(event.MouseX, event.MouseY, 'release event', true)
        end
    end
end

--- The blueprint on the cursor in build mode, or false.
---@return string | boolean
local function CurrentBuildId()
    if not Config.Build.Enabled then
        return false
    end
    local mode, data = unpack(CommandMode.GetCommandMode())
    if mode == 'build' and data and data.name then
        return data.name
    end
    return false
end

--- Whether the build in hand is a build template (several structures in a
--- saved layout) rather than one structure. The game puts a template in hand
--- as build mode for its first structure, plus SetActiveBuildTemplate; it is
--- cleared again on cancelling, and whenever a single structure is picked. The
--- first structure has to match the build mode too, in case one lingers.
---@return boolean
local function TemplateActive()
    local ok, template = pcall(GetActiveBuildTemplate)
    if not ok or type(template) ~= 'table' or type(template[3]) ~= 'table' then
        return false
    end
    local first = template[3][1]
    return type(first) == 'string' and first == CurrentBuildId()
end

--- A build drag was released: announce the structure placed there -- or the
--- row of them, from where the drag began to where it ended -- so teammates
--- see it land like a right-click order. Only on a real release; a drag ended
--- by a backstop placed nothing we know of.
---
--- With Orders.BuildConfirm (and the commandmode hook present) nothing is
--- queued yet: the release only opens a short wait for the game's own build
--- orders, and ResolvePendingBuild decides what, if anything, to announce.
local function AnnounceBuild()
    local bp = sendState.buildBp
    if not localSelecting or not sendState.line or not bp or not pinnedAnchor
        or not Config.Orders.Enabled or not Config.Orders.Share or not Config.Orders.ShowBuilds then
        return
    end
    local x, y, z = pinnedAnchor[1], pinnedAnchor[2], pinnedAnchor[3]
    local x2, z2 = ResolveDragBox()
    if not x2 then
        x2, z2 = x, z
    end
    local dx, dz = x2 - x, z2 - z
    local minDrag = Config.Orders.MinDragWorld
    if dx * dx + dz * dz <= minDrag * minDrag then
        x2, z2 = x, z
    end

    local bw = buildWatch
    if Config.Orders.BuildConfirm and rawget(_G, 'TeamMouseCommandHook')
        and rawget(_G, 'TeamMouseOnCommandIssued') then
        bw.pending = true
        bw.relT = GetSystemTimeSeconds()
        bw.bp = bp
        bw.ax, bw.ay, bw.az, bw.ex, bw.ez = x, y, z, x2, z2
        return
    end
    if bw.template then
        QueueOrder(0, Round1(x), Round1(y), Round1(z), Round1(x), Round1(z), 0, bp, true)
    else
        QueueOrder(0, Round1(x), Round1(y), Round1(z), Round1(x2), Round1(z2), 0, bp)
    end
end

--- The wait after a build release is over: announce what the game placed, or
--- nothing if it placed nothing.
local function ResolvePendingBuild()
    local bw = buildWatch
    if not bw.pending then
        return
    end
    bw.pending = false
    bw.armed = false

    if bw.n > 0 and bw.template then
        -- A template's structures are of several kinds, in its own layout,
        -- not a row: only the first is shown, marked as a template.
        QueueOrder(0, Round1(bw.fx), Round1(bw.fy), Round1(bw.fz), Round1(bw.fx), Round1(bw.fz), 0,
            bw.cbp or bw.bp, true)
        Debug('template placed: ' .. tostring(bw.n) .. ' build order(s) issued')
    elseif bw.n > 0 then
        -- Where the game really put them: the first structure to the last.
        QueueOrder(0, Round1(bw.fx), Round1(bw.fy), Round1(bw.fz), Round1(bw.lx), Round1(bw.lz), 0,
            bw.cbp or bw.bp)
        Debug('build placed: ' .. tostring(bw.n) .. ' build order(s) issued')
    elseif not bw.seen then
        -- The hook has never passed us a single command, so its silence says
        -- nothing (another mod may have replaced OnCommandIssued without
        -- chaining it). Announce the drag as it was, as before.
        if bw.template then
            QueueOrder(0, Round1(bw.ax), Round1(bw.ay), Round1(bw.az), Round1(bw.ax), Round1(bw.az), 0,
                bw.bp, true)
        else
            QueueOrder(0, Round1(bw.ax), Round1(bw.ay), Round1(bw.az), Round1(bw.ex), Round1(bw.ez), 0, bw.bp)
        end
        Debug('build announced unconfirmed: no command has reached the hook yet')
    else
        Debug('build placement refused by the game: not announced')
    end
end

--- A build-mode left press: build orders from here on are this press's. One
--- still waiting from the last press is settled first with what it has.
local function ArmBuild()
    local bw = buildWatch
    if bw.pending then
        ResolvePendingBuild()
    end
    bw.armed = true
    bw.n = 0
    bw.cbp = false
    bw.template = TemplateActive()
end

--- Handed every command the player issues, by the commandmode hook. Counts the
--- structures placed for the build press in progress.
---@param command table   # UserCommand: CommandType, Blueprint, Target.Position, Units
local function OnCommandIssuedListener(command)
    local bw = buildWatch
    bw.seen = true
    if not (bw.armed or bw.pending) or type(command) ~= 'table'
        or command.CommandType ~= 'BuildMobile' then
        return
    end
    -- No units: the build interface used for something else (cheat spawn, a
    -- callback) -- nothing is being built by this player.
    local units = command.Units
    if type(units) ~= 'table' or not units[1] then
        return
    end
    local pos = type(command.Target) == 'table' and command.Target.Position
    if not IsFiniteVector(pos) then
        return
    end
    bw.n = bw.n + 1
    if bw.n == 1 then
        bw.fx, bw.fy, bw.fz = pos[1], pos[2], pos[3]
        bw.cbp = type(command.Blueprint) == 'string' and command.Blueprint or false
    end
    bw.lx, bw.lz = pos[1], pos[3]
    bw.lastT = GetSystemTimeSeconds()
end

--- Per frame: settle a build release once its orders have all arrived (a
--- short lull after the first), or once it has waited long enough that none
--- are coming.
---@param now number
local function CheckPendingBuild(now)
    local bw = buildWatch
    if not bw.pending then
        return
    end
    local cfg = Config.Orders
    local waited = now - bw.relT
    if (bw.n > 0 and waited >= cfg.BuildSettle and (now - bw.lastT) >= cfg.BuildSettle)
        or waited >= cfg.BuildConfirmTimeout then
        ResolvePendingBuild()
    end
end

--- A waypoint drag was released: the order now sits where it was dropped.
local function AnnounceGrab()
    if not localSelecting or not sendState.waypoint or sendState.grabKind == 0
        or not Config.Orders.Enabled or not Config.Orders.Share or not Config.Orders.ShowGrabs then
        return
    end
    local x, z = ResolveDragBox()
    if not x then
        return
    end
    local y = pinnedAnchor and pinnedAnchor[2] or 0
    QueueOrder(sendState.grabKind, Round1(x), Round1(y), Round1(z), Round1(x), Round1(z), 0)
end

--- The cursor for each order mode, for when the cursor itself says nothing
--- more useful than the plain arrow at the moment of the click.
local MODE_CURSORS = {
    RULEUCC_Patrol = 'patrol',
    RULEUCC_Move = 'move',
    RULEUCC_Attack = 'attack',
    RULEUCC_Reclaim = 'reclaim',
    RULEUCC_Repair = 'repair',
    RULEUCC_Guard = 'guard',
    RULEUCC_Capture = 'capture',
    RULEUCC_Ferry = 'ferry',
    RULEUCC_Transport = 'transport',
    RULEUCC_Overcharge = 'overcharge',
    RULEUCC_Tactical = 'launch',
    RULEUCC_Nuke = 'launch',
}

--- A left click in an order mode (patrol, attack-move, reclaim, ...) gives
--- the order there and then: announce it like a right-click order, with its
--- own cursor as the icon.
---@param mode table   # CommandMode.GetCommandMode()
local function AnnounceModeOrder(mode)
    if not Config.Orders.Enabled or not Config.Orders.Share or not Config.Orders.ShowModeOrders
        or mode[1] ~= 'order' or not HasSelection() then
        return
    end
    local ok, world = pcall(GetMouseWorldPos)
    if not ok or not IsFiniteVector(world) then
        return
    end

    local key = cursor and cursor.TeamMouseOrder
    local kind = CursorData.IndexFromKey(key)
    if (kind == 0 or key == 'selectable') and type(mode[2]) == 'table' then
        kind = CursorData.IndexFromKey(MODE_CURSORS[mode[2].name])
    end
    local x, y, z = Round1(world[1]), Round1(world[2]), Round1(world[3])
    QueueOrder(kind, x, y, z, x, z, 0)
end

--- An action happened (a callback from actions.lua).
---@param code number
local function QueueAction(code)
    local cap = Config.Actions.MaxPerPacket
    if sendState.actCount >= cap then
        for i = 1, cap - 1 do
            sendState.acts[i] = sendState.acts[i + 1]
        end
        sendState.actCount = cap - 1
    end
    sendState.actCount = sendState.actCount + 1
    sendState.acts[sendState.actCount] = code
end

--- The actions queued since the last packet, or false.
---@return table | boolean
local function FlushActions()
    local n = sendState.actCount
    if n == 0 then
        return false
    end
    local out = {}
    for i = 1, n do
        out[i] = sendState.acts[i]
    end
    sendState.actCount = 0
    return out
end

--- Pack the queued orders for the wire, or false if there are none.
---@return table | boolean, table | boolean   # the orders, and the structure for each
local function FlushOrders()
    local n = sendState.ordCount
    if n == 0 then
        return false, false
    end

    -- mob: the structure for each order that placed one, false for the rest;
    -- only sent at all if one did. mot: which of them were templates; mou:
    -- which were upgrades.
    local mo, mob, mot, mou = {}, false, false, false
    for i = 1, n do
        if sendState.ord[i][8] then
            mob = mob or {}
            mob[i] = sendState.ord[i][8]
            if sendState.ord[i][9] then
                mot = mot or {}
                table.insert(mot, i)
            end
            if sendState.ord[i][10] then
                mou = mou or {}
                table.insert(mou, i)
            end
        end
        local o = sendState.ord[i]
        local base = (i - 1) * ORDER_STRIDE
        mo[base + 1] = o[1]
        mo[base + 2] = o[2]
        mo[base + 3] = o[3]
        mo[base + 4] = o[4]
        mo[base + 5] = o[5]
        mo[base + 6] = o[6]
        mo[base + 7] = o[7]
    end
    if mob then
        for i = 1, n do
            mob[i] = mob[i] or false
        end
    end
    sendState.ordCount = 0
    return mo, mob, mot, mou
end

--------------------------------------------------------------------------------
-- Extra samples between beats
--------------------------------------------------------------------------------

--- The state flags for right now.
---@param onHud boolean
---@return number
local function CurrentFlags(onHud)
    local f = 0
    if onHud then f = f + FLAG_HUD end
    if localSelecting then
        if sendState.plain then
            f = f + FLAG_FOLLOW
        else
            f = f + (sendState.line and FLAG_LINE or FLAG_BOX)
        end
    elseif rightClick.live then
        if rightClick.drawing then
            f = f + FLAG_DRAW
        elseif rightClick.order and Config.Orders.ShowLiveLine
            and (GetSystemTimeSeconds() - rightClick.since) >= Config.Orders.LineDelay then
            -- An order's line only exists once the button has been held long
            -- enough for the game to draw its own.
            f = f + FLAG_ORDER
        else
            f = f + FLAG_FOLLOW
        end
    end
    return f
end

--- Sample the local pointer now and keep the result for the next packet. Called
--- from the frame driver, which runs far more often than the beat; the interval
--- in the config is what decides how often a sample is actually taken.
---@param now number
local function CaptureExtra(now)
    local buf = sampleBuf
    if not buf.active then
        return
    end
    if (now - buf.lastT) < Config.Network.ExtraSamples.Interval then
        return
    end
    buf.lastT = now

    local state = ReadLocalState(buf.state)
    local x, y, z = ResolveWorldPosition(state)
    if not x then
        return
    end
    local bx, bz = ResolveDragBox()

    local capacity = Config.Network.ExtraSamples.MaxPerPacket
    local count = buf.count
    if count >= capacity then
        local evicted = buf.slots[1]
        for i = 1, capacity - 1 do
            buf.slots[i] = buf.slots[i + 1]
        end
        buf.slots[capacity] = evicted
        count = capacity - 1
    end

    count = count + 1
    local slot = buf.slots[count]
    if not slot then
        slot = {}
        buf.slots[count] = slot
    end

    slot.t = now
    slot.x, slot.y, slot.z = x, y, z
    slot.hx = math.floor(state.hudX * 1000 + 0.5) / 1000
    slot.hy = math.floor(state.hudY * 1000 + 0.5) / 1000
    slot.flags = CurrentFlags(not state.overWorld)
    if bx then
        slot.bx = math.floor(bx * 10 + 0.5) / 10
        slot.bz = math.floor(bz * 10 + 0.5) / 10
    else
        slot.bx, slot.bz = x, z
    end
    buf.count = count
end

--- Pack the samples gathered since the last packet, oldest first, and empty the
--- buffer. False when there is nothing worth sending -- no samples, or none of
--- them anywhere other than where the packet's own sample already says.
---@param now number
---@param x number    # the packet's own sample
---@param z number
---@param hx number
---@param hy number
---@param bx number   # the packet's own drag-box corner (equal to x, z when there is no drag)
---@param bz number
---@param flags number   # the packet's own state flags
---@return table | boolean
local function BuildExtras(now, x, z, hx, hy, bx, bz, flags)
    local buf = sampleBuf
    local cfg = Config.Network.ExtraSamples
    local list, n, differs = sampleBuf.packList, 0, false
    local minMove = Config.Network.MinMoveDistance

    for i = 1, buf.count do
        local s = buf.slots[i]
        local age = now - s.t
        if age >= 0.004 and age <= cfg.MaxAge then
            n = n + 1
            local item = list[n]
            if not item then
                item = {}
                list[n] = item
            end
            item.age = age
            item.x, item.z = s.x, s.z
            item.hx, item.hy = s.hx, s.hy
            item.bx, item.bz = s.bx, s.bz
            item.flags = s.flags

            -- During a drag the pointer's own position is pinned at the press
            -- point and only the box corner moves, so the corner has to count.
            if math.abs(s.x - x) > minMove or math.abs(s.z - z) > minMove
                or math.abs(s.bx - bx) > minMove or math.abs(s.bz - bz) > minMove
                or (math.abs(s.hx - hx) + math.abs(s.hy - hy)) > HUD_MIN_MOVE
                or s.flags ~= flags then
                differs = true
            end
        end
    end
    buf.count = 0

    if differs then
        -- As one short string: see wirepack.lua.
        return WirePack.PackSamples(list, n, x, z)
    end
    return false
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

    RefreshOverlayGeometry(GetSystemTimeSeconds())

    if not frameDriver then
        CreateFrameDriver()
    end
end

--------------------------------------------------------------------------------
-- The beat: gather, decide, send
--------------------------------------------------------------------------------

--- What one beat has gathered, reused every beat.
local beat = {
    x = 0, y = 0, z = 0,
    -- Our view's outline and camera (GatherViewport).
    vp = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    vpHave = false,
    vpDue = false,
    cam = { 0, 0, 0, 0, 0, 0 },
    camHave = false,
    order = 0,
    build = false,
    boxX = 0, boxZ = 0,
    hudX = 0, hudY = 0,
    onHud = false,
    flags = 0,
    extras = false,
    orders = false,
    builds = false,
    actions = false,
    applied = 0,
}

--- The order icon to report. While a waypoint is being dragged that is the
--- hand, whatever the game's cursor says from one frame to the next.
---@return number
local function CurrentOrderIndex()
    if localSelecting and sendState.waypoint then
        return CursorData.IndexFromKey('waypoint-drag')
    end
    -- A box drag shows as a plain pointer, whatever the game's cursor turns
    -- into on its way (with Shift held, the hand over every order it passes).
    if localSelecting and not sendState.line then
        return 0
    end
    return CursorData.IndexFromKey(cursor and cursor.TeamMouseOrder)
end


--- Safety valve. The drag flag is cleared by ButtonRelease, but that event can
--- be consumed before it reaches our hook -- by a dialog opening over the view,
--- for instance. Without this the selection ring would stay on a teammate's
--- screen indefinitely, and the streaming send path would never go quiet.
---@param now number
---@param state table
local function CheckStuckDrag(now, state)
    if localSelecting and ((now - selectingSince) > Config.Selection.MaxDragSeconds
        or not state.overWorld) then
        EndDrag()
    end
end

--- Fill `beat` for this moment. False if there is no position to report.
---
--- The extra samples and queued orders are taken even when the beat turns out
--- not to send, so a stale one never rides along with a later packet.
---@param now number
---@param state table
---@return boolean
--- Our main view's outline on the map, for teammates who show it
--- (Config.Viewport): its four corners, clockwise from the top left, each as
--- world x, y, z, into beat.vp. beat.vpDue when it has moved enough since it
--- was last sent to be worth sending again.
--- The camera's settings (for GatherViewport, in pcall: one function, not a
--- new closure every beat).
local function SaveCamera(camera)
    return camera and camera:SaveSettings()
end

local function GatherViewport()
    beat.vpDue = false
    beat.vpHave = false
    beat.camHave = false
    if not Config.Viewport.Share then
        return
    end

    -- The camera itself, whole (what SaveSettings says), for following a
    -- player's view in a replay: focus x, y, z, heading, pitch, zoom. Only
    -- when recording: following is for replays, and live packets stay small.
    local camera = (sendState.recording or table.getn(sendState.specTo) > 0) and GetCamera('WorldCamera')
    local okCam, settings = pcall(SaveCamera, camera)
    if okCam and type(settings) == 'table' and IsFiniteVector(settings.Focus)
        and type(settings.Heading) == 'number' and type(settings.Pitch) == 'number'
        and type(settings.Zoom) == 'number' then
        local cam = beat.cam
        cam[1], cam[2], cam[3] = Round1(settings.Focus[1]), Round1(settings.Focus[2]), Round1(settings.Focus[3])
        cam[4] = math.floor(settings.Heading * 1000 + 0.5) / 1000
        cam[5] = math.floor(settings.Pitch * 1000 + 0.5) / 1000
        cam[6] = Round1(settings.Zoom)
        beat.camHave = true
        local sent = sendState.camSent
        if not sendState.vpT or math.abs(cam[1] - sent[1]) > 0.5 or math.abs(cam[3] - sent[3]) > 0.5
            or math.abs(cam[4] - sent[4]) > 0.005 or math.abs(cam[5] - sent[5]) > 0.005
            or math.abs(cam[6] - sent[6]) > 0.5 then
            beat.vpDue = true
        end
    end

    local views = WorldViewManager.GetWorldViews()
    local view = views and views['WorldCamera']
    if not view or view:IsHidden() then
        return
    end
    local l, t, r, b = view.Left() + 1, view.Top() + 1, view.Right() - 1, view.Bottom() - 1
    local vp = beat.vp
    local sx = sendState.vpCornerX
    local sy = sendState.vpCornerY
    sx[1], sx[2], sx[3], sx[4] = l, r, r, l
    sy[1], sy[2], sy[3], sy[4] = t, t, b, b
    for i = 1, 4 do
        local world = UnProjectAt(view, sx[i], sy[i])
        if not world then
            return
        end
        vp[i * 3 - 2], vp[i * 3 - 1], vp[i * 3] = Round1(world[1]), Round1(world[2]), Round1(world[3])
    end
    beat.vpHave = true
    if beat.vpDue then
        return
    end

    local sent = sendState.vpSent
    if not sendState.vpT then
        beat.vpDue = true
        return
    end
    local min = Config.Viewport.MinChange
    for i = 1, 12 do
        if math.abs(vp[i] - sent[i]) > min then
            beat.vpDue = true
            return
        end
    end
end

local function GatherBeat(now, state)
    local x, y, z = ResolveWorldPosition(state)
    if not x then
        return false
    end

    -- Zoom is only meaningful while the mouse is over a world view. Hold the
    -- last real value rather than sending zero, so a teammate's cursor does
    -- not snap back to unit scale every time they dip into their interface.
    if state.zoom > 0 then
        worldHold.zoom = state.zoom
    end

    -- No drag in progress: a degenerate, zero-size box at the pointer, never
    -- 0,0 (which would draw a box streaking across a teammate's screen).
    local boxX, boxZ = ResolveDragBox()

    beat.x, beat.y, beat.z = x, y, z
    beat.order = CurrentOrderIndex()
    beat.build = CurrentBuildId()
    beat.template = beat.build and TemplateActive() or false
    beat.boxX, beat.boxZ = boxX or x, boxZ or z
    beat.hudX = math.floor(state.hudX * 1000 + 0.5) / 1000
    beat.hudY = math.floor(state.hudY * 1000 + 0.5) / 1000
    beat.onHud = not state.overWorld
    beat.flags = CurrentFlags(beat.onHud)
    beat.extras = BuildExtras(now, x, z, beat.hudX, beat.hudY, beat.boxX, beat.boxZ, beat.flags)
    beat.orders, beat.builds, beat.templates, beat.upgrades = FlushOrders()
    beat.actions = FlushActions()
    beat.applied = rightClick.appliedOut
    rightClick.appliedOut = 0
    GatherViewport()
    return true
end

--- Is this beat worth a packet?
---@param now number
---@param state table
---@return boolean
local function BeatChanged(now, state)
    local minMove = Config.Network.MinMoveDistance
    local dx = beat.x - sendState.pos[1]
    local dy = beat.y - sendState.pos[2]
    local dz = beat.z - sendState.pos[3]
    if (dx * dx + dy * dy + dz * dz) > minMove * minMove then
        return true
    end

    -- On the HUD the world position is held, so it never "moves" there.
    -- Pointer motion across the interface has to count on its own, or the
    -- ghost only updates on the forced resend.
    if beat.onHud and (math.abs(state.hudX - sendState.hudX)
        + math.abs(state.hudY - sendState.hudY)) > HUD_MIN_MOVE then
        return true
    end

    return beat.order ~= sendState.order
        or beat.onHud ~= sendState.hud
        -- Whatever they are doing changing is news in itself: a drag or a
        -- drawing ending, an order's line coming due.
        or beat.flags ~= sendState.flags
        -- An order given is news whether or not the pointer moved, and so is
        -- one reaching the sim.
        or beat.orders ~= false
        or beat.actions ~= false
        or beat.applied > 0
        -- Keep streaming throughout any drag, so it stays live on the other
        -- end rather than updating once per second.
        or localSelecting
        or rightClick.live
        -- The camera moved, though the pointer may not have.
        or beat.vpDue
        -- Or just zoomed: the zoom bar under their name should not wait for
        -- the resend below.
        or math.floor(worldHold.zoom + 0.5) ~= sendState.sentZoom
        -- Or clicked, or selected something else.
        or sendState.clicks > 0
        or sendState.selDue
        or (now - sendState.time) >= Config.Network.ForceResendInterval
end

--- Remember what was sent, to compare the next beat against.
---@param now number
---@param state table
local function RecordSent(now, state)
    sendState.pos[1], sendState.pos[2], sendState.pos[3] = beat.x, beat.y, beat.z
    sendState.order = beat.order
    sendState.hud = beat.onHud
    sendState.hudX, sendState.hudY = state.hudX, state.hudY
    sendState.flags = beat.flags
    sendState.time = now
end

--- `value` if `present`, else nil -- a field left off the packet.
---@param present any
---@param value any
---@return any
local function OptionalValue(present, value)
    if present then
        return value
    end
    return nil
end

--- A whole non-negative number in base 36.
---@param n number
---@return string
local function Base36(n)
    local digits = '0123456789abcdefghijklmnopqrstuvwxyz'
    n = math.floor(n)
    if n < 0 then n = 0 end
    local s = ''
    repeat
        local d = math.mod(n, 36)
        s = string.sub(digits, d + 1, d + 1) .. s
        n = math.floor(n / 36)
    until n == 0
    return s
end

--- The selection's ids, packed for the wire: base 36, comma-separated
--- ("1048612" is "mh3o"). A list of separate strings made a packet big
--- enough that a selection sent over chat may not have arrived at all.
---@param ids string[]
---@return string
local function PackIds(ids)
    local out = {}
    for _, id in ipairs(ids) do
        local n = tonumber(id)
        if n and n >= 0 then
            table.insert(out, Base36(n))
        end
    end
    return table.concat(out, ',')
end

--- Send `outgoing` as it stands: the compact string (wirecodec.lua) to
--- `compactTo`, the plain table to `plainTo` -- and to `compactTo` as well
--- when the packet has no exact compact form. Returns the string sent (false
--- if there was none) when there were compact recipients, nil otherwise.
---@param compactTo number[]
---@param plainTo number[]
---@return string | boolean | nil
local function Deliver(compactTo, plainTo)
    local wire = nil
    if table.getn(compactTo) > 0 then
        wire = WireCodec.Encode(outgoing) or false
        if wire then
            local out = sendState.compactOut
            out[Config.ChatIdentifier] = wire
            SessionSendChatMessage(compactTo, out)
        else
            SessionSendChatMessage(compactTo, outgoing)
        end
    end
    if table.getn(plainTo) > 0 then
        SessionSendChatMessage(plainTo, outgoing)
    end
    return wire
end

--- Send `beat`: the full packet to teammates, the legacy packet for older
--- builds, and optionally the commander-name copy for replays.
---@param now number
---@param state table
local function Transmit(now, state)
    -- Anyone to send to? (Not if every one of them has hidden our cursor.)
    local sharing = table.getn(sendState.teamLive) + table.getn(sendState.specLive) > 0
    if sharing or sendState.recording then
        local _, dragKind = DecodeFlags(beat.flags)
        local Opt = OptionalValue
        outgoing.a = myArmy
        outgoing.p[1], outgoing.p[2], outgoing.p[3] = beat.x, beat.y, beat.z
        -- The order cursor when it changes, and with the keep-alive.
        local sendOrder = beat.order ~= sendState.sentOrder
            or (now - sendState.orderT) >= Config.Network.ForceResendInterval
        outgoing.o = Opt(sendOrder, beat.order)
        if sendOrder then
            sendState.sentOrder = beat.order
            sendState.orderT = now
        end

        -- Zoom when it changes, and now and then in case a packet was lost.
        local zoom = math.floor(worldHold.zoom + 0.5)
        if zoom ~= sendState.sentZoom or (now - sendState.zoomT) >= Config.Network.ForceResendInterval then
            outgoing.z = zoom
            sendState.sentZoom = zoom
            sendState.zoomT = now
        else
            outgoing.z = nil
        end

        local onHud = not state.overWorld
        outgoing.w = Opt(onHud, false)
        outgoing.s = Opt(dragKind == 1, true)
        outgoing.l = Opt(dragKind == 2, true)
        outgoing.r = Opt(dragKind == 3, true)
        outgoing.d = (dragKind == 4 and 1) or (dragKind == 5 and 2) or nil
        outgoing.b = Opt(beat.build, beat.build)
        outgoing.bt = Opt(beat.template, true)
        outgoing.hx = Opt(onHud, beat.hudX)
        outgoing.hy = Opt(onHud, beat.hudY)
        outgoing.bx = Opt(dragKind ~= 0, beat.boxX)
        outgoing.bz = Opt(dragKind ~= 0, beat.boxZ)
        outgoing.e = Opt(beat.extras, beat.extras)
        outgoing.mo = Opt(beat.orders, beat.orders)
        outgoing.mob = Opt(beat.builds, beat.builds)
        outgoing.mot = Opt(beat.templates, beat.templates)
        outgoing.mou = Opt(beat.upgrades, beat.upgrades)
        outgoing.ac = Opt(beat.actions, beat.actions)
        outgoing.gk = Opt(localSelecting and sendState.waypoint and sendState.grabKind > 0
            and Config.Orders.ShowGrabs, sendState.grabKind)
        outgoing.oa = Opt(beat.applied > 0, beat.applied)

        -- Clicks since the last packet, for a pulse at the cursor's tip.
        outgoing.ck = Opt(sendState.clicks > 0, sendState.clicks)
        sendState.clicks = 0

        -- Our selection when it changes, and now and then regardless (for an
        -- observer arriving late). Where they were goes only with a change: a
        -- teammate's boxes for it fade, and a repeat must not bring them back.
        local selChanged = sendState.selDue or not sendState.selT
        local sendSel = sendState.selWatch and (selChanged
            or (now - sendState.selT) >= Config.TeamSelection.ResendInterval)
        sendSel = sendSel and Config.TeamSelection.Enabled
        outgoing.sel = Opt(sendSel, sendSel and PackIds(sendState.sel))
        -- Their sizes go with the ids (doubled, base 36).
        local sizes = false
        if sendSel then
            local list = {}
            for i, size in ipairs(sendState.selSizes) do
                list[i] = Base36(size * 2 + 0.5)
            end
            sizes = table.concat(list, ',')
        end
        outgoing.ss = Opt(sendSel, sizes)
        -- Too many for a box each: rectangles round the bunches, instead of
        -- where each one is.
        local rects = sendSel and selChanged and Config.TeamSelection.SendPositions and sendState.selRects
        outgoing.sr = Opt(rects, rects)
        outgoing.sq = Opt(sendSel and selChanged and Config.TeamSelection.SendPositions and not rects,
            sendState.selPlaces)
        if sendSel then
            sendState.selDue = false
            sendState.selT = now
        end

        -- Our view's outline and camera, when they have moved, and now and
        -- then regardless.
        -- Refreshed on its own, slower clock: when the camera is still, the
        -- outline cannot have changed, and it is the biggest thing in a packet.
        local viewDue = beat.vpDue or not sendState.vpT
            or (now - sendState.vpT) >= Config.Viewport.ResendInterval
        local sendVp = beat.vpHave and viewDue
        local sendCam = beat.camHave and viewDue
        outgoing.vp = Opt(sendVp, beat.vp)
        outgoing.cam = nil
        if sendVp then
            local sent = sendState.vpSent
            for i = 1, 12 do sent[i] = beat.vp[i] end
        end
        if sendCam then
            local sent = sendState.camSent
            for i = 1, 6 do sent[i] = beat.cam[i] end
        end
        if sendVp or sendCam then
            sendState.vpT = now
        end

        -- Teammates: the packet. Observers: the same, and our camera, which
        -- they can follow (teammates do not follow, so are not sent it). Each
        -- as the compact string to those who read it (wirecodec.lua), the
        -- plain table to the rest; without a camera to add, teammates and
        -- observers get the one message.
        local wire
        if sendCam and table.getn(sendState.specLive) > 0 then
            Deliver(sendState.teamC, sendState.teamP)
            outgoing.cam = beat.cam
            wire = Deliver(sendState.specC, sendState.specP)
        else
            wire = Deliver(sendState.allC, sendState.allP)
            if sendCam then
                -- No observers to send it: only the replay's copy has it.
                outgoing.cam = beat.cam
                wire = nil
            end
        end
        -- The very same packet into the replay (see replaycodec.lua), camera
        -- and all: the compact string, or the table if it has no exact one.
        if sendState.recording then
            if wire == nil then
                wire = WireCodec.Encode(outgoing) or false
            end
            ReplayCodec.Record(wire or outgoing, myArmy)
        end
        outgoing.cam = nil
    end

    -- The old SharedMouse format, only to teammates seen using it: every
    -- TeamMouse client reads the packet above instead.
    if table.getn(sendState.legacyTo) > 0 then
        LegacyProtocol.PopulatePacket(legacyOutgoing, beat.x, beat.y, beat.z, beat.order)
        SessionSendChatMessage(sendState.legacyTo, legacyOutgoing)
    end

end

--- One beat for a player: read the pointer, and send if anything changed.
local function PlayerBeat()
    local now = GetSystemTimeSeconds()
    sendState.lastRun = now
    Version.Tick(now)
    CheckRightPress(now)
    local state = ReadLocalState(sendState.state)
    CheckStuckDrag(now, state)
    CheckSelection()
    CheckUpgrades(now)
    if GatherBeat(now, state) and BeatChanged(now, state) then
        RecordSent(now, state)
        Transmit(now, state)
    end
end

function OnBeat()
    if not initialised then
        return
    end

    if not sendState.compactStarted then
        sendState.compactStarted = true
        pcall(StartCompact)
    end

    -- Observers and replay viewers still need this, even though they never
    -- transmit -- they have cursors to keep parented to live views.
    local viewsOk, viewsErr = pcall(VerifyViews)
    if not viewsOk then
        Log('view check error: ' .. tostring(viewsErr))
    end

    pcall(Panel.Refresh)

    if isObserver or isReplay then
        return
    end

    local ok, err = pcall(PlayerBeat)
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
    replay = false,   -- set once at init: cursors are drawn for replay viewing
}

--- Drop right-click orders that have run their course. Expired ones are
--- swapped to the end of the array and left out of the count, never set to nil,
--- so the slot tables are reused (see the note above PushSample).
---@param record table
---@param now number
local function PruneOrders(record, now)
    local count = record.orderCount
    if count == 0 then
        return
    end

    local orders = record.orders
    local lifetime = Config.Orders.Lifetime
    local keep = 0
    for i = 1, count do
        local order = orders[i]
        if (now - order.t) <= lifetime then
            keep = keep + 1
            if keep ~= i then
                orders[i] = orders[keep]
                orders[keep] = order
            end
        end
    end
    record.orderCount = keep
end

--- A replay that is paused sends nothing: no sim, no recorded packets. Hold
--- every cursor's age still meanwhile, so none of them goes stale and fades
--- away while the viewer looks at the paused game.
---@param delta number
local function HoldWhilePaused(delta)
    if not isReplay then
        return
    end
    local ok, paused = pcall(SessionIsPaused)
    if not ok or not paused then
        return
    end
    for _, record in pairs(peers) do
        if record.hasData then
            record.lastUpdate = record.lastUpdate + delta
        end
    end
end

--- Where the followed camera is now, on its way to the player's (replays).
--- army: whose it is following (false: nobody), so a new choice starts from
--- where the camera already is rather than jumping.
local follow = { army = false, fx = 0, fy = 0, fz = 0, heading = 0, pitch = 0, zoom = 1, selVersion = -1 }

--- Replays: the viewer's camera follows the player whose "follow" box is
--- ticked in the panel. Each frame it moves part of the way to where theirs
--- last was (Follow.Rate), so their updates -- about ten a second, and only
--- when their camera moves -- read as smooth motion rather than steps. The
--- heading turns the short way round; the zoom eases on a log scale, so
--- zooming reads as even.
---@param delta number
local function FollowPass(delta)
    if not (isReplay or isObserver) or not Config.Follow.Enabled then
        return
    end
    local target = false
    for _, record in pairs(peers) do
        if record.follow and record.hasData then
            target = record
            break
        end
    end
    if not target then
        follow.army = false
        return
    end

    local camera = GetCamera('WorldCamera')
    if not camera then
        return
    end
    local ok, mine = pcall(function() return camera:SaveSettings() end)
    if not ok or type(mine) ~= 'table' or not IsFiniteVector(mine.Focus)
        or type(mine.Heading) ~= 'number' or type(mine.Pitch) ~= 'number' or type(mine.Zoom) ~= 'number' then
        return
    end

    -- Where they are looking.
    local cam = target.cam
    if not cam then
        return
    end
    local tx, ty, tz, th, tp, tzoom = cam[1], cam[2], cam[3], cam[4], cam[5], cam[6]

    if follow.army ~= target.army then
        follow.army = target.army
        follow.fx, follow.fy, follow.fz = mine.Focus[1], mine.Focus[2], mine.Focus[3]
        follow.heading, follow.pitch, follow.zoom = mine.Heading, mine.Pitch, math.max(mine.Zoom, 1)
        follow.selVersion = -1
    end

    -- In a replay, their selection is ours too while we follow them.
    if isReplay and Config.Follow.CopySelection and follow.selVersion ~= target.selVersion then
        follow.selVersion = target.selVersion
        local units = {}
        for _, id in ipairs(target.sel) do
            local ok, unit = pcall(GetUnitById, id)
            if ok and unit then
                table.insert(units, unit)
            end
        end
        pcall(SelectUnits, units)
    end

    local k = 1 - math.exp(-Config.Follow.Rate * delta)
    follow.fx = follow.fx + (tx - follow.fx) * k
    follow.fy = follow.fy + (ty - follow.fy) * k
    follow.fz = follow.fz + (tz - follow.fz) * k
    local turn = th - follow.heading
    while turn > math.pi do turn = turn - 2 * math.pi end
    while turn < -math.pi do turn = turn + 2 * math.pi end
    follow.heading = follow.heading + turn * k
    follow.pitch = follow.pitch + (tp - follow.pitch) * k
    if tzoom < 1 then tzoom = 1 end
    follow.zoom = math.exp(math.log(follow.zoom) + (math.log(tzoom) - math.log(follow.zoom)) * k)

    pcall(function()
        camera:RestoreSettings({ Focus = { follow.fx, follow.fy, follow.fz },
            Heading = follow.heading, Pitch = follow.pitch, Zoom = follow.zoom })
    end)
end

--- What only a replay does each frame: hold cursors still while paused, and
--- follow a player's camera.
---@param delta number
local function ReplayFrame(delta)
    HoldWhilePaused(delta)
    FollowPass(delta)
end

local function UpdateFrame(delta)
    local now = GetSystemTimeSeconds()

    local mouseX, mouseY = false, false
    if localMouse.x then
        mouseX, mouseY = localMouse.x, localMouse.y
    end

    -- The tracking grid is only up during a left press: take it down once one
    -- has ended however it ended (a release the view heard already did).
    -- Costs a comparison per view when nothing changes.
    SyncOverlays(mouseX, mouseY)

    -- A build release waiting to hear whether the game placed anything.
    CheckPendingBuild(now)


    -- Between beats, note where our own pointer is. (Does nothing unless this
    -- is a player with someone to send to, and only once per interval.)
    CaptureExtra(now)

    -- The beat is what normally sends, but it can't be relied on for timing:
    -- FAF skips a throttled beat function whenever a sim beat comes in under
    -- 0.1s after the last, so a beat a hair early is dropped and the next
    -- packet leaves ~0.2s after the one before -- longer than teammates
    -- render behind, so their copy of the cursor stalls until it arrives. A
    -- slow or uneven sim spaces beats out further still. So if too long has
    -- passed since the last one, send from here.
    if sampleBuf.active and (now - sendState.lastRun) >= Config.Network.MaxSendGap then
        local ok, err = pcall(PlayerBeat)
        if not ok then
            Log('send error: ' .. tostring(err))
        end
    end

    ReplayFrame(delta)

    -- Advance every peer's interpolated position and crossfade.
    local fadeStep = Config.Smoothing.FadeSpeed * delta
    if fadeStep > 1 then fadeStep = 1 end

    for _, record in pairs(peers) do
        if record.hasData then
            Interpolate(record, now)
            PruneOrders(record, now)
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
                viewInfo.minZoom, viewInfo.maxZoom = false, false
                local camera = GetCamera(view._cameraName)
                if camera then
                    viewInfo.zoom = camera:GetZoom()
                    -- How far in and out this camera goes (the map decides
                    -- the far end), for the name bar and view outlines. It
                    -- hardly ever changes: read once a second, kept on the view.
                    local limits = view.TeamMouseZoomLimits
                    if not limits or (now - limits.t) >= 1 then
                        limits = limits or {}
                        limits.t = now
                        limits.min, limits.max = false, false
                        local okMin, zMin = pcall(camera.GetMinZoom, camera)
                        local okMax, zMax = pcall(camera.GetMaxZoom, camera)
                        if okMin and okMax and type(zMin) == 'number' and type(zMax) == 'number'
                            and zMax > zMin then
                            limits.min, limits.max = zMin, zMax
                        end
                        view.TeamMouseZoomLimits = limits
                    end
                    viewInfo.minZoom, viewInfo.maxZoom = limits.min, limits.max
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

    frameDriver = Group(frame, 'TeamMouseDriver')
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

--- A button press on a world view, for the left button: a selection box, a
--- structure line, a waypoint being moved, or an order-mode click. Split out
--- of HookViewEvents to keep it well under Lua 5.0's upvalue limit.
---@param self WorldView
---@param event table
local function HandleLeftPress(self, event)
    -- A left press is a selection drag, or in build mode a drag
    -- that lays a line of structures. Any other command mode is
    -- neither.
    local buildDrag = false
    local inMode = CommandMode.InCommandMode()
    if inMode and Config.Line.Enabled then
        buildDrag = IsBuildMode()
    end
    local mods = event.Modifiers
    if Config.Debug and mods and mods.Left then
        Log('left press: shift=' .. tostring(mods.Shift and true or false)
            .. ' ctrl=' .. tostring(mods.Ctrl and true or false)
            .. ' alt=' .. tostring(mods.Alt and true or false)
            .. ' commandMode=' .. tostring(inMode and true or false)
            .. ' selection=' .. tostring(HasSelection())
            .. ' cursor=' .. tostring(cursor and cursor.TeamMouseOrder))
    end
    if mods and mods.Left and inMode and not buildDrag then
        local okMode, mode = pcall(CommandMode.GetCommandMode)
        if okMode and type(mode) == 'table' then
            AnnounceModeOrder(mode)
        end
    end
    if mods and mods.Left and (not inMode or buildDrag) then
        localSelecting = true
        sendState.line = buildDrag
        sendState.buildBp = buildDrag and CurrentBuildId() or false
        if buildDrag then
            ArmBuild()
        end
        sendState.plain = false
        sendState.dragX = event.MouseX or localMouse.x or 0
        sendState.dragY = event.MouseY or localMouse.y or 0
        -- Pressed on a waypoint: this drag moves it, and is no box.
        local grabPos = nil
        if not buildDrag and IsWaypointCursor(cursor and cursor.TeamMouseOrder) then
            sendState.waypoint = true
            sendState.plain = true
            sendState.grabKind, grabPos = GrabbedCommand()
            sendState.grabKind = sendState.grabKind or 0
        end
        selectingSince = GetSystemTimeSeconds()
        activeDragView = self

        -- The far corner starts at the press. It is otherwise only
        -- updated when the pointer crosses into a new cell, so it
        -- would hold wherever the pointer entered the cell it's
        -- resting in -- most of a cell away, drawing a box for a
        -- click that never moved.
        local overlay = dragOverlays[self]
        if overlay then
            overlay.liveScreen[1] = event.MouseX or localMouse.x or overlay.liveScreen[1]
            overlay.liveScreen[2] = event.MouseY or localMouse.y or overlay.liveScreen[2]
        end
        -- The grid comes up now, with its hole under the press (the press
        -- itself has already landed on the view), and goes again the moment
        -- the release does (LowerGridNow).
        sendState.pressX = event.MouseX or localMouse.x or 0
        sendState.pressY = event.MouseY or localMouse.y or 0
        RaiseGridForDrag(sendState.pressX, sendState.pressY)

        local ok, world = pcall(GetMouseWorldPos)
        if grabPos then
            -- The order's own spot, which the line runs back to.
            pinnedAnchor = grabPos
        elseif ok and IsFiniteVector(world) then
            pinnedAnchor = { world[1], world[2], world[3] }
        else
            pinnedAnchor = false
        end
    end
end

-- Hook ingame "WorldCamera" event handler
---@param view WorldView
--------------------------------------------------------------------------------
-- Upgrades and selections, for teammates
--------------------------------------------------------------------------------

--- The game's upgrade functions as they were before we wrapped them.
local upgradeOriginals = {}

--- Upgrading `units` to `bp`: each goes to teammates as a structure marker on
--- the building, flagged as an upgrade (mou), so they see what it becomes.
---@param units any   # UserUnit[]
---@param bp any
local function NoteUpgrade(units, bp)
    local cfg = Config.Orders
    if not (cfg.Enabled and cfg.Share and cfg.ShowBuilds and cfg.ShowUpgrades)
        or type(bp) ~= 'string' or type(units) ~= 'table' then
        return
    end
    local n = 0
    for _, unit in ipairs(units) do
        -- Told once per upgrade: CheckUpgrades will see it start, too.
        local okId, id = pcall(unit.GetEntityId, unit)
        local w = okId and sendState.watch[tostring(id)]
        if w then
            w.announced = true
            w.announcedT = GetSystemTimeSeconds()
        end
        local ok, pos = pcall(unit.GetPosition, unit)
        if ok and IsFiniteVector(pos) then
            local x, y, z = Round1(pos[1]), Round1(pos[2]), Round1(pos[3])
            QueueOrder(0, x, y, z, x, z, 0, bp, false, true)
            n = n + 1
            if n >= cfg.MaxPerPacket then
                break
            end
        end
    end
end

--- Wrap the three ways the game issues an upgrade (FAF calls them by their
--- global names: the build menu, hotkeys, hotbuild, auto-upgrade). The
--- original always runs, whatever becomes of noting it.
local function HookUpgrades()
    local function Wrap(name, unitsOf)
        local original = rawget(_G, name)
        if type(original) ~= 'function' or upgradeOriginals[name] then
            return
        end
        upgradeOriginals[name] = original
        rawset(_G, name, function(a, b, c, d, e)
            pcall(unitsOf, a, b, c)
            return original(a, b, c, d, e)
        end)
    end
    -- (command, bp, count, clear): the selection
    Wrap('IssueBlueprintCommand', function(command, bp)
        if command == 'UNITCOMMAND_Upgrade' then
            NoteUpgrade(GetSelectedUnits(), bp)
        end
    end)
    -- (units, command, bp, count, clear)
    Wrap('IssueBlueprintCommandToUnits', function(units, command, bp)
        if command == 'UNITCOMMAND_Upgrade' then
            NoteUpgrade(units, bp)
        end
    end)
    -- (unit, command, bp, count, clear)
    Wrap('IssueBlueprintCommandToUnit', function(unit, command, bp)
        if command == 'UNITCOMMAND_Upgrade' then
            NoteUpgrade({ unit }, bp)
        end
    end)
end

local function UnhookUpgrades()
    for name, original in pairs(upgradeOriginals) do
        rawset(_G, name, original)
    end
    upgradeOriginals = {}
end

--- How big a unit is, from its own blueprint: the biggest of its skirt (a
--- structure's pad), footprint and body.
---@param unit UserUnit
---@return number
local function UnitSize(unit)
    local size = 1
    local okBp, bp = pcall(unit.GetBlueprint, unit)
    if okBp and type(bp) == 'table' then
        local ph, fp = bp.Physics or {}, bp.Footprint or {}
        -- (Not ipairs: any of these may be missing, and ipairs stops at the
        -- first gap.)
        local dims = { ph.SkirtSizeX, ph.SkirtSizeZ, fp.SizeX, fp.SizeZ, bp.SizeX, bp.SizeZ }
        for k = 1, 6 do
            local v = dims[k]
            if type(v) == 'number' and v > size then size = v end
        end
    end
    return size
end

--- More units selected than TeamSelection.MaxSend: rectangles round the ones
--- close together, packed for the wire (sr). Units are put in grid cells of
--- ClusterCell world units, each cell's units get one rectangle round them
--- (padded by their size), and rectangles that overlap become one; while
--- that still leaves more than MaxRects, the cells are made twice as big, up
--- to ClusterMaxCell -- far-apart units are never lumped into one huge box.
--- Each "x1,z1,x2,z2,y", x and z in quarter units, base 36, ';' between.
---@param units UserUnit[]
---@return string
local function SelectionRects(units)
    local cfg = Config.TeamSelection
    local points = {}
    for _, unit in ipairs(units) do
        if table.getn(points) >= cfg.MaxCluster then break end
        local ok, pos = pcall(unit.GetPosition, unit)
        if ok and IsFiniteVector(pos) then
            table.insert(points, { pos[1], pos[3], pos[2], UnitSize(unit) * 0.5 + cfg.Margin })
        end
    end

    local rects
    local cell = cfg.ClusterCell
    while true do
        -- One rectangle per occupied cell.
        local byCell = {}
        rects = {}
        for _, p in ipairs(points) do
            local key = math.floor(p[1] / cell) .. ',' .. math.floor(p[2] / cell)
            local r = byCell[key]
            if not r then
                r = { p[1] - p[4], p[2] - p[4], p[1] + p[4], p[2] + p[4], p[3] }
                byCell[key] = r
                table.insert(rects, r)
            else
                if p[1] - p[4] < r[1] then r[1] = p[1] - p[4] end
                if p[2] - p[4] < r[2] then r[2] = p[2] - p[4] end
                if p[1] + p[4] > r[3] then r[3] = p[1] + p[4] end
                if p[2] + p[4] > r[4] then r[4] = p[2] + p[4] end
            end
        end
        -- Overlapping rectangles become one, until none overlap.
        local merged = true
        while merged do
            merged = false
            for i = table.getn(rects), 2, -1 do
                local a = rects[i]
                for j = i - 1, 1, -1 do
                    local b = rects[j]
                    if a[1] <= b[3] and b[1] <= a[3] and a[2] <= b[4] and b[2] <= a[4] then
                        if a[1] < b[1] then b[1] = a[1] end
                        if a[2] < b[2] then b[2] = a[2] end
                        if a[3] > b[3] then b[3] = a[3] end
                        if a[4] > b[4] then b[4] = a[4] end
                        table.remove(rects, i)
                        merged = true
                        break
                    end
                end
            end
        end
        if table.getn(rects) <= cfg.MaxRects or cell * 2 > cfg.ClusterMaxCell then
            break
        end
        cell = cell * 2
    end

    local parts = {}
    for i, r in ipairs(rects) do
        if i > cfg.MaxRects then break end
        table.insert(parts, Base36(math.max(r[1], 0) * 4 + 0.5) .. ',' .. Base36(math.max(r[2], 0) * 4 + 0.5)
            .. ',' .. Base36(r[3] * 4 + 0.5) .. ',' .. Base36(r[4] * 4 + 0.5) .. ',' .. Base36(r[5] + 0.5))
    end
    return table.concat(parts, ';')
end

--- Our selection changed: note its units' ids (up to TeamSelection.MaxSend)
--- for the next packet (sel).
---@param units any   # UserUnit[] or nil
local function NoteSelection(units)
    local ids = sendState.sel
    for i = table.getn(ids), 1, -1 do
        table.remove(ids)
    end
    if type(units) == 'table' then
        for _, unit in ipairs(units) do
            local ok, id = pcall(unit.GetEntityId, unit)
            if ok and (type(id) == 'string' or type(id) == 'number') then
                table.insert(ids, tostring(id))
                if table.getn(ids) >= Config.TeamSelection.MaxSend then
                    break
                end
            end
        end
    end
    -- (With how many there are: past MaxSend, more units change the
    -- rectangles though not the ids.)
    local total = type(units) == 'table' and table.getn(units) or 0
    local key = table.concat(ids, ',') .. '#' .. total
    if key ~= sendState.selKey then
        sendState.selKey = key
        sendState.selDue = true
        -- A click just before (or just after, see NoteClick) that selected
        -- something: a pulse.
        if table.getn(ids) > 0 then
            -- A click just before that selected something: a pulse. Where the
            -- pointer is now settles a drag the view never heard move.
            local overlay = activeDragView and dragOverlays[activeDragView]
            if overlay then
                NoteClickMove(overlay.liveScreen[1], overlay.liveScreen[2])
            end
            local now = GetSystemTimeSeconds()
            if sendState.clickT and (now - sendState.clickT) <= Config.ClickPulse.SelectWindow then
                CountClick()
            end
        else
            -- The click selected nothing (the ground): no pulse for it.
            sendState.clickT = false
        end

        -- What to tell teammates beyond the ids: each unit's size (its own
        -- blueprint: skirt, footprint or body, whichever is biggest), and
        -- where each is right now. A player cannot look a teammate's units up
        -- by id in a live game (an engine rule: only observers can), so a
        -- teammate shows the boxes where they were when selected, and fades
        -- them like any other marker; an observer or a replay tracks the
        -- units themselves. x and z in quarter world units, y whole, base 36,
        -- "x,z,y" per unit, ';' between.
        local sizes, places = sendState.selSizes, {}
        for i = table.getn(sizes), 1, -1 do table.remove(sizes) end
        if type(units) == 'table' then
            for _, unit in ipairs(units) do
                if table.getn(sizes) >= table.getn(ids) then break end
                local okPos, pos = pcall(unit.GetPosition, unit)
                if okPos and IsFiniteVector(pos) then
                    table.insert(places, Base36(pos[1] * 4 + 0.5) .. ',' .. Base36(pos[3] * 4 + 0.5)
                        .. ',' .. Base36(pos[2] + 0.5))
                else
                    table.insert(places, '')
                end
                table.insert(sizes, UnitSize(unit))
            end
        end
        sendState.selPlaces = table.concat(places, ';')
        -- More than we send ids for: rectangles round the bunches instead.
        sendState.selRects = false
        if total > Config.TeamSelection.MaxSend then
            sendState.selRects = SelectionRects(units)
        end
    end

    -- Structures in it are watched for an upgrade starting (CheckUpgrades).
    if type(units) == 'table' then
        local now = GetSystemTimeSeconds()
        local watch = sendState.watch
        for i, unit in ipairs(units) do
            local id = ids[i]
            if id and (watch[id] or sendState.watchCount < Config.Orders.UpgradeWatchMax) then
                local okCat, structure = pcall(unit.IsInCategory, unit, 'STRUCTURE')
                if okCat and structure then
                    if not watch[id] then
                        watch[id] = { unit = unit, t = now, announced = false }
                        sendState.watchCount = sendState.watchCount + 1
                    else
                        watch[id].t = now
                    end
                end
            end
        end
    end
end

--- Each beat: has any watched structure started upgrading? It is then
--- building a structure in its own place (GetFocus). Whichever way the upgrade
--- was ordered -- the build menu, the upgrade hotkey (which keeps its own copy
--- of the game's function, out of HookUpgrades' reach), another mod -- this
--- sees it. Structures not selected for UpgradeWatchSeconds are let go.
---@param now number
function CheckUpgrades(now)
    local watch = sendState.watch
    for id, w in pairs(watch) do
        local unit = w.unit
        local okDead, dead = pcall(unit.IsDead, unit)
        if not okDead or dead or (now - w.t) > Config.Orders.UpgradeWatchSeconds then
            watch[id] = nil
            sendState.watchCount = sendState.watchCount - 1
        else
            local okFocus, focus = pcall(unit.GetFocus, unit)
            focus = okFocus and focus or nil
            local okCat, structure = false, false
            if focus then
                okCat, structure = pcall(focus.IsInCategory, focus, 'STRUCTURE')
            end
            if okCat and structure then
                -- Upgrading: told once, whether here or already by
                -- NoteUpgrade when it was ordered.
                w.busy = true
                if not w.announced then
                    local okBp, bp = pcall(focus.GetUnitId, focus)
                    if okBp and type(bp) == 'string' then
                        NoteUpgrade({ unit }, bp)
                    end
                    w.announced = true
                end
            elseif w.busy then
                -- That upgrade is over (cancelled): the next one is news.
                w.busy = false
                w.announced = false
            elseif w.announced and (now - (w.announcedT or 0)) > 10 then
                -- Ordered, and told, but never started.
                w.announced = false
            end
        end
    end
end


--- Follow our selection: FAF's ObserveSelection where the game has it, else
--- a look at GetSelectedUnits each beat (CheckSelection).
local function HookSelection()
    local ok = pcall(function()
        import('/lua/ui/game/gamemain.lua').ObserveSelection:AddObserver(function(data)
            if initialised and sendState.selWatch then
                NoteSelection(data and data.newSelection)
            end
        end, 'TeamMouseSelection')
    end)
    sendState.selWatch = true
    sendState.selPoll = not ok
end


--- Each beat, where the selection is not observed: look at it.
function CheckSelection()
    if sendState.selPoll and sendState.selWatch then
        local ok, units = pcall(GetSelectedUnits)
        if ok then
            NoteSelection(units)
        end
    end
end

--- What a player does that teammates are told of, beyond the pointer: build
--- orders the game really issues (hook/lua/ui/game/commandmode.lua), so a
--- refused placement is not shown; upgrades; and our selection.
local function HookPlayerInputs()
    rawset(_G, 'TeamMouseOnCommandIssued', OnCommandIssuedListener)
    HookUpgrades()
    HookSelection()
end

--- A left click that selected something: counted, and sent with the next
--- packet (ck) for teammates to see a pulse at the tip of the cursor. Not a
--- drag, not a click that selected nothing (the terrain), not a right click.
function CountClick()
    if sendState.clicks < 9 then
        sendState.clicks = sendState.clicks + 1
    end
    sendState.clickT = false
end

--- The pointer is at (x, y) during a left press: gone further than
--- ClickPulse.MaxMove from the press, it is a drag, not a click.
---@param x? number
---@param y? number
function NoteClickMove(x, y)
    if sendState.clickT and x and y then
        local dx, dy = x - sendState.pressX, y - sendState.pressY
        local max = Config.ClickPulse.MaxMove
        if dx * dx + dy * dy > max * max then
            sendState.clickT = false
        end
    end
end

--- The view heard a left press, motion, release or double-click. A press is
--- a click unless the pointer then moves away (NoteClickMove); it pulses once
--- the selection changes to something within ClickPulse.SelectWindow of it.
--- (Decided from the press, not the release: when a click selects a unit the
--- release does not reach us -- single clicks never pulsed, double-clicks,
--- which have their own event, did.)
---@param t string
---@param event table
local function NoteClick(t, event)
    local cfg = Config.ClickPulse
    if not cfg.Enabled then
        return
    end
    local m = event.Modifiers
    if t == 'ButtonPress' and m and m.Left then
        sendState.pressX, sendState.pressY = event.MouseX or 0, event.MouseY or 0
        sendState.clickT = GetSystemTimeSeconds()
    elseif t == 'ButtonDClick' and m and m.Left then
        sendState.pressX, sendState.pressY = event.MouseX or 0, event.MouseY or 0
        sendState.clickT = GetSystemTimeSeconds()
    elseif t == 'MouseMotion' or t == 'ButtonRelease' then
        NoteClickMove(event.MouseX, event.MouseY)
    end
end

--- Whether the left drag in progress is still within Orders.GrabStartPixels of
--- where it began (by the grid's last word on where the pointer is).
---@return boolean
local function DragStillNear()
    local overlay = activeDragView and dragOverlays[activeDragView]
    if not overlay then
        return true
    end
    local dx = overlay.liveScreen[1] - sendState.dragX
    local dy = overlay.liveScreen[2] - sendState.dragY
    local max = Config.Orders.GrabStartPixels
    return dx * dx + dy * dy <= max * max
end

local function HookViewEvents(view)
    if view._TeamMouseHooked then
        return
    end
    view._TeamMouseHooked = true

    local trackSelection = Config.Selection.Enabled and not isObserver and not isReplay

    -- The right button matters to players for two reasons -- the grid has to
    -- lift out of its way, and its orders are shared -- and to nobody else.
    local trackRight = not isObserver and not isReplay

    if trackSelection and Config.Selection.DragTracking then
        CreateDragOverlayForView(view)
    end

    local originalHandleEvent = view.HandleEvent
    view.HandleEvent = function(self, event)
        local t = event.Type

        if t == 'MouseMotion' or t == 'MouseEnter' or t == 'ButtonPress' then
            if event.MouseX then
                localMouse.x = event.MouseX
                localMouse.y = event.MouseY
                localMouse.overWorld = true
                localMouse.view = self
            end
        end
        if trackRight and (t == 'ButtonPress' or t == 'ButtonDClick' or t == 'ButtonRelease'
            or (t == 'MouseMotion' and sendState.clickT)) then
            NoteClick(t, event)
        end
        -- A right press ends the way a left drag does (below): on a motion
        -- event that doesn't have the button held. There is no IsKeyDown to
        -- confirm it with -- IsKeyDown('RBUTTON') reads up even while the
        -- right button is held -- and the release event itself never arrives.
        if t == 'MouseMotion' and rightClick.middle and event.Modifiers
            and not event.Modifiers.Middle then
            EndMiddle(event.MouseX, event.MouseY)
        end
        if t == 'MouseMotion' and rightClick.press then
            rightClick.motionEvents = rightClick.motionEvents + 1
            if event.Modifiers and event.Modifiers.Right then
                rightClick.heldEvents = rightClick.heldEvents + 1
            elseif event.Modifiers then
                FinishRightPress(event.MouseX, event.MouseY, 'motion without the right button', true)
            end
        end
        if t == 'MouseMotion' and localMouse.pendingHud and not localSelecting then
            localMouse.pendingHud = false
        end
        --LOG("Pending: " .. tostring(localMouse.pendingHud))
        if trackRight and (t == 'ButtonPress' or t == 'ButtonRelease') then
            HandleRightButton(t, event, self)
        end
        if trackSelection then
            if t == 'ButtonPress' then
                HandleLeftPress(self, event)
            elseif t == 'ButtonRelease' then
                AnnounceBuild()
                AnnounceGrab()
                EndDrag()
                LowerGridNow(self)
            elseif t == 'MouseMotion' and localSelecting
                and event.Modifiers and not event.Modifiers.Left then
                -- The engine can deliver a MouseMotion with Left unset here
                -- even while the button is still physically held -- observed
                -- while crossing from the view onto one of our own overlay
                -- cells. Confirm against the real hardware state before
                -- trusting this one event's Modifiers.
                if not IsKeyDown('LBUTTON') then
                    AnnounceBuild()
                    AnnounceGrab()
                    EndDrag()
                    LowerGridNow(self)
                end
            elseif t == 'MouseMotion' and localSelecting then
                NoteDragMotion(self, event)
            end
        end

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
                if localMouse.view == cachedView then
                    localMouse.view = false
                    localMouse.overWorld = false
                end
                if activeDragView == cachedView then
                    EndDrag()
                end
                DestroyDragOverlayForView(cachedView)
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

    cursor.TeamMouseOrder = 'selectable'

    local originalSetTexture = cursor.SetTexture
    cursor.SetTexture = function(self, filename, hotspotX, hotspotY, numFrames, fps)
        originalSetTexture(self, filename, hotspotX, hotspotY, numFrames, fps)
        local key = CursorData.KeyFromTexture(filename) or 'selectable'
        self.TeamMouseOrder = key

        -- A left drag that turns out to be moving a waypoint (the hand may
        -- only appear once the drag is under way): from here to the release it
        -- is reported as the hand, whatever the cursor flickers to. Only near
        -- where the drag began: a waypoint drag starts on the waypoint. A box
        -- drag that later passes over one (holding Shift shows them, and the
        -- hand with them) stays a box.
        if localSelecting and not sendState.line and IsWaypointCursor(key) and DragStillNear() then
            sendState.waypoint = true
            sendState.plain = true
            if sendState.grabKind == 0 then
                sendState.grabKind = GrabbedCommand() or 0
            end
        end
    end

    local originalReset = cursor.Reset
    cursor.Reset = function(self)
        originalReset(self)
        self.TeamMouseOrder = 'selectable'
    end
end

--------------------------------------------------------------------------------
-- Replay playback
--------------------------------------------------------------------------------

--- During replay playback there is no live chat traffic: the packets come
--- back up out of the replayed sim instead (ReplayCodec), and go through the
--- same receive code as a live one. No sender name comes with them; the army
--- in the packet says whose it is.
local function StartReplayPlayback()
    ReplayCodec.Listen(function(msg)
        ProcessMessage(false, msg)
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

--Hook UI event handler
local function HookRootFrame()
    local frame = GetFrame(0)

    if not frame or frame._TeamMouseHooked then
        return
    end
    frame._TeamMouseHooked = true

    local originalEvent = frame.HandleEvent
    frame.HandleEvent = function(self, event)
        local x = event.MouseX
        local t = event.Type
        
        if localMouse.overWorld and t == 'MouseExit' then
            localMouse.pendingHud = false
        end

        -- A right press ends wherever the button comes up, which is not
        -- always over the map. (One that did land on the map has already been
        -- handled by the view's hook, and this is then a no-op.)
        if t == 'ButtonRelease' and (rightClick.press or rightClick.middle) then
            HandleRightButton(t, event)
        end
        
        if x then
            local y = event.MouseY
            -- Ignore a map event that bubbled up here: it carries the
            -- position the view hook just stored. Also ignore everything here
            -- for the length of our own drag -- the overlay's own cells are
            -- themselves descendants of this frame, so their crossings bubble
            -- up here too, and with a screenful of them, almost none happen
            -- to match the exact position the view last set, which is
            -- otherwise exactly the signal used below to conclude the
            -- pointer left the map.
            if not localSelecting
                and not (localMouse.overWorld and x == localMouse.x and y == localMouse.y)
                and not (x == localMouse.cellX and y == localMouse.cellY) then
                localMouse.x, localMouse.y = x, y
                if localMouse.pendingHud then
                    localMouse.overWorld = false
                    localMouse.pendingHud = false
                else 
                    localMouse.pendingHud = true
                end
            end
        end
        return originalEvent(self, event)
    end
end

---@param replay boolean
function InitTeamMouse(replay)
    if initialised then
        return
    end

    local ok, err = pcall(function()
        isReplay = replay and true or false
        viewInfo.replay = isReplay

        local armiesInfo = GetArmiesTable()
        local armies = armiesInfo.armiesTable
        local clients = GetSessionClients()

        -- Every other client, by index and by name: for telling a player we
        -- hid their cursor, and knowing who told us they hid ours.
        sendState.everyone, sendState.clientIndex, sendState.muted = {}, {}, {}
        for index, client in ipairs(clients) do
            sendState.clientIndex[client.name] = index
            if not client['local'] then
                table.insert(sendState.everyone, index)
            end
        end

        myArmy = GetFocusArmy()
        isObserver = (myArmy == nil or myArmy < 1)
        -- An observer can look players' units up by id (RemoteCursor.ApplySelection).
        viewInfo.observer = isObserver
        myName = FindLocalName(clients)

        ------------------------------------------------------------------
        -- Who can we see?
        ------------------------------------------------------------------
        -- Players see allies. Observers and replay viewers see everyone --
        -- in a replay, the viewer's own army too: watching your own game,
        -- your cursor is one of the ones recorded.
        for index, army in pairs(armies) do
            if army.human and (isReplay or army.nickname ~= myName) then
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
                        sendState.clientByName[client.name] = index
                        -- (Nobody has hidden our cursor yet: the live lists
                        -- start as the whole ones. RebuildTargets after.)
                        if isSpectator then
                            table.insert(sendState.specTo, index)
                            table.insert(sendState.specLive, index)
                        else
                            table.insert(sendState.teamTo, index)
                            table.insert(sendState.teamLive, index)
                        end
                    end
                end
            end
        end

        -- Only a player with someone to send to has any use for extra samples.
        -- The panel listing everyone whose cursor can be seen, by army.
        local listed = {}
        for _, record in pairs(peers) do
            table.insert(listed, record)
        end
        table.sort(listed, function(a, b) return a.army < b.army end)
        Panel.Create(listed, OnPanelToggle, isReplay or isObserver)

        -- Versions in chat, for a player with teammates.
        if not isObserver and not isReplay and table.getn(recipients) > 0 then
            local names = {}
            for _, record in ipairs(listed) do
                table.insert(names, record.name)
            end
            Version.Start(names, function(msg)
                SessionSendChatMessage(recipients, msg)
            end, GetSystemTimeSeconds())
        end

        -- Stop, repeat build and pause, for teammates to see.
        if Config.Actions.Enabled and Config.Actions.Share and not isObserver and not isReplay then
            local hooked = Actions.Install(QueueAction)
            Debug('actions hooked: ' .. table.concat(hooked, ', '))
        end

        -- Into the replay too, when the game has that on (the host's lobby
        -- option). Players only; with or without teammates.
        sendState.recording = not isObserver and not isReplay
            and Config.ReplayCodec.Write and ReplayCodec.IsEnabled()

        sampleBuf.active = Config.Network.ExtraSamples.Enabled
            and not isObserver and not isReplay
            and (table.getn(recipients) > 0 or sendState.recording)
        if sampleBuf.active and Config.Smoothing.InterpolationDelay < Config.Network.ExtraSamples.Interval then
            Log('extra samples are on but Smoothing.InterpolationDelay is too short'
                .. ' for them to be used; teammates will see little difference')
        end

        Debug('army ' .. tostring(myArmy) .. ', observer=' .. tostring(isObserver)
            .. ', peers=' .. tostring(table.getsize(peers))
            .. ', recipients=' .. tostring(table.getn(recipients)))

        ------------------------------------------------------------------
        -- Wire it up
        ------------------------------------------------------------------
        -- RegisterChatFunc lives in the gamemain module table, not in _G.
        -- Calling it bare -- as the previous version did from this file --
        -- resolves to nil and throws.
        local GameMain = import('/lua/ui/game/gamemain.lua')
        GameMain.RegisterChatFunc(OnReceive, Config.ChatIdentifier)
        GameMain.RegisterChatFunc(OnLegacyReceive, 'a')
        -- (Saying we read the compact format waits for the first beat:
        -- StartCompact. Kept out of here for the upvalue limit.)


        if not isReplay then
            HookCursor()
        end

        HookRootFrame()

        -- Build orders the game really issues (hook/lua/ui/game/commandmode.lua),
        -- so a refused placement is not shown to teammates.
        if not isObserver and not isReplay then
            HookPlayerInputs()
        end

        initialised = true
        SyncViews()

        if isReplay and Config.ReplayCodec.Read and ReplayCodec.IsEnabled() then
            StartReplayPlayback()
        end

        if isReplay then
            Log('replay session; live sharing unavailable, replay codec '
                .. (ReplayCodec.IsEnabled() and 'enabled' or 'disabled'))
        elseif isObserver then
            Log('observing; receiving from all players')
        elseif table.getn(recipients) == 0 then
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
    rawset(_G, 'TeamMouseOnCommandIssued', nil)
    UnhookUpgrades()
    sendState.selWatch = false
    ReplayCodec.ResetOption()
    buildWatch.armed = false
    buildWatch.pending = false
    buildWatch.n = 0
    buildWatch.seen = false
    Actions.Uninstall()
    Panel.Destroy()
    Version.Reset()
    sendState.actCount = 0

    for _, overlay in pairs(dragOverlays) do
        overlay.group:Destroy()
    end
    dragOverlays = {}
    activeDragView = false

    ReplayCodec.StopListening()

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
    sendState.teamTo = {}
    sendState.specTo = {}
    sendState.teamLive = {}
    sendState.specLive = {}
    sendState.muted = {}
    sendState.compact = {}
    sendState.hello = {}
    sendState.compactStarted = false
    sendState.teamC, sendState.teamP, sendState.specC, sendState.specP = {}, {}, {}, {}
    sendState.allC, sendState.allP = {}, {}
    knownViews = {}

    sendState.pos[1], sendState.pos[2], sendState.pos[3] = 0, 0, 0
    sendState.order = -1
    sendState.time = 0
    sendState.hud = false
    sendState.hudX, sendState.hudY = -1, -1
    sendState.line = false
    sendState.plain = false
    sendState.waypoint = false
    sendState.flags = 0
    sendState.lastRun = 0
    sendState.sentZoom = -1
    sendState.sentOrder = -1
    sendState.orderT = 0
    sendState.zoomT = 0
    sendState.legacyTo = {}
    sendState.clientByName = {}
    sendState.tmSeen = {}
    sendState.smSeen = {}
    sendState.ordCount = 0
    sendState.gridCheck = 0
    sampleBuf.active = false
    sampleBuf.count = 0
    sampleBuf.lastT = 0
    rightClick.press = false
    rightClick.middle = false
    rightClick.suspended = false
    localSelecting = false
    pinnedAnchor = false
    worldHold.pos[1], worldHold.pos[2], worldHold.pos[3] = 0, 0, 0
    worldHold.have = false
    worldHold.zoom = 0
    frameErrors = 0
    receiveErrors = 0
    localMouse.overWorld = false
    localMouse.view = false
    pointerMap.verified = false
    pointerMap.mode = false
    pointerMap.failed = false
    pointerMap.lastX, pointerMap.lastY = -1, -1
end
