--******************************************************************************
--** TeamMouse -- extras/wire_size.lua
--**
--** Estimates how many bytes a chat message costs on the wire. FA's own
--** serialisation isn't documented, so this is a generic binary model: a type
--** byte per value, 4-byte numbers (FA's Lua numbers are 32-bit floats),
--** length-prefixed strings, and a table as its entries plus an end marker.
--** Good for comparing one packet layout with another; the absolute numbers
--** are an estimate.
--******************************************************************************

local M = {}

function M.Size(v)
    local t = type(v)
    if t == 'nil' then return 1 end
    if t == 'boolean' then return 2 end
    if t == 'number' then return 5 end
    if t == 'string' then return 3 + string.len(v) end
    if t == 'table' then
        local n = 2
        for k, x in pairs(v) do
            n = n + M.Size(k) + M.Size(x)
        end
        return n
    end
    return 1
end

return M
