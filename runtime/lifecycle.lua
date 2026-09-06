local Constants = require("runtime.constants")
local BatchCoordinator = require("runtime.batch_coordinator")
local Drain = require("runtime.drain")
local Gui = require("runtime.gui")
local InserterController = require("runtime.inserter_controller")
local OutputStatus = require("runtime.output_status")
local Reconciliation = require("runtime.reconciliation")
local Registry = require("runtime.registry")
local Requests = require("runtime.requests")
local StateMachine = require("runtime.state_machine")

local Lifecycle = {}
local pending_replacement_tick
local pending_replacements = {}

local function safe_state_call(instance, callback, ...)
  local ok, failure = pcall(callback, instance, ...)
  if ok then return true end
  local handled, handler_failure = pcall(StateMachine.on_runtime_error, instance, failure)
  if not handled then
    pcall(OutputStatus.fail_safe_off, instance)
    log("[Batch Request Combinator] lifecycle error handler failed for instance "
      .. tostring(instance and instance.unit_number) .. ": " .. tostring(handler_failure))
  end
  return false
end

local function refresh_output(instance)
  local called, updated, error_code = pcall(OutputStatus.update, instance, true)
  if called and updated then return true end
  if not called then
    safe_state_call(instance, StateMachine.on_runtime_error, updated)
  else
    safe_state_call(instance, StateMachine.fail, error_code or Constants.ERROR.OUTPUT_UNAVAILABLE)
  end
  return false
end

local function valid_sign_mode(mode)
  return mode == Constants.SIGN_MODE.ANY
    or mode == Constants.SIGN_MODE.POSITIVE
    or mode == Constants.SIGN_MODE.NEGATIVE
end

local function valid_input_mode(mode)
  return mode == Constants.INPUT_MODE.FOLLOW or mode == Constants.INPUT_MODE.SNAPSHOT
end

local function valid_tail_mode(mode)
  return mode == Constants.TAIL_MODE.NO_TAIL
    or mode == Constants.TAIL_MODE.SINGLE
    or mode == Constants.TAIL_MODE.PARALLEL
end

local function normalized_configuration(configuration)
  if type(configuration) ~= "table" then configuration = {sign_mode = configuration} end
  return {
    sign_mode = valid_sign_mode(configuration.sign_mode)
      and configuration.sign_mode or Constants.SIGN_MODE.ANY,
    input_mode = valid_input_mode(configuration.input_mode)
      and configuration.input_mode or Constants.INPUT_MODE.FOLLOW,
    tail_mode = valid_tail_mode(configuration.tail_mode)
      and configuration.tail_mode or Constants.TAIL_MODE.PARALLEL,
    auto_cleanup_after_interrupt = configuration.auto_cleanup_after_interrupt == true,
  }
end

local function exact_replacement(surface, force_index, position, excluded_unit_number)
  if not surface or not position then return nil end
  local candidates = surface.find_entities_filtered{
    name = Constants.ENTITY_NAME,
    position = position,
  }
  table.sort(candidates, function(left, right) return left.unit_number < right.unit_number end)
  for _, candidate in ipairs(candidates) do
    if candidate.valid
      and candidate.unit_number ~= excluded_unit_number
      and candidate.surface.index == surface.index
      and candidate.force.index == force_index
      and candidate.position.x == position.x
      and candidate.position.y == position.y then
      return candidate
    end
  end
  return nil
end

local function current_pending_replacements()
  if pending_replacement_tick ~= game.tick then
    pending_replacement_tick = game.tick
    pending_replacements = {}
  end
  return pending_replacements
end

local function pending_slot(surface_index, force_index, position, create)
  local pending = current_pending_replacements()
  local by_force = pending[surface_index]
  if not by_force and create then
    by_force = {}
    pending[surface_index] = by_force
  end
  local by_x = by_force and by_force[force_index]
  if not by_x and create then
    by_x = {}
    by_force[force_index] = by_x
  end
  local by_y = by_x and by_x[position.x]
  if not by_y and create then
    by_y = {}
    by_x[position.x] = by_y
  end
  return by_y
end

local function remember_pending_replacement(instance)
  local entity = instance and instance.entity
  local anchor = instance and instance.owner_anchor
  local surface_index = entity and entity.valid and entity.surface.index
    or (anchor and anchor.surface_index)
  local force_index = entity and entity.valid and entity.force.index
    or (anchor and anchor.force_index)
  local position = entity and entity.valid and entity.position
    or (anchor and {x = anchor.x, y = anchor.y})
  if not surface_index or not force_index or not position then return end
  local slot = pending_slot(surface_index, force_index, position, true)
  slot[position.y] = normalized_configuration(instance)
end

