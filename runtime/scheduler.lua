local Constants = require("runtime.constants")
local BatchCoordinator = require("runtime.batch_coordinator")
local Debug = require("runtime.debug")
local Drain = require("runtime.drain")
local InserterController = require("runtime.inserter_controller")
local OutputStatus = require("runtime.output_status")
local Registry = require("runtime.registry")
local StateMachine = require("runtime.state_machine")

local Scheduler = {}

function Scheduler.on_tick(event, on_invalid, after_process)
  local root = Registry.root()
  local override_retry_tick = root.temporary_override_retry_tick
  if next(root.temporary_overrides) ~= nil
    and (type(override_retry_tick) ~= "number" or event.tick >= override_retry_tick) then
    local override_ok, override_failures = pcall(InserterController.process_temporary_overrides)
    if override_ok then
      for _, failure in ipairs(override_failures) do
        if root.instances[failure.instance.unit_number] == failure.instance then
          pcall(StateMachine.fail, failure.instance, failure.error_code, failure.detail)
        end
      end
    elseif root.debug.last_override_error ~= tostring(override_failures) then
      root.debug.last_override_error = tostring(override_failures)
      log("[Batch Request Combinator] temporary override recovery failed: " .. tostring(override_failures))
    end
  end
  if #root.cleanup_order > 0 then
    local cleanup_ok, cleanup_result = pcall(BatchCoordinator.retry_one_tombstone, event.tick)
    if not cleanup_ok and root.debug.last_cleanup_error ~= tostring(cleanup_result) then
      root.debug.last_cleanup_error = tostring(cleanup_result)
      log("[Batch Request Combinator] deferred cleanup failed: " .. tostring(cleanup_result))
    end
  end
  if #root.drain_order > 0 then
    local drain_ok, drain_result = pcall(Drain.retry_one_tombstone, event.tick)
    if not drain_ok and root.debug.last_drain_cleanup_error ~= tostring(drain_result) then
      root.debug.last_drain_cleanup_error = tostring(drain_result)
      log("[Batch Request Combinator] deferred drain restoration failed: " .. tostring(drain_result))
    end
  end
  local bucket = Registry.bucket_for_tick(event.tick)
  local debug_enabled = settings.global[Constants.SETTING_DEBUG]
    and settings.global[Constants.SETTING_DEBUG].value
  local profiler = debug_enabled and helpers.create_profiler() or nil
  local processed = 0
  local index = 1
  while index <= #bucket do
    local unit_number = bucket[index]
    local instance = root.instances[unit_number]
    if not instance or not instance.entity or not instance.entity.valid then
      if instance then
        on_invalid(instance)
      else
        Registry.remove_stale_bucket_entry(unit_number)
      end
    else
      local ok, failure = pcall(StateMachine.process, instance)
      if not ok then
        local handled, handler_failure = pcall(StateMachine.on_runtime_error, instance, failure)
        if not handled then
          pcall(OutputStatus.fail_safe_off, instance)
          instance.state = Constants.STATE.ERROR
          instance.error_code = Constants.ERROR.INTERNAL
          log("[Batch Request Combinator] error handler failed for instance "
            .. tostring(instance.unit_number) .. ": " .. tostring(handler_failure))
        end
      end
      processed = processed + 1
      if after_process and root.open_gui_instances[unit_number] then
        local after_ok, after_failure = pcall(after_process, instance)
        if not after_ok and instance.last_after_process_error ~= tostring(after_failure) then
          instance.last_after_process_error = tostring(after_failure)
          log("[Batch Request Combinator] post-process hook failed for instance "
            .. tostring(instance.unit_number) .. ": " .. tostring(after_failure))
        end
      end
      index = index + 1
    end
  end

  if debug_enabled then
    profiler.stop()
    root.debug.bucket_ticks = root.debug.bucket_ticks + 1
    root.debug.processed = root.debug.processed + processed
    root.debug.maximum = math.max(root.debug.maximum, processed)
    Debug.set_last_profiler(profiler)
  end
end

return Scheduler
