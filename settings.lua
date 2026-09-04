data:extend({
  {
    type = "int-setting",
    name = "batch-request-combinator-requester-capacity",
    setting_type = "startup",
    default_value = 5000,
    minimum_value = 48,
    maximum_value = 5000,
    order = "a[requester-capacity]",
  },
  {
    type = "int-setting",
    name = "batch-request-combinator-poll-interval",
    setting_type = "runtime-global",
    default_value = 12,
    minimum_value = 1,
    maximum_value = 60,
    order = "a[poll-interval]",
  },
  {
    type = "bool-setting",
    name = "batch-request-combinator-debug",
    setting_type = "runtime-global",
    default_value = false,
    order = "b[debug]",
  },
})
