local Constants = require("runtime.constants")
local Util = require("runtime.util")

local CircuitInput = {}
local EMPTY_SNAPSHOT = {
  items = {},
  total = 0,
  signature = "",
  invalid_quantity = false,
  has_input = false,
}
local EMPTY_OBSERVATION = {
  invalid_quantity = false,
  has_input = false,
}

local function normalized_count(count, sign_mode)
  if sign_mode == Constants.SIGN_MODE.POSITIVE then
    return count > 0 and count or 0
  end
  if sign_mode == Constants.SIGN_MODE.NEGATIVE then
    return count < 0 and -count or 0
  end
  return count ~= 0 and math.abs(count) or 0
end

local function aggregate(signals, item_exists, quality_exists)
  if not signals or next(signals) == nil then return nil end
  local raw
  for _, circuit_signal in pairs(signals) do
    local signal = circuit_signal.signal
    if signal and (signal.type == nil or signal.type == "item") and signal.name then
      local quality = signal.quality or "normal"
      if item_exists(signal.name) and quality_exists(quality) then
        raw = raw or {}
        local key = Util.item_key(signal.name, quality)
        raw[key] = (raw[key] or 0) + circuit_signal.count
      end
    end
  end
  return raw
end

function CircuitInput.snapshot(signals, sign_mode, item_exists, quality_exists)
  local raw = aggregate(signals, item_exists, quality_exists)
  if not raw then return EMPTY_SNAPSHOT end

  local items = {}
  local total = 0
  local invalid_quantity = false
  local has_input = false
  for _, key in ipairs(Util.sorted_keys(raw)) do
    local count = normalized_count(raw[key], sign_mode)
    if count > 0 then has_input = true end
    if count > Constants.MAX_REQUEST_VALUE then
      invalid_quantity = true
    elseif count > 0 then
      local name, quality = Util.split_item_key(key)
      items[#items + 1] = {name = name, quality = quality, count = count}
      total = total + count
    end
  end

  return {
    items = items,
    total = total,
    signature = Util.items_signature(items),
    invalid_quantity = invalid_quantity,
    has_input = has_input,
  }
end

function CircuitInput.observe(signals, sign_mode, expected_items, item_exists, quality_exists)
  local raw = aggregate(signals, item_exists, quality_exists)
  if not raw then return EMPTY_OBSERVATION end

  local invalid_quantity = false
  local has_input = false
  local identity_count = 0
  for _, raw_count in pairs(raw) do
    local count = normalized_count(raw_count, sign_mode)
    if count > 0 then
      has_input = true
      identity_count = identity_count + 1
      if count > Constants.MAX_REQUEST_VALUE then invalid_quantity = true end
    end
  end
  if not has_input then return EMPTY_OBSERVATION end

  local matches_expected
  if expected_items then
    matches_expected = not invalid_quantity and identity_count == #expected_items
    if matches_expected then
      for _, item in ipairs(expected_items) do
        local key = item.key
        if not key then
          key = Util.item_key(item.name, item.quality or "normal")
          item.key = key
        end
        if normalized_count(raw[key] or 0, sign_mode) ~= item.count then
          matches_expected = false
          break
        end
      end
    end
  end

  return {
    invalid_quantity = invalid_quantity,
    has_input = true,
    matches_expected = matches_expected,
  }
end

local function runtime_item_exists(name)
  return prototypes.item[name] ~= nil
end

local function runtime_quality_exists(name)
  return prototypes.quality[name] ~= nil
end

function CircuitInput.read(entity, sign_mode)
  local connector = defines.wire_connector_id
  local signals = entity.get_signals(
    connector.combinator_input_red,
    connector.combinator_input_green
  )
  return CircuitInput.snapshot(
    signals,
    sign_mode,
    runtime_item_exists,
    runtime_quality_exists
  )
end

function CircuitInput.read_active(entity, sign_mode, expected_items)
  local connector = defines.wire_connector_id
  local signals = entity.get_signals(
    connector.combinator_input_red,
    connector.combinator_input_green
  )
  return CircuitInput.observe(
    signals,
    sign_mode,
    expected_items,
    runtime_item_exists,
    runtime_quality_exists
  )
end

return CircuitInput
