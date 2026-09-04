local Constants = require("runtime.constants")
local Registry = require("runtime.registry")

local Migrations = {}

function Migrations.run()
  local existing_root = storage.batch_request_combinator
  local stored_schema_version = Constants.SCHEMA_VERSION
  if existing_root then stored_schema_version = existing_root.schema_version or 0 end
  local root = Registry.ensure_storage()
  if root.schema_version > Constants.SCHEMA_VERSION then
    error("Batch Request Combinator storage was created by a newer mod version")
  end
  local migrate_legacy_modes = stored_schema_version < 2
  local migrate_auto_cleanup = stored_schema_version < 4
  for _, instance in pairs(root.instances) do
    instance.captured = instance.captured or {}
    instance.captured_total = instance.captured_total or 0
    instance.captured_signature = instance.captured_signature or ""
    instance.plan_revision = instance.plan_revision or 0
    instance.targets = instance.targets or {}
    instance.inserters = instance.inserters or {}
    instance.monitored_inserters = instance.monitored_inserters or {}
    instance.drain_targets = instance.drain_targets or {}
    instance.drain_initial_total = instance.drain_initial_total or 0
    instance.drain_remaining_total = instance.drain_remaining_total or 0
    instance.drain_pending_deliveries = instance.drain_pending_deliveries or 0
    instance.drain_last_remaining_total = instance.drain_last_remaining_total
      or instance.drain_remaining_total
    instance.drain_last_pending_total = instance.drain_last_pending_total
      or instance.drain_pending_deliveries
    instance.drain_last_progress_tick = instance.drain_last_progress_tick
      or (#instance.drain_targets > 0 and game.tick or nil)
    instance.drain_diagnostic_cursor = instance.drain_diagnostic_cursor or 1
    if instance.drain_wait_reason ~= Constants.DRAIN_WAIT_REASON.NETWORK
      and instance.drain_wait_reason ~= Constants.DRAIN_WAIT_REASON.ROBOTS
      and instance.drain_wait_reason ~= Constants.DRAIN_WAIT_REASON.AVAILABLE_ROBOTS
      and instance.drain_wait_reason ~= Constants.DRAIN_WAIT_REASON.DESTINATION
      and instance.drain_wait_reason ~= Constants.DRAIN_WAIT_REASON.MOVEMENT then
      instance.drain_wait_reason = nil
    end
    instance.drain_input_observed = instance.drain_input_observed == true
    instance.drain_restore_blocked = instance.drain_restore_blocked == true
    instance.auto_cleanup_after_interrupt = not migrate_auto_cleanup
      and instance.auto_cleanup_after_interrupt == true
    instance.requests_started = not migrate_auto_cleanup and instance.requests_started == true
    if migrate_auto_cleanup then
      instance.drain_kind = #instance.drain_targets > 0 and "maintenance" or nil
    elseif instance.drain_kind ~= "automatic" and instance.drain_kind ~= "maintenance" then
      instance.drain_kind = #instance.drain_targets > 0 and "maintenance" or nil
    end
    instance.sign_mode = instance.sign_mode or Constants.SIGN_MODE.ANY
    if migrate_legacy_modes then
      instance.input_mode = Constants.INPUT_MODE.FOLLOW
      instance.tail_mode = Constants.TAIL_MODE.NO_TAIL
      instance.captured_input_mode = Constants.INPUT_MODE.FOLLOW
      instance.captured_tail_mode = Constants.TAIL_MODE.NO_TAIL
      for _, record in ipairs(instance.monitored_inserters) do record.controlled = false end
    else
      instance.input_mode = instance.input_mode or Constants.INPUT_MODE.FOLLOW
      instance.tail_mode = instance.tail_mode or Constants.TAIL_MODE.NO_TAIL
      instance.captured_input_mode = instance.captured_input_mode or Constants.INPUT_MODE.FOLLOW
      instance.captured_tail_mode = instance.captured_tail_mode or Constants.TAIL_MODE.NO_TAIL
    end
    instance.snapshot_zero_observed = instance.snapshot_zero_observed or false
    instance.snapshot_reset_invalidated = instance.snapshot_reset_invalidated or false
    instance.snapshot_new_input_warning = instance.snapshot_new_input_warning or false
    instance.manual_tail_recovery = instance.manual_tail_recovery or false
    instance.temporary_override_count = instance.temporary_override_count or 0
    if instance.cleanup_complete == nil then instance.cleanup_complete = false end
    instance.state = instance.state or Constants.STATE.ARMED
    instance.gui_players = instance.gui_players or {}
    for _, target in ipairs(instance.targets) do
      if not target.unit_number and target.entity and target.entity.valid then
        target.unit_number = target.entity.unit_number
      end
    end
  end
  root.schema_version = Constants.SCHEMA_VERSION
end

return Migrations
