data:extend({
  {
    type = "technology",
    name = "batch-request-combinator",
    icon = "__base__/graphics/technology/circuit-network.png",
    icon_size = 256,
    prerequisites = {"circuit-network", "logistic-system"},
    effects = {
      {
        type = "unlock-recipe",
        recipe = "batch-request-combinator",
      },
      {
        type = "unlock-recipe",
        recipe = "batch-combinator-requester",
      },
    },
    unit = {
      count = 150,
      ingredients = {
        {"automation-science-pack", 1},
        {"logistic-science-pack", 1},
        {"chemical-science-pack", 1},
        {"utility-science-pack", 1},
      },
      time = 30,
    },
    order = "a-d-e[batch-request-combinator]",
  },
})
