local Constants = require("runtime.constants")
local BatchCoordinator = require("runtime.batch_coordinator")
local CircuitInput = require("runtime.circuit_input")
local Drain = require("runtime.drain")
local InserterController = require("runtime.inserter_controller")
local OutputStatus = require("runtime.output_status")
local Registry = require("runtime.registry")
local Util = require("runtime.util")

local StateMachine = {}
local begin_automatic_cleanup

local function is_active_state(state)
  return state == Constants.STATE.DRAINING
    or state == Constants.STATE.REQUESTING
    or state == Constants.STATE.SETTLING
    or state == Constants.STATE.READY
    or state == Constants.STATE.COMPLETE
end

local function notify_error(instance, error_code, error_detail)
  error_code = error_code or instance.error_code
  if error_detail == nil then error_detail = instance.error_detail end
  local signature = Util.error_signature(error_code, error_detail)
  if instance.notified_error_signature == signature then return end
  instance.notified_error_signature = signature
  if instance.entity and instance.entity.valid then
    instance.entity.force.print{
      "batch-request-combinator.message-error",
      instance.entity.localised_name,
      Util.localised_error(error_code, error_detail),
    }
  end
end

local function input_reset_cleanup_enabled(instance)
  return instance.auto_cleanup_after_interrupt == true
    and instance.requests_started == true
    and (instance.state == Constants.STATE.REQUESTING
      or instance.state == Constants.STATE.SETTLING
      or instance.state == Constants.STATE.READY)
end

local function transition(instance, new_state, error_code, error_detail)
  local old_state = instance.state
  if (old_state == Constants.STATE.READY or old_state == Constants.STATE.COMPLETE)
    and new_state ~= old_state then
    OutputStatus.fail_safe_off(instance)
  end
  instance.state = new_state
  instance.error_code = error_code
  instance.error_detail = error_detail
  Registry.set_active(instance, is_active_state(new_state))
  local updated = OutputStatus.update(instance, true)
  if updated then instance.reconciliation_output_suppressed = nil end
  return updated
end

local function output_failure(instance)
  OutputStatus.fail_safe_off(instance)
  local drain_restored, drain_error, drain_detail = Drain.stop(instance)
  BatchCoordinator.cleanup(instance, false)
  instance.state = Constants.STATE.ERROR
  instance.error_code = drain_restored
    and Constants.ERROR.OUTPUT_UNAVAILABLE or (drain_error or Constants.ERROR.DRAIN_RESTORE_FAILED)
  instance.error_detail = drain_restored and nil or drain_detail
  instance.last_error_code = instance.error_code
  instance.last_error_detail = instance.error_detail
  instance.reconciliation_output_suppressed = nil
  Registry.set_active(instance, false)
  notify_error(instance)
end

local function enter_error(
  instance,
  error_code,
  error_detail,
  drain_restore_attempted,
  cleanup_attempted
)
  if not drain_restore_attempted and Drain.has_lease(instance) then
    OutputStatus.fail_safe_off(instance)
    local restored, restore_error, restore_detail = Drain.stop(instance)
    if not restored then
      error_code = restore_error or Constants.ERROR.DRAIN_RESTORE_FAILED
      error_detail = restore_detail
    end
  end
  local already_same = instance.state == Constants.STATE.ERROR
    and Util.error_signature(instance.error_code, instance.error_detail)
      == Util.error_signature(error_code, error_detail)
  instance.last_error_code = error_code
  instance.last_error_detail = error_detail
  if already_same then
    if not cleanup_attempted then BatchCoordinator.cleanup(instance, false) end
    return
  end
  if not transition(instance, Constants.STATE.ERROR, error_code, error_detail) then
    output_failure(instance)
    return
  end
  if not cleanup_attempted then BatchCoordinator.cleanup(instance, false) end
  notify_error(instance)
end

