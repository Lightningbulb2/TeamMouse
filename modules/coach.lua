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
--** Live, while you follow someone, your clicks are your own (select, build,
--** order your own units), except a right-drag with nothing selected: that is
--** not a drawing in the game (nothing reaches the sim or the replay), it is
--** drawn straight on THEIR screen, as if on the camera lens -- fixed to the
--** screen, over the interface -- and fades (Coach.LensFadeSeconds) once it is
--** finished. You see it too. A right click that never moved is a ghost order:
--** a marker for them, nothing given. (Observers draw with units selected too:
--** theirs are the player's, copied.)
--**
--** A teammate following you stays in sight, cursor and drawings; an observer
--** coaching and following you shows their cursor only while they act
--** (Coach.AlwaysShowCursor: always). Whoever follows you is sent your
--** panel's ticks, and draws them round their own boxes (panel.lua).
--**
--** Coaching (live observers only). The panel's "coach" box, on as many
--** players as you like (following someone ticks theirs):
--**   * your cursor is sent to those players, and to nobody else (observers
--**     are never recorded into the replay);
--**   * your selection follows the one you follow, or else the one you
--**     ticked last;
--**   * a right-drag on the map (not following) is drawn on all their maps,
--**     not through the game's painting, and fades like the lens strokes.
--**     Following, a right-drag is a lens stroke, on the followed player's
--**     screen only.
--**
--** Messages (plain tables, Identifier = Config.ChatIdentifier), each to the
--** one client concerned:
--**   { tmf = 1|0, ta = army }     I follow you / no longer
--**   { tmh = 1|0, tv = 1|0 }      I coach you / no longer (observers); tv:
--**                                I am following someone (anyone), so my
--**                                cursor shows only while I act. Said again
--**                                whenever that changes.
--**   { tml = <points> }           a lens stroke: thousandths of your main view
--**   { tmw = <points> }           a coach's stroke on the map, world tenths
--**   { tmp = <panel> }            my panel's ticks, to whoever follows me
--**                                (Panel.State; again when they change)
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

--- The lobby's choice of team for observers (observerteam.lua): here for
--- teammouse.lua too, which is at Lua 5.0's 200 file-level locals.
ObserverTeam = import(_G.TeamMousePath .. '/modules/observerteam.lua')

--- What teammouse.lua hands us at the start of a session (Start):
---   send(index, msg)      SessionSendChatMessage to one client
---   clientIndex           name -> client index
---   peers                 name -> record
---   myArmy, observer, replay
---   myColor               our own strokes' colour
---   addCoach(name)        a cursor for an observer coaching us
---   removeCoach(name)
---   setCoachTarget(list)  the client indices an observer's cursor goes to
---   forceView()           send our camera with the next packet
---   viewsChanged()        we opened or closed a view: check them now
---   panelSync()           show the panel as following/coaching now is
---   ghostOrder()          an order marker where the pointer is, never given
---   panelState()          our panel's ticks, as a string (Panel.State)
---   panelOverlay(state)   draw the followed player's ticks round ours (false: none)
local env = false

--- Our side of it.
---   follows     the records we follow, in order: one, or two (Shift-click,
---               live), each on a view of its own (FollowView)
---   following   the first of them, live (false: nobody): their panel, the
---               focus and selection, lens strokes from the interface
---   before      view key -> its camera before following began on it (put
---               back when following there ends by a click)
---   openedSplit we opened the splitscreen (and close it after)
---   splitOwn    while it is open with one followed: the side that is ours
---               (closing it, the main view carries on from there)
---   splitOne    the one we follow was Ctrl-clicked: in the splitscreen, as
---               Follow.AutoSplit would (on the main monitor, the other side ours)
---   head2       our second view on the second monitor, beside CameraHead2,
---               for two followed (false: none); head2Rect, CameraHead2's
---               own rectangle to give back
---   coached     record -> true: everyone we coach (observers)
---   coaching    the one of them our focus and selection go by when we follow
---               nobody: the last ticked (false: nobody)
---   coachSel    their selVersion last copied into ours
---   followers   client index -> true: who follows us
---   followTeam  how many of them are teammates (they need our camera)
---   coaches     name -> true: observers coaching us
---   stroke      the stroke we are drawing, or false
---   nextId      our stroke ids
---   followSaidT when we last said we follow (said again while no camera comes)
local state = {
    follows = {}, following = false, before = {}, openedSplit = false, splitOwn = false, splitOne = false, head2 = false, head2Rect = false,
    coached = {}, coaching = false, coachSel = -1,
    followers = {}, followTeam = 0,
    coaches = {},
    stroke = false, nextId = 0,
    followSaidT = 0,
    -- (observers) the army our focus is set to, and whose selection ours copies
    focusArmy = -1, selFrom = false,
}

--- What is drawn.
---   root      the overlay over everything (lens strokes)
---   free      spare dots, explicit count (nfree)
---   lens      lens strokes, explicit count (nlens), each
---             { key, color, l, t, w, h, x, y, n, dots, nd, endT, lastT, alpha }
---   ink       strokes on the map, explicit count (nink), each
---             { key, color, pts, n, endT, lastT, drawColor }
---   shape     draws the ink (every world view, FAF's AddShape)
---   shaped    view -> true: has the shape
local draw = {
    root = false,
    free = {}, nfree = 0, made = 0,
    lens = {}, nlens = 0,
    ink = {}, nink = 0,
    shape = false, shaped = {},
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

--- Everyone we coach, as client indices: where our cursor and our ink go.
---@return number[]
local function CoachIndices()
    local out = {}
    for record in pairs(state.coached) do
        local index = IndexOf(record)
        if index then
            table.insert(out, index)
        end
    end
    return out
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
-- Lens strokes
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

--- Fade finished strokes; let go of what is done.
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

--- Start a stroke of ours: 'lens' (following; on their screen) or 'ink'
--- (coaching; on their map).
---@param kind string
---@param view WorldView
---@param x number
---@param y number
local function StartStroke(kind, view, x, y)
    state.nextId = state.nextId + 1
    local target = kind == 'lens' and FollowedOn(view) or state.coaching
    -- (A lens stroke goes to the player we follow; ink to everyone we coach.)
    local indices = kind == 'lens' and { IndexOf(target) } or CoachIndices()
    local s = { kind = kind, id = state.nextId, target = target, indices = indices,
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
        local msg = s.kind == 'lens' and { tml = packed } or { tmw = packed }
        for _, index in ipairs(s.indices) do
            Send(index, msg)
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

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

--- A whole number's offset, and the range a one-digit difference covers.
local WHOLE = 131072
local SMALL = 31
local ESCAPE = 63

--- PackPoints' pieces, reused (WirePack.PutDigits counts them in n).
local packParts = { n = 0 }

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
    local parts = packParts
    parts.n = 0
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
    return table.concat(parts, '', 1, parts.n)
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
    if record and not record.observer then
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
        state.followers[index] = record and not record.observer and 'team' or 'spec'
        if state.followers[index] == 'team' then
            state.followTeam = state.followTeam + 1
        end
        -- Our camera at once, not on its next refresh; and our panel's ticks.
        pcall(env.forceView)
        local ok, panel = pcall(env.panelState)
        if ok and type(panel) == 'string' then
            Send(index, { tmp = panel })
        end
    elseif not on and was then
        if was == 'team' then
            state.followTeam = state.followTeam - 1
        end
        state.followers[index] = nil
        EndStrokesOf(sender)
    end
    -- (A coach's cursor shows then only while they act: CoachBusy.)
    if record then
        record.followsMe = on
    end
end

--- An observer coaching us (tmh).
local function OnCoached(sender, msg)
    if env.observer then
        return
    end
    if msg.tmh == 1 then
        if not state.coaches[sender] then
            state.coaches[sender] = true
            pcall(env.addCoach, sender)
            -- Following us already (their tmf came first, before the record
            -- was theirs): their cursor fades between actions from the start
            -- (reported: it did not, the first time they followed in a match).
            local record = env.peers[sender]
            local index = env.clientIndex[sender]
            if record and index and state.followers[index] then
                record.followsMe = true
            end
        end
        -- Following someone (maybe not us): their cursor only while they act.
        local record = env.peers[sender]
        if record then
            record.coachViewing = msg.tv == 1
        end
    elseif state.coaches[sender] then
        state.coaches[sender] = nil
        local record = env.peers[sender]
        if record then
            record.coachViewing = false
        end
        EndStrokesOf(sender)
        pcall(env.removeCoach, sender)
    end
end

--- A message of ours (tmf, tmh, tml, tmw, tmp)? Then it is handled here:
--- true. Anything else: false, for the cursor code.
---@param sender any
---@param msg table
---@return boolean
function Receive(sender, msg)
    if msg.tmf == nil and msg.tmh == nil and msg.tml == nil and msg.tmw == nil and msg.tmp == nil then
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
    -- The panel of the player we follow, drawn round ours.
    if msg.tmp ~= nil then
        -- (Kept for each player we follow: the first's is drawn, and the
        -- second's as soon as it is the first.)
        local r = env.peers[sender]
        if r and r.follow and type(msg.tmp) == 'string' and string.len(msg.tmp) < 4000 then
            r.panelSeen = msg.tmp
            if r == state.following then
                pcall(env.panelOverlay, msg.tmp, r.army)
            end
        end
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
    -- (Following, on a view that shows nobody we follow: as if not.)
    if mode == 'lens' and not FollowedOn(view) then
        mode = state.coaching and 'ink' or false
    end
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
        -- A player following, with units selected: an order for their own
        -- units, as in the game. (An observer's selection is the player's,
        -- copied: theirs is always a drawing.)
        if m.Right and mode == 'lens' and not env.observer and HasSelection() then
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
    return false
end

--- The view the first player we follow is on.
---@return WorldView | nil
local function MainView()
    local key = state.following and FollowView(state.following)
    return key and Views()[key]
end

--- The root frame's event: a lens stroke carries on over the interface, and
--- a right press that comes up from the interface (one the control under it
--- did not take) starts one, as on the map.
---@param event table
---@return boolean   # true: ours
function RootEvent(event)
    local t = event.Type
    local m = event.Modifiers
    if t == 'ButtonPress' and m and m.Right and env and Mode() == 'lens'
        and not InCommandMode() and (env.observer or not HasSelection()) then
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

--------------------------------------------------------------------------------
-- Following and coaching
--------------------------------------------------------------------------------

--- Our second view on the second monitor (OpenHead2).
HEAD2 = 'TeamMouseHead2'

--- Which view is ours, in order (OwnView).
local OWN_ORDER = { 'WorldCamera', 'WorldCamera2', 'CameraHead2', 'TeamMouseHead2' }

--- The world views there are now.
---@return table
function Views()
    return WorldViewManager.GetWorldViews() or {}
end

--- The view a single follow goes on: the second monitor's, if there is
--- one (Follow.SecondMonitor); else the splitscreen's right side if it is
--- open and Follow.RightSide; else the main view (the left side).
---@return string
function DefaultView()
    local views = Views()
    local cfg = Config.Follow
    -- (Ctrl-clicked: the splitscreen here, not the second monitor.)
    if cfg.SecondMonitor and views['CameraHead2'] and not state.splitOne then
        return 'CameraHead2'
    end
    if cfg.RightSide and views['WorldCamera2'] then
        return 'WorldCamera2'
    end
    return 'WorldCamera'
end

--- The view `record` is followed on (nil: none right now -- two followed,
--- and the second view would not open). Two: the second monitor's two
--- halves (HeadSplit), or the splitscreen's left and right. Its camera from
--- before is kept the first time (state.before).
---@param record table
---@return string | nil
function FollowView(record)
    local key
    if state.follows[2] then
        local i = (record == state.follows[1] and 1) or (record == state.follows[2] and 2) or nil
        local views = Views()
        if i and views['CameraHead2'] and state.head2 then
            key = i == 1 and 'CameraHead2' or (views[HEAD2] and HEAD2) or nil
        elseif i then
            key = i == 1 and 'WorldCamera' or (views['WorldCamera2'] and 'WorldCamera2') or nil
        end
    else
        key = DefaultView()
    end
    if key and not state.before[key] then
        local ok, camera = pcall(GetCamera, key)
        local okSave, saved = false, nil
        if ok and camera then
            okSave, saved = pcall(camera.SaveSettings, camera)
        end
        if okSave and type(saved) == 'table' then
            state.before[key] = saved
        end
    end
    return key
end

--- The view that is ours, following nobody, for what we show others (our
--- view outline and camera): the main view, else the splitscreen's right,
--- else either on the second monitor. The main view if every one follows.
---@return string
function OwnView()
    local views = Views()
    local followed = {}
    for _, r in ipairs(state.follows) do
        local key = FollowView(r)
        if key then
            followed[key] = true
        end
    end
    for _, key in ipairs(OWN_ORDER) do
        if views[key] and not followed[key] then
            return key
        end
    end
    return 'WorldCamera'
end

--- Whom we follow on `view` (nil: nobody).
---@param view WorldView
---@return table | nil
function FollowedOn(view)
    local views = Views()
    for _, r in ipairs(state.follows) do
        local key = FollowView(r)
        if key and views[key] == view then
            return r
        end
    end
end

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

--- Tell `record` we no longer follow them (and, if theirs is the panel we
--- draw round ours, stop).
---@param record table
local function SayUnfollow(record)
    if record and Live() and not env.replay then
        Send(IndexOf(record), { tmf = 0, ta = record.army })
    end
    if record and env and record == state.following then
        pcall(env.panelOverlay, false)
    end
end

--- Tell everyone we coach whether we follow someone now (tv): while we do,
--- they see our cursor only while we act, as the one we follow does.
local function SayViewing()
    if not env or not env.observer or not Live() then
        return
    end
    local tv = state.following and 1 or 0
    for record in pairs(state.coached) do
        Send(IndexOf(record), { tmh = 1, tv = tv })
    end
end

--- Open or close the splitscreen, as the game's Home and End keys do. (It
--- clears the selection: an observer's copied one is put back -- selFrom.)
---@param on boolean
local function SetSplit(on)
    pcall(function() import('/lua/ui/game/borders.lua').SplitMapGroup(on) end)
    state.selFrom = false
    pcall(env.viewsChanged)
end

--- A camera's settings now (nil if it cannot be had).
---@param key string
---@return table | nil
local function CameraSettings(key)
    local ok, camera = pcall(GetCamera, key)
    if ok and camera then
        local okSave, saved = pcall(camera.SaveSettings, camera)
        if okSave and type(saved) == 'table' then
            return saved
        end
    end
end

---@param key string
---@param settings table
local function SetCamera(key, settings)
    local ok, camera = pcall(GetCamera, key)
    if ok and camera then
        pcall(camera.RestoreSettings, camera, settings)
    end
end

--- Our second view on the second monitor: CameraHead2 halved, and a view
--- of ours (its own camera: the engine makes one for any name) on the
--- right half, starting where CameraHead2 looks.
local function OpenHead2()
    local main = Views()['CameraHead2']
    if not main or state.head2 then
        return
    end
    local ok, err = pcall(function()
        local l, t, r, b = main.Left(), main.Top(), main.Right(), main.Bottom()
        local mid = math.floor((l + r) / 2)
        local WorldView = import('/lua/ui/controls/worldview.lua').WorldView
        local UIUtil = import('/lua/ui/uiutil.lua')
        local view = WorldView(main:GetParent(), HEAD2, 1, false)
        view:Register(HEAD2, nil, 'TeamMouse second view', 3)
        if view.SetRenderPass and UIUtil.UIRP_UnderWorld then
            -- (As the game's own: else the camera lags a frame behind.)
            view:SetRenderPass(UIUtil.UIRP_UnderWorld + UIUtil.UIRP_PostGlow)
        end
        state.head2Rect = { l, t, r, b }
        main.Right:Set(mid - 2)
        main.Width:Set(mid - 2 - l)
        view.Left:Set(mid + 2)
        view.Top:Set(t)
        view.Right:Set(r)
        view.Bottom:Set(b)
        view.Width:Set(r - mid - 2)
        view.Height:Set(b - t)
        view.Depth:Set(function() return main.Depth() end)
        state.head2 = view
        local okFrom, from = pcall(GetCamera, 'CameraHead2')
        local okTo, to = pcall(GetCamera, HEAD2)
        if okFrom and from and okTo and to then
            local okSave, saved = pcall(from.SaveSettings, from)
            if okSave and type(saved) == 'table' then
                pcall(to.RestoreSettings, to, saved)
            end
        end
    end)
    if not ok then
        LOG('TeamMouse: could not split the second monitor: ' .. tostring(err))
    end
    pcall(env.viewsChanged)
end

--- Back to CameraHead2 alone.
local function CloseHead2()
    local view, rect = state.head2, state.head2Rect
    state.head2, state.head2Rect = false, false
    state.before[HEAD2] = nil
    if view then
        pcall(view.Destroy, view)
    end
    local main = Views()['CameraHead2']
    if main and rect then
        pcall(function()
            main.Right:Set(rect[3])
            main.Width:Set(rect[3] - rect[1])
        end)
    end
    pcall(env.viewsChanged)
end

--- Two followed with a second monitor (Follow.SplitSecondMonitor): that
--- monitor is halved for them, not the main one.
---@return boolean
local function HeadSplit()
    local cfg = Config.Follow
    return (cfg.SecondMonitor and cfg.SplitSecondMonitor and Views()['CameraHead2']) and true or false
end

--- Views for whoever we follow: two on the second monitor halved (ours,
--- HeadSplit), or the splitscreen's two sides; one on the main view with
--- Follow.AutoSplit, the splitscreen. Opened if not open, and closed again
--- when no longer wanted, if we opened it.
local function AssignViews()
    local n = table.getn(state.follows)
    local head = HeadSplit()
    if n >= 2 and head then
        OpenHead2()
    elseif state.head2 then
        CloseHead2()
    end
    local primary = (n >= 2 and not head)
        or (n == 1 and (Config.Follow.AutoSplit or state.splitOne) and DefaultView() ~= 'CameraHead2')
    if primary and not Views()['WorldCamera2'] then
        -- The game keeps the main view's camera, but the new right side
        -- starts at the whole map: it starts where we were looking instead
        -- (reported: our own side was reset to the map view).
        local was = CameraSettings('WorldCamera')
        SetSplit(true)
        state.openedSplit = Views()['WorldCamera2'] and true or false
        if state.openedSplit and was then
            SetCamera('WorldCamera2', was)
        end
    elseif not primary and state.openedSplit then
        -- Closing: the main view carries on from our own side (where we
        -- were looking meanwhile), not from the followed one.
        local own = state.splitOwn == 'WorldCamera2' and CameraSettings('WorldCamera2')
        state.openedSplit, state.splitOwn = false, false
        SetSplit(false)
        if own then
            SetCamera('WorldCamera', own)
            state.before['WorldCamera'] = nil
        end
    end
    -- Which side is ours while one is followed in a splitscreen we opened.
    if state.openedSplit and n == 1 then
        state.splitOwn = FollowView(state.follows[1]) == 'WorldCamera' and 'WorldCamera2' or 'WorldCamera'
    elseif n >= 2 then
        state.splitOwn = false
    end
end

--- `record` is followed no more.
---@param record table
local function Unfollow(record)
    for i, r in ipairs(state.follows) do
        if r == record then
            table.remove(state.follows, i)
            break
        end
    end
    SayUnfollow(record)
    record.follow = false
    record.followCam = nil
    record.panelSeen = nil
end

--- Views that no longer show anyone we follow: put back as they were
--- before (`restore`, an unclick), or just forgotten (a hard scroll: the
--- camera stays where it was taken).
---@param restore boolean
local function ReleaseViews(restore)
    local shown = {}
    for _, r in ipairs(state.follows) do
        local key = FollowView(r)
        if key then
            shown[key] = true
        end
    end
    for key, saved in pairs(state.before) do
        if not shown[key] then
            state.before[key] = nil
            if restore and Views()[key] then
                local ok, camera = pcall(GetCamera, key)
                if ok and camera then
                    pcall(camera.RestoreSettings, camera, saved)
                end
            end
        end
    end
end

--- After a change to who we follow: the views, the focus, the panel.
local function Followed()
    if not state.follows[1] then
        state.splitOne = false
    end
    local was = state.following
    state.following = not env.replay and state.follows[1] or false
    if state.following and state.following ~= was and state.following.panelSeen then
        pcall(env.panelOverlay, state.following.panelSeen, state.following.army)
    end
    AssignViews()
    SayViewing()
    SyncFocus()
    pcall(env.panelSync)
end

--- Following stopped from elsewhere (a hard scroll on its view): that
--- camera stays where it is; anyone else followed carries on.
---@param record? table
function FollowStopped(record)
    if state.stroke then
        EndStroke()
    end
    if record then
        Unfollow(record)
    end
    Followed()
    ReleaseViews(false)
end

--- A player's name was clicked in the panel: follow their view, or stop
--- (and put the view back where it was looking before). `add` (Shift, a
--- live observer): follow them as well as whoever we follow already, two at
--- most, side by side in the splitscreen (the earlier of two makes room).
--- `split` (Ctrl): in the splitscreen, opened for it, the other side ours --
--- Follow.AutoSplit for this one follow.
---@param record table
---@param add? boolean
---@param split? boolean
function ToggleFollow(record, add, split)
    if not env or not Config.Follow.Enabled then
        return
    end
    -- (Two at once: live, players and observers alike.)
    add = add and not env.replay and Live()
    if state.stroke then
        EndStroke()
    end
    if record.follow then
        Unfollow(record)
    else
        if not add then
            -- (The views keep the cameras to go back to: from before the first.)
            while state.follows[1] do
                Unfollow(state.follows[1])
            end
            state.splitOne = split and true or false
        elseif table.getn(state.follows) >= 2 then
            Unfollow(state.follows[1])
        end
        table.insert(state.follows, record)
        record.follow = true
        record.followCam = nil
        if not env.replay then
            state.followSaidT = GetSystemTimeSeconds()
            if Live() then
                Send(IndexOf(record), { tmf = 1, ta = record.army })
            end
            -- An observer coaches whoever they follow (Coach.CoachFollowed).
            if env.observer and Live() and Config.Coach.CoachFollowed and not state.coached[record] then
                SetCoach(record, true)
            end
        end
    end
    Followed()
    ReleaseViews(true)
end

--- The panel's "coach" box (live observers): on or off for one player, the
--- others as they are.
---@param record table
---@param on boolean
function SetCoach(record, on)
    if not env or not env.observer or env.replay then
        return
    end
    on = on and true or false
    if (state.coached[record] or false) == on then
        return
    end
    -- (An ink stroke goes to whoever was coached when it began.)
    if state.stroke and state.stroke.kind == 'ink' then
        EndStroke()
    end
    if on then
        state.coached[record] = true
        record.coached = true
        state.coaching = record
        state.coachSel = -1
        Send(IndexOf(record), { tmh = 1, tv = state.following and 1 or 0 })
    else
        state.coached[record] = nil
        record.coached = false
        Send(IndexOf(record), { tmh = 0 })
        if state.coaching == record then
            state.coaching = next(state.coached) or false
            state.coachSel = -1
        end
    end
    pcall(env.setCoachTarget, CoachIndices())
    SyncFocus()
    pcall(env.panelSync)
end

--- Our panel changed: whoever follows us sees it (Panel hooks.changed).
function PanelChanged()
    if not env or not Live() or not next(state.followers) then
        return
    end
    local ok, panel = pcall(env.panelState)
    if not ok or type(panel) ~= 'string' then
        return
    end
    for index in pairs(state.followers) do
        Send(index, { tmp = panel })
    end
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
    -- (The prefix of their strokes' keys, made once.)
    local prefix = record.lensPrefix
    if not prefix then
        prefix = tostring(record.name) .. '/'
        record.lensPrefix = prefix
    end
    local plen = string.len(prefix)
    if Config.Coach.AlwaysShowCursor or record.buildId or (record.renderDrag or 0) ~= 0 then
        return true
    end
    for _, pulse in pairs(record.pulses or {}) do
        if pulse.t and now >= pulse.t - 0.2 and now - pulse.t <= 0.3 then
            return true
        end
    end
    for i = 1, draw.nlens do
        local s = draw.lens[i]
        if not s.endT and string.sub(s.key, 1, plen) == prefix then
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
    if draw.nlens > 0 then
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
    if Live() and now - state.followSaidT >= 2 then
        for _, f in ipairs(state.follows) do
            if not f.cam then
                state.followSaidT = now
                Send(IndexOf(f), { tmf = 1, ta = f.army })
            end
        end
    end

    -- A coach following us: their cursor (record.coachFade, used by the
    -- frame driver) up while they do something, fading out after.
    for name in pairs(state.coaches) do
        local record = env.peers[name]
        -- (Following us, or anyone: tv.)
        if record and (record.followsMe or record.coachViewing) then
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
    -- A live observer kept to one team by the lobby: their focus cannot
    -- leave it (observerteam.lua).
    if env.observer and not env.replay then
        ObserverTeam.Install()
    end
end

function Destroy()
    ObserverTeam.Uninstall()
    if env and Live() then
        for _, r in ipairs(state.follows) do
            SayUnfollow(r)
        end
        for record in pairs(state.coached) do
            Send(IndexOf(record), { tmh = 0 })
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
    draw.ink, draw.nink = {}, 0
    draw.shape, draw.shaped = false, {}
    state.focusArmy, state.selFrom = -1, false
    if state.openedSplit then
        SetSplit(false)
    end
    if state.head2 then
        CloseHead2()
    end
    for _, r in ipairs(state.follows) do
        r.follow, r.followCam = false, nil
    end
    state.follows, state.following, state.before, state.openedSplit = {}, false, {}, false
    state.splitOne, state.splitOwn = false, false
    for record in pairs(state.coached) do
        record.coached = false
    end
    state.coached, state.coaching, state.coachSel = {}, false, -1
    state.followers, state.followTeam = {}, 0
    state.coaches = {}
    state.stroke = false
    env = false
end

--- For the tests.
function Get()
    return state, draw
end
