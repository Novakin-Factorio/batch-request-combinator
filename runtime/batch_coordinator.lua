local Constants = require("runtime.constants")
local InserterController = require("runtime.inserter_controller")
local Registry = require("runtime.registry")
local Requests = require("runtime.requests")
local TailPlanner = require("runtime.tail_planner")
local TargetDiscovery = require("runtime.target_discovery")

local BatchCoordinator = {}

local function target_unit(target)
  return target and target.entity and target.entity.valid and target.entity.unit_number
    or (target and target.unit_number)
end

local function has_unresolved_target(instance, target_unit_number)
  return InserterController.has_unresolved_target(instance, target_unit_number)
end

local function release_target_claims(instance, target_unit_number)
  return InserterController.release_target_claims(instance, target_unit_number)
end

local function rollback_started_batch(instance)
  local root = Registry.root()
  for _, target in ipairs(instance.targets or {}) do
    if target.section == nil then
      local unit_number = Requests.cleanup_target_unit_number(target)
      if unit_number then
        release_target_claims(instance, unit_number)
        Requests.release_target(instance, target, false)
      else
        Requests.release_target(instance, target, true)
      end
    else
      local unit_number = Requests.cleanup_target_unit_number(target)
      if unit_number and root.chest_owners[unit_number] == nil then
        root.chest_owners[unit_number] = instance.unit_number
      end
    end
  end
end

function BatchCoordinator.begin(instance, targets, inserters, endpoints_by_unit)
  instance.cleanup_complete = false
  instance.captured_tail_mode = instance.captured_tail_mode
    or instance.tail_mode or Constants.TAIL_MODE.NO_TAIL
  if not targets then
    targets, inserters, endpoints_by_unit = TargetDiscovery.discover(instance.entity)
  end
  if #targets == 0 then return false, Constants.ERROR.NO_TARGETS end
  for _, target in ipairs(targets) do
    local entity = target.entity
    if entity and entity.valid then
      target.unit_number = target.unit_number or entity.unit_number
      target.diagnostic_name = target.diagnostic_name or entity.localised_name
      local position = entity.position
      if position then
        target.diagnostic_x = target.diagnostic_x or position.x
        target.diagnostic_y = target.diagnostic_y or position.y
      end
    end
  end
  local monitored, inserter_error, inserter_detail = InserterController.prepare(
    instance,
    targets,
    inserters,
    instance.captured_tail_mode,
    endpoints_by_unit
  )
  if not monitored then return false, inserter_error, inserter_detail end

  instance.targets = targets
  local contents_error, contents_detail, planning_observations =
    Requests.planning_contents_error(instance, targets)
  if contents_error then return false, contents_error, contents_detail end
  local descriptors, descriptor_error = Requests.planning_targets(
    instance,
    targets,
    planning_observations
  )
  if not descriptors then return false, descriptor_error or Constants.ERROR.TAIL_PLAN_UNSAFE end
  local plan, plan_reason = TailPlanner.plan(
    instance.captured,
    descriptors,
    instance.captured_tail_mode
  )
  if not plan then
    local error_code = instance.captured_tail_mode == Constants.TAIL_MODE.SINGLE
      and Constants.ERROR.TAIL_PLAN_UNSAFE or Constants.ERROR.INSUFFICIENT_CAPACITY
    local detail = plan_reason == "planning-limit"
      and {"batch-request-combinator-error.planning-limit"} or nil
    return false, error_code, detail
  end
  instance.tail_target_index = plan.tail_target_index
  instance.planned_tail_count = plan.planned_tail_count or 0

  local root = Registry.root()
  for index, target in ipairs(targets) do
    target.allocation = plan.allocations[index]
    local unit_number = target_unit(target)
    local owner = unit_number and root.chest_owners[unit_number] or nil
    if owner and owner ~= instance.unit_number then
      return false, Constants.ERROR.TARGET_CONFLICT, target.entity.localised_name
    end
    local error_code = Requests.preflight(instance, target, planning_observations[index])
    if error_code then return false, error_code, target.entity.localised_name end
  end
  local applied, apply_error, apply_detail = InserterController.apply_plan(instance, descriptors)
  if not applied then
    return false, apply_error or Constants.ERROR.INSERTER_CONFIGURATION, apply_detail
  end
  local claimed, claim_detail = InserterController.claim(instance)
  if not claimed then
    return false, Constants.ERROR.INSERTER_OWNERSHIP, claim_detail
  end

  for _, target in ipairs(targets) do
    local unit_number = target_unit(target)
    root.chest_owners[unit_number] = instance.unit_number
    target.destroy_registration = script.register_on_object_destroyed(target.entity)
    root.destroyed[target.destroy_registration] = {
      kind = "target",
      owner = instance.unit_number,
      target = unit_number,
    }
  end
  local started, error_code, error_detail = Requests.begin_sections(instance)
  if not started then
    rollback_started_batch(instance)
    return false, error_code, error_detail
  end
  return true
