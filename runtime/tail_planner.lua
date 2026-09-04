local Constants = require("runtime.constants")
local Util = require("runtime.util")

local TailPlanner = {}

local SINGLE_SEARCH_STATE_LIMIT = 512

local function limit(target, field, key, fallback)
  local values = target[field]
  local value = values and values[key]
  return type(value) == "number" and value or fallback
end

local function transfer_size(target, key)
  local values = target.transfer_by_key
  local value = values and values[key]
  if type(value) ~= "number" or value < 1 or value ~= math.floor(value) then return nil end
  return value
end

local function required_unfiltered_slots(by_key, target)
  local joint = target.joint_capacity
  if not joint then return 0 end
  local required = 0
  for key, count in pairs(by_key) do
    local remaining = math.max(0, count - (joint.existing_by_key[key] or 0))
    remaining = math.max(0, remaining - (joint.dedicated_by_key[key] or 0))
    if remaining > 0 then
      local stack_size = joint.stack_size_by_key[key]
      if type(stack_size) ~= "number" or stack_size < 1 then return math.huge end
      required = required + math.ceil(remaining / stack_size)
    end
  end
  return required
end

local function target_fits(by_key, target)
  for key, count in pairs(by_key) do
    if count < limit(target, "min_by_key", key, 0)
      or count > limit(target, "max_by_key", key, Constants.MAX_REQUEST_VALUE) then
      return false
    end
  end
  for key, minimum in pairs(target.min_by_key or {}) do
    if (by_key[key] or 0) < minimum then return false end
  end
  local joint = target.joint_capacity
  return not joint or required_unfiltered_slots(by_key, target) <= joint.unfiltered_slots
end

