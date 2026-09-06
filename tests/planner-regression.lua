package.path = "./?.lua;./?/init.lua;" .. package.path

local Constants = require("runtime.constants")
local Util = require("runtime.util")
local TailPlanner = require("runtime.tail_planner")

local function equal(actual, expected, label)
  assert(actual == expected, label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local iron = Util.item_key("iron-plate", "normal")
local copper = Util.item_key("copper-plate", "normal")
local uncommon_iron = Util.item_key("iron-plate", "uncommon")

-- Match Requests.planning_targets: minima are existing contents, while dedicated
-- capacity holds partial stacks or exact-quality filters outside shared slots.
local function target(keys, slots, transfer, existing, dedicated, maximum)
  local result = {
    min_by_key = {}, max_by_key = {}, transfer_by_key = {},
    joint_capacity = {
      existing_by_key = {}, dedicated_by_key = {}, stack_size_by_key = {},
      unfiltered_slots = slots,
    },
  }
  for _, key in ipairs(keys) do
    local current = existing and existing[key] or 0
    local reserved = dedicated and dedicated[key] or 0
    result.min_by_key[key] = current
    result.max_by_key[key] = maximum and maximum[key] or current + reserved + slots * 100
    result.transfer_by_key[key] = type(transfer) == "table" and transfer[key] or transfer
    result.joint_capacity.existing_by_key[key] = current
    result.joint_capacity.dedicated_by_key[key] = reserved
    result.joint_capacity.stack_size_by_key[key] = 100
  end
  return result
end

local function allocation_signature(plan, items)
  local result = {}
  for _, allocation in ipairs(plan.allocations) do
    local counts = {}
    for _, item in ipairs(items) do
      counts[#counts + 1] = tostring(allocation.by_key[Util.item_key(item.name, item.quality)] or 0)
    end
    result[#result + 1] = table.concat(counts, ",")
  end
  return table.concat(result, ";")
end

local function check_plan(label, items, targets, mode, expected, tail_index, tail_count)
  local plan, failure = TailPlanner.plan(items, targets, mode)
  assert(plan, label .. ": " .. tostring(failure))
  equal(allocation_signature(plan, items), expected, label .. " deterministic allocation")
  equal(plan.tail_target_index, tail_index, label .. " tail target")
  equal(plan.planned_tail_count, tail_count, label .. " planned tails")
  for _, item in ipairs(items) do
    local key = Util.item_key(item.name, item.quality)
    local total = 0
    for index, allocation in ipairs(plan.allocations) do
      local count = allocation.by_key[key] or 0
      assert(count >= targets[index].min_by_key[key], label .. " preserves existing contents")
      assert(count <= targets[index].max_by_key[key], label .. " respects individual capacity")
      if mode == Constants.TAIL_MODE.SINGLE and index ~= plan.tail_target_index then
        equal(count % targets[index].transfer_by_key[key], 0, label .. " full non-tail transfers")
      end
      total = total + count
    end
    equal(total, item.count, label .. " conserves " .. key)
  end
  for index, allocation in ipairs(plan.allocations) do
    local joint, slots = targets[index].joint_capacity, 0
    for key, count in pairs(allocation.by_key) do
      local uncovered = math.max(0, count - joint.existing_by_key[key] - joint.dedicated_by_key[key])
      slots = slots + math.ceil(uncovered / joint.stack_size_by_key[key])
    end
    assert(slots <= joint.unfiltered_slots, label .. " respects shared capacity")
  end
  return plan
end

local simple_items = {{name = "iron-plate", quality = "normal", count = 10}}
local simple_targets = {target({iron}, 1, 4), target({iron}, 1, 4)}
for _, mode in ipairs(Constants.TAIL_MODE_ORDER) do
  local single = mode == Constants.TAIL_MODE.SINGLE
  check_plan("basic " .. mode, simple_items, simple_targets, mode,
    single and "6;4" or "5;5", single and 1 or nil,
    mode == Constants.TAIL_MODE.NO_TAIL and 0 or single and 1 or 2)
end

local shared_items = {
  {name = "iron-plate", quality = "normal", count = 201},
  {name = "copper-plate", quality = "normal", count = 201},
}
local shared_targets = {target({iron, copper}, 3, 2), target({iron, copper}, 3, 2)}
for _, mode in ipairs(Constants.TAIL_MODE_ORDER) do
  local single = mode == Constants.TAIL_MODE.SINGLE
  check_plan("shared slots " .. mode, shared_items, shared_targets, mode,
    single and "101,99;100,102" or "100,101;101,100", single and 1 or nil,
    mode == Constants.TAIL_MODE.NO_TAIL and 0 or single and 1 or 2)
end

local quality_items = {
  {name = "iron-plate", quality = "normal", count = 14},
  {name = "iron-plate", quality = "uncommon", count = 10},
}
local quality_targets = {
  target({iron, uncommon_iron}, 0, 2, {[iron] = 8, [uncommon_iron] = 1},
    {[iron] = 92, [uncommon_iron] = 99}),
  target({iron, uncommon_iron}, 1, 2, {[uncommon_iron] = 2}, {[uncommon_iron] = 98}),
}
check_plan("quality and minima single", quality_items, quality_targets, Constants.TAIL_MODE.SINGLE,
  "8,6;6,4", 1, 0)

for _, mode in ipairs({Constants.TAIL_MODE.NO_TAIL, Constants.TAIL_MODE.PARALLEL}) do
  local plan, failure = TailPlanner.plan(quality_items, quality_targets, mode)
  equal(plan, nil, "existing contents block balanced " .. mode)
  equal(failure, "balanced-plan-infeasible", "minimum failure " .. mode)
end
quality_items[1].count = 20
for _, mode in ipairs(Constants.TAIL_MODE_ORDER) do
  local single = mode == Constants.TAIL_MODE.SINGLE
  check_plan("quality and dedicated slots " .. mode, quality_items, quality_targets, mode,
    single and "10,6;10,4" or "10,5;10,5", single and 1 or nil,
    mode == Constants.TAIL_MODE.PARALLEL and 2 or 0)
end

local offset_items = {{name = "iron-plate", quality = "normal", count = 99}}
local offset_targets = {
  target({iron}, 0, 2, {[iron] = 1}),
  target({iron}, 1, 6),
  target({iron}, 1, 10),
}
check_plan("fixed offset and mixed transfer divisors", offset_items, offset_targets,
  Constants.TAIL_MODE.SINGLE, "1;48;50", 1, 1)

check_plan("all domains fixed", {{name = "iron-plate", quality = "normal", count = 7}},
  {target({iron}, 0, 4, {[iron] = 7})}, Constants.TAIL_MODE.SINGLE, "7", 1, 1)

local impossible_targets = {
  target({iron}, 0, 2, {[iron] = 1}), target({iron}, 5000, 2), target({iron}, 5000, 2),
}
local impossible_items = {{name = "iron-plate", quality = "normal", count = 500000}}

local large_items = {{name = "iron-plate", quality = "normal", count = 499999}}
local large_targets = {
  target({iron}, 0, 2, nil, nil, {[iron] = 500000}),
  target({iron}, 5000, 2), target({iron}, 5000, 2),
}
-- Bound VM work instead of wall time. The original parity-infeasible first tail
-- needed about 500,000 propagation passes before trying a feasible tail.
local instructions = 0
debug.sethook(function()
  instructions = instructions + 1000
  assert(instructions <= 3000000, "single propagation scales with requested quantity")
end, "", 1000)
local ok, large_plan = pcall(check_plan, "barred chest with large odd total", large_items,
  large_targets, Constants.TAIL_MODE.SINGLE, "0;320697;179302", 2, 1)
debug.sethook()
assert(ok, large_plan)
equal(large_plan.planning_states, 512, "existing search-state limit")
equal(large_plan.planning_limited, true, "existing search-limit diagnostic")

instructions = 0
debug.sethook(function()
  instructions = instructions + 1000
  assert(instructions <= 100000, "infeasible fixed-offset sum scales with requested quantity")
end, "", 1000)
local impossible_ok, impossible_plan, impossible_reason = pcall(
  TailPlanner.plan, impossible_items, impossible_targets, Constants.TAIL_MODE.SINGLE
)
debug.sethook()
assert(impossible_ok, impossible_plan)
equal(impossible_plan, nil, "fixed-offset arithmetic infeasibility")
equal(impossible_reason, "single-plan-infeasible", "proven infeasibility keeps its reason")

print("Planner joint-capacity regressions passed.")
