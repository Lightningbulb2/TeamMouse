--******************************************************************************
--** TeamMouse -- modules/optionswindow.lua
--**
--** TeamMouse's window in ReUI's options list. ReUI's own table-built window
--** has neither tooltips nor a scrollbar, but ReUI.Options.Builder.AddOptions
--** also takes a function that builds the window itself (ReUI's
--** Options/Modules/Selector.lua: `iscallable(self.data[2])`). This is that
--** window: the game's own Window, a Grid of rows with the game's scrollbar
--** (as FAF's own options dialog, lua/ui/dialogs/options.lua), and the game's
--** tooltips on every row.
--**
--** The values are ReUI's OptionVars (ReUI/Options/Modules/OptionVar.lua):
--** read by calling them, :Set(v) (which calls OnChange: options.lua writes
--** Config from there, so a change shows at once), :Save() to keep it in the
--** profile, :Reset() to go back to the saved value. OK saves, Cancel (or the
--** window's close button) resets, Defaults puts config.lua's values back.
--**
--** Only loaded when the window is opened, from the game's interface.
--******************************************************************************

local UIUtil = import('/lua/ui/uiutil.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local Group = import('/lua/maui/group.lua').Group
local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local Window = import('/lua/maui/window.lua').Window
local Grid = import('/lua/maui/grid.lua').Grid
local IntegerSlider = import('/lua/maui/slider.lua').IntegerSlider
local Tooltip = import('/lua/ui/game/tooltip.lua')
local Options = import((rawget(_G, 'TeamMousePath') or '/mods/TeamMouse') .. '/modules/options.lua')

local ROW_W = 380
local ROW_H = 44
local TITLE_H = 30
local VISIBLE_ROWS = 10
local PAD = 10
local SCROLL_W = 26
local BUTTONS_H = 44

--- The same frame ReUI's own options windows use.
local function WindowTextures()
    return {
        tl = UIUtil.SkinnableFile('/game/panel/panel_brd_ul.dds'),
        tr = UIUtil.SkinnableFile('/game/panel/panel_brd_ur.dds'),
        tm = UIUtil.SkinnableFile('/game/panel/panel_brd_horz_um.dds'),
        ml = UIUtil.SkinnableFile('/game/panel/panel_brd_vert_l.dds'),
        m = UIUtil.SkinnableFile('/game/panel/panel_brd_m.dds'),
        mr = UIUtil.SkinnableFile('/game/panel/panel_brd_vert_r.dds'),
        bl = UIUtil.SkinnableFile('/game/panel/panel_brd_ll.dds'),
        bm = UIUtil.SkinnableFile('/game/panel/panel_brd_lm.dds'),
        br = UIUtil.SkinnableFile('/game/panel/panel_brd_lr.dds'),
        borderColor = '00415055',
    }
end

--- A slider value as shown beside it.
---@param entry table
---@param value number
---@return string
local function Shown(entry, value)
    if entry.kind == 'percent' then
        return string.format('%d%%', value)
    end
    return string.format('%d', value)
end

--- Give a control the row's tooltip, and pass the mouse wheel to the list
--- (anything in a row would otherwise swallow it). Keeps what the control
--- did with every other event.
---@param control Control
---@param state table
---@param tip table | false   # { text, body }
local function Hook(control, state, tip)
    local original = control.HandleEvent
    control.HandleEvent = function(self, event)
        local t = event.Type
        if t == 'WheelRotation' then
            if state.scrollbar then
                state.scrollbar:DoScrollLines(event.WheelRotation > 0 and -1 or 1)
            end
            return true
        elseif tip and t == 'MouseEnter' then
            Tooltip.CreateMouseoverDisplay(self, tip, 0.3, true)
        elseif tip and t == 'MouseExit' then
            Tooltip.DestroyMouseoverDisplay()
        end
        if original then
            return original(self, event)
        end
        return false
    end
end

--- One row of the list: a heading, a checkbox, or a slider with its value.
---@param grid Grid
---@param entry table
---@param option any      # its OptionVar (none for a heading)
---@param state table
---@return Group
local function CreateRow(grid, entry, option, state)
    local row = Group(grid)
    LayoutHelpers.SetDimensions(row, ROW_W, ROW_H)

    -- Behind everything: catches the pointer anywhere on the row, for the
    -- tooltip and the wheel. Fully transparent (a Bitmap needs a colour).
    local back = Bitmap(row)
    back:SetSolidColor('00000000')
    LayoutHelpers.FillParent(back, row)
    local tip = entry.tip and { text = entry.label, body = entry.tip } or false
    Hook(back, state, tip)

    if entry.kind == 'title' then
        local text = UIUtil.CreateText(row, entry.label, 16, UIUtil.titleFont)
        text:SetColor(UIUtil.highlightColor or 'ffffffff')
        LayoutHelpers.AtLeftIn(text, row, 2)
        LayoutHelpers.AtBottomIn(text, row, 4)
        text:DisableHitTest()
        row.text = text
        return row
    end

    if entry.kind == 'toggle' then
        local check = UIUtil.CreateCheckbox(row, '/dialogs/check-box_btn/', entry.label, true)
        LayoutHelpers.AtLeftIn(check, row, 8)
        LayoutHelpers.AtVerticalCenterIn(check, row)
        check:SetCheck(Options.Read(option) and true or false, true)
        check.OnCheck = function(control, checked)
            option:Set(checked and true or false)
        end
        Hook(check, state, tip)
        row.control = check
        row.Refresh = function(self)
            check:SetCheck(Options.Read(option) and true or false, true)
        end
        return row
    end

    -- A slider: its name above, its value beside it.
    local name = UIUtil.CreateText(row, entry.label, 14, UIUtil.bodyFont)
    LayoutHelpers.AtLeftTopIn(name, row, 8, 2)
    Hook(name, state, tip)

    local slider = IntegerSlider(row, false, entry.min, entry.max, entry.step,
        UIUtil.SkinnableFile('/slider02/slider_btn_up.dds'),
        UIUtil.SkinnableFile('/slider02/slider_btn_over.dds'),
        UIUtil.SkinnableFile('/slider02/slider_btn_down.dds'),
        UIUtil.SkinnableFile('/dialogs/options-02/slider-back_bmp.dds'))
    LayoutHelpers.AtLeftTopIn(slider, row, 8, 20)
    Hook(slider, state, tip)

    local value = UIUtil.CreateText(row, '', 14, UIUtil.bodyFont)
    LayoutHelpers.AtRightTopIn(value, row, 8, 20)
    value:DisableHitTest()

    slider.OnValueChanged = function(control, newValue)
        value:SetText(Shown(entry, newValue))
    end
    -- Live while dragging: the cursors change as the thumb moves.
    slider.OnValueSet = function(control, newValue)
        option:Set(newValue)
    end
    local current = Options.Read(option)
    if type(current) ~= 'number' then current = entry.min end
    slider:SetValue(current)
    value:SetText(Shown(entry, current))

    row.control = slider
    row.Refresh = function(self)
        local v = Options.Read(option)
        if type(v) == 'number' then
            slider:SetValue(v)
            value:SetText(Shown(entry, v))
        end
    end
    return row
end

--- Every option of ours, for OK / Cancel / Defaults.
---@param spec table
---@param values table
---@param fn function   # fn(entry, option)
local function EachOption(spec, values, fn)
    for _, entry in ipairs(spec) do
        local option = entry.key and values[entry.key]
        if option then
            fn(entry, option)
        end
    end
end

--- Build the window. ReUI calls this when TeamMouse is picked in its list.
---@param parent Control   # ReUI passes its root frame
---@param title string
---@param spec table       # options.lua's Spec
---@param values table     # ReUI.Options.Mods[MOD_KEY]
---@return Window
function Create(parent, title, spec, values)
    local state = { scrollbar = false, rows = {} }

    local width = PAD + ROW_W + SCROLL_W + PAD
    local listHeight = ROW_H * VISIBLE_ROWS
    local window = Window(parent, title, nil, false, false, true, false, 'TeamMouseOptionsWindow', {
        Left = 120,
        Top = 100,
        Right = 120 + width + 16,
        Bottom = 100 + listHeight + BUTTONS_H + 60,
    }, WindowTextures())
    local client = window:GetClientGroup()

    -- The list, and the game's scrollbar beside it.
    local grid = Grid(client, ROW_W, ROW_H)
    LayoutHelpers.AtLeftTopIn(grid, client, PAD, PAD)
    LayoutHelpers.SetDimensions(grid, ROW_W, listHeight)
    grid:AppendCols(1, true)
    local n = 0
    for _, entry in ipairs(spec) do
        local option = entry.key and values[entry.key]
        if entry.kind == 'title' or option then
            n = n + 1
            grid:AppendRows(1, true)
            local row = CreateRow(grid, entry, option, state)
            grid:SetItem(row, 1, n, true)
            table.insert(state.rows, row)
        end
    end
    grid:EndBatch()
    state.scrollbar = UIUtil.CreateVertScrollbarFor(grid, 4)
    Hook(grid, state, false)

    -- OK keeps the changes, Cancel (or closing) puts them back as they were;
    -- Defaults puts config.lua's values in (still to be kept with OK).
    local function Close(save)
        Tooltip.DestroyMouseoverDisplay()
        EachOption(spec, values, function(entry, option)
            if save then
                if option.Save then option:Save() end
            elseif option.Reset then
                option:Reset()
            end
        end)
        window:Destroy()
    end

    local ok = UIUtil.CreateButtonStd(client, '/widgets02/small', '<LOC _Ok>', 16)
    LayoutHelpers.AtLeftIn(ok, client, PAD)
    LayoutHelpers.AtBottomIn(ok, client, 6)
    ok.OnClick = function() Close(true) end

    local cancel = UIUtil.CreateButtonStd(client, '/widgets02/small', '<LOC _Cancel>', 16)
    LayoutHelpers.AtRightIn(cancel, client, PAD)
    LayoutHelpers.AtBottomIn(cancel, client, 6)
    cancel.OnClick = function() Close(false) end

    local defaults = UIUtil.CreateButtonStd(client, '/widgets02/small', 'Defaults', 16)
    LayoutHelpers.AtHorizontalCenterIn(defaults, client)
    LayoutHelpers.AtBottomIn(defaults, client, 6)
    defaults.OnClick = function()
        EachOption(spec, values, function(entry, option)
            local default = entry.default
            if default ~= nil and default ~= Options.Read(option) then
                option:Set(default)
            end
        end)
        for _, row in ipairs(state.rows) do
            if row.Refresh then row:Refresh() end
        end
    end
    Tooltip.AddControlTooltipManual(defaults, 'Defaults',
        'Put every TeamMouse setting back as it ships. OK keeps it, Cancel undoes it.')

    window.OnClose = function(self) Close(false) end

    window.TeamMouseRows = state.rows
    window.TeamMouseGrid = grid
    window.TeamMouseButtons = { ok = ok, cancel = cancel, defaults = defaults }
    return window
end
