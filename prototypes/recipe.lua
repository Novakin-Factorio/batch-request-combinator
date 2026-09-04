data:extend({
  {
    type = "recipe",
    name = "batch-request-combinator",
    enabled = false,
    energy_required = 2,
    ingredients = {
      {type = "item", name = "decider-combinator", amount = 1},
      {type = "item", name = "advanced-circuit", amount = 5},
      {type = "item", name = "processing-unit", amount = 2},
    },
    results = {
      {type = "item", name = "batch-request-combinator", amount = 1},
    },
  },
  {
    type = "recipe",
    name = "batch-combinator-requester",
    enabled = false,
    energy_required = 2,
    ingredients = {
      {type = "item", name = "requester-chest", amount = 1},
      {type = "item", name = "advanced-circuit", amount = 5},
      {type = "item", name = "processing-unit", amount = 2},
    },
    results = {
      {type = "item", name = "batch-combinator-requester", amount = 1},
    },
  },
})
