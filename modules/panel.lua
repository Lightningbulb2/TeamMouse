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
--** Each row also shows the version of TeamMouse that player is on (version.lua).
--** Click a player's name to follow their view (coach.lua); click it again to
--** stop. Live observers also get a "coach" box per player (one at a time),
--** and players a "drawings on my screen" box under the list.
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
local VERSION_WIDTH = 30

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
local layout = { editing = false, place = false, loaded = false, raised = false }

local PREF_KEY = 'TeamMousePanelPlace'
local HINT_COLOR = 'ffffd24a'
--- A followed player's name, and the band behind it.
local FOLLOW_COLOR = 'ffffd24a'
local FOLLOW_BACK = 'ff6b5200'

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

--- Show a row as on or off.
---@param row table
local function Paint(row)
    local on = not row.record.disabled
    row.swatch:SetSolidColor(on and row.color or OFF_COLOR)
    row.label:SetAlpha(on and 1 or 0.4)
    row.label:SetColor(row.record.follow and FOLLOW_COLOR or 'ffffffff')
    -- Through its alpha, not Hide: showing the panel shows every child.
    if row.highlight then
        row.highlight:SetAlpha(row.record.follow and 0.9 or 0)
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
--- it shows the whole name. With `onClick`, a left click on it calls
--- onClick() (following them), and hovering it says so.
---@param label Text
---@param name string
---@param room number
---@param onClick? function
local function ShowName(label, name, room, onClick)
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
    label.HandleEvent = function(self, event)
        local t = event.Type
        if t == 'MouseEnter' then
            Tip(self, tip)
        elseif t == 'MouseExit' then
            Tip()
        elseif onClick and (t == 'ButtonPress' or t == 'ButtonDClick')
            and not (event.Modifiers and event.Modifiers.Right) then
            Play('UI_Menu_MouseDown_Sml')
            onClick()
            return true
        end
        return false
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

