local Constants = require("runtime.constants")
local Registry = require("runtime.registry")

local Debug = {}
local last_profiler = nil

function Debug.set_last_profiler(profiler)
  last_profiler = profiler
end

local function stats()
  local root = Registry.root()
  local counts = {
    registered = 0,
    active = 0,
    requesting = 0,
    settling = 0,
    ready = 0,
    error = 0,
  }
  for _, instance in pairs(root.instances) do
    counts.registered = counts.registered + 1
    if instance.state == Constants.STATE.DRAINING
      or instance.state == Constants.STATE.REQUESTING
      or instance.state == Constants.STATE.SETTLING
      or instance.state == Constants.STATE.READY
      or instance.state == Constants.STATE.COMPLETE then
      counts.active = counts.active + 1
    end
    if counts[instance.state] ~= nil then counts[instance.state] = counts[instance.state] + 1 end
  end
  counts.average_processed = root.debug.bucket_ticks > 0
    and (root.debug.processed / root.debug.bucket_ticks) or 0
  counts.maximum_processed = root.debug.maximum
  counts.last_profiler = last_profiler or "disabled"
  counts.poll_interval = root.poll_interval
  counts.cleanup_pending = #root.cleanup_order + #root.drain_order
  return counts
end

function Debug.snapshot()
  return stats()
end

function Debug.message(values)
  return {
    "batch-request-combinator.message-stats",
    values.registered,
    values.active,
    values.requesting,
    values.settling,
    values.ready,
    values.error,
    string.format("%.2f", values.average_processed),
    values.maximum_processed,
    values.poll_interval,
    values.last_profiler,
    values.cleanup_pending,
  }
end

function Debug.print(player_index)
  local message = Debug.message(stats())
  local player = player_index and game.get_player(player_index) or nil
  if player then player.print(message) else game.print(message) end
end

function Debug.command(command)
  local player_index = command and command.player_index or nil
  Debug.print(player_index)
end

return Debug
