local Icons = require("prototypes.icons")

local item = table.deepcopy(data.raw.item["decider-combinator"])
item.name = "batch-request-combinator"
item.icon = nil
item.icons = Icons.batch_request_combinator()
item.place_result = "batch-request-combinator"
item.order = "c[combinators]-e[batch-request-combinator]"

local requester = table.deepcopy(data.raw.item["requester-chest"])
requester.name = "batch-combinator-requester"
requester.icon = nil
requester.icons = Icons.batch_combinator_requester()
requester.place_result = "batch-combinator-requester"
requester.order = "b[storage]-c[logistic-chest-requester]-z[batch-combinator-requester]"

data:extend({item, requester})