local function clear_batch(instance)
  instance.plan_revision = (instance.plan_revision or 0) + 1
  instance.captured = {}
  instance.captured_total = 0
  instance.captured_signature = ""
  instance.captured_key_set = nil
  instance.targets = {}
  instance.monitored_inserters = {}
  instance.monitored_inserters_by_unit = nil
  instance.inserters = {}
  instance.drain_input_observed = false
  instance.staged_total = 0
  instance.ready_counts = nil
  instance.warning_input_changed = false
  instance.snapshot_zero_observed = false
  instance.snapshot_reset_invalidated = false
  instance.snapshot_new_input_warning = false
  instance.snapshot_reset_recorded = false
  instance.captured_input_mode = nil
  instance.captured_tail_mode = nil
  instance.tail_target_index = nil
  instance.planned_tail_count = 0
  instance.tail_waiting_reason = nil
  instance.manual_tail_recovery = false
  instance.complete_since_tick = nil
  instance.complete_hold_until_tick = nil
  instance.reconciliation_output_suppressed = nil
  instance.requests_started = false
end

begin_automatic_cleanup = function(instance, input_observed)
  OutputStatus.fail_safe_off(instance)
  local batch_targets = instance.targets or {}
  local cleaned, cleanup_error, cleanup_detail = BatchCoordinator.cleanup(instance, false)
  if not cleaned then
    return false, cleanup_error or Constants.ERROR.REQUEST_WRITE_FAILED, cleanup_detail, true
  end
  local started, active, start_error, start_detail = Drain.start_after_interruption(
    instance,
    batch_targets
  )
  if not started then return false, start_error, start_detail, true end

  local monitored_inserters = instance.monitored_inserters or {}
  clear_batch(instance)
  if active then
    instance.monitored_inserters = monitored_inserters
    instance.monitored_inserters_by_unit = nil
  end
  instance.drain_input_observed = input_observed == true

  local next_state = active and Constants.STATE.DRAINING
    or (instance.drain_input_observed and Constants.STATE.ABORTED or Constants.STATE.ARMED)
  if not transition(instance, next_state, nil, nil) then output_failure(instance) end
  if next_state == Constants.STATE.ARMED then
    instance.notified_error_signature = nil
    instance.last_runtime_error = nil
  end
  return true
end

local function reset_to_armed(instance)
  if not transition(instance, Constants.STATE.RESET, nil, nil) then
    output_failure(instance)
    return false
  end
  local cleaned, cleanup_error, cleanup_detail = BatchCoordinator.cleanup(instance, true)
  if not cleaned then
    enter_error(
      instance,
      cleanup_error or Constants.ERROR.REQUEST_WRITE_FAILED,
      cleanup_detail,
      nil,
      true
    )
    return false
  end
  clear_batch(instance)
  if not transition(instance, Constants.STATE.ARMED, nil, nil) then
    output_failure(instance)
    return false
  end
  instance.notified_error_signature = nil
  instance.last_runtime_error = nil
  return true
end

local function abort_for_zero(instance)
  instance.last_abort = game.tick
  if input_reset_cleanup_enabled(instance) then
    local started, error_code, error_detail, cleanup_attempted = begin_automatic_cleanup(instance, false)
    if not started then enter_error(instance, error_code, error_detail, nil, cleanup_attempted) end
    return started
  end
  return reset_to_armed(instance)
end

local function input_changed(instance, snapshot)
  if snapshot.invalid_quantity then return true end
  if snapshot.matches_expected ~= nil then return not snapshot.matches_expected end
  return snapshot.signature ~= instance.captured_signature
end

local function update_input_warning(instance, snapshot)
  if snapshot.has_input
    and input_changed(instance, snapshot)
    and not instance.warning_input_changed then
    instance.warning_input_changed = true
    instance.last_warning_input_changed = true
    if not instance.reconciliation_output_suppressed
      and not OutputStatus.update(instance, true) then output_failure(instance) end
  end
end

local function observe_active_input(instance, snapshot)
  if instance.captured_input_mode == Constants.INPUT_MODE.SNAPSHOT then
    if snapshot.has_input then
      if instance.snapshot_zero_observed then
        instance.snapshot_zero_observed = false
        instance.snapshot_reset_invalidated = true
        instance.snapshot_new_input_warning = true
      end
      update_input_warning(instance, snapshot)
    else
      instance.snapshot_zero_observed = true
      instance.snapshot_reset_invalidated = false
      instance.snapshot_reset_recorded = true
    end
    return true
  end
  if not snapshot.has_input then return false end
  update_input_warning(instance, snapshot)
  return true
end

