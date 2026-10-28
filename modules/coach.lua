--******************************************************************************
--** TeamMouse -- modules/coach.lua
--**
--** Coaching: following a player's view, and drawing for them.
--**
--** Following. Click a player's name in the panel (teammates, live observers,
--** replays) and your camera follows theirs (FollowPass in teammouse.lua).
--** Click the name again and your camera goes back to where it was; a hard
--** scroll breaks free and leaves it where it is.
--**
--** Live, while you follow someone:
--**   * a right-drag is not a drawing in the game (nothing reaches the sim or
--**     the replay): it is drawn straight on THEIR screen, as if on the camera
--**     lens -- fixed to the screen, over the interface -- and fades
--**     (Coach.FadeSeconds) once it is finished. You see it too.
--**   * a left click is not a click: an expanding ring plays on their screen
--**     where you clicked.
--**   * they do not see your cursor.
--** A player sees these only with "drawings on my screen" ticked in their
--** panel (Coach.ShowLens starts it).
--**
--** Coaching (live observers only). The panel's "coach" box on one player:
--**   * your cursor is sent to that player, and to nobody else (observers are
--**     never recorded into the replay);
--**   * your selection follows theirs;
--**   * a right-drag on the map (not following) is drawn on THEIR map, not
--**     through the game's painting, and fades like the lens strokes.
--**
--** Messages (plain tables, Identifier = Config.ChatIdentifier), each to the
--** one client concerned:
--**   { tmf = 1|0, ta = army }     I follow you / no longer
--**   { tmh = 1|0 }                I coach you / no longer (observers)
--**   { tml = <points> }           a lens stroke: thousandths of your main view
--**   { tmk = 'x,y' }              a click ring, in thousandths the same way
--**   { tmw = <points> }           a coach's stroke on the map, world tenths
--** <points> is one string in wirepack.lua's 64 digits (PackPoints): whether
--** the stroke is done (1 digit), its id (2), the chunk's first point whole
--** (3 digits a number), then each number as the difference from the point
--** before: one digit for -31..31, else '_' and three. Each chunk repeats the
--** last point of the one before, whole, so a lost message leaves a gap, not a
--** wrong line.
--**
--** UNVERIFIED in game: that a right press returned as handled (true) from the
--** world view's HandleEvent stops the game's painting and orders, as a left
--** one does (engine-gotchas.md, "The native drag capture"); and how well
--** their view's outline, projected through our camera, places their screen
--** on ours (TargetRect).
--******************************************************************************

local Config = import(_G.TeamMousePath .. '/modules/config.lua')
local CursorData = import(_G.TeamMousePath .. '/modules/cursordata.lua')
local WirePack = import(_G.TeamMousePath .. '/modules/wirepack.lua')
local WorldViewManager = import('/lua/ui/game/worldview.lua')
local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap

--- What teammouse.lua hands us at the start of a session (Start):
---   send(index, msg)      SessionSendChatMessage to one client
---   clientIndex           name -> client index
---   peers                 name -> record
---   myArmy, observer, replay
---   myColor               our own strokes' colour
---   addCoach(name)        a cursor for an observer coaching us
---   removeCoach(name)
---   setCoachTarget(index) who an observer's cursor goes to (false: nobody)
---   forceView()           send our camera with the next packet
---   panelSync()           show the panel as following/coaching now is
---   raisePanel(on)        put the panel above the capture layer (or back)
local env = false

--- Our side of it.
---   following   the record we follow (false: nobody)
---   before      our camera before following began (put back on unclick)
---   coaching    the record we coach (observers; false: nobody)
---   coachSel    their selVersion last copied into ours
---   show        draw what those following or coaching us send
---   followers   client index -> true: who follows us
---   followTeam  how many of them are teammates (they need our camera)
---   coaches     name -> true: observers coaching us
---   stroke      the stroke we are drawing, or false
---   nextId      our stroke ids
---   followSaidT when we last said we follow (said again while no camera comes)
local state = {
    following = false, before = false,
    coaching = false, coachSel = -1,
    show = true,
    followers = {}, followTeam = 0,
    coaches = {},
    stroke = false, nextId = 0,
    followSaidT = 0,
    -- (observers) the army our focus is set to, and whose selection ours copies
    focusArmy = -1, selFrom = false,
}

