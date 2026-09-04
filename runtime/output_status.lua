local Constants = require("runtime.constants")
local Registry = require("runtime.registry")
local Util = require("runtime.util")

local OutputStatus = {}
local ensured_by_unit = {}
local OUTPUT_AUDIT_INTERVAL = 60

local function is_active_state(state)
  return state == Constants.STATE.DRAINING
    or state == Constants.STATE.REQUESTING
    or state == Constants.STATE.SETTLING
    or state == Constants.STATE.READY
    or state == Constants.STATE.COMPLETE
end

local function owner_anchor_changed(instance, parent)
  local anchor = instance.owner_anchor
  return anchor
    and (anchor.surface_index ~= parent.surface.index
      or anchor.force_index ~= parent.force.index
      or anchor.x ~= parent.position.x
      or anchor.y ~= parent.position.y)
end

local function record_owner_anchor(instance, parent)
  local anchor = instance.owner_anchor
  if not anchor then
    anchor = {}
    instance.owner_anchor = anchor
  end
  anchor.surface_index = parent.surface.index
  anchor.force_index = parent.force.index
  anchor.x = parent.position.x
  anchor.y = parent.position.y
end

local function clear_visible_behavior(entity)
  local behavior = entity.get_or_create_control_behavior()
  if behavior and behavior.valid and behavior.parameters ~= nil then behavior.parameters = nil end
end

