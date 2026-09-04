local Constants = require("runtime.constants")
local InserterController = require("runtime.inserter_controller")
local Registry = require("runtime.registry")
local Requests = require("runtime.requests")
local TargetDiscovery = require("runtime.target_discovery")
local Util = require("runtime.util")

local Drain = {}

local function target_unit(target)
  return target and target.entity and target.entity.valid and target.entity.unit_number
    or (target and target.unit_number)
end

local function target_detail(target)
  local entity = target and target.entity
  if entity and entity.valid then return entity.localised_name end
  return target and target.diagnostic_name or nil
end

local function clear_destroy_registration(root, target)
  if target.destroy_registration then root.destroyed[target.destroy_registration] = nil end
  target.destroy_registration = nil
end

local function release_claim(root, owner, target)
  local unit_number = target_unit(target) or target.unit_number
  if unit_number and root.chest_owners[unit_number] == owner then
    root.chest_owners[unit_number] = nil
  end
  clear_destroy_registration(root, target)
end

local function clear_instance(instance)
  instance.drain_targets = {}
  instance.drain_initial_total = 0
  instance.drain_remaining_total = 0
  instance.drain_pending_deliveries = 0
  instance.drain_last_remaining_total = 0
  instance.drain_last_pending_total = 0
  instance.drain_last_progress_tick = nil
  instance.drain_last_diagnostic_tick = nil
  instance.drain_wait_reason = nil
  instance.drain_diagnostic_cursor = 1
  instance.drain_restore_blocked = false
  instance.drain_kind = nil
  instance.mutating_drain = nil
  instance.monitored_inserters = {}
  instance.monitored_inserters_by_unit = nil
end

local function logistic_network(point)
  local ok, network = pcall(function() return point and point.logistic_network end)
  if not ok or not network then return nil end
  local valid_ok, valid = pcall(function() return network.valid end)
  return valid_ok and valid and network or nil
end

local function representative_stack(inventory)
  if not inventory or not inventory.valid then return nil end
  local ok, contents = pcall(function() return inventory.get_contents() end)
  if not ok then return nil end
  local selected
  local selected_key
  for _, item in pairs(contents or {}) do
    if type(item.name) == "string" and type(item.count) == "number" and item.count > 0 then
      local quality = Util.quality_name(item.quality)
      local key = Util.item_key(item.name, quality)
      if not selected_key or key < selected_key then
        selected_key = key
        selected = {name = item.name, count = 1, quality = quality}
      end
    end
  end
  return selected
end

local function observation_stack(observation)
  return representative_stack(observation and observation.inventory)
    or representative_stack(observation and observation.trash_inventory)
end

local function network_robot_counts(network)
  local ok, all, available = pcall(function()
    return network.all_logistic_robots, network.available_logistic_robots
  end)
  if not ok then return nil end
  return all, available
end

