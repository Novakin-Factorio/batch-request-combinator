local Constants = require("runtime.constants")
local Requests = require("runtime.requests")

local Reconciliation = {}

function Reconciliation.normalize_target_aliases(root, present_section_units, stale, record_pre_conflict)
  local seen_target_lists = {}
  local seen_target_tables = {}
  seen_target_lists[root.cleanup_tombstones] = true
  for _, tombstone in pairs(root.cleanup_tombstones) do
    if type(tombstone) == "table" then seen_target_tables[tombstone] = true end
  end
  local function target_key_rank(key)
    if type(key) == "number" then return 1 end
    if type(key) == "string" then return 2 end
    if type(key) == "boolean" then return 3 end
    return 4
  end
  local function stable_number(value)
    if type(value) == "number" and value == value
      and value > -math.huge and value < math.huge then
      return value
    end
    return -math.huge
  end
  local function canonical_cleanup_target(target)
    if type(target) ~= "table" or not Requests.has_owned_section_reference(target) then return nil, nil end
    local entity = target.entity
    local section = target.section
    local unit_number = entity.unit_number
    if type(unit_number) ~= "number" or unit_number ~= unit_number
      or unit_number <= 0 or unit_number >= math.huge or unit_number ~= math.floor(unit_number) then
      return nil, nil
    end
    return {
      entity = entity,
      unit_number = unit_number,
      cleanup_unit_number = unit_number,
      section = section,
    }, {
      Requests.has_current_owned_section(target) and 0 or 1,
      stable_number(entity.surface and entity.surface.index),
      stable_number(entity.force and entity.force.index),
      unit_number,
      stable_number(entity.position and entity.position.x),
      stable_number(entity.position and entity.position.y),
      stable_number(section.index),
      section.active and 0 or 1,
      stable_number(target.section_destroy_registration),
      stable_number(target.destroy_registration),
    }
  end
  local function stable_target_less(left, right)
    for index = 1, #left do
      if left[index] ~= right[index] then return left[index] < right[index] end
    end
    return false
  end
  local function normalize_target_container(instance, record_conflict)
    local targets = instance.targets
    if targets == nil then return end
    if type(targets) ~= "table" then
      instance.targets = {}
      if record_conflict then record_pre_conflict(instance, Constants.ERROR.TARGET_CONFLICT) end
      return
    end
    local count = 0
    local maximum = 0
    local dense = true
    for key in pairs(targets) do
      if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
        dense = false
      else
        count = count + 1
        maximum = math.max(maximum, key)
      end
    end
    dense = dense and maximum == count
    if dense then return end
    local entries = {}
    local seen_rank4_sections = {}
    for key, target in pairs(targets) do
      local rank = target_key_rank(key)
      local normalized_target = target
      local identity
      local append_entry = true
      if rank == 4 then
        normalized_target, identity = canonical_cleanup_target(target)
        local section = normalized_target and normalized_target.section or nil
        local retained_entry = section and seen_rank4_sections[section] or nil
        if retained_entry then
          if stable_target_less(identity, retained_entry.identity) then retained_entry.identity = identity end
          append_entry = false
        elseif section then
          local entry = {
            key = key,
            rank = rank,
            target = normalized_target,
            identity = identity,
          }
          entries[#entries + 1] = entry
          seen_rank4_sections[section] = entry
          append_entry = false
        else
          append_entry = false
        end
      end
      if append_entry then
        entries[#entries + 1] = {
          key = key,
          rank = rank,
          target = normalized_target,
          identity = identity,
        }
      end
    end
    table.sort(entries, function(left, right)
      local left_rank = left.rank
      local right_rank = right.rank
      if left_rank ~= right_rank then return left_rank < right_rank end
      if left_rank == 1 or left_rank == 2 then return left.key < right.key end
      if left_rank == 3 then return left.key == false and right.key == true end
      if not left.identity then return right.identity ~= nil end
      if not right.identity then return false end
      return stable_target_less(left.identity, right.identity)
    end)
    local normalized = {}
    local index = 1
    while index <= #entries do
      local entry = entries[index]
      if entry.rank ~= 4 then
        if type(entry.target) == "table" then normalized[#normalized + 1] = entry.target end
        index = index + 1
      elseif type(entry.target) ~= "table" then
        index = index + 1
      else
        local group_end = index
        while group_end + 1 <= #entries do
          local next_entry = entries[group_end + 1]
          if next_entry.rank ~= 4 or type(next_entry.target) ~= "table"
            or stable_target_less(entry.identity, next_entry.identity)
            or stable_target_less(next_entry.identity, entry.identity) then
            break
          end
          group_end = group_end + 1
        end
        if group_end == index then
          normalized[#normalized + 1] = entry.target
        else
          -- Native logistic sections are unique by owner, index, and current membership. A residual tie is corrupt state, so neutralize every exact object instead of choosing by table identity.
          local all_inactive = true
          for tied_index = index, group_end do
            local tied_target = entries[tied_index].target
            local section = tied_target.section
            local deactivated, inactive = pcall(function()
              section.active = false
              return section.active == false
            end)
            if not deactivated or not inactive then all_inactive = false end
          end
          if not all_inactive then
            error("Batch Request Combinator could not quarantine ambiguous owned request sections")
          end
          local removal_failed = false
          for tied_index = index, group_end do
            local tied_target = entries[tied_index].target
            local section = tied_target.section
            if section.valid and Requests.has_current_owned_section(tied_target) then
              local point = tied_target.entity.get_requester_point()
              if point and point.valid then
                local called, removed = pcall(point.remove_section, section.index)
                if not called or (not removed and section.valid) then removal_failed = true end
              else
                removal_failed = true
              end
            end
          end
          if removal_failed then
            error("Batch Request Combinator could not quarantine ambiguous owned request sections")
          end
        end
        index = group_end + 1
      end
    end
    instance.targets = normalized
    if record_conflict then record_pre_conflict(instance, Constants.ERROR.TARGET_CONFLICT) end
  end
  local function isolate_target_aliases(instance, record_conflict)
    if type(instance.targets) == "table" and seen_target_lists[instance.targets] then
      local isolated_targets = {}
      for key, value in pairs(instance.targets) do isolated_targets[key] = value end
      instance.targets = isolated_targets
      if record_conflict then record_pre_conflict(instance, Constants.ERROR.TARGET_CONFLICT) end
    elseif type(instance.targets) == "table" then
      seen_target_lists[instance.targets] = true
    end
    normalize_target_container(instance, record_conflict)
    for index, target in ipairs(instance.targets or {}) do
      if type(target) == "table" then
        if seen_target_tables[target] then
          local isolated = {}
          for key, value in pairs(target) do isolated[key] = value end
          instance.targets[index] = isolated
          if record_conflict then record_pre_conflict(instance, Constants.ERROR.TARGET_CONFLICT) end
        else
          seen_target_tables[target] = true
        end
      else
        instance.targets[index] = {}
        if record_conflict then record_pre_conflict(instance, Constants.ERROR.TARGET_CONFLICT) end
      end
    end
  end
  for _, unit_number in ipairs(present_section_units) do
    local instance = root.instances[unit_number]
    if instance then isolate_target_aliases(instance, true) end
  end
  for _, entry in ipairs(stale) do isolate_target_aliases(entry.instance, false) end
end

return Reconciliation
