package.path = "./?.lua;./?/init.lua;" .. package.path

local function equal(actual, expected, label)
  assert(actual == expected, label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local Constants = require("runtime.constants")
local root
package.loaded["runtime.registry"] = {root = function() return root end}
package.loaded["runtime.inserter_controller"] = {}
package.loaded["runtime.requests"] = {}
package.loaded["runtime.target_discovery"] = {}
local Drain = require("runtime.drain")
game = {tick = 0}
local registrations
script = {register_on_object_destroyed = function(entity)
  assert(entity and entity.valid, "only live targets receive destruction registrations")
  registrations = registrations + 1
  return registrations
end}

local function reset()
  root = {chest_owners = {}, destroyed = {}, drain_tombstones = {}, drain_order = {}, drain_cursor = 1}
  registrations = 0
  game = {tick = 0}
end

local function target(unit_number, original)
  local state = {trash = true, writes = 0, reads = 0, fail_write = false, fail_read = false}
  local point = setmetatable({valid = true}, {
    __index = function(_, key)
      if key == "trash_not_requested" then return state.trash end
    end,
    __newindex = function(_, key, value)
      assert(key == "trash_not_requested", "only native trash setting changes")
      assert(root.chest_owners[unit_number], "native restoration retains ownership until verified")
      state.writes = state.writes + 1
      if state.fail_write then error("native trash write failed") end
      state.trash = value
    end,
  })
  local entity = {valid = true, unit_number = unit_number, localised_name = "chest-" .. unit_number}
  entity.get_requester_point = function()
    state.reads = state.reads + 1
    if state.fail_read then error("native requester lookup failed") end
    return point
  end
  return {entity = entity, unit_number = unit_number, original_trash_not_requested = original}, state
end

local function instance(owner, targets)
  return {unit_number = owner, drain_targets = targets, monitored_inserters = {}}
end

local function detached(owner, unit_number)
  local saved, native = target(unit_number, false)
  root.chest_owners[unit_number] = owner
  Drain.detach_failed_cleanup(instance(owner, {saved}))
  return root.drain_tombstones[tostring(owner) .. ":" .. tostring(unit_number)], native
end

-- Removed prototypes and absent references need no native restoration. Surviving snapshots do.
reset()
local first, first_native = target(10, false)
local second, second_native = target(20, true)
local gone = {unit_number = 30, entity = setmetatable({valid = false}, {
  __index = function() error("invalid LuaEntity properties must not be read") end,
})}
local missing = {unit_number = 40}
local saved = instance(1, {first, gone, second, missing})
saved.drain_restore_blocked = true
assert(Drain.reconcile(saved), "gone target must not reject surviving drain lease")
equal(saved.drain_restore_blocked, false, "fresh validation clears obsolete lease block")
equal(registrations, 2, "register only surviving targets")
assert(Drain.stop(saved), "surviving native settings restore after reconciliation")
equal(first_native.trash, false, "original false snapshot restored")
equal(second_native.trash, true, "original true snapshot preserved")
equal(first_native.writes, 1, "false snapshot restored once")
equal(second_native.writes, 0, "already restored snapshot needs no write")
equal(next(root.chest_owners), nil, "restored lease releases all claims")
equal(#saved.drain_targets, 0, "restored lease clears snapshots")

-- A failed native write retains every live claim and original snapshot until cleanup is verified.
reset()
local failed, failed_native = target(10, false)
local restored, restored_native = target(20, false)
saved = instance(1, {failed, {unit_number = 30}, restored})
assert(Drain.reconcile(saved))
failed_native.fail_write = true
local stopped, failure = Drain.stop(saved)
equal(stopped, false, "write failure prevents successful stop")
equal(failure, Constants.ERROR.DRAIN_RESTORE_FAILED, "write failure has drain restore error")
equal(root.chest_owners[10], 1, "failed native restoration keeps claim")
equal(root.chest_owners[20], 1, "partial restoration keeps live lease claims")
equal(failed.original_trash_not_requested, false, "failed restoration keeps original false snapshot")
equal(restored_native.trash, false, "independent survivor restores despite write failure")
Drain.detach_failed_cleanup(saved)
equal(root.chest_owners[10], 1, "detached failed native restoration keeps claim")
equal(root.chest_owners[20], nil, "detached verified restoration releases claim")
equal(root.drain_tombstones["1:10"].original_trash_not_requested, false,
  "detachment retains unresolved original snapshot")
equal(Drain.retry_one_tombstone(0), false, "blocked native restoration remains queued")
equal(root.drain_tombstones["1:10"].retry_after_tick, 60, "failed tombstone stores deadline")
failed_native.fail_write = false
equal(Drain.retry_one_tombstone(59), false, "deadline prevents early retry")
equal(Drain.retry_one_tombstone(60), true, "restoration retries at deadline")
equal(failed_native.trash, false, "eventual restoration uses original false snapshot")
equal(root.chest_owners[10], nil, "verified tombstone restoration releases claim")

-- Conflicting snapshots never authorize native writes. Independent survivors retain restoration evidence.
reset()
local conflicting, conflict_native = target(10, false)
local duplicate = {unit_number = 10, entity = conflicting.entity, original_trash_not_requested = true}
local survivor, survivor_native = target(20, false)
saved = instance(1, {conflicting, duplicate, survivor})
equal(Drain.reconcile(saved), false, "duplicate target snapshots reject reconciliation")
Drain.quarantine_failed_reconciliation(saved)
equal(Drain.stop(saved), false, "ambiguous lease must not write native settings")
Drain.detach_failed_cleanup(saved)
equal(conflict_native.writes, 0, "ambiguous snapshots receive no native writes")
equal(root.drain_tombstones["1:10"], nil, "ambiguous snapshots cannot become write authority")
equal(root.chest_owners[20], 1, "independent survivor keeps restoration claim")
equal(root.drain_tombstones["1:20"].original_trash_not_requested, false,
  "blocked detach preserves independent survivor snapshot")
assert(Drain.retry_one_tombstone(0), "independent survivor restores through deferred cleanup")
equal(survivor_native.trash, false, "independent survivor native setting restored")
equal(conflict_native.writes, 0, "deferred cleanup does not write ambiguous target")

-- Ownership conflicts remain blocked even when lifecycle releases the other owner's claim before quarantine.
reset()
local contested, contested_native = target(10, false)
local invalid_snapshot, invalid_native = target(30, nil)
survivor, survivor_native = target(20, false)
saved = instance(1, {invalid_snapshot, contested, survivor})
root.chest_owners[10] = 2
equal(Drain.reconcile(saved), false, "foreign ownership rejects reconciliation")
root.chest_owners[10] = nil
equal(Drain.reconcile(saved), false, "later reconciliation cannot validate a previously conflicting snapshot")
Drain.quarantine_failed_reconciliation(saved)
Drain.detach_failed_cleanup(saved)
equal(root.drain_tombstones["1:10"], nil, "later claim availability does not validate conflicting snapshot")
assert(Drain.retry_one_tombstone(0))
equal(contested_native.writes, 0, "conflicting owner snapshot receives no write")
equal(invalid_native.writes, 0, "unknown original value receives no write")
equal(survivor_native.trash, false, "uncontested survivor still restores")

-- Mismatched entity identity cannot release a claim belonging to the actual entity.
reset()
local mismatched, mismatch_native = target(10, false)
mismatched.unit_number = 11
saved = instance(1, {mismatched})
root.chest_owners[10] = 1
equal(Drain.reconcile(saved), false, "mismatched identity rejects reconciliation")
Drain.quarantine_failed_reconciliation(saved)
Drain.detach_failed_cleanup(saved)
equal(mismatch_native.writes, 0, "mismatched identity receives no native write")
equal(root.chest_owners[10], 1, "cleanup releases saved identity only")

-- One blocked entry cannot pause other entries. Saved deadlines survive claim reconciliation.
reset()
local blocked, blocked_native = detached(1, 10)
local ready, ready_native = detached(2, 20)
blocked_native.fail_write = true
equal(Drain.retry_one_tombstone(0), false, "first tombstone blocks")
equal(blocked.retry_after_tick, 60, "first tombstone has independent deadline")
equal(Drain.retry_one_tombstone(1), true, "next tombstone restores on next tick")
equal(ready_native.trash, false, "ready tombstone restored despite blocked predecessor")
equal(root.drain_tombstones[ready.key], nil, "ready tombstone removed immediately")
local writes = blocked_native.writes
root.chest_owners = {}
Drain.restore_tombstone_claims()
equal(blocked.retry_after_tick, 60, "configuration reconciliation preserves per-record deadline")
equal(Drain.retry_one_tombstone(2), false, "reconciled blocked tombstone waits")
equal(blocked_native.writes, writes, "ineligible tombstone performs no native write")
equal(root.chest_owners[10], 1, "ineligible tombstone keeps claim")
ready, ready_native = detached(2, 20)
equal(Drain.retry_one_tombstone(3), false, "ineligible cursor entry skips")
equal(Drain.retry_one_tombstone(4), true, "cursor advances past ineligible entry")
equal(ready_native.trash, false, "eligible successor restores after skipped entry")
blocked_native.fail_write = false
game.tick = 60
assert(Drain.retry_one_tombstone(), "omitted tick uses current game tick")
equal(#root.drain_order, 0, "all verified restorations leave queue")

-- A native lookup exception keeps evidence, advances the cursor, and observes the same deadline.
reset()
blocked, blocked_native = detached(1, 10)
ready, ready_native = detached(2, 20)
blocked_native.fail_read = true
local checked = pcall(Drain.retry_one_tombstone, 5)
equal(checked, false, "native lookup exception remains visible to scheduler")
equal(blocked.retry_after_tick, 65, "exception persists retry deadline")
equal(root.chest_owners[10], 1, "exception preserves claim")
equal(blocked.original_trash_not_requested, false, "exception preserves snapshot")
assert(Drain.retry_one_tombstone(6), "exception does not pin cursor before ready successor")
equal(ready_native.trash, false, "successor restores after predecessor exception")
equal(Drain.retry_one_tombstone(64), false, "native lookup waits until its deadline")
blocked_native.fail_read = false
assert(Drain.retry_one_tombstone(65), "native lookup retries at deadline")

reset()
blocked, blocked_native = detached(1, 10)
blocked_native.fail_write = true
game = nil
equal(Drain.retry_one_tombstone(), false, "omitted tick without game uses zero")
equal(blocked.retry_after_tick, 60, "fallback tick records normal retry interval")

print("Drain regressions passed")
