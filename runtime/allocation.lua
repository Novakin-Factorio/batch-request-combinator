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

return Allocation
