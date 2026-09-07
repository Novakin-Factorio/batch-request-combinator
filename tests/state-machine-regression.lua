package.path = "./?.lua;" .. package.path

local Constants = require("runtime.constants")
local Util = require("runtime.util")
local root = {poll_interval = 12}
local input, source_empty, cleanup_fails, output_fails, automatic_drains
local ready, complete, requests_active
game = {tick = 0}
log = function() end

local function snapshot()
  local items = input == 0 and {} or {{name = "iron-plate", quality = "normal", count = input}}
  return {items = items, total = input, signature = Util.items_signature(items), has_input = input ~= 0}
end
package.loaded["runtime.circuit_input"] = {read = snapshot, read_active = snapshot}
package.loaded["runtime.registry"] = {
  root = function() return root end,
}
package.loaded["runtime.output_status"] = {
  ensure = function() return true end,
  fail_safe_off = function() ready, complete = false, false; return true end,
  update = function(instance)
    ready = instance.state == Constants.STATE.READY
    complete = instance.state == Constants.STATE.COMPLETE
    assert(not (ready and complete), "handshake outputs never overlap")
    assert(not ready or not requests_active, "requests are removed before READY")
    if output_fails and ready then output_fails = false; return false end
    return true
  end,
}
local function valid() return true end
local targets = {{unit_number = 10}}
package.loaded["runtime.batch_coordinator"] = {
  begin = function(instance) instance.targets = targets; requests_active = true; return true end,
  cleanup = function(instance, clear_targets)
    assert(not ready and not complete, "cleanup starts with loading outputs lowered")
    if cleanup_fails then return false, Constants.ERROR.REQUEST_WRITE_FAILED end
    requests_active = false
    instance.cleanup_complete = true
    if clear_targets then instance.targets = {} end
    return true
  end,
  validate_requesting = valid,
  progress = valid,
  remove_sections = function() requests_active = false; return true end,
  settled = function() return true, nil, false end,
  validate_settled_controller = function() return true, nil, nil, true end,
  capture_ready_counts = function(instance) instance.ready_counts = {} end,
  validate_ready = valid,
  source_drained = function() return source_empty end,
  validate_controller = function() return true, nil, nil, true end,
  validate_complete = valid,
  has_temporary = function() return false end,
}
package.loaded["runtime.drain"] = {
  has_lease = function() return false end,
  stop = valid,
  start_after_interruption = function(instance, batch_targets)
    assert(batch_targets == targets, "automatic cleanup preserves the interrupted scope")
    assert(not requests_active and not ready and not complete, "requests and loading stop before drain")
    automatic_drains = automatic_drains + 1
    instance.drain_targets = batch_targets
    return true, true
  end,
}
package.loaded["runtime.inserter_controller"] = {}
local StateMachine = require("runtime.state_machine")

local function new_instance(input_mode, automatic_cleanup)
  input, source_empty, cleanup_fails, output_fails, automatic_drains = 10, false, false, false, 0
  ready, complete, requests_active = false, false, false
  game.tick = 0
  return {
    unit_number = 1, entity = {valid = true, force = {print = function() end}},
    state = Constants.STATE.ARMED, sign_mode = Constants.SIGN_MODE.ANY,
    input_mode = input_mode, tail_mode = Constants.TAIL_MODE.NO_TAIL,
    auto_cleanup_after_interrupt = automatic_cleanup,
  }
end

local function poll(instance, expected)
  game.tick = game.tick + root.poll_interval
  StateMachine.process(instance)
  assert(instance.state == expected, "expected " .. expected .. ", got " .. instance.state)
end

local instance = new_instance(Constants.INPUT_MODE.FOLLOW, false)
poll(instance, Constants.STATE.REQUESTING)
poll(instance, Constants.STATE.SETTLING)
poll(instance, Constants.STATE.READY)
assert(ready and not complete)
source_empty = true
poll(instance, Constants.STATE.COMPLETE)
assert(complete and not ready)
input = 0
poll(instance, Constants.STATE.ARMED)
assert(#instance.captured == 0 and not ready and not complete)

instance = new_instance(Constants.INPUT_MODE.SNAPSHOT, true)
poll(instance, Constants.STATE.REQUESTING)
input = 0
poll(instance, Constants.STATE.SETTLING)
poll(instance, Constants.STATE.READY)
assert(automatic_drains == 0, "Snapshot zero never starts automatic cleanup")
source_empty = true
poll(instance, Constants.STATE.COMPLETE)
local completed_tick = game.tick
game.tick = completed_tick + root.poll_interval - 1
StateMachine.process(instance)
assert(instance.state == Constants.STATE.COMPLETE, "Snapshot holds COMPLETE for a full interval")
input = 10
game.tick = completed_tick + root.poll_interval
StateMachine.process(instance)
assert(instance.state == Constants.STATE.COMPLETE and not instance.snapshot_zero_observed,
  "reasserted input invalidates the prior zero observation")
input = 0
poll(instance, Constants.STATE.ARMED)

for _, state in ipairs{Constants.STATE.REQUESTING, Constants.STATE.SETTLING, Constants.STATE.READY} do
  for _, automatic_cleanup in ipairs{false, true} do
    instance = new_instance(Constants.INPUT_MODE.FOLLOW, automatic_cleanup)
    poll(instance, Constants.STATE.REQUESTING)
    if state ~= Constants.STATE.REQUESTING then poll(instance, Constants.STATE.SETTLING) end
    if state == Constants.STATE.READY then poll(instance, Constants.STATE.READY) end
    input = 0
    poll(instance, automatic_cleanup and Constants.STATE.DRAINING or Constants.STATE.ARMED)
    assert(automatic_drains == (automatic_cleanup and 1 or 0))
  end
end

instance = new_instance(Constants.INPUT_MODE.FOLLOW, true)
poll(instance, Constants.STATE.REQUESTING)
StateMachine.manual_abort(instance)
assert(instance.state == Constants.STATE.ABORTED and automatic_drains == 0,
  "manual abort with high input waits without automatic cleanup")
input = 0
poll(instance, Constants.STATE.ARMED)

instance = new_instance(Constants.INPUT_MODE.FOLLOW, false)
poll(instance, Constants.STATE.REQUESTING)
cleanup_fails = true
input = 0
poll(instance, Constants.STATE.ERROR)
assert(instance.targets == targets and #instance.captured == 1, "failed cleanup retains recovery context")
cleanup_fails = false
poll(instance, Constants.STATE.ARMED)

instance = new_instance(Constants.INPUT_MODE.FOLLOW, false)
poll(instance, Constants.STATE.REQUESTING)
poll(instance, Constants.STATE.SETTLING)
output_fails = true
poll(instance, Constants.STATE.ERROR)
assert(not ready and not complete and not requests_active, "partial output failure shuts loading down")

print("State-machine handshake and recovery regressions passed")