local function begin_batch(instance, snapshot)
  if snapshot.invalid_quantity then
    enter_error(instance, Constants.ERROR.INVALID_QUANTITY)
    return
  end
  instance.captured = Util.copy_items(snapshot.items)
  instance.captured_total = snapshot.total
  instance.captured_signature = snapshot.signature
  instance.captured_key_set = nil
  instance.staged_total = 0
  instance.warning_input_changed = false
  instance.captured_input_mode = instance.input_mode or Constants.INPUT_MODE.FOLLOW
  instance.captured_tail_mode = instance.tail_mode or Constants.TAIL_MODE.NO_TAIL
  instance.snapshot_zero_observed = false
  instance.snapshot_reset_invalidated = false
  instance.snapshot_new_input_warning = false
  instance.snapshot_reset_recorded = false
  instance.requests_started = false

  local started, error_code, error_detail = BatchCoordinator.begin(instance)
  if not started then
    enter_error(instance, error_code, error_detail)
    return
  end
  instance.requests_started = true
  instance.plan_revision = (instance.plan_revision or 0) + 1
  if not transition(instance, Constants.STATE.REQUESTING, nil, nil) then output_failure(instance) end
end

local function process_requesting(instance, snapshot)
  if not observe_active_input(instance, snapshot) then
    abort_for_zero(instance)
    return
  end
  if instance.state ~= Constants.STATE.REQUESTING then return end
  local valid, error_code, error_detail, request_observation =
    BatchCoordinator.validate_requesting(instance)
  if not valid then
    enter_error(instance, error_code, error_detail)
    return
  end
  local exact, content_error = BatchCoordinator.progress(instance, request_observation)
  if content_error then
    enter_error(instance, content_error)
    return
  end
  if exact then
    instance.staged_total = instance.captured_total
    if not BatchCoordinator.remove_sections(instance) then
      enter_error(instance, Constants.ERROR.SECTION_LOST)
      return
    end
    if not transition(instance, Constants.STATE.SETTLING, nil, nil) then output_failure(instance) end
  end
end

local function process_settling(instance, snapshot)
  if not observe_active_input(instance, snapshot) then
    abort_for_zero(instance)
    return
  end
  if instance.state ~= Constants.STATE.SETTLING then return end
  local settled, error_code, pending = BatchCoordinator.settled(instance)
  if error_code then
    enter_error(instance, error_code)
    return
  end
  if pending or not settled then return end
  local controller_valid, controller_error, controller_detail, empty, detail =
    BatchCoordinator.validate_settled_controller(instance)
  if not controller_valid then
    enter_error(instance, controller_error, controller_detail)
    return
  end
  if not empty then
    enter_error(instance, Constants.ERROR.INSERTER_NOT_EMPTY, detail)
    return
  end
  instance.tail_waiting_reason = nil
  BatchCoordinator.capture_ready_counts(instance)
  if not transition(instance, Constants.STATE.READY, nil, nil) then output_failure(instance) end
end

local function process_ready(instance, snapshot)
  if not observe_active_input(instance, snapshot) then
    abort_for_zero(instance)
    return
  end
  if instance.state ~= Constants.STATE.READY then return end
  local valid, error_code, error_detail, request_observation =
    BatchCoordinator.validate_ready(instance)
  if not valid then
    enter_error(instance, error_code, error_detail)
    return
  end
  if instance.reconciliation_output_suppressed
    and not BatchCoordinator.has_temporary(instance) then
    local controller_valid, controller_error, controller_detail = BatchCoordinator.validate_controller(instance)
    if not controller_valid then
      enter_error(instance, controller_error, controller_detail)
    elseif not OutputStatus.update(instance, true) then
      output_failure(instance)
    else
      instance.reconciliation_output_suppressed = nil
    end
    return
  end
  if instance.captured_tail_mode == Constants.TAIL_MODE.NO_TAIL then
    local drained = BatchCoordinator.source_drained(instance, request_observation)
    if not drained then
      instance.tail_waiting_reason = nil
      return
    end
    local controller_valid, controller_error, controller_detail, hands_empty =
      BatchCoordinator.validate_controller(instance)
    if not controller_valid then
      enter_error(instance, controller_error, controller_detail)
      return
    end
    instance.tail_waiting_reason = not hands_empty and "monitored" or nil
    if hands_empty then
      instance.complete_since_tick = game.tick
      instance.complete_hold_until_tick = game.tick + Registry.root().poll_interval
      if not transition(instance, Constants.STATE.COMPLETE, nil, nil) then output_failure(instance) end
    end
    return
  end
  local controlled, controller_error, controller_detail, hands_empty, _, has_temporary =
    BatchCoordinator.process_tail(instance, request_observation)
  if not controlled then
    enter_error(instance, controller_error, controller_detail)
    return
  end
  local drained = BatchCoordinator.source_drained(instance, request_observation)
  if drained and hands_empty and not has_temporary then
    instance.complete_since_tick = game.tick
    instance.complete_hold_until_tick = game.tick + Registry.root().poll_interval
    if not transition(instance, Constants.STATE.COMPLETE, nil, nil) then output_failure(instance) end
  end