local function diagnose_wait(instance, observations, pending)
  local networks = {}
  local candidates = {}
  for index, observation in ipairs(observations or {}) do
    if (observation.remaining or 0) > 0 then
      local network = logistic_network(observation.point)
      if not network then return Constants.DRAIN_WAIT_REASON.NETWORK end
      local id_ok, network_id = pcall(function() return network.network_id end)
      if not id_ok or type(network_id) ~= "number" then
        return Constants.DRAIN_WAIT_REASON.MOVEMENT
      end
      if not networks[network_id] then networks[network_id] = network end
      candidates[#candidates + 1] = index
    end
  end
  if #candidates == 0 then
    return pending > 0 and Constants.DRAIN_WAIT_REASON.MOVEMENT or nil
  end

  local unavailable = false
  for _, network in pairs(networks) do
    local all, available = network_robot_counts(network)
    if all == nil then return Constants.DRAIN_WAIT_REASON.MOVEMENT end
    if all <= 0 then return Constants.DRAIN_WAIT_REASON.ROBOTS end
    if available <= 0 then unavailable = true end
  end
  if unavailable then return Constants.DRAIN_WAIT_REASON.AVAILABLE_ROBOTS end

  local cursor = math.max(1, math.floor(instance.drain_diagnostic_cursor or 1))
  local selected_index = candidates[((cursor - 1) % #candidates) + 1]
  instance.drain_diagnostic_cursor = (cursor % #candidates) + 1
  local observation = observations[selected_index]
  local stack = observation_stack(observation)
  if not stack then return Constants.DRAIN_WAIT_REASON.MOVEMENT end
  local network = logistic_network(observation.point)
  if not network then return Constants.DRAIN_WAIT_REASON.NETWORK end
  local ok, drop_point = pcall(function()
    return network.select_drop_point{stack = stack, members = "storage"}
  end)
  if not ok then return Constants.DRAIN_WAIT_REASON.MOVEMENT end
  if not drop_point then return Constants.DRAIN_WAIT_REASON.DESTINATION end
  return Constants.DRAIN_WAIT_REASON.MOVEMENT
end

local function update_wait_diagnostic(instance, observations, remaining, pending)
  local previous_remaining = instance.drain_last_remaining_total
  local progressed = previous_remaining == nil or remaining < previous_remaining

  instance.drain_last_remaining_total = remaining
  instance.drain_last_pending_total = pending

  if progressed then
    instance.drain_last_progress_tick = game.tick
    instance.drain_last_diagnostic_tick = nil
    instance.drain_wait_reason = nil
    return
  end
  if remaining <= 0 and pending <= 0 then
    instance.drain_wait_reason = nil
    return
  end

  instance.drain_last_progress_tick = instance.drain_last_progress_tick or game.tick
  if game.tick - instance.drain_last_progress_tick < Constants.DRAIN_STALL_TICKS then return end
  if instance.drain_last_diagnostic_tick
    and game.tick - instance.drain_last_diagnostic_tick
      < Constants.DRAIN_DIAGNOSTIC_INTERVAL_TICKS then return end

  instance.drain_last_diagnostic_tick = game.tick
  instance.drain_wait_reason = diagnose_wait(instance, observations, pending)
end

local function relevant_hands_empty(instance, targets, inserters)
  local target_units = {}
  for _, target in ipairs(targets) do target_units[target.unit_number] = true end
  for _, inserter in ipairs(inserters or {}) do
    if inserter and inserter.valid and inserter.type == "inserter"
      and Util.is_same_force_and_surface(inserter, instance.entity) then
      local pickup = inserter.pickup_target
      if pickup and pickup.valid and target_units[pickup.unit_number] then
        local held = inserter.held_stack
        if held and held.valid_for_read and held.count > 0 then
          return false, inserter.localised_name
        end
      end
    end
  end
  return true
end

local function preflight(instance)
  local targets, inserters, endpoints_by_unit = TargetDiscovery.discover(instance.entity)
  if #targets == 0 then return nil, Constants.ERROR.NO_TARGETS end
  local root = Registry.root()
  local total = 0
  local observations = {}
  local scope_units = {}
  for index, target in ipairs(targets) do
    local unit_number = target_unit(target)
    local owner = unit_number and root.chest_owners[unit_number] or nil
    if not unit_number then return nil, Constants.ERROR.TARGET_LOST end
    local entity = target.entity
    if entity and entity.valid then
      target.diagnostic_name = target.diagnostic_name or entity.localised_name
      local position = entity.position
      if position then
        target.diagnostic_x = target.diagnostic_x or position.x
        target.diagnostic_y = target.diagnostic_y or position.y
      end
    end
    if owner then return nil, Constants.ERROR.TARGET_CONFLICT, target_detail(target) end
    local valid, error_code, detail, observation = Requests.inspect_drain_target(instance, target, nil)
    if not valid then return nil, error_code, detail end
    if observation.pending > 0 then
      return nil, Constants.ERROR.EXTERNAL_DELIVERY, target_detail(target)
    end
    observations[index] = observation
    total = total + observation.remaining
    scope_units[index] = tostring(unit_number)
  end
  local hands_empty, hand_detail = relevant_hands_empty(instance, targets, inserters)
  if not hands_empty then return nil, Constants.ERROR.INSERTER_NOT_EMPTY, hand_detail end
  return {
    targets = targets,
    inserters = inserters,
    endpoints_by_unit = endpoints_by_unit,
    observations = observations,
    total = total,
    scope_signature = table.concat(scope_units, ",") .. "|" .. tostring(total),
  }
end

local function restore_instance(instance)
  local root = Registry.root()
  if instance.drain_restore_blocked then return false, Constants.ERROR.TARGET_CONFLICT end
  local seen = {}
  for _, target in ipairs(instance.drain_targets or {}) do
    local entity = target.entity
    if entity and entity.valid then
      if type(target.unit_number) ~= "number" or seen[target.unit_number]
        or entity.unit_number ~= target.unit_number
        or root.chest_owners[target.unit_number] ~= instance.unit_number then
        return false, Constants.ERROR.TARGET_CONFLICT, target_detail(target)
      end
      seen[target.unit_number] = true
    end
  end
  local all_restored = true
  local first_detail
  instance.mutating_drain = true
  for _, target in ipairs(instance.drain_targets or {}) do
    local entity = target.entity
    local restored = false
    if not entity or not entity.valid then
      restored = true
    elseif entity.unit_number == target.unit_number then
      local point = entity.get_requester_point()
      if point and point.valid and type(target.original_trash_not_requested) == "boolean" then
        if point.trash_not_requested ~= target.original_trash_not_requested then
          local wrote = pcall(function()
            point.trash_not_requested = target.original_trash_not_requested
          end)
          restored = wrote and point.trash_not_requested == target.original_trash_not_requested
        else
          restored = true
        end
      end
    end
    target.drain_restored = restored
    if not restored then
      all_restored = false
      first_detail = first_detail or (entity and entity.valid and entity.localised_name)
    elseif not entity or not entity.valid then
      release_claim(root, instance.unit_number, target)
    end
  end
  instance.mutating_drain = nil
  if not all_restored then return false, Constants.ERROR.DRAIN_RESTORE_FAILED, first_detail end
  for _, target in ipairs(instance.drain_targets or {}) do
    release_claim(root, instance.unit_number, target)
  end
  clear_instance(instance)
  return true
end

function Drain.preview(instance)
  local prepared, error_code, detail = preflight(instance)
  if not prepared then return false, error_code, detail end
  return true, nil, nil, {
    target_count = #prepared.targets,
    item_count = prepared.total,
    scope_signature = prepared.scope_signature,
  }
end

local function activate_prepared(instance, prepared, drain_kind, allow_existing_claim)
  local root = Registry.root()
  for _, target in ipairs(prepared.targets) do
    local owner = root.chest_owners[target.unit_number]
    if owner and (not allow_existing_claim or owner ~= instance.unit_number) then
      return false, Constants.ERROR.TARGET_CONFLICT, target_detail(target)
    end
  end
  for index, target in ipairs(prepared.targets) do
    root.chest_owners[target.unit_number] = instance.unit_number
    target.original_trash_not_requested = prepared.observations[index].point.trash_not_requested
    target.drain_restored = false
    target.destroy_registration = script.register_on_object_destroyed(target.entity)
    root.destroyed[target.destroy_registration] = {
      kind = "drain-target",
      owner = instance.unit_number,
      target = target.unit_number,
    }
  end
  instance.drain_targets = prepared.targets
  instance.drain_restore_blocked = false
  instance.drain_kind = drain_kind
  instance.drain_initial_total = prepared.total
  instance.drain_remaining_total = prepared.total
  instance.drain_pending_deliveries = prepared.pending or 0
  instance.drain_last_remaining_total = prepared.total
  instance.drain_last_pending_total = prepared.pending or 0
  instance.drain_last_progress_tick = game.tick
  instance.drain_last_diagnostic_tick = nil
  instance.drain_wait_reason = nil
  instance.drain_diagnostic_cursor = 1

  instance.mutating_drain = true
  local write_detail
  for index, target in ipairs(prepared.targets) do
    local point = prepared.observations[index].point
    if point.trash_not_requested ~= true then
      local wrote = pcall(function() point.trash_not_requested = true end)
      target.drain_written = wrote and point.trash_not_requested == true
      if not target.drain_written then
        write_detail = target_detail(target)
        break
      end
    else
      target.drain_written = false
    end
  end
  instance.mutating_drain = nil
  if write_detail then
    local restored, restore_error, restore_detail = restore_instance(instance)
    if not restored then return false, restore_error, restore_detail, true end
    return false, Constants.ERROR.DRAIN_WRITE_FAILED, write_detail
  end
  return true
end

function Drain.start(instance, expected_scope_signature)
  local prepared, error_code, detail = preflight(instance)
  if not prepared then return false, error_code, detail end
  if expected_scope_signature and prepared.scope_signature ~= expected_scope_signature then
    return false, Constants.ERROR.DRAIN_SCOPE_CHANGED
  end
  local monitored, inserter_error, inserter_detail = InserterController.prepare(
    instance,
    prepared.targets,
    prepared.inserters,
    Constants.TAIL_MODE.NO_TAIL,
    prepared.endpoints_by_unit
  )
  if not monitored then
    clear_instance(instance)
    return false, inserter_error, inserter_detail
  end
  local hands_empty, hand_detail = InserterController.hands_empty(instance)
  if not hands_empty then
    clear_instance(instance)
    return false, Constants.ERROR.INSERTER_NOT_EMPTY, hand_detail
  end
  return activate_prepared(instance, prepared, "maintenance", false)
end

local function automatic_target(target)
  local entity = target and target.entity
  if not entity or not entity.valid or type(entity.unit_number) ~= "number"
    or entity.unit_number ~= target.unit_number then return nil end
  return {
    entity = entity,
    unit_number = target.unit_number,
    topology_endpoints = target.topology_endpoints,
    diagnostic_name = target.diagnostic_name or entity.localised_name,
    diagnostic_x = target.diagnostic_x,
    diagnostic_y = target.diagnostic_y,
  }
end

function Drain.start_after_interruption(instance, batch_targets)
  local prepared = {targets = {}, observations = {}, total = 0, pending = 0}
  local seen = {}
  for index, batch_target in ipairs(batch_targets or {}) do
    local target = automatic_target(batch_target)
    if not target or seen[target.unit_number] then
      return false, nil, Constants.ERROR.TARGET_LOST, target_detail(batch_target)
    end
    seen[target.unit_number] = true
    local valid, error_code, detail, observation = Requests.inspect_drain_target(
      instance,
      target,
      nil
    )
    if not valid then return false, nil, error_code, detail end
    prepared.targets[index] = target
    prepared.observations[index] = observation
    prepared.total = prepared.total + observation.remaining
    prepared.pending = prepared.pending + observation.pending
  end
  if #prepared.targets == 0 then return false, nil, Constants.ERROR.NO_TARGETS end

  local controller_valid, controller_error, controller_detail, hands_empty =
    InserterController.validate_passive(instance)
  if not controller_valid then return false, nil, controller_error, controller_detail end
  if prepared.total == 0 and prepared.pending == 0 and hands_empty then return true, false end

  local started, error_code, error_detail, restoration_failed = activate_prepared(
    instance,
    prepared,
    "automatic",
    true
  )
  if not started then return false, nil, error_code, error_detail, restoration_failed end
  return true, true
end

function Drain.process(instance)
  local root = Registry.root()
  local remaining = 0
  local pending = 0
  local observations = {}
  for index, target in ipairs(instance.drain_targets or {}) do
    if root.chest_owners[target.unit_number] ~= instance.unit_number then
      return false, Constants.ERROR.TARGET_CONFLICT, target_detail(target)
    end
    local valid, error_code, detail, observation = Requests.inspect_drain_target(instance, target, true)
    if not valid then return false, error_code, detail end
    observations[index] = observation
    remaining = remaining + observation.remaining
    pending = pending + observation.pending
  end
  local controller_valid, controller_error, controller_detail, hands_empty =
    InserterController.validate_passive(instance)
  if not controller_valid then return false, controller_error, controller_detail end
  instance.drain_remaining_total = remaining
  instance.drain_pending_deliveries = pending
  update_wait_diagnostic(instance, observations, remaining, pending)
  if remaining > 0 or pending > 0 or not hands_empty then return true, false end
  local restored, restore_error, restore_detail = restore_instance(instance)
  if not restored then return false, restore_error, restore_detail end
  return true, true
end

function Drain.stop(instance)
  if not instance or #(instance.drain_targets or {}) == 0 then return true end
  return restore_instance(instance)
end

function Drain.has_lease(instance)
  return instance and #(instance.drain_targets or {}) > 0
end

local function tombstone_key(owner, unit_number)
  return tostring(owner) .. ":" .. tostring(unit_number)
end

function Drain.detach_failed_cleanup(instance)
  local root = Registry.root()
  if instance.drain_restore_blocked then
    for _, target in ipairs(instance.drain_targets or {}) do
      release_claim(root, instance.unit_number, target)
    end
    clear_instance(instance)
    return
  end
  for _, target in ipairs(instance.drain_targets or {}) do
    local entity = target.entity
    local point = entity and entity.valid and entity.get_requester_point() or nil
    local restored = not entity or not entity.valid
      or (entity.unit_number == target.unit_number and point and point.valid
        and point.trash_not_requested == target.original_trash_not_requested)
    if restored then
      release_claim(root, instance.unit_number, target)
    elseif root.chest_owners[target.unit_number] == instance.unit_number then
      clear_destroy_registration(root, target)
      local key = tombstone_key(instance.unit_number, target.unit_number)
      if not root.drain_tombstones[key] then root.drain_order[#root.drain_order + 1] = key end
      root.drain_tombstones[key] = {
        key = key,
        owner = instance.unit_number,
        unit_number = target.unit_number,
        entity = entity,
        original_trash_not_requested = target.original_trash_not_requested,
      }
      root.chest_owners[target.unit_number] = instance.unit_number
    else
      clear_destroy_registration(root, target)
    end
  end
  table.sort(root.drain_order)
  root.drain_cursor = 1
  clear_instance(instance)
end

function Drain.quarantine_failed_reconciliation(instance)
  if not Drain.has_lease(instance) then return end
  local root = Registry.root()
  instance.drain_restore_blocked = true
  for _, target in ipairs(instance.drain_targets) do
    if type(target.unit_number) == "number" and root.chest_owners[target.unit_number] == nil then
      root.chest_owners[target.unit_number] = instance.unit_number
    end
  end
end

local function remove_tombstone(root, index, key, tombstone)
  root.drain_tombstones[key] = nil
  table.remove(root.drain_order, index)
  if root.chest_owners[tombstone.unit_number] == tombstone.owner then
    root.chest_owners[tombstone.unit_number] = nil
  end
  root.drain_cursor = #root.drain_order == 0 and 1
    or math.min(index, #root.drain_order)
end

function Drain.retry_one_tombstone()
  local root = Registry.root()
  if #root.drain_order == 0 then return end
  local index = math.min(root.drain_cursor or 1, #root.drain_order)
  local key = root.drain_order[index]
  local tombstone = root.drain_tombstones[key]
  if not tombstone then
    table.remove(root.drain_order, index)
    root.drain_cursor = #root.drain_order == 0 and 1
      or math.min(index, #root.drain_order)
    return
  end
  if root.chest_owners[tombstone.unit_number] ~= tombstone.owner then
    root.drain_cursor = (index % #root.drain_order) + 1
    return
  end
  local entity = tombstone.entity
  local restored = not entity or not entity.valid
  if not restored and entity.unit_number == tombstone.unit_number then
    local point = entity.get_requester_point()
    if point and point.valid then
      if point.trash_not_requested ~= tombstone.original_trash_not_requested then
        local wrote = pcall(function()
          point.trash_not_requested = tombstone.original_trash_not_requested
        end)
        restored = wrote
          and point.trash_not_requested == tombstone.original_trash_not_requested
      else
        restored = true
      end
    end
  end
  if restored then
    remove_tombstone(root, index, key, tombstone)
  else
    root.drain_cursor = (index % #root.drain_order) + 1
  end
end

function Drain.restore_tombstone_claims()
  local root = Registry.root()
  local candidates = {}
  for key, tombstone in pairs(root.drain_tombstones or {}) do
    if type(tombstone) == "table" and type(tombstone.owner) == "number"
      and type(tombstone.unit_number) == "number"
      and type(tombstone.original_trash_not_requested) == "boolean" then
      tombstone.key = key
      candidates[#candidates + 1] = key
    else
      root.drain_tombstones[key] = nil
    end
  end
  table.sort(candidates, function(left_key, right_key)
    local left = root.drain_tombstones[left_key]
    local right = root.drain_tombstones[right_key]
    if left.owner ~= right.owner then return left.owner < right.owner end
    return tostring(left_key) < tostring(right_key)
  end)
  local grouped = {}
  local grouped_units = {}
  for _, key in ipairs(candidates) do
    local unit_number = root.drain_tombstones[key].unit_number
    if not grouped[unit_number] then
      grouped[unit_number] = {}
      grouped_units[#grouped_units + 1] = unit_number
    end
    grouped[unit_number][#grouped[unit_number] + 1] = key
  end
  table.sort(grouped_units)
  local order = {}
  for _, unit_number in ipairs(grouped_units) do
    local keys = grouped[unit_number]
    local first = root.drain_tombstones[keys[1]]
    local compatible = true
    for index = 2, #keys do
      local other = root.drain_tombstones[keys[index]]
      if other.original_trash_not_requested ~= first.original_trash_not_requested
        or other.entity ~= first.entity then
        compatible = false
        break
      end
    end
    local current_owner = root.chest_owners[unit_number]
    local chosen_key
    if compatible then
      if current_owner then
        for _, key in ipairs(keys) do
          if root.drain_tombstones[key].owner == current_owner then
            chosen_key = key
            break
          end
        end
      else
        chosen_key = keys[1]
      end
    end
    for _, key in ipairs(keys) do
      if key ~= chosen_key then root.drain_tombstones[key] = nil end
    end
    if chosen_key then
      local chosen = root.drain_tombstones[chosen_key]
      root.chest_owners[unit_number] = chosen.owner
      order[#order + 1] = chosen_key
    end
  end
  root.drain_order = order
  root.drain_cursor = 1
end

function Drain.reconcile(instance)
  if not Drain.has_lease(instance) then return true end
  if instance.drain_restore_blocked then return false, Constants.ERROR.TARGET_CONFLICT end
  local root = Registry.root()
  local seen = {}
  for _, target in ipairs(instance.drain_targets) do
    local entity = target.entity
    if type(target.unit_number) ~= "number" or seen[target.unit_number]
      or not entity or not entity.valid or entity.unit_number ~= target.unit_number
      or type(target.original_trash_not_requested) ~= "boolean" then
      return false, Constants.ERROR.TARGET_LOST
    end
    seen[target.unit_number] = true
    local owner = root.chest_owners[target.unit_number]
    if owner and owner ~= instance.unit_number then
      return false, Constants.ERROR.TARGET_CONFLICT, target_detail(target)
    end
  end
  for _, target in ipairs(instance.drain_targets) do
    root.chest_owners[target.unit_number] = instance.unit_number
    clear_destroy_registration(root, target)
    target.destroy_registration = script.register_on_object_destroyed(target.entity)
    root.destroyed[target.destroy_registration] = {
      kind = "drain-target",
      owner = instance.unit_number,
      target = target.unit_number,
    }
  end
  return true
end

return Drain