local function allocation_from_counts(items, counts)
  local allocations = {}
  for target_index = 1, #counts do
    allocations[target_index] = {items = {}, by_key = {}, total = 0}
  end
  for _, item in ipairs(items) do
    local key = Util.item_key(item.name, item.quality or "normal")
    for target_index, by_key in ipairs(counts) do
      local count = by_key[key] or 0
      if count > 0 then
        local allocated = {name = item.name, quality = item.quality or "normal", count = count}
        local target = allocations[target_index]
        target.items[#target.items + 1] = allocated
        target.by_key[key] = count
        target.total = target.total + count
      end
    end
  end
  return allocations
end

local function allocations_fit(allocations, targets)
  for index, allocation in ipairs(allocations) do
    if not target_fits(allocation.by_key, targets[index]) then return false end
  end
  return true
end

local function add_tail_metadata(plan, items, targets, mode)
  plan.tail_keys_by_target = {}
  local planned = {}
  if mode == Constants.TAIL_MODE.NO_TAIL then
    plan.planned_tail_count = 0
    return plan
  end
  for target_index, allocation in ipairs(plan.allocations) do
    local keys = {}
    for _, item in ipairs(items) do
      local key = Util.item_key(item.name, item.quality or "normal")
      local count = allocation.by_key[key] or 0
      local transfer = transfer_size(targets[target_index], key)
      local is_tail = count > 0 and transfer and count % transfer ~= 0
      if is_tail and (mode == Constants.TAIL_MODE.PARALLEL
        or target_index == plan.tail_target_index) then
        keys[key] = count % transfer
        planned[target_index] = true
      end
    end
    plan.tail_keys_by_target[target_index] = keys
  end
  local count = 0
  for _ in pairs(planned) do count = count + 1 end
  plan.planned_tail_count = count
  return plan
end

local function add_selected(selected, counts, group, target_index)
  selected[group.index] = selected[group.index] or {}
  if selected[group.index][target_index] then return false end
  selected[group.index][target_index] = true
  counts[target_index][group.key] = counts[target_index][group.key] + 1
  group.need = group.need - 1
  return true
end

local function balanced_counts(items, targets)
  local counts = {}
  for index = 1, #targets do counts[index] = {} end
  local groups = {}
  local selected = {}

  for item_index, item in ipairs(items) do
    local key = Util.item_key(item.name, item.quality or "normal")
    local low = math.floor(item.count / #targets)
    local high_count = item.count % #targets
    local group = {index = item_index, key = key, need = high_count, candidates = {}}
    groups[#groups + 1] = group
    for target_index, target in ipairs(targets) do
      local minimum = limit(target, "min_by_key", key, 0)
      local maximum = limit(target, "max_by_key", key, Constants.MAX_REQUEST_VALUE)
      local low_ok = low >= minimum and low <= maximum
      local high_ok = low + 1 >= minimum and low + 1 <= maximum
      if not low_ok and not high_ok then return nil end
      counts[target_index][key] = low
      if not low_ok then
        if group.need <= 0 then return nil end
        add_selected(selected, counts, group, target_index)
      elseif high_ok then
        group.candidates[#group.candidates + 1] = target_index
      end
    end
    if group.need < 0 or group.need > #group.candidates then return nil end
  end

  local capacities = {}
  for target_index, target in ipairs(targets) do
    local joint = target.joint_capacity
    local used = required_unfiltered_slots(counts[target_index], target)
    local capacity = joint and joint.unfiltered_slots or math.huge
    if used > capacity then return nil end
    capacities[target_index] = capacity - used
  end

  local delta_candidates = {}
  for _, group in ipairs(groups) do
    local remaining = {}
    for _, target_index in ipairs(group.candidates) do
      if not (selected[group.index] and selected[group.index][target_index]) then
        local before = required_unfiltered_slots(counts[target_index], targets[target_index])
        counts[target_index][group.key] = counts[target_index][group.key] + 1
        local after = required_unfiltered_slots(counts[target_index], targets[target_index])
        counts[target_index][group.key] = counts[target_index][group.key] - 1
        if after == before and group.need > 0 then
          add_selected(selected, counts, group, target_index)
        else
          remaining[#remaining + 1] = target_index
        end
      end
    end
    delta_candidates[group.index] = remaining
  end

  local owners = {}
  local owner_count = {}
  for index = 1, #targets do owners[index], owner_count[index] = {}, 0 end
  local movable = {}

  local function assign(group_index, seen_targets, seen_groups)
    if seen_groups[group_index] then return false end
    seen_groups[group_index] = true
    local group = groups[group_index]
    for _, target_index in ipairs(delta_candidates[group_index] or {}) do
      if not (selected[group_index] and selected[group_index][target_index])
        and not seen_targets[target_index] then
        seen_targets[target_index] = true
        if owner_count[target_index] < capacities[target_index] then
          add_selected(selected, counts, group, target_index)
          movable[group_index] = movable[group_index] or {}
          movable[group_index][target_index] = true
          owners[target_index][group_index] = true
          owner_count[target_index] = owner_count[target_index] + 1
          return true
        end
        local owner_groups = {}
        for owner_group in pairs(owners[target_index]) do owner_groups[#owner_groups + 1] = owner_group end
        table.sort(owner_groups)
        for _, owner_group in ipairs(owner_groups) do
          owners[target_index][owner_group] = nil
          owner_count[target_index] = owner_count[target_index] - 1
          movable[owner_group][target_index] = nil
          selected[owner_group][target_index] = nil
          counts[target_index][groups[owner_group].key] = counts[target_index][groups[owner_group].key] - 1
          groups[owner_group].need = groups[owner_group].need + 1
          if assign(owner_group, seen_targets, seen_groups) then
            add_selected(selected, counts, group, target_index)
            movable[group_index] = movable[group_index] or {}
            movable[group_index][target_index] = true
            owners[target_index][group_index] = true
            owner_count[target_index] = owner_count[target_index] + 1
            return true
          end
          add_selected(selected, counts, groups[owner_group], target_index)
          movable[owner_group][target_index] = true
          owners[target_index][owner_group] = true
          owner_count[target_index] = owner_count[target_index] + 1
        end
      end
    end
    return false
  end

  for _, group in ipairs(groups) do
    while group.need > 0 do
      if not assign(group.index, {}, {}) then return nil end
    end
  end
  return counts
end

local function balanced_plan(items, targets, mode)
  local counts = balanced_counts(items, targets)
  if not counts then return nil end
  local allocations = allocation_from_counts(items, counts)
  if not allocations_fit(allocations, targets) then return nil end
  if mode == Constants.TAIL_MODE.PARALLEL then
    for target_index, allocation in ipairs(allocations) do
      for key in pairs(allocation.by_key) do
        if not transfer_size(targets[target_index], key) then return nil end
      end
    end
  end
  return add_tail_metadata({allocations = allocations}, items, targets, mode)
end

local function range_score(counts)
  local smallest, largest
  for _, count in ipairs(counts) do
    smallest = smallest and math.min(smallest, count) or count
    largest = largest and math.max(largest, count) or count
  end
  return largest - smallest
end

local function round_up(value, step)
  return math.ceil(value / step) * step
end

local function round_down(value, step)
  return math.floor(value / step) * step
end

local function clone_domains(domains)
  local result = {}
  for item_index, item_domains in ipairs(domains) do
    result[item_index] = {}
    for target_index, domain in ipairs(item_domains) do
      result[item_index][target_index] = {
        low = domain.low,
        high = domain.high,
        step = domain.step,
        key = domain.key,
      }
    end
  end
  return result
end

local function slot_usage(target, key, count)
  local joint = target.joint_capacity
  if not joint then return 0 end
  local covered = (joint.existing_by_key[key] or 0) + (joint.dedicated_by_key[key] or 0)
  local remaining = math.max(0, count - covered)
  if remaining == 0 then return 0 end
  local stack_size = joint.stack_size_by_key[key]
  if type(stack_size) ~= "number" or stack_size < 1 then return math.huge end
  return math.ceil(remaining / stack_size)
end

local function initial_domains(items, targets, tail_index)
  local domains = {}
  for item_index, item in ipairs(items) do
    local key = Util.item_key(item.name, item.quality or "normal")
    domains[item_index] = {}
    for target_index, target in ipairs(targets) do
      if not transfer_size(target, key) then return nil end
      local step = target_index == tail_index and 1 or transfer_size(target, key)
      local low = math.max(0, limit(target, "min_by_key", key, 0))
      local high = math.min(item.count, limit(
        target,
        "max_by_key",
        key,
        Constants.MAX_REQUEST_VALUE
      ))
      low = round_up(low, step)
      high = round_down(high, step)
      if low > high then return nil end
      domains[item_index][target_index] = {low = low, high = high, step = step, key = key}
    end
  end
  return domains
end

local function tighten_domain(domain, low, high)
  local next_low = math.max(domain.low, round_up(low, domain.step))
  local next_high = math.min(domain.high, round_down(high, domain.step))
  if next_low > next_high then return false, false end
  local changed = next_low ~= domain.low or next_high ~= domain.high
  domain.low, domain.high = next_low, next_high
  return true, changed
end

local function propagate(domains, items, targets)
  local changed = true
  while changed do
    changed = false
    for item_index, item in ipairs(items) do
      local item_domains = domains[item_index]
      local low_sum, high_sum = 0, 0
      for _, domain in ipairs(item_domains) do
        low_sum = low_sum + domain.low
        high_sum = high_sum + domain.high
      end
      if item.count < low_sum or item.count > high_sum then return false end
      for _, domain in ipairs(item_domains) do
        local ok, tightened = tighten_domain(
          domain,
          item.count - (high_sum - domain.high),
          item.count - (low_sum - domain.low)
        )
        if not ok then return false end
        changed = changed or tightened
      end
    end

    for target_index, target in ipairs(targets) do
      local joint = target.joint_capacity
      if joint then
        local minimum_usage = {}
        local used = 0
        for item_index, item_domains in ipairs(domains) do
          local domain = item_domains[target_index]
          local usage = slot_usage(target, domain.key, domain.low)
          if usage == math.huge then return false end
          minimum_usage[item_index] = usage
          used = used + usage
        end
        if used > joint.unfiltered_slots then return false end
        for item_index, item_domains in ipairs(domains) do
          local domain = item_domains[target_index]
          local available = joint.unfiltered_slots - (used - minimum_usage[item_index])
          local covered = (joint.existing_by_key[domain.key] or 0)
            + (joint.dedicated_by_key[domain.key] or 0)
          local stack_size = joint.stack_size_by_key[domain.key]
          if type(stack_size) ~= "number" or stack_size < 1 then return false end
          local ok, tightened = tighten_domain(
            domain,
            domain.low,
            covered + available * stack_size
          )
          if not ok then return false end
          changed = changed or tightened
        end
      end
    end
  end
  return true
end

local function balance_lower_bound(domains)
  local score = 0
  for _, item_domains in ipairs(domains) do
    local largest_low, smallest_high
    for _, domain in ipairs(item_domains) do
      largest_low = largest_low and math.max(largest_low, domain.low) or domain.low
      smallest_high = smallest_high and math.min(smallest_high, domain.high) or domain.high
    end
    score = score + math.max(0, largest_low - smallest_high)
  end
  return score
end

local function completed_counts(domains, items, targets)
  local counts = {}
  local balance_score = 0
  for target_index = 1, #targets do counts[target_index] = {} end
  for item_index, item in ipairs(items) do
    local item_counts = {}
    local total = 0
    for target_index, domain in ipairs(domains[item_index]) do
      if domain.low ~= domain.high then return nil end
      counts[target_index][domain.key] = domain.low
      item_counts[target_index] = domain.low
      total = total + domain.low
    end
    if total ~= item.count then return nil end
    balance_score = balance_score + range_score(item_counts)
  end
  return counts, balance_score
end

local function choose_branch(domains, items, targets)
  local best_item, best_target, best_span
  for item_index, item_domains in ipairs(domains) do
    for target_index, domain in ipairs(item_domains) do
      local span = (domain.high - domain.low) / domain.step
      if span > 0 and (not best_span or span > best_span
        or (span == best_span and (item_index < best_item
          or (item_index == best_item and target_index < best_target)))) then
        best_item, best_target, best_span = item_index, target_index, span
      end
    end
  end
  if not best_item then return nil end
  local domain = domains[best_item][best_target]
  local ideal = items[best_item].count / #targets
  local lower = math.max(domain.low, math.min(domain.high, round_down(ideal, domain.step)))
  local upper = math.max(domain.low, math.min(domain.high, round_up(ideal, domain.step)))
  local value = math.abs(upper - ideal) < math.abs(lower - ideal) and upper or lower
  return best_item, best_target, value
end

local function greatest_common_divisor(left, right)
  left, right = math.abs(left), math.abs(right)
  while right ~= 0 do left, right = right, left % right end
  return left
end

local function extended_gcd(left, right)
  if right == 0 then return left, 1, 0 end
  local divisor, x, y = extended_gcd(right, left % right)
  return divisor, y, x - math.floor(left / right) * y
end

local function add_domain_value(values, seen, domain, value)
  if type(value) ~= "number" then return end
  local below = math.max(domain.low, math.min(domain.high, round_down(value, domain.step)))
  local above = math.max(domain.low, math.min(domain.high, round_up(value, domain.step)))
  for _, candidate in ipairs({below, above}) do
    if candidate >= domain.low and candidate <= domain.high and not seen[candidate] then
      seen[candidate] = true
      values[#values + 1] = candidate
    end
  end
end

local function add_congruent_values(values, seen, domain, residue, modulus, desired_values)
  if modulus <= 1 then
    for _, desired in ipairs(desired_values) do add_domain_value(values, seen, domain, desired) end
    return
  end
  local divisor = greatest_common_divisor(domain.step, modulus)
  local difference = residue - domain.low
  if difference % divisor ~= 0 then return end
  local reduced_step = domain.step / divisor
  local reduced_modulus = modulus / divisor
  local first
  local period
  if reduced_modulus == 1 then
    first = domain.low
    period = domain.step
  else
    local _, inverse = extended_gcd(reduced_step, reduced_modulus)
    local multiplier = ((difference / divisor) * inverse) % reduced_modulus
    first = domain.low + domain.step * multiplier
    period = domain.step * reduced_modulus
  end
  if first < domain.low then first = first + math.ceil((domain.low - first) / period) * period end
  if first > domain.high then return end
  local last = first + math.floor((domain.high - first) / period) * period
  for _, desired in ipairs(desired_values) do
    local lower = first + math.floor((desired - first) / period) * period
    for _, candidate in ipairs({lower, lower + period}) do
      if candidate >= first and candidate <= last and not seen[candidate] then
        seen[candidate] = true
        values[#values + 1] = candidate
      end
    end
  end
  for _, candidate in ipairs({first, last}) do
    if not seen[candidate] then
      seen[candidate] = true
      values[#values + 1] = candidate
    end
  end
end

local function value_precedes(left, right, ideal)
  local left_distance = math.abs(left - ideal)
  local right_distance = math.abs(right - ideal)
  if left_distance ~= right_distance then return left_distance < right_distance end
  return left < right
end

local function slot_breakpoint_value(domain, covered, stack_size, offset, ceiling, slots)
  local raw = covered + slots * stack_size + offset
  local value = ceiling and round_up(raw, domain.step) or round_down(raw, domain.step)
  return math.max(domain.low, math.min(domain.high, value))
end

local function last_slot_at_or_below(
  domain,
  covered,
  stack_size,
  offset,
  ceiling,
  first_slot,
  last_slot,
  ideal
)
  local low, high = first_slot, last_slot
  local result = first_slot - 1
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local value = slot_breakpoint_value(domain, covered, stack_size, offset, ceiling, middle)
    if value <= ideal then
      result = middle
      low = middle + 1
    else
      high = middle - 1
    end
  end
  return result
end

local function advance_slot_cursor(cursor)
  local low, high
  local next_slot
  if cursor.direction < 0 then
    low, high = cursor.first_slot, cursor.slot - 1
    while low <= high do
      local middle = math.floor((low + high) / 2)
      local value = slot_breakpoint_value(
        cursor.domain,
        cursor.covered,
        cursor.stack_size,
        cursor.offset,
        cursor.ceiling,
        middle
      )
      if value < cursor.value then
        next_slot = middle
        low = middle + 1
      else
        high = middle - 1
      end
    end
  else
    low, high = cursor.slot + 1, cursor.last_slot
    while low <= high do
      local middle = math.floor((low + high) / 2)
      local value = slot_breakpoint_value(
        cursor.domain,
        cursor.covered,
        cursor.stack_size,
        cursor.offset,
        cursor.ceiling,
        middle
      )
      if value > cursor.value then
        next_slot = middle
        high = middle - 1
      else
        low = middle + 1
      end
    end
  end
  if not next_slot then return false end
  cursor.slot = next_slot
  cursor.value = slot_breakpoint_value(
    cursor.domain,
    cursor.covered,
    cursor.stack_size,
    cursor.offset,
    cursor.ceiling,
    next_slot
  )
  return true
end

local function add_slot_breakpoint_values(
  values,
  seen,
  domain,
  ideal,
  covered,
  stack_size,
  first_slot,
  last_slot,
  limit
)
  if limit <= 0 or first_slot > last_slot then return end
  local cursors = {}
  local function add_cursor(offset, ceiling, slot, direction)
    cursors[#cursors + 1] = {
      domain = domain,
      covered = covered,
      stack_size = stack_size,
      offset = offset,
      ceiling = ceiling,
      first_slot = first_slot,
      last_slot = last_slot,
      slot = slot,
      direction = direction,
      value = slot_breakpoint_value(domain, covered, stack_size, offset, ceiling, slot),
    }
  end
  for offset = 0, 1 do
    for _, ceiling in ipairs({false, true}) do
      local last_below = last_slot_at_or_below(
        domain,
        covered,
        stack_size,
        offset,
        ceiling,
        first_slot,
        last_slot,
        ideal
      )
      if last_below >= first_slot then add_cursor(offset, ceiling, last_below, -1) end
      if last_below < last_slot then
        add_cursor(offset, ceiling, math.max(first_slot, last_below + 1), 1)
      end
    end
  end

  local slot_seen = {}
  local distinct = 0
  while distinct < limit and #cursors > 0 do
    local best_index = 1
    for index = 2, #cursors do
      if value_precedes(cursors[index].value, cursors[best_index].value, ideal) then
        best_index = index
      end
    end
    local cursor = cursors[best_index]
    local value = cursor.value
    if not slot_seen[value] then
      slot_seen[value] = true
      distinct = distinct + 1
      if not seen[value] then
        seen[value] = true
        values[#values + 1] = value
      end
    end
    if not advance_slot_cursor(cursor) then table.remove(cursors, best_index) end
  end
end

local function branch_values(domains, items, targets, item_index, target_index, max_values)
  local domain = domains[item_index][target_index]
  local item_domains = domains[item_index]
  local values, seen = {}, {}
  local cardinality = math.floor((domain.high - domain.low) / domain.step) + 1
  if cardinality <= 12 then
    for value = domain.low, domain.high, domain.step do
      seen[value] = true
      values[#values + 1] = value
    end
  else
    local ideal = items[item_index].count / #targets
    add_domain_value(values, seen, domain, domain.low)
    add_domain_value(values, seen, domain, domain.high)
    add_domain_value(values, seen, domain, ideal)
    for other_target_index, other in ipairs(item_domains) do
      if other_target_index ~= target_index then
        add_domain_value(values, seen, domain, other.low)
        add_domain_value(values, seen, domain, other.high)
      end
    end

    local other_low_sum = 0
    local other_step_gcd = 0
    for other_target_index, other in ipairs(item_domains) do
      if other_target_index ~= target_index then
        other_low_sum = other_low_sum + other.low
        other_step_gcd = greatest_common_divisor(other_step_gcd, other.step)
      end
    end
    if other_step_gcd > 0 then
      add_congruent_values(
        values,
        seen,
        domain,
        items[item_index].count - other_low_sum,
        other_step_gcd,
        {ideal, domain.low, domain.high}
      )
    end

    local target = targets[target_index]
    local joint = target.joint_capacity
    if joint then
      local covered = (joint.existing_by_key[domain.key] or 0)
        + (joint.dedicated_by_key[domain.key] or 0)
      local stack_size = joint.stack_size_by_key[domain.key]
      if type(stack_size) == "number" and stack_size >= 1 then
        local first_slot = math.max(0, math.ceil((domain.low - 1 - covered) / stack_size))
        local last_slot = math.min(
          joint.unfiltered_slots,
          math.floor((domain.high - covered) / stack_size)
        )
        add_slot_breakpoint_values(
          values,
          seen,
          domain,
          ideal,
          covered,
          stack_size,
          first_slot,
          last_slot,
          math.min(cardinality, max_values or cardinality)
        )
      end
    end
  end
  local ideal = items[item_index].count / #targets
  table.sort(values, function(left, right) return value_precedes(left, right, ideal) end)
  if max_values and #values > max_values then
    for index = #values, max_values + 1, -1 do values[index] = nil end
  end
  return values, #values == cardinality, cardinality
end

local function choose_breakpoint_branch(domains, items, targets, max_values)
  local best_item, best_target, best_cardinality
  for item_index, item_domains in ipairs(domains) do
    for target_index, domain in ipairs(item_domains) do
      local cardinality = math.floor((domain.high - domain.low) / domain.step) + 1
      if cardinality > 1 and (not best_cardinality or cardinality < best_cardinality
        or (cardinality == best_cardinality and (item_index < best_item
          or (item_index == best_item and target_index < best_target)))) then
        best_item, best_target, best_cardinality = item_index, target_index, cardinality
      end
    end
  end
  if not best_item then return nil end
  local values, exhaustive = branch_values(domains, items, targets, best_item, best_target, max_values)
  return best_item, best_target, values, exhaustive
end

local function candidate_from_domains(domains, items, targets, tail_index)
  local counts, balance_score = completed_counts(domains, items, targets)
  if not counts then return nil end
  local allocations = allocation_from_counts(items, counts)
  if not allocations_fit(allocations, targets) then return nil end
  return add_tail_metadata({
    allocations = allocations,
    tail_target_index = tail_index,
    balance_score = balance_score,
  }, items, targets, Constants.TAIL_MODE.SINGLE)
end

local function simple_single_item_candidate(item, targets, tail_index)
  for _, target in ipairs(targets) do
    if target.joint_capacity then return nil end
  end
  local key = Util.item_key(item.name, item.quality or "normal")
  local ideal = item.count / #targets
  local counts = {}
  local assigned = 0
  for target_index, target in ipairs(targets) do
    if not transfer_size(target, key) then return nil end
    if target_index ~= tail_index then
      local step = transfer_size(target, key)
      local low = round_up(math.max(0, limit(target, "min_by_key", key, 0)), step)
      local high = round_down(math.min(
        item.count,
        limit(target, "max_by_key", key, Constants.MAX_REQUEST_VALUE)
      ), step)
      if low > high then return nil end
      local below = math.max(low, math.min(high, round_down(ideal, step)))
      local above = math.max(low, math.min(high, round_up(ideal, step)))
      local count = math.abs(above - ideal) < math.abs(below - ideal) and above or below
      counts[target_index] = count
      assigned = assigned + count
    end
  end
  local tail = targets[tail_index]
  local tail_low = math.max(0, limit(tail, "min_by_key", key, 0))
  local tail_high = math.min(
    item.count,
    limit(tail, "max_by_key", key, Constants.MAX_REQUEST_VALUE)
  )
  local assigned_low = item.count - tail_high
  local assigned_high = item.count - tail_low
  if assigned > assigned_high then
    for target_index, target in ipairs(targets) do
      if target_index ~= tail_index and assigned > assigned_high then
        local step = transfer_size(target, key)
        local low = round_up(math.max(0, limit(target, "min_by_key", key, 0)), step)
        local maximum_steps = math.floor((counts[target_index] - low) / step)
        local needed_steps = math.ceil((assigned - assigned_high) / step)
        local safe_steps = math.floor((assigned - assigned_low) / step)
        local steps = math.min(maximum_steps, needed_steps, safe_steps)
        counts[target_index] = counts[target_index] - steps * step
        assigned = assigned - steps * step
      end
    end
  elseif assigned < assigned_low then
    for target_index, target in ipairs(targets) do
      if target_index ~= tail_index and assigned < assigned_low then
        local step = transfer_size(target, key)
        local high = round_down(math.min(
          item.count,
          limit(target, "max_by_key", key, Constants.MAX_REQUEST_VALUE)
        ), step)
        local maximum_steps = math.floor((high - counts[target_index]) / step)
        local needed_steps = math.ceil((assigned_low - assigned) / step)
        local safe_steps = math.floor((assigned_high - assigned) / step)
        local steps = math.min(maximum_steps, needed_steps, safe_steps)
        counts[target_index] = counts[target_index] + steps * step
        assigned = assigned + steps * step
      end
    end
  end
  if assigned < assigned_low or assigned > assigned_high then return nil end
  counts[tail_index] = item.count - assigned
  local by_target = {}
  for target_index, count in ipairs(counts) do by_target[target_index] = {[key] = count} end
  local allocations = allocation_from_counts({item}, by_target)
  if not allocations_fit(allocations, targets) then return nil end
  return add_tail_metadata({
    allocations = allocations,
    tail_target_index = tail_index,
    balance_score = range_score(counts),
  }, {item}, targets, Constants.TAIL_MODE.SINGLE)
end

local function quick_single_candidate(items, targets, tail_index)
  local domains = initial_domains(items, targets, tail_index)
  if not domains or not propagate(domains, items, targets) then return nil end
  while true do
    local item_index, target_index, value = choose_branch(domains, items, targets)
    if not item_index then return candidate_from_domains(domains, items, targets, tail_index) end
    domains[item_index][target_index].low = value
    domains[item_index][target_index].high = value
    if not propagate(domains, items, targets) then return nil end
  end
end

local function single_candidate(items, targets, tail_index, search_context)
  local domains = initial_domains(items, targets, tail_index)
  if not domains then return nil, true end
  local best
  local exhausted = false
  local incomplete = false

  local function search(current)
    if exhausted then return end
    if search_context.remaining <= 0 then exhausted = true return end
    search_context.remaining = search_context.remaining - 1
    search_context.states = search_context.states + 1
    if not propagate(current, items, targets) then return end
    if best and balance_lower_bound(current) >= best.balance_score then return end
    local item_index, target_index, values, exhaustive = choose_breakpoint_branch(
      current,
      items,
      targets,
      search_context.remaining
    )
    if not item_index then
      best = candidate_from_domains(current, items, targets, tail_index)
      return
    end
    if not exhaustive then incomplete = true end
    for _, value in ipairs(values) do
      local child = clone_domains(current)
      child[item_index][target_index].low = value
      child[item_index][target_index].high = value
      search(child)
      if exhausted then return end
    end
  end

  search(domains)
  return best, not exhausted and not incomplete
end

function TailPlanner.plan(items, targets, mode)
  if type(items) ~= "table" or #items == 0 or type(targets) ~= "table" or #targets == 0 then
    return nil, "empty-plan"
  end
  if mode == Constants.TAIL_MODE.NO_TAIL or mode == Constants.TAIL_MODE.PARALLEL then
    local plan = balanced_plan(items, targets, mode)
    if plan then return plan end
    return nil, "balanced-plan-infeasible"
  end
  if mode ~= Constants.TAIL_MODE.SINGLE then return nil, "unknown-tail-mode" end
  local best
  if #items == 1 then
    for tail_index = 1, #targets do
      local candidate = simple_single_item_candidate(items[1], targets, tail_index)
      if candidate and (not best or candidate.balance_score < best.balance_score
        or (candidate.balance_score == best.balance_score
          and candidate.tail_target_index < best.tail_target_index)) then
        best = candidate
      end
    end
    if best then return best end
  end
  for tail_index = 1, #targets do
    local candidate = quick_single_candidate(items, targets, tail_index)
    if candidate and (not best or candidate.balance_score < best.balance_score
      or (candidate.balance_score == best.balance_score
        and candidate.tail_target_index < best.tail_target_index)) then
      best = candidate
    end
  end
  if best then return best end
  local planning_limited = false
  local search_context = {remaining = SINGLE_SEARCH_STATE_LIMIT, states = 0}
  for tail_index = 1, #targets do
    local candidate, complete = single_candidate(items, targets, tail_index, search_context)
    if not complete then planning_limited = true end
    if candidate and (not best or candidate.balance_score < best.balance_score
      or (candidate.balance_score == best.balance_score
        and candidate.tail_target_index < best.tail_target_index)) then
      best = candidate
    end
    if search_context.remaining <= 0 then
      if tail_index < #targets then planning_limited = true end
      break
    end
  end
  if best then
    best.planning_limited = planning_limited
    best.planning_states = search_context.states
    return best
  end
  if planning_limited then return nil, "planning-limit", search_context.states end
  return nil, "single-plan-infeasible"
end

return TailPlanner
