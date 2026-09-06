local Constants = require("runtime.constants")
local Registry = require("runtime.registry")
local TargetDiscovery = require("runtime.target_discovery")
local Util = require("runtime.util")

local Requests = {}
local last_poll_totals

local function read_set_requests(behavior)
  return behavior.set_requests
end

local function poll_totals_requested(instance)
  local root = Registry.root()
  return root.open_gui_instances and root.open_gui_instances[instance.unit_number] == true
end

local function cache_poll_totals(instance, remaining_source, pending_deliveries, requested)
  if not game or not game.tick then return end
  if requested == nil then requested = poll_totals_requested(instance) end
  if not requested then return end
  last_poll_totals = {
    tick = game.tick,
    unit_number = instance.unit_number,
    remaining_source = remaining_source,
    pending_deliveries = pending_deliveries,
  }
end

local function cached_poll_totals(instance)
  if not game or not last_poll_totals or last_poll_totals.tick ~= game.tick
    or last_poll_totals.unit_number ~= instance.unit_number then
    return nil
  end
  return last_poll_totals
end

local function target_api(target)
  local entity = target.entity
  if not Util.valid_entity(entity) then return nil, nil end
  local point = entity.get_requester_point()
  local inventory = entity.get_inventory(defines.inventory.chest)
  if not point or not point.valid or not inventory or not inventory.valid then return nil, nil end
  return point, inventory
end

local function target_trash_inventory(entity, main_inventory)
  local inventory_id = defines.inventory.logistic_container_trash
  if not inventory_id then return nil end
  local readable, inventory = pcall(function() return entity.get_inventory(inventory_id) end)
  if not readable or not inventory or not inventory.valid or inventory == main_inventory
    or #inventory < 1 then return nil end
  return inventory
end

local function target_detail(target)
  local entity = target and target.entity
  if entity and entity.valid then return entity.localised_name end
  return target and target.diagnostic_name or nil
end

local function owned_section_reference(target, section)
  local entity = target and target.entity
  if not section or not section.valid or not section.is_manual
    or not Util.valid_entity(entity) or section.owner ~= entity then
    return false
  end
  return true
end

local function current_owned_section_index(target, section, observed_point)
  if not owned_section_reference(target, section) then return nil end
  local entity = target.entity
  local point = observed_point or entity.get_requester_point()
  if not point or not point.valid then return nil end
  local index = section.index
  local readable, current = pcall(point.get_section, index)
  if readable and current == section then return index end
  return nil
end

function Requests.has_current_owned_section(target)
  return current_owned_section_index(target, target and target.section) ~= nil
end

function Requests.has_owned_section_reference(target)
  return owned_section_reference(target, target and target.section)
end

local function has_pending(entries)
  for _, entry in pairs(entries or {}) do
    if entry.count and entry.count > 0 then return true end
  end
  return false
end

local function pending_total(entries)
  local total = 0
  for _, entry in pairs(entries or {}) do
    if entry.count and entry.count > 0 then total = total + entry.count end
  end
  return total
end

local function section_has_filters(section)
  if not section or not section.valid or not section.active then return false end
  for _, filter in pairs(section.filters or {}) do
    if filter and filter.value and filter.value.name then return true end
  end
  return false
end

local function has_external_requests(point, own_section)
  for _, section in pairs(point.sections or {}) do
    if section.valid and section ~= own_section and section_has_filters(section) then return true end
  end
  return false
end

local function circuit_sets_requests(entity)
  local behavior = entity.get_control_behavior()
  if not behavior or not behavior.valid then return false end
  local readable, enabled = pcall(read_set_requests, behavior)
  return readable and enabled == true
end

local function has_compiled_requests(point)
  return next(point.filters or {}) ~= nil
end

local function capability_error(instance, target, observed_point, observed_inventory, observed_trash_inventory)
  local point, inventory = observed_point, observed_inventory
  if not point or not inventory then point, inventory = target_api(target) end
  if not point then return Constants.ERROR.TARGET_LOST end
  if not Util.is_same_force_and_surface(instance.entity, target.entity) then
    return Constants.ERROR.TARGET_INCOMPATIBLE
  end
  if not TargetDiscovery.validate_cached_endpoint(
    instance.entity,
    target.entity,
    target.topology_endpoints
  ) then
    return Constants.ERROR.TARGET_LOST
  end
  if point.mode ~= defines.logistic_mode.requester or not point.enabled then
    return Constants.ERROR.TARGET_INCOMPATIBLE
  end
  if point.trash_not_requested then return Constants.ERROR.TARGET_INCOMPATIBLE end
  local trash_inventory = observed_trash_inventory
    or target_trash_inventory(target.entity, inventory)
  if point.exact ~= true and not trash_inventory then
    return Constants.ERROR.TARGET_INCOMPATIBLE
  end
  if circuit_sets_requests(target.entity) then return Constants.ERROR.EXTERNAL_REQUEST end
  if has_external_requests(point, target.section) then return Constants.ERROR.EXTERNAL_REQUEST end
  if not target.section and has_compiled_requests(point) then return Constants.ERROR.EXTERNAL_REQUEST end
  return nil, point, inventory, trash_inventory
end

local function inventory_contents(inventory)
  local contents = {}
  for _, item in pairs(inventory.get_contents()) do
    local key = Util.item_key(item.name, Util.quality_name(item.quality))
    contents[key] = (contents[key] or 0) + item.count
  end
  return contents
end

local function inventory_total(inventory)
  if inventory.get_item_count then return inventory.get_item_count() end
  local total = 0
  for _, item in pairs(inventory.get_contents()) do total = total + (item.count or 0) end
  return total
end

function Requests.inspect_drain_target(instance, target, expected_trash_not_requested)
  local point, inventory = target_api(target)
  if not point then return false, Constants.ERROR.TARGET_LOST, target_detail(target) end
  if not Util.is_same_force_and_surface(instance.entity, target.entity)
    or not TargetDiscovery.validate_cached_endpoint(
      instance.entity,
      target.entity,
      target.topology_endpoints
    )
    or point.mode ~= defines.logistic_mode.requester
    or not point.enabled then
    return false, Constants.ERROR.TARGET_INCOMPATIBLE, target_detail(target)
  end
  if expected_trash_not_requested ~= nil
    and point.trash_not_requested ~= expected_trash_not_requested then
    return false, Constants.ERROR.TARGET_INCOMPATIBLE, target_detail(target)
  end
  if circuit_sets_requests(target.entity)
    or has_external_requests(point, nil)
    or has_compiled_requests(point) then
    return false, Constants.ERROR.EXTERNAL_REQUEST, target_detail(target)
  end
  local pending = pending_total(point.targeted_items_deliver)
    + pending_total(point.targeted_items_pickup)
  local trash_inventory = target_trash_inventory(target.entity, inventory)
  local remaining = inventory_total(inventory)
  if trash_inventory then remaining = remaining + inventory_total(trash_inventory) end
  return true, nil, nil, {
    point = point,
    inventory = inventory,
    trash_inventory = trash_inventory,
    remaining = remaining,
    pending = pending,
  }
end

local function accessible_slot_count(inventory)
  local count = #inventory
  if inventory.supports_bar() then
    count = math.min(count, math.max(0, inventory.get_bar() - 1))
  end
  return count
end

