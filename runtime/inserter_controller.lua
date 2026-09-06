local Constants = require("runtime.constants")
local Registry = require("runtime.registry")
local TargetDiscovery = require("runtime.target_discovery")
local Util = require("runtime.util")

local InserterController = {}

local function debug_enabled()
  local setting = settings and settings.global and settings.global[Constants.SETTING_DEBUG]
  return setting and setting.value == true
end

local function diagnostic(subject, reason)
  local record = type(subject) == "table" and subject.entity and subject or nil
  local entity = record and record.entity or subject
  local valid = entity and entity.valid == true
  local name = valid and entity.localised_name or (record and record.diagnostic_name)
  local unit_number = valid and entity.unit_number or (record and record.unit_number)
  local position = valid and entity.position or nil
  local x = position and position.x or (record and record.diagnostic_x)
  local y = position and position.y or (record and record.diagnostic_y)
  if not debug_enabled() then
    return {
      "batch-request-combinator.inserter-diagnostic-compact",
      reason,
      name or {"batch-request-combinator.gui-invalid-target"},
    }
  end
  return {
    "batch-request-combinator.inserter-diagnostic",
    reason,
    name or {"batch-request-combinator.gui-invalid-target"},
    unit_number or "?",
    type(x) == "number" and string.format("%.1f", x) or "?",
    type(y) == "number" and string.format("%.1f", y) or "?",
  }
end

local function setting_reason(field)
  return {"batch-request-combinator.inserter-diagnostic-setting", {
    "batch-request-combinator.inserter-setting-" .. field,
  }}
end

local function valid_mode(mode)
  return mode == Constants.TAIL_MODE.NO_TAIL
    or mode == Constants.TAIL_MODE.SINGLE
    or mode == Constants.TAIL_MODE.PARALLEL
end

local function count_reason(mode, count)
  local key = mode == Constants.TAIL_MODE.SINGLE
    and "batch-request-combinator.inserter-diagnostic-single-count"
    or "batch-request-combinator.inserter-diagnostic-parallel-count"
  return {key, count}
end

local function target_unit(target)
  return target and target.entity and target.entity.valid and target.entity.unit_number
    or (target and target.unit_number)
end

local function held_identity(inserter)
  local held = inserter and inserter.valid and inserter.held_stack or nil
  if not held or not held.valid_for_read or held.count <= 0 then return nil, 0 end
  return Util.item_key(held.name, Util.quality_name(held.quality)), held.count
end

local function filter_identity(filter)
  if type(filter) == "string" then return filter, "normal", "=" end
  if filter == nil then return nil end
  local readable, name = pcall(function() return filter.name end)
  if not readable then return nil end
  if type(name) ~= "string" then
    local named, prototype_name = pcall(function() return name.name end)
    name = named and prototype_name or nil
  end
  local quality = Util.quality_name(filter.quality)
  local comparator = filter.comparator or "="
  return name, quality, comparator
end

