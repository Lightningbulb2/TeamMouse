--******************************************************************************
--** Mouse -- modules/legacyprotocol.lua
--**
--** Adapter for SharedMouse v2's unversioned wire format.
--******************************************************************************

local CursorData = import(_G.TeamMousePath .. '/modules/cursordata.lua')

local LegacyOrderNames = {
    'selectable', 'selectable-invalid', 'attack', 'attack-invalid',
    'attack_coordinated', 'capture', 'capture-invalid', 'construct',
    'construct-invalid', 'ferry', 'ferry-invalid', 'guard', 'guard-invalid',
    'launch', 'launch-invalid', 'load', 'load-invalid', 'message', 'move',
    'move-invalid', 'move_window', 'n_s', 'ne_sw', 'nw_se', 'w_e',
    'overcharge_grey', 'patrol', 'patrol-invalid', 'reclaim',
    'reclaim-invalid', 'repair', 'repair-invalid', 'sacrifice', 'transport',
    'transport-invalid', 'unload', 'unload-invalid', 'waypoint-drag',
    'waypoint-hover', 'attack-coordinated-invalid',
}

local LegacyOrderIndices = {
    ['selectable'] = 1,
    ['selectable-invalid'] = 2,
    ['attack'] = 3,
    ['attack_move'] = 3,
    ['attack-invalid'] = 4,
    ['attack_coordinated'] = 5,
    ['attack-coordinated'] = 5,
    ['capture'] = 6,
    ['capture-invalid'] = 7,
    ['construct'] = 8,
    ['construct02'] = 8,
    ['construct-invalid'] = 9,
    ['ferry'] = 10,
    ['ferry-invalid'] = 11,
    ['guard'] = 12,
    ['guard-invalid'] = 13,
    ['launch'] = 14,
    ['launch-invalid'] = 15,
    ['load'] = 16,
    ['load-invalid'] = 17,
    ['message'] = 18,
    ['move'] = 19,
    ['move-invalid'] = 20,
    ['move_window'] = 21,
    ['n_s'] = 22,
    ['ne_sw'] = 23,
    ['nw_se'] = 24,
    ['w_e'] = 25,
    ['overcharge'] = 26,
    ['overcharge_grey'] = 26,
    ['overcharge_orange'] = 26,
    ['patrol'] = 27,
    ['patrol-invalid'] = 28,
    ['reclaim'] = 29,
    ['reclaim02'] = 29,
    ['reclaim-disabled'] = 29,
    ['reclaim-invalid'] = 30,
    ['repair'] = 31,
    ['repair-invalid'] = 32,
    ['sacrifice'] = 33,
    ['transport'] = 34,
    ['transport-invalid'] = 35,
    ['unload'] = 36,
    ['unload-invalid'] = 37,
    ['waypoint-drag'] = 38,
    ['waypoint-hover'] = 39,
    ['attack-coordinated-invalid'] = 40,
}

local function IsFiniteNumber(value)
    return type(value) == 'number' and value == value
        and value >= -100000 and value <= 100000
end

MarkerField = 'mouseProtocol'

---@param protocol number
---@return table
function CreatePacket(protocol)
    return { a = true, b = { 0, 0, 0, 1 }, mouseProtocol = protocol }
end

---@param packet table
---@param x number
---@param y number
---@param z number
---@param mouseOrderIndex number
function PopulatePacket(packet, x, y, z, mouseOrderIndex)
    local key = CursorData.OrderNames[mouseOrderIndex]
    packet.b[1], packet.b[2], packet.b[3] = x, y, z
    packet.b[4] = LegacyOrderIndices[key] or 1
end

---@param msg table
---@return number | nil, number | nil, number | nil, number | nil
function DecodePacket(msg)
    if type(msg) ~= 'table' or msg[MarkerField] ~= nil or msg.a ~= true then
        return nil, nil, nil, nil
    end

    local data = msg.b
    if type(data) ~= 'table'
        or not IsFiniteNumber(data[1])
        or not IsFiniteNumber(data[2])
        or not IsFiniteNumber(data[3]) then
        return nil, nil, nil, nil
    end

    local legacyIndex = data[4]
    if type(legacyIndex) ~= 'number' or legacyIndex ~= math.floor(legacyIndex)
        or legacyIndex < 1 or legacyIndex > table.getn(LegacyOrderNames) then
        legacyIndex = 1
    end

    local key = LegacyOrderNames[legacyIndex] or 'selectable'
    return data[1], data[2], data[3], CursorData.IndexFromKey(key)
end