local function take_pending_replacement(entity)
  if not entity or not entity.valid then return nil end
  local slot = pending_slot(entity.surface.index, entity.force.index, entity.position, false)
  if not slot then return nil end
  local configuration = slot[entity.position.y]
  slot[entity.position.y] = nil
  return configuration
end

local function registered_predecessor(entity)
  if not entity or not entity.valid then return nil end
  local candidate = exact_replacement(
    entity.surface,
    entity.force.index,
    entity.position,
    entity.unit_number
  )
  return candidate and Registry.instance(candidate.unit_number) or nil
end

local function replacement_for_instance(instance)
  local entity = instance and instance.entity
  local anchor = instance and instance.owner_anchor
  local surface = entity and entity.valid and entity.surface
    or (anchor and game.surfaces[anchor.surface_index])
  local force_index = entity and entity.valid and entity.force.index
    or (anchor and anchor.force_index)
  local position = entity and entity.valid and entity.position
    or (anchor and {x = anchor.x, y = anchor.y})
  return force_index and exact_replacement(surface, force_index, position, instance.unit_number) or nil
end

local function handoff_replacement(instance, replacement)
  if not instance or not replacement or not replacement.valid then return nil end
  local configuration = normalized_configuration(instance)
  Lifecycle.remove_instance(instance)
  return Lifecycle.register(replacement, configuration)
end

local function event_entity(event)
  return event.entity or event.created_entity or event.destination
end

local function tags_configuration(tags)
  local schema = tags and tags[Constants.BLUEPRINT_SCHEMA_TAG]
  local configuration = {
    sign_mode = tags and tags[Constants.BLUEPRINT_SIGN_MODE_TAG],
    input_mode = Constants.INPUT_MODE.FOLLOW,
    tail_mode = Constants.TAIL_MODE.PARALLEL,
    auto_cleanup_after_interrupt = false,
  }
  if schema == 2 then
    local input_mode = tags[Constants.BLUEPRINT_INPUT_MODE_TAG]
    local tail_mode = tags[Constants.BLUEPRINT_TAIL_MODE_TAG]
    if valid_input_mode(input_mode) and valid_tail_mode(tail_mode) then
      configuration.input_mode = input_mode
      configuration.tail_mode = tail_mode
    end
  elseif schema == Constants.BLUEPRINT_SCHEMA_VERSION then
    local input_mode = tags[Constants.BLUEPRINT_INPUT_MODE_TAG]
    local tail_mode = tags[Constants.BLUEPRINT_TAIL_MODE_TAG]
    local auto_cleanup = tags[Constants.BLUEPRINT_AUTO_CLEANUP_AFTER_INTERRUPT_TAG]
    if valid_input_mode(input_mode)
      and valid_tail_mode(tail_mode)
      and type(auto_cleanup) == "boolean" then
      configuration.input_mode = input_mode
      configuration.tail_mode = tail_mode
      configuration.auto_cleanup_after_interrupt = auto_cleanup
    end
  end
  return normalized_configuration(configuration)
end

function Lifecycle.register(entity, configuration)
  if not entity or not entity.valid or entity.name ~= Constants.ENTITY_NAME then return nil end
  local instance = Registry.add(entity, normalized_configuration(configuration))
  refresh_output(instance)
  return instance
end

function Lifecycle.on_built(event)
  local entity = event_entity(event)
  if not entity or not entity.valid then return end
  if entity.name == Constants.OUTPUT_ENTITY_NAME then
    OutputStatus.on_cloned_helper(entity)
    return
  end
  if entity.name == Constants.ENTITY_NAME then
    local pending_configuration = take_pending_replacement(entity)
    local predecessor = registered_predecessor(entity)
    if predecessor then
      handoff_replacement(predecessor, entity)
    elseif pending_configuration then
      Lifecycle.register(entity, pending_configuration)
    else
      local existing = Registry.instance(entity.unit_number)
      if existing then
        refresh_output(existing)
      else
        Lifecycle.register(entity, tags_configuration(event.tags))
      end
    end
  end
end

function Lifecycle.on_cloned(event)
  local destination = event.destination
  if not destination or not destination.valid then return end
  if destination.name == Constants.OUTPUT_ENTITY_NAME then
    OutputStatus.on_cloned_helper(destination)
    return
  end
  if destination.name ~= Constants.ENTITY_NAME then return end
  local source = event.source
  local source_instance = source and source.valid and Registry.instance(source.unit_number) or nil
  Lifecycle.register(destination, source_instance and normalized_configuration(source_instance) or nil)
end