end

local function process_complete(instance, snapshot)
  local valid, error_code, error_detail = BatchCoordinator.validate_complete(instance)
  if not valid then
    enter_error(instance, error_code, error_detail)
    return
  end
  if instance.captured_input_mode == Constants.INPUT_MODE.SNAPSHOT then
    observe_active_input(instance, snapshot)
    if instance.snapshot_zero_observed and not instance.snapshot_reset_invalidated
      and game.tick >= (instance.complete_hold_until_tick or game.tick) then
      reset_to_armed(instance)
    end
  elseif not snapshot.has_input then
    reset_to_armed(instance)
  else
    update_input_warning(instance, snapshot)
  end
end

local function process_draining(instance, snapshot)
  if snapshot.has_input then instance.drain_input_observed = true end
  local valid, completed_or_error, detail = Drain.process(instance)
  if not valid then
    enter_error(instance, completed_or_error, detail)
    return
  end
  if not completed_or_error then return end
  instance.last_drain = game.tick
  local next_state = instance.drain_input_observed
    and Constants.STATE.ABORTED or Constants.STATE.ARMED
  if not transition(instance, next_state, nil, nil) then
    output_failure(instance)
    return
  end
  if next_state == Constants.STATE.ARMED then
    instance.notified_error_signature = nil
    instance.last_runtime_error = nil
  end
end

function StateMachine.process(instance)
  if not instance.entity or not instance.entity.valid then return end
  local output_ready, output_error = OutputStatus.ensure(instance)
  if not output_ready then
    enter_error(instance, output_error or Constants.ERROR.OUTPUT_UNAVAILABLE)
    return
  end
  local state = instance.state
  local snapshot
  if state == Constants.STATE.ARMED then
    snapshot = CircuitInput.read(instance.entity, instance.sign_mode)
  elseif state ~= Constants.STATE.RESET then
    snapshot = CircuitInput.read_active(
      instance.entity,
      instance.sign_mode,
      state ~= Constants.STATE.DRAINING and is_active_state(state)
        and instance.captured or nil
    )
  end
  if state == Constants.STATE.ARMED then
    if snapshot.has_input then begin_batch(instance, snapshot) end
  elseif state == Constants.STATE.DRAINING then
    process_draining(instance, snapshot)
  elseif state == Constants.STATE.REQUESTING then
    process_requesting(instance, snapshot)
  elseif state == Constants.STATE.SETTLING then
    process_settling(instance, snapshot)
  elseif state == Constants.STATE.READY then
    process_ready(instance, snapshot)
  elseif state == Constants.STATE.COMPLETE then
    process_complete(instance, snapshot)
  elseif state == Constants.STATE.ERROR or state == Constants.STATE.ABORTED then
    local had_drain_lease = Drain.has_lease(instance)
    local drain_cleaned, drain_error, drain_detail = Drain.stop(instance)
    if not drain_cleaned then
      enter_error(instance, drain_error or Constants.ERROR.DRAIN_RESTORE_FAILED, drain_detail, true)
      return
    end
    local cleaned, cleanup_error, cleanup_detail = BatchCoordinator.cleanup(instance, false)
    if not cleaned then
      enter_error(
        instance,
        cleanup_error or Constants.ERROR.REQUEST_WRITE_FAILED,
        cleanup_detail,
        true,
        true
      )
      return
    end
    if had_drain_lease and instance.drain_input_observed then
      if not transition(instance, Constants.STATE.ABORTED, nil, nil) then output_failure(instance) end
    elseif not snapshot.has_input then
      reset_to_armed(instance)
    end
  elseif state == Constants.STATE.RESET then
    reset_to_armed(instance)
  end
  if instance.reconciliation_output_suppressed
    and not BatchCoordinator.has_temporary(instance) then
    if not is_active_state(instance.state) then
      instance.reconciliation_output_suppressed = nil
    elseif not OutputStatus.update(instance, true) then
      output_failure(instance)
    else
      instance.reconciliation_output_suppressed = nil
    end
  end
