local Icons = require("prototypes.icons")

local visible = table.deepcopy(data.raw["decider-combinator"]["decider-combinator"])
visible.name = "batch-request-combinator"
visible.icon = nil
visible.icons = Icons.batch_request_combinator()
visible.minable = {mining_time = 0.1, result = "batch-request-combinator"}
visible.fast_replaceable_group = "batch-request-combinator"
visible.next_upgrade = nil
local body_sprite = "__batch-request-combinator__/graphics/entity/batch-request-combinator/batch-request-combinator.png"
local directions = {"north", "east", "south", "west"}
for _, direction in ipairs(directions) do
  assert(visible.sprites[direction] and visible.sprites[direction].layers
      and visible.sprites[direction].layers[1],
    "batch-request-combinator requires the vanilla decider four-way sprite layout")
  visible.sprites[direction].layers[1].filename = body_sprite
end
visible.activity_led_sprites = nil
visible.activity_led_light = nil
visible.screen_light = nil
local comparison_symbol_fields = {
  "greater_symbol_sprites",
  "less_symbol_sprites",
  "equal_symbol_sprites",
  "not_equal_symbol_sprites",
  "less_or_equal_symbol_sprites",
  "greater_or_equal_symbol_sprites",
}
for _, field in ipairs(comparison_symbol_fields) do
  visible[field] = nil
end

assert(
  visible.input_connection_points and visible.output_connection_points,
  "batch-request-combinator requires a decider prototype with separate input and output connectors"
)

local empty_sprite = {
  filename = "__core__/graphics/empty.png",
  size = 1,
}

local output = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
output.name = "batch-request-combinator-output"
output.flags = {
  "placeable-player",
  "placeable-off-grid",
  "not-blueprintable",
  "not-deconstructable",
  "not-upgradable",
  "not-repairable",
  "not-on-map",
  "hide-alt-info",
  "not-flammable",
  "not-in-kill-statistics",
}
output.hidden = true
output.hidden_in_factoriopedia = true
output.selectable_in_game = false
output.allow_copy_paste = false
output.minable = nil
output.placeable_by = nil
output.fast_replaceable_group = nil
output.next_upgrade = nil
output.corpse = nil
output.dying_explosion = nil
output.collision_box = {{0, 0}, {0, 0}}
output.selection_box = {{0, 0}, {0, 0}}
output.collision_mask = {
  layers = {water_tile = true},
  colliding_with_tiles_only = true,
}
output.sprites = empty_sprite
output.activity_led_sprites = empty_sprite
output.activity_led_light = nil
output.draw_circuit_wires = false
output.order = "zz[batch-request-combinator-output]"

local requester = table.deepcopy(data.raw["logistic-container"]["requester-chest"])
requester.name = "batch-combinator-requester"
requester.icon = nil
requester.icons = Icons.batch_combinator_requester()
requester.minable = {mining_time = 0.1, result = "batch-combinator-requester"}
requester.inventory_size = settings.startup["batch-request-combinator-requester-capacity"].value
requester.quality_affects_inventory_size = false
requester.use_exact_mode = true
requester.fast_replaceable_group = "batch-combinator-requester"
requester.next_upgrade = nil
assert(requester.robot_door and requester.robot_door.animation
    and requester.robot_door.animation.layers and requester.robot_door.animation.layers[1],
  "batch-combinator-requester requires the vanilla requester-chest animation layout")
requester.robot_door.animation.layers[1].filename =
  "__batch-request-combinator__/graphics/entity/logistic-chest/requester-chest-exact-electric-blue.png"

data:extend({visible, output, requester})