function Lifecycle.remove_instance(instance)
  if not instance then return end
  local gui_ok, gui_failure = pcall(Gui.close_instance, instance)
  if not gui_ok then log("[Batch Request Combinator] GUI cleanup failed: " .. tostring(gui_failure)) end
  local state_ok, state_failure = pcall(StateMachine.destroy, instance)
  if not state_ok then
    pcall(OutputStatus.fail_safe_off, instance)
    local drain_ok, drain_restored = pcall(Drain.stop, instance)
    local cleanup_ok, cleaned = pcall(BatchCoordinator.cleanup, instance, true)
    if not cleanup_ok or not cleaned then pcall(BatchCoordinator.detach_failed_cleanup, instance) end
    if not drain_ok or not drain_restored then pcall(Drain.detach_failed_cleanup, instance) end
    log("[Batch Request Combinator] instance cleanup failed for "
      .. tostring(instance.unit_number) .. ": " .. tostring(state_failure))
  end
  local output_ok, output_failure = pcall(OutputStatus.destroy, instance)
  if not output_ok then
    if instance.helper and instance.helper.valid
      and instance.helper.name == Constants.OUTPUT_ENTITY_NAME then
      pcall(instance.helper.destroy)
    end
    log("[Batch Request Combinator] output cleanup failed for "
      .. tostring(instance.unit_number) .. ": " .. tostring(output_failure))
  end
  Registry.remove(instance)
end

function Lifecycle.on_invalid(instance)
  if not instance then return end
  local replacement = replacement_for_instance(instance)
  if replacement then
    handoff_replacement(instance, replacement)
  else
    Lifecycle.remove_instance(instance)
  end
end

function Lifecycle.on_removed(event)
  local entity = event.entity
  if not entity or entity.name ~= Constants.ENTITY_NAME or not entity.unit_number then return end
  local instance = Registry.instance(entity.unit_number)
  if not instance then return end
  local replacement = replacement_for_instance(instance)
  if replacement then
    handoff_replacement(instance, replacement)
  else
    if event.name ~= defines.events.on_entity_died then
      remember_pending_replacement(instance)
    end
    Lifecycle.remove_instance(instance)
  end
end

function Lifecycle.on_object_destroyed(event)
  local record = Registry.destroy_record(event.registration_number)
  if not record then return end
  Registry.clear_destroy_record(event.registration_number)
  local instance = Registry.instance(record.owner)
  if not instance then return end
  if record.kind == "combinator" then
    local replacement = replacement_for_instance(instance)
    if replacement then
      handoff_replacement(instance, replacement)
    else
      remember_pending_replacement(instance)
      Lifecycle.remove_instance(instance)
    end
  else
    safe_state_call(instance, StateMachine.on_managed_object_destroyed, record.kind)
  end
end

function Lifecycle.on_settings_pasted(event)
  local source = event.source
  local destination = event.destination
  if not destination or not destination.valid or destination.name ~= Constants.ENTITY_NAME then return end
  local destination_instance = Registry.instance(destination.unit_number)
    or Lifecycle.register(destination)
  local source_instance = source and source.valid and source.name == Constants.ENTITY_NAME
    and Registry.instance(source.unit_number) or nil
  if source_instance and destination_instance.state == Constants.STATE.ARMED then
    destination_instance.sign_mode = source_instance.sign_mode
    destination_instance.input_mode = source_instance.input_mode
    destination_instance.tail_mode = source_instance.tail_mode
    destination_instance.auto_cleanup_after_interrupt =
      source_instance.auto_cleanup_after_interrupt == true
  end
  refresh_output(destination_instance)
end

function Lifecycle.on_blueprint_settings_pasted(event)
  local entity = event.entity
  if not entity or not entity.valid or entity.name ~= Constants.ENTITY_NAME then return end
  local instance = Registry.instance(entity.unit_number) or Lifecycle.register(entity)
  local configuration = tags_configuration(event.tags)
  if instance.state == Constants.STATE.ARMED then
    instance.sign_mode = configuration.sign_mode
    instance.input_mode = configuration.input_mode
    instance.tail_mode = configuration.tail_mode
    instance.auto_cleanup_after_interrupt = configuration.auto_cleanup_after_interrupt
  end
  refresh_output(instance)
end

