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
--** Choices last for the game only.
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
--- toggle callback, whether there is a follow column, and whether only players
--- whose data has arrived are listed (replays).
local source = false

--- Folded or not, carried across a rebuild (nil: Panel.StartCollapsed).
local collapsedPref = nil

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

--- Build the panel.
---@param records table[]   # the players, in the order to list them; each a peer record
---@param onToggle? function   # called with a record after its cursor is hidden or shown
---@param replay? boolean       # each player also gets a "follow" box (replays, observers)
---@param onlyHeard? boolean    # list a player only once their data has arrived (replays)
function Create(records, onToggle, replay, onlyHeard)
    Destroy()
    source = { records = records, onToggle = onToggle, replay = replay, onlyHeard = onlyHeard and true or false }
    Build()
end

Build = function()
    DestroyControls()
    if not source then
        return
    end
    local records = Listed()
    local onToggle, replay = source.onToggle, source.replay
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
    -- Each player's TeamMouse version, in a column of its own.
    local VERSIONS = Config.Panel.ShowVersions and VERSION_WIDTH or 0
    local WIDTH = WIDTH + FOLLOW + VERSIONS
    -- The version column sits just left of the right-hand box columns.
    local versionLeft = WIDTH - PAD - CHECK - 4 - VERSION_WIDTH
    if FOLLOW > 0 then
        versionLeft = WIDTH - PAD - CHECK * 2 - 22 - VERSION_WIDTH
    end
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

    if VERSIONS > 0 then
        local versionHeader = UIUtil.CreateText(body, 'ver', 9, UIUtil.bodyFont, true)
        versionHeader:SetColor('ffaaaaaa')
        versionHeader:DisableHitTest(true)
        LayoutHelpers.AtLeftTopIn(versionHeader, body, versionLeft, PAD - 1)
    end

    panel = { root = root, body = body, rows = {}, collapsed = false, versions = VERSIONS > 0 }

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

        -- Their TeamMouse version (filled in by Refresh as it is heard).
        local versionLabel = false
        if VERSIONS > 0 then
            versionLabel = UIUtil.CreateText(body, '?', 10, UIUtil.bodyFont, true)
            versionLabel:DisableHitTest(true)
            LayoutHelpers.AtLeftTopIn(versionLabel, body, versionLeft, top + 4)
        end

        local row = { record = record, check = check, swatch = swatch, label = label,
            viewCheck = viewCheck, followCheck = followCheck, color = CursorData.SafeUIColor(record.color),
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

--- Show each row's "follow" box as its record says (following was stopped
--- from elsewhere: a strong scroll).
function SyncFollow()
    if not panel then
        return
    end
    for _, row in ipairs(panel.rows) do
        if row.followCheck and row.followCheck:IsChecked() ~= (row.record.follow and true or false) then
            row.followCheck:SetCheck(row.record.follow and true or false, true)
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
    if want ~= have or (panel and panel.versions ~= versions) then
        Build()
    end
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