end

function BatchCoordinator.cleanup(instance, clear_targets)
  if instance.cleanup_complete then
    if clear_targets then
      InserterController.clear_records(instance)
      instance.targets = {}
      instance.inserters = {}
      instance.ready_counts = nil
    end
    return true
  end
  local restored, restore_error, restore_detail = InserterController.restore(instance)
  local sections_removed = Requests.cleanup_sections(instance)
  local root = Registry.root()
  local drain_targets_by_unit = {}
  for _, drain_target in ipairs(instance.drain_targets or {}) do
    local unit_number = target_unit(drain_target)
    if unit_number then drain_targets_by_unit[unit_number] = drain_target end
  end
  for _, target in ipairs(instance.targets or {}) do
    if target.section == nil then
      local unit_number = Requests.cleanup_target_unit_number(target)
      local drain_target = unit_number and drain_targets_by_unit[unit_number] or nil
      if drain_target then
        release_target_claims(instance, unit_number)
        if target ~= drain_target then Requests.release_target(instance, target, true) end
        if root.chest_owners[unit_number] == nil then
          root.chest_owners[unit_number] = instance.unit_number
        end
      elseif unit_number and not has_unresolved_target(instance, unit_number) then
        release_target_claims(instance, unit_number)
        Requests.release_target(instance, target, false)
      else
        Requests.release_target(instance, target, true)
        if unit_number and root.chest_owners[unit_number] == nil then
          root.chest_owners[unit_number] = instance.unit_number
        end
      end
    end
  end
  local success = restored and sections_removed
  if success then instance.cleanup_complete = true end
  if clear_targets and success then
    InserterController.clear_records(instance)
    instance.targets = {}
    instance.inserters = {}
    instance.ready_counts = nil
  end
  if not restored then return false, restore_error, restore_detail end
  if not sections_removed then return false, Constants.ERROR.REQUEST_WRITE_FAILED end
  return true
end

function BatchCoordinator.detach_failed_cleanup(instance)
  Requests.detach_failed_cleanup(instance, function(unit_number)
    return has_unresolved_target(instance, unit_number)
  end)
  InserterController.detach_failed_cleanup(instance)
  instance.targets = {}
  instance.inserters = {}
  instance.ready_counts = nil
end

function BatchCoordinator.retry_one_tombstone(tick)
  return Requests.retry_one_tombstone(function(owner, target_unit_number)
    InserterController.release_resolved_tombstones_for_target(owner, target_unit_number)
  end, tick)
end

function BatchCoordinator.validate_requesting(instance)
  return Requests.validate(instance, true, false, true)
end

function BatchCoordinator.progress(instance, observations)
  return Requests.progress(instance, observations)
end

function BatchCoordinator.remove_sections(instance)
  return Requests.remove_sections(instance)
end

function BatchCoordinator.settled(instance)
  return Requests.settled(instance)
end

function BatchCoordinator.validate_settled_controller(instance)
  return InserterController.validate(instance, nil, true)
end

function BatchCoordinator.capture_ready_counts(instance)
  Requests.capture_ready_counts(instance)
end

function BatchCoordinator.validate_ready(instance)
  local mode = instance.captured_tail_mode or instance.tail_mode or Constants.TAIL_MODE.NO_TAIL
  local collect_tail_observations = mode ~= Constants.TAIL_MODE.NO_TAIL
  return Requests.validate_ready(instance, collect_tail_observations)
end

function BatchCoordinator.validate_controller(instance)
  return InserterController.validate(instance)
end

function BatchCoordinator.process_tail(instance, request_observation)
  return InserterController.process_scheduled(instance, request_observation)
end

function BatchCoordinator.source_drained(instance, request_observation)
  return Requests.source_drained(instance, request_observation)
end

function BatchCoordinator.has_temporary(instance)
  return InserterController.has_temporary(instance)
end

function BatchCoordinator.validate_complete(instance)
  local valid, error_code, detail, request_observation = Requests.validate_ready(instance, false)
  if not valid then return false, error_code, detail end
  local controller_valid, controller_error, controller_detail, hands_empty, _, has_temporary =
    InserterController.validate(instance)
  if not controller_valid then return false, controller_error, controller_detail end
  if not request_observation.source_drained or not hands_empty or has_temporary then
    return false, Constants.ERROR.DELIVERY_MISMATCH
  end
  return true
end

function BatchCoordinator.retry_tail(instance)
  if not Requests.sections_absent(instance) then return false end
  local valid = Requests.validate_ready(instance, false)
  if not valid then return false end
  return InserterController.retry_tail(instance)
end

return BatchCoordinator
