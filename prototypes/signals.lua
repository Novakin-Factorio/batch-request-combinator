local subgroup = {
  type = "item-subgroup",
  name = "batch-request-combinator-signals",
  group = "signals",
  order = "z[batch-request-combinator]",
}

local function make_signal(suffix, source_name, order)
  local source = data.raw["virtual-signal"][source_name]
  assert(source, "Missing base virtual signal: " .. source_name)

  local signal = table.deepcopy(source)
  signal.name = "batch-request-combinator-" .. suffix
  signal.subgroup = subgroup.name
  signal.order = order
  return signal
end

data:extend({
  subgroup,
  make_signal("armed", "signal-unlock", "a[armed]"),
  make_signal("requesting", "signal-hourglass", "b[requesting]"),
  make_signal("settling", "signal-clock", "c[settling]"),
  make_signal("ready", "signal-check", "d[ready]"),
  make_signal("complete", "signal-star", "e[complete]"),
  make_signal("warning", "signal-exclamation-mark", "f[warning]"),
  make_signal("error", "signal-alert", "g[error]"),
  make_signal("aborted", "signal-deny", "h[aborted]"),
})
