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
--** Built once at the start of the game. Choices last for the game only.
--******************************************************************************

local Config = import(_G.TeamMousePath .. '/modules/config.lua')
local CursorData = import(_G.TeamMousePath .. '/modules/cursordata.lua')
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

local panel = false

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
    if collapsed then
        panel.body:Hide()
    else
        panel.body:Show()
    end
end

--- Build the panel.
---@param records table[]   # the players, in the order to list them; each a peer record
---@param onToggle? function   # called with a record after its cursor is hidden or shown
---@param replay? boolean       # a replay: each player also gets a "follow" box
function Create(records, onToggle, replay)
    Destroy()
    if not Config.Panel.Enabled or table.getn(records) == 0 then
        return
    end

    local frame = GetFrame(0)
    if not frame then
        return
    end

    local cfg = Config.Panel
    -- In a replay, a second column of boxes: follow that player's camera.
    local FOLLOW = replay and Config.Follow.Enabled and 44 or 0
    local WIDTH = WIDTH + FOLLOW
    -- The title, a row of "all" boxes, then a row per player.
    local height = TITLE_HEIGHT + (table.getn(records) + 1) * ROW_HEIGHT + PAD * 2

    local root = Group(frame, 'TeamMousePanel')
    root.Left:Set(function() return frame.Left() + frame.Width() * cfg.X end)
    root.Top:Set(function() return frame.Top() + frame.Height() * cfg.Y end)
    LayoutHelpers.SetDimensions(root, WIDTH, height)
    root.Depth:Set(cfg.Depth)
    root:DisableHitTest()

    -- Everything that collapses away.
    local body = Group(root, 'TeamMousePanelBody')
    LayoutHelpers.AtLeftTopIn(body, root, 0, 0)
    LayoutHelpers.SetDimensions(body, WIDTH, height)
    body:DisableHitTest()

    local back = Bitmap(body)
    back:SetSolidColor(cfg.BackColor)
    LayoutHelpers.AtLeftTopIn(back, body, 0, 0)
    LayoutHelpers.SetDimensions(back, WIDTH, height)
    back:DisableHitTest()

    local title = UIUtil.CreateText(body, 'TeamMouse cursors', 10, UIUtil.bodyFont, true)
    title:SetColor('ffaaaaaa')
    title:DisableHitTest(true)
    LayoutHelpers.AtLeftTopIn(title, body, PAD + 14, PAD - 2)

    -- Over the right-hand column of boxes: their view's outline (Viewport).
    local viewHeader = UIUtil.CreateText(body, 'view', 9, UIUtil.bodyFont, true)
    viewHeader:SetColor('ffaaaaaa')
    viewHeader:DisableHitTest(true)
    LayoutHelpers.AtLeftTopIn(viewHeader, body, WIDTH - PAD - CHECK - 4, PAD - 1)
    if FOLLOW > 0 then
        local followHeader = UIUtil.CreateText(body, 'follow', 9, UIUtil.bodyFont, true)
        followHeader:SetColor('ffaaaaaa')
        followHeader:DisableHitTest(true)
        LayoutHelpers.AtLeftTopIn(followHeader, body, WIDTH - PAD - CHECK * 2 - 18, PAD - 1)
    end

    panel = { root = root, body = body, rows = {}, collapsed = false }

    -- The "all" row: its boxes set every player's box in their column, and
    -- show ticked while every player's is.
    local allTop = PAD + TITLE_HEIGHT
    local allLabel = UIUtil.CreateText(body, 'all', 12, UIUtil.bodyFont, true)
    allLabel:SetColor('ffaaaaaa')
    allLabel:DisableHitTest()
    LayoutHelpers.AtLeftTopIn(allLabel, body, PAD + 14 + CHECK + 5 + SWATCH + 5, allTop + 3)

    local allCursors = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
    LayoutHelpers.AtLeftTopIn(allCursors, body, PAD + 14, allTop + (ROW_HEIGHT - CHECK) / 2)
    LayoutHelpers.SetDimensions(allCursors, CHECK, CHECK)
    local allViews = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
    LayoutHelpers.AtLeftTopIn(allViews, body, WIDTH - PAD - CHECK, allTop + (ROW_HEIGHT - CHECK) / 2)
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
        LayoutHelpers.AtLeftTopIn(check, body, PAD + 14, top + (ROW_HEIGHT - CHECK) / 2)
        LayoutHelpers.SetDimensions(check, CHECK, CHECK)

        local swatch = Bitmap(body)
        LayoutHelpers.AtLeftTopIn(swatch, body, PAD + 14 + CHECK + 5, top + (ROW_HEIGHT - SWATCH) / 2)
        LayoutHelpers.SetDimensions(swatch, SWATCH, SWATCH)
        swatch:DisableHitTest()

        local label = UIUtil.CreateText(body, record.name or '?', 12, UIUtil.bodyFont, true)
        label:SetColor('ffffffff')
        label:DisableHitTest()
        LayoutHelpers.AtLeftTopIn(label, body, PAD + 14 + CHECK + 5 + SWATCH + 5, top + 3)

        -- Their view's outline on the map (Viewport): off unless ticked, and
        -- not remembered between games.
        local viewCheck = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
        LayoutHelpers.AtLeftTopIn(viewCheck, body, WIDTH - PAD - CHECK, top + (ROW_HEIGHT - CHECK) / 2)
        LayoutHelpers.SetDimensions(viewCheck, CHECK, CHECK)
        viewCheck:SetCheck(record.showView and true or false, true)
        viewCheck.OnCheck = function(self, checked)
            record.showView = checked and true or false
            SyncAll()
        end

        -- In a replay: your camera follows theirs (Config.Follow). One
        -- player at a time: ticking one unticks the rest.
        local followCheck = false
        if FOLLOW > 0 then
            followCheck = UIUtil.CreateCheckbox(body, '/CHECKBOX/')
            LayoutHelpers.AtLeftTopIn(followCheck, body, WIDTH - PAD - CHECK * 2 - 12,
                top + (ROW_HEIGHT - CHECK) / 2)
            LayoutHelpers.SetDimensions(followCheck, CHECK, CHECK)
            followCheck:SetCheck(record.follow and true or false, true)
            followCheck.OnCheck = function(self, checked)
                if checked then
                    for _, other in ipairs(panel.rows) do
                        if other.record ~= record and other.followCheck then
                            other.record.follow = false
                            other.followCheck:SetCheck(false, true)
                        end
                    end
                end
                record.follow = checked and true or false
            end
        end

        local row = { record = record, check = check, swatch = swatch, label = label,
            viewCheck = viewCheck, followCheck = followCheck, color = CursorData.SafeUIColor(record.color) }
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


    -- FAF's own left-edge tab. Checked means collapsed, as for its panels.
    local okArrow, arrow = pcall(UIUtil.CreateCollapseArrow, root, 'l')
    if okArrow and arrow then
        LayoutHelpers.AtLeftTopIn(arrow, root, -3, (height - 24) / 2)
        arrow.Depth:Set(function() return root.Depth() + 10 end)
        arrow.OnCheck = function(self, checked)
            SetCollapsed(checked)
            Play(checked and 'UI_Score_Window_Close' or 'UI_Score_Window_Open')
        end
        panel.arrow = arrow
    end

    if cfg.StartCollapsed then
        SetCollapsed(true)
        if panel.arrow and panel.arrow.SetCheck then
            pcall(panel.arrow.SetCheck, panel.arrow, true, true)
        end
    end
end

--- Called every beat: follow the rest of the interface in and out of screen
--- capture mode.
function Refresh()
    if not panel then
        return
    end
    local ok, GameMain = pcall(import, '/lua/ui/game/gamemain.lua')
    local hidden = ok and type(GameMain) == 'table' and GameMain.gameUIHidden and true or false
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
    if panel then
        pcall(function() panel.root:Destroy() end)
        panel = false
    end
end
