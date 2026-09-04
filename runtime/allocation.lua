local Util = require("runtime.util")

local Allocation = {}

function Allocation.sort_targets(targets)
  table.sort(targets, function(left, right)
    local left_entity = left.entity or left
    local right_entity = right.entity or right
    if left_entity.surface.index ~= right_entity.surface.index then
      return left_entity.surface.index < right_entity.surface.index
    end
    if left_entity.position.x ~= right_entity.position.x then
      return left_entity.position.x < right_entity.position.x
    end
    if left_entity.position.y ~= right_entity.position.y then
      return left_entity.position.y < right_entity.position.y
    end
    return left_entity.unit_number < right_entity.unit_number
  end)
  return targets
end

function Allocation.distribute(items, target_count)
  assert(target_count > 0, "target_count must be positive")
  local allocations = {}
  for index = 1, target_count do
    allocations[index] = {items = {}, by_key = {}, total = 0}
  end

  for _, item in ipairs(items) do
    local quotient = math.floor(item.count / target_count)
    local remainder = item.count % target_count
    for index = 1, target_count do
      local count = quotient + (index <= remainder and 1 or 0)
      if count > 0 then
        local allocated = {
          name = item.name,
          quality = item.quality or "normal",
          count = count,
        }
        local target = allocations[index]
        target.items[#target.items + 1] = allocated
        target.by_key[Util.item_key(allocated.name, allocated.quality)] = count
        target.total = target.total + count
      end
    end
  end

  return allocations
end

return Allocation