end

function StateMachine.retry_tail(instance)
  if not instance or instance.state ~= Constants.STATE.READY then return false end
  return BatchCoordinator.retry_tail(instance)
end

function StateMachine.preview_drain(instance)
  if not instance or instance.state ~= Constants.STATE.ARMED
    or not instance.entity or not instance.entity.valid then
    return false, Constants.ERROR.DRAIN_INPUT_ACTIVE
  end
  local snapshot = CircuitInput.read_active(instance.entity, instance.sign_mode, nil)
  if snapshot.has_input then return false, Constants.ERROR.DRAIN_INPUT_ACTIVE end
  return Drain.preview(instance)
end

local function inserter_setup_available(instance)
  if not instance or instance.state ~= Constants.STATE.ARMED
    or not instance.entity or not instance.entity.valid then
    return false, Constants.ERROR.INSERTER_SETUP_INPUT_ACTIVE
  end
  local snapshot = CircuitInput.read_active(instance.entity, instance.sign_mode, nil)
  if snapshot.has_input then return false, Constants.ERROR.INSERTER_SETUP_INPUT_ACTIVE end
  return true
end

function StateMachine.preview_inserter_setup(instance)
  local available, error_code = inserter_setup_available(instance)
  if not available then return false, error_code end
  return InserterController.preview_setup(instance)
end

function StateMachine.configure_inserters(instance, expected_scope_signature)
  local available, error_code = inserter_setup_available(instance)
  if not available then return false, error_code end
  return InserterController.configure_setup(instance, expected_scope_signature)
end

function StateMachine.start_drain(instance, expected_scope_signature)
  if not instance or instance.state ~= Constants.STATE.ARMED
    or not instance.entity or not instance.entity.valid then
    return false, Constants.ERROR.DRAIN_INPUT_ACTIVE
  end
  local snapshot = CircuitInput.read_active(instance.entity, instance.sign_mode, nil)
  if snapshot.has_input then return false, Constants.ERROR.DRAIN_INPUT_ACTIVE end
  instance.drain_input_observed = false
  local started, error_code, error_detail, restoration_failed = Drain.start(
    instance,
    expected_scope_signature
  )
  if not started then
    if restoration_failed then enter_error(instance, error_code, error_detail) end
    return false, error_code, error_detail
  end
  if not transition(instance, Constants.STATE.DRAINING, nil, nil) then
    output_failure(instance)
    return false, instance.error_code, instance.error_detail
  end
  return true
end

function StateMachine.stop_drain(instance)
  if not instance or instance.state ~= Constants.STATE.DRAINING then return false end
  local snapshot = CircuitInput.read_active(instance.entity, instance.sign_mode, nil)
  if snapshot.has_input then instance.drain_input_observed = true end
  OutputStatus.fail_safe_off(instance)
  local restored, error_code, error_detail = Drain.stop(instance)
  if not restored then
    enter_error(instance, error_code or Constants.ERROR.DRAIN_RESTORE_FAILED, error_detail)
    return false
  end
  instance.last_drain_stop = game.tick
  local next_state = instance.drain_input_observed
    and Constants.STATE.ABORTED or Constants.STATE.ARMED
  if not transition(instance, next_state, nil, nil) then
    output_failure(instance)
    return false
  end
  return true
end

function StateMachine.restore_drain_lease(instance)
  if not instance or not Drain.has_lease(instance) then return true end
  OutputStatus.fail_safe_off(instance)
  instance.drain_input_observed = true
  local restored, error_code, error_detail = Drain.stop(instance)
  if not restored then
    enter_error(
      instance,
      error_code or Constants.ERROR.DRAIN_RESTORE_FAILED,
      error_detail,
      true
    )
    return false
  end
  instance.last_drain_stop = game.tick
  if not transition(instance, Constants.STATE.ABORTED, nil, nil) then
    output_failure(instance)
    return false
  end
  return true
end

