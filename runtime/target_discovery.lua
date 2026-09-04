local Constants = require("runtime.constants")
local Allocation = require("runtime.allocation")
local Util = require("runtime.util")

local TargetDiscovery = {}
local cached_root_tick
local cached_root_parent
local cached_roots = {}

local function root_connector(parent, connector_id)
  local tick = game and game.tick or nil
  if not tick then return parent.get_wire_connector(connector_id, false) end
  if cached_root_tick ~= tick or cached_root_parent ~= parent then
    cached_root_tick = tick
    cached_root_parent = parent
    cached_roots = {}
  end
  local root = cached_roots[connector_id]
  if root == nil then
    root = parent.get_wire_connector(connector_id, false) or false
    cached_roots[connector_id] = root
  end
  return root or nil
end

local function is_parent_output_connector(connector, parent)
  if connector.owner ~= parent then return false end
  local connector_id = connector.wire_connector_id
  local ids = defines.wire_connector_id
  return connector_id == ids.combinator_output_red or connector_id == ids.combinator_output_green
end

local function connector_key(connector)
  local owner = connector.owner
  if not Util.valid_entity(owner) then return nil end
  return tostring(owner.unit_number) .. ":" .. tostring(connector.wire_connector_id)
end

local function add_endpoint(endpoints_by_unit, connector, root_connector_id)
  local owner = connector.owner
  if not Util.valid_entity(owner) or owner.name == Constants.OUTPUT_ENTITY_NAME then return end
  local endpoints = endpoints_by_unit[owner.unit_number]
  if not endpoints then
    endpoints = {}
    endpoints_by_unit[owner.unit_number] = endpoints
  end
  endpoints[#endpoints + 1] = {
    connector = connector,
    connector_id = connector.wire_connector_id,
    root_connector_id = root_connector_id,
    network_id = connector.network_id,
  }
end

local function selected_input_network(entity, root_connector_id)
  if entity.type ~= "inserter" then return true end
  local behavior = entity.get_control_behavior and entity.get_control_behavior() or nil
  local selection = behavior and behavior.valid and behavior.input_networks or nil
  if selection == nil then return true end
  local ids = defines.wire_connector_id
  if root_connector_id == ids.combinator_output_red then return selection.red ~= false end
  if root_connector_id == ids.combinator_output_green then return selection.green ~= false end
  return false
end

function TargetDiscovery.validate_cached_endpoint(parent, entity, endpoints)
  if not Util.valid_entity(parent) or not Util.valid_entity(entity)
    or type(endpoints) ~= "table" or #endpoints == 0 then
    return false
  end
  for _, endpoint in ipairs(endpoints) do
    local connector = endpoint.connector
    local root = root_connector(parent, endpoint.root_connector_id)
    if connector and connector.valid and connector.owner == entity
      and connector.wire_connector_id == endpoint.connector_id
      and endpoint.network_id ~= 0
      and connector.network_id == endpoint.network_id
      and root and root.valid and root.network_id == endpoint.network_id
      and selected_input_network(entity, endpoint.root_connector_id) then
      return true
    end
  end
  return false
end

local function requester_target(entity, parent)
  if not Util.valid_entity(entity) or not Util.is_same_force_and_surface(entity, parent) then return nil end
  local point = entity.get_requester_point()
  local inventory = entity.get_inventory(defines.inventory.chest)
  if not point or not point.valid or not inventory or not inventory.valid then return nil end
  if point.mode ~= defines.logistic_mode.requester then return nil end
  return {entity = entity, unit_number = entity.unit_number}
end

function TargetDiscovery.discover(parent)
  local connector_ids = defines.wire_connector_id
  local starts = {
    parent.get_wire_connector(connector_ids.combinator_output_red, false),
    parent.get_wire_connector(connector_ids.combinator_output_green, false),
  }
  local queue = {}
  for index, connector in ipairs(starts) do
    if connector and connector.valid then
      queue[#queue + 1] = {connector = connector, root_connector_id = index == 1
        and connector_ids.combinator_output_red or connector_ids.combinator_output_green}
    end
  end

  local visited_connectors = {}
  local seen_entities = {}
  local targets = {}
  local inserters = {}
  local endpoints_by_unit = {}
  local cursor = 1
  while cursor <= #queue do
    local queued = queue[cursor]
    local connector = queued.connector
    cursor = cursor + 1
    if connector and connector.valid then
      local key = connector_key(connector)
      if key and not visited_connectors[key] then
        visited_connectors[key] = true
        local owner = connector.owner
        if owner ~= parent then add_endpoint(endpoints_by_unit, connector, queued.root_connector_id) end
        local may_traverse = owner ~= parent or is_parent_output_connector(connector, parent)
        if Util.valid_entity(owner) and owner ~= parent and owner.name ~= Constants.OUTPUT_ENTITY_NAME then
          local unit_number = owner.unit_number
          if not seen_entities[unit_number] then
            seen_entities[unit_number] = true
            local target = requester_target(owner, parent)
            if target then targets[#targets + 1] = target end
            if owner.type == "inserter" then inserters[#inserters + 1] = owner end
          end
        end
        if may_traverse then
          for _, connection in pairs(connector.real_connections) do
            local next_connector = connection.target
            if next_connector and next_connector.valid then
              queue[#queue + 1] = {
                connector = next_connector,
                root_connector_id = queued.root_connector_id,
              }
            end
          end
        end
      end
    end
  end

  Allocation.sort_targets(targets)
  for _, target in ipairs(targets) do
    target.topology_endpoints = endpoints_by_unit[target.unit_number] or {}
  end
  table.sort(inserters, function(left, right) return left.unit_number < right.unit_number end)
  return targets, inserters, endpoints_by_unit
end

function TargetDiscovery.inserters_empty(inserters)
  for _, inserter in ipairs(inserters or {}) do
    if not inserter.valid then return false, "invalid" end
    local held = inserter.held_stack
    if held and held.valid_for_read and held.count > 0 then
      return false, inserter.localised_name
    end
  end
  return true
end

return TargetDiscovery