local function helper_candidates(entity)
  local found = entity.surface.find_entities_filtered{
    name = Constants.OUTPUT_ENTITY_NAME,
    position = entity.position,
    radius = 0.05,
    force = entity.force,
  }
  local candidates = {}
  for _, helper in pairs(found) do
    if helper and helper.valid and helper.name == Constants.OUTPUT_ENTITY_NAME
      and helper.surface.index == entity.surface.index
      and helper.force.index == entity.force.index
      and helper.position.x == entity.position.x
      and helper.position.y == entity.position.y then
      candidates[#candidates + 1] = helper
    end
  end
  table.sort(candidates, function(left, right) return left.unit_number < right.unit_number end)
  return candidates
end

local function clear_helper_registration(instance)
  local registration = instance.helper_destroy_registration
  if not registration then return end
  local root = Registry.root()
  local record = root.destroyed[registration]
  if record and record.kind == "helper" and record.owner == instance.unit_number then
    root.destroyed[registration] = nil
  end
  instance.helper_destroy_registration = nil
end

local function valid_helper(helper)
  return helper and helper.valid and helper.name == Constants.OUTPUT_ENTITY_NAME
end

local function helper_matches_anchor(helper, anchor)
  return valid_helper(helper)
    and anchor
    and helper.surface.index == anchor.surface_index
    and helper.force.index == anchor.force_index
    and helper.position.x == anchor.x
    and helper.position.y == anchor.y
end

local function helper_matches_parent(instance, helper)
  local parent = instance.entity
  return Util.valid_entity(parent)
    and valid_helper(helper)
    and helper.surface.index == parent.surface.index
    and helper.force.index == parent.force.index
    and helper.position.x == parent.position.x
    and helper.position.y == parent.position.y
end

local function detach_untrusted_helper(instance, allow_saved_anchor)
  local helper = instance.helper
  if not helper or not helper.valid then return false end
  if helper_matches_parent(instance, helper)
    or (allow_saved_anchor and helper_matches_anchor(helper, instance.owner_anchor)) then
    return false
  end
  clear_helper_registration(instance)
  ensured_by_unit[instance.unit_number] = nil
  instance.helper = nil
  instance.output_signature = nil
  return true
end

function OutputStatus.detach_mismatched_helper(instance)
  return detach_untrusted_helper(instance, false)
end

local function connect_pair(parent, helper, parent_id, helper_id)
  local parent_connector = parent.get_wire_connector(parent_id, true)
  local helper_connector = helper.get_wire_connector(helper_id, true)
  if not parent_connector or not helper_connector then return false end
  if helper_connector.is_connected_to(parent_connector, defines.wire_origin.script) then return true end
  local connected = helper_connector.connect_to(
    parent_connector,
    false,
    defines.wire_origin.script
  )
  return connected
    or helper_connector.is_connected_to(parent_connector, defines.wire_origin.script)
end

local function connect_helper(parent, helper)
  local wire = defines.wire_connector_id
  return connect_pair(parent, helper, wire.combinator_output_red, wire.circuit_red)
    and connect_pair(parent, helper, wire.combinator_output_green, wire.circuit_green)
end

local function register_helper(instance, helper)
  local root = Registry.root()
  clear_helper_registration(instance)
  local registration = script.register_on_object_destroyed(helper)
  instance.helper_destroy_registration = registration
  root.destroyed[registration] = {kind = "helper", owner = instance.unit_number}
end

local function reset_helper_behavior(helper)
  local behavior = helper.get_or_create_control_behavior()
  if not behavior or not behavior.valid then return nil end
  while behavior.sections_count > 1 do behavior.remove_section(behavior.sections_count) end
  local section = behavior.sections_count == 1 and behavior.get_section(1) or behavior.add_section()
  if not section or not section.valid or not section.is_manual then return nil end
  return section
end

local function clear_filters(section)
  for index = section.filters_count, 1, -1 do
    local ok = pcall(section.clear_slot, index)
    if not ok then return false end
  end
  return true
end

local function same_filter(actual, expected)
  local actual_value = actual and actual.value
  local expected_value = expected.value
  return actual_value
    and actual_value.name == expected_value.name
    and (actual_value.type or expected_value.type) == expected_value.type
    and (actual_value.quality or "normal") == (expected_value.quality or "normal")
    and actual.min == expected.min
end

local function replace_filters(section, filters)
  if not clear_filters(section) then return false end
  for index, filter in ipairs(filters) do
    local wrote = pcall(section.set_slot, index, filter)
    local read, actual = pcall(section.get_slot, index)
    if not wrote or not read or not same_filter(actual, filter) then return false end
  end
  return true
end

function OutputStatus.ensure(instance, force_audit)
  local parent = instance.entity
  if not Util.valid_entity(parent) then return false, Constants.ERROR.TARGET_LOST end
  local tick = game and game.tick or nil
  local cached = tick and ensured_by_unit[instance.unit_number] or nil
  if cached and cached.tick == tick and cached.helper == instance.helper
    and cached.section and cached.section.valid and helper_matches_parent(instance, cached.helper)
    and instance.helper_destroy_registration
    and Registry.root().destroyed[instance.helper_destroy_registration] then
    return true, nil, cached.section
  end
  local owner_moved = owner_anchor_changed(instance, parent)
  local repair_needed = false
  if owner_moved then
    OutputStatus.destroy(instance)
    instance.output_signature = nil
    if is_active_state(instance.state) then
      return false, Constants.ERROR.TARGET_LOST
    end
    repair_needed = true
  end
  if detach_untrusted_helper(instance, owner_moved) then repair_needed = true end
  if not instance.owner_anchor or owner_moved then record_owner_anchor(instance, parent) end
  local helper = instance.helper
  if not valid_helper(helper) then
    local candidates = helper_candidates(parent)
    helper = candidates[1]
    if not helper then
      helper = parent.surface.create_entity{
        name = Constants.OUTPUT_ENTITY_NAME,
        position = parent.position,
        direction = parent.direction,
        force = parent.force,
        create_build_effect_smoke = false,
      }
    end
    if not helper then return false, Constants.ERROR.OUTPUT_UNAVAILABLE end
    instance.helper = helper
    helper.destructible = false
    helper.operable = false
    register_helper(instance, helper)
    for index = 2, #candidates do candidates[index].destroy() end
    instance.output_signature = nil
    repair_needed = true
  end
  local root = Registry.root()
  if not instance.helper_destroy_registration
    or not root.destroyed[instance.helper_destroy_registration] then
    register_helper(instance, helper)
    repair_needed = true
  end
  if helper.surface.index ~= parent.surface.index
    or helper.position.x ~= parent.position.x or helper.position.y ~= parent.position.y then
    return false, Constants.ERROR.OUTPUT_UNAVAILABLE
  end
  if helper.force.index ~= parent.force.index then
    local changed = pcall(function() helper.force = parent.force end)
    if not changed or helper.force.index ~= parent.force.index then
      return false, Constants.ERROR.OUTPUT_UNAVAILABLE
    end
    repair_needed = true
  end
  if helper.direction ~= parent.direction then
    helper.direction = parent.direction
    repair_needed = true
  end
  local audit_due = not tick or type(instance.output_audit_tick) ~= "number"
    or tick >= instance.output_audit_tick
  if not force_audit and not repair_needed and not audit_due then return true end
  clear_visible_behavior(parent)
  if not connect_helper(parent, helper) then return false, Constants.ERROR.OUTPUT_UNAVAILABLE end
  local section = reset_helper_behavior(helper)
  if not section then return false, Constants.ERROR.OUTPUT_UNAVAILABLE end
  if tick then instance.output_audit_tick = tick + OUTPUT_AUDIT_INTERVAL end
  if tick then ensured_by_unit[instance.unit_number] = {tick = tick, helper = helper, section = section} end
  return true, nil, section
end

local function state_filters(instance)
  local state = instance.state
  local filters = {}
  local signal
  local count = 1
  if state == Constants.STATE.ARMED then
    signal = Constants.STATUS_SIGNAL.armed
  elseif state == Constants.STATE.REQUESTING then
    signal = Constants.STATUS_SIGNAL.requesting
  elseif state == Constants.STATE.SETTLING then
    signal = Constants.STATUS_SIGNAL.settling
  elseif state == Constants.STATE.READY then
    signal = Constants.STATUS_SIGNAL.ready
  elseif state == Constants.STATE.COMPLETE then
    signal = Constants.STATUS_SIGNAL.complete
  elseif state == Constants.STATE.ERROR then
    signal = Constants.STATUS_SIGNAL.error
    count = instance.error_code or 1
  elseif state == Constants.STATE.ABORTED then
    signal = Constants.STATUS_SIGNAL.aborted
  end
  if signal then
    filters[#filters + 1] = {
      value = {type = "virtual", name = signal, quality = "normal", comparator = "="},
      min = count,
    }
  end
  if instance.warning_input_changed then
    filters[#filters + 1] = {
      value = {type = "virtual", name = Constants.STATUS_SIGNAL.warning, quality = "normal", comparator = "="},
      min = 1,
    }
  end
  return filters
end

local function output_signature(filters)
  local parts = {}
  for _, filter in ipairs(filters) do
    parts[#parts + 1] = filter.value.name .. ":" .. tostring(filter.min)
  end
  return table.concat(parts, ";")
end

local function diode_for_state(state)
  if state == Constants.STATE.ERROR or state == Constants.STATE.ABORTED then
    return defines.entity_status_diode.red
  end
  if state == Constants.STATE.DRAINING
    or state == Constants.STATE.REQUESTING or state == Constants.STATE.SETTLING then
    return defines.entity_status_diode.yellow
  end
  return defines.entity_status_diode.green
end

local function status_label(instance)
  if instance.state == Constants.STATE.ERROR and instance.error_code then
    return {"batch-request-combinator.status-error-detail", Util.localised_error(instance.error_code, instance.error_detail)}
  end
  return {"batch-request-combinator.state-" .. instance.state}
end

local function render_signal(instance, filters)
  if instance.status_render and instance.status_render.valid then instance.status_render.destroy() end
  instance.status_render = nil
  if not filters[1] then return end
  instance.status_render = rendering.draw_sprite{
    sprite = "virtual-signal." .. filters[1].value.name,
    target = {entity = instance.entity, offset = {0, -0.1}},
    surface = instance.entity.surface,
    only_in_alt_mode = true,
    x_scale = 0.5,
    y_scale = 0.5,
    render_layer = "entity-info-icon-above",
  }
end

function OutputStatus.update(instance, force)
  local ensured, error_code, section = OutputStatus.ensure(instance, true)
  if not ensured then return false, error_code end
  local filters = state_filters(instance)
  local signature = output_signature(filters)
  if force or instance.output_signature ~= signature then
    if not section or not replace_filters(section, filters) then return false end
    section.active = true
    instance.output_signature = signature
    render_signal(instance, filters)
  end
  instance.entity.custom_status = {
    diode = diode_for_state(instance.state),
    label = status_label(instance),
  }
  return true
end

function OutputStatus.destroy(instance)
  ensured_by_unit[instance.unit_number] = nil
  instance.output_audit_tick = nil
  if instance.status_render and instance.status_render.valid then instance.status_render.destroy() end
  instance.status_render = nil
  detach_untrusted_helper(instance, true)
  clear_helper_registration(instance)
  if valid_helper(instance.helper) then instance.helper.destroy() end
  instance.helper = nil
  if instance.entity and instance.entity.valid then instance.entity.custom_status = nil end
end

function OutputStatus.fail_safe_off(instance)
  instance.output_signature = nil
  if detach_untrusted_helper(instance, true) then return false end
  local helper = instance.helper
  if not helper or not helper.valid then return true end
  local ok = pcall(function()
    local section = reset_helper_behavior(helper)
    if not section then error("missing output section") end
    if not clear_filters(section) then error("output section clear failed") end
    section.active = true
  end)
  if ok then return true end
  clear_helper_registration(instance)
  helper.destroy()
  instance.helper = nil
  return false
end

function OutputStatus.on_cloned_helper(helper)
  if helper and helper.valid then helper.destroy() end
end

return OutputStatus