function Lifecycle.on_player_setup_blueprint(event)
  local target = event.stack or event.record
  if not target then return end
  local mapping = event.mapping.get()
  for blueprint_index, entity in pairs(mapping) do
    if entity.valid and entity.name == Constants.ENTITY_NAME then
      local instance = Registry.instance(entity.unit_number)
      if instance then
        target.set_blueprint_entity_tag(
          blueprint_index,
          Constants.BLUEPRINT_SCHEMA_TAG,
          Constants.BLUEPRINT_SCHEMA_VERSION
        )
        target.set_blueprint_entity_tag(
          blueprint_index,
          Constants.BLUEPRINT_SIGN_MODE_TAG,
          instance.sign_mode
        )
        target.set_blueprint_entity_tag(
          blueprint_index,
          Constants.BLUEPRINT_INPUT_MODE_TAG,
          instance.input_mode
        )
        target.set_blueprint_entity_tag(
          blueprint_index,
          Constants.BLUEPRINT_TAIL_MODE_TAG,
          instance.tail_mode
        )
        target.set_blueprint_entity_tag(
          blueprint_index,
          Constants.BLUEPRINT_AUTO_CLEANUP_AFTER_INTERRUPT_TAG,
          instance.auto_cleanup_after_interrupt == true
        )
      end
    end
  end
end

function Lifecycle.on_rotated(event)
  local entity = event.entity
  if not entity or entity.name ~= Constants.ENTITY_NAME then return end
  local instance = Registry.instance(entity.unit_number)
  if instance then refresh_output(instance) end
end

function Lifecycle.on_teleported(event)
  local entity = event.entity
  if not entity or entity.name ~= Constants.ENTITY_NAME then return end
  local instance = Registry.instance(entity.unit_number)
  if not instance then return end
  OutputStatus.destroy(instance)
  if instance.state == Constants.STATE.REQUESTING
    or instance.state == Constants.STATE.DRAINING
    or instance.state == Constants.STATE.SETTLING
    or instance.state == Constants.STATE.READY
    or instance.state == Constants.STATE.COMPLETE then
    safe_state_call(instance, StateMachine.fail, Constants.ERROR.TARGET_LOST)
    return
  end
  if not OutputStatus.update(instance, true) then
    safe_state_call(instance, StateMachine.fail, Constants.ERROR.OUTPUT_UNAVAILABLE)
  end
end

function Lifecycle.on_logistic_slot_changed(event)
  local entity = event.entity
  if not entity or not entity.unit_number then return end
  local owner = Registry.root().chest_owners[entity.unit_number]
  local instance = owner and Registry.instance(owner) or nil
  if instance and not instance.mutating_sections and not instance.mutating_drain then
    safe_state_call(instance, StateMachine.on_external_request_changed)
  end
end