function StateMachine.manual_abort(instance)
  if not instance or not instance.entity or not instance.entity.valid then return end
  if instance.state == Constants.STATE.DRAINING then
    StateMachine.stop_drain(instance)
    return
  end
  if Drain.has_lease(instance) then
    if instance.drain_restore_blocked then
      Drain.detach_failed_cleanup(instance)
    else
      local restored, restore_error, restore_detail = Drain.stop(instance)
      if not restored then
        enter_error(instance, restore_error or Constants.ERROR.DRAIN_RESTORE_FAILED, restore_detail, true)
        return
      end
    end
  end
  local snapshot = CircuitInput.read_active(instance.entity, instance.sign_mode, nil)
  if not transition(instance, Constants.STATE.RESET, nil, nil) then
    output_failure(instance)
    return
  end
  local cleaned, cleanup_error, cleanup_detail = BatchCoordinator.cleanup(instance, true)
  if not cleaned then
    enter_error(
      instance,
      cleanup_error or Constants.ERROR.REQUEST_WRITE_FAILED,
      cleanup_detail,
      nil,
      true
    )
    return
  end
  clear_batch(instance)
  instance.last_abort = game.tick
  if snapshot.has_input then
    if not transition(instance, Constants.STATE.ABORTED, nil, nil) then output_failure(instance) end
  else
    if not transition(instance, Constants.STATE.ARMED, nil, nil) then
      output_failure(instance)
      return
    end
    instance.notified_error_signature = nil
    instance.last_runtime_error = nil
  end
end

function StateMachine.destroy(instance)
  if not instance then return end
  OutputStatus.fail_safe_off(instance)
  local drain_restored = Drain.stop(instance)
  if not BatchCoordinator.cleanup(instance, true) then
    BatchCoordinator.detach_failed_cleanup(instance)
  end
  if not drain_restored then Drain.detach_failed_cleanup(instance) end
  Registry.set_active(instance, false)
end

function StateMachine.on_runtime_error(instance, message)
  OutputStatus.fail_safe_off(instance)
  local drain_restored, drain_error, drain_detail = Drain.stop(instance)
  local text = tostring(message)
  local repeated = instance.last_runtime_error == text
  instance.last_runtime_error = text
  instance.state = Constants.STATE.ERROR
  instance.error_code = drain_restored
    and Constants.ERROR.INTERNAL or (drain_error or Constants.ERROR.DRAIN_RESTORE_FAILED)
  instance.error_detail = drain_restored and string.sub(text, 1, 240) or drain_detail
  instance.last_error_code = instance.error_code
  instance.last_error_detail = instance.error_detail
  Registry.set_active(instance, false)
  BatchCoordinator.cleanup(instance, false)
  if not OutputStatus.update(instance, true) then OutputStatus.fail_safe_off(instance) end
  if not repeated then
    log("[Batch Request Combinator] instance " .. tostring(instance.unit_number) .. " failed: " .. text)
    notify_error(instance)
  end
end

function StateMachine.on_managed_object_destroyed(instance, kind)
  if not instance or not instance.entity or not instance.entity.valid then return end
  if kind == "helper" then
    instance.helper = nil
    instance.helper_destroy_registration = nil
    instance.output_signature = nil
    if not OutputStatus.update(instance, true) then
      enter_error(instance, Constants.ERROR.OUTPUT_UNAVAILABLE)
    end
    return
  end
  if kind == "drain-target" then
    enter_error(instance, Constants.ERROR.TARGET_LOST)
    return
  end
  local code = kind == "section" and Constants.ERROR.SECTION_LOST or Constants.ERROR.TARGET_LOST
  enter_error(instance, code)
end

function StateMachine.on_external_request_changed(instance)
  if not instance or instance.mutating_sections or instance.mutating_drain then return end
  if is_active_state(instance.state) then
    enter_error(instance, Constants.ERROR.EXTERNAL_REQUEST)
  end
end

function StateMachine.fail(instance, error_code, error_detail)
  if instance then enter_error(instance, error_code, error_detail) end
end

function StateMachine.fail_reconciliation(instance, error_code, error_detail)
  if instance then enter_error(instance, error_code, error_detail) end
end

function StateMachine.fail_drain_reconciliation(instance, error_code, error_detail)
  if instance then
    instance.drain_input_observed = true
    instance.drain_restore_blocked = true
    enter_error(instance, error_code, error_detail, true)
  end
end

return StateMachine