local function has_inaccessible_items(inventory)
  local accessible = accessible_slot_count(inventory)
  for index = accessible + 1, #inventory do
    local stack = inventory[index]
    if stack and stack.valid_for_read then return true end
  end
  return false
end

local function validate_contents(target, require_exact, allow_allocated_excess, inventory, observed_contents)
  if not inventory then
    local _, current_inventory = target_api(target)
    inventory = current_inventory
  end
  if not inventory then return false, Constants.ERROR.TARGET_LOST end
  if has_inaccessible_items(inventory) then
    return false, Constants.ERROR.INACCESSIBLE_ITEMS
  end
  local contents = observed_contents or inventory_contents(inventory)
  local exact = true
  local staged = 0
  local source_total = 0

  for _, key in ipairs(Util.sorted_keys(contents)) do
    local count = contents[key]
    source_total = source_total + count
    local allocated = target.allocation.by_key[key]
    if not allocated then return false, Constants.ERROR.CONTAMINATION, contents end
    if count > allocated and not allow_allocated_excess then
      return false, Constants.ERROR.EXCESS_ITEMS, contents
    end
  end
  for key, allocated in pairs(target.allocation.by_key) do
    local current = contents[key] or 0
    staged = staged + math.min(current, allocated)
    if current ~= allocated then exact = false end
  end
  if require_exact and not exact then return false, Constants.ERROR.DELIVERY_MISMATCH, contents end
  return true, nil, contents, exact, staged, source_total
end

local function validate_trash_contents(target, inventory)
  if not inventory then return true, nil, true, 0 end
  local contents = inventory_contents(inventory)
  local total = 0
  for _, key in ipairs(Util.sorted_keys(contents)) do
    local count = contents[key]
    total = total + count
    if not target.allocation.by_key[key] then
      return false, Constants.ERROR.CONTAMINATION, false, total
    end
  end
  return true, nil, total == 0, total
end

local function filter_identity(filter)
  if not filter then return nil, nil end
  if type(filter) == "string" then return filter, "normal", "=" end
  local name = filter.name
  if type(name) ~= "string" then
    local readable, prototype_name = pcall(function() return name.name end)
    name = readable and prototype_name or nil
  end
  return name, Util.quality_name(filter.quality), filter.comparator or "="
end

local function validate_capacity(target, inventory, observed_contents)
  local allocation = target.allocation
  local contents = observed_contents or inventory_contents(inventory)
  local remaining = {}
  for key, count in pairs(allocation.by_key) do
    remaining[key] = count - (contents[key] or 0)
    local name, quality = Util.split_item_key(key)
    local ok, insertable = pcall(inventory.get_insertable_count, {name = name, quality = quality})
    if not ok or insertable < remaining[key] then return false end
  end

  local accessible_slots = accessible_slot_count(inventory)
  local supports_filters = inventory.supports_filters()
  local unfiltered_empty = 0

  for index = 1, accessible_slots do
    local stack = inventory[index]
    local filter = supports_filters and inventory.get_filter(index) or nil
    local filter_name, filter_quality, filter_comparator = filter_identity(filter)
    if filter and (not filter_name or filter_comparator ~= "=") then return false end
    if stack.valid_for_read then
      local quality = Util.quality_name(stack.quality)
      local key = Util.item_key(stack.name, quality)
      if remaining[key] and remaining[key] > 0 then
        local free = math.max(0, stack.prototype.stack_size - stack.count)
        remaining[key] = math.max(0, remaining[key] - free)
      end
    else
      if filter then
        local key = Util.item_key(filter_name, filter_quality)
        if key and remaining[key] and remaining[key] > 0 then
          local prototype = prototypes.item[filter_name]
          if prototype then remaining[key] = math.max(0, remaining[key] - prototype.stack_size) end
        end
      else
        unfiltered_empty = unfiltered_empty + 1
      end
    end
  end

  local required_empty = 0
  for key, count in pairs(remaining) do
    if count > 0 then
      local name = Util.split_item_key(key)
      local prototype = prototypes.item[name]
      if not prototype then return false end
      required_empty = required_empty + math.ceil(count / prototype.stack_size)
    end
  end
  return required_empty <= unfiltered_empty
end

local function planning_joint_capacity(inventory, contents, captured)
  local descriptor = {
    existing_by_key = {},
    dedicated_by_key = {},
    stack_size_by_key = {},
    unfiltered_slots = 0,
  }
  local captured_keys = {}
  for _, item in ipairs(captured) do
    local key = Util.item_key(item.name, item.quality or "normal")
    local prototype = prototypes.item[item.name]
    if not prototype then return nil end
    captured_keys[key] = true
    descriptor.existing_by_key[key] = contents[key] or 0
    descriptor.dedicated_by_key[key] = 0
    descriptor.stack_size_by_key[key] = prototype.stack_size
  end
  local accessible_slots = accessible_slot_count(inventory)
  local supports_filters = inventory.supports_filters()
  if next(contents) == nil and inventory.is_empty()
    and (not supports_filters or not inventory.is_filtered()) then
    descriptor.unfiltered_slots = accessible_slots
    return descriptor
  end
  for index = 1, accessible_slots do
    local stack = inventory[index]
    local filter = supports_filters and inventory.get_filter(index) or nil
    local filter_name, filter_quality, filter_comparator = filter_identity(filter)
    if filter and (not filter_name or filter_comparator ~= "=") then return nil end
    if stack.valid_for_read then
      local key = Util.item_key(stack.name, Util.quality_name(stack.quality))
      if captured_keys[key] then
        descriptor.dedicated_by_key[key] = descriptor.dedicated_by_key[key]
          + math.max(0, stack.prototype.stack_size - stack.count)
      end
    else
      if filter then
        local key = Util.item_key(filter_name, filter_quality)
        if captured_keys[key] then
          descriptor.dedicated_by_key[key] = descriptor.dedicated_by_key[key]
            + descriptor.stack_size_by_key[key]
        end
      else
        descriptor.unfiltered_slots = descriptor.unfiltered_slots + 1
      end
    end
  end
  return descriptor
end

local function validate_preflight(instance, target, observation)
  local error_code, point, inventory, trash_inventory = capability_error(
    instance,
    target,
    observation and observation.point or nil,
    observation and observation.inventory or nil,
    observation and observation.trash_inventory or nil
  )
  if error_code then return error_code end
  if has_external_requests(point, nil) then return Constants.ERROR.EXTERNAL_REQUEST end
  if has_compiled_requests(point) then return Constants.ERROR.EXTERNAL_REQUEST end
  if has_pending(point.targeted_items_deliver) or has_pending(point.targeted_items_pickup) then
    return Constants.ERROR.EXTERNAL_DELIVERY
  end
  local trash_valid, trash_error, trash_empty = validate_trash_contents(target, trash_inventory)
  if not trash_valid then return trash_error end
  if not trash_empty then return Constants.ERROR.CONTAMINATION end
  local valid, content_error = validate_contents(
    target,
    false,
    nil,
    inventory,
    observation and observation.contents or nil
  )
  if not valid then return content_error end
  if not (observation and observation.capacity_proven)
    and not validate_capacity(target, inventory, observation and observation.contents or nil) then
    return Constants.ERROR.INSUFFICIENT_CAPACITY
  end
  return nil
end