--- What is drawn.
---   root      the overlay over everything (lens strokes, rings)
---   free      spare dots, explicit count (nfree)
---   lens      lens strokes, explicit count (nlens), each
---             { key, color, l, t, w, h, x, y, n, dots, nd, endT, lastT, alpha }
---   rings     click rings, explicit count (nrings), each { x, y, t0, color, dots }
---   ink       strokes on the map, explicit count (nink), each
---             { key, color, pts, n, endT, lastT, drawColor }
---   shape     draws the ink (every world view, FAF's AddShape)
---   shaped    view -> true: has the shape
local draw = {
    root = false,
    free = {}, nfree = 0, made = 0,
    lens = {}, nlens = 0,
    rings = {}, nrings = 0,
    ink = {}, nink = 0,
    shape = false, shaped = {},
    -- while following live: a layer over the whole screen (but the panel)
    -- that takes every click and right-drag for drawing on their screen
    capture = false, captureShown = false,
}

--- Scratch for reading numbers off the wire.
local scratch = {}

--- `color` ('AARRGGBB') with its alpha byte replaced, remembered (the ink
--- shape asks every frame).
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

---@param index number
---@param msg table
local function Send(index, msg)
    if env and index then
        msg.Identifier = Config.ChatIdentifier
        pcall(env.send, index, msg)
    end
end

--- The client a record's player is on, or nil.
---@param record table
---@return number | nil
local function IndexOf(record)
    return record and env and env.clientIndex[record.name]
end

--- Whether we can say anything to anyone: a live game.
---@return boolean
local function Live()
    return env and not env.replay and Config.Coach.Enabled and true or false
end

--------------------------------------------------------------------------------
-- Dots: the lens is drawn in small square bitmaps
--------------------------------------------------------------------------------

--- The overlay, made when first needed: over the whole screen, over the
--- interface, never in the way of a click.
---@return Group | false
local function Root()
    if draw.root then
        return draw.root
    end
    local frame = GetFrame(0)
    if not frame then
        return false
    end
    local root = Group(frame, 'TeamMouseLens')
    root.Left:Set(function() return frame.Left() end)
    root.Top:Set(function() return frame.Top() end)
    root.Width:Set(function() return frame.Width() end)
    root.Height:Set(function() return frame.Height() end)
    root.Depth:Set(Config.Coach.LensDepth)
    root:DisableHitTest(true)
    draw.root = root
    return root
end

--- Put a dot centred on screen point (x, y).
local function PlaceDot(dot, x, y)
    local half = Config.Coach.LensThickness / 2
    dot.Left:Set(math.floor(x - half + 0.5))
    dot.Top:Set(math.floor(y - half + 0.5))
end

--- A dot centred on (x, y), from the spares or new (up to Coach.MaxDots), or
--- nil. Its whole layout is set BEFORE it is shown: a new bitmap's Left and
--- Top are each other's formulas (engine-gotchas.md, "circular dependency in
--- lazy evaluation"), and shown like that it was drawn as a box from the
--- corner of the screen to the stroke (reported with a screenshot).
---@param color string
---@param x number
---@param y number
---@return Bitmap | nil
local function TakeDot(color, x, y)
    local dot
    local size = Config.Coach.LensThickness
    if draw.nfree > 0 then
        dot = draw.free[draw.nfree]
        draw.free[draw.nfree] = nil
        draw.nfree = draw.nfree - 1
    else
        if draw.made >= Config.Coach.MaxDots then
            return nil
        end
        local root = Root()
        if not root then
            return nil
        end
        dot = Bitmap(root)
        dot:Hide()
        dot:DisableHitTest(true)
        dot.Width:Set(size)
        dot.Height:Set(size)
        dot.Right:Set(function() return dot.Left() + dot.Width() end)
        dot.Bottom:Set(function() return dot.Top() + dot.Height() end)
        draw.made = draw.made + 1
    end
    dot.Width:Set(size)
    dot.Height:Set(size)
    PlaceDot(dot, x, y)
    dot:SetSolidColor(color)
    dot:SetAlpha(1)
    dot:Show()
    return dot
end

---@param dot Bitmap
local function GiveDot(dot)
    dot:Hide()
    draw.nfree = draw.nfree + 1
    draw.free[draw.nfree] = dot
end

--------------------------------------------------------------------------------
-- Lens strokes and click rings
--------------------------------------------------------------------------------

--- Our main view's rectangle on screen (where their marks are drawn), or
--- the whole screen.
---@return number, number, number, number
local function MainRect()
    local views = WorldViewManager.GetWorldViews()
    local view = views and views['WorldCamera']
    if view and not view:IsHidden() then
        local l, t = view.Left(), view.Top()
        return l, t, view.Right() - l, view.Bottom() - t
    end
    local frame = GetFrame(0)
    return frame.Left(), frame.Top(), frame.Width(), frame.Height()
end

--- The lens stroke with this key, made if new (a full list drops the oldest).
---@param key string
---@param color string
---@return table
local function LensStroke(key, color)
    for i = 1, draw.nlens do
        if draw.lens[i].key == key then
            return draw.lens[i]
        end
    end
    if draw.nlens >= Config.Coach.MaxStrokes then
        local old = draw.lens[1]
        for j = 1, old.nd do GiveDot(old.dots[j]) end
        for i = 1, draw.nlens - 1 do draw.lens[i] = draw.lens[i + 1] end
        draw.lens[draw.nlens] = nil
        draw.nlens = draw.nlens - 1
    end
    local l, t, w, h = MainRect()
    local s = { key = key, color = color, l = l, t = t, w = w, h = h,
        x = 0, y = 0, n = 0, dots = {}, nd = 0, endT = false, lastT = GetSystemTimeSeconds(), alpha = 1 }
    draw.nlens = draw.nlens + 1
    draw.lens[draw.nlens] = s
    return s
end

--- Add a point to a lens stroke: (u, v) in its rectangle, 0..1 each (beyond
--- is allowed: over the interface round the view). Dots fill the way from
--- the last point.
---@param s table
---@param u number
---@param v number
local function LensPoint(s, u, v)
    local x, y = s.l + u * s.w, s.t + v * s.h
    if s.n >= Config.Coach.MaxPoints then
        return
    end
    s.lastT = GetSystemTimeSeconds()
    local steps = 1
    local fromX, fromY = x, y
    if s.n > 0 then
        fromX, fromY = s.x, s.y
        local dx, dy = x - fromX, y - fromY
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist < 0.5 then
            return
        end
        steps = math.max(1, math.floor(dist / Config.Coach.LensSpacing + 0.5))
    end
    s.n = s.n + 1
    s.x, s.y = x, y
    for i = 1, steps do
        local k = i / steps
        if s.n == 1 then k = 1 end
        local dot = TakeDot(s.color, fromX + (x - fromX) * k, fromY + (y - fromY) * k)
        if not dot then
            break
        end
        dot:SetAlpha(s.alpha)
        s.nd = s.nd + 1
        s.dots[s.nd] = dot
    end
end

--- A click ring at screen point (x, y).
---@param x number
---@param y number
---@param color string
local function Ring(x, y, color)
    if draw.nrings >= 6 then
        local old = draw.rings[1]
        for j = 1, table.getn(old.dots) do GiveDot(old.dots[j]) end
        for i = 1, draw.nrings - 1 do draw.rings[i] = draw.rings[i + 1] end
        draw.rings[draw.nrings] = nil
        draw.nrings = draw.nrings - 1
    end
    local ring = { x = x, y = y, t0 = GetSystemTimeSeconds(), color = color, dots = {} }
    local r = Config.Coach.RingRadius * 0.25
    local n = Config.Coach.RingDots
    for i = 1, n do
        local a = (i / n) * 2 * math.pi
        local dot = TakeDot(color, x + math.cos(a) * r, y + math.sin(a) * r)
        if not dot then
            break
        end
        table.insert(ring.dots, dot)
    end
    draw.nrings = draw.nrings + 1
    draw.rings[draw.nrings] = ring
end

--- Fade finished strokes, grow and fade rings; let go of what is done.
---@param now number
local function AnimateLens(now)
    local cfg = Config.Coach
    local keep = 0
    for i = 1, draw.nlens do
        local s = draw.lens[i]
        -- A stroke nobody finished (its last message lost): done once quiet.
        if not s.endT and now - s.lastT > cfg.StaleSeconds then
            s.endT = now
        end
        local alpha = 1
        if s.endT then
            alpha = 1 - (now - s.endT) / cfg.LensFadeSeconds
        end
        if alpha <= 0 then
            for j = 1, s.nd do GiveDot(s.dots[j]) end
        else
            -- In steps (Coach.FadeStep): every dot is an engine call.
            if math.abs(alpha - s.alpha) >= cfg.FadeStep then
                s.alpha = alpha
                for j = 1, s.nd do s.dots[j]:SetAlpha(alpha) end
            end
            keep = keep + 1
            draw.lens[keep] = s
        end
    end
    for i = keep + 1, draw.nlens do draw.lens[i] = nil end
    draw.nlens = keep

    keep = 0
    for i = 1, draw.nrings do
        local ring = draw.rings[i]
        local k = (now - ring.t0) / cfg.RingSeconds
        local n = table.getn(ring.dots)
        if k >= 1 then
            for j = 1, n do GiveDot(ring.dots[j]) end
        else
            local r = cfg.RingRadius * (0.25 + 0.75 * k)
            local alpha = 1 - k * k
            for j = 1, n do
                local a = (j / n) * 2 * math.pi
                local dot = ring.dots[j]
                PlaceDot(dot, ring.x + math.cos(a) * r, ring.y + math.sin(a) * r)
                dot:SetAlpha(alpha)
            end
            keep = keep + 1
            draw.rings[keep] = ring
        end
    end
    for i = keep + 1, draw.nrings do draw.rings[i] = nil end
    draw.nrings = keep
end

--- Take down every lens mark, or only those whose key starts with `prefix`
--- (one sender's), at once.
---@param prefix? string
local function ClearLens(prefix)
    local keep = 0
    for i = 1, draw.nlens do
        local s = draw.lens[i]
        if prefix and string.sub(s.key, 1, string.len(prefix)) ~= prefix then
            keep = keep + 1
            draw.lens[keep] = s
        else
            for j = 1, s.nd do GiveDot(s.dots[j]) end
        end
    end
    for i = keep + 1, draw.nlens do draw.lens[i] = nil end
    draw.nlens = keep
    if not prefix then
        for i = 1, draw.nrings do
            local ring = draw.rings[i]
            for j = 1, table.getn(ring.dots) do GiveDot(ring.dots[j]) end
            draw.rings[i] = nil
        end
        draw.nrings = 0
    end
end

--------------------------------------------------------------------------------
-- Ink: a coach's strokes on the map
--------------------------------------------------------------------------------

--- The one shape that draws the ink, in every world view.
---@return table
local function InkShape()
    if draw.shape then
        return draw.shape
    end
    local shape = { Hidden = true }
    shape.OnRender = function(self, delta)
        local thick = Config.Coach.InkThickness
        for i = 1, draw.nink do
            local s = draw.ink[i]
            local pts = s.pts
            for j = 2, s.n do
                UI_DrawLine(pts[j - 1], pts[j], s.drawColor, thick)
            end
        end
    end
    shape.Render = function(self, delta)
        if not self.Hidden and draw.nink > 0 then
            self:OnRender(delta)
        end
    end
    shape.Destroy = function(self) end
    draw.shape = shape
    return shape
end

--- Make sure every world view draws the ink (views come and go with
--- layout changes).
local function ShapeViews()
    local views = WorldViewManager.GetWorldViews()
    local shape = InkShape()
    for key, view in pairs(views or {}) do
        if key ~= 'MiniMap' and view and not draw.shaped[view] and view.AddShape then
            draw.shaped[view] = true
            pcall(view.AddShape, view, shape, 'TeamMouseCoachInk')
        end
    end
end

---@param key string
---@param color string
---@return table
local function InkStroke(key, color)
    for i = 1, draw.nink do
        if draw.ink[i].key == key then
            return draw.ink[i]
        end
    end
    if draw.nink >= Config.Coach.MaxStrokes then
        for i = 1, draw.nink - 1 do draw.ink[i] = draw.ink[i + 1] end
        draw.ink[draw.nink] = nil
        draw.nink = draw.nink - 1
    end
    local s = { key = key, color = color, drawColor = color, pts = {}, n = 0,
        endT = false, lastT = GetSystemTimeSeconds() }
    draw.nink = draw.nink + 1
    draw.ink[draw.nink] = s
    ShapeViews()
    draw.shape.Hidden = false
    return s
end

---@param s table
---@param x number
---@param y number
---@param z number
local function InkPoint(s, x, y, z)
    if s.n >= Config.Coach.MaxPoints then
        return
    end
    s.lastT = GetSystemTimeSeconds()
    s.n = s.n + 1
    local p = s.pts[s.n]
    if not p then
        p = { 0, 0, 0 }
        s.pts[s.n] = p
    end
    p[1], p[2], p[3] = x, y, z
end

---@param now number
local function AnimateInk(now)
    local cfg = Config.Coach
    local keep = 0
    for i = 1, draw.nink do
        local s = draw.ink[i]
        if not s.endT and now - s.lastT > cfg.StaleSeconds then
            s.endT = now
        end
        local alpha = 1
        if s.endT then
            alpha = 1 - (now - s.endT) / cfg.FadeSeconds
        end
        if alpha > 0 then
            s.drawColor = WithAlpha(s.color, alpha)
            keep = keep + 1
            draw.ink[keep] = s
        end
    end
    for i = keep + 1, draw.nink do draw.ink[i] = nil end
    draw.nink = keep
    if draw.shape then
        draw.shape.Hidden = keep == 0
    end
end

--------------------------------------------------------------------------------
-- Drawing it ourselves
--------------------------------------------------------------------------------

--- Where their screen is on ours: the middle of each edge of their view's
--- outline (vp, four world corners clockwise from the top left) projected
--- through our view. Ours, if that cannot be had or makes no sense.
---@param view WorldView
---@param record table
---@return number, number, number, number   # left, top, width, height
local function TargetRect(view, record)
    local l, t = view.Left(), view.Top()
    local w, h = view.Right() - l, view.Bottom() - t
    local vp = record.vp
    if type(vp) ~= 'table' or not vp[12] then
        return l, t, w, h
    end
    local function Mid(a, b)
        local ia, ib = (a - 1) * 3, (b - 1) * 3
        local p = { (vp[ia + 1] + vp[ib + 1]) * 0.5, (vp[ia + 2] + vp[ib + 2]) * 0.5,
            (vp[ia + 3] + vp[ib + 3]) * 0.5 }
        local ok, proj = pcall(view.Project, view, p)
        if ok and proj and type(proj.x) == 'number' and proj.x == proj.x and proj.y == proj.y then
            return proj.x, proj.y
        end
    end
    local lx = Mid(1, 4)
    local rx = Mid(2, 3)
    local _, ty = Mid(1, 2)
    local _, by = Mid(4, 3)
    if not (lx and rx and ty and by) then
        return l, t, w, h
    end
    local rw, rh = rx - lx, by - ty
    -- Nonsense (a camera nowhere near theirs): ours.
    if rw < 40 or rh < 40 or rw > w * 4 or rh > h * 4 then
        return l, t, w, h
    end
    return l + lx, t + ty, rw, rh
end

--- A number for the wire: a whole number, as text.
local function Int(v)
    return string.format('%d', math.floor(v + 0.5))
end

--- Start a stroke of ours: 'lens' (following; on their screen) or 'ink'
--- (coaching; on their map).
---@param kind string
---@param view WorldView
---@param x number
---@param y number
local function StartStroke(kind, view, x, y)
    state.nextId = state.nextId + 1
    local target = kind == 'lens' and state.following or state.coaching
    local s = { kind = kind, id = state.nextId, target = target, index = IndexOf(target),
        wire = {}, n = 0, sent = 0, lastSend = GetSystemTimeSeconds(), view = view,
        l = 0, t = 0, w = 1, h = 1, local_ = false, lx = x, ly = y }
    if kind == 'lens' then
        s.l, s.t, s.w, s.h = TargetRect(view, target)
        s.local_ = LensStroke('me/' .. s.id, env.myColor)
        s.local_.l, s.local_.t, s.local_.w, s.local_.h = s.l, s.t, s.w, s.h
    else
        s.local_ = InkStroke('me/' .. s.id, env.myColor)
    end
    state.stroke = s
end

--- The pointer is at (x, y) during our stroke.
---@param x number
---@param y number
local function StrokePoint(x, y)
    local s = state.stroke
    if not s or not x or not y then
        return
    end
    local dx, dy = x - s.lx, y - s.ly
    if s.n > 0 and dx * dx + dy * dy < Config.Coach.MinMove * Config.Coach.MinMove then
        return
    end
    if s.n >= Config.Coach.MaxPoints then
        return
    end
    s.lx, s.ly = x, y
    if s.kind == 'lens' then
        local u, v = (x - s.l) / s.w, (y - s.t) / s.h
        LensPoint(s.local_, u, v)
        s.n = s.n + 1
        s.wire[s.n * 2 - 1] = math.floor(u * 1000 + 0.5)
        s.wire[s.n * 2] = math.floor(v * 1000 + 0.5)
    else
        local ok, pos = pcall(GetMouseWorldPos)
        if not ok or type(pos) ~= 'table' then
            return
        end
        local wx, wy, wz = pos[1], pos[2], pos[3]
        if type(wx) ~= 'number' or wx ~= wx or type(wz) ~= 'number' or wz ~= wz then
            return
        end
        if type(wy) ~= 'number' or wy ~= wy then wy = 0 end
        InkPoint(s.local_, wx, wy, wz)
        s.n = s.n + 1
        s.wire[s.n * 3 - 2] = math.floor(wx * 10 + 0.5)
        s.wire[s.n * 3 - 1] = math.floor(wy * 10 + 0.5)
        s.wire[s.n * 3] = math.floor(wz * 10 + 0.5)
    end
end

--- Send the points not yet sent (with the last one sent before them).
---@param done boolean   # the stroke is finished
local function FlushStroke(done)
    local s = state.stroke
    if not s then
        return
    end
    local per = s.kind == 'lens' and 2 or 3
    -- One point is not a stroke yet (it may be a click: EndStroke).
    if s.n < 2 then
        s.lastSend = GetSystemTimeSeconds()
        return
    end
    if s.n > s.sent or done then
        -- From the last point sent (whole), so a lost chunk leaves a gap.
        local packed = PackPoints(s.id, done, s.wire, math.max(1, s.sent), s.n, per)
        if s.kind == 'lens' then
            Send(s.index, { tml = packed })
        else
            Send(s.index, { tmw = packed })
        end
        s.sent = s.n
    end
    s.lastSend = GetSystemTimeSeconds()
end

--- Our stroke is over. One that never moved (Coach.MinMove) was a right
--- click, not a drawing: no dot -- an order where it was, shown to the
--- player as any order of theirs would be, never given (env.ghostOrder).
local function EndStroke()
    local s = state.stroke
    if not s then
        return
    end
    state.stroke = false
    if s.n < 2 and s.sent == 0 then
        if s.local_ then
            s.local_.endT = GetSystemTimeSeconds() - 1000
        end
        pcall(env.ghostOrder)
        return
    end
    state.stroke = s
    FlushStroke(true)
    state.stroke = false
    if s.local_ then
        s.local_.endT = GetSystemTimeSeconds()
    end
end

--- A click ring on their screen at our screen point (x, y), and on ours.
---@param view WorldView
---@param x number
---@param y number
local function Click(view, x, y)
    local target = state.following
    local l, t, w, h = TargetRect(view, target)
    local u, v = (x - l) / w, (y - t) / h
    Ring(x, y, env.myColor)
    Send(IndexOf(target), { tmk = Int(u * 1000) .. ',' .. Int(v * 1000) })
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

--- Numbers off the wire (comma-separated whole numbers), into `scratch`.
--- (Only the click ring still comes this way.)
---@param s any
---@param max number
---@return number   # how many (0: none, or not readable)
local function ReadInts(s, max)
    if type(s) ~= 'string' or string.len(s) > 8 * max then
        return 0
    end
    local n = 0
    for word in string.gfind(s, '[^,]+') do
        if n >= max then break end
        if not string.find(word, '^%-?%d+$') then
            return 0
        end
        n = n + 1
        scratch[n] = tonumber(word)
    end
    return n
end

--- A whole number's offset, and the range a one-digit difference covers.
local WHOLE = 131072
local SMALL = 31
local ESCAPE = 63

--- A chunk of a stroke as one string (see the top of the file): `values`
--- holds whole numbers, `per` to a point; points `from`..`to` go.
---@param id number
---@param done boolean
---@param values number[]
---@param from number
---@param to number
---@param per number   # 2 on the screen, 3 on the map
---@return string
function PackPoints(id, done, values, from, to, per)
    local parts = {}
    local Put = WirePack.PutDigits
    Put(parts, done and 1 or 0, 1)
    Put(parts, math.mod(math.floor(id), 4096), 2)
    local base = (from - 1) * per
    for i = base + 1, to * per do
        local v = values[i]
        if i <= base + per then
            Put(parts, v + WHOLE, 3)
        else
            local d = v - values[i - per]
            if d >= -SMALL and d <= SMALL then
                Put(parts, d + SMALL, 1)
            else
                Put(parts, ESCAPE, 1)
                Put(parts, d + WHOLE, 3)
            end
        end
    end
    return table.concat(parts)
end

--- The reverse, into `out` (scratch unless given): how many numbers (whole
--- points only; 0 if the string is not one), the stroke's id, and whether it
--- is done.
---@param s any
---@param per number
---@param max number   # numbers at most
---@param out? table
---@return number, number, boolean
function UnpackPoints(s, per, max, out)
    out = out or scratch
    if type(s) ~= 'string' or string.len(s) > 4 * max + 3 then
        return 0, 0, false
    end
    local Get = WirePack.GetDigits
    local done, id = Get(s, 1, 1), Get(s, 2, 2)
    if not done or not id then
        return 0, 0, false
    end
    local at, len, n = 4, string.len(s), 0
    while at <= len and n < max do
        local v
        if n < per then
            v = Get(s, at, 3)
            if not v then return 0, 0, false end
            v = v - WHOLE
            at = at + 3
        else
            local d = Get(s, at, 1)
            if not d then return 0, 0, false end
            at = at + 1
            if d == ESCAPE then
                d = Get(s, at, 3)
                if not d then return 0, 0, false end
                d = d - WHOLE
                at = at + 3
            else
                d = d - SMALL
            end
            v = out[n + 1 - per] + d
        end
        n = n + 1
        out[n] = v
    end
    return n - math.mod(n, per), id, done == 1
end

--- The colour someone draws in: a player's own, an observer's Coach.Color.
---@param sender string
---@return string
local function ColorOf(sender)
    local record = env.peers[sender]
    if record and not record.coach then
        return CursorData.SafeUIColor(record.color)
    end
    return Config.Coach.Color
end

--- Someone stopped following us: their strokes fade from now.
---@param sender string
local function EndStrokesOf(sender)
    local prefix = sender .. '/'
    local now = GetSystemTimeSeconds()
    for i = 1, draw.nlens do
        local s = draw.lens[i]
        if not s.endT and string.sub(s.key, 1, string.len(prefix)) == prefix then
            s.endT = now
        end
    end
    for i = 1, draw.nink do
        local s = draw.ink[i]
        if not s.endT and string.sub(s.key, 1, string.len(prefix)) == prefix then
            s.endT = now
        end
    end
end

--- Someone following us (tmf).
local function OnFollowed(sender, index, msg)
    if msg.ta ~= env.myArmy then
        return
    end
    local record = env.peers[sender]
    local on = msg.tmf == 1
    local was = state.followers[index]
    if on and not was then
        state.followers[index] = record and not record.coach and 'team' or 'spec'
        if state.followers[index] == 'team' then
            state.followTeam = state.followTeam + 1
        end
        -- Our camera at once, not on its next refresh.
        pcall(env.forceView)
    elseif not on and was then
        if was == 'team' then
            state.followTeam = state.followTeam - 1
        end
        state.followers[index] = nil
        EndStrokesOf(sender)
    end
    -- Their cursor is not shown while they look through our eyes.
    if record then
        record.followsMe = on
    end
end

--- An observer coaching us (tmh).
local function OnCoached(sender, msg)
    if env.observer then
        return
    end
    if msg.tmh == 1 and not state.coaches[sender] then
        state.coaches[sender] = true
        pcall(env.addCoach, sender)
    elseif msg.tmh ~= 1 and state.coaches[sender] then
        state.coaches[sender] = nil
        EndStrokesOf(sender)
        pcall(env.removeCoach, sender)
    end
end

--- A message of ours (tmf, tmh, tml, tmk, tmw)? Then it is handled here:
--- true. Anything else: false, for the cursor code.
---@param sender any
---@param msg table
---@return boolean
function Receive(sender, msg)
    if msg.tmf == nil and msg.tmh == nil and msg.tml == nil and msg.tmk == nil and msg.tmw == nil then
        return false
    end
    if not Live() or type(sender) ~= 'string' then
        return true
    end
    local index = env.clientIndex[sender]
    if not index then
        return true
    end
    if msg.tmf ~= nil then
        OnFollowed(sender, index, msg)
        return true
    end
    if msg.tmh ~= nil then
        OnCoached(sender, msg)
        return true
    end
    if not state.show then
        return true
    end

    local cfg = Config.Coach
    if msg.tml ~= nil and state.followers[index] then
        local n, id, done = UnpackPoints(msg.tml, 2, cfg.MaxPoints * 2)
        if n == 0 then
            return true
        end
        local s = LensStroke(sender .. '/' .. id, ColorOf(sender))
        for i = 1, n - 1, 2 do
            LensPoint(s, scratch[i] / 1000, scratch[i + 1] / 1000)
        end
        if done then
            s.endT = GetSystemTimeSeconds()
        end
    elseif msg.tmk ~= nil and state.followers[index] then
        if ReadInts(msg.tmk, 2) == 2 then
            local l, t, w, h = MainRect()
            Ring(l + scratch[1] / 1000 * w, t + scratch[2] / 1000 * h, ColorOf(sender))
        end
    elseif msg.tmw ~= nil and state.coaches[sender] then
        local n, id, done = UnpackPoints(msg.tmw, 3, cfg.MaxPoints * 3)
        if n == 0 then
            return true
        end
        local s = InkStroke(sender .. '/' .. id, ColorOf(sender))
        for i = 1, n - 2, 3 do
            InkPoint(s, scratch[i] / 10, scratch[i + 1] / 10, scratch[i + 2] / 10)
        end
        if done then
            s.endT = GetSystemTimeSeconds()
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

---@return boolean
local function InCommandMode()
    local ok, on = pcall(function()
        return import('/lua/ui/game/commandmode.lua').InCommandMode()
    end)
    return ok and on and true or false
end

---@return boolean
local function HasSelection()
    local ok, units = pcall(GetSelectedUnits)
    return ok and type(units) == 'table' and units[1] ~= nil
end

--- What a right-drag does now: 'lens' (following, live), 'ink' (coaching,
--- not following), or false (the game's own).
---@return string | false
local function Mode()
    if not Live() then
        return false
    end
    if state.following then
        return 'lens'
    end
    if state.coaching then
        return 'ink'
    end
    return false
end

--- A world view's event. True: it was ours, and the game must not see it
--- (no drawing reaches the sim, no click selects anything).
---@param view WorldView
---@param event table
---@return boolean
function ViewEvent(view, event)
    local mode = Mode()
    local t = event.Type
    if not mode then
        if state.stroke then
            EndStroke()
        end
        return false
    end
    local m = event.Modifiers or {}
    if t == 'ButtonPress' or t == 'ButtonDClick' then
        -- Coaching, a right press is a drawing only as the game's own would
        -- be: nothing selected, no command mode. Anything else is an order,
        -- which TeamMouse shows the player and keeps from the game.
        if m.Right and mode == 'ink' and (InCommandMode() or HasSelection()) then
            return false
        end
        -- In build mode (or an order mode) a right click leaves it.
        if m.Right and InCommandMode() then
            return false
        end
        if m.Right then
            if state.stroke then
                EndStroke()
            end
            StartStroke(mode, view, event.MouseX or 0, event.MouseY or 0)
            StrokePoint(event.MouseX, event.MouseY)
            return true
        end
        -- (An observer's left clicks are their own: the build menu, to show
        -- the player where to build.)
        if m.Left and mode == 'lens' and not env.observer then
            Click(view, event.MouseX or 0, event.MouseY or 0)
            return true
        end
        return false
    end
    if t == 'MouseMotion' and state.stroke then
        -- Like the game's own right drags, the release may never come: a
        -- motion without the button held ends it.
        if event.Modifiers and not m.Right then
            EndStroke()
        else
            StrokePoint(event.MouseX, event.MouseY)
        end
        return false
    end
    if t == 'ButtonRelease' and state.stroke then
        StrokePoint(event.MouseX, event.MouseY)
        EndStroke()
        return true
    end
    -- The release of a click that was a ring: the game never saw the press.
    if t == 'ButtonRelease' and mode == 'lens' and m.Left and not env.observer then
        return true
    end
    return false
end

--- The followed player's view in our main world view.
---@return WorldView | nil
local function MainView()
    local views = WorldViewManager.GetWorldViews()
    return views and views['WorldCamera']
end

--- The root frame's event: a lens stroke carries on over the interface. An
--- observer following has no capture layer (their clicks are their own),
--- so a right press that comes up from the interface starts one here.
---@param event table
---@return boolean   # true: ours
function RootEvent(event)
    local t = event.Type
    local m = event.Modifiers
    if t == 'ButtonPress' and m and m.Right and env and env.observer and Mode() == 'lens'
        and not InCommandMode() then
        local view = MainView()
        if view then
            if state.stroke then
                EndStroke()
            end
            StartStroke('lens', view, event.MouseX or 0, event.MouseY or 0)
            StrokePoint(event.MouseX, event.MouseY)
            return true
        end
    end
    local s = state.stroke
    if not s then
        return false
    end
    if t == 'ButtonRelease' then
        EndStroke()
    elseif t == 'MouseMotion' and s.kind == 'lens' then
        if event.Modifiers and not event.Modifiers.Right then
            EndStroke()
        else
            StrokePoint(event.MouseX, event.MouseY)
        end
    end
    return false
end

--- An event on the capture layer: while following, the whole screen (but
--- the panel) is for drawing on their screen -- the interface too. A right
--- drag is a stroke, a left click a ring; the wheel goes on to the map, so
--- zooming and scrolling free still work.
---@param event table
---@return boolean
local function CaptureEvent(event)
    local t = event.Type
    local view = MainView()
    if t == 'WheelRotation' then
        if view and view.HandleEvent then
            pcall(view.HandleEvent, view, event)
        end
        return true
    end
    if Mode() ~= 'lens' or not view then
        return true
    end
    local m = event.Modifiers or {}
    if t == 'ButtonPress' or t == 'ButtonDClick' then
        if m.Right and InCommandMode() then
            -- (The layer has taken the click from the game: leave the mode here.)
            pcall(function() import('/lua/ui/game/commandmode.lua').EndCommandMode(true) end)
        elseif m.Right then
            if state.stroke then
                EndStroke()
            end
            StartStroke('lens', view, event.MouseX or 0, event.MouseY or 0)
            StrokePoint(event.MouseX, event.MouseY)
        elseif m.Left then
            Click(view, event.MouseX or 0, event.MouseY or 0)
        end
    elseif t == 'MouseMotion' and state.stroke then
        if event.Modifiers and not m.Right then
            EndStroke()
        else
            StrokePoint(event.MouseX, event.MouseY)
        end
    elseif t == 'ButtonRelease' and state.stroke then
        StrokePoint(event.MouseX, event.MouseY)
        EndStroke()
    end
    return true
end

--- Raise the capture layer while following live, lower it otherwise. The
--- panel goes above it meanwhile, so a click on the name still stops.
--- FAF's menu bar (lua/ui/game/tabs.lua: menu, pause, ...) above the capture
--- layer while it is up, so the menu still opens; back to where it was after.
---@param on boolean
local function RaiseMenu(on)
    pcall(function()
        local tabs = import('/lua/ui/game/tabs.lua').controls
        for _, key in ipairs({ 'parent', 'collapseArrow' }) do
            local control = tabs and tabs[key]
            if control and control.Depth then
                if on then
                    control.TeamMouseDepth = control.TeamMouseDepth or control.Depth()
                    control.Depth:Set(Config.Coach.PanelRaisedDepth)
                elseif control.TeamMouseDepth then
                    control.Depth:Set(control.TeamMouseDepth)
                    control.TeamMouseDepth = nil
                end
            end
        end
    end)
end

local function SyncCapture()
    -- Players only: an observer's clicks stay theirs (the build menu).
    local want = Mode() == 'lens' and not env.observer
    if want == draw.captureShown then
        return
    end
    if want and not draw.capture then
        local frame = GetFrame(0)
        if not frame then
            return
        end
        local capture = Bitmap(frame)
        capture:Hide()
        capture.Left:Set(function() return frame.Left() end)
        capture.Top:Set(function() return frame.Top() end)
        capture.Width:Set(function() return frame.Width() end)
        capture.Height:Set(function() return frame.Height() end)
        capture.Right:Set(function() return capture.Left() + capture.Width() end)
        capture.Bottom:Set(function() return capture.Top() + capture.Height() end)
        capture.Depth:Set(Config.Coach.CaptureDepth)
        capture:SetSolidColor('00ffffff')
        capture.HandleEvent = function(self, event)
            return CaptureEvent(event)
        end
        draw.capture = capture
    end
    draw.captureShown = want
    if want then
        draw.capture:Show()
    else
        if state.stroke then
            EndStroke()
        end
        draw.capture:Hide()
    end
    pcall(env.raisePanel, want)
    RaiseMenu(want)
end

--------------------------------------------------------------------------------
-- Following and coaching
--------------------------------------------------------------------------------

--- An observer looks through the eyes of the army they follow or coach:
--- their focus army is set to it (as FAF's score panel does for a click on
--- an army), so their selection can be copied. Stopping leaves it there.
local function SyncFocus()
    if not env or not env.observer or env.replay then
        return
    end
    local who = state.following or state.coaching
    local army = who and who.army or -1
    if who then
        -- Locked there: changed from elsewhere (the score panel), it is put
        -- back. Once, then again only if it has not taken a second later: the
        -- change takes a moment to arrive, and each request is a moderator
        -- event in everyone's log (reported: a screenful of them).
        local ok, now = pcall(GetFocusArmy)
        local t = GetSystemTimeSeconds()
        if (not ok or now ~= army)
            and (state.focusArmy ~= army or t - (state.focusT or -1000) >= 1) then
            state.focusT = t
            pcall(ConExecute, 'SetFocusArmy ' .. tostring(army - 1))
        end
    end
    -- (Neither any more: the focus stays on that army.)
    state.focusArmy = army
end

---@return table | nil
local function Camera()
    local ok, camera = pcall(GetCamera, 'WorldCamera')
    if ok then
        return camera
    end
end

--- Tell whoever we follow that we have stopped.
local function SayUnfollow()
    local old = state.following
    if old and Live() then
        Send(IndexOf(old), { tmf = 0, ta = old.army })
    end
end

--- Following stopped from elsewhere (a hard scroll): the camera stays
--- where it is.
---@param record? table
function FollowStopped(record)
    if state.stroke then
        EndStroke()
    end
    SayUnfollow()
    state.following = false
    state.before = false
    SyncFocus()
    SyncCapture()
end

--- A player's name was clicked in the panel: follow their view, or stop
--- (and go back to where we were looking before).
---@param record table
function ToggleFollow(record)
    if not env or not Config.Follow.Enabled then
        return
    end
    if record.follow then
        record.follow = false
        if state.stroke then
            EndStroke()
        end
        SayUnfollow()
        state.following = false
        local before = state.before
        state.before = false
        local camera = Camera()
        if before and camera then
            pcall(camera.RestoreSettings, camera, before)
        end
    else
        -- Only one at a time; the camera to go back to is from before the first.
        for _, other in pairs(env.peers) do
            if other ~= record and other.follow then
                other.follow = false
            end
        end
        if state.stroke then
            EndStroke()
        end
        SayUnfollow()
        if not state.before then
            local camera = Camera()
            local ok, saved = false, nil
            if camera then
                ok, saved = pcall(camera.SaveSettings, camera)
            end
            state.before = ok and type(saved) == 'table' and saved or false
        end
        record.follow = true
        if not env.replay then
            state.following = record
            state.followSaidT = GetSystemTimeSeconds()
            if Live() then
                Send(IndexOf(record), { tmf = 1, ta = record.army })
            end
            -- An observer coaches whoever they last followed (Coach.CoachFollowed).
            if env.observer and Live() and Config.Coach.CoachFollowed and state.coaching ~= record then
                SetCoach(record, true)
            end
        end
    end
    SyncFocus()
    SyncCapture()
    pcall(env.panelSync)
end

--- The panel's "coach" box (live observers).
---@param record table
---@param on boolean
function SetCoach(record, on)
    if not env or not env.observer or env.replay then
        return
    end
    local old = state.coaching
    if old and (old ~= record or not on) then
        if state.stroke and state.stroke.kind == 'ink' then
            EndStroke()
        end
        old.coached = false
        Send(IndexOf(old), { tmh = 0 })
        state.coaching = false
        pcall(env.setCoachTarget, false)
    end
    if on and old ~= record then
        state.coaching = record
        state.coachSel = -1
        record.coached = true
        Send(IndexOf(record), { tmh = 1 })
        pcall(env.setCoachTarget, IndexOf(record) or false)
    end
    SyncFocus()
    pcall(env.panelSync)
end

--- The panel's "drawings on my screen" box: show what those following or
--- coaching us draw. Off takes down what is up.
---@param on boolean
function SetShow(on)
    state.show = on and true or false
    if not state.show then
        ClearLens()
        draw.nink = 0
        if draw.shape then draw.shape.Hidden = true end
    end
end

---@return boolean
function Showing()
    return state.show
end

--- Coaching someone (an observer whose cursor goes to them).
---@return boolean
function Coaching()
    return state.coaching and true or false
end

--- An observer following or coaching someone, live: their focus is that
--- army, so what they do is tracked (and kept from the game).
---@return boolean
function Acting()
    return (Live() and env.observer and (state.following or state.coaching)) and true or false
end

--- A teammate is following us: they need our camera, as observers get it.
---@return boolean
function TeamFollowing()
    return state.followTeam > 0
end

--- Whether a coach following us is doing something worth their cursor: a
--- building in hand, a drag (box, line, order), a click, or a stroke on
--- our screen in progress. (Coach.AlwaysShowCursor: always.)
---@param record table
---@param now number
---@return boolean
local function CoachBusy(record, now)
    if Config.Coach.AlwaysShowCursor or record.buildId or (record.renderDrag or 0) ~= 0 then
        return true
    end
    for _, pulse in pairs(record.pulses or {}) do
        if pulse.t and now >= pulse.t - 0.2 and now - pulse.t <= 0.3 then
            return true
        end
    end
    local prefix = tostring(record.name) .. '/'
    for i = 1, draw.nlens do
        local s = draw.lens[i]
        if not s.endT and string.sub(s.key, 1, string.len(prefix)) == prefix then
            return true
        end
    end
    return false
end

--- Each frame.
---@param delta number
function Frame(delta)
    if not env then
        return
    end
    local now = GetSystemTimeSeconds()
    if draw.nlens > 0 or draw.nrings > 0 then
        AnimateLens(now)
    end
    if draw.nink > 0 then
        AnimateInk(now)
    end

    local s = state.stroke
    if s and now - s.lastSend >= Config.Coach.SendInterval then
        FlushStroke(false)
    end

    -- Following a teammate whose camera has not come: they may not have
    -- heard us. Say it again, now and then.
    local f = state.following
    if f and not f.cam and Live() and now - state.followSaidT >= 2 then
        state.followSaidT = now
        Send(IndexOf(f), { tmf = 1, ta = f.army })
    end

    -- A coach following us: their cursor (record.coachFade, used by the
    -- frame driver) up while they do something, fading out after.
    for name in pairs(state.coaches) do
        local record = env.peers[name]
        if record and record.followsMe then
            if CoachBusy(record, now) then
                record.coachFade = 1
            else
                local step = (delta or 0) / math.max(Config.Coach.CursorFadeSeconds, 0.01)
                record.coachFade = math.max(0, (record.coachFade or 0) - step)
            end
        elseif record then
            record.coachFade = 0
        end
    end

    -- In case following or coaching changed from elsewhere.
    SyncCapture()
    SyncFocus()

    -- An observer coaching or following someone: our selection is theirs
    -- (our focus army is theirs: SyncFocus).
    local c = state.coaching
    if env.observer and state.following then
        c = state.following
    end
    if c and (c ~= state.selFrom or c.selVersion ~= state.coachSel) then
        state.selFrom = c
        state.coachSel = c.selVersion
        local units = {}
        for _, id in ipairs(c.sel or {}) do
            local ok, unit = pcall(GetUnitById, id)
            if ok and unit then
                table.insert(units, unit)
            end
        end
        pcall(SelectUnits, units)
    end
end

--- The start of a session.
---@param e table
function Start(e)
    Destroy()
    env = e
    state.show = Config.Coach.ShowLens and true or false
end

function Destroy()
    if env and Live() then
        SayUnfollow()
        if state.coaching then
            Send(IndexOf(state.coaching), { tmh = 0 })
        end
    end
    if draw.root then
        pcall(draw.root.Destroy, draw.root)
    end
    for view in pairs(draw.shaped) do
        pcall(view.RemoveShape, view, 'TeamMouseCoachInk')
    end
    draw.root = false
    draw.free, draw.nfree, draw.made = {}, 0, 0
    draw.lens, draw.nlens = {}, 0
    draw.rings, draw.nrings = {}, 0
    draw.ink, draw.nink = {}, 0
    draw.shape, draw.shaped = false, {}
    if draw.capture then
        pcall(draw.capture.Destroy, draw.capture)
    end
    if draw.captureShown and env then
        pcall(env.raisePanel, false)
        RaiseMenu(false)
    end
    draw.capture, draw.captureShown = false, false
    state.focusArmy, state.selFrom = -1, false
    state.following, state.before = false, false
    state.coaching, state.coachSel = false, -1
    state.followers, state.followTeam = {}, 0
    state.coaches = {}
    state.stroke = false
    env = false
end

--- For the tests.
function Get()
    return state, draw
end
