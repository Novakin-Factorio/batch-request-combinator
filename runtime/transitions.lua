local Constants = require("runtime.constants")

local Transitions = {}

function Transitions.action(state, context)
  local follows_input = context.input_mode ~= Constants.INPUT_MODE.SNAPSHOT
  if state == Constants.STATE.ARMED then
    return context.has_input and "begin" or "wait"
  end
  if state == Constants.STATE.REQUESTING then
    if not context.has_input and follows_input then return "abort" end
    if context.failed then return "error" end
    return context.inventory_exact and "settle" or "wait"
  end
  if state == Constants.STATE.SETTLING then
    if not context.has_input and follows_input then return "abort" end
    if context.failed then return "error" end
    return context.deliveries_clear and context.inventory_exact and "ready" or "wait"
  end
  if state == Constants.STATE.READY then
    if not context.has_input and follows_input then return "reset" end
    return context.failed and "error" or "wait"
  end
  if state == Constants.STATE.COMPLETE then
    if context.failed then return "error" end
    if follows_input then return context.has_input and "wait" or "reset" end
    return context.reset_observed and context.hold_expired and "reset" or "wait"
  end
  if state == Constants.STATE.ERROR or state == Constants.STATE.ABORTED then
    return context.has_input and "wait" or "reset"
  end
  return "wait"
end

return Transitions
