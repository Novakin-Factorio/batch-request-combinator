package.path = "./?.lua;./?/init.lua;" .. package.path

local function equal(actual, expected, label)
  assert(actual == expected, label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local Constants = require("runtime.constants")
local Util = require("runtime.util")

-- Existing input and ordering contracts.
local CircuitInput = require("runtime.circuit_input")
local signals = {
  {signal = {type = "item", name = "iron-plate"}, count = 10},
  {signal = {type = "item", name = "iron-plate"}, count = -3},
  {signal = {type = "item", name = "iron-plate", quality = "uncommon"}, count = -4},
  {signal = {type = "item", name = "copper-plate"}, count = -6},
  {signal = {type = "item", name = "copper-plate"}, count = 1},
  {signal = {type = "virtual", name = "signal-A"}, count = 100},
}
local function exists() return true end
equal(CircuitInput.snapshot(signals, Constants.SIGN_MODE.ANY, exists, exists).total, 16,
  "any-sign input aggregation")
equal(CircuitInput.snapshot(signals, Constants.SIGN_MODE.POSITIVE, exists, exists).total, 7,
  "positive input aggregation")
equal(CircuitInput.snapshot(signals, Constants.SIGN_MODE.NEGATIVE, exists, exists).total, 9,
  "negative input aggregation")

local Allocation = require("runtime.allocation")
local targets = {
  {entity = {surface = {index = 2}, position = {x = 0, y = 0}, unit_number = 9}},
  {entity = {surface = {index = 1}, position = {x = 2, y = 0}, unit_number = 8}},
  {entity = {surface = {index = 1}, position = {x = 1, y = 5}, unit_number = 7}},
  {entity = {surface = {index = 1}, position = {x = 1, y = 5}, unit_number = 6}},
}
Allocation.sort_targets(targets)
equal(table.concat({
  targets[1].entity.unit_number,
  targets[2].entity.unit_number,
  targets[3].entity.unit_number,
  targets[4].entity.unit_number,
}, ","), "6,7,8,9", "target ordering")

-- The scheduler visits each queue every tick; records own their retry deadlines.
local scheduler_root = {
  temporary_overrides = {},
  cleanup_order = {"cleanup-1", "cleanup-2"},
  drain_order = {"drain-1", "drain-2"},
  instances = {},
  open_gui_instances = {},
  debug = {},
}
local cleanup_retries, drain_retries = 0, 0
local cleanup_resolves, drain_resolves = true, true
package.loaded["runtime.registry"] = {
  root = function() return scheduler_root end,
  bucket_for_tick = function() return {} end,
}
package.loaded["runtime.batch_coordinator"] = {
  retry_one_tombstone = function()
    cleanup_retries = cleanup_retries + 1
    if not cleanup_resolves then return false end
    table.remove(scheduler_root.cleanup_order, 1)
    return true
  end,
}
package.loaded["runtime.drain"] = {
  retry_one_tombstone = function()
    drain_retries = drain_retries + 1
    if not drain_resolves then return false end
    table.remove(scheduler_root.drain_order, 1)
    return true
  end,
}
package.loaded["runtime.debug"] = {set_last_profiler = function() end}
package.loaded["runtime.inserter_controller"] = {process_temporary_overrides = function() return {} end}
package.loaded["runtime.output_status"] = {fail_safe_off = function() end}
package.loaded["runtime.state_machine"] = {process = function() end, on_runtime_error = function() end}
settings = {global = {[Constants.SETTING_DEBUG] = {value = false}}}
log = function() end
package.loaded["runtime.scheduler"] = nil
local Scheduler = require("runtime.scheduler")
for _, tick in ipairs{0, 1} do Scheduler.on_tick({tick = tick}, function() end) end
equal(cleanup_retries, 2, "successful cleanup throughput")
equal(drain_retries, 2, "successful drain throughput")
equal(#scheduler_root.cleanup_order, 0, "successful cleanup queue drained")
equal(#scheduler_root.drain_order, 0, "successful drain queue drained")
scheduler_root.cleanup_order[1] = "blocked-cleanup"
scheduler_root.drain_order[1] = "blocked-drain"
cleanup_resolves, drain_resolves = false, false
for _, tick in ipairs{2, 3, 61, 62} do Scheduler.on_tick({tick = tick}, function() end) end
equal(cleanup_retries, 6, "blocked cleanup does not suppress queue visits")
equal(drain_retries, 6, "blocked drain does not suppress queue visits")

-- Inserter setup is explicit, scope-bound, reversible on failure, and preserves stack overrides.
defines = {wire_connector_id = {combinator_output_red = 1, combinator_output_green = 2}}
local discovery_behavior = {valid = true, input_networks = {red = false, green = false}}
local discovery_parent = {valid = true, unit_number = 1}
local discovery_inserter = {
  valid = true,
  unit_number = 2,
  type = "inserter",
  get_control_behavior = function() return discovery_behavior end,
}
local discovery_root = {valid = true, network_id = 7}
function discovery_parent.get_wire_connector(connector_id)
  return connector_id == defines.wire_connector_id.combinator_output_red and discovery_root or nil
end
local discovery_endpoints = {{
  connector = {valid = true, owner = discovery_inserter, wire_connector_id = 3, network_id = 7},
  connector_id = 3,
  root_connector_id = defines.wire_connector_id.combinator_output_red,
  network_id = 7,
}}
local RealTargetDiscovery = require("runtime.target_discovery")
local physically_connected, connected_red, connected_green = RealTargetDiscovery.connected_input_networks(
  discovery_parent,
  discovery_inserter,
  discovery_endpoints
)
assert(physically_connected and connected_red and not connected_green,
  "physical endpoint discovery ignores disabled input selection")
assert(not RealTargetDiscovery.validate_cached_endpoint(discovery_parent, discovery_inserter, discovery_endpoints),
  "ordinary topology validation still requires a selected input")
discovery_behavior.input_networks.red = true
assert(RealTargetDiscovery.validate_cached_endpoint(discovery_parent, discovery_inserter, discovery_endpoints),
  "ordinary topology validation accepts a selected connected input")

local discovered_targets
local discovered_inserters
local setup_red, setup_green = true, false
package.loaded["runtime.target_discovery"] = {
  discover = function()
    local endpoints = {}
    for _, inserter in ipairs(discovered_inserters) do endpoints[inserter.unit_number] = {true} end
    return discovered_targets, discovered_inserters, endpoints
  end,
  connected_input_networks = function() return true, setup_red, setup_green end,
}
local setup_root = {
  chest_owners = {},
  inserter_owners = {},
  instances = {},
  temporary_overrides = {},
  override_tombstones = {},
}
package.loaded["runtime.registry"] = {root = function() return setup_root end}
package.loaded["runtime.inserter_controller"] = nil
local InserterController = require("runtime.inserter_controller")

-- Failed temporary stack restoration backs off without delaying its first next-tick attempt.
local retry_override = 1
local retry_writes = 0
local retry_blocked = true
local retry_inserter = setmetatable({
  valid = true,
  type = "inserter",
  unit_number = 50,
  localised_name = "retry inserter",
}, {
  __index = function(_, key)
    if key == "inserter_stack_size_override" then return retry_override end
  end,
  __newindex = function(target, key, value)
    if key ~= "inserter_stack_size_override" then
      rawset(target, key, value)
      return
    end
    retry_writes = retry_writes + 1
    if retry_blocked then error("simulated stack override restore failure") end
    retry_override = value
  end,
})
local retry_record = {
  entity = retry_inserter,
  unit_number = retry_inserter.unit_number,
  original_override = 3,
  temporary_override = {
    written_override = retry_override,
    written_tick = 100,
    held_count = 0,
  },
}
local retry_instance = {unit_number = 49, monitored_inserters = {retry_record}}
setup_root.instances[retry_instance.unit_number] = retry_instance
setup_root.temporary_overrides[retry_record.unit_number] = retry_instance.unit_number
local previous_game = game
game = {tick = 100}
InserterController.process_temporary_overrides()
equal(retry_writes, 0, "temporary override remains for its write tick")
game.tick = 101
local retry_failures = InserterController.process_temporary_overrides()
equal(retry_writes, 1, "temporary override first restoration runs next tick")
equal(#retry_failures, 1, "temporary override restoration failure reported")
local deferred_tick = 101 + Constants.DEFERRED_RETRY_INTERVAL_TICKS
equal(setup_root.temporary_override_retry_tick, deferred_tick,
  "temporary override restoration failure schedules backoff")
game.tick = deferred_tick - 1
InserterController.process_temporary_overrides()
equal(retry_writes, 1, "temporary override restoration skips backoff window")
assert(not InserterController.restore(retry_instance),
  "direct cleanup also respects temporary override backoff")
equal(retry_writes, 1, "direct cleanup performs no native write during backoff")
retry_blocked = false
game.tick = deferred_tick
InserterController.process_temporary_overrides()
equal(retry_writes, 2, "temporary override restoration retries at backoff deadline")
equal(retry_override, retry_record.original_override, "temporary override restored after retry")
assert(next(setup_root.temporary_overrides) == nil
    and setup_root.temporary_override_retry_tick == nil,
  "successful temporary override restoration clears retry schedule")
setup_root.instances[retry_instance.unit_number] = nil
game = previous_game

local surface, force = {index = 1}, {index = 1}
local owner = {valid = true, unit_number = 1, surface = surface, force = force}
local chest = {valid = true, unit_number = 10, surface = surface, force = force}
local function make_inserter(unit_number, fail_once)
  local filters = {[1] = {name = "iron-plate", quality = "normal", comparator = "="}}
  local behavior = {
    valid = true,
    circuit_enable_disable = false,
    circuit_condition = {first_signal = {type = "item", name = "iron-plate"}, comparator = "<", constant = 5},
    connect_to_logistic_network = true,
    circuit_set_stack_size = true,
    circuit_set_filters = true,
    input_networks = {red = true, green = true},
  }
  local inserter = {
    valid = true,
    unit_number = unit_number,
    localised_name = "test inserter " .. tostring(unit_number),
    surface = surface,
    force = force,
    pickup_target = chest,
    filter_slot_count = 1,
    use_filters = true,
    inserter_filter_mode = "whitelist",
    inserter_stack_size_override = 3,
    inserter_target_pickup_count = 4,
  }
  local behavior_reads = 0
  function inserter.get_control_behavior()
    behavior_reads = behavior_reads + 1
    if behavior_reads == fail_once.canonicalize_condition_on_read then
      local condition = behavior.circuit_condition
      behavior.circuit_condition = {
        first_signal = condition.first_signal,
        second_signal = condition.second_signal,
        comparator = condition.comparator or "<",
        constant = 0,
      }
    end
    return behavior
  end
  function inserter.get_filter(index) return filters[index] end
  function inserter.set_filter(index, filter)
    if fail_once.value then
      fail_once.value = false
      error("simulated filter write failure")
    end
    if fail_once.ignore_restored_filter and filter ~= nil then return end
    filters[index] = filter
  end
  return inserter, behavior, filters
end

discovered_targets = {{entity = chest, unit_number = chest.unit_number}}
local no_failure = {value = false}
local inserter, behavior, filters = make_inserter(20, no_failure)
local second_inserter, second_behavior, second_filters = make_inserter(21, {value = false})
local setup_instance = {
  entity = owner,
  unit_number = owner.unit_number,
  tail_mode = Constants.TAIL_MODE.NO_TAIL,
}
discovered_inserters = {inserter, second_inserter}
local no_tail_preview_ok, _, _, no_tail_preview = InserterController.preview_setup(setup_instance)
assert(no_tail_preview_ok and no_tail_preview.inserter_count == 2,
  "no-tail setup accepts multiple inserters for one requester chest")
setup_instance.tail_mode = Constants.TAIL_MODE.PARALLEL
local parallel_preview_ok, _, _, parallel_preview = InserterController.preview_setup(setup_instance)
assert(parallel_preview_ok and parallel_preview.inserter_count == 2,
  "parallel setup accepts multiple inserters for one requester chest")
setup_instance.tail_mode = Constants.TAIL_MODE.NO_TAIL
local changed_mode_ok, changed_mode_error =
  InserterController.configure_setup(setup_instance, parallel_preview.scope_signature)
assert(not changed_mode_ok and changed_mode_error == Constants.ERROR.INSERTER_SETUP_SCOPE_CHANGED
    and not behavior.circuit_enable_disable and not second_behavior.circuit_enable_disable,
  "inserter setup rejects a tail-mode change after preview")
setup_instance.tail_mode = Constants.TAIL_MODE.SINGLE
local single_preview_ok, single_preview_error, single_preview_detail =
  InserterController.preview_setup(setup_instance)
assert(not single_preview_ok and single_preview_error == Constants.ERROR.INSERTER_CONFIGURATION
    and single_preview_detail[2][1]
      == "batch-request-combinator.inserter-diagnostic-single-count"
    and single_preview_detail[2][2] == 2,
  "single setup requires exactly one inserter per requester chest")
local single_configured, single_configure_error =
  InserterController.configure_setup(setup_instance, parallel_preview.scope_signature)
assert(not single_configured and single_configure_error == Constants.ERROR.INSERTER_CONFIGURATION
    and not behavior.circuit_enable_disable and not second_behavior.circuit_enable_disable
    and filters[1] ~= nil and second_filters[1] ~= nil,
  "single setup rechecks topology before changing inserters")
discovered_inserters = {inserter}
setup_root.chest_owners[chest.unit_number] = 90
local chest_owned, chest_error = InserterController.preview_setup({entity = owner, unit_number = owner.unit_number})
assert(not chest_owned and chest_error == Constants.ERROR.TARGET_CONFLICT,
  "inserter setup rejects an owned requester chest")
setup_root.chest_owners[chest.unit_number] = nil
local preview_ok, _, _, preview = InserterController.preview_setup({entity = owner})
assert(preview_ok and preview.inserter_count == 1, "inserter setup preview")
setup_root.inserter_owners[inserter.unit_number] = 90
local inserter_owned, ownership_error =
  InserterController.configure_setup({entity = owner}, preview.scope_signature)
assert(not inserter_owned and ownership_error == Constants.ERROR.INSERTER_OWNERSHIP
    and not behavior.circuit_enable_disable,
  "inserter setup rechecks ownership before writes")
setup_root.inserter_owners[inserter.unit_number] = nil
local configured, setup_error, _, configured_count =
  InserterController.configure_setup({entity = owner}, preview.scope_signature)
assert(configured, "inserter setup failed: " .. tostring(setup_error))
equal(configured_count, 1, "configured inserter count")
assert(behavior.circuit_enable_disable and not behavior.connect_to_logistic_network
    and not behavior.circuit_set_stack_size and not behavior.circuit_set_filters,
  "inserter control settings")
equal(behavior.circuit_condition.first_signal.name, Constants.STATUS_SIGNAL.ready,
  "inserter ready condition")
assert(not inserter.use_filters and filters[1] == nil, "inserter filters cleared")
equal(inserter.inserter_stack_size_override, 3, "stack override preserved")
assert(behavior.input_networks.red and not behavior.input_networks.green,
  "inserter setup selects only the connected output color")

for _, connected in ipairs{{true, false}, {false, true}, {true, true}} do
  for _, initially_enabled in ipairs{true, false} do
    local candidate, candidate_behavior = make_inserter(22, {value = false})
    candidate_behavior.input_networks = {red = initially_enabled, green = initially_enabled}
    discovered_inserters = {candidate}
    setup_red, setup_green = connected[1], connected[2]
    local valid, _, _, candidate_preview = InserterController.preview_setup({entity = owner})
    assert(valid, "connected-color setup preview")
    assert(InserterController.configure_setup({entity = owner}, candidate_preview.scope_signature),
      "connected-color setup applies")
    equal(candidate_behavior.input_networks.red, setup_red, "exact red input selection")
    equal(candidate_behavior.input_networks.green, setup_green, "exact green input selection")
    equal(candidate.inserter_stack_size_override, 3, "selection repair preserves stack override")
  end
end
setup_red, setup_green = true, false

local prior_inserter, prior_behavior, prior_filters = make_inserter(25, {value = false})
local rollback_failure = {value = true}
local rollback_inserter, rollback_behavior, rollback_filters = make_inserter(30, rollback_failure)
discovered_inserters = {prior_inserter, rollback_inserter}
local rollback_preview_ok, _, _, rollback_preview = InserterController.preview_setup({entity = owner})
assert(rollback_preview_ok, "rollback preview")
local rollback_ok, rollback_error =
  InserterController.configure_setup({entity = owner}, rollback_preview.scope_signature)
assert(not rollback_ok and rollback_error == Constants.ERROR.INSERTER_SETUP_FAILED,
  "failed setup reports dedicated error")
for _, restored in ipairs{
  {prior_inserter, prior_behavior, prior_filters},
  {rollback_inserter, rollback_behavior, rollback_filters},
} do
  local restored_inserter, restored_behavior, restored_filters = restored[1], restored[2], restored[3]
  assert(not restored_behavior.circuit_enable_disable and restored_behavior.connect_to_logistic_network
      and restored_behavior.circuit_set_stack_size and restored_behavior.circuit_set_filters,
    "failed setup restores every inserter control setting")
  assert(restored_behavior.input_networks.red and restored_behavior.input_networks.green,
    "failed setup restores circuit input selection")
  assert(restored_inserter.use_filters and restored_filters[1] ~= nil,
    "failed setup restores every inserter filter")
  equal(restored_inserter.inserter_stack_size_override, 3, "rollback preserves stack override")
end

local canonical_failure = {value = true, canonicalize_condition_on_read = 3}
local canonical_inserter, canonical_behavior = make_inserter(32, canonical_failure)
canonical_behavior.circuit_condition = {
  first_signal = {type = "item", name = "iron-plate"},
  second_signal = {type = "item", name = "copper-plate"},
  constant = 7,
}
discovered_inserters = {canonical_inserter}
local canonical_preview_ok, _, _, canonical_preview = InserterController.preview_setup({entity = owner})
assert(canonical_preview_ok, "canonical condition rollback preview")
local canonical_ok, canonical_error, canonical_detail =
  InserterController.configure_setup({entity = owner}, canonical_preview.scope_signature)
assert(not canonical_ok and canonical_error == Constants.ERROR.INSERTER_SETUP_FAILED
    and canonical_detail == canonical_inserter.localised_name,
  "semantically equivalent circuit condition passes rollback verification")

local unrestorable_failure = {value = false, ignore_restored_filter = true}
local unrestorable, _, unrestorable_filters = make_inserter(35, unrestorable_failure)
local verification_failure = make_inserter(40, {value = false})
verification_failure.inserter_target_pickup_count = 0
discovered_inserters = {unrestorable, verification_failure}
local unverified_preview_ok, _, _, unverified_preview = InserterController.preview_setup({entity = owner})
assert(unverified_preview_ok, "unverified rollback preview")
local unverified_ok, unverified_error, unverified_detail =
  InserterController.configure_setup({entity = owner}, unverified_preview.scope_signature)
assert(not unverified_ok and unverified_error == Constants.ERROR.INSERTER_SETUP_FAILED,
  "unverified rollback never reports success")
assert(unverified_detail[2][1] == "batch-request-combinator.inserter-diagnostic-setup-rollback"
    and unverified_detail[2][2] == unrestorable.unit_number,
  "rollback failure identifies the exact inserter")
assert(unrestorable_filters[1] == nil, "test fixture proves rollback readback detected the ignored write")

discovered_inserters = {inserter, rollback_inserter}
local scope_ok, scope_error =
  InserterController.configure_setup({entity = owner}, preview.scope_signature)
assert(not scope_ok and scope_error == Constants.ERROR.INSERTER_SETUP_SCOPE_CHANGED,
  "changed setup scope rejected")

-- Lifecycle catches output projection errors at registration.
local runtime_failure
local registered_instance = {unit_number = 99}
package.loaded["runtime.batch_coordinator"] = {}
package.loaded["runtime.drain"] = {}
package.loaded["runtime.gui"] = {}
package.loaded["runtime.inserter_controller"] = {}
package.loaded["runtime.output_status"] = {
  update = function() error("simulated output failure") end,
  fail_safe_off = function() end,
}
package.loaded["runtime.reconciliation"] = {}
package.loaded["runtime.registry"] = {add = function() return registered_instance end}
package.loaded["runtime.requests"] = {}
package.loaded["runtime.state_machine"] = {
  on_runtime_error = function(_, failure) runtime_failure = tostring(failure) end,
}
package.loaded["runtime.lifecycle"] = nil
local Lifecycle = require("runtime.lifecycle")
equal(Lifecycle.register({valid = true, name = Constants.ENTITY_NAME}, {}), registered_instance,
  "lifecycle registration survives output failure")
assert(runtime_failure and runtime_failure:find("simulated output failure", 1, true),
  "lifecycle routes output failure through runtime error handling")

print("Batch Request Combinator minimum tests passed")
