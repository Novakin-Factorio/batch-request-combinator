local Constants = require("runtime.constants")

local Util = {}

local function readable_name(value)
  return value.name
end

function Util.quality_name(quality)
  if type(quality) == "string" then return quality end
  if quality ~= nil then
    local readable, name = pcall(readable_name, quality)
    if readable and type(name) == "string" then return name end
  end
  return "normal"
end

function Util.item_key(name, quality)
  return name .. Constants.KEY_SEPARATOR .. (quality or "normal")
end

function Util.split_item_key(key)
  local separator = string.find(key, Constants.KEY_SEPARATOR, 1, true)
  if not separator then return key, "normal" end
  return string.sub(key, 1, separator - 1), string.sub(key, separator + 1)
end

function Util.sorted_keys(values)
  local keys = {}
  for key in pairs(values) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

function Util.copy_items(items)
  local copy = {}
  for index, item in ipairs(items or {}) do
    copy[index] = {
      name = item.name,
      quality = item.quality or "normal",
      count = item.count,
      key = Util.item_key(item.name, item.quality or "normal"),
    }
  end
  return copy
end

function Util.items_to_map(items)
  local result = {}
  for _, item in ipairs(items or {}) do
    result[Util.item_key(item.name, item.quality)] = item.count
  end
  return result
end

function Util.items_signature(items)
  local parts = {}
  for _, item in ipairs(items or {}) do
    parts[#parts + 1] = table.concat({
      item.name,
      item.quality or "normal",
      tostring(item.count),
    }, Constants.KEY_SEPARATOR)
  end
  return table.concat(parts, Constants.SIGNATURE_SEPARATOR)
end

function Util.is_same_force_and_surface(left, right)
  return left.surface.index == right.surface.index and left.force.index == right.force.index
end

function Util.valid_entity(entity)
  return entity and entity.valid and entity.unit_number ~= nil
end

function Util.localised_error(code, detail)
  local key = Constants.ERROR_LOCALE[code] or "batch-request-combinator-error.unknown"
  if detail and code == Constants.ERROR.INTERNAL then return {key, detail} end
  if detail then return {"", {key}, " (", detail, ")"} end
  return {key}
end

local function stable_value_signature(value, seen)
  local value_type = type(value)
  if value_type == "nil" or value_type == "boolean" or value_type == "number"
    or value_type == "string" then
    return value_type .. ":" .. tostring(value)
  end
  if value_type == "table" then
    seen = seen or {}
    if seen[value] then return "table:<cycle>" end
    seen[value] = true
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right)
      local left_type, right_type = type(left), type(right)
      if left_type ~= right_type then return left_type < right_type end
      return tostring(left) < tostring(right)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = stable_value_signature(key, seen)
        .. "=" .. stable_value_signature(value[key], seen)
    end
    seen[value] = nil
    return "table:{" .. table.concat(parts, ",") .. "}"
  end
  local unit_readable, unit_number = pcall(function() return value.unit_number end)
  if unit_readable and type(unit_number) == "number" then
    return value_type .. ":unit=" .. tostring(unit_number)
  end
  local name_readable, name = pcall(function() return value.name end)
  if name_readable and type(name) == "string" then return value_type .. ":name=" .. name end
  return value_type
end

function Util.error_signature(code, detail)
  return tostring(code) .. Constants.SIGNATURE_SEPARATOR .. stable_value_signature(detail)
end

return Util
