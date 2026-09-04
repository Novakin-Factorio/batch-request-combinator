local Constants = require("runtime.constants")
local Debug = require("runtime.debug")
local Gui = require("runtime.gui")
local Lifecycle = require("runtime.lifecycle")
local Migrations = require("runtime.migrations")
local Registry = require("runtime.registry")
local Scheduler = require("runtime.scheduler")
local pending_load_drain_restore = false

local function initialize()
  Migrations.run()
  Lifecycle.reconcile()
end

local function on_configuration_changed()
  Migrations.run()
  Lifecycle.reconcile()
end

local function on_runtime_mod_setting_changed(event)
  if event.setting == Constants.SETTING_POLL_INTERVAL then Registry.rebuild_buckets() end
end

local visible_filter = {{filter = "name", name = Constants.ENTITY_NAME}}
local managed_filter = {
  {filter = "name", name = Constants.ENTITY_NAME},
  {filter = "name", name = Constants.OUTPUT_ENTITY_NAME},
}

local function register_filtered_events(event_ids, handler, filters)
  for _, event_id in ipairs(event_ids) do
    script.on_event(event_id, handler, filters)
  end
end

script.on_init(initialize)
script.on_load(function()
  pending_load_drain_restore = true
  Gui.on_load()
end)
script.on_configuration_changed(on_configuration_changed)

register_filtered_events({
  defines.events.on_built_entity,
  defines.events.on_robot_built_entity,
  defines.events.on_space_platform_built_entity,
  defines.events.script_raised_built,
  defines.events.script_raised_revive,
}, Lifecycle.on_built, visible_filter)

register_filtered_events({
  defines.events.on_player_mined_entity,
  defines.events.on_robot_mined_entity,
  defines.events.on_space_platform_mined_entity,
  defines.events.on_entity_died,
  defines.events.script_raised_destroy,
}, Lifecycle.on_removed, visible_filter)

script.on_event(defines.events.on_entity_cloned, Lifecycle.on_cloned, managed_filter)
script.on_event(defines.events.on_object_destroyed, Lifecycle.on_object_destroyed)
script.on_event(defines.events.on_entity_settings_pasted, Lifecycle.on_settings_pasted)
script.on_event(defines.events.on_blueprint_settings_pasted, Lifecycle.on_blueprint_settings_pasted)
script.on_event(defines.events.on_player_setup_blueprint, Lifecycle.on_player_setup_blueprint)
script.on_event(defines.events.on_player_rotated_entity, Lifecycle.on_rotated)
script.on_event(defines.events.script_raised_teleported, Lifecycle.on_teleported, visible_filter)
script.on_event(defines.events.on_entity_logistic_slot_changed, Lifecycle.on_logistic_slot_changed)
script.on_event(defines.events.on_runtime_mod_setting_changed, on_runtime_mod_setting_changed)

script.on_event(defines.events.on_gui_opened, Gui.open)
script.on_event(defines.events.on_gui_closed, Gui.on_closed)
script.on_event(defines.events.on_gui_click, Gui.on_click)
script.on_event(defines.events.on_gui_checked_state_changed, Gui.on_checked_changed)
script.on_event(defines.events.on_player_removed, Gui.on_player_removed)
script.on_event(defines.events.on_player_display_resolution_changed, Gui.on_display_changed)
script.on_event(defines.events.on_player_display_scale_changed, Gui.on_display_changed)
script.on_event(defines.events.on_player_locale_changed, Gui.on_display_changed)

script.on_event(defines.events.on_tick, function(event)
  if pending_load_drain_restore then
    pending_load_drain_restore = false
    Lifecycle.restore_loaded_drains()
    Gui.restore_after_load()
  end
  Scheduler.on_tick(event, Lifecycle.on_invalid, Gui.refresh_instance)
end)

commands.add_command(
  "batch-request-combinator-stats",
  {"batch-request-combinator.command-stats-help"},
  Debug.command
)