local function filters_signature(inserter)
  local parts = {}
  local keys = {}
  local slots = {}
  for index = 1, inserter.filter_slot_count or 0 do
    local filter = inserter.get_filter(index)
    if filter then
      local name, quality, comparator = filter_identity(filter)
      local key = name and Util.item_key(name, quality) or nil
      if not key or comparator ~= "=" or keys[key] then return nil end
      keys[key] = true
      slots[index] = {name = name, quality = quality}
      parts[#parts + 1] = tostring(index) .. "=" .. key .. ":" .. comparator
    end
  end
  return table.concat(parts, ";"), keys, slots
end

local function condition_signature(condition)
  if not condition then return nil end
  local first = condition.first_signal
  local second = condition.second_signal
  if not first or first.name ~= Constants.STATUS_SIGNAL.ready
    or (first.type and first.type ~= "virtual")
    or second ~= nil
    or condition.comparator ~= ">"
    or (condition.constant or 0) ~= 0 then
    return nil
  end
  return "ready>0"
end

local function input_networks(behavior)
  local selection = behavior.input_networks
  if selection == nil then return true, true end
  return selection.red ~= false, selection.green ~= false
end

local function input_network_signature(behavior)
  local red, green = input_networks(behavior)
  return (red and "red" or "") .. "+" .. (green and "green" or "")
end

local function capture_automatic_settings(inserter)
  local behavior = inserter.get_control_behavior()
  if not behavior or not behavior.valid then return nil, setting_reason("control-behavior") end
  if behavior.circuit_enable_disable ~= true then return nil, setting_reason("ready-control") end
  if behavior.connect_to_logistic_network ~= false then return nil, setting_reason("logistic-control") end
  if behavior.circuit_set_stack_size ~= false then return nil, setting_reason("circuit-stack") end
  if behavior.circuit_set_filters ~= false then return nil, setting_reason("circuit-filters") end
  local condition = condition_signature(behavior.circuit_condition)
  local filters, filter_keys, filter_slots = filters_signature(inserter)
  local pickup = inserter.inserter_target_pickup_count
  if not condition then return nil, setting_reason("ready-condition") end
  if filters == nil then return nil, setting_reason("filters") end
  if type(pickup) ~= "number" or pickup < 1 then return nil, setting_reason("pickup-count") end
  local input_red, input_green = input_networks(behavior)
  return {
    original_override = inserter.inserter_stack_size_override or 0,
    effective_pickup_count = pickup,
    condition_signature = condition,
    filters_signature = filters,
    filter_keys = filter_keys,
    filter_slots = filter_slots,
    filter_slot_count = inserter.filter_slot_count or 0,
    use_filters = inserter.use_filters == true,
    inserter_filter_mode = inserter.inserter_filter_mode,
    input_network_signature = input_network_signature(behavior),
    input_network_red = input_red,
    input_network_green = input_green,
  }
end

local function effective_transfer_size(record, item)
  local prototype = prototypes and prototypes.item and prototypes.item[item.name]
  local stack_size = prototype and prototype.stack_size
  if type(stack_size) ~= "number" or stack_size < 1 then return nil end
  return math.min(record.effective_pickup_count, stack_size)
end

local function transfer_sizes_match(instance, records)
  local reference = records[1]
  for _, item in ipairs(instance.captured or {}) do
    local expected = effective_transfer_size(reference, item)
    if expected then
      for index = 2, #records do
        local actual = effective_transfer_size(records[index], item)
        if actual ~= expected then
          return false, records[index], item, expected, actual
        end
      end
    end
  end
  return true
end

local function filters_cover_allocation(captured, allocation_keys)
  if not captured.use_filters then return next(captured.filter_keys or {}) == nil end
  if captured.inserter_filter_mode ~= "whitelist" then return false end
  for key in pairs(allocation_keys or {}) do
    if not captured.filter_keys[key] then return false end
  end
  for key in pairs(captured.filter_keys or {}) do
    if not allocation_keys[key] then return false end
  end
  return true
end

local function filter_slots_match(record, inserter)
  if not record.filter_slots then
    local signature, keys, slots = filters_signature(inserter)
    if signature == nil or signature ~= record.filters_signature then return false end
    record.filter_keys = keys
    record.filter_slots = slots
    record.filter_slot_count = inserter.filter_slot_count or 0
    return true
  end
  if (inserter.filter_slot_count or 0) ~= (record.filter_slot_count or 0) then return false end
  for index = 1, record.filter_slot_count or 0 do
    local expected = record.filter_slots[index]
    local filter = inserter.get_filter(index)
    if filter then
      local name, quality, comparator = filter_identity(filter)
      if not expected or comparator ~= "="
        or name ~= expected.name or quality ~= expected.quality then return false end
    elseif expected then
      return false
    end
  end
  return true
end

local function settings_match(record)
  local inserter = record.entity
  if not inserter or not inserter.valid or inserter.type ~= "inserter" then
    return false, {"batch-request-combinator.inserter-diagnostic-entity"}
  end
  local behavior = inserter.get_control_behavior()
  if not behavior or not behavior.valid then return false, setting_reason("control-behavior") end
  if behavior.circuit_enable_disable ~= true then return false, setting_reason("ready-control") end
  if behavior.connect_to_logistic_network ~= false then return false, setting_reason("logistic-control") end
  if behavior.circuit_set_stack_size ~= false then return false, setting_reason("circuit-stack") end
  if behavior.circuit_set_filters ~= false then return false, setting_reason("circuit-filters") end
  if condition_signature(behavior.circuit_condition) ~= record.condition_signature then
    return false, setting_reason("ready-condition")
  end
  if not filter_slots_match(record, inserter) then return false, setting_reason("filters") end
  if (inserter.inserter_stack_size_override or 0) ~= record.original_override then
    return false, setting_reason("stack-override"), true
  end
  if inserter.inserter_target_pickup_count ~= record.effective_pickup_count then
    return false, setting_reason("pickup-count")
  end
  if (inserter.use_filters == true) ~= record.use_filters then
    return false, setting_reason("use-filters")
  end
  if inserter.inserter_filter_mode ~= record.inserter_filter_mode then
    return false, setting_reason("filter-mode")
  end
  local input_red, input_green = input_networks(behavior)
  if record.input_network_red == nil or record.input_network_green == nil then
    if input_network_signature(behavior) ~= record.input_network_signature then
      return false, setting_reason("input-network")
    end
    record.input_network_red = input_red
    record.input_network_green = input_green
  elseif input_red ~= record.input_network_red or input_green ~= record.input_network_green then
    return false, setting_reason("input-network")
  end
  if record.filter_coverage_valid ~= true
    and not filters_cover_allocation(record, record.filter_allowed_by_key or {}) then
    return false, setting_reason("allocation-filters")
  end
  record.filter_coverage_valid = true
  return true
end

local function topology_matches(instance, record)
  local inserter = record.entity
  if not inserter or not inserter.valid or inserter.type ~= "inserter"
    or inserter.unit_number ~= record.unit_number
    or not Util.is_same_force_and_surface(inserter, instance.entity) then
    return false, {"batch-request-combinator.inserter-diagnostic-entity"}
  end
  local pickup = inserter.pickup_target
  if not pickup or not pickup.valid or pickup.unit_number ~= record.target_unit_number then
    return false, {"batch-request-combinator.inserter-diagnostic-pickup"}
  end
  if not TargetDiscovery.validate_cached_endpoint(
    instance.entity,
    inserter,
    record.topology_endpoints
  ) then
    return false, {"batch-request-combinator.inserter-diagnostic-endpoint"}
  end
  return true
end

local function validate_record(instance, record, mode, root)
  local topology_valid, topology_reason = topology_matches(instance, record)
  if not topology_valid then
    return false, Constants.ERROR.INSERTER_CONFIGURATION,
      diagnostic(record, topology_reason)
  end
  if mode ~= Constants.TAIL_MODE.NO_TAIL then
    if root.inserter_owners[record.unit_number] ~= instance.unit_number then
      return false, Constants.ERROR.INSERTER_OWNERSHIP, diagnostic(
        record,
        {"batch-request-combinator.inserter-diagnostic-ownership"}
      )
    end
    if not record.temporary_override then
      local settings_valid, settings_reason, ownership_change = settings_match(record)
      if not settings_valid then
        return false,
          ownership_change and Constants.ERROR.INSERTER_OWNERSHIP
            or Constants.ERROR.INSERTER_CONFIGURATION,
          diagnostic(record, settings_reason)
      end
    end
  end
  return true
end

local function allowed_item_keys(instance)
  if instance.captured_key_set then return instance.captured_key_set end
  local allowed = {}
  for _, item in ipairs(instance.captured or {}) do
    local key = item.key or Util.item_key(item.name, item.quality or "normal")
    item.key = key
    allowed[key] = true
  end
  instance.captured_key_set = allowed
  return allowed
end

local function record_by_unit(instance, unit_number)
  local indexed = instance.monitored_inserters_by_unit
  local record = indexed and indexed[unit_number] or nil
  if record and record.unit_number == unit_number then return record end
  for _, record in ipairs(instance.monitored_inserters or {}) do
    if record.unit_number == unit_number then
      indexed = indexed or {}
      instance.monitored_inserters_by_unit = indexed
      indexed[unit_number] = record
      return record
    end
  end
  return nil
end

local function rebuild_record_index(instance)
  local indexed = {}
  for _, record in ipairs(instance.monitored_inserters or {}) do
    indexed[record.unit_number] = record
  end
  instance.monitored_inserters_by_unit = indexed
end

local function clear_temporary(instance, record)
  Registry.root().temporary_overrides[record.unit_number] = nil
  record.temporary_override = nil
end

local function hand_position(inserter)
  local position = inserter.held_stack_position
  return position and position.x or nil, position and position.y or nil
end

local function release_motion_started(inserter, temporary, held_key, held_count)
  if held_key ~= temporary.held_key or held_count ~= temporary.held_count then return true end
  local x, y = hand_position(inserter)
  if x ~= temporary.hand_x or y ~= temporary.hand_y then return true end
  local waiting = defines and defines.entity_status and defines.entity_status.waiting_for_more_items
  return waiting ~= nil and temporary.status == waiting and inserter.status ~= waiting
end

local function has_section_tombstone(root, owner, target_unit_number)
  for _, tombstone in pairs(root.cleanup_tombstones or {}) do
    if tombstone.owner == owner and tombstone.target_unit_number == target_unit_number then return true end
  end
  return false
end

local function has_sibling_override_tombstone(root, current, owner, target_unit_number)
  for _, tombstone in pairs(root.override_tombstones or {}) do
    if tombstone ~= current and tombstone.owner == owner
      and tombstone.target_unit_number == target_unit_number then return true end
  end
  return false
end

local function release_tombstone_claims(root, unit_number, tombstone)
  if not tombstone.override_resolved
    or has_section_tombstone(root, tombstone.owner, tombstone.target_unit_number) then
    return false
  end
  if root.inserter_owners[tombstone.unit_number] == tombstone.owner then
    root.inserter_owners[tombstone.unit_number] = nil
  end
  local target_unit_number = tombstone.target_unit_number
  if target_unit_number and root.chest_owners[target_unit_number] == tombstone.owner
    and not has_section_tombstone(root, tombstone.owner, target_unit_number)
    and not has_sibling_override_tombstone(
      root,
      tombstone,
      tombstone.owner,
      target_unit_number
    ) then
    root.chest_owners[target_unit_number] = nil
  end
  root.override_tombstones[unit_number] = nil
  root.temporary_overrides[unit_number] = nil
  return true
end

local function restore_record(instance, record)
  local temporary = record.temporary_override
  if not temporary then return true end
  local inserter = record.entity
  if not inserter or not inserter.valid then
    clear_temporary(instance, record)
    return false, Constants.ERROR.TAIL_RESTORE_FAILED, diagnostic(
      record,
      {"batch-request-combinator.inserter-diagnostic-entity"}
    )
  end
  if inserter.type ~= "inserter" or inserter.unit_number ~= record.unit_number then
    return false, Constants.ERROR.INSERTER_OWNERSHIP, diagnostic(
      record,
      {"batch-request-combinator.inserter-diagnostic-entity"}
    )
  end
  if inserter.inserter_stack_size_override ~= temporary.written_override then
    clear_temporary(instance, record)
    return false, Constants.ERROR.INSERTER_OWNERSHIP, diagnostic(
      record,
      setting_reason("stack-override")
    )
  end
  local held_key, held_count = held_identity(inserter)
  local release_started = release_motion_started(inserter, temporary, held_key, held_count)
  local wrote = pcall(function() inserter.inserter_stack_size_override = record.original_override end)
  if not wrote or inserter.inserter_stack_size_override ~= record.original_override then
    return false, Constants.ERROR.TAIL_RESTORE_FAILED, diagnostic(
      record,
      setting_reason("stack-override")
    )
  end
  clear_temporary(instance, record)
  if release_started then
    record.tail_attempts = 0
    instance.tail_waiting_reason = nil
  else
    record.tail_attempts = (record.tail_attempts or 0) + 1
    if record.tail_attempts >= Constants.TAIL_MAX_ATTEMPTS then
      instance.manual_tail_recovery = true
      instance.tail_waiting_reason = "manual"
    end
  end
  return true
end

local function pending_for_target(target)
  local entity = target and target.entity
  local point = entity and entity.valid and entity.get_requester_point() or nil
  if not point or not point.valid then return true end
  for _, entries in ipairs({point.targeted_items_deliver, point.targeted_items_pickup}) do
    for _, entry in pairs(entries or {}) do
      if entry.count and entry.count > 0 then return true end
    end
  end
  return false
end

local function chest_has_identity(target, key)
  local entity = target and target.entity
  local inventory = entity and entity.valid and entity.get_inventory(defines.inventory.chest) or nil
  if not inventory or not inventory.valid then return true end
  for _, item in pairs(inventory.get_contents()) do
    if Util.item_key(item.name, Util.quality_name(item.quality)) == key and item.count > 0 then return true end
  end
  return false
end

local function destination_blocked(inserter)
  local statuses = defines and defines.entity_status
  return statuses and statuses.waiting_for_space_in_destination
    and inserter.status == statuses.waiting_for_space_in_destination
end

local function setup_candidates(instance)
  local targets, inserters, endpoints_by_unit = TargetDiscovery.discover(instance.entity)
  if #targets == 0 then return nil, nil, Constants.ERROR.NO_TARGETS end
  local root = Registry.root()
  local target_units = {}
  local candidate_count_by_target = {}
  local signature_parts = {"m:" .. tostring(instance.tail_mode)}
  for _, target in ipairs(targets) do
    local owner = root.chest_owners[target.unit_number]
    if owner then
      return nil, nil, Constants.ERROR.TARGET_CONFLICT, target.entity.localised_name
    end
    target_units[target.unit_number] = true
    candidate_count_by_target[target.unit_number] = 0
    signature_parts[#signature_parts + 1] = "t:" .. tostring(target.unit_number)
  end
  local candidates = {}
  local connected_networks_by_unit = {}
  for _, inserter in ipairs(inserters) do
    local pickup = inserter and inserter.valid and inserter.pickup_target or nil
    if pickup and pickup.valid and target_units[pickup.unit_number]
      and Util.is_same_force_and_surface(inserter, instance.entity) then
      local owner = root.inserter_owners[inserter.unit_number]
      if owner then
        return nil, nil, Constants.ERROR.INSERTER_OWNERSHIP, diagnostic(
          inserter,
          {"batch-request-combinator.inserter-diagnostic-ownership"}
        )
      end
      local endpoints = endpoints_by_unit[inserter.unit_number]
      local connected, red, green = TargetDiscovery.connected_input_networks(
        instance.entity,
        inserter,
        endpoints
      )
      if not connected then
        return nil, nil, Constants.ERROR.INSERTER_CONFIGURATION, diagnostic(
          inserter,
          {"batch-request-combinator.inserter-diagnostic-endpoint"}
        )
      end
      candidates[#candidates + 1] = inserter
      candidate_count_by_target[pickup.unit_number] = candidate_count_by_target[pickup.unit_number] + 1
      connected_networks_by_unit[inserter.unit_number] = {red = red, green = green}
    end
  end
  table.sort(candidates, function(left, right) return left.unit_number < right.unit_number end)
  if instance.tail_mode == Constants.TAIL_MODE.SINGLE then
    for _, target in ipairs(targets) do
      local count = candidate_count_by_target[target.unit_number]
      if count ~= 1 then
        return nil, nil, Constants.ERROR.INSERTER_CONFIGURATION, diagnostic(
          target.entity,
          count_reason(Constants.TAIL_MODE.SINGLE, count)
        )
      end
    end
  end
  if #candidates == 0 then return nil, nil, Constants.ERROR.INSERTER_CONFIGURATION end
  for _, inserter in ipairs(candidates) do
    signature_parts[#signature_parts + 1] = "i:" .. tostring(inserter.unit_number)
  end
  return candidates, table.concat(signature_parts, ";"), nil, nil, connected_networks_by_unit
end

local function setup_snapshot(inserter, connected_networks)
  local behavior = inserter.get_control_behavior()
  if not behavior or not behavior.valid then return nil end
  local filters = {}
  for index = 1, inserter.filter_slot_count or 0 do filters[index] = inserter.get_filter(index) end
  local network_selection = behavior.input_networks
  local input_red, input_green = input_networks(behavior)
  local desired_red, desired_green = input_red, input_green
  if network_selection ~= nil then
    desired_red, desired_green = connected_networks.red, connected_networks.green
  end
  local position = inserter.position
  return {
    entity = inserter,
    unit_number = inserter.unit_number,
    diagnostic_name = inserter.localised_name,
    diagnostic_x = position and position.x,
    diagnostic_y = position and position.y,
    behavior = behavior,
    circuit_enable_disable = behavior.circuit_enable_disable,
    circuit_condition = behavior.circuit_condition,
    connect_to_logistic_network = behavior.connect_to_logistic_network,
    circuit_set_stack_size = behavior.circuit_set_stack_size,
    circuit_set_filters = behavior.circuit_set_filters,
    input_networks_supported = network_selection ~= nil,
    input_network_red = input_red,
    input_network_green = input_green,
    desired_input_network_red = desired_red,
    desired_input_network_green = desired_green,
    stack_size_override = inserter.inserter_stack_size_override or 0,
    filter_slot_count = inserter.filter_slot_count or 0,
    use_filters = inserter.use_filters == true,
    filters = filters,
  }
end

local function clear_setup_filters(inserter)
  for index = 1, inserter.filter_slot_count or 0 do inserter.set_filter(index, nil) end
end

local function setup_signals_equal(left, right)
  if left == nil or right == nil then return left == right end
  return left.name == right.name
    and (left.type or "item") == (right.type or "item")
    and Util.quality_name(left.quality) == Util.quality_name(right.quality)
end

local function setup_conditions_equal(left, right)
  if left == nil or right == nil then return left == right end
  if not setup_signals_equal(left.first_signal, right.first_signal)
    or not setup_signals_equal(left.second_signal, right.second_signal)
    or (left.comparator or "<") ~= (right.comparator or "<") then
    return false
  end
  return left.second_signal ~= nil or (left.constant or 0) == (right.constant or 0)
end

local function setup_filters_equal(left, right)
  if left == nil or right == nil then return left == right end
  local left_name, left_quality, left_comparator = filter_identity(left)
  local right_name, right_quality, right_comparator = filter_identity(right)
  return left_name ~= nil and right_name ~= nil
    and left_name == right_name
    and left_quality == right_quality
    and left_comparator == right_comparator
end

local function setup_snapshot_matches(snapshot)
  local readable, matches = pcall(function()
    local inserter = snapshot.entity
    if not inserter.valid or inserter.unit_number ~= snapshot.unit_number then return false end
    local behavior = inserter.get_control_behavior()
    if not behavior or not behavior.valid then return false end
    local network_selection = behavior.input_networks
    local input_red, input_green = input_networks(behavior)
    if behavior.circuit_enable_disable ~= snapshot.circuit_enable_disable
      or not setup_conditions_equal(behavior.circuit_condition, snapshot.circuit_condition)
      or behavior.connect_to_logistic_network ~= snapshot.connect_to_logistic_network
      or behavior.circuit_set_stack_size ~= snapshot.circuit_set_stack_size
      or behavior.circuit_set_filters ~= snapshot.circuit_set_filters
      or (network_selection ~= nil) ~= snapshot.input_networks_supported
      or input_red ~= snapshot.input_network_red
      or input_green ~= snapshot.input_network_green
      or (inserter.inserter_stack_size_override or 0) ~= snapshot.stack_size_override
      or (inserter.use_filters == true) ~= snapshot.use_filters
      or (inserter.filter_slot_count or 0) ~= snapshot.filter_slot_count then
      return false
    end
    for index = 1, snapshot.filter_slot_count do
      if not setup_filters_equal(inserter.get_filter(index), snapshot.filters[index]) then return false end
    end
    return true
  end)
  return readable and matches
end

local function restore_setup_snapshot(snapshot)
  local inserter = snapshot.entity
  local readable, behavior = pcall(function()
    if not inserter.valid or inserter.unit_number ~= snapshot.unit_number then return nil end
    return inserter.get_control_behavior()
  end)
  if not readable or not behavior or not behavior.valid then return false end
  local function attempt(callback) pcall(callback) end
  attempt(function() behavior.circuit_condition = snapshot.circuit_condition end)
  attempt(function() behavior.circuit_enable_disable = snapshot.circuit_enable_disable end)
  attempt(function() behavior.connect_to_logistic_network = snapshot.connect_to_logistic_network end)
  attempt(function() behavior.circuit_set_stack_size = snapshot.circuit_set_stack_size end)
  attempt(function() behavior.circuit_set_filters = snapshot.circuit_set_filters end)
  if snapshot.input_networks_supported then
    attempt(function()
      behavior.input_networks = {
        red = snapshot.input_network_red,
        green = snapshot.input_network_green,
      }
    end)
  end
  for index = 1, snapshot.filter_slot_count do
    attempt(function() inserter.set_filter(index, snapshot.filters[index]) end)
  end
  attempt(function() inserter.use_filters = snapshot.use_filters end)
  attempt(function() inserter.inserter_stack_size_override = snapshot.stack_size_override end)
  return setup_snapshot_matches(snapshot)
end

local function apply_setup(snapshot)
  return pcall(function()
    local inserter = snapshot.entity
    local behavior = snapshot.behavior
    behavior.circuit_condition = {
      first_signal = {type = "virtual", name = Constants.STATUS_SIGNAL.ready},
      comparator = ">",
      constant = 0,
    }
    behavior.circuit_enable_disable = true
    behavior.connect_to_logistic_network = false
    behavior.circuit_set_stack_size = false
    behavior.circuit_set_filters = false
    if snapshot.input_networks_supported
      and (snapshot.input_network_red ~= snapshot.desired_input_network_red
      or snapshot.input_network_green ~= snapshot.desired_input_network_green) then
      behavior.input_networks = {
        red = snapshot.desired_input_network_red,
        green = snapshot.desired_input_network_green,
      }
    end
    clear_setup_filters(inserter)
    inserter.use_filters = false
    local configured = capture_automatic_settings(inserter)
    if not configured or configured.use_filters or next(configured.filter_keys or {}) ~= nil
      or configured.input_network_red ~= snapshot.desired_input_network_red
      or configured.input_network_green ~= snapshot.desired_input_network_green
      or configured.original_override ~= snapshot.stack_size_override then
      error("inserter setup verification failed")
    end
  end)
end

function InserterController.preview_setup(instance)
  local candidates, signature, error_code, detail = setup_candidates(instance)
  if not candidates then return false, error_code, detail end
  return true, nil, nil, {inserter_count = #candidates, scope_signature = signature}
end

function InserterController.configure_setup(instance, expected_scope_signature)
  local candidates, signature, error_code, detail, connected_networks_by_unit = setup_candidates(instance)
  if not candidates then return false, error_code, detail end
  if signature ~= expected_scope_signature then
    return false, Constants.ERROR.INSERTER_SETUP_SCOPE_CHANGED
  end
  local snapshots = {}
  for index, inserter in ipairs(candidates) do
    local snapshot = setup_snapshot(inserter, connected_networks_by_unit[inserter.unit_number])
    if not snapshot then return false, Constants.ERROR.INSERTER_SETUP_FAILED, inserter.localised_name end
    snapshots[index] = snapshot
  end
  for index, snapshot in ipairs(snapshots) do
    local applied = apply_setup(snapshot)
    if not applied then
      local rollback_failure
      for restore_index = index, 1, -1 do
        local restore_snapshot = snapshots[restore_index]
        if not restore_setup_snapshot(restore_snapshot) and not rollback_failure then
          rollback_failure = restore_snapshot
        end
      end
      if rollback_failure then
        return false, Constants.ERROR.INSERTER_SETUP_FAILED, diagnostic(
          rollback_failure,
          {"batch-request-combinator.inserter-diagnostic-setup-rollback", rollback_failure.unit_number}
        )
      end
      return false, Constants.ERROR.INSERTER_SETUP_FAILED, snapshot.diagnostic_name
    end
  end
  return true, nil, nil, #candidates
end

local function eligibility(instance, record, allowed, request_observation, held_key, held_count)
  local mode = instance.captured_tail_mode or Constants.TAIL_MODE.NO_TAIL
  local may_control = mode == Constants.TAIL_MODE.PARALLEL
    or record.target_index == instance.tail_target_index
  if not may_control or record.temporary_override then return false, "not-tail" end
  local key, count = held_key, held_count
  if count == nil then key, count = held_identity(record.entity) end
  local transfer = key and record.transfer_by_key and record.transfer_by_key[key]
    or record.effective_pickup_count
  if not key or not allowed[key] or type(transfer) ~= "number" or count >= transfer then
    return false, "not-partial"
  end
  local observed = request_observation and request_observation.contents_by_target
    and request_observation.contents_by_target[record.target_unit_number] or nil
  if observed then
    if (observed.contents[key] or 0) > 0 then return false, "source-not-empty" end
    if observed.pending then return false, "targeted-activity" end
  else
    if chest_has_identity(record.target, key) then return false, "source-not-empty" end
    if pending_for_target(record.target) then return false, "targeted-activity" end
  end
  if destination_blocked(record.entity) then return false, "destination" end
  return true, nil, key, count
end

function InserterController.prepare(instance, targets, connected_inserters, mode, endpoints_by_unit)
  mode = valid_mode(mode) and mode or Constants.TAIL_MODE.NO_TAIL
  local by_target = {}
  for index, target in ipairs(targets) do
    local unit_number = target_unit(target)
    by_target[unit_number] = {index = index, target = target, inserters = {}}
  end
  local monitored = {}
  for _, inserter in ipairs(connected_inserters or {}) do
    if inserter and inserter.valid and inserter.type == "inserter"
      and Util.is_same_force_and_surface(inserter, instance.entity) then
      local pickup = inserter.pickup_target
      local match = pickup and pickup.valid and by_target[pickup.unit_number] or nil
      if match then
        local position = inserter.position
        local record = {
          entity = inserter,
          unit_number = inserter.unit_number,
          diagnostic_name = inserter.localised_name,
          diagnostic_x = position and position.x,
          diagnostic_y = position and position.y,
          target = match.target,
          target_index = match.index,
          target_unit_number = pickup.unit_number,
          controlled = mode ~= Constants.TAIL_MODE.NO_TAIL,
          tail_attempts = 0,
          topology_endpoints = endpoints_by_unit and endpoints_by_unit[inserter.unit_number] or nil,
        }
        monitored[#monitored + 1] = record
        match.inserters[#match.inserters + 1] = record
      end
    end
  end
  table.sort(monitored, function(left, right) return left.unit_number < right.unit_number end)

  local root = Registry.root()
  for _, target in ipairs(targets) do
    local match = by_target[target_unit(target)]
    local count = #match.inserters
    if (mode == Constants.TAIL_MODE.SINGLE and count ~= 1)
      or (mode == Constants.TAIL_MODE.PARALLEL and count < 1) then
      return nil, Constants.ERROR.INSERTER_CONFIGURATION, diagnostic(
        target.entity,
        count_reason(mode, count)
      )
    end
    for _, record in ipairs(match.inserters) do
      local _, held_count = held_identity(record.entity)
      if held_count > 0 then
        return nil, Constants.ERROR.INSERTER_NOT_EMPTY, diagnostic(
          record,
          {"batch-request-combinator.inserter-diagnostic-hand"}
        )
      end
      local topology_valid, topology_reason = topology_matches(instance, record)
      if not topology_valid then
        return nil, Constants.ERROR.INSERTER_CONFIGURATION,
          diagnostic(record, topology_reason)
      end
      if mode ~= Constants.TAIL_MODE.NO_TAIL then
        local owner = root.inserter_owners[record.unit_number]
        if owner and owner ~= instance.unit_number then
          return nil, Constants.ERROR.INSERTER_OWNERSHIP, diagnostic(
            record,
            {"batch-request-combinator.inserter-diagnostic-ownership"}
          )
        end
        local captured, capture_reason = capture_automatic_settings(record.entity)
        if not captured then
          return nil, Constants.ERROR.INSERTER_CONFIGURATION,
            diagnostic(record, capture_reason)
        end
        for key, value in pairs(captured) do record[key] = value end
      end
    end
    if mode ~= Constants.TAIL_MODE.NO_TAIL then
      local compatible, incompatible_record, item, expected, actual = transfer_sizes_match(
        instance,
        match.inserters
      )
      if not compatible then
        return nil, Constants.ERROR.INSERTER_CONFIGURATION,
          diagnostic(incompatible_record, {
            "batch-request-combinator.inserter-diagnostic-transfer-size-detail",
            item.name,
            item.quality or "normal",
            expected,
            actual or "?",
          })
      end
    end
  end
  instance.monitored_inserters = monitored
  rebuild_record_index(instance)
  instance.inserters = {}
  return monitored
end

function InserterController.claim(instance)
  if instance.captured_tail_mode == Constants.TAIL_MODE.NO_TAIL then return true end
  local root = Registry.root()
  for _, record in ipairs(instance.monitored_inserters or {}) do
    local owner = root.inserter_owners[record.unit_number]
    if owner and owner ~= instance.unit_number then
      return false, diagnostic(
        record,
        {"batch-request-combinator.inserter-diagnostic-ownership"}
      )
    end
  end
  for _, record in ipairs(instance.monitored_inserters or {}) do
    root.inserter_owners[record.unit_number] = instance.unit_number
  end
  return true
end

function InserterController.apply_plan(instance, descriptors)
  local mode = instance.captured_tail_mode or Constants.TAIL_MODE.NO_TAIL
  if mode == Constants.TAIL_MODE.NO_TAIL then
    return true
  end
  for _, record in ipairs(instance.monitored_inserters or {}) do
    local target = instance.targets and instance.targets[record.target_index]
    local descriptor = descriptors and descriptors[record.target_index]
    if not target or not target.allocation or not descriptor then return false end
    local allowed = {}
    for key, count in pairs(target.allocation.by_key or {}) do
      if count > 0 then allowed[key] = true end
    end
    record.filter_allowed_by_key = allowed
    record.filter_coverage_valid = nil
    record.transfer_by_key = descriptor.transfer_by_key or {}
    local topology_valid, topology_reason = topology_matches(instance, record)
    if not topology_valid then
      return false, Constants.ERROR.INSERTER_CONFIGURATION, diagnostic(record, topology_reason)
    end
    local settings_valid, settings_reason, ownership_change = settings_match(record)
    if not settings_valid then
      return false,
        ownership_change and Constants.ERROR.INSERTER_OWNERSHIP
          or Constants.ERROR.INSERTER_CONFIGURATION,
        diagnostic(record, settings_reason)
    end
  end
  return true
end

function InserterController.validate(instance, mode_override, include_hand_detail)
  local mode = mode_override or instance.captured_tail_mode or Constants.TAIL_MODE.NO_TAIL
  if mode == Constants.TAIL_MODE.NO_TAIL then
    return InserterController.validate_passive(instance, include_hand_detail)
  end
  local root = Registry.root()
  local hands_empty = true
  local hand_detail
  local has_temporary = false
  for _, record in ipairs(instance.monitored_inserters or {}) do
    local valid, error_code, detail = validate_record(instance, record, mode, root)
    if not valid then return false, error_code, detail end
    local _, held_count = held_identity(record.entity)
    if held_count > 0 and hands_empty then
      hands_empty = false
      if include_hand_detail then
        hand_detail = diagnostic(record, {"batch-request-combinator.inserter-diagnostic-hand"})
      end
    end
    if record.temporary_override then has_temporary = true end
  end
  return true, nil, nil, hands_empty, hand_detail, has_temporary
end

function InserterController.validate_passive(instance, include_hand_detail)
  local hands_empty = true
  local hand_detail
  for _, record in ipairs(instance.monitored_inserters or {}) do
    local topology_valid, topology_reason = topology_matches(instance, record)
    if not topology_valid then
      return false, Constants.ERROR.INSERTER_CONFIGURATION,
        diagnostic(record, topology_reason)
    end
    local _, held_count = held_identity(record.entity)
    if held_count > 0 and hands_empty then
      hands_empty = false
      if include_hand_detail then
        hand_detail = diagnostic(record, {"batch-request-combinator.inserter-diagnostic-hand"})
      end
    end
  end
  return true, nil, nil, hands_empty, hand_detail, false
end

function InserterController.hands_empty(instance)
  for _, record in ipairs(instance.monitored_inserters or {}) do
    local _, count = held_identity(record.entity)
    if count > 0 then
      return false, diagnostic(record, {"batch-request-combinator.inserter-diagnostic-hand"})
    end
  end
  return true
end

function InserterController.has_temporary(instance)
  for _, record in ipairs(instance.monitored_inserters or {}) do
    if record.temporary_override then return true end
  end
  return false
end

function InserterController.process_scheduled(instance, request_observation)
  local mode = instance.captured_tail_mode or Constants.TAIL_MODE.NO_TAIL
  if mode == Constants.TAIL_MODE.NO_TAIL then
    return InserterController.validate_passive(instance)
  end
  local root = Registry.root()
  local may_control = mode ~= Constants.TAIL_MODE.NO_TAIL and not instance.manual_tail_recovery
  local allowed = may_control and allowed_item_keys(instance) or nil
  local hands_empty = true
  local has_temporary = false
  local candidates
  local wrote_any = false
  local blocked = false
  for _, record in ipairs(instance.monitored_inserters or {}) do
    local valid, error_code, detail = validate_record(instance, record, mode, root)
    if not valid then return false, error_code, detail end
    local key, count = held_identity(record.entity)
    if count > 0 and hands_empty then
      hands_empty = false
    end
    if record.temporary_override then has_temporary = true end
    if may_control then
      local eligible, reason = eligibility(
        instance,
        record,
        allowed,
        request_observation,
        key,
        count
      )
      if reason == "destination" then
        blocked = true
      elseif eligible then
        candidates = candidates or {}
        candidates[#candidates + 1] = {record = record, key = key, count = count}
      end
    end
  end
  for _, candidate in ipairs(candidates or {}) do
    local record = candidate.record
    local key = candidate.key
    local count = candidate.count
    if record.entity.inserter_stack_size_override ~= record.original_override then
      return false, Constants.ERROR.INSERTER_OWNERSHIP, diagnostic(
        record,
        setting_reason("stack-override")
      )
    else
      local hand_x, hand_y = hand_position(record.entity)
      local status = record.entity.status
      local wrote = pcall(function() record.entity.inserter_stack_size_override = count end)
      if not wrote or record.entity.inserter_stack_size_override ~= count then
        return false, Constants.ERROR.TAIL_RESTORE_FAILED, diagnostic(
          record,
          setting_reason("stack-override")
        )
      end
      record.temporary_override = {
        written_override = count,
        written_tick = game.tick,
        held_key = key,
        held_count = count,
        hand_x = hand_x,
        hand_y = hand_y,
        status = status,
      }
      root.temporary_overrides[record.unit_number] = instance.unit_number
      has_temporary = true
      wrote_any = true
    end
  end
  if blocked then
    instance.tail_waiting_reason = "destination"
  elseif wrote_any then
    instance.tail_waiting_reason = "tail"
  elseif instance.tail_waiting_reason ~= "manual" then
    instance.tail_waiting_reason = nil
  end
  return true, nil, nil, hands_empty, nil, has_temporary
end

local function report_detached_ownership_conflict(tombstone, inserter)
  if tombstone.ownership_conflict_reported then return end
  tombstone.ownership_conflict_reported = true
  local force = inserter and inserter.valid and inserter.force or nil
  if force and force.print then
    force.print{
      "batch-request-combinator.message-error",
      {"entity-name.batch-request-combinator"},
      Util.localised_error(Constants.ERROR.INSERTER_OWNERSHIP, diagnostic(
        tombstone,
        {"batch-request-combinator.inserter-diagnostic-ownership"}
      )),
    }
  end
end

function InserterController.process_temporary_overrides()
  local root = Registry.root()
  local units = {}
  for unit_number in pairs(root.temporary_overrides) do units[#units + 1] = unit_number end
  table.sort(units)
  local failures = {}
  for _, unit_number in ipairs(units) do
    local tombstone = root.override_tombstones[unit_number]
    if tombstone then
      local inserter = tombstone.entity
      local owner_instance = (root.instances or {})[tombstone.owner]
      if not tombstone.override_resolved and game.tick > (tombstone.written_tick or -1) then
        if not inserter or not inserter.valid then
          tombstone.override_resolved = true
        elseif inserter.type ~= "inserter" or inserter.unit_number ~= tombstone.unit_number then
          tombstone.identity_conflict = true
          if owner_instance then
            failures[#failures + 1] = {
              instance = owner_instance,
              error_code = Constants.ERROR.INSERTER_OWNERSHIP,
              detail = diagnostic(
                tombstone,
                {"batch-request-combinator.inserter-diagnostic-ownership"}
              ),
            }
          else
            report_detached_ownership_conflict(tombstone, inserter)
          end
        elseif inserter.inserter_stack_size_override ~= tombstone.written_override then
          tombstone.override_resolved = true
          if owner_instance then
            failures[#failures + 1] = {
              instance = owner_instance,
              error_code = Constants.ERROR.INSERTER_OWNERSHIP,
              detail = diagnostic(
                tombstone,
                {"batch-request-combinator.inserter-diagnostic-ownership"}
              ),
            }
          else
            report_detached_ownership_conflict(tombstone, inserter)
          end
        else
          local wrote = pcall(function() inserter.inserter_stack_size_override = tombstone.original_override end)
          tombstone.override_resolved = wrote
            and inserter.inserter_stack_size_override == tombstone.original_override
        end
      end
      if tombstone.override_resolved then
        root.temporary_overrides[unit_number] = nil
        release_tombstone_claims(root, unit_number, tombstone)
      end
    else
      local owner = root.temporary_overrides[unit_number]
      local instance = owner and root.instances[owner] or nil
      local record = instance and record_by_unit(instance, unit_number) or nil
      if not instance or not record or not record.temporary_override then
        root.temporary_overrides[unit_number] = nil
      elseif game.tick > record.temporary_override.written_tick then
        local restored, error_code, detail = restore_record(instance, record)
        if not restored then
          failures[#failures + 1] = {instance = instance, error_code = error_code, detail = detail}
        end
      end
    end
  end
  return failures
end

function InserterController.has_unresolved_target(instance, target_unit_number)
  for _, record in ipairs(instance.monitored_inserters or {}) do
    if record.target_unit_number == target_unit_number and record.temporary_override then return true end
  end
  for _, tombstone in pairs(Registry.root().override_tombstones or {}) do
    if tombstone.owner == instance.unit_number
      and tombstone.target_unit_number == target_unit_number then return true end
  end
  return false
end

function InserterController.detach_failed_cleanup(instance)
  local root = Registry.root()
  for _, record in ipairs(instance.monitored_inserters or {}) do
    local temporary = record.temporary_override
    local section_pending = has_section_tombstone(root, instance.unit_number, record.target_unit_number)
    if temporary or (record.controlled and section_pending) then
      root.override_tombstones[record.unit_number] = {
        owner = instance.unit_number,
        unit_number = record.unit_number,
        target_unit_number = record.target_unit_number,
        entity = record.entity,
        diagnostic_name = record.diagnostic_name,
        diagnostic_x = record.diagnostic_x,
        diagnostic_y = record.diagnostic_y,
        written_override = temporary and temporary.written_override or nil,
        original_override = record.original_override,
        written_tick = temporary and temporary.written_tick or nil,
        override_resolved = temporary == nil,
      }
      if temporary then root.temporary_overrides[record.unit_number] = instance.unit_number end
    elseif root.inserter_owners[record.unit_number] == instance.unit_number then
      root.inserter_owners[record.unit_number] = nil
    end
  end
end

function InserterController.restore(instance)
  local success = true
  local first_error
  local first_detail
  for _, record in ipairs(instance.monitored_inserters or {}) do
    if record.temporary_override then
      local restored, error_code, detail = restore_record(instance, record)
      if not restored then
        success = false
        if not first_error then
          first_error = error_code or Constants.ERROR.TAIL_RESTORE_FAILED
          first_detail = detail
        end
      end
    end
  end
  return success, first_error, first_detail
end

function InserterController.release_target_claims(instance, target_unit_number)
  if InserterController.has_unresolved_target(instance, target_unit_number) then return false end
  local root = Registry.root()
  for _, record in ipairs(instance.monitored_inserters or {}) do
    if record.target_unit_number == target_unit_number
      and root.inserter_owners[record.unit_number] == instance.unit_number then
      root.inserter_owners[record.unit_number] = nil
    end
  end
  return true
end

function InserterController.release_resolved_tombstones_for_target(owner, target_unit_number)
  local root = Registry.root()
  local units = {}
  for unit_number, tombstone in pairs(root.override_tombstones or {}) do
    if tombstone.owner == owner and tombstone.target_unit_number == target_unit_number then
      units[#units + 1] = unit_number
    end
  end
  table.sort(units)
  for _, unit_number in ipairs(units) do
    local tombstone = root.override_tombstones[unit_number]
    if tombstone then release_tombstone_claims(root, unit_number, tombstone) end
  end
end

function InserterController.clear_records(instance)
  instance.monitored_inserters = {}
  instance.monitored_inserters_by_unit = nil
end

function InserterController.restore_tombstone_claims()
  local root = Registry.root()
  local entries = {}
  for key, tombstone in pairs(root.override_tombstones or {}) do
    if type(tombstone) == "table" and type(tombstone.owner) == "number"
      and type(tombstone.unit_number) == "number"
      and type(tombstone.target_unit_number) == "number" then
      entries[#entries + 1] = {key = key, tombstone = tombstone}
    end
  end
  table.sort(entries, function(left, right)
    if left.tombstone.unit_number ~= right.tombstone.unit_number then
      return left.tombstone.unit_number < right.tombstone.unit_number
    end
    return left.tombstone.owner < right.tombstone.owner
  end)
  local rebuilt = {}
  for _, entry in ipairs(entries) do
    local tombstone = entry.tombstone
    local unit_number = tombstone.unit_number
    if not rebuilt[unit_number] then
      tombstone.override_resolved = tombstone.override_resolved == true
        or tombstone.written_override == nil
      rebuilt[unit_number] = tombstone
      if not root.inserter_owners[unit_number] then root.inserter_owners[unit_number] = tombstone.owner end
      if not root.chest_owners[tombstone.target_unit_number] then
        root.chest_owners[tombstone.target_unit_number] = tombstone.owner
      end
      if not tombstone.override_resolved then root.temporary_overrides[unit_number] = tombstone.owner end
    end
  end
  root.override_tombstones = rebuilt
  local units = {}
  for unit_number in pairs(rebuilt) do units[#units + 1] = unit_number end
  table.sort(units)
  for _, unit_number in ipairs(units) do
    local tombstone = rebuilt[unit_number]
    if tombstone.override_resolved then release_tombstone_claims(root, unit_number, tombstone) end
  end
end

function InserterController.retry_tail(instance)
  if not instance or not instance.manual_tail_recovery then return false end
  local valid, _, _, _, _, has_temporary = InserterController.validate(instance)
  if not valid or has_temporary then return false end
  local allowed = allowed_item_keys(instance)
  local eligible = false
  for _, record in ipairs(instance.monitored_inserters or {}) do
    local current = eligibility(instance, record, allowed)
    if current then eligible = true break end
  end
  if not eligible then return false end
  for _, record in ipairs(instance.monitored_inserters or {}) do record.tail_attempts = 0 end
  instance.manual_tail_recovery = false
  instance.tail_waiting_reason = nil
  return true
end

local function dense_array_count(values)
  if type(values) ~= "table" then return nil end
  local count = 0
  local maximum = 0
  for key in pairs(values) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
    count = count + 1
    if key > maximum then maximum = key end
  end
  if count ~= maximum then return nil end
  return count
end

local function index_saved_temporaries(instance, root)
  local target_units = {}
  for _, target in ipairs(instance.targets or {}) do
    local unit_number = target_unit(target)
    if type(unit_number) == "number" then target_units[unit_number] = true end
  end
  local pending = {}
  local seen = {}
  for _, record in ipairs(instance.monitored_inserters or {}) do
    if record.temporary_override then
      local inserter = record.entity
      if type(record.unit_number) ~= "number" or seen[record.unit_number]
        or not inserter or not inserter.valid or inserter.type ~= "inserter"
        or inserter.unit_number ~= record.unit_number
        or not target_units[record.target_unit_number] then
        return false, diagnostic(
          record,
          {"batch-request-combinator.inserter-diagnostic-entity"}
        )
      end
      local inserter_owner = root.inserter_owners[record.unit_number]
      local chest_owner = root.chest_owners[record.target_unit_number]
      if inserter_owner and inserter_owner ~= instance.unit_number then
        return false, diagnostic(
          record,
          {"batch-request-combinator.inserter-diagnostic-ownership"}
        )
      end
      if chest_owner and chest_owner ~= instance.unit_number then
        return false, diagnostic(
          record,
          {"batch-request-combinator.inserter-diagnostic-ownership"}
        )
      end
      seen[record.unit_number] = true
      pending[#pending + 1] = record
    end
  end
  for _, record in ipairs(pending) do
    root.inserter_owners[record.unit_number] = instance.unit_number
    root.chest_owners[record.target_unit_number] = instance.unit_number
    root.temporary_overrides[record.unit_number] = instance.unit_number
  end
  return true
end

function InserterController.index_saved_temporaries(instance)
  return index_saved_temporaries(instance, Registry.root())
end

local function exact_reconcile_coverage(instance, discovered_targets, discovered_inserters)
  local target_count = dense_array_count(instance.targets)
  local record_count = dense_array_count(instance.monitored_inserters)
  if not target_count or target_count == 0 or not record_count then
    return false, diagnostic(
      instance.targets and instance.targets[1] or instance.entity,
      {"batch-request-combinator.inserter-diagnostic-plan"}
    )
  end

  local cached_targets = {}
  local target_index_by_unit = {}
  for index, target in ipairs(instance.targets) do
    local unit_number = target_unit(target)
    if type(unit_number) ~= "number" or cached_targets[unit_number] then
      return false, diagnostic(
        target,
        {"batch-request-combinator.inserter-diagnostic-target"}
      )
    end
    cached_targets[unit_number] = target
    target_index_by_unit[unit_number] = index
  end
  local discovered_target_count = 0
  local discovered_target_units = {}
  for _, target in ipairs(discovered_targets or {}) do
    local unit_number = target_unit(target)
    if not cached_targets[unit_number] or discovered_target_units[unit_number] then
      return false, diagnostic(target, {"batch-request-combinator.inserter-diagnostic-pickup"})
    end
    discovered_target_units[unit_number] = true
    discovered_target_count = discovered_target_count + 1
  end
  if discovered_target_count ~= target_count then
    for _, target in ipairs(instance.targets) do
      if not discovered_target_units[target_unit(target)] then
        return false, diagnostic(
          target,
          {"batch-request-combinator.inserter-diagnostic-target"}
        )
      end
    end
    return false, diagnostic(
      instance.targets[1],
      {"batch-request-combinator.inserter-diagnostic-target"}
    )
  end

  local discovered_by_unit = {}
  for _, inserter in ipairs(discovered_inserters or {}) do
    local pickup = inserter and inserter.valid and inserter.pickup_target or nil
    if pickup and pickup.valid and cached_targets[pickup.unit_number] then
      if inserter.type ~= "inserter" or type(inserter.unit_number) ~= "number"
        or discovered_by_unit[inserter.unit_number] then
        return false, diagnostic(inserter, {"batch-request-combinator.inserter-diagnostic-entity"})
      end
      discovered_by_unit[inserter.unit_number] = inserter
    end
  end

  local mode = instance.captured_tail_mode or Constants.TAIL_MODE.NO_TAIL
  local seen_records = {}
  local records_by_target = {}
  for _, record in ipairs(instance.monitored_inserters) do
    if type(record) ~= "table" or type(record.unit_number) ~= "number"
      or seen_records[record.unit_number]
      or discovered_by_unit[record.unit_number] ~= record.entity
      or not cached_targets[record.target_unit_number]
      or record.target_index ~= target_index_by_unit[record.target_unit_number]
      or target_unit(record.target) ~= record.target_unit_number
      or not record.target
      or record.target.entity ~= cached_targets[record.target_unit_number].entity
      or record.controlled ~= (mode ~= Constants.TAIL_MODE.NO_TAIL) then
      return false, diagnostic(record, {"batch-request-combinator.inserter-diagnostic-entity"})
    end
    local topology_valid, topology_reason = topology_matches(instance, record)
    if not topology_valid then
      return false, diagnostic(record, topology_reason)
    end
    if not record.diagnostic_name then record.diagnostic_name = record.entity.localised_name end
    local position = record.entity.position
    if position then
      record.diagnostic_x = record.diagnostic_x or position.x
      record.diagnostic_y = record.diagnostic_y or position.y
    end
    seen_records[record.unit_number] = true
    records_by_target[record.target_unit_number] = (records_by_target[record.target_unit_number] or 0) + 1
  end
  local discovered_count = 0
  for unit_number in pairs(discovered_by_unit) do
    discovered_count = discovered_count + 1
    if not seen_records[unit_number] then
      return false, diagnostic(
        discovered_by_unit[unit_number],
        {"batch-request-combinator.inserter-diagnostic-entity"}
      )
    end
  end
  if discovered_count ~= record_count then
    for _, record in ipairs(instance.monitored_inserters) do
      if not discovered_by_unit[record.unit_number] then
        return false, diagnostic(
          record,
          {"batch-request-combinator.inserter-diagnostic-entity"}
        )
      end
    end
    return false, diagnostic(
      instance.monitored_inserters[1],
      {"batch-request-combinator.inserter-diagnostic-entity"}
    )
  end
  if mode ~= Constants.TAIL_MODE.NO_TAIL then
    for unit_number in pairs(cached_targets) do
      local count = records_by_target[unit_number] or 0
      if (mode == Constants.TAIL_MODE.SINGLE and count ~= 1)
        or (mode == Constants.TAIL_MODE.PARALLEL and count < 1) then
        return false, diagnostic(
          cached_targets[unit_number],
          count_reason(mode, count)
        )
      end
    end
  end
  if mode == Constants.TAIL_MODE.SINGLE then
    local tail_index = instance.tail_target_index
    if type(tail_index) ~= "number" or tail_index ~= math.floor(tail_index)
      or tail_index < 1 or tail_index > target_count then
      return false, diagnostic(
        instance.monitored_inserters[1],
        {"batch-request-combinator.inserter-diagnostic-plan"}
      )
    end
  end
  return true
end

local function saved_plan_matches_runtime(instance)
  local mode = instance.captured_tail_mode or Constants.TAIL_MODE.NO_TAIL
  if mode == Constants.TAIL_MODE.NO_TAIL then return true end
  local captured_keys = {}
  for _, item in ipairs(instance.captured or {}) do
    if type(item) ~= "table" or type(item.name) ~= "string" then return false end
    local key = item.key or Util.item_key(item.name, item.quality or "normal")
    item.key = key
    if captured_keys[key] then return false end
    captured_keys[key] = item.name
  end
  local transfers_by_target = {}
  local records_by_target = {}
  for _, record in ipairs(instance.monitored_inserters or {}) do
    local target = instance.targets and instance.targets[record.target_index]
    local allocation = target and target.allocation
    local transfers = record.transfer_by_key
    if not allocation or type(allocation.by_key) ~= "table" or type(transfers) ~= "table"
      or type(record.effective_pickup_count) ~= "number"
      or record.effective_pickup_count < 1 then
      return false, diagnostic(record, {"batch-request-combinator.inserter-diagnostic-plan"})
    end
    for key, name in pairs(captured_keys) do
      local prototype = prototypes and prototypes.item and prototypes.item[name]
      local stack_size = prototype and prototype.stack_size
      local expected = type(stack_size) == "number"
        and math.min(record.effective_pickup_count, stack_size) or nil
      if type(expected) ~= "number" or expected < 1 or transfers[key] ~= expected then
        return false, diagnostic(
          record,
          {"batch-request-combinator.inserter-diagnostic-transfer-size"}
        )
      end
    end
    for key in pairs(transfers) do
      if not captured_keys[key] then
        return false, diagnostic(record, {"batch-request-combinator.inserter-diagnostic-plan"})
      end
    end
    if mode == Constants.TAIL_MODE.SINGLE
      and record.target_index ~= instance.tail_target_index then
      for key, count in pairs(allocation.by_key) do
        local transfer = transfers[key]
        if type(count) ~= "number" or count < 1 or count ~= math.floor(count)
          or type(transfer) ~= "number" or count % transfer ~= 0 then
          return false, diagnostic(record, {"batch-request-combinator.inserter-diagnostic-plan"})
        end
      end
    end
    local reference = transfers_by_target[record.target_unit_number]
    if reference then
      for key in pairs(captured_keys) do
        if transfers[key] ~= reference[key] then
          return false, diagnostic(record, {
            "batch-request-combinator.inserter-diagnostic-transfer-size",
          })
        end
      end
    else
      transfers_by_target[record.target_unit_number] = transfers
    end
    records_by_target[record.target_unit_number] =
      (records_by_target[record.target_unit_number] or 0) + 1
  end
  if mode == Constants.TAIL_MODE.SINGLE then
    for _, target in ipairs(instance.targets or {}) do
      local unit_number = target_unit(target)
      if records_by_target[unit_number] ~= 1 then
        return false, diagnostic(
          target,
          count_reason(mode, records_by_target[unit_number] or 0)
        )
      end
    end
  end
  return true
end

function InserterController.reconcile(instance)
  instance.monitored_inserters = instance.monitored_inserters or {}
  instance.monitored_inserters_by_unit = nil
  local mode = instance.captured_tail_mode or Constants.TAIL_MODE.NO_TAIL
  local root = Registry.root()
  local temporaries_indexed, temporary_detail = InserterController.index_saved_temporaries(instance)
  if not temporaries_indexed then
    return false, Constants.ERROR.INSERTER_OWNERSHIP, temporary_detail
  end
  local discovered_targets, discovered_inserters, endpoints_by_unit = TargetDiscovery.discover(instance.entity)
  if #instance.monitored_inserters == 0 then
    if mode ~= Constants.TAIL_MODE.NO_TAIL then
      return false, Constants.ERROR.INSERTER_CONFIGURATION, diagnostic(
        instance.targets and instance.targets[1] or instance.entity,
        count_reason(mode, 0)
      )
    end
    local monitored, prepare_error, prepare_detail = InserterController.prepare(
      instance,
      instance.targets or {},
      discovered_inserters,
      mode,
      endpoints_by_unit
    )
    if not monitored then
      return false,
        prepare_error or Constants.ERROR.INSERTER_CONFIGURATION,
        prepare_detail or diagnostic(
          instance.targets and instance.targets[1] or instance.entity,
          {"batch-request-combinator.inserter-diagnostic-entity"}
        )
    end
  end
  local coverage_valid, coverage_detail = exact_reconcile_coverage(
    instance,
    discovered_targets,
    discovered_inserters
  )
  if not coverage_valid then
    return false, Constants.ERROR.INSERTER_CONFIGURATION, coverage_detail
  end
  rebuild_record_index(instance)
  local plan_valid, plan_detail = saved_plan_matches_runtime(instance)
  if not plan_valid then
    return false, Constants.ERROR.INSERTER_CONFIGURATION, plan_detail
  end
  if (instance.captured_tail_mode or Constants.TAIL_MODE.NO_TAIL) ~= Constants.TAIL_MODE.NO_TAIL then
    local claimed, claim_detail = InserterController.claim(instance)
    if not claimed then
      return false, Constants.ERROR.INSERTER_OWNERSHIP, claim_detail
    end
  end
  return InserterController.validate(instance)
end

return InserterController