--- Build the panel.
---@param records table[]   # the players, in the order to list them; each a peer record
---@param onToggle? function   # called with a record after its cursor is hidden or shown
---@param hooks? table          # coaching (coach.lua): follow(record) for a click on a
---                               name; coach(record, on) for a "coach" box per player
---                               (live observers); lens(on), lensOn() for the "drawings
---                               on my screen" box (players)
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
    local FOLLOW = hooks.coach and Config.Coach.Enabled and 44 or 0
    -- A player: a row under the list, "drawings on my screen".
    local LENS = hooks.lens and Config.Coach.Enabled and ROW_HEIGHT or 0
    -- Each player's TeamMouse version, in a column of its own.
    local VERSIONS = Config.Panel.ShowVersions and VERSION_WIDTH or 0
    local WIDTH = WIDTH + FOLLOW + VERSIONS
    -- The version column sits just left of the right-hand box columns.
    local versionLeft = WIDTH - PAD - CHECK - 4 - VERSION_WIDTH
    if FOLLOW > 0 then
        versionLeft = WIDTH - PAD - CHECK * 2 - 22 - VERSION_WIDTH
    end
    -- Room for a name: up to the version column, or else the first column of boxes.
    local nameLeft = PAD + 14 + CHECK + 5 + SWATCH + 5
    local nameRight = (VERSIONS > 0 and versionLeft)
        or (FOLLOW > 0 and WIDTH - PAD - CHECK * 2 - 12) or (WIDTH - PAD - CHECK)
    local nameRoom = nameRight - 4 - nameLeft
    -- The title, a row of "all" boxes, then a row per player (or one saying
    -- there is nobody).
    local height = TITLE_HEIGHT + (math.max(table.getn(records), 1) + 1) * ROW_HEIGHT + PAD * 2 + LENS

    local root = Group(frame, 'TeamMousePanel')
    LayoutHelpers.SetDimensions(root, WIDTH, height)
    Place(root)
    root.Depth:Set(layout.raised and Config.Coach.PanelRaisedDepth or cfg.Depth)
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

    local title = UIUtil.CreateText(body, 'TeamMouse cursors', 10, UIUtil.bodyFont, true)
    title:SetColor('ffaaaaaa')
    title:DisableHitTest(true)
    LayoutHelpers.AtLeftTopIn(title, inner, PAD + 14, PAD - 2)

    -- Over the right-hand column of boxes: their view's outline (Viewport).
    local viewHeader = UIUtil.CreateText(body, 'view', 9, UIUtil.bodyFont, true)
    viewHeader:SetColor('ffaaaaaa')
    viewHeader:DisableHitTest(true)
    LayoutHelpers.AtLeftTopIn(viewHeader, inner, WIDTH - PAD - CHECK - 4, PAD - 1)
    if FOLLOW > 0 then
        local followHeader = UIUtil.CreateText(body, 'coach', 9, UIUtil.bodyFont, true)
        followHeader:SetColor('ffaaaaaa')
        followHeader:DisableHitTest(true)
        LayoutHelpers.AtLeftTopIn(followHeader, inner, WIDTH - PAD - CHECK * 2 - 18, PAD - 1)
    end

    if VERSIONS > 0 then
        local versionHeader = UIUtil.CreateText(body, 'ver', 9, UIUtil.bodyFont, true)
        versionHeader:SetColor('ffaaaaaa')
        versionHeader:DisableHitTest(true)
        LayoutHelpers.AtLeftTopIn(versionHeader, inner, versionLeft, PAD - 1)
    end

    panel = { root = root, body = body, rows = {}, collapsed = false, versions = VERSIONS > 0,
        edge = edge, editing = layout.editing }

    if table.getn(records) == 0 then
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
        local cursors, views = true, true
        for _, row in ipairs(panel.rows) do
            if not row.check:IsChecked() then cursors = false end
            if not row.viewCheck:IsChecked() then views = false end
        end
        allCursors:SetCheck(cursors and table.getn(panel.rows) > 0, true)
        allViews:SetCheck(views and table.getn(panel.rows) > 0, true)
    end
    allCursors.OnCheck = function(self, checked)
        for _, row in ipairs(panel.rows) do
            if row.check:IsChecked() ~= checked then
                row.check:SetCheck(checked)   -- as if clicked: hides or shows them
            end
        end
        SyncAll()
    end
    allViews.OnCheck = function(self, checked)
        for _, row in ipairs(panel.rows) do
            if row.viewCheck:IsChecked() ~= checked then
                row.viewCheck:SetCheck(checked)
            end
        end
        SyncAll()
    end

    for i, entry in ipairs(records) do
        -- A local of this iteration's own. In Lua 5.0 a closure made in a
        -- for loop captures the loop variable itself, which is nil once the
        -- loop has finished: OnCheck below would find no record at all.
        local record = entry
        local top = PAD + TITLE_HEIGHT + i * ROW_HEIGHT

        -- FAF's own checkbox, as its panels use (multifunction.lua): it does
        -- its own clicks, hover and sound. Ticked = shown.
        local check = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
        LayoutHelpers.AtLeftTopIn(check, inner, PAD + 14, top + (ROW_HEIGHT - CHECK) / 2)
        LayoutHelpers.SetDimensions(check, CHECK, CHECK)

        local swatch = Bitmap(body)
        LayoutHelpers.AtLeftTopIn(swatch, inner, PAD + 14 + CHECK + 5, top + (ROW_HEIGHT - SWATCH) / 2)
        LayoutHelpers.SetDimensions(swatch, SWATCH, SWATCH)
        swatch:DisableHitTest()

        -- Behind the name while we follow them (made first: drawn under it).
        local highlight = Bitmap(body)
        highlight:SetSolidColor(FOLLOW_BACK)
        highlight:SetAlpha(0)
        highlight:DisableHitTest()
        -- (Right of their colour square, which stays in sight.)
        LayoutHelpers.AtLeftTopIn(highlight, inner, nameLeft - 3, top + 1)
        LayoutHelpers.SetDimensions(highlight, nameRight - nameLeft + 3, ROW_HEIGHT - 2)

        local label = UIUtil.CreateText(body, record.name or '?', 12, UIUtil.bodyFont, true)
        label:SetColor('ffffffff')
        local onClick = nil
        if hooks.follow and Config.Follow.Enabled then
            onClick = function()
                hooks.follow(record)
                SyncFollow()
            end
        end
        ShowName(label, record.name or '?', nameRoom, onClick)
        LayoutHelpers.AtLeftTopIn(label, inner, nameLeft, top + 3)

        -- Their view's outline on the map (Viewport): off unless ticked, and
        -- not remembered between games.
        local viewCheck = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
        LayoutHelpers.AtLeftTopIn(viewCheck, inner, WIDTH - PAD - CHECK, top + (ROW_HEIGHT - CHECK) / 2)
        LayoutHelpers.SetDimensions(viewCheck, CHECK, CHECK)
        viewCheck:SetCheck(record.showView and true or false, true)
        viewCheck.OnCheck = function(self, checked)
            record.showView = checked and true or false
            SyncAll()
        end

        -- A live observer: coach this player (coach.lua). One player at a
        -- time: ticking one unticks the rest.
        local coachCheck = false
        if FOLLOW > 0 then
            coachCheck = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
            LayoutHelpers.AtLeftTopIn(coachCheck, inner, WIDTH - PAD - CHECK * 2 - 12,
                top + (ROW_HEIGHT - CHECK) / 2)
            LayoutHelpers.SetDimensions(coachCheck, CHECK, CHECK)
            coachCheck:SetCheck(record.coached and true or false, true)
            coachCheck.OnCheck = function(self, checked)
                hooks.coach(record, checked and true or false)
                SyncFollow()
            end
        end

        -- Their TeamMouse version (filled in by Refresh as it is heard).
        local versionLabel = false
        if VERSIONS > 0 then
            versionLabel = UIUtil.CreateText(body, '?', 10, UIUtil.bodyFont, true)
            versionLabel:DisableHitTest(true)
            LayoutHelpers.AtLeftTopIn(versionLabel, inner, versionLeft, top + 4)
        end

        local row = { record = record, check = check, swatch = swatch, label = label,
            viewCheck = viewCheck, coachCheck = coachCheck, highlight = highlight,
            color = CursorData.SafeUIColor(record.color),
            versionLabel = versionLabel, versionText = false }
        check:SetCheck(not record.disabled, true)
        check.OnCheck = function(self, checked)
            record.disabled = not checked
            Paint(row)
            if onToggle then
                pcall(onToggle, record)
            end
            SyncAll()
        end

        Paint(row)
        table.insert(panel.rows, row)
    end
    SyncAll()
    UpdateVersions()

    -- A player: whether what those following (or coaching) them draw shows.
    if LENS > 0 then
        local lensTop = PAD + TITLE_HEIGHT + (math.max(table.getn(records), 1) + 1) * ROW_HEIGHT
        local lensCheck = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
        LayoutHelpers.AtLeftTopIn(lensCheck, inner, PAD + 14, lensTop + (ROW_HEIGHT - CHECK) / 2)
        LayoutHelpers.SetDimensions(lensCheck, CHECK, CHECK)
        lensCheck:SetCheck(hooks.lensOn and hooks.lensOn() and true or false, true)
        lensCheck.OnCheck = function(self, checked)
            hooks.lens(checked and true or false)
        end
        local lensLabel = UIUtil.CreateText(body, 'drawings on my screen', 10, UIUtil.bodyFont, true)
        lensLabel:SetColor('ffaaaaaa')
        lensLabel:DisableHitTest()
        LayoutHelpers.AtLeftTopIn(lensLabel, inner, PAD + 14 + CHECK + 5, lensTop + 4)
        panel.lensCheck = lensCheck
    end

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

--- Bring each row's version up to date. Only touches a row whose text changed.
function UpdateVersions()
    if not panel or not panel.versions then
        return
    end
    for _, row in ipairs(panel.rows) do
        if row.versionLabel then
            local text, color = Version.Describe(row.record.name)
            if text ~= row.versionText then
                row.versionText = text
                row.versionLabel:SetText(text)
                row.versionLabel:SetColor(color)
            end
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
--- a player whose data has just arrived; the panel switched on or off, or its
--- version column (both ReUI options). Cheap when nothing changed.
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
    local versions = Config.Panel.ShowVersions and true or false
    -- (Nobody listed, the panel is there only while the options window is.)
    local shown = panel and true or false
    if want ~= have or shown ~= (want > 0 or layout.editing)
        or (panel and panel.versions ~= versions) then
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

--- While following someone (coach.lua), the panel goes above the layer that
--- takes every click for drawing on their screen, so a name can still be
--- clicked to stop; back down afterwards.
---@param on boolean
function SetRaised(on)
    layout.raised = on and true or false
    if panel then
        panel.root.Depth:Set(layout.raised and Config.Coach.PanelRaisedDepth or Config.Panel.Depth)
    end
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
end