local function target_unit_number(target)
  local saved = target.unit_number
  if target.entity and target.entity.valid then
    local current = target.entity.unit_number
    if type(current) ~= "number" then return nil end
    if type(saved) == "number" and saved == current then return saved end
    return nil
  end
  return type(saved) == "number" and saved or nil
end

local function cleanup_target_unit_number(target)
  local cleanup_unit = target.cleanup_unit_number
  if type(cleanup_unit) == "number" then
    local entity = target.entity
    if entity and entity.valid then
      return entity.unit_number == cleanup_unit and cleanup_unit or nil
    end
    return cleanup_unit
  end
  return target_unit_number(target)
end

local function cleanup_state_rank(instance)
  if instance.state == Constants.STATE.REQUESTING then return 1 end
  if instance.state == Constants.STATE.ERROR then return 2 end
  return 3
end

local function stable_registry_number(value)
  if type(value) == "number" and value == value
    and value > -math.huge and value < math.huge then
    return value
  end
  return -math.huge
end

local function valid_positive_integer(value)
  return type(value) == "number"
    and value == value
    and value > 0
    and value < math.huge
    and value == math.floor(value)
end

local function stable_scalar_key_identity(value)
  local value_type = type(value)
  if value_type == "number" then
    if value ~= value or value <= -math.huge or value >= math.huge then return "1:" end
    return "1:" .. tostring(value)
  end
  if value_type == "string" then return "2:" .. value end
  if value_type == "boolean" then return value and "3:1" or "3:0" end
  return "4:"
end

local function registry_value_identity(value)
  local entity = type(value) == "table" and value.entity or nil
  local section = type(value) == "table" and value.section or nil
  local section_owner = section and section.valid and section.owner or nil
  return {
    stable_scalar_key_identity(type(value) == "table" and value.key),
    type(value) == "table" and current_owned_section_index(value, section) and 0 or 1,
    type(value) == "table" and owned_section_reference(value, section) and 0 or 1,
    stable_registry_number(type(value) == "table" and value.owner),
    stable_registry_number(entity and entity.valid and entity.unit_number),
    stable_registry_number(type(value) == "table" and value.target_unit_number),
    stable_registry_number(type(value) == "table" and value.claim_unit_number),
    stable_registry_number(section_owner and section_owner.valid and section_owner.unit_number),
    stable_registry_number(section and section.valid and section.index),
    section and section.valid and section.active and 0 or 1,
    stable_registry_number(type(value) == "table" and value.section_destroy_registration),
    stable_registry_number(type(value) == "table" and value.destroy_registration),
  }
end

local function registry_identity_less(left, right)
  for index = 1, #left do
    if left[index] ~= right[index] then return left[index] < right[index] end
  end
  return false
end

local function registry_key_less(registry, left, right)
  local function rank(key)
    if type(key) == "number" then return 1 end
    if type(key) == "string" then return 2 end
    if type(key) == "boolean" then return 3 end
    return 4
  end
  local left_rank = rank(left)
  local right_rank = rank(right)
  if left_rank ~= right_rank then return left_rank < right_rank end
  if left_rank == 1 or left_rank == 2 then return left < right end
  if left_rank == 3 then return left == false and right == true end
  local left_identity = registry_value_identity(registry[left])
  local right_identity = registry_value_identity(registry[right])
  return registry_identity_less(left_identity, right_identity)
end

