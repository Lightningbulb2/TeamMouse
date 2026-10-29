--******************************************************************************
--** TeamMouse -- modules/panel.lua
--**
--** A small panel listing the players whose cursors you can see, each with
--** FAF's standard checkbox: untick it to hide that player's cursor (and
--** everything drawn for them -- orders, lines, trails), tick it to bring it
--** back. Collapses to
--** its tab with FAF's own collapse arrow, like the score panel, and hides
--** itself along with the rest of the interface in screen capture mode.
--**
--** Built at the start of the game. In a replay, a player only gets a row
--** once their recorded cursor data has actually turned up (the panel is rebuilt
--** then), so players without the mod, or without recording on, are not listed.
--** The title, "TeamMouse - v4", is underlined: hovering it lists everyone's
--** version of TeamMouse (version.lua), as Sim Speed Balancer's panel does.
--** Click a player's name to follow their view (coach.lua); click it again to
--** stop (hovering a name lights its band first). Live observers also get a
--** "coach" box per player (any number). Observers are listed under their
--** own heading, "observers - Team: any" (or the team the lobby keeps them to:
--** observerteam.lua), with no "view" box, and cannot be followed (a player
--** sees an observer's cursor while they coach). A teammate whose army is out
--** of the game has a red line through their name, and their cursor shows only
--** with "show dead cursors" ticked (Panel.ShowDead starts it). In a replay
--** there is no such box (nothing of theirs is recorded once their commander
--** is dead): a dead player's boxes are unticked and locked. Following
--** someone, their own panel's ticks are drawn as green outlines round your
--** boxes (not "all"), and their box for you round theirs (SetOverlay).
--** Choices last for the game only.
--**
--** While TeamMouse's options window is open (optionswindow.lua -> SetEditing)
--** the panel shows even with nobody to list (a solo game), and its tab can be
--** dragged to anywhere along the left, right or top edge of the screen (FAF's
--** collapse tabs come in those three). Where it is put is kept in the game's
--** profile; "Reset position" under it puts it back where config.lua says.
--******************************************************************************

local Config = import(_G.TeamMousePath .. '/modules/config.lua')
local CursorData = import(_G.TeamMousePath .. '/modules/cursordata.lua')
local Version = import(_G.TeamMousePath .. '/modules/version.lua')
local ObserverTeam = import(_G.TeamMousePath .. '/modules/observerteam.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local UIUtil = import('/lua/ui/uiutil.lua')
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Group = import('/lua/maui/group.lua').Group

local ROW_HEIGHT = 22
local CHECK = 18
local WIDTH = 160
local PAD = 6
local SWATCH = 10
local TITLE_HEIGHT = 16
local OFF_COLOR = 'ff3a3a3a'
--- Colours (one table: Build is near Lua 5.0's 32 upvalues). follow, followBack:
--- a followed player's name and the band behind it. dead: the line through a
--- dead teammate's name. overlay: the outline round a box the player we follow
--- has ticked in their own panel. title, titleOther: the title, and the same
--- while someone is on another version.
local COLORS = {
    follow = 'ffffd24a', followBack = 'ff6b5200', dead = 'ffe02020', overlay = 'ff3cd23c',
    title = 'ffaaaaaa', titleOther = 'ffff9933',
}

local panel = false

--- What the panel is built from, kept so it can be rebuilt: the records, the
--- toggle callback, the coaching hooks, and whether only players whose data
--- has arrived are listed (replays).
local source = false

--- Folded or not, carried across a rebuild (nil: Panel.StartCollapsed).
local collapsedPref = nil

--- editing: TeamMouse's options window is open (SetEditing). place: false
--- for config.lua's spot (Panel.X / Panel.Y), or { edge, along }: the edge
--- ('l', 'r' or 't') and how far along it, 0..1 of the room there is.
--- loaded: place has been read from the profile.
local layout = { editing = false, place = false, loaded = false }

--- The panel of the player we follow, as they sent it (coach.lua): army ->
--- { c = cursor ticked, v = view ticked }; dead = their "show dead cursors";
--- me = our army as they list us. False: nobody's.
local overlay = false

local PREF_KEY = 'TeamMousePanelPlace'
local HINT_COLOR = 'ffffd24a'

--- Whether the game's interface is hidden (screen capture mode).
---@return boolean
local function UIHidden()
    local ok, GameMain = pcall(import, '/lua/ui/game/gamemain.lua')
    return ok and type(GameMain) == 'table' and GameMain.gameUIHidden and true or false
end

--- Play one of the interface's own sounds, if there is sound.
---@param cue string
local function Play(cue)
    pcall(function() PlaySound(Sound({ Cue = cue, Bank = 'Interface' })) end)
end

local Ring

--- Show or hide the outline `holder[key]` round `box`, made the first time
--- it shows (most never do: only while following someone).
---@param holder table   # a row, or the panel; its `parent` is what to make it in
---@param key string
---@param box Control
---@param on any
local function SetRing(holder, key, box, on)
    local ring = holder[key]
    if not ring then
        if not on then
            return
        end
        ring = Ring(holder.parent, box)
        holder[key] = ring
    end
    ring:SetAlpha(on and 1 or 0)
end

--- Show a row as on or off.
---@param row table
local function Paint(row)
    local record = row.record
    local on = not record.disabled
    row.swatch:SetSolidColor(on and row.color or OFF_COLOR)
    row.label:SetAlpha(on and 1 or 0.4)
    row.label:SetColor(record.follow and COLORS.follow or 'ffffffff')
    -- Through its alpha, not Hide: showing the panel shows every child.
    row.highlight:SetAlpha((record.follow and 0.9) or (row.hover and 0.45) or 0)
    row.strike:SetAlpha(record.dead and Config.Panel.StrikeAlpha or 0)
    -- (The player we follow has no row for themselves: theirs stands in for
    -- their box for us.)
    local theirs = overlay and overlay[record.follow and overlay.me or record.army]
    SetRing(row, 'checkRing', row.check, theirs and theirs.c)
    if row.viewCheck then
        SetRing(row, 'viewRing', row.viewCheck, theirs and theirs.v)
    end
    if row.check.IsChecked and row.check:IsChecked() ~= on then
        row.check:SetCheck(on, true)
    end
end

---@param collapsed boolean
local function SetCollapsed(collapsed)
    if not panel then
        return
    end
    panel.collapsed = collapsed
    collapsedPref = collapsed
    if collapsed then
        panel.body:Hide()
    else
        panel.body:Show()
    end
end

--- The players to list right now.
---@return table[]
local function Listed()
    if not source.onlyHeard then
        return source.records
    end
    local out = {}
    for _, record in ipairs(source.records) do
        if record.hasData then
            table.insert(out, record)
        end
    end
    return out
end

--- Take the controls down, keeping what the panel is built from.
local function DestroyControls()
    if panel then
        pcall(function() panel.root:Destroy() end)
        panel = false
    end
end

local Build

--- A name cut short with "..." so it fits in `room` (unscaled) beside its
--- label, never splitting a UTF-8 character. Whole if it fits, or if the
--- label cannot measure text.
---@param label Text
---@param name string
---@param room number
---@return string
local function FitName(label, name, room)
    if not label.GetStringAdvance then
        return name
    end
    room = LayoutHelpers.ScaleNumber and LayoutHelpers.ScaleNumber(room) or room
    if label:GetStringAdvance(name) <= room then
        return name
    end
    local n = string.len(name)
    while n > 1 do
        n = n - 1
        -- Not in the middle of a character: the next byte starts one.
        local nextByte = string.byte(name, n + 1)
        if not (nextByte >= 128 and nextByte < 192)
            and label:GetStringAdvance(string.sub(name, 1, n) .. '...') <= room then
            break
        end
    end
    return string.sub(name, 1, n) .. '...'
end

--- A green outline round `box`: four thin lines just outside it, over the
--- panel (a ring behind the box was under the panel's own background).
--- Shown through SetAlpha: the player we follow has that box ticked.
---@param parent Control
---@param box Control
---@return table   # SetAlpha(a), GetAlpha()
Ring = function(parent, box)
    local lines = {}
    for i = 1, 4 do
        local line = Bitmap(parent)
        line:SetSolidColor(COLORS.overlay)
        line:DisableHitTest()
        line.Depth:Set(function() return box.Depth() + 2 end)
        line:SetAlpha(0)
        lines[i] = line
    end
    local top, bottom, left, right = lines[1], lines[2], lines[3], lines[4]
    for _, line in ipairs({ top, bottom }) do
        line.Left:Set(function() return box.Left() - 2 end)
        line.Width:Set(function() return box.Width() + 4 end)
        line.Height:Set(2)
    end
    top.Top:Set(function() return box.Top() - 2 end)
    bottom.Top:Set(function() return box.Top() + box.Height() end)
    for _, line in ipairs({ left, right }) do
        line.Top:Set(function() return box.Top() end)
        line.Height:Set(function() return box.Height() end)
        line.Width:Set(2)
    end
    left.Left:Set(function() return box.Left() - 2 end)
    right.Left:Set(function() return box.Left() + box.Width() end)
    local ring = { alpha = 0 }
    function ring:SetAlpha(alpha)
        if alpha ~= self.alpha then
            self.alpha = alpha
            for _, line in ipairs(lines) do
                line:SetAlpha(alpha)
            end
        end
    end
    function ring:GetAlpha()
        return self.alpha
    end
    return ring
end

--- Our own name, as the session knows it.
---@return string | nil
local function MyName()
    local ok, clients = pcall(GetSessionClients)
    for _, client in ipairs(ok and clients or {}) do
        if client['local'] then
            return client.name
        end
    end
end

--- Every listed player's (and observer's) TeamMouse version, one a line,
--- ours first: the title's tooltip.
---@return string
function VersionList()
    local lines = {}
    -- (Not in a replay -- the panel lists only players heard there -- the
    -- viewer is nobody, whatever their name.)
    local me = not (source and source.onlyHeard) and MyName()
    if me then
        table.insert(lines, me .. ': v' .. Config.ModVersion .. ' (you)')
    end
    for _, record in ipairs(source and source.records or {}) do
        local text = Version.Describe(record.name)
        table.insert(lines, tostring(record.name) .. ': ' .. text)
    end
    return table.concat(lines, '\n')
end

--- Whether anyone listed is on another version than ours (the title goes orange).
---@return boolean
local function VersionsDiffer()
    for _, record in ipairs(source and source.records or {}) do
        if Version.Differs(record.name) then
            return true
        end
    end
    return false
end

--- The edge the panel is on.
---@return 'l' | 'r' | 't'
local function Edge()
    return layout.place and layout.place.edge or 'l'
end

--- The saved spot, read from the profile once.
local function LoadPlace()
    if layout.loaded then
        return
    end
    layout.loaded = true
    pcall(function()
        local saved = import('/lua/user/prefs.lua').GetFromCurrentProfile(PREF_KEY)
        if type(saved) == 'table' and (saved.edge == 'l' or saved.edge == 'r' or saved.edge == 't')
            and type(saved.along) == 'number' and saved.along == saved.along then
            layout.place = { edge = saved.edge, along = math.max(0, math.min(1, saved.along)) }
        end
    end)
end

--- Keep the spot in the profile (none: config.lua's).
local function SavePlace()
    pcall(function()
        local place = layout.place
        import('/lua/user/prefs.lua').SetToCurrentProfile(PREF_KEY,
            place and { edge = place.edge, along = place.along } or nil)
        SavePreferences()
    end)
end

--- Put the panel's root where layout.place says.
---@param root Group
local function Place(root)
    local frame = GetFrame(0)
    local place = layout.place
    if not place then
        local cfg = Config.Panel
        root.Left:Set(function() return frame.Left() + frame.Width() * cfg.X end)
        root.Top:Set(function() return frame.Top() + frame.Height() * cfg.Y end)
        return
    end
    local along = place.along
    if place.edge == 't' then
        root.Left:Set(function() return frame.Left() + (frame.Width() - root.Width()) * along end)
        root.Top:Set(function() return frame.Top() end)
        return
    end
    if place.edge == 'r' then
        root.Left:Set(function() return frame.Left() + frame.Width() - root.Width() end)
    else
        root.Left:Set(function() return frame.Left() end)
    end
    root.Top:Set(function() return frame.Top() + (frame.Height() - root.Height()) * along end)
end

--- Show or take down the tooltip on the tab while it can be dragged.
---@param control? Control
---@param tip? table   # { text, body }; none: the tab's
local function Tip(control, tip)
    pcall(function()
        local Tooltip = import('/lua/ui/game/tooltip.lua')
        if control then
            Tooltip.CreateMouseoverDisplay(control, tip or { text = 'Move the panel',
                body = 'Drag this tab along the left, right or top edge of the screen. Click it to fold the panel.' },
                0.3, true)
        else
            Tooltip.DestroyMouseoverDisplay()
        end
    end)
end

--- A player's name on their row, cut to fit `room`; when it is cut, hovering
--- it shows the whole name. With `onClick`, a left click on it -- or on the
--- band behind it -- calls onClick() (following them), and hovering lights
--- the band and says so.
---@param label Text
---@param name string
---@param room number
---@param onClick? function
---@param row? table
local function ShowName(label, name, room, onClick, row)
    local shown = FitName(label, name, room)
    label:SetText(shown)
    if shown == name and not onClick then
        label:DisableHitTest()
        return
    end
    local tip = { text = name }
    if onClick then
        tip.body = 'Click to follow their view. Click again to go back to where you were looking;'
            .. ' scrolling hard also breaks free.'
    end
    local function Hover(on)
        if onClick and row then
            row.hover = on
            Paint(row)
        end
    end
    label.HandleEvent = function(self, event)
        local t = event.Type
        if t == 'MouseEnter' then
            Tip(self, tip)
            Hover(true)
        elseif t == 'MouseExit' then
            Tip()
            Hover(false)
        elseif onClick and (t == 'ButtonPress' or t == 'ButtonDClick')
            and not (event.Modifiers and event.Modifiers.Right) then
            Play('UI_Menu_MouseDown_Sml')
            onClick()
            return true
        end
        return false
    end
    if onClick and row then
        row.highlight:EnableHitTest()
        row.highlight.HandleEvent = label.HandleEvent
    end
end

--- A small solid triangle pointing 'u', 'd', 'l' or 'r', from lines of
--- bitmaps (no texture to go missing).
---@param parent Control
---@param dir string
---@return Group
local function Triangle(parent, dir)
    local tri = Group(parent)
    if dir == 'u' or dir == 'd' then
        LayoutHelpers.SetDimensions(tri, 7, 4)
    else
        LayoutHelpers.SetDimensions(tri, 4, 7)
    end
    tri:DisableHitTest()
    for i = 0, 3 do
        local line = Bitmap(tri)
        line:SetSolidColor(HINT_COLOR)
        line:DisableHitTest()
        if dir == 'u' or dir == 'd' then
            LayoutHelpers.AtLeftTopIn(line, tri, 3 - i, dir == 'u' and i or 3 - i)
            LayoutHelpers.SetDimensions(line, 2 * i + 1, 1)
        else
            LayoutHelpers.AtLeftTopIn(line, tri, dir == 'l' and i or 3 - i, 3 - i)
            LayoutHelpers.SetDimensions(line, 1, 2 * i + 1)
        end
    end
    return tri
end

--- Little arrows either side of the tab, the ways it can be dragged.
---@param root Group
---@param arrow Control
---@param edge string
---@return Group[]
local function DragHints(root, arrow, edge)
    local function Hang(tri, left, top)
        tri.Left:Set(left)
        tri.Top:Set(top)
        tri.Depth:Set(function() return arrow.Depth() + 1 end)
        return tri
    end
    if edge == 't' then
        local a, b = Triangle(root, 'l'), Triangle(root, 'r')
        local function Middle(tri)
            return function() return arrow.Top() + (arrow.Height() - tri.Height()) / 2 end
        end
        return {
            Hang(a, function() return arrow.Left() - a.Width() - 2 end, Middle(a)),
            Hang(b, function() return arrow.Left() + arrow.Width() + 2 end, Middle(b)),
        }
    end
    local a, b = Triangle(root, 'u'), Triangle(root, 'd')
    local function Centre(tri)
        return function() return arrow.Left() + (arrow.Width() - tri.Width()) / 2 end
    end
    return {
        Hang(a, Centre(a), function() return arrow.Top() - a.Height() - 2 end),
        Hang(b, Centre(b), function() return arrow.Top() + arrow.Height() + 2 end),
    }
end

--- A small "Reset position" button under the panel (over it, if there is no
--- room under it), while the options window is open. Folds away with it.
---@param body Group
---@param edge string
---@return Bitmap
local function ResetButton(body, edge)
    local frame = GetFrame(0)
    local back = Bitmap(body)
    back:SetSolidColor(Config.Panel.BackColor)
    LayoutHelpers.SetDimensions(back, 96, 18)
    if edge == 'r' then
        back.Left:Set(function() return body.Left() + body.Width() - back.Width() end)
    elseif edge == 't' then
        back.Left:Set(function() return body.Left() + (body.Width() - back.Width()) / 2 end)
    else
        back.Left:Set(function() return body.Left() end)
    end
    back.Top:Set(function()
        local below = body.Top() + body.Height() + 2
        if below + back.Height() > frame.Top() + frame.Height() then
            return body.Top() - back.Height() - 2
        end
        return below
    end)

    local text = UIUtil.CreateText(back, 'Reset position', 10, UIUtil.bodyFont, true)
    text:SetColor('ffaaaaaa')
    text:DisableHitTest()
    text.Left:Set(function() return back.Left() + (back.Width() - text.Width()) / 2 end)
    text.Top:Set(function() return back.Top() + (back.Height() - text.Height()) / 2 end)

    back.HandleEvent = function(self, event)
        if event.Type == 'MouseEnter' then
            text:SetColor('ffffffff')
        elseif event.Type == 'MouseExit' then
            text:SetColor('ffaaaaaa')
        elseif event.Type == 'ButtonPress' then
            Play('UI_Menu_MouseDown_Sml')
            ResetPlace()
            return true
        end
        return false
    end
    return back
end

--- How far v is through room, 0..1.
---@param v number
---@param room number
---@return number
local function Fraction(v, room)
    if room <= 0 then
        return 0
    end
    return math.max(0, math.min(1, v / room))
end

--- The tab dragged to (x, y): onto the nearest of the three edges, with the
--- tab under the pointer. A new edge needs a new tab: rebuilt.
---@param x number
---@param y number
function DragTo(x, y)
    local frame = GetFrame(0)
    if not panel or not frame then
        return
    end
    local fl, ft, fw, fh = frame.Left(), frame.Top(), frame.Width(), frame.Height()
    local edge, nearest = 'l', x - fl
    if fl + fw - x < nearest then
        edge, nearest = 'r', fl + fw - x
    end
    if y - ft < nearest then
        edge = 't'
    end
    local w, h = panel.root.Width(), panel.root.Height()
    local along
    if edge == 't' then
        along = Fraction(x - fl - w / 2, fw - w)
    else
        along = Fraction(y - ft - h / 2, fh - h)
    end
    local was = Edge()
    layout.place = { edge = edge, along = along }
    if edge ~= was then
        Build()
    else
        Place(panel.root)
    end
end

--- A press on the tab while the options window is open: a drag moves the
--- panel, a click without moving folds or opens it as usual.
---@param event table
---@return boolean   # whether a drag was started
local function StartDrag(event)
    local ok, DraggerModule = pcall(import, '/lua/maui/dragger.lua')
    local post = rawget(_G, 'PostDragger')
    if not ok or type(DraggerModule) ~= 'table' or not DraggerModule.Dragger or not post then
        return false
    end
    local drag = DraggerModule.Dragger()
    local startX, startY = event.MouseX or 0, event.MouseY or 0
    local moved = false
    drag.OnMove = function(self, x, y)
        if not moved and math.abs(x - startX) + math.abs(y - startY) < 4 then
            return
        end
        moved = true
        DragTo(x, y)
    end
    drag.OnRelease = function(self, x, y)
        if moved then
            SavePlace()
        elseif panel and panel.arrow then
            panel.arrow:SetCheck(not panel.collapsed)
        end
        if self.Destroy then self:Destroy() end
    end
    drag.OnCancel = function(self)
        if moved then
            SavePlace()
        end
        if self.Destroy then self:Destroy() end
    end
    post(GetFrame(0), event.KeyCode, drag)
    return true
end

--- The tab: just past the screen's edge as FAF puts its own, folds the panel,
--- and while the options window is open drags it (with arrows to say so).
---@param root Group
---@param arrow Checkbox
---@param edge string
---@param height number
local function SetUpTab(root, arrow, edge, height)
    if edge == 't' then
        arrow.Left:Set(function() return root.Left() + (root.Width() - arrow.Width()) / 2 end)
        arrow.Top:Set(function() return root.Top() - 3 end)
    else
        LayoutHelpers.AtLeftTopIn(arrow, root, -3, (height - 24) / 2)
        if edge == 'r' then
            arrow.Left:Set(function() return root.Left() + root.Width() - arrow.Width() + 3 end)
        end
    end
    arrow.Depth:Set(function() return root.Depth() + 10 end)
    arrow.OnCheck = function(self, checked)
        SetCollapsed(checked)
        Play(checked and 'UI_Score_Window_Close' or 'UI_Score_Window_Open')
    end
    local handle = arrow.HandleEvent
    arrow.HandleEvent = function(self, event)
        if layout.editing then
            local t = event.Type
            if (t == 'ButtonPress' or t == 'ButtonDClick')
                and not (event.Modifiers and event.Modifiers.Right) and StartDrag(event) then
                return true
            elseif t == 'MouseEnter' then
                Tip(self)
            elseif t == 'MouseExit' then
                Tip()
            end
        end
        if handle then
            return handle(self, event)
        end
        return false
    end
    panel.arrow = arrow
    if layout.editing then
        panel.hints = DragHints(root, arrow, edge)
    end
end

--- The title, "TeamMouse - v4", underlined: hovering it lists everyone's
--- version (VersionList).
---@param body Group
---@param inner Group
---@return Text, Bitmap
local function Title(body, inner)
    local title = UIUtil.CreateText(body, 'TeamMouse - v' .. Config.ModVersion, 10, UIUtil.bodyFont, true)
    title:SetText('TeamMouse - v' .. Config.ModVersion)
    title:SetColor(COLORS.title)
    LayoutHelpers.AtLeftTopIn(title, inner, PAD + 14, PAD - 2)
    title.HandleEvent = function(self, event)
        if event.Type == 'MouseEnter' then
            Tip(self, { text = 'TeamMouse versions', body = VersionList() })
        elseif event.Type == 'MouseExit' then
            Tip()
        end
        return false
    end
    local underline = Bitmap(body)
    underline:SetSolidColor(COLORS.title)
    underline:DisableHitTest()
    underline.Left:Set(function() return title.Left() end)
    -- (The text's box has room under the letters: up into it a little.)
    underline.Top:Set(function() return title.Top() + title.Height() - LayoutHelpers.ScaleNumber(2) end)
    underline.Width:Set(function() return title.Width() end)
    underline.Height:Set(function() return math.max(1, math.floor(LayoutHelpers.ScaleNumber(1))) end)
    return title, underline
end

--- "show dead cursors" (whether a dead teammate's cursor shows at all;
--- Panel.ShowDead starts it), under the rows at `top`. Not in a replay.
---@param body Group
---@param inner Group
---@param top number
local function DeadRow(body, inner, top)
    local deadCheck = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
    LayoutHelpers.AtLeftTopIn(deadCheck, inner, PAD + 14, top + (ROW_HEIGHT - CHECK) / 2)
    LayoutHelpers.SetDimensions(deadCheck, CHECK, CHECK)
    deadCheck:SetCheck(Config.Panel.ShowDead and true or false, true)
    deadCheck.OnCheck = function(self, checked)
        Config.Panel.ShowDead = checked and true or false
        Changed()
    end
    local deadLabel = UIUtil.CreateText(body, 'show dead cursors', 10, UIUtil.bodyFont, true)
    deadLabel:SetColor('ffaaaaaa')
    deadLabel:DisableHitTest()
    LayoutHelpers.AtLeftTopIn(deadLabel, inner, PAD + 14 + CHECK + 5, top + 4)
    panel.deadCheck = deadCheck
end

--- One row: a player's (or an observer's) boxes, colour and name. `ctx` is
--- what Build laid out: body, inner, hooks, onToggle, width, nameLeft,
--- nameRight, nameRoom, coachColumn, syncAll.
---@param ctx table
---@param record table
---@param top number
---@return table
local function MakeRow(ctx, record, top)
    local body, inner, hooks = ctx.body, ctx.inner, ctx.hooks
    local mid = top + (ROW_HEIGHT - CHECK) / 2

    -- FAF's own checkbox, as its panels use (multifunction.lua): it does
    -- its own clicks, hover and sound. Ticked = shown.
    local check = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
    LayoutHelpers.AtLeftTopIn(check, inner, PAD + 14, mid)
    LayoutHelpers.SetDimensions(check, CHECK, CHECK)

    local swatch = Bitmap(body)
    LayoutHelpers.AtLeftTopIn(swatch, inner, PAD + 14 + CHECK + 5, top + (ROW_HEIGHT - SWATCH) / 2)
    LayoutHelpers.SetDimensions(swatch, SWATCH, SWATCH)
    swatch:DisableHitTest()

    -- Behind the name while we follow them, or hover it (made first: drawn
    -- under it). Right of their colour square, which stays in sight.
    local highlight = Bitmap(body)
    highlight:SetSolidColor(COLORS.followBack)
    highlight:SetAlpha(0)
    highlight:DisableHitTest()
    LayoutHelpers.AtLeftTopIn(highlight, inner, ctx.nameLeft - 3, top + 1)
    LayoutHelpers.SetDimensions(highlight, ctx.nameRight - ctx.nameLeft + 3, ROW_HEIGHT - 2)

    local label = UIUtil.CreateText(body, record.name or '?', 12, UIUtil.bodyFont, true)
    label:SetColor('ffffffff')
    local row = { record = record, check = check, swatch = swatch, label = label, highlight = highlight,
        color = CursorData.SafeUIColor(record.color), parent = body }
    local onClick = nil
    -- (An observer has no camera to follow.)
    if hooks.follow and Config.Follow.Enabled and not record.observer then
        onClick = function()
            hooks.follow(record)
            SyncFollow()
        end
    end
    ShowName(label, record.name or '?', ctx.nameRoom, onClick, row)
    LayoutHelpers.AtLeftTopIn(label, inner, ctx.nameLeft, top + 3)

    -- A red line through a dead teammate's name (Paint shows it).
    local strike = Bitmap(body)
    strike:SetSolidColor(COLORS.dead)
    strike:DisableHitTest()
    strike.Left:Set(function() return label.Left() - 1 end)
    strike.Top:Set(function() return label.Top() + math.floor(label.Height() / 2) end)
    strike.Width:Set(function() return label.Width() + 2 end)
    strike.Height:Set(2)
    strike.Depth:Set(function() return label.Depth() + 1 end)
    strike:SetAlpha(0)
    row.strike = strike

    -- (An observer has no view to outline, and is not coached.)
    if not record.observer then
        -- Their view's outline on the map (Viewport): off unless ticked, and
        -- not remembered between games.
        local viewCheck = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
        LayoutHelpers.AtLeftTopIn(viewCheck, inner, ctx.width - PAD - CHECK, mid)
        LayoutHelpers.SetDimensions(viewCheck, CHECK, CHECK)
        viewCheck:SetCheck(record.showView and true or false, true)
        viewCheck.OnCheck = function(self, checked)
            record.showView = checked and true or false
            ctx.syncAll()
            Changed()
        end
        if record.locked then
            viewCheck:Disable()
        end
        row.viewCheck = viewCheck

        -- A live observer: coach this player (coach.lua), as many as they
        -- like.
        if ctx.coachColumn then
            local coachCheck = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
            LayoutHelpers.AtLeftTopIn(coachCheck, inner, ctx.width - PAD - CHECK * 2 - 12, mid)
            LayoutHelpers.SetDimensions(coachCheck, CHECK, CHECK)
            coachCheck:SetCheck(record.coached and true or false, true)
            coachCheck.OnCheck = function(self, checked)
                hooks.coach(record, checked and true or false)
                SyncFollow()
            end
            row.coachCheck = coachCheck
        end
    end

    check:SetCheck(not record.disabled, true)
    -- (Dead in a replay: unticked, for good. UpdateDead.)
    if record.locked then
        check:Disable()
    end
    check.OnCheck = function(self, checked)
        record.disabled = not checked
        Paint(row)
        if ctx.onToggle then
            pcall(ctx.onToggle, record)
        end
        ctx.syncAll()
        Changed()
    end
    Paint(row)
    return row
end

--- Build the panel.
---@param records table[]   # the players, in the order to list them; each a peer record
---@param onToggle? function   # called with a record after its cursor is hidden or shown
---@param hooks? table          # coaching (coach.lua): follow(record) for a click on a
---                               name; coach(record, on) for a "coach" box per player
---                               (live observers); changed() when a box changes
---@param onlyHeard? boolean    # list a player only once their data has arrived (replays)
function Create(records, onToggle, hooks, onlyHeard)
    Destroy()
    source = { records = records, onToggle = onToggle, hooks = type(hooks) == 'table' and hooks or {},
        onlyHeard = onlyHeard and true or false }
    Build()
end

Build = function()
    DestroyControls()
    if not source then
        return
    end
    local records = Listed()
    local onToggle, hooks = source.onToggle, source.hooks
    -- Nobody to list (a solo game): none, unless the options window is open,
    -- so the panel can be seen and placed.
    if not Config.Panel.Enabled or (table.getn(records) == 0 and not layout.editing) then
        return
    end

    local frame = GetFrame(0)
    if not frame then
        return
    end
    LoadPlace()

    local cfg = Config.Panel
    local edge = Edge()
    -- What is drawn keeps clear of the tab: it is on the left, right or top.
    local shift = (edge == 'r' and -14) or (edge == 't' and -7) or 0
    -- A live observer: a second column of boxes, coach that player.
    local COACH = hooks.coach and Config.Coach.Enabled and 44 or 0
    local WIDTH = WIDTH + COACH
    -- Room for a name: up to the first column of boxes.
    local nameLeft = PAD + 14 + CHECK + 5 + SWATCH + 5
    local nameRight = (COACH > 0 and WIDTH - PAD - CHECK * 2 - 12) or (WIDTH - PAD - CHECK)
    -- The players, then the observers under their own heading -- which an
    -- observer kept to one team by the lobby sees too.
    local players, observers = {}, {}
    for _, record in ipairs(records) do
        table.insert(record.observer and observers or players, record)
    end
    local obsHeading = table.getn(observers) > 0 or (hooks.coach and ObserverTeam.Forced() and true or false)
    -- The title, a row of "all" boxes, a row per player (or one saying there
    -- is nobody), the observers, then "show dead cursors".
    local lines = math.max(table.getn(players), 1) + (obsHeading and table.getn(observers) + 1 or 0)
    -- ("show dead cursors" is not in a replay: nothing of a dead player's is
    -- recorded.)
    local deadRow = not source.onlyHeard
    local height = TITLE_HEIGHT + (lines + (deadRow and 2 or 1)) * ROW_HEIGHT + PAD * 2

    local root = Group(frame, 'TeamMousePanel')
    LayoutHelpers.SetDimensions(root, WIDTH, height)
    Place(root)
    root.Depth:Set(cfg.Depth)
    root:DisableHitTest()

    -- FAF's own tab, on the edge the panel is on (placed below, once the rows
    -- are in). Checked means collapsed, as for its panels.
    local okArrow, arrow = pcall(UIUtil.CreateCollapseArrow, root, edge)
    if not okArrow then
        arrow = false
    end

    -- Everything that collapses away. On the top edge, under the tab.
    local body = Group(root, 'TeamMousePanelBody')
    LayoutHelpers.AtLeftTopIn(body, root, 0, 0)
    LayoutHelpers.SetDimensions(body, WIDTH, height)
    body:DisableHitTest()
    if edge == 't' and arrow then
        body.Top:Set(function() return root.Top() + arrow.Height() - 6 end)
    end

    local back = Bitmap(body)
    back:SetSolidColor(cfg.BackColor)
    LayoutHelpers.AtLeftTopIn(back, body, 0, 0)
    LayoutHelpers.SetDimensions(back, WIDTH, height)
    back:DisableHitTest()

    -- What the rows are laid out in: the body, moved clear of the tab.
    local inner = Group(body)
    LayoutHelpers.AtLeftTopIn(inner, body, shift, 0)
    LayoutHelpers.SetDimensions(inner, WIDTH, height)
    inner:DisableHitTest()

    local title, underline = Title(body, inner)

    -- Over the right-hand column of boxes: their view's outline (Viewport).
    local viewHeader = UIUtil.CreateText(body, 'view', 9, UIUtil.bodyFont, true)
    viewHeader:SetColor('ffaaaaaa')
    viewHeader:DisableHitTest(true)
    LayoutHelpers.AtLeftTopIn(viewHeader, inner, WIDTH - PAD - CHECK - 4, PAD - 1)
    if COACH > 0 then
        local followHeader = UIUtil.CreateText(body, 'coach', 9, UIUtil.bodyFont, true)
        followHeader:SetColor('ffaaaaaa')
        followHeader:DisableHitTest(true)
        LayoutHelpers.AtLeftTopIn(followHeader, inner, WIDTH - PAD - CHECK * 2 - 18, PAD - 1)
    end

    panel = { root = root, body = body, rows = {}, collapsed = false, title = title, underline = underline,
        edge = edge, editing = layout.editing }

    if table.getn(players) == 0 then
        local none = UIUtil.CreateText(body, 'no other players', 12, UIUtil.bodyFont, true)
        none:SetColor('ff777777')
        none:DisableHitTest()
        LayoutHelpers.AtLeftTopIn(none, inner, PAD + 14 + CHECK + 5 + SWATCH + 5,
            PAD + TITLE_HEIGHT + ROW_HEIGHT + 3)
        panel.placeholder = none
    end

    -- The "all" row: its boxes set every player's box in their column, and
    -- show ticked while every player's is.
    local allTop = PAD + TITLE_HEIGHT
    local allLabel = UIUtil.CreateText(body, 'all', 12, UIUtil.bodyFont, true)
    allLabel:SetColor('ffaaaaaa')
    allLabel:DisableHitTest()
    LayoutHelpers.AtLeftTopIn(allLabel, inner, PAD + 14 + CHECK + 5 + SWATCH + 5, allTop + 3)

    local allCursors = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
    LayoutHelpers.AtLeftTopIn(allCursors, inner, PAD + 14, allTop + (ROW_HEIGHT - CHECK) / 2)
    LayoutHelpers.SetDimensions(allCursors, CHECK, CHECK)
    local allViews = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
    LayoutHelpers.AtLeftTopIn(allViews, inner, WIDTH - PAD - CHECK, allTop + (ROW_HEIGHT - CHECK) / 2)
    LayoutHelpers.SetDimensions(allViews, CHECK, CHECK)
    panel.allCursors, panel.allViews = allCursors, allViews

    --- Show the "all" boxes ticked while every player's box is.
    local function SyncAll()
        -- (A locked row -- dead, in a replay -- does not count.)
        local cursors, views, anyCursor, anyView = true, true, false, false
        for _, row in ipairs(panel.rows) do
            if not row.record.locked then
                anyCursor = true
                if not row.check:IsChecked() then cursors = false end
                if row.viewCheck then
                    anyView = true
                    if not row.viewCheck:IsChecked() then views = false end
                end
            end
        end
        allCursors:SetCheck(cursors and anyCursor, true)
        allViews:SetCheck(views and anyView, true)
    end
    allCursors.OnCheck = function(self, checked)
        for _, row in ipairs(panel.rows) do
            if not row.record.locked and row.check:IsChecked() ~= checked then
                row.check:SetCheck(checked)   -- as if clicked: hides or shows them
            end
        end
        SyncAll()
    end
    allViews.OnCheck = function(self, checked)
        for _, row in ipairs(panel.rows) do
            if not row.record.locked and row.viewCheck and row.viewCheck:IsChecked() ~= checked then
                row.viewCheck:SetCheck(checked)
            end
        end
        SyncAll()
    end

    local ctx = { body = body, inner = inner, hooks = hooks, onToggle = onToggle, width = WIDTH,
        nameLeft = nameLeft, nameRight = nameRight, nameRoom = nameRight - 4 - nameLeft,
        coachColumn = COACH > 0, syncAll = SyncAll }
    local line = 1
    for _, record in ipairs(players) do
        table.insert(panel.rows, MakeRow(ctx, record, PAD + TITLE_HEIGHT + line * ROW_HEIGHT))
        line = line + 1
    end
    -- (Nobody: "no other players" has the first line.)
    line = math.max(line, 2)
    if obsHeading then
        local text = 'observers - Team: ' .. ObserverTeam.Label()
        local heading = UIUtil.CreateText(body, text, 10, UIUtil.bodyFont, true)
        heading:SetText(text)
        heading:SetColor('ffaaaaaa')
        heading:DisableHitTest()
        LayoutHelpers.AtLeftTopIn(heading, inner, PAD + 14, PAD + TITLE_HEIGHT + line * ROW_HEIGHT + 5)
        panel.obsHeading = heading
        line = line + 1
        for _, record in ipairs(observers) do
            table.insert(panel.rows, MakeRow(ctx, record, PAD + TITLE_HEIGHT + line * ROW_HEIGHT))
            line = line + 1
        end
    end
    SyncAll()
    UpdateVersions()

    panel.parent = body
    if deadRow then
        DeadRow(body, inner, PAD + TITLE_HEIGHT + line * ROW_HEIGHT)
    end
    PaintOverlay()

    if arrow then
        SetUpTab(root, arrow, edge, height)
    end
    if layout.editing then
        panel.reset = ResetButton(body, edge)
    end

    local collapsed = collapsedPref
    if collapsed == nil then
        collapsed = cfg.StartCollapsed and true or false
    end
    if collapsed then
        SetCollapsed(true)
        if panel.arrow and panel.arrow.SetCheck then
            pcall(panel.arrow.SetCheck, panel.arrow, true, true)
        end
    end

    -- Built while the interface is hidden (a replay row turning up during
    -- screen capture mode): stay hidden with it.
    if UIHidden() then
        panel.hidden = true
        root:Hide()
    end
end

--- The title orange while anyone is on another version than ours.
function UpdateVersions()
    -- (Only when something was heard: Version.Revision.)
    if not panel or not panel.title or panel.versionRev == Version.Revision() then
        return
    end
    panel.versionRev = Version.Revision()
    local color = VersionsDiffer() and COLORS.titleOther or COLORS.title
    if color ~= panel.titleColor then
        panel.titleColor = color
        panel.title:SetColor(color)
        panel.underline:SetSolidColor(color)
    end
end

--- What our panel shows, for whoever follows us (coach.lua sends it): each
--- row's army and its two boxes, and "show dead cursors". "2:11,1003:10|d0".
---@return string
function State()
    local parts = {}
    for _, record in ipairs(source and source.records or {}) do
        table.insert(parts, string.format('%d:%d%d', record.army, record.disabled and 0 or 1,
            record.showView and not record.observer and 1 or 0))
    end
    return table.concat(parts, ',') .. '|d' .. (Config.Panel.ShowDead and 1 or 0)
end

--- Something in our panel changed: whoever follows us is told (coach.lua).
function Changed()
    local hooks = source and source.hooks
    if hooks and hooks.changed then
        pcall(hooks.changed)
    end
end

--- Their ticks (State's string, from the player we follow), drawn as green
--- outlines round our boxes; false takes them away. Ours stay as they are.
---@param state string | false
function SetOverlay(state)
    overlay = false
    if type(state) == 'string' and string.len(state) < 4000 then
        overlay = { me = source and source.hooks.me }
        for army, c, v in string.gfind(state, '(%d+):(%d)(%d)') do
            overlay[tonumber(army)] = { c = c == '1', v = v == '1' }
        end
        local _, _, dead = string.find(state, '|d(%d)')
        overlay.dead = dead == '1'
    end
    PaintOverlay()
end

--- Show the overlay as it stands on every row and the "show dead" box.
--- ("all" never: it is ours alone.)
function PaintOverlay()
    if not panel then
        return
    end
    for _, row in ipairs(panel.rows) do
        Paint(row)
    end
    if panel.deadCheck then
        SetRing(panel, 'deadRing', panel.deadCheck, overlay and overlay.dead)
    end
end

--- When UpdateDead last looked.
local deadT = -1000

--- Which teammates' armies are out of the game (dead): a line through their
--- name, and no cursor unless "show dead cursors" is ticked. Once a second:
--- GetArmiesTable builds the whole table afresh each call.
local function UpdateDead()
    local now = GetSystemTimeSeconds()
    if now - deadT < 1 then
        return
    end
    deadT = now
    local ok, info = pcall(GetArmiesTable)
    local armies = ok and type(info) == 'table' and info.armiesTable
    if type(armies) ~= 'table' then
        return
    end
    local changed, locked = false, false
    for _, record in ipairs(source.records) do
        if not record.observer then
            local army = armies[record.army]
            local dead = army and army.outOfGame and true or false
            if dead ~= (record.dead or false) then
                record.dead = dead
                changed = true
            end
            -- In a replay, nothing of theirs is recorded once they are dead:
            -- their boxes unticked and locked (rebuilt so).
            if dead and source.onlyHeard and not record.locked then
                record.locked, record.disabled, record.showView = true, true, false
                locked = true
                if source.onToggle then
                    pcall(source.onToggle, record)
                end
            end
        end
    end
    if locked then
        Build()
    elseif changed and panel then
        for _, row in ipairs(panel.rows) do
            Paint(row)
        end
    end
end

--- Show each row as its record says: the followed name highlighted, the
--- coached player's box ticked (changed from elsewhere too: a strong scroll).
function SyncFollow()
    if not panel then
        return
    end
    for _, row in ipairs(panel.rows) do
        Paint(row)
        if row.coachCheck and row.coachCheck:IsChecked() ~= (row.record.coached and true or false) then
            row.coachCheck:SetCheck(row.record.coached and true or false, true)
        end
    end
end

--- Rebuild when the panel no longer matches what it should list: in a replay,
--- a player whose data has just arrived; the panel switched on or off (a ReUI
--- option). Cheap when nothing changed.
function Sync()
    if not source then
        return
    end
    if not Config.Panel.Enabled then
        DestroyControls()
        return
    end
    local want = 0
    if source.onlyHeard then
        for _, record in ipairs(source.records) do
            if record.hasData then
                want = want + 1
            end
        end
    else
        want = table.getn(source.records)
    end
    local have = panel and table.getn(panel.rows) or 0
    -- (Nobody listed, the panel is there only while the options window is.)
    local shown = panel and true or false
    if want ~= have or shown ~= (want > 0 or layout.editing) then
        Build()
    end
end

--- TeamMouse's options window opened or closed: while it is open the panel
--- shows even with nobody to list, and its tab drags it along the edges.
---@param on boolean
function SetEditing(on)
    on = on and true or false
    if layout.editing == on then
        return
    end
    layout.editing = on
    Tip()
    Build()
end

--- Back to where config.lua puts it (Panel.X / Panel.Y), and forget the
--- saved spot.
function ResetPlace()
    layout.place = false
    SavePlace()
    Build()
end

--- Called every beat: follow the rest of the interface in and out of screen
--- capture mode.
function Refresh()
    if source then
        UpdateDead()
    end
    Sync()
    if not panel then
        return
    end
    UpdateVersions()
    local hidden = UIHidden()
    if hidden ~= (panel.hidden or false) then
        panel.hidden = hidden
        if hidden then
            panel.root:Hide()
        else
            panel.root:Show()
            -- Show() shows every child: put the collapsed state back.
            SetCollapsed(panel.collapsed)
        end
    end
end

--- For the tests.
function Get()
    return panel
end

function Destroy()
    DestroyControls()
    source = false
    collapsedPref = nil
    overlay = false
    deadT = -1000
end
