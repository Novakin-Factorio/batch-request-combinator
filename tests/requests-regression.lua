package.path = "./?.lua;" .. package.path

local Constants = require("runtime.constants")
local TailPlanner = require("runtime.tail_planner")
local Util = require("runtime.util")
local root
package.loaded["runtime.registry"] = {root = function() return root end}
package.loaded["runtime.target_discovery"] = {validate_cached_endpoint = function() return true end}
defines = {inventory = {chest = 1}, logistic_mode = {requester = 1}}
log = function() end
local registrations, next_registration = {}, 0
script = {register_on_object_destroyed = function(object)
  if not registrations[object] then
    next_registration = next_registration + 1
    registrations[object] = next_registration
  end
  return registrations[object]
end}
local Requests = require("runtime.requests")
local force, surface = {index = 1}, {index = 1}

local function reset_root()
  root = {
    chest_owners = {}, instances = {}, destroyed = {}, override_tombstones = {},
    cleanup_tombstones = {}, cleanup_order = {},
  }
end

-- Model native section identity, indexed lookup, and index changes after removal.
local function target(unit, options)
  options = options or {}
  local inventory = options.inventory or {valid = true}
  local point = {
    valid = true, mode = defines.logistic_mode.requester, enabled = true,
    exact = true, trash_not_requested = false, sections = {}, filters = {},
  }
  local entity = {
    valid = true, unit_number = unit, force = force, surface = surface,
    position = {x = unit, y = 0}, localised_name = "requester " .. unit,
    get_inventory = function() return inventory end,
    get_control_behavior = function() return nil end,
  }
  entity.get_requester_point = function()
    if options.lookup_failure then error("requester lookup failed") end
    return point
  end
  function point.get_section(index)
    assert(index >= 1 and index <= #point.sections, "native section index out of range")
    return point.sections[index]
  end
  function point.add_section()
    local slots = {}
    local section = {
      valid = true, is_manual = true, owner = entity, index = #point.sections + 1,
      active = true, multiplier = options.multiplier or 1, filters_count = 0, filters = slots,
    }
    function section.set_slot(index, filter)
      if options.write_failure then error("slot write failed") end
      slots[index] = filter
      section.filters_count = #slots
    end
    function section.get_slot(index) return slots[index] end
    point.sections[#point.sections + 1] = section
    return section
  end
  function point.remove_section(index)
    options.removal_attempts = (options.removal_attempts or 0) + 1
    if options.remove_blocked then return false end
    local section = point.get_section(index)
    if not section.is_manual then return false end
    assert(not section.active, "owned requests must deactivate before removal")
    section.valid = false
    table.remove(point.sections, index)
    for current_index, current in ipairs(point.sections) do current.index = current_index end
    return true
  end
  root.chest_owners[unit] = 1
  return {
    entity = entity, unit_number = unit,
    allocation = {items = {{name = "iron-plate", quality = "normal", count = 100}}},
  }, point, options
end

local function instance(targets)
  return {unit_number = 1, entity = {force = force, surface = surface}, targets = targets}
end

reset_root()
local first, point = target(10, {multiplier = 0.5})
local batch = instance({first})
assert(Requests.begin_sections(batch), "request creation")
assert(first.section.active and first.section.multiplier == 1, "new owned section uses exact multiplier")
assert(Requests.validate(batch, true, false, true), "unchanged section validates")
for _, multiplier in ipairs{0, 0.5, 2} do
  first.section.multiplier = multiplier
  local valid, code = Requests.validate(batch, true, false, true)
  assert(not valid and code == Constants.ERROR.SECTION_LOST, "changed multiplier fails closed")
end
first.section.multiplier = 1

local original = first.section
local foreign = point.add_section()
table.remove(point.sections, 2)
table.insert(point.sections, 1, foreign)
foreign.index, original.index = 1, 2
assert(Requests.has_current_owned_section(first), "current index locates owned section")
foreign.active = false
point.remove_section(1)
local other = point.add_section()
assert(original.index == 1 and other.index == 2)
assert(Requests.cleanup_sections(batch), "cleanup follows shifted index")
assert(other.valid and other.active and point.sections[1] == other, "foreign section survives cleanup")
assert(first.section == nil and not original.valid)

first.section = original
assert(Requests.cleanup_sections(batch), "destroyed saved section is harmless")
first.section = other
local another_point_section = {valid = true, is_manual = true, owner = first.entity, index = 1, active = true}
first.section = another_point_section
assert(not Requests.cleanup_sections(batch), "same entity alone does not prove requester-point membership")
assert(other.valid and another_point_section.active, "failed membership proof performs no deletion")
another_point_section.index = 50
assert(not Requests.has_current_owned_section(first), "out-of-range native lookup fails closed")

reset_root()
local ready, ready_point = target(20)
local failed = target(30, {write_failure = true})
batch = instance({ready, failed})
assert(not Requests.begin_sections(batch), "partial write fails")
assert(ready.section == nil and failed.section == nil and #ready_point.sections == 0,
  "partial creation rolls back every owned section")
assert(not batch.mutating_sections and next(root.destroyed) == nil, "rollback clears mutation guard and registrations")

reset_root()
local released_target = target(15)
batch = instance({released_target})
Requests.release_target(batch, released_target, true)
assert(root.chest_owners[15] == 1, "preserved cleanup target keeps its claim")
Requests.release_target(batch, released_target, false)
assert(root.chest_owners[15] == nil, "healthy cleanup releases its owned claim")
local recovery_section = {
  valid = true,
  is_manual = true,
  owner = released_target.entity,
}
root.instances[2] = {
  unit_number = 2,
  state = Constants.STATE.ERROR,
  targets = {{
    entity = released_target.entity,
    unit_number = released_target.unit_number,
    section = recovery_section,
  }},
}
root.chest_owners[15] = batch.unit_number
Requests.release_target(batch, released_target, false)
assert(root.chest_owners[15] == 2,
  "healthy cleanup transfers ownership to unresolved recovery")

reset_root()
local blocked, _, blocked_options = target(20, {remove_blocked = true})
ready = target(30)
batch = instance({blocked, ready})
assert(Requests.begin_sections(batch))
local blocked_section, ready_section = blocked.section, ready.section
Requests.detach_failed_cleanup(batch, function() return false end)
local released = {}
local function on_removed(_, unit) released[#released + 1] = unit end
assert(not Requests.retry_one_tombstone(on_removed, 100), "blocked record waits")
assert(not blocked_section.active and blocked_section.valid and root.chest_owners[20] == 1,
  "failed cleanup keeps ownership and lowers requests")
assert(Requests.retry_one_tombstone(on_removed, 101), "unrelated ready record cleans next tick")
assert(not ready_section.valid and root.chest_owners[30] == nil and released[1] == 30)
assert(not Requests.retry_one_tombstone(on_removed, 159))
assert(blocked_options.removal_attempts == 1, "blocked native write is not retried early")
Requests.normalize_tombstones()
package.loaded["runtime.requests"] = nil
Requests = require("runtime.requests")
assert(not Requests.retry_one_tombstone(on_removed, 159))
assert(blocked_options.removal_attempts == 1, "saved retry deadline survives module reload and normalization")
blocked_options.remove_blocked = false
assert(Requests.retry_one_tombstone(on_removed, 160))
assert(root.chest_owners[20] == nil and #root.cleanup_order == 0 and released[2] == 20)

reset_root()
local shared_claim = target(35)
local sibling_claim = {
  entity = shared_claim.entity,
  unit_number = shared_claim.unit_number,
  allocation = shared_claim.allocation,
}
batch = instance({shared_claim, sibling_claim})
assert(Requests.begin_sections(batch))
Requests.detach_failed_cleanup(batch, function() return false end)
root.cleanup_tombstones[root.cleanup_order[2]].claim_unit_number = nil
assert(#root.cleanup_order == 2 and Requests.retry_one_tombstone(on_removed, 170),
  "first shared-target tombstone cleans")
local retained_claim = root.cleanup_tombstones[root.cleanup_order[1]]
assert(root.chest_owners[35] == 1 and retained_claim.claim_unit_number == 35,
  "surviving shared-target tombstone retains ownership")
assert(Requests.retry_one_tombstone(on_removed, 171) and root.chest_owners[35] == nil,
  "last shared-target tombstone releases ownership")

reset_root()
local throwing, _, throwing_options = target(20)
ready = target(30)
batch = instance({throwing, ready})
assert(Requests.begin_sections(batch))
Requests.detach_failed_cleanup(batch, function() return false end)
throwing_options.lookup_failure = true
assert(not pcall(Requests.retry_one_tombstone, on_removed, 200), "native lookup exception propagates for diagnostics")
assert(Requests.retry_one_tombstone(on_removed, 201), "throwing record does not pin queue cursor")
assert(not Requests.retry_one_tombstone(on_removed, 202), "throwing record still backs off")
throwing_options.lookup_failure = false
assert(Requests.retry_one_tombstone(on_removed, 260))

-- Occupied slots whose exact filters disagree with their contents cannot accept more of that content.
local iron_key = Util.item_key("iron-plate", "normal")
prototypes = {item = {
  ["iron-plate"] = {stack_size = 100},
  ["copper-plate"] = {stack_size = 100},
}}
local filtered_inventory = {
  valid = true,
  [1] = {
    valid_for_read = true,
    name = "iron-plate",
    quality = "normal",
    count = 50,
    prototype = prototypes.item["iron-plate"],
  },
  [2] = {valid_for_read = false},
}
local occupied_filter
function filtered_inventory.supports_bar() return false end
function filtered_inventory.supports_filters() return true end
function filtered_inventory.get_filter(index)
  return index == 1 and occupied_filter or nil
end
function filtered_inventory.get_insertable_count() return 100 end
reset_root()
local capacity_target, capacity_point = target(50, {inventory = filtered_inventory})
local capacity_instance = instance({capacity_target})
capacity_instance.monitored_inserters = {}
local capacity_observation = {
  point = capacity_point,
  inventory = filtered_inventory,
  contents = {[iron_key] = 50},
}
for _, mismatch in ipairs{
  {name = "copper-plate", quality = "normal"},
  {name = "iron-plate", quality = "uncommon"},
} do
  occupied_filter = {name = mismatch.name, quality = mismatch.quality, comparator = "="}
  local filtered_key = Util.item_key(mismatch.name, mismatch.quality)
  capacity_instance.captured = {
    {name = "iron-plate", quality = "normal", count = 100},
    {name = mismatch.name, quality = mismatch.quality, count = 100},
  }
  capacity_target.allocation = {
    by_key = {[iron_key] = 100, [filtered_key] = 100},
    items = capacity_instance.captured,
  }
  capacity_observation.capacity_proven = nil
  assert(Requests.preflight(capacity_instance, capacity_target, capacity_observation)
      == Constants.ERROR.INSUFFICIENT_CAPACITY,
    "mismatched occupied filter does not provide shared capacity")
  local descriptors = assert(Requests.planning_targets(
    capacity_instance,
    {capacity_target},
    {capacity_observation}
  ))
  assert(not TailPlanner.plan(capacity_instance.captured, descriptors, Constants.TAIL_MODE.NO_TAIL),
    "planner rejects allocations that compete for one unfiltered slot")
end

-- Exercise extracted reconciliation with shared saved tables, preserving native objects.
local Reconciliation = require("runtime.reconciliation")
reset_root()
local shared = target(40)
local shared_targets = {shared}
root.instances = {[1] = {targets = shared_targets}, [2] = {targets = shared_targets}}
local conflicts = 0
Reconciliation.normalize_target_aliases(root, {1, 2}, {}, function() conflicts = conflicts + 1 end)
assert(root.instances[1].targets ~= root.instances[2].targets, "reconciliation isolates shared target arrays")
assert(root.instances[1].targets[1] ~= root.instances[2].targets[1], "reconciliation isolates shared target records")
assert(root.instances[2].targets[1].entity == shared.entity, "reconciliation preserves native identity")
assert(conflicts > 0, "aliased ownership is flagged for caller reconciliation")

print("Requester and reconciliation regressions passed")