local function retained_cleanup_claim(root, target_unit, fallback_instance, excluded_tombstone)
  for _, tombstone in pairs(root.override_tombstones or {}) do
    if tombstone.target_unit_number == target_unit then return tombstone.owner, nil end
  end
  local tombstone_keys = {}
  for key in pairs(root.cleanup_tombstones or {}) do tombstone_keys[#tombstone_keys + 1] = key end
  table.sort(tombstone_keys, function(left, right)
    return registry_key_less(root.cleanup_tombstones, left, right)
  end)
  for _, key in ipairs(tombstone_keys) do
    local tombstone = root.cleanup_tombstones[key]
    local entity = tombstone and tombstone.entity
    if tombstone ~= excluded_tombstone
      and Util.valid_entity(entity)
      and entity.unit_number == target_unit
      and owned_section_reference(tombstone, tombstone.section) then
      return tombstone.owner, tombstone
    end
  end

  local instances = {}
  local seen_instances = {}
  for _, instance in pairs(root.instances or {}) do
    if type(instance) == "table" and not seen_instances[instance] then
      seen_instances[instance] = true
      instances[#instances + 1] = instance
    end
  end
  if type(fallback_instance) == "table" and not seen_instances[fallback_instance] then
    instances[#instances + 1] = fallback_instance
  end
  table.sort(instances, function(left, right)
    local left_rank = cleanup_state_rank(left)
    local right_rank = cleanup_state_rank(right)
    if left_rank ~= right_rank then return left_rank < right_rank end
    return (left.unit_number or math.huge) < (right.unit_number or math.huge)
  end)
  for _, instance in ipairs(instances) do
    for _, target in ipairs(instance.targets or {}) do
      local entity = target.entity
      local active_sectionless_claim = (instance.state == Constants.STATE.SETTLING
        or instance.state == Constants.STATE.READY
        or instance.state == Constants.STATE.COMPLETE)
        and instance ~= fallback_instance
        and Util.valid_entity(entity)
        and type(target.unit_number) == "number"
        and target.unit_number == entity.unit_number
      if Util.valid_entity(entity)
        and entity.unit_number == target_unit
        and (owned_section_reference(target, target.section) or active_sectionless_claim) then
        return instance.unit_number, nil
      end
    end
  end
  return nil, nil
end

local function reconcile_cleanup_claim(root, target_unit, releasing_owner, fallback_instance, excluded_tombstone)
  if type(target_unit) ~= "number" then return end
  local current_owner = root.chest_owners[target_unit]
  if current_owner ~= nil and current_owner ~= releasing_owner then return end
  local replacement_owner, replacement_tombstone = retained_cleanup_claim(
    root,
    target_unit,
    fallback_instance,
    excluded_tombstone
  )
  root.chest_owners[target_unit] = replacement_owner
  if replacement_tombstone then replacement_tombstone.claim_unit_number = target_unit end
end

local function clear_owned_destroy_record(root, registration, kind, owner, target_unit)
  if not registration then return end
  local record = root.destroyed[registration]
  if record and record.kind == kind and record.owner == owner
    and (not target_unit or record.target == target_unit) then
    root.destroyed[registration] = nil
  end
end

local function release_target(owner_unit_number, target, preserve_claim, fallback_instance)
  local root = Registry.root()
  local target_unit = cleanup_target_unit_number(target)
  if not preserve_claim then
    reconcile_cleanup_claim(root, target_unit, owner_unit_number, fallback_instance)
  end
  if target.destroy_registration then
    clear_owned_destroy_record(
      root,
      target.destroy_registration,
      "target",
      owner_unit_number,
      target_unit
    )
    target.destroy_registration = nil
  end
  target.cleanup_unit_number = nil
end

function Requests.cleanup_target_unit_number(target)
  return cleanup_target_unit_number(target)
end

function Requests.release_target(instance, target, preserve_claim)
  release_target(instance.unit_number, target, preserve_claim, instance)
end

local function remove_section(target, owner_unit_number)
  local section = target.section
  if not section then return true end
  local root = Registry.root()
  local target_unit = cleanup_target_unit_number(target)
  if not section.valid then
    if target.section_destroy_registration then
      clear_owned_destroy_record(
        root,
        target.section_destroy_registration,
        "section",
        owner_unit_number,
        target_unit
      )
      target.section_destroy_registration = nil
    end
    target.section = nil
    return true
  end
  local entity = target.entity
  if not section.is_manual or not Util.valid_entity(entity) or section.owner ~= entity then return false end
  local point = entity.get_requester_point()
  local index = current_owned_section_index(target, section)
  if not point or not point.valid or not index then return false end
  local deactivated, inactive = pcall(function()
    section.active = false
    return not section.active
  end)
  local removed = false
  if deactivated and inactive and point and point.valid then
    local ok, result = pcall(point.remove_section, index)
    removed = ok and result
  end
  if removed or not section.valid then
    if target.section_destroy_registration then
      clear_owned_destroy_record(
        root,
        target.section_destroy_registration,
        "section",
        owner_unit_number,
        target_unit
      )
      target.section_destroy_registration = nil
    end
    target.section = nil
  end
  return deactivated and inactive and removed
end

function Requests.remove_sections(instance)
  instance.mutating_sections = true
  local success = true
  for _, target in ipairs(instance.targets or {}) do
    if not remove_section(target, instance.unit_number) then success = false end
  end
  instance.mutating_sections = false
  return success
end

function Requests.sections_absent(instance)
  for _, target in ipairs(instance.targets or {}) do
    if target.section ~= nil then return false end
  end
  return true
end

Requests.cleanup_sections = Requests.remove_sections

local function tombstone_key(root, owner_unit_number, target_unit_number, entity, section)
  local base = tostring(owner_unit_number) .. ":" .. tostring(target_unit_number)
  local suffix = 1
  while true do
    local key = suffix == 1 and base or base .. ":" .. tostring(suffix)
    local existing = root.cleanup_tombstones[key]
    if not existing
      or (existing.owner == owner_unit_number
        and existing.target_unit_number == target_unit_number
        and existing.entity == entity
        and existing.section == section) then
      return key
    end
    suffix = suffix + 1
  end
end

function Requests.detach_failed_cleanup(instance, has_unresolved_target)
  local root = Registry.root()
  for _, target in ipairs(instance.targets or {}) do
    local target_unit = cleanup_target_unit_number(target)
    local retained_section = owned_section_reference(target, target.section)
    if retained_section and target_unit and not root.chest_owners[target_unit] then
      root.chest_owners[target_unit] = instance.unit_number
    end
    local still_claimed = target_unit and root.chest_owners[target_unit] == instance.unit_number
    if retained_section then
      clear_owned_destroy_record(
        root,
        target.destroy_registration,
        "target",
        instance.unit_number,
        target_unit
      )
      clear_owned_destroy_record(
        root,
        target.section_destroy_registration,
        "section",
        instance.unit_number,
        target_unit
      )
      target.destroy_registration = nil
      target.section_destroy_registration = nil
      local key = tombstone_key(
        root,
        instance.unit_number,
        target_unit or 0,
        target.entity,
        target.section
      )
      if not root.cleanup_tombstones[key] then
        root.cleanup_order[#root.cleanup_order + 1] = key
      end
      root.cleanup_tombstones[key] = {
        key = key,
        owner = instance.unit_number,
        target_unit_number = target_unit,
        claim_unit_number = still_claimed and target_unit or nil,
        entity = target.entity,
        section = target.section,
      }
      log("[Batch Request Combinator] deferred owned-section cleanup retained for owner "
        .. tostring(instance.unit_number) .. ", target " .. tostring(target_unit))
    else
      if target.section_destroy_registration then
        clear_owned_destroy_record(
          root,
          target.section_destroy_registration,
          "section",
          instance.unit_number,
          target_unit
        )
        target.section_destroy_registration = nil
      end
      target.section = nil
      if not has_unresolved_target(target_unit) then
        release_target(instance.unit_number, target, false, instance)
      else
        release_target(instance.unit_number, target, true, instance)
      end
    end
  end
  table.sort(root.cleanup_order, function(left, right)
    return registry_key_less(root.cleanup_tombstones, left, right)
  end)
  root.cleanup_cursor = 1
end

local function remove_tombstone_at(root, index, key, tombstone, on_section_removed)
  local target_unit = tombstone.claim_unit_number
  root.cleanup_tombstones[key] = nil
  table.remove(root.cleanup_order, index)
  tombstone.claim_unit_number = nil
  on_section_removed(tombstone.owner, tombstone.target_unit_number)
  reconcile_cleanup_claim(root, target_unit, tombstone.owner, nil, tombstone)
  if #root.cleanup_order == 0 then
    root.cleanup_cursor = 1
  else
    root.cleanup_cursor = math.min(index, #root.cleanup_order)
  end
end

function Requests.retry_one_tombstone(on_section_removed, tick)
  local root = Registry.root()
  if #root.cleanup_order == 0 then return true end
  local index = math.min(root.cleanup_cursor or 1, #root.cleanup_order)
  local key = root.cleanup_order[index]
  local tombstone = root.cleanup_tombstones[key]
  if not tombstone then
    table.remove(root.cleanup_order, index)
    root.cleanup_cursor = #root.cleanup_order == 0 and 1 or math.min(index, #root.cleanup_order)
    return true
  end
  tick = tick or (game and game.tick) or 0
  if tick < (tombstone.retry_after_tick or 0) then
    root.cleanup_cursor = (index % #root.cleanup_order) + 1
    return false
  end
  -- Set the deadline before native calls so thrown failures back off as well.
  tombstone.retry_after_tick = tick + Constants.DEFERRED_RETRY_INTERVAL_TICKS
  local called, removed = pcall(remove_section, tombstone, tombstone.owner)
  if not called then
    root.cleanup_cursor = (index % #root.cleanup_order) + 1
    error(removed)
  end
  if removed then
    remove_tombstone_at(root, index, key, tombstone, on_section_removed)
    return true
  else
    root.cleanup_cursor = (index % #root.cleanup_order) + 1
    return false
  end
end

local function normalize_tombstones(root)
  local source = root.cleanup_tombstones
  local entries = {}
  local by_tombstone = {}
  for source_key, tombstone in pairs(source) do
    if type(tombstone) == "table" then
      local entry = by_tombstone[tombstone]
      if not entry then
        entry = {
          tombstone = tombstone,
          source_strings = {},
          source_identity = stable_scalar_key_identity(source_key),
          identity = registry_value_identity(tombstone),
        }
        by_tombstone[tombstone] = entry
        entries[#entries + 1] = entry
      else
        local source_identity = stable_scalar_key_identity(source_key)
        if source_identity < entry.source_identity then entry.source_identity = source_identity end
      end
      if type(source_key) == "string" then entry.source_strings[source_key] = true end
    end
  end

  table.sort(entries, function(left, right)
    local left_tombstone = left.tombstone
    local right_tombstone = right.tombstone
    local left_current = current_owned_section_index(left_tombstone, left_tombstone.section) and 0 or 1
    local right_current = current_owned_section_index(right_tombstone, right_tombstone.section) and 0 or 1
    if left_current ~= right_current then return left_current < right_current end
    local left_owned = owned_section_reference(left_tombstone, left_tombstone.section) and 0 or 1
    local right_owned = owned_section_reference(right_tombstone, right_tombstone.section) and 0 or 1
    if left_owned ~= right_owned then return left_owned < right_owned end
    local left_owner = valid_positive_integer(left_tombstone.owner) and 0 or 1
    local right_owner = valid_positive_integer(right_tombstone.owner) and 0 or 1
    if left_owner ~= right_owner then return left_owner < right_owner end
    if registry_identity_less(left.identity, right.identity) then return true end
    if registry_identity_less(right.identity, left.identity) then return false end
    return left.source_identity < right.source_identity
  end)

  local canonical_entries = {}
  local by_section = {}
  for _, entry in ipairs(entries) do
    local tombstone = entry.tombstone
    local section = tombstone.section
    local section_type = type(section)
    local retained = (section_type == "table" or section_type == "userdata")
      and by_section[section] or nil
    if retained then
      local retained_tombstone = retained.tombstone
      if not retained.merged then
        local original = retained_tombstone
        retained_tombstone = {
          key = original.key,
          owner = original.owner,
          target_unit_number = valid_positive_integer(original.target_unit_number)
            and original.target_unit_number or nil,
          claim_unit_number = valid_positive_integer(original.claim_unit_number)
            and original.claim_unit_number or nil,
          entity = owned_section_reference(original, section) and original.entity or nil,
          section = section,
          section_destroy_registration = valid_positive_integer(original.section_destroy_registration)
            and original.section_destroy_registration or nil,
          destroy_registration = valid_positive_integer(original.destroy_registration)
            and original.destroy_registration or nil,
        }
        retained.tombstone = retained_tombstone
        retained.merged = true
      end
      if not owned_section_reference(retained_tombstone, section)
        and owned_section_reference(tombstone, section) then
        retained_tombstone.entity = tombstone.entity
      end
      local retained_claim = retained_tombstone.claim_unit_number
      local candidate_claim = tombstone.claim_unit_number
      local entity = retained_tombstone.entity
      local live_target = entity and entity.valid and entity.unit_number or nil
      if valid_positive_integer(candidate_claim)
        and (not valid_positive_integer(retained_claim)
          or (candidate_claim == live_target and retained_claim ~= live_target)
          or (candidate_claim ~= live_target and retained_claim ~= live_target
            and candidate_claim < retained_claim)) then
        retained_tombstone.claim_unit_number = candidate_claim
      end
      if not valid_positive_integer(retained_tombstone.target_unit_number)
        and valid_positive_integer(tombstone.target_unit_number) then
        retained_tombstone.target_unit_number = tombstone.target_unit_number
      end
    else
      canonical_entries[#canonical_entries + 1] = entry
      if section_type == "table" or section_type == "userdata" then by_section[section] = entry end
    end
  end

  local canonical_index = 1
  while canonical_index <= #canonical_entries do
    local entry = canonical_entries[canonical_index]
    local group_end = canonical_index
    while group_end + 1 <= #canonical_entries do
      local candidate = canonical_entries[group_end + 1]
      if candidate.source_identity ~= entry.source_identity
        or registry_identity_less(entry.identity, candidate.identity)
        or registry_identity_less(candidate.identity, entry.identity) then
        break
      end
      group_end = group_end + 1
    end
    if group_end > canonical_index
      and owned_section_reference(entry.tombstone, entry.tombstone.section) then
      local all_inactive = true
      for tied_index = canonical_index, group_end do
        local tied_tombstone = canonical_entries[tied_index].tombstone
        local section = tied_tombstone.section
        local deactivated, inactive = pcall(function()
          section.active = false
          return section.active == false
        end)
        if not deactivated or not inactive then all_inactive = false end
      end
      if not all_inactive then
        error("Batch Request Combinator could not quarantine ambiguous cleanup tombstones")
      end
      local removal_failed = false
      for tied_index = canonical_index, group_end do
        local tied_tombstone = canonical_entries[tied_index].tombstone
        local section = tied_tombstone.section
        local current_index = current_owned_section_index(tied_tombstone, section)
        if section.valid and current_index then
          local point = tied_tombstone.entity.get_requester_point()
          if point and point.valid then
            local called, removed = pcall(point.remove_section, current_index)
            if not called or (not removed and section.valid) then removal_failed = true end
          else
            removal_failed = true
          end
        end
        canonical_entries[tied_index].drop_ambiguous = true
      end
      if removal_failed then
        error("Batch Request Combinator could not quarantine ambiguous cleanup tombstones")
      end
    end
    canonical_index = group_end + 1
  end

  local function preferred_key(entry, owner, target_unit)
    local tombstone = entry.tombstone
    local stored_key = tombstone.key
    if type(stored_key) == "string" and entry.source_strings[stored_key] then return stored_key end
    local source_key
    for key in pairs(entry.source_strings) do
      if not source_key or key < source_key then source_key = key end
    end
    if source_key then return source_key end
    if type(stored_key) == "string" then return stored_key end
    return tostring(owner) .. ":" .. tostring(target_unit)
  end

  local rebuilt = {}
  local compact = {}
  local dropped_claim_owners = {}
  for _, entry in ipairs(canonical_entries) do
    local tombstone = entry.tombstone
    if not entry.drop_ambiguous and owned_section_reference(tombstone, tombstone.section) then
      local entity = tombstone.entity
      local target_unit = entity and entity.valid and entity.unit_number or nil
      if not valid_positive_integer(target_unit) then target_unit = tombstone.target_unit_number end
      if not valid_positive_integer(target_unit) then target_unit = tombstone.claim_unit_number end
      if not valid_positive_integer(target_unit) then target_unit = 0 end
      local owner = valid_positive_integer(tombstone.owner) and tombstone.owner or 0
      local base_key = preferred_key(entry, owner, target_unit)
      local retained_key = base_key
      local suffix = 2
      while rebuilt[retained_key] do
        retained_key = base_key .. ":" .. tostring(suffix)
        suffix = suffix + 1
      end
      local key_owner = tonumber(string.match(retained_key, "^([1-9]%d*):"))
      if valid_positive_integer(key_owner) then owner = key_owner end
      tombstone.key = retained_key
      tombstone.owner = owner
      rebuilt[retained_key] = tombstone
      compact[#compact + 1] = retained_key
    else
      if valid_positive_integer(tombstone.claim_unit_number) then
        local claim_unit = tombstone.claim_unit_number
        local claim_owner = valid_positive_integer(tombstone.owner) and tombstone.owner or nil
        if claim_owner == nil then
          local candidate_key = preferred_key(entry, 0, claim_unit)
          local key_owner = tonumber(string.match(candidate_key, "^([1-9]%d*):"))
          if valid_positive_integer(key_owner) then claim_owner = key_owner end
        end
        if claim_owner ~= nil then
          local owners = dropped_claim_owners[claim_unit]
          if not owners then
            owners = {}
            dropped_claim_owners[claim_unit] = owners
          end
          owners[claim_owner] = true
        end
      end
      tombstone.section = nil
      tombstone.claim_unit_number = nil
    end
  end
  root.cleanup_tombstones = rebuilt
  local sorted_dropped_claims = {}
  for target_unit in pairs(dropped_claim_owners) do
    sorted_dropped_claims[#sorted_dropped_claims + 1] = target_unit
  end
  table.sort(sorted_dropped_claims)
  for _, target_unit in ipairs(sorted_dropped_claims) do
    local current_owner = root.chest_owners[target_unit]
    if dropped_claim_owners[target_unit][current_owner] then
      reconcile_cleanup_claim(root, target_unit, current_owner, nil, nil)
    end
  end
  table.sort(compact)
  for _, key in ipairs(compact) do
    local tombstone = root.cleanup_tombstones[key]
    local section = tombstone.section
    if section and section.valid and not owned_section_reference(tombstone, section) then
      tombstone.section = nil
    end
  end
  root.cleanup_order = compact
  root.cleanup_cursor = 1
  return compact
end

function Requests.normalize_tombstones()
  return normalize_tombstones(Registry.root())
end

function Requests.restore_tombstone_claims(section_owners)
  local root = Registry.root()
  local compact = normalize_tombstones(root)
  for _, key in ipairs(compact) do
    local tombstone = root.cleanup_tombstones[key]
    local entity = tombstone.entity
    local section = tombstone.section
    local target_unit = entity and entity.valid and entity.unit_number or nil
    local retained_section = owned_section_reference(tombstone, section)
    tombstone.claim_unit_number = nil
    local existing_section_owner = retained_section and section_owners and section_owners[section] or nil
    if type(target_unit) == "number" and retained_section and not existing_section_owner then
      tombstone.target_unit_number = target_unit
      if section_owners then
        section_owners[section] = {kind = "tombstone", owner = tombstone.owner, target = target_unit}
      end
      if not root.chest_owners[target_unit] then root.chest_owners[target_unit] = tombstone.owner end
      if root.chest_owners[target_unit] == tombstone.owner then
        tombstone.claim_unit_number = target_unit
      end
    elseif retained_section and existing_section_owner then
      tombstone.section = nil
    end
  end
end

local function rollback_setup(instance)
  Requests.cleanup_sections(instance)
end

local function verify_slot(section, index, expected)
  local actual = section.get_slot(index)
  local value = actual and actual.value
  return value
    and value.name == expected.name
    and (value.quality or "normal") == expected.quality
    and (value.type == nil or value.type == "item")
    and value.comparator == "="
    and actual.min == expected.count
    and actual.max == expected.count
end

function Requests.planning_targets(instance, discovered_targets, observations)
  local controllers_by_target = {}
  for _, record in ipairs(instance.monitored_inserters or {}) do
    if record.controlled then
      local controllers = controllers_by_target[record.target_index]
      if not controllers then
        controllers = {}
        controllers_by_target[record.target_index] = controllers
      end
      controllers[#controllers + 1] = record
    end
  end
  local result = {}
  for index, target in ipairs(discovered_targets) do
    local observation = observations and observations[index] or nil
    local _, inventory = observation and observation.point or nil,
      observation and observation.inventory or nil
    if not inventory then _, inventory = target_api(target) end
    if not inventory then return nil, Constants.ERROR.TARGET_LOST end
    local contents = observation and observation.contents or inventory_contents(inventory)
    local descriptor = {min_by_key = {}, max_by_key = {}, transfer_by_key = {}}
    descriptor.joint_capacity = planning_joint_capacity(inventory, contents, instance.captured)
    if not descriptor.joint_capacity then return nil, Constants.ERROR.INSUFFICIENT_CAPACITY end
    local controllers = controllers_by_target[index]
    for _, item in ipairs(instance.captured) do
      local key = Util.item_key(item.name, item.quality or "normal")
      local current = contents[key] or 0
      local insertable_ok, insertable = pcall(inventory.get_insertable_count, {
        name = item.name,
        quality = item.quality or "normal",
      })
      if not insertable_ok then return nil, Constants.ERROR.INSUFFICIENT_CAPACITY end
      descriptor.min_by_key[key] = current
      descriptor.max_by_key[key] = math.min(Constants.MAX_REQUEST_VALUE, current + insertable)
      if controllers then
        local prototype = prototypes.item[item.name]
        if not prototype then return nil, Constants.ERROR.INSUFFICIENT_CAPACITY end
        local transfer
        for _, controller in ipairs(controllers) do
          local candidate = math.min(controller.effective_pickup_count, prototype.stack_size)
          if transfer and candidate ~= transfer then
            return nil, Constants.ERROR.INSERTER_CONFIGURATION
          end
          transfer = candidate
        end
        descriptor.transfer_by_key[key] = transfer
      end
    end
    if observation then observation.capacity_proven = true end
    result[index] = descriptor
  end
  return result, nil
end

function Requests.planning_contents_error(instance, discovered_targets)
  local captured = Util.items_to_map(instance.captured)
  local observations = {}
  for index, target in ipairs(discovered_targets) do
    local point, inventory = target_api(target)
    if not inventory then return Constants.ERROR.TARGET_LOST, target.entity.localised_name end
    local contents = inventory_contents(inventory)
    observations[index] = {
      point = point,
      inventory = inventory,
      trash_inventory = target_trash_inventory(target.entity, inventory),
      contents = contents,
    }
    for key, count in pairs(contents) do
      if not captured[key] then return Constants.ERROR.CONTAMINATION, target.entity.localised_name end
      if count > captured[key] then return Constants.ERROR.EXCESS_ITEMS, target.entity.localised_name end
    end
  end
  return nil, nil, observations
end

function Requests.preflight(instance, target, observation)
  return validate_preflight(instance, target, observation)
end

function Requests.begin_sections(instance)
  local root = Registry.root()
  instance.mutating_sections = true
  for _, target in ipairs(instance.targets) do
    local point = target.entity.get_requester_point()
    local ok, section = pcall(point.add_section)
    if not ok or not section or not section.valid or not section.is_manual then
      rollback_setup(instance)
      return false, Constants.ERROR.INSUFFICIENT_FILTERS, target.entity.localised_name
    end
    target.section = section
    local deactivated = pcall(function()
      section.active = false
      section.multiplier = 1
    end)
    if not deactivated or section.active or section.multiplier ~= 1 then
      rollback_setup(instance)
      return false, Constants.ERROR.REQUEST_WRITE_FAILED, target.entity.localised_name
    end
    target.section_destroy_registration = script.register_on_object_destroyed(section)
    root.destroyed[target.section_destroy_registration] = {
      kind = "section",
      owner = instance.unit_number,
      target = target_unit_number(target),
    }
  end

  for _, target in ipairs(instance.targets) do
    for index, item in ipairs(target.allocation.items) do
      local ok = pcall(target.section.set_slot, index, {
        value = {
          type = "item",
          name = item.name,
          quality = item.quality,
          comparator = "=",
        },
        min = item.count,
        max = item.count,
      })
      local verify_ok, verified = pcall(verify_slot, target.section, index, item)
      if not ok or not verify_ok or not verified then
        rollback_setup(instance)
        return false, Constants.ERROR.INSUFFICIENT_FILTERS, target.entity.localised_name
      end
    end
  end

  for _, target in ipairs(instance.targets) do
    local activated, active = pcall(function()
      target.section.active = true
      return target.section.active
    end)
    if not activated or not active then
      rollback_setup(instance)
      return false, Constants.ERROR.REQUEST_WRITE_FAILED, target.entity.localised_name
    end
  end
  instance.mutating_sections = false
  return true
end

local function verify_owned_section(target, observed_point)
  local section = target.section
  if not section or not current_owned_section_index(target, section, observed_point) then return false end
  if not section.active or section.multiplier ~= 1 then return false end
  if section.filters_count ~= #target.allocation.items then return false end
  for index, item in ipairs(target.allocation.items) do
    if not verify_slot(section, index, item) then return false end
  end
  return true
end

local function valid_positive_item_count(count)
  return type(count) == "number"
    and count == count
    and count == math.floor(count)
    and count > 0
    and count <= Constants.MAX_REQUEST_VALUE
end

local function valid_item_identity(item)
  local quality = item.quality or "normal"
  if type(item.name) ~= "string" or type(quality) ~= "string" then return false end
  if prototypes and prototypes.item and not prototypes.item[item.name] then return false end
  if prototypes and prototypes.quality and not prototypes.quality[quality] then return false end
  return true
end

local function valid_reconciled_batch(instance)
  if type(instance.captured) ~= "table" or #instance.captured == 0
    or type(instance.captured_total) ~= "number" or instance.captured_total <= 0
    or type(instance.targets) ~= "table" or #instance.targets == 0 then
    return false
  end

  local captured_by_key = {}
  local captured_total = 0
  for _, item in ipairs(instance.captured) do
    if type(item) ~= "table" or not valid_item_identity(item)
      or not valid_positive_item_count(item.count) then
      return false
    end
    local key = Util.item_key(item.name, item.quality or "normal")
    if captured_by_key[key] then return false end
    captured_by_key[key] = item.count
    captured_total = captured_total + item.count
  end
  if captured_total ~= instance.captured_total then return false end

  local allocated_by_key = {}
  local allocated_total = 0
  for _, target in ipairs(instance.targets) do
    local allocation = target.allocation
    if type(allocation) ~= "table" or type(allocation.items) ~= "table"
      or type(allocation.by_key) ~= "table" or type(allocation.total) ~= "number" then
      return false
    end
    local target_total = 0
    local target_by_key = {}
    for _, item in ipairs(allocation.items) do
      if type(item) ~= "table" or not valid_item_identity(item)
        or not valid_positive_item_count(item.count) then
        return false
      end
      local key = Util.item_key(item.name, item.quality or "normal")
      if target_by_key[key] then return false end
      target_by_key[key] = item.count
      target_total = target_total + item.count
      allocated_by_key[key] = (allocated_by_key[key] or 0) + item.count
    end
    if target_total ~= allocation.total then return false end
    for key, count in pairs(allocation.by_key) do
      if target_by_key[key] ~= count then return false end
    end
    for key, count in pairs(target_by_key) do
      if allocation.by_key[key] ~= count then return false end
    end
    allocated_total = allocated_total + target_total
  end
  if allocated_total ~= captured_total then return false end
  for key, count in pairs(captured_by_key) do
    if allocated_by_key[key] ~= count then return false end
  end
  for key, count in pairs(allocated_by_key) do
    if captured_by_key[key] ~= count then return false end
  end
  return true
end

function Requests.validate(instance, require_section, reject_deliveries, collect_observations)
  local root = Registry.root()
  local seen_targets = {}
  local observations = collect_observations and {} or nil
  for index, target in ipairs(instance.targets or {}) do
    if not target.entity or not target.entity.valid then return false, Constants.ERROR.TARGET_LOST end
    local target_unit = target_unit_number(target)
    if not target_unit then return false, Constants.ERROR.TARGET_LOST end
    if seen_targets[target_unit] then return false, Constants.ERROR.TARGET_CONFLICT end
    seen_targets[target_unit] = true
    if root.chest_owners[target_unit] ~= instance.unit_number then
      return false, Constants.ERROR.TARGET_CONFLICT
    end
    local error_code, point, inventory, trash_inventory = capability_error(instance, target)
    if error_code then return false, error_code, target.entity.localised_name end
    if require_section and not verify_owned_section(target, point) then
      return false, Constants.ERROR.SECTION_LOST, target.entity.localised_name
    end
    if reject_deliveries and (has_pending(point.targeted_items_deliver) or has_pending(point.targeted_items_pickup)) then
      return false, Constants.ERROR.EXTERNAL_DELIVERY, target.entity.localised_name
    end
    if observations then
      observations[index] = {
        point = point,
        inventory = inventory,
        trash_inventory = trash_inventory,
        target_unit_number = target_unit,
      }
    end
  end
  return true, nil, nil, observations
end

function Requests.progress(instance, observations)
  local all_exact = true
  local staged = 0
  local source_total = 0
  local collect_poll_totals = poll_totals_requested(instance)
  local pending_deliveries = collect_poll_totals and 0 or nil
  for index, target in ipairs(instance.targets or {}) do
    local observed = observations and observations[index] or nil
    local point, inventory, trash_inventory
    if observed then
      point = observed.point
      inventory = observed.inventory
      trash_inventory = observed.trash_inventory
    else
      point, inventory = target_api(target)
      trash_inventory = inventory and target_trash_inventory(target.entity, inventory) or nil
    end
    local allow_allocated_excess = point and point.valid and point.exact ~= true
    local valid, error_code, _, exact, target_staged, target_source_total = validate_contents(
      target,
      false,
      allow_allocated_excess,
      inventory
    )
    if not valid then return false, error_code, staged end
    local trash_valid, trash_error, trash_empty, trash_total = validate_trash_contents(
      target,
      trash_inventory
    )
    if not trash_valid then return false, trash_error, staged end
    local target_pending = has_pending(point and point.targeted_items_deliver)
      or has_pending(point and point.targeted_items_pickup)
    all_exact = all_exact and exact and trash_empty and not target_pending
    staged = staged + target_staged
    source_total = source_total + target_source_total + trash_total
    target.staged = target_staged
    if collect_poll_totals and point and point.valid then
      pending_deliveries = pending_deliveries
        + pending_total(point.targeted_items_deliver)
        + pending_total(point.targeted_items_pickup)
    end
  end
  instance.staged_total = staged
  cache_poll_totals(instance, source_total, pending_deliveries, collect_poll_totals)
  return all_exact, nil, staged
end

function Requests.settled(instance)
  local valid, error_code, _, observations = Requests.validate(instance, false, false, true)
  if not valid then return false, error_code, false end
  local collect_poll_totals = poll_totals_requested(instance)
  local pending_deliveries = 0
  local pending = false
  for index, target in ipairs(instance.targets or {}) do
    local observed = observations[index]
    local point = observed.point
    local target_pending = has_pending(point.targeted_items_deliver)
      or has_pending(point.targeted_items_pickup)
    local trash_valid, trash_error, trash_empty, trash_total = validate_trash_contents(
      target,
      observed.trash_inventory
    )
    if not trash_valid then return false, trash_error, false end
    if (target_pending or not trash_empty) and not collect_poll_totals then
      return false, nil, true
    end
    pending = pending or target_pending
    if collect_poll_totals then
      pending_deliveries = pending_deliveries
        + pending_total(point.targeted_items_deliver)
        + pending_total(point.targeted_items_pickup)
    end
    observed.trash_total = trash_total
    if not trash_empty then pending = true end
  end
  if pending then
    local source_total = 0
    for index in ipairs(instance.targets or {}) do
      source_total = source_total + inventory_total(observations[index].inventory)
        + (observations[index].trash_total or 0)
    end
    cache_poll_totals(instance, source_total, pending_deliveries, collect_poll_totals)
    return false, nil, true
  end
  local source_total = 0
  for index, target in ipairs(instance.targets or {}) do
    local exact, content_error, _, _, _, target_source_total =
      validate_contents(target, true, nil, observations[index].inventory)
    if not exact then return false, content_error, false end
    source_total = source_total + target_source_total
  end
  cache_poll_totals(instance, source_total, 0)
  return true, nil, false
end

function Requests.capture_ready_counts(instance)
  instance.ready_counts = {}
  for _, target in ipairs(instance.targets or {}) do
    local _, inventory = target_api(target)
    instance.ready_counts[target_unit_number(target)] = inventory_contents(inventory)
  end
end

function Requests.pending_delivery_count(instance)
  local cached = cached_poll_totals(instance)
  if cached and cached.pending_deliveries ~= nil then return cached.pending_deliveries end
  local total = 0
  for _, target in ipairs(instance.targets or {}) do
    local point = target.entity and target.entity.valid and target.entity.get_requester_point() or nil
    if point and point.valid then
      for _, entry in pairs(point.targeted_items_deliver or {}) do total = total + (entry.count or 0) end
      for _, entry in pairs(point.targeted_items_pickup or {}) do total = total + (entry.count or 0) end
    end
  end
  return total
end

function Requests.remaining_source_count(instance)
  local cached = cached_poll_totals(instance)
  if cached and cached.remaining_source ~= nil then return cached.remaining_source end
  local total = 0
  for _, target in ipairs(instance.targets or {}) do
    local _, inventory = target_api(target)
    if inventory then
      total = total + inventory_total(inventory)
      local trash_inventory = target_trash_inventory(target.entity, inventory)
      if trash_inventory then total = total + inventory_total(trash_inventory) end
    end
  end
  return total
end

function Requests.validate_ready(instance, collect_tail_observations)
  if collect_tail_observations == nil then collect_tail_observations = true end
  local valid, error_code, detail, observations = Requests.validate(instance, false, true, true)
  if not valid then return false, error_code, detail end
  local staged = 0
  local source_total = 0
  local source_drained = true
  local contents_by_target = collect_tail_observations and {} or nil
  for index, target in ipairs(instance.targets or {}) do
    local inventory = observations[index].inventory
    if has_inaccessible_items(inventory) then
      return false, Constants.ERROR.INACCESSIBLE_ITEMS, target.entity.localised_name
    end
    local contents = inventory_contents(inventory)
    local trash_valid, trash_error, trash_empty = validate_trash_contents(
      target,
      observations[index].trash_inventory
    )
    if not trash_valid then return false, trash_error, target.entity.localised_name end
    if not trash_empty then
      return false, Constants.ERROR.DELIVERY_MISMATCH, target.entity.localised_name
    end
    local target_unit = target_unit_number(target)
    if contents_by_target then
      observations[index].contents = contents
      observations[index].pending = false
      contents_by_target[target_unit] = observations[index]
    end
    if next(contents) ~= nil then source_drained = false end
    local previous = instance.ready_counts[target_unit] or {}
    for _, key in ipairs(Util.sorted_keys(contents)) do
      local count = contents[key]
      local allocated = target.allocation.by_key[key]
      if not allocated then
        return false, Constants.ERROR.CONTAMINATION, target.entity.localised_name
      end
      if count > allocated then
        return false, Constants.ERROR.DELIVERY_MISMATCH, target.entity.localised_name
      end
      if count > (previous[key] or 0) then
        return false, Constants.ERROR.DELIVERY_MISMATCH, target.entity.localised_name
      end
      staged = staged + count
      source_total = source_total + count
    end
    instance.ready_counts[target_unit] = contents
  end
  instance.staged_total = staged
  cache_poll_totals(instance, source_total, 0)
  observations.source_drained = source_drained
  observations.contents_by_target = contents_by_target
  return true, nil, nil, observations
end

function Requests.source_drained(instance, observations)
  if observations and observations.source_drained ~= nil then
    return observations.source_drained
  end
  for _, target in ipairs(instance.targets or {}) do
    local _, inventory = target_api(target)
    if not inventory or not inventory.valid or not inventory.is_empty() then return false end
    local trash_inventory = target_trash_inventory(target.entity, inventory)
    if trash_inventory and not trash_inventory.is_empty() then return false end
  end
  return true
end

local function valid_reconciled_ready_counts(instance)
  local expected_targets = {}
  for _, target in ipairs(instance.targets) do
    local target_unit = target_unit_number(target)
    local previous = target_unit and instance.ready_counts[target_unit] or nil
    if not target_unit or type(previous) ~= "table" then return false end
    expected_targets[target_unit] = target
    for key, count in pairs(previous) do
      local allocated = target.allocation.by_key[key]
      if type(key) ~= "string" or type(allocated) ~= "number"
        or type(count) ~= "number" or count ~= count or count ~= math.floor(count)
        or count < 0 or count > allocated or count > Constants.MAX_REQUEST_VALUE then
        return false
      end
    end
  end
  for target_unit, previous in pairs(instance.ready_counts) do
    if type(target_unit) ~= "number" or type(previous) ~= "table"
      or not expected_targets[target_unit] then
      return false
    end
  end
  return true
end

function Requests.validate_reconciled_state(instance)
  local state = instance.state
  if state ~= Constants.STATE.REQUESTING
    and state ~= Constants.STATE.SETTLING
    and state ~= Constants.STATE.READY
    and state ~= Constants.STATE.COMPLETE then
    return true
  end
  if not valid_reconciled_batch(instance) then
    return false, Constants.ERROR.DELIVERY_MISMATCH
  end
  if state == Constants.STATE.REQUESTING then
    local valid, error_code, error_detail, observations = Requests.validate(instance, true, false, true)
    if not valid then return false, error_code, error_detail end
    for index, target in ipairs(instance.targets) do
      local observation = observations[index]
      local contents_valid, content_error = validate_contents(
        target,
        false,
        observation.point.exact ~= true,
        observation.inventory
      )
      if not contents_valid then return false, content_error, target.entity.localised_name end
      local trash_valid, trash_error = validate_trash_contents(target, observation.trash_inventory)
      if not trash_valid then return false, trash_error, target.entity.localised_name end
      if not validate_capacity(target, observation.inventory) then
        return false, Constants.ERROR.INSUFFICIENT_CAPACITY, target.entity.localised_name
      end
    end
    return true
  end
  for _, target in ipairs(instance.targets) do
    if target.section ~= nil then return false, Constants.ERROR.SECTION_LOST end
  end
  if state == Constants.STATE.SETTLING then
    local _, settle_error = Requests.settled(instance)
    if settle_error then return false, settle_error end
    return true
  end
  if type(instance.ready_counts) ~= "table" then
    return false, Constants.ERROR.DELIVERY_MISMATCH
  end
  if not valid_reconciled_ready_counts(instance) then
    return false, Constants.ERROR.DELIVERY_MISMATCH
  end
  local valid, error_code, error_detail = Requests.validate_ready(instance)
  if not valid then return false, error_code, error_detail end
  if state == Constants.STATE.COMPLETE and not Requests.source_drained(instance) then
    return false, Constants.ERROR.DELIVERY_MISMATCH
  end
  return true
end

return Requests