local function sorted_instances()
  local root = Registry.root()
  local units = {}
  for unit_number in pairs(root.instances) do units[#units + 1] = unit_number end
  table.sort(units)
  local instances = {}
  for _, unit_number in ipairs(units) do instances[#instances + 1] = root.instances[unit_number] end
  return instances
end

local function sorted_surfaces()
  local surfaces = {}
  for _, surface in pairs(game.surfaces) do surfaces[#surfaces + 1] = surface end
  table.sort(surfaces, function(left, right) return left.index < right.index end)
  return surfaces
end

local function restore_instance_drain(instance)
  local called, restored = pcall(StateMachine.restore_drain_lease, instance)
  if called then return restored end
  safe_state_call(instance, StateMachine.on_runtime_error, restored)
  return false
end

function Lifecycle.restore_loaded_drains()
  for _, instance in ipairs(sorted_instances()) do
    if Drain.has_lease(instance) then restore_instance_drain(instance) end
  end
end

function Lifecycle.reconcile()
  local root = Registry.ensure_storage()
  local present = {}
  local present_entities = {}
  for _, surface in ipairs(sorted_surfaces()) do
    local entities = surface.find_entities_filtered{name = Constants.ENTITY_NAME}
    table.sort(entities, function(left, right) return left.unit_number < right.unit_number end)
    for _, entity in ipairs(entities) do
      present[entity.unit_number] = true
      present_entities[entity.unit_number] = entity
    end
  end

  local invalid_instance_identities = {}
  local registry_keys_by_instance = {}
  for registry_key, instance in pairs(root.instances) do
    local keys = registry_keys_by_instance[instance]
    if not keys then
      keys = {}
      registry_keys_by_instance[instance] = keys
    end
    keys[#keys + 1] = registry_key
  end
  for instance, keys in pairs(registry_keys_by_instance) do
    if #keys > 1 then
      table.sort(keys)
      local retained_key
      for _, registry_key in ipairs(keys) do
        if present[registry_key] and instance.unit_number == registry_key then
          retained_key = registry_key
          break
        end
      end
      if not retained_key then
        for _, registry_key in ipairs(keys) do
          if present[registry_key] then
            retained_key = registry_key
            break
          end
        end
      end
      retained_key = retained_key or keys[1]
      for _, registry_key in ipairs(keys) do
        if registry_key ~= retained_key then root.instances[registry_key] = nil end
      end
      invalid_instance_identities[instance] = true
    end
  end

  local present_units = {}
  for unit_number in pairs(present_entities) do present_units[#present_units + 1] = unit_number end
  table.sort(present_units)
  for _, unit_number in ipairs(present_units) do
    local entity = present_entities[unit_number]
    local instance = root.instances[unit_number]
    if instance then
      local saved_entity = instance.entity
      if type(instance.unit_number) ~= "number" or instance.unit_number ~= unit_number
        or not saved_entity or not saved_entity.valid or saved_entity ~= entity
        or saved_entity.unit_number ~= unit_number then
        invalid_instance_identities[instance] = true
      end
      instance.unit_number = unit_number
      instance.entity = entity
    else
      Registry.add(entity)
    end
  end

  local stale = {}
  for unit_number, instance in pairs(root.instances) do
    if not present[unit_number] then stale[#stale + 1] = {unit = unit_number, instance = instance} end
  end
  table.sort(stale, function(left, right) return left.unit < right.unit end)

  local pre_conflicts = {}
  local function record_pre_conflict(instance, code)
    if not pre_conflicts[instance] then pre_conflicts[instance] = code end
  end
  local function section_state_rank(instance)
    if instance.state == Constants.STATE.REQUESTING then return 1 end
    if instance.state == Constants.STATE.ERROR then return 2 end
    return 3
  end
  local function sorted_instances_for_sections()
    local instances = sorted_instances()
    table.sort(instances, function(left, right)
      local left_rank = section_state_rank(left)
      local right_rank = section_state_rank(right)
      if left_rank ~= right_rank then return left_rank < right_rank end
      return left.unit_number < right.unit_number
    end)
    return instances
  end
  local protected_helpers = {}
  local function protect_helpers_at_owner(instance)
    local entity = instance.entity
    if not entity or not entity.valid then return end
    for _, helper in pairs(entity.surface.find_entities_filtered{
      name = Constants.OUTPUT_ENTITY_NAME,
      position = entity.position,
      radius = 0.05,
      force = entity.force,
    }) do
      if helper.valid
        and helper.surface.index == entity.surface.index
        and helper.force.index == entity.force.index
        and helper.position.x == entity.position.x
        and helper.position.y == entity.position.y then
        protected_helpers[helper] = true
      end
    end
  end
  local present_section_units = {}
  for _, unit_number in ipairs(present_units) do present_section_units[#present_section_units + 1] = unit_number end
  table.sort(present_section_units, function(left, right)
    local left_instance = root.instances[left]
    local right_instance = root.instances[right]
    local left_rank = left_instance and section_state_rank(left_instance) or 4
    local right_rank = right_instance and section_state_rank(right_instance) or 4
    if left_rank ~= right_rank then return left_rank < right_rank end
    return left < right
  end)

  Reconciliation.normalize_target_aliases(
    root,
    present_section_units,
    stale,
    record_pre_conflict
  )

  for _, unit_number in ipairs(present_section_units) do
    local instance = root.instances[unit_number]
    if instance then
      protect_helpers_at_owner(instance)
      local detached_helper = OutputStatus.detach_mismatched_helper(instance)
      if detached_helper and (instance.state == Constants.STATE.DRAINING
        or instance.state == Constants.STATE.REQUESTING
        or instance.state == Constants.STATE.SETTLING
        or instance.state == Constants.STATE.READY
        or instance.state == Constants.STATE.COMPLETE) then
        record_pre_conflict(instance, Constants.ERROR.OUTPUT_UNAVAILABLE)
      end
      if instance.state == Constants.STATE.DRAINING
        or instance.state == Constants.STATE.READY or instance.state == Constants.STATE.COMPLETE then
        local ensured, output_ready, output_error = pcall(OutputStatus.ensure, instance, true)
        if not ensured or not output_ready then
          record_pre_conflict(instance, output_error or Constants.ERROR.OUTPUT_UNAVAILABLE)
        else
          local cleared, clear_result = pcall(OutputStatus.fail_safe_off, instance)
          if not cleared or not clear_result then
            record_pre_conflict(instance, Constants.ERROR.OUTPUT_UNAVAILABLE)
          end
        end
      end
      if instance.helper and instance.helper.valid then protected_helpers[instance.helper] = true end
    end
  end

  local protected_sections = {}
  for _, key in ipairs(Requests.normalize_tombstones()) do
    local tombstone = root.cleanup_tombstones[key]
    local section = tombstone and tombstone.section
    if section and section.valid then
      if protected_sections[section] then
        tombstone.section = nil
      else
        protected_sections[section] = {kind = "tombstone", owner = tombstone.owner}
      end
    end
  end

  for _, unit_number in ipairs(present_section_units) do
    local instance = root.instances[unit_number]
    if instance then
      for _, target in ipairs(instance.targets or {}) do
        local section = target.section
        if section and section.valid then
          if not Requests.has_owned_section_reference(target) then
            target.section = nil
            target.section_destroy_registration = nil
            record_pre_conflict(instance, Constants.ERROR.SECTION_LOST)
          elseif protected_sections[section] then
            target.section = nil
            target.section_destroy_registration = nil
            record_pre_conflict(instance, Constants.ERROR.TARGET_CONFLICT)
          else
            protected_sections[section] = {kind = "instance", owner = unit_number}
            if not Requests.has_current_owned_section(target)
              or (instance.state ~= Constants.STATE.REQUESTING
              and instance.state ~= Constants.STATE.ERROR) then
              record_pre_conflict(instance, Constants.ERROR.SECTION_LOST)
            end
          end
        end
      end
    end
  end

  for _, entry in ipairs(stale) do
    local instance = entry.instance
    if instance.helper and protected_helpers[instance.helper] then
      instance.helper = nil
      instance.helper_destroy_registration = nil
    end
    for _, target in ipairs(instance.targets or {}) do
      local section = target.section
      if section and section.valid then
        if not Requests.has_owned_section_reference(target) then
          target.section = nil
          target.section_destroy_registration = nil
        elseif protected_sections[section] then
          target.section = nil
          target.section_destroy_registration = nil
        else
          protected_sections[section] = {kind = "stale-instance", owner = entry.unit}
        end
      end
    end
  end

  for _, entry in ipairs(stale) do
    entry.instance.unit_number = entry.unit
    Lifecycle.remove_instance(entry.instance)
  end

  Registry.rebuild_buckets()
  root.destroyed = {}
  root.chest_owners = {}
  root.inserter_owners = {}
  root.temporary_overrides = {}
  root.active_batches = {}
  InserterController.restore_tombstone_claims()
  Drain.restore_tombstone_claims()
  local conflicts = {}
  local conflict_by_unit = {}
  local helper_owners = {}
  local function add_conflict(instance, code, detail)
    if conflict_by_unit[instance.unit_number] then return end
    conflict_by_unit[instance.unit_number] = true
    conflicts[#conflicts + 1] = {instance = instance, code = code, detail = detail}
  end

  for _, instance in ipairs(sorted_instances()) do
    local active = instance.state == Constants.STATE.REQUESTING
      or instance.state == Constants.STATE.SETTLING
      or instance.state == Constants.STATE.READY
      or instance.state == Constants.STATE.COMPLETE
    if active then
      local indexed, detail = InserterController.index_saved_temporaries(instance)
      if not indexed then add_conflict(instance, Constants.ERROR.INSERTER_OWNERSHIP, detail) end
    end
  end

  for _, instance in ipairs(sorted_instances()) do
    if invalid_instance_identities[instance] then
      add_conflict(instance, Constants.ERROR.TARGET_CONFLICT)
    end
    if pre_conflicts[instance] then add_conflict(instance, pre_conflicts[instance]) end
    instance.destroy_registration = script.register_on_object_destroyed(instance.entity)
    root.destroyed[instance.destroy_registration] = {kind = "combinator", owner = instance.unit_number}
    instance.helper_destroy_registration = nil
    local saved_helper = instance.helper
    if saved_helper and saved_helper.valid and saved_helper.name == Constants.OUTPUT_ENTITY_NAME then
      local helper_owner = helper_owners[saved_helper.unit_number]
      if helper_owner and helper_owner ~= instance.unit_number then
        instance.helper = nil
        instance.output_signature = nil
        add_conflict(instance, Constants.ERROR.OUTPUT_UNAVAILABLE)
      else
        helper_owners[saved_helper.unit_number] = instance.unit_number
      end
    end
    local output_ready, output_error = OutputStatus.ensure(instance, true)
    if not output_ready then
      add_conflict(instance, output_error or Constants.ERROR.OUTPUT_UNAVAILABLE)
    else
      if instance.state == Constants.STATE.READY or instance.state == Constants.STATE.COMPLETE then
        local clear_called, cleared = pcall(OutputStatus.fail_safe_off, instance)
        if not clear_called or not cleared then
          add_conflict(instance, Constants.ERROR.OUTPUT_UNAVAILABLE)
        end
      end
      if instance.helper and instance.helper.valid then
        helper_owners[instance.helper.unit_number] = instance.unit_number
      end
    end
  end

  local section_owners = {}
  Requests.restore_tombstone_claims(section_owners)

  local reconciled_drains = {}
  local failed_drains = {}
  for _, instance in ipairs(sorted_instances()) do
    if Drain.has_lease(instance) then
      local checked, reconciled, error_code, error_detail = pcall(Drain.reconcile, instance)
      if checked and reconciled then
        reconciled_drains[#reconciled_drains + 1] = instance
      else
        failed_drains[#failed_drains + 1] = {
          instance = instance,
          code = checked and (error_code or Constants.ERROR.DRAIN_RESTORE_FAILED)
            or Constants.ERROR.INTERNAL,
          detail = checked and error_detail or string.sub(tostring(reconciled), 1, 240),
        }
      end
    end
  end
  for _, failure in ipairs(failed_drains) do
    conflict_by_unit[failure.instance.unit_number] = true
    safe_state_call(
      failure.instance,
      StateMachine.fail_drain_reconciliation,
      failure.code,
      failure.detail
    )
  end
  for _, instance in ipairs(reconciled_drains) do
    if not restore_instance_drain(instance) then conflict_by_unit[instance.unit_number] = true end
  end
  for _, failure in ipairs(failed_drains) do
    Drain.quarantine_failed_reconciliation(failure.instance)
  end

  for _, instance in ipairs(sorted_instances_for_sections()) do
    local active = instance.state == Constants.STATE.REQUESTING
      or instance.state == Constants.STATE.SETTLING
      or instance.state == Constants.STATE.READY
      or instance.state == Constants.STATE.COMPLETE
    local seen_targets = {}
    for _, target in ipairs(instance.targets or {}) do
      local retain_cleanup_claim = target.section ~= nil
        and (instance.state == Constants.STATE.ERROR
          or conflict_by_unit[instance.unit_number])
      if active or retain_cleanup_claim then
        local entity = target.entity
        local entity_unit = entity and entity.valid and entity.unit_number or nil
        if type(entity_unit) ~= "number" then
          add_conflict(instance, Constants.ERROR.TARGET_LOST)
        else
          if type(target.unit_number) ~= "number" or target.unit_number ~= entity_unit then
            add_conflict(instance, Constants.ERROR.TARGET_LOST)
          elseif seen_targets[entity_unit] then
            add_conflict(instance, Constants.ERROR.TARGET_CONFLICT)
          end
          seen_targets[entity_unit] = true
        end
      end

      local section = target.section
      if section and section.valid then
        if not Requests.has_owned_section_reference(target) then
          target.section = nil
          target.section_destroy_registration = nil
          add_conflict(instance, Constants.ERROR.SECTION_LOST)
        elseif section_owners[section] then
          target.section = nil
          target.section_destroy_registration = nil
          add_conflict(instance, Constants.ERROR.TARGET_CONFLICT)
        else
          section_owners[section] = {
            kind = "instance",
            owner = instance.unit_number,
            target = target.entity and target.entity.valid and target.entity.unit_number or nil,
          }
          if not Requests.has_current_owned_section(target)
            or (instance.state ~= Constants.STATE.REQUESTING
            and instance.state ~= Constants.STATE.ERROR) then
            add_conflict(instance, Constants.ERROR.SECTION_LOST)
          end
        end
      end
    end
  end

  for _, instance in ipairs(sorted_instances()) do
    local active = instance.state == Constants.STATE.REQUESTING
      or instance.state == Constants.STATE.SETTLING
      or instance.state == Constants.STATE.READY
      or instance.state == Constants.STATE.COMPLETE
    if active or instance.state == Constants.STATE.DRAINING then
      Registry.set_active(instance, true)
    end
    local claimed_targets = {}
    for _, target in ipairs(instance.targets or {}) do
      target.destroy_registration = nil
      target.section_destroy_registration = nil
      local retain_cleanup_claim = target.section ~= nil
        and (instance.state == Constants.STATE.ERROR
          or conflict_by_unit[instance.unit_number])
      if active or retain_cleanup_claim then
        if not target.entity or not target.entity.valid then
          add_conflict(instance, Constants.ERROR.TARGET_LOST)
        else
          local entity_unit = target.entity.unit_number
          local valid_identity = type(entity_unit) == "number"
            and type(target.unit_number) == "number"
            and target.unit_number == entity_unit
          local duplicate = type(entity_unit) == "number" and claimed_targets[entity_unit]
          local quarantine_identity = type(entity_unit) == "number"
            and not valid_identity
            and conflict_by_unit[instance.unit_number]
            and target.section and target.section.valid
          if type(entity_unit) ~= "number" then
            add_conflict(instance, Constants.ERROR.TARGET_LOST)
          elseif duplicate then
            add_conflict(instance, Constants.ERROR.TARGET_CONFLICT)
          elseif not valid_identity and not quarantine_identity then
            add_conflict(instance, Constants.ERROR.TARGET_LOST)
          else
            if quarantine_identity then
              add_conflict(instance, Constants.ERROR.TARGET_LOST)
              target.cleanup_unit_number = entity_unit
            else
              target.cleanup_unit_number = nil
            end
            claimed_targets[entity_unit] = true
            local owner = root.chest_owners[entity_unit]
            if owner and owner ~= instance.unit_number then
              add_conflict(instance, Constants.ERROR.TARGET_CONFLICT)
            else
              root.chest_owners[entity_unit] = instance.unit_number
              target.destroy_registration = script.register_on_object_destroyed(target.entity)
              root.destroyed[target.destroy_registration] = {
                kind = "target",
                owner = instance.unit_number,
                target = entity_unit,
              }
              local section_forbidden = instance.state == Constants.STATE.SETTLING
                or instance.state == Constants.STATE.READY
                or instance.state == Constants.STATE.COMPLETE
              if section_forbidden and target.section ~= nil then
                add_conflict(instance, Constants.ERROR.SECTION_LOST)
              elseif target.section and target.section.valid then
                target.section_destroy_registration = script.register_on_object_destroyed(target.section)
                root.destroyed[target.section_destroy_registration] = {
                  kind = "section",
                  owner = instance.unit_number,
                  target = entity_unit,
                }
              elseif instance.state == Constants.STATE.REQUESTING then
                add_conflict(instance, Constants.ERROR.SECTION_LOST)
              end
            end
          end
        end
      end
    end
  end

  for _, conflict in ipairs(conflicts) do
    safe_state_call(
      conflict.instance,
      StateMachine.fail_reconciliation,
      conflict.code,
      conflict.detail
    )
  end

  for _, instance in ipairs(sorted_instances()) do
    local active = instance.state == Constants.STATE.REQUESTING
      or instance.state == Constants.STATE.SETTLING
      or instance.state == Constants.STATE.READY
      or instance.state == Constants.STATE.COMPLETE
    if active and not conflict_by_unit[instance.unit_number] then
      local controller_checked, controller_valid, controller_error, controller_detail = pcall(
        InserterController.reconcile,
        instance
      )
      if not controller_checked then
        conflict_by_unit[instance.unit_number] = true
        safe_state_call(instance, StateMachine.on_runtime_error, controller_valid)
      elseif not controller_valid then
        conflict_by_unit[instance.unit_number] = true
        safe_state_call(
          instance,
          StateMachine.fail_reconciliation,
          controller_error or Constants.ERROR.INSERTER_CONFIGURATION,
          controller_detail
        )
      end
      local checked, valid, error_code, error_detail = true, true, nil, nil
      if not conflict_by_unit[instance.unit_number] then
        checked, valid, error_code, error_detail = pcall(Requests.validate_reconciled_state, instance)
      end
      if not checked then
        conflict_by_unit[instance.unit_number] = true
        safe_state_call(instance, StateMachine.on_runtime_error, valid)
      elseif not valid then
        conflict_by_unit[instance.unit_number] = true
        safe_state_call(
          instance,
          StateMachine.fail_reconciliation,
          error_code or Constants.ERROR.DELIVERY_MISMATCH,
          error_detail
        )
      end
      if not conflict_by_unit[instance.unit_number]
        and instance.state == Constants.STATE.COMPLETE then
        local complete_checked, complete_valid, complete_error, complete_detail = pcall(
          BatchCoordinator.validate_complete,
          instance
        )
        if not complete_checked then
          conflict_by_unit[instance.unit_number] = true
          safe_state_call(instance, StateMachine.on_runtime_error, complete_valid)
        elseif not complete_valid then
          conflict_by_unit[instance.unit_number] = true
          safe_state_call(
            instance,
            StateMachine.fail_reconciliation,
            complete_error or Constants.ERROR.DELIVERY_MISMATCH,
            complete_detail
          )
        end
      end
    end
  end

  local active_helpers = {}
  for _, instance in ipairs(sorted_instances()) do
    if not conflict_by_unit[instance.unit_number] then
      if InserterController.has_temporary(instance) then
        local clear_called, cleared = pcall(OutputStatus.fail_safe_off, instance)
        if not clear_called or not cleared then
          safe_state_call(
            instance,
            StateMachine.fail_reconciliation,
            Constants.ERROR.OUTPUT_UNAVAILABLE
          )
        else
          instance.reconciliation_output_suppressed = true
        end
      else
        instance.reconciliation_output_suppressed = nil
        refresh_output(instance)
      end
    end
    if instance.helper and instance.helper.valid then active_helpers[instance.helper.unit_number] = true end
  end

  for _, surface in ipairs(sorted_surfaces()) do
    for _, helper in pairs(surface.find_entities_filtered{name = Constants.OUTPUT_ENTITY_NAME}) do
      if not active_helpers[helper.unit_number] then helper.destroy() end
    end
  end
end

return Lifecycle
