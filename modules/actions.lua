--******************************************************************************
--** TeamMouse -- modules/actions.lua
--**
--** Notices a few orders that have no position of their own -- Stop, toggling
--** repeat build, pausing and resuming, copying and distributing orders -- so
--** teammates can see them happen, as a short label by the player's cursor.
--**
--** Hooked where FAF's own key actions and command buttons end up (checked
--** against lua/keymap/keyactions.lua):
--**
--**   Stop, SoftStop       /lua/ui/game/orders.lua            ('stop', 'soft_stop', the Stop button)
--**   ToggleRepeatBuild    /lua/keymap/misckeyactions.lua     ('toggle_repeat_build')
--**   AbortNavigation      /lua/keymap/misckeyactions.lua     ('abort_navigation': "Interrupt
--**                                                            pathfinding of engineers")
--**   ToggleUnitPause,     /lua/ui/game/construction.lua      ('pause_unit', 'pause_unit_all',
--**   ...PauseAll, ...UnpauseAll                              'unpause_unit_all')
--**   SetPaused            engine global                      (the pause button, anything else)
--**   SimCallback          engine global                      (CopyOrders: 'copy_orders', ctrl-assist;
--**                                                            DistributeOrders: 'spreadattack' and its
--**                                                            shift/_context variants)
--**
--** A key action runs `import(file).Function()` when it fires, so replacing
--** the function in the module table catches it. Each hook is installed only if
--** the function is there, and removed again on teardown.
--******************************************************************************

STOP = 1
REPEAT_ON = 2
REPEAT_OFF = 3
PAUSED = 4
RESUMED = 5
INTERRUPT = 6
COPY = 7
DISTRIBUTE = 8

--- Label for each action, by code.
Labels = { 'STOP', 'REPEAT ON', 'REPEAT OFF', 'PAUSED', 'RESUMED', 'INTERRUPT', 'COPY', 'DISTRIBUTE ORDERS' }

local installed = {}   -- { table, key, original, wrapper }
local notify = false
local inSoftStop = false
local inPause = false

---@param units any
---@return boolean
local function HasUnits(units)
    return type(units) == 'table' and units[1] ~= nil
end

---@return table | nil
local function Selection()
    local ok, units = pcall(GetSelectedUnits)
    if ok and HasUnits(units) then
        return units
    end
    return nil
end

--- Replace tbl[key] with a wrapper. `before` runs first, with the same
--- arguments, and returns the action to report (or nil); the report is made
--- only once the original has run without error.
---@param tbl table
---@param key string
---@param before function
---@return boolean   # installed
local function Wrap(tbl, key, before)
    if type(tbl) ~= 'table' or type(tbl[key]) ~= 'function' then
        return false
    end
    local original = tbl[key]
    local wrapper = function(a, b, c, d)
        local okBefore, action = pcall(before, a, b)
        local r1, r2, r3 = original(a, b, c, d)
        if okBefore and action and notify then
            pcall(notify, action)
        end
        return r1, r2, r3
    end
    tbl[key] = wrapper
    table.insert(installed, { tbl, key, original, wrapper })
    return true
end

--- Start reporting actions to `callback(code)`.
---@param callback function
---@return string[]   # what was hooked, for the log
function Install(callback)
    Uninstall()
    notify = callback
    local hooked = {}

    local okOrders, orders = pcall(import, '/lua/ui/game/orders.lua')
    if okOrders then
        -- SoftStop ends by calling Stop, often with nothing left to stop once
        -- factories are filtered out: report it once, from here.
        if Wrap(orders, 'SoftStop', function(units)
            inSoftStop = true
            return HasUnits(units or Selection()) and STOP or nil
        end) then
            local wrapper = orders.SoftStop
            orders.SoftStop = function(a, b, c, d)
                local ok, r1, r2, r3 = pcall(wrapper, a, b, c, d)
                inSoftStop = false
                if not ok then error(r1, 0) end
                return r1, r2, r3
            end
            installed[table.getn(installed)][4] = orders.SoftStop
            table.insert(hooked, 'SoftStop')
        end
        if Wrap(orders, 'Stop', function(units)
            if inSoftStop then return nil end
            return HasUnits(units or Selection()) and STOP or nil
        end) then
            table.insert(hooked, 'Stop')
        end
    end

    local okKeys, keys = pcall(import, '/lua/keymap/misckeyactions.lua')
    if okKeys and Wrap(keys, 'ToggleRepeatBuild', function()
        -- Read before the toggle: after it, the units only say so once the
        -- sim has caught up. Same rule as the function itself: it only acts
        -- on a selection of factories, and turns repeat off if any has it on.
        local units = Selection()
        if not units then return nil end
        local anyOn = false
        for _, unit in ipairs(units) do
            if unit:IsRepeatQueue() then anyOn = true end
            if not unit:IsInCategory('FACTORY') and not unit:IsInCategory('EXTERNALFACTORY') then
                return nil
            end
        end
        return anyOn and REPEAT_OFF or REPEAT_ON
    end) then
        table.insert(hooked, 'ToggleRepeatBuild')
    end
    if okKeys and Wrap(keys, 'AbortNavigation', function()
        return Selection() and INTERRUPT or nil
    end) then
        table.insert(hooked, 'AbortNavigation')
    end

    -- The pause keys ('pause_unit' and friends). Hooked here rather than
    -- relying on SetPaused below, which was not seen to catch them in game.
    -- State is read before the toggle, as the function itself does.
    local okBuild, construction = pcall(import, '/lua/ui/game/construction.lua')
    if okBuild then
        local function PauseHook(key, decide)
            if Wrap(construction, key, function()
                local units = Selection()
                if not units then return nil end
                inPause = true
                return decide(units)
            end) then
                local wrapper = construction[key]
                construction[key] = function(a, b, c, d)
                    local ok, r1, r2, r3 = pcall(wrapper, a, b, c, d)
                    inPause = false
                    if not ok then error(r1, 0) end
                    return r1, r2, r3
                end
                installed[table.getn(installed)][4] = construction[key]
                table.insert(hooked, key)
            end
        end
        PauseHook('ToggleUnitPause', function(units)
            local okState, paused = pcall(GetIsPaused, units)
            if not okState then return nil end
            return paused and RESUMED or PAUSED
        end)
        PauseHook('ToggleUnitPauseAll', function() return PAUSED end)
        PauseHook('ToggleUnitUnpauseAll', function() return RESUMED end)
    end

    -- Copying a unit's orders: the copy-orders hotkey, and ctrl-assisting an
    -- engineer, both end in SimCallback { Func = 'CopyOrders' }.
    -- Distributing them: every 'spreadattack' key (distribute-queue.lua's
    -- DistributeOrders and DistributeOrdersOfMouseContext) ends in
    -- SimCallback { Func = 'DistributeOrders' }, sent only when the unit had
    -- orders to give out.
    if Wrap(_G, 'SimCallback', function(callback)
        if type(callback) ~= 'table' then
            return nil
        end
        if callback.Func == 'CopyOrders' then
            return COPY
        end
        if callback.Func == 'DistributeOrders' then
            return DISTRIBUTE
        end
        return nil
    end) then
        table.insert(hooked, 'SimCallback')
    end

    -- Everything else that pauses: the pause button, other mods. Quiet while a
    -- pause key above is already reporting.
    if Wrap(_G, 'SetPaused', function(units, paused)
        if inPause or not HasUnits(units) then return nil end
        return paused and PAUSED or RESUMED
    end) then
        table.insert(hooked, 'SetPaused')
    end

    return hooked
end

--- Put everything back as it was. Only undoes a hook that is still ours: if
--- something else has since wrapped the function, leave its wrapper be.
function Uninstall()
    for i = table.getn(installed), 1, -1 do
        local entry = installed[i]
        if entry[1][entry[2]] == entry[4] then
            entry[1][entry[2]] = entry[3]
        end
        installed[i] = nil
    end
    installed = {}
    notify = false
    inSoftStop = false
    inPause = false
end
