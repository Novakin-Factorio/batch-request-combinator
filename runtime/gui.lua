local Constants = require("runtime.constants")
local Debug = require("runtime.debug")
local Registry = require("runtime.registry")
local Requests = require("runtime.requests")
local StateMachine = require("runtime.state_machine")
local Util = require("runtime.util")

local Gui = {}
local element_cache_by_player = {}
local inspector_by_player = {}
local drain_preview_by_player = {}
local diagnostics_by_player = {}

local GUI_SCHEMA_TAG = "batch-request-combinator-gui-version"
local GUI_SCHEMA_VERSION = 14

local DRAIN_WAIT_CAPTIONS = {
  [Constants.DRAIN_WAIT_REASON.NETWORK] = "condition-drain-waiting-network",
  [Constants.DRAIN_WAIT_REASON.ROBOTS] = "condition-drain-waiting-robots",
  [Constants.DRAIN_WAIT_REASON.AVAILABLE_ROBOTS] = "condition-drain-waiting-available-robots",
  [Constants.DRAIN_WAIT_REASON.DESTINATION] = "condition-drain-waiting-destination",
  [Constants.DRAIN_WAIT_REASON.MOVEMENT] = "condition-drain-waiting-movement",
}
local ERROR_TITLE_CAPTIONS = {
  [Constants.ERROR.NO_TARGETS] = "error-title-no-targets",
  [Constants.ERROR.TARGET_CONFLICT] = "error-title-target-conflict",
  [Constants.ERROR.TARGET_INCOMPATIBLE] = "error-title-target-incompatible",
  [Constants.ERROR.CONTAMINATION] = "error-title-contamination",
  [Constants.ERROR.EXCESS_ITEMS] = "error-title-excess-items",
  [Constants.ERROR.INSUFFICIENT_CAPACITY] = "error-title-insufficient-capacity",
  [Constants.ERROR.INSUFFICIENT_FILTERS] = "error-title-insufficient-filters",
  [Constants.ERROR.REQUEST_WRITE_FAILED] = "error-title-request-write-failed",
  [Constants.ERROR.TARGET_LOST] = "error-title-target-lost",
  [Constants.ERROR.DELIVERY_MISMATCH] = "error-title-delivery-mismatch",
  [Constants.ERROR.INSERTER_NOT_EMPTY] = "error-title-inserter-not-empty",
  [Constants.ERROR.EXTERNAL_REQUEST] = "error-title-external-request",
  [Constants.ERROR.EXTERNAL_DELIVERY] = "error-title-external-delivery",
  [Constants.ERROR.OUTPUT_UNAVAILABLE] = "error-title-output-unavailable",
  [Constants.ERROR.INVALID_QUANTITY] = "error-title-invalid-quantity",
  [Constants.ERROR.SECTION_LOST] = "error-title-section-lost",
  [Constants.ERROR.INTERNAL] = "error-title-internal",
  [Constants.ERROR.INACCESSIBLE_ITEMS] = "error-title-inaccessible-items",
  [Constants.ERROR.TAIL_PLAN_UNSAFE] = "error-title-tail-plan-unsafe",
  [Constants.ERROR.INSERTER_CONFIGURATION] = "error-title-inserter-configuration",
  [Constants.ERROR.INSERTER_OWNERSHIP] = "error-title-inserter-ownership",
  [Constants.ERROR.TAIL_RESTORE_FAILED] = "error-title-tail-restore-failed",
  [Constants.ERROR.DRAIN_WRITE_FAILED] = "error-title-drain-write-failed",
  [Constants.ERROR.DRAIN_RESTORE_FAILED] = "error-title-drain-restore-failed",
  [Constants.ERROR.DRAIN_INPUT_ACTIVE] = "error-title-drain-input-active",
  [Constants.ERROR.DRAIN_SCOPE_CHANGED] = "error-title-drain-scope-changed",
}
local ERROR_TECHNICAL_CAPTIONS = {
  [Constants.ERROR.INSERTER_CONFIGURATION] = "technical-inserter-requirements",
}
local PLAN_SIGNATURE_TAG = "batch-request-combinator-plan-signature"
local SUMMARY_SIGNATURE_TAG = "batch-request-combinator-summary-signature"
local TARGET_WIDTH = 900
local TARGET_BODY_HEIGHT = 720
local DISPLAY_HORIZONTAL_MARGIN = 80
local DISPLAY_VERTICAL_MARGIN = 160
local MINIMUM_WIDTH = 320
local MINIMUM_BODY_HEIGHT = 180
local COMPACT_LAYOUT_MINIMUM_WIDTH = 520
local WIDE_LAYOUT_MINIMUM_WIDTH = 850

local INSPECTOR = {
  CONFIGURATION = "configuration",
  BATCH = "batch",
  MAINTENANCE = "maintenance",
  DIAGNOSTICS = "diagnostics",
  TECHNICAL = "technical",
}

local function sign_mode_caption(mode)
  if mode == Constants.SIGN_MODE.POSITIVE then return {"batch-request-combinator.sign-mode-positive"} end
  if mode == Constants.SIGN_MODE.NEGATIVE then return {"batch-request-combinator.sign-mode-negative-absolute"} end
  return {"batch-request-combinator.sign-mode-any-absolute"}
end

local function input_mode_caption(mode)
  if mode == Constants.INPUT_MODE.SNAPSHOT then return {"batch-request-combinator.input-mode-snapshot"} end
  return {"batch-request-combinator.input-mode-follow"}
end

local function tail_mode_caption(mode)
  if mode == Constants.TAIL_MODE.SINGLE then return {"batch-request-combinator.tail-mode-single"} end
  if mode == Constants.TAIL_MODE.PARALLEL then return {"batch-request-combinator.tail-mode-parallel"} end
  return {"batch-request-combinator.tail-mode-none"}
end

function Gui.layout_presentation(instance, remaining)
  local state = instance.state
  local draining = state == Constants.STATE.DRAINING
  local total = draining and (instance.drain_initial_total or 0) or (instance.captured_total or 0)
  local has_plan_data = #(instance.captured or {}) > 0 or #(instance.targets or {}) > 0
  local retained = total > 0 or has_plan_data
  local active = state == Constants.STATE.REQUESTING
    or state == Constants.STATE.SETTLING
    or state == Constants.STATE.READY
  local progress_count = instance.staged_total or 0
  local progress_caption = {"batch-request-combinator.gui-progress-staged"}
  if draining then
    progress_count = total - (remaining or 0)
    progress_caption = {"batch-request-combinator.gui-progress-drained"}
  elseif state == Constants.STATE.READY then
    progress_count = total - (remaining == nil and total or remaining)
    progress_caption = {"batch-request-combinator.gui-progress-loaded"}
  elseif (state == Constants.STATE.ERROR or state == Constants.STATE.ABORTED)
    and instance.ready_counts then
    progress_count = total - (instance.staged_total or (remaining == nil and total or remaining))
    progress_caption = {"batch-request-combinator.gui-progress-loaded"}
  elseif state == Constants.STATE.COMPLETE then
    progress_count = total
    progress_caption = {"batch-request-combinator.gui-progress-loaded"}
  end
  progress_count = math.max(0, math.min(total, progress_count))
  return {
    edit = state == Constants.STATE.ARMED,
    monitor = draining or retained,
    draining = draining,
    retained = retained,
    compact_recovery = state ~= Constants.STATE.ARMED and not retained,
    progress = draining or active or state == Constants.STATE.COMPLETE
      or ((state == Constants.STATE.ERROR or state == Constants.STATE.ABORTED) and retained),
    plan = has_plan_data and not draining and state ~= Constants.STATE.RESET,
    abort = active or state == Constants.STATE.ERROR,
    configuration = state == Constants.STATE.ARMED
      or (retained and state ~= Constants.STATE.DRAINING and state ~= Constants.STATE.RESET),
    maintenance = state == Constants.STATE.ARMED,
    diagnostics = true,
    technical = state == Constants.STATE.ERROR,
    total = total,
    progress_count = progress_count,
    progress_caption = progress_caption,
  }
end

local function item_caption(item)
  local quality = Util.quality_name(item.quality)
  local item_prototype = prototypes.item and prototypes.item[item.name]
  local caption = {
    "",
    "[item=" .. item.name .. ",quality=" .. quality .. "] ",
    item_prototype and item_prototype.localised_name or item.name,
  }
  if quality ~= "normal" then
    local quality_prototype = prototypes.quality and prototypes.quality[quality]
    caption[#caption + 1] = " ("
    caption[#caption + 1] = quality_prototype and quality_prototype.localised_name or quality
    caption[#caption + 1] = ")"
  end
  caption[#caption + 1] = " × "
  caption[#caption + 1] = tostring(item.count)
  return caption
end

local function allocation_target_caption(target, target_index)
  local caption = {"", {"batch-request-combinator.gui-target-number", target_index}}
  if target.entity and target.entity.valid then
    caption[#caption + 1] = " — "
    caption[#caption + 1] = target.entity.localised_name
    caption[#caption + 1] = " @ "
    caption[#caption + 1] = string.format("%.1f, %.1f", target.entity.position.x, target.entity.position.y)
  else
    caption[#caption + 1] = " — "
    caption[#caption + 1] = {"batch-request-combinator.gui-invalid-target"}
  end
  return caption
end

local function frame_for(player)
  return player.gui.screen[Constants.GUI.FRAME]
end

local function index_elements(element, elements)
  if not element or not element.valid then return end
  if element.name and element.name ~= "" then elements[element.name] = element end
  for _, child in pairs(element.children or {}) do
    index_elements(child, elements)
  end
end

local function elements_for(player, frame)
  local cached = element_cache_by_player[player.index]
  if cached and cached.frame == frame and frame.valid then return cached.elements end
  local elements = {}
  index_elements(frame, elements)
  element_cache_by_player[player.index] = {frame = frame, elements = elements}
  return elements
end

local function clear_player_registration(player_index)
  local root = Registry.root()
  local unit_number = root.gui_players[player_index]
  local instance = unit_number and root.instances[unit_number] or nil
  if instance and instance.gui_players then instance.gui_players[player_index] = nil end
  root.gui_players[player_index] = nil
  if unit_number and (not instance or not next(instance.gui_players or {})) then
    root.open_gui_instances[unit_number] = nil
  end
end

local function add_mode_option(parent, name, caption, description)
  local row = parent.add{type = "flow", direction = "horizontal"}
  row.style.bottom_margin = 4
  row.style.vertical_align = "center"
  row.add{type = "radiobutton", name = name, caption = caption, state = false}
  local info = row.add{type = "sprite", sprite = "info", tooltip = description}
  info.style.left_margin = 4
  info.style.minimal_width = 20
  info.style.minimal_height = 20
end

local function add_info_sprite(parent, tooltip)
  local info = parent.add{type = "sprite", sprite = "info", tooltip = tooltip}
  info.style.left_margin = 4
  info.style.minimal_width = 20
  info.style.minimal_height = 20
  return info
end

function Gui.display_layout(display_resolution, display_scale)
  local scale = math.max(display_scale or 1, 0.01)
  local logical_width = display_resolution.width / scale
  local logical_height = display_resolution.height / scale
  local available_width = math.max(1, logical_width - DISPLAY_HORIZONTAL_MARGIN)
  local available_body_height = math.max(1, logical_height - 112)
  local width = math.floor(math.min(
    TARGET_WIDTH,
    math.max(MINIMUM_WIDTH, available_width),
    logical_width
  ))
  local body_height = math.floor(math.min(
    TARGET_BODY_HEIGHT,
    math.max(MINIMUM_BODY_HEIGHT, logical_height - DISPLAY_VERTICAL_MARGIN),
    available_body_height
  ))
  local wide = width >= WIDE_LAYOUT_MINIMUM_WIDTH
  local compact = width >= COMPACT_LAYOUT_MINIMUM_WIDTH and not wide
  return {
    width = width,
    body_height = body_height,
    scale = scale,
    logical_width = logical_width,
    logical_height = logical_height,
    wide = wide,
    compact = compact,
    constrained = not wide and not compact,
    navigation_columns = wide and 5 or (compact and 2 or 1),
    fact_columns = wide and 3 or (compact and 2 or 1),
    action_columns = wide and 3 or (compact and 2 or 1),
  }
end

local function display_layout(player)
  return Gui.display_layout(player.display_resolution, player.display_scale)
end

local function apply_window_size(frame, body, layout)
  frame.style.width = layout.width
  body.style.maximal_height = layout.body_height
end

function Gui.clamp_location(location, layout)
  if type(location) ~= "table" then return nil end
  local estimated_height = math.min(layout.logical_height, layout.body_height + 112)
  return {
    x = math.floor(math.max(0, math.min(
      location.x or 0,
      (layout.logical_width - layout.width) * layout.scale
    ))),
    y = math.floor(math.max(0, math.min(
      location.y or 0,
      (layout.logical_height - estimated_height) * layout.scale
    ))),
  }
end

local function add_operational_fact(parent, caption, value)
  local row = parent.add{type = "flow", direction = "horizontal"}
  row.style.vertical_align = "center"
  local label = row.add{type = "label", caption = {"", caption, ":"}}
  label.style.single_line = false
  local value_label = row.add{type = "label", caption = tostring(value)}
  value_label.style.font = "default-semibold"
  value_label.style.left_margin = 4
end

local function plan_signature(instance)
  return table.concat({
    tostring(instance.plan_revision or 0),
    instance.captured_signature or "",
    tostring(#(instance.targets or {})),
    tostring(instance.error_code or ""),
  }, "|")
end

local function build(player, instance, preserve_presentation)
  local existing = frame_for(player)
  local previous_location = existing and existing.valid and existing.location or nil
  if existing then existing.destroy() end
  element_cache_by_player[player.index] = nil
  if not preserve_presentation then
    inspector_by_player[player.index] = nil
    drain_preview_by_player[player.index] = nil
    diagnostics_by_player[player.index] = nil
  end
  local root = Registry.root()
  if root.gui_players[player.index] ~= instance.unit_number then
    clear_player_registration(player.index)
  end

  local frame = player.gui.screen.add{
    type = "frame",
    name = Constants.GUI.FRAME,
    direction = "vertical",
  }
  frame.tags = {[GUI_SCHEMA_TAG] = GUI_SCHEMA_VERSION}

  local layout = display_layout(player)
  if not preserve_presentation then
    inspector_by_player[player.index] = Gui.layout_presentation(instance, 0).configuration
      and INSPECTOR.CONFIGURATION or nil
  end
  local titlebar = frame.add{type = "flow", name = Constants.GUI.TITLEBAR, direction = "horizontal"}
  titlebar.style.vertical_align = "center"
  titlebar.drag_target = frame
  titlebar.add{
    type = "label",
    caption = {"batch-request-combinator.gui-title"},
    style = "frame_title",
    ignored_by_interaction = true,
  }
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header"}
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.drag_target = frame
  titlebar.add{
    type = "sprite-button",
    name = Constants.GUI.CLOSE,
    style = "frame_action_button",
    sprite = "utility/close",
    tooltip = {"batch-request-combinator.gui-close"},
  }

  local body = frame.add{
    type = "scroll-pane",
    name = Constants.GUI.BODY,
    direction = "vertical",
    horizontal_scroll_policy = "never",
    vertical_scroll_policy = "auto",
  }
  body.style.horizontally_stretchable = true
  apply_window_size(frame, body, layout)

  local status = body.add{
    type = "frame",
    name = Constants.GUI.STATUS,
    direction = "vertical",
    style = "inside_shallow_frame_with_padding",
  }
  status.style.horizontally_stretchable = true
  local status_title = status.add{type = "flow", direction = "horizontal"}
  status_title.style.vertical_align = "center"
  status_title.add{type = "label", name = Constants.GUI.STATUS_ICON, caption = ""}
  local status_text = status_title.add{type = "label", name = Constants.GUI.STATUS_TEXT, caption = ""}
  status_text.style.font = "default-semibold"
  local status_detail = status.add{type = "label", name = Constants.GUI.STATUS_DETAIL, caption = ""}
  status_detail.style.single_line = false
  status_detail.style.horizontally_stretchable = true

  for _, row in ipairs{
    {Constants.GUI.CONDITION_ROW, {1, 0.72, 0.2}},
    {Constants.GUI.WARNING_ROW, {1, 0.72, 0.2}},
    {Constants.GUI.INFO_ROW, {0.35, 0.7, 1}},
  } do
    local label = status.add{type = "label", name = row[1], caption = ""}
    label.style.single_line = false
    label.style.horizontally_stretchable = true
    label.style.font_color = row[2]
    label.style.top_margin = 6
  end

  local progress_section = body.add{
    type = "frame",
    name = Constants.GUI.PROGRESS_SECTION,
    direction = "vertical",
    style = "inside_shallow_frame_with_padding",
  }
  progress_section.style.horizontally_stretchable = true
  progress_section.style.top_margin = 8
  local progress_header = progress_section.add{type = "flow", direction = layout.wide and "horizontal" or "vertical"}
  progress_header.style.horizontally_stretchable = true
  progress_header.add{type = "label", name = Constants.GUI.PROGRESS_LABEL, caption = ""}.style.font = "default-semibold"
  if layout.wide then
    local progress_spacer = progress_header.add{type = "empty-widget"}
    progress_spacer.style.horizontally_stretchable = true
  end
  progress_header.add{type = "label", name = Constants.GUI.PROGRESS_VALUE, caption = "—"}.style.font = "default-semibold"
  local progress = progress_section.add{type = "progressbar", name = Constants.GUI.PROGRESS_BAR, value = 0}
  progress.style.horizontally_stretchable = true

  local facts = body.add{
    type = "table",
    name = Constants.GUI.FACTS,
    column_count = layout.fact_columns,
  }
  facts.style.horizontally_stretchable = true
  facts.style.horizontal_spacing = 16
  facts.style.vertical_spacing = 4
  facts.style.top_margin = 8

  local mode_summary = body.add{type = "label", name = Constants.GUI.MODE_SUMMARY, caption = ""}
  mode_summary.style.single_line = false
  mode_summary.style.horizontally_stretchable = true
  mode_summary.style.top_margin = 8

  local navigation = body.add{
    type = "table",
    name = Constants.GUI.NAVIGATION,
    column_count = layout.navigation_columns,
  }
  navigation.style.horizontally_stretchable = true
  navigation.style.horizontal_spacing = 8
  navigation.style.vertical_spacing = 6
  navigation.style.top_margin = 8
  navigation.add{type = "button", name = Constants.GUI.NAV_CONFIGURATION, caption = {"batch-request-combinator.gui-configuration"}}
  navigation.add{type = "button", name = Constants.GUI.NAV_BATCH, caption = {"batch-request-combinator.gui-batch-details"}}
  navigation.add{type = "button", name = Constants.GUI.NAV_MAINTENANCE, caption = {"batch-request-combinator.gui-maintenance"}}
  navigation.add{type = "button", name = Constants.GUI.NAV_DIAGNOSTICS, caption = {"batch-request-combinator.gui-diagnostics"}}
  navigation.add{type = "button", name = Constants.GUI.NAV_TECHNICAL, caption = {"batch-request-combinator.gui-technical-details"}}

  local inspector = body.add{
    type = "frame",
    name = Constants.GUI.INSPECTOR_HOST,
    direction = "vertical",
    style = "inside_shallow_frame_with_padding",
  }
  inspector.style.horizontally_stretchable = true
  inspector.style.top_margin = 8
  inspector.add{type = "label", name = Constants.GUI.INSPECTOR_TITLE, caption = ""}.style.font = "default-semibold"

  local configuration = inspector.add{
    type = "flow",
    name = Constants.GUI.CONFIGURATION_PANEL,
    direction = "vertical",
  }
  configuration.style.horizontally_stretchable = true
  configuration.style.top_margin = 8
  local sign_header = configuration.add{type = "flow", direction = "horizontal"}
  sign_header.style.vertical_align = "center"
  sign_header.add{type = "label", caption = {"batch-request-combinator.gui-accepted-signals"}}.style.font = "default-semibold"
  add_info_sprite(sign_header, {"batch-request-combinator.gui-accepted-signals-tooltip"})
  local sign_options = configuration.add{type = "flow", direction = layout.wide and "horizontal" or "vertical"}
  sign_options.style.horizontally_stretchable = true
  sign_options.add{type = "radiobutton", name = Constants.GUI.SIGN_ANY, caption = sign_mode_caption(Constants.SIGN_MODE.ANY), state = false}
  sign_options.add{type = "radiobutton", name = Constants.GUI.SIGN_POSITIVE, caption = sign_mode_caption(Constants.SIGN_MODE.POSITIVE), state = false}
  sign_options.add{type = "radiobutton", name = Constants.GUI.SIGN_NEGATIVE, caption = sign_mode_caption(Constants.SIGN_MODE.NEGATIVE), state = false}

  local settings = configuration.add{type = "table", name = Constants.GUI.SETTINGS_GROUPS, column_count = layout.wide and 2 or 1}
  settings.style.horizontally_stretchable = true
  settings.style.horizontal_spacing = 24
  settings.style.vertical_spacing = 8
  settings.style.top_margin = 8
  local input_modes = settings.add{type = "flow", direction = "vertical"}
  input_modes.style.horizontally_stretchable = true
  input_modes.add{type = "label", caption = {"batch-request-combinator.gui-input-handling"}}.style.font = "default-semibold"
  local input_options = input_modes.add{type = "flow", direction = layout.wide and "horizontal" or "vertical"}
  add_mode_option(input_options, Constants.GUI.INPUT_FOLLOW, {"batch-request-combinator.gui-summary-follow"}, {"batch-request-combinator.input-mode-follow-description"})
  add_mode_option(input_options, Constants.GUI.INPUT_SNAPSHOT, {"batch-request-combinator.gui-summary-snapshot"}, {"batch-request-combinator.input-mode-snapshot-description"})
  local tail_modes = settings.add{type = "flow", direction = "vertical"}
  tail_modes.style.horizontally_stretchable = true
  tail_modes.add{type = "label", caption = {"batch-request-combinator.gui-tail-mode"}}.style.font = "default-semibold"
  local tail_options = tail_modes.add{type = "flow", direction = layout.wide and "horizontal" or "vertical"}
  add_mode_option(tail_options, Constants.GUI.TAIL_NONE, {"batch-request-combinator.gui-summary-no-tail"}, {"batch-request-combinator.tail-mode-none-description"})
  add_mode_option(tail_options, Constants.GUI.TAIL_SINGLE, {"batch-request-combinator.gui-summary-single"}, {"batch-request-combinator.tail-mode-single-description"})
  add_mode_option(tail_options, Constants.GUI.TAIL_PARALLEL, {"batch-request-combinator.gui-summary-parallel"}, {"batch-request-combinator.tail-mode-parallel-description"})
  local auto_cleanup_row = configuration.add{type = "flow", direction = "horizontal"}
  auto_cleanup_row.style.vertical_align = "center"
  auto_cleanup_row.style.top_margin = 8
  auto_cleanup_row.add{
    type = "checkbox",
    name = Constants.GUI.AUTO_CLEANUP_AFTER_INTERRUPT,
    caption = {"batch-request-combinator.gui-auto-cleanup-after-interrupt"},
    state = false,
  }
  add_info_sprite(auto_cleanup_row, {"batch-request-combinator.gui-auto-cleanup-after-interrupt-tooltip"})
  local locked = configuration.add{
    type = "label",
    name = Constants.GUI.CONFIGURATION_LOCKED,
    caption = {"batch-request-combinator.gui-config-locked"},
  }
  locked.style.single_line = false
  locked.style.horizontally_stretchable = true
  locked.style.top_margin = 6

  local batch = inspector.add{type = "flow", name = Constants.GUI.BATCH_PANEL, direction = "vertical"}
  batch.style.horizontally_stretchable = true
  batch.style.top_margin = 8
  local items_section = batch.add{type = "flow", name = Constants.GUI.ITEMS_SECTION, direction = "vertical"}
  items_section.style.horizontally_stretchable = true
  items_section.add{type = "label", name = Constants.GUI.ITEMS_HEADING, caption = ""}.style.font = "default-semibold"
  local items = items_section.add{
    type = "table",
    name = Constants.GUI.ITEMS,
    column_count = layout.wide and 2 or 1,
  }
  items.style.horizontally_stretchable = true
  items.style.horizontal_spacing = 24
  items.style.vertical_spacing = 4
  local allocations_section = batch.add{type = "flow", name = Constants.GUI.ALLOCATIONS_SECTION, direction = "vertical"}
  allocations_section.style.horizontally_stretchable = true
  allocations_section.style.top_margin = 8
  allocations_section.add{type = "label", name = Constants.GUI.ALLOCATIONS_HEADING, caption = ""}.style.font = "default-semibold"
  local allocations = allocations_section.add{type = "flow", name = Constants.GUI.ALLOCATIONS, direction = "vertical"}
  allocations.style.horizontally_stretchable = true

  local maintenance = inspector.add{type = "flow", name = Constants.GUI.MAINTENANCE_PANEL, direction = "vertical"}
  maintenance.style.horizontally_stretchable = true
  maintenance.style.top_margin = 8
  local drain_confirmation = maintenance.add{
    type = "flow",
    name = Constants.GUI.DRAIN_CONFIRMATION,
    direction = "vertical",
  }
  drain_confirmation.style.horizontally_stretchable = true
  drain_confirmation.visible = false
  local confirmation_text = drain_confirmation.add{type = "label", name = Constants.GUI.DRAIN_CONFIRMATION_TEXT, caption = ""}
  confirmation_text.style.single_line = false
  confirmation_text.style.horizontally_stretchable = true
  local confirmation_actions = drain_confirmation.add{
    type = "table",
    column_count = layout.constrained and 1 or 3,
  }
  confirmation_actions.style.top_margin = 6
  confirmation_actions.style.horizontal_spacing = 8
  confirmation_actions.style.vertical_spacing = 6
  confirmation_actions.add{type = "button", name = Constants.GUI.DRAIN_CONFIRM, caption = {"batch-request-combinator.gui-drain-confirm-action"}, style = "green_button"}
  confirmation_actions.add{type = "button", name = Constants.GUI.DRAIN_CANCEL, caption = {"batch-request-combinator.gui-cancel"}}

  local diagnostics = inspector.add{type = "flow", name = Constants.GUI.DIAGNOSTICS_PANEL, direction = "vertical"}
  diagnostics.style.horizontally_stretchable = true
  diagnostics.style.top_margin = 8
  for _, row in ipairs{
    Constants.GUI.DIAGNOSTIC_ENTITY,
    Constants.GUI.DIAGNOSTIC_PRIMARY,
    Constants.GUI.DIAGNOSTIC_WARNING,
    Constants.GUI.DIAGNOSTIC_SETTINGS,
  } do
    local parent = diagnostics
    if row == Constants.GUI.DIAGNOSTIC_SETTINGS then
      parent = diagnostics.add{type = "flow", direction = "horizontal"}
      parent.style.horizontally_stretchable = true
      parent.style.vertical_align = "center"
    end
    local label = parent.add{type = "label", name = row, caption = ""}
    label.style.single_line = false
    label.style.horizontally_stretchable = true
    if row == Constants.GUI.DIAGNOSTIC_SETTINGS then
      add_info_sprite(parent, {"batch-request-combinator.gui-settings-path"})
    end
  end
  diagnostics.add{type = "label", caption = {"batch-request-combinator.gui-settings-path"}}
  for _, row in ipairs{
    Constants.GUI.DIAGNOSTIC_SNAPSHOT,
    Constants.GUI.DIAGNOSTIC_COUNTS,
    Constants.GUI.DIAGNOSTIC_STATES,
    Constants.GUI.DIAGNOSTIC_PROCESSED,
    Constants.GUI.DIAGNOSTIC_PROFILER,
  } do
    local label = diagnostics.add{type = "label", name = row, caption = ""}
    label.style.single_line = false
    label.style.horizontally_stretchable = true
  end
  local diagnostic_actions = diagnostics.add{type = "table", column_count = layout.constrained and 1 or 2}
  diagnostic_actions.style.top_margin = 8
  diagnostic_actions.style.horizontal_spacing = 8
  diagnostic_actions.style.vertical_spacing = 6
  diagnostic_actions.add{type = "button", name = Constants.GUI.DIAGNOSTICS_REFRESH, caption = {"batch-request-combinator.gui-refresh-diagnostics"}}
  diagnostic_actions.add{type = "button", name = Constants.GUI.DIAGNOSTICS_PRINT, caption = {"batch-request-combinator.gui-print-stats"}}

  local technical = inspector.add{type = "flow", name = Constants.GUI.TECHNICAL_PANEL, direction = "vertical"}
  technical.style.horizontally_stretchable = true
  technical.style.top_margin = 8
  for _, row in ipairs{
    Constants.GUI.TECHNICAL_ERROR,
    Constants.GUI.TECHNICAL_DETAIL,
    Constants.GUI.TECHNICAL_GUIDANCE,
    Constants.GUI.TECHNICAL_OUTPUT,
  } do
    local label = technical.add{type = "label", name = row, caption = ""}
    label.style.single_line = false
    label.style.horizontally_stretchable = true
  end
  technical.add{type = "button", name = Constants.GUI.TECHNICAL_BATCH, caption = {"batch-request-combinator.gui-batch-details"}}

  local action_bar = frame.add{
    type = "flow",
    name = Constants.GUI.ACTION_BAR,
    direction = layout.constrained and "vertical" or "horizontal",
  }
  action_bar.style.horizontally_stretchable = true
  action_bar.style.top_margin = 8
  local action_spacer = action_bar.add{type = "empty-widget"}
  action_spacer.style.horizontally_stretchable = true
  local actions = action_bar.add{type = "table", name = Constants.GUI.ACTIONS, column_count = layout.action_columns}
  actions.style.horizontal_spacing = 8
  actions.style.vertical_spacing = 6
  actions.add{type = "button", name = Constants.GUI.RETRY_TAIL, caption = {"batch-request-combinator.gui-retry-tail"}}
  actions.add{type = "button", name = Constants.GUI.ABORT, caption = {"batch-request-combinator.gui-abort-batch"}, style = "red_button"}
  actions.add{type = "button", name = Constants.GUI.DRAIN_STOP, caption = {"batch-request-combinator.gui-stop-draining"}, tooltip = {"batch-request-combinator.gui-stop-draining-tooltip"}}

  for _, panel in ipairs{configuration, batch, maintenance, diagnostics, technical} do panel.visible = false end
  inspector.visible = false
  action_bar.visible = false

  root.gui_players[player.index] = instance.unit_number
  root.open_gui_instances[instance.unit_number] = true
  instance.gui_players = instance.gui_players or {}
  instance.gui_players[player.index] = true
  elements_for(player, frame)
  local location = preserve_presentation and Gui.clamp_location(previous_location, layout) or nil
  if location then frame.location = location else frame.auto_center = true end
  return frame
end

local function update_list(container, values, caption_function)
  container.clear()
  for index, value in ipairs(values) do
    local label = container.add{type = "label", caption = caption_function(value, index)}
    label.style.single_line = false
    label.style.horizontally_stretchable = true
  end
end

local function update_allocations(container, targets)
  container.clear()
  for target_index, target in ipairs(targets) do
    local target_label = container.add{
      type = "label",
      caption = allocation_target_caption(target, target_index),
    }
    target_label.style.single_line = false
    target_label.style.horizontally_stretchable = true

    local items = target.allocation and target.allocation.items
    if type(items) ~= "table" or #items == 0 then
      items = {{empty = true}}
    end
    for _, item in ipairs(items) do
      local item_label = container.add{
        type = "label",
        caption = item.empty
          and {"batch-request-combinator.gui-empty-allocation"}
          or item_caption(item),
      }
      item_label.style.single_line = false
      item_label.style.horizontally_stretchable = true
      item_label.style.left_margin = 16
    end
  end
end

local function short_sign_mode_caption(mode)
  if mode == Constants.SIGN_MODE.POSITIVE then return {"batch-request-combinator.gui-summary-positive"} end
  if mode == Constants.SIGN_MODE.NEGATIVE then return {"batch-request-combinator.gui-summary-negative"} end
  return {"batch-request-combinator.gui-summary-any"}
end

local function short_input_mode_caption(mode)
  if mode == Constants.INPUT_MODE.SNAPSHOT then return {"batch-request-combinator.gui-summary-snapshot"} end
  return {"batch-request-combinator.gui-summary-follow"}
end

local function short_tail_mode_caption(mode)
  if mode == Constants.TAIL_MODE.SINGLE then return {"batch-request-combinator.gui-summary-single"} end
  if mode == Constants.TAIL_MODE.PARALLEL then return {"batch-request-combinator.gui-summary-parallel"} end
  return {"batch-request-combinator.gui-summary-no-tail"}
end

local function mode_summary_caption(instance, captured)
  return {
    "batch-request-combinator.gui-mode-summary",
    short_sign_mode_caption(instance.sign_mode),
    short_input_mode_caption(captured and instance.captured_input_mode or instance.input_mode),
    short_tail_mode_caption(captured and instance.captured_tail_mode or instance.tail_mode),
    instance.auto_cleanup_after_interrupt == true
      and {"batch-request-combinator.gui-summary-cleanup-on"}
      or {"batch-request-combinator.gui-summary-cleanup-off"},
  }
end

local function maximum_tail_attempts(instance)
  local maximum = 0
  for _, record in ipairs(instance.monitored_inserters or {}) do
    maximum = math.max(maximum, record.tail_attempts or 0)
  end
  return maximum
end

local function update_operational_summary(summary, instance, pending, remaining)
  summary.clear()
  local state = instance.state
  if state == Constants.STATE.DRAINING then
    add_operational_fact(summary, {"batch-request-combinator.gui-drain-target-count"}, #(instance.drain_targets or {}))
    add_operational_fact(summary, {"batch-request-combinator.gui-drain-remaining"}, instance.drain_remaining_total or 0)
    if pending > 0 then
      add_operational_fact(summary, {"batch-request-combinator.gui-pending-deliveries"}, pending)
    end
  elseif state == Constants.STATE.REQUESTING or state == Constants.STATE.SETTLING then
    if pending > 0 then
      add_operational_fact(summary, {"batch-request-combinator.gui-pending-deliveries"}, pending)
    end
    if (instance.planned_tail_count or 0) > 0 then
      add_operational_fact(summary, {"batch-request-combinator.gui-planned-tail-inserters"}, instance.planned_tail_count)
    end
  elseif state == Constants.STATE.READY then
    if #(instance.targets or {}) > 0 then
      add_operational_fact(summary, {"batch-request-combinator.gui-target-count"}, #(instance.targets or {}))
    end
    if (instance.planned_tail_count or 0) > 0 then
      add_operational_fact(summary, {"batch-request-combinator.gui-planned-tail-inserters"}, instance.planned_tail_count)
    end
    if instance.manual_tail_recovery then
      add_operational_fact(summary, {"batch-request-combinator.gui-tail-attempts"}, maximum_tail_attempts(instance))
      if remaining > 0 then
        add_operational_fact(summary, {"batch-request-combinator.gui-remaining-source"}, remaining)
      end
    end
  end
  summary.visible = #summary.children > 0
end

local STATUS = {
  [Constants.STATE.ARMED] = {signal = Constants.STATUS_SIGNAL.armed, color = {0.7, 0.7, 0.7}, detail = "status-armed"},
  [Constants.STATE.DRAINING] = {signal = Constants.STATUS_SIGNAL.warning, color = {1, 0.72, 0.2}, detail = "status-draining"},
  [Constants.STATE.REQUESTING] = {signal = Constants.STATUS_SIGNAL.requesting, color = {0.35, 0.7, 1}, detail = "status-requesting"},
  [Constants.STATE.SETTLING] = {signal = Constants.STATUS_SIGNAL.settling, color = {0.35, 0.7, 1}, detail = "status-settling"},
  [Constants.STATE.READY] = {signal = Constants.STATUS_SIGNAL.ready, color = {0.35, 1, 0.45}, detail = "status-ready"},
  [Constants.STATE.COMPLETE] = {signal = Constants.STATUS_SIGNAL.complete, color = {0.35, 1, 0.45}, detail = "status-complete"},
  [Constants.STATE.ERROR] = {signal = Constants.STATUS_SIGNAL.error, color = {1, 0.35, 0.3}, detail = "status-error"},
  [Constants.STATE.ABORTED] = {signal = Constants.STATUS_SIGNAL.aborted, color = {0.7, 0.7, 0.7}, detail = "status-aborted"},
  [Constants.STATE.RESET] = {signal = Constants.STATUS_SIGNAL.armed, color = {0.7, 0.7, 0.7}, detail = "status-reset"},
}

function Gui.status_presentation(instance)
  return STATUS[instance.state] or STATUS[Constants.STATE.ARMED]
end

function Gui.condition_presentation(instance)
  if instance.state == Constants.STATE.DRAINING and instance.drain_wait_reason then
    local caption = DRAIN_WAIT_CAPTIONS[instance.drain_wait_reason]
    if caption then
      return {
        signal = Constants.STATUS_SIGNAL.warning,
        color = {1, 0.72, 0.2},
        caption = caption,
      }
    end
  end
  if instance.tail_waiting_reason
    and (instance.state == Constants.STATE.READY or instance.state == Constants.STATE.SETTLING) then
    local destination = instance.tail_waiting_reason == "destination"
    local monitored = instance.tail_waiting_reason == "monitored"
    local manual = instance.tail_waiting_reason == "manual"
    return {
      signal = Constants.STATUS_SIGNAL.warning,
      color = {1, 0.72, 0.2},
      caption = destination and "condition-destination-blocked"
        or (monitored and "condition-monitored-hand-waiting"
        or (manual and "condition-manual-tail-waiting" or "condition-tail-waiting")),
    }
  end
  return nil
end

function Gui.error_presentation(instance)
  local code = instance.error_code
  local title_key = ERROR_TITLE_CAPTIONS[code] or "error-title-unknown"
  local message_key = Constants.ERROR_LOCALE[code] or "batch-request-combinator-error.unknown"
  local detail = {""}
  if instance.error_detail ~= nil then
    detail[#detail + 1] = {"batch-request-combinator.gui-error-detail", instance.error_detail}
    detail[#detail + 1] = "\n"
  end
  detail[#detail + 1] = {message_key}
  detail[#detail + 1] = "\n"
  detail[#detail + 1] = {"batch-request-combinator.gui-error-reset-instruction"}
  return {
    title = {"batch-request-combinator." .. title_key},
    detail = detail,
  }
end

function Gui.state_caption(instance)
  return {"batch-request-combinator.state-" .. instance.state}
end

function Gui.snapshot_reset_presentation(instance)
  local active = instance.state == Constants.STATE.REQUESTING
    or instance.state == Constants.STATE.SETTLING
    or instance.state == Constants.STATE.READY
    or instance.state == Constants.STATE.COMPLETE
  if not instance.snapshot_reset_recorded or not active then return nil end
  return {
    "",
    "[virtual-signal=" .. Constants.STATUS_SIGNAL.requesting .. "] ",
    {"batch-request-combinator.info-snapshot-reset"},
  }
end

function Gui.input_warning_presentation(instance)
  local active = instance.state == Constants.STATE.REQUESTING
    or instance.state == Constants.STATE.SETTLING
    or instance.state == Constants.STATE.READY
    or instance.state == Constants.STATE.COMPLETE
    or instance.state == Constants.STATE.ERROR
  if not active then return nil end
  if instance.snapshot_new_input_warning then return "warning-snapshot-new-input" end
  if instance.warning_input_changed then return "warning-input-changed" end
  return nil
end

local PRIMARY_OUTPUT = {
  [Constants.STATUS_SIGNAL.armed] = "gui-output-armed",
  [Constants.STATUS_SIGNAL.requesting] = "gui-output-requesting",
  [Constants.STATUS_SIGNAL.settling] = "gui-output-settling",
  [Constants.STATUS_SIGNAL.ready] = "gui-output-ready",
  [Constants.STATUS_SIGNAL.complete] = "gui-output-complete",
  [Constants.STATUS_SIGNAL.aborted] = "gui-output-aborted",
}

local function applied_output(instance)
  local primary
  local warning = false
  for entry in string.gmatch(instance.output_signature or "", "[^;]+") do
    local signal, count = string.match(entry, "^(.+):(-?%d+)$")
    if signal == Constants.STATUS_SIGNAL.warning then
      warning = true
    elseif signal == Constants.STATUS_SIGNAL.error then
      primary = {"batch-request-combinator.gui-output-error", tonumber(count) or 0}
    else
      local key = PRIMARY_OUTPUT[signal]
      if key then primary = {"batch-request-combinator." .. key} end
    end
  end
  return primary or {"batch-request-combinator.gui-output-none"}, warning
end

function Gui.output_presentation(instance)
  return applied_output(instance)
end

local function primary_output_caption(instance)
  local primary = Gui.output_presentation(instance)
  return primary
end

local function inspector_available(layout, inspector)
  if inspector == INSPECTOR.CONFIGURATION then return layout.configuration end
  if inspector == INSPECTOR.BATCH then return layout.plan end
  if inspector == INSPECTOR.MAINTENANCE then return layout.maintenance end
  if inspector == INSPECTOR.DIAGNOSTICS then return layout.diagnostics end
  if inspector == INSPECTOR.TECHNICAL then return layout.technical end
  return false
end

local INSPECTOR_CAPTION = {
  [INSPECTOR.CONFIGURATION] = "gui-configuration",
  [INSPECTOR.BATCH] = "gui-batch-details",
  [INSPECTOR.MAINTENANCE] = "gui-maintenance",
  [INSPECTOR.DIAGNOSTICS] = "gui-diagnostics",
  [INSPECTOR.TECHNICAL] = "gui-technical-details",
}

local NAVIGATION = {
  {INSPECTOR.CONFIGURATION, Constants.GUI.NAV_CONFIGURATION, "configuration"},
  {INSPECTOR.BATCH, Constants.GUI.NAV_BATCH, "plan"},
  {INSPECTOR.MAINTENANCE, Constants.GUI.NAV_MAINTENANCE, "maintenance"},
  {INSPECTOR.DIAGNOSTICS, Constants.GUI.NAV_DIAGNOSTICS, "diagnostics"},
  {INSPECTOR.TECHNICAL, Constants.GUI.NAV_TECHNICAL, "technical"},
}

local PANELS = {
  [INSPECTOR.CONFIGURATION] = Constants.GUI.CONFIGURATION_PANEL,
  [INSPECTOR.BATCH] = Constants.GUI.BATCH_PANEL,
  [INSPECTOR.MAINTENANCE] = Constants.GUI.MAINTENANCE_PANEL,
  [INSPECTOR.DIAGNOSTICS] = Constants.GUI.DIAGNOSTICS_PANEL,
  [INSPECTOR.TECHNICAL] = Constants.GUI.TECHNICAL_PANEL,
}

local function update_configuration(elements, instance)
  local editable = instance.state == Constants.STATE.ARMED
  local sign_mode = instance.sign_mode or Constants.SIGN_MODE.ANY
  local input_mode = editable and instance.input_mode
    or (instance.captured_input_mode or instance.input_mode)
  local tail_mode = editable and instance.tail_mode
    or (instance.captured_tail_mode or instance.tail_mode)
  local sign_controls = {
    [Constants.SIGN_MODE.ANY] = elements[Constants.GUI.SIGN_ANY],
    [Constants.SIGN_MODE.POSITIVE] = elements[Constants.GUI.SIGN_POSITIVE],
    [Constants.SIGN_MODE.NEGATIVE] = elements[Constants.GUI.SIGN_NEGATIVE],
  }
  for mode, control in pairs(sign_controls) do
    local selected = sign_mode == mode
    control.state = selected
    control.enabled = editable or selected
    control.ignored_by_interaction = not editable
  end
  local input_controls = {
    [Constants.INPUT_MODE.FOLLOW] = elements[Constants.GUI.INPUT_FOLLOW],
    [Constants.INPUT_MODE.SNAPSHOT] = elements[Constants.GUI.INPUT_SNAPSHOT],
  }
  for mode, control in pairs(input_controls) do
    local selected = input_mode == mode
    control.state = selected
    control.enabled = editable or selected
    control.ignored_by_interaction = not editable
  end
  local tail_controls = {
    [Constants.TAIL_MODE.NO_TAIL] = elements[Constants.GUI.TAIL_NONE],
    [Constants.TAIL_MODE.SINGLE] = elements[Constants.GUI.TAIL_SINGLE],
    [Constants.TAIL_MODE.PARALLEL] = elements[Constants.GUI.TAIL_PARALLEL],
  }
  for mode, control in pairs(tail_controls) do
    local selected = tail_mode == mode
    control.state = selected
    control.enabled = editable or selected
    control.ignored_by_interaction = not editable
  end
  local auto_cleanup = elements[Constants.GUI.AUTO_CLEANUP_AFTER_INTERRUPT]
  auto_cleanup.state = instance.auto_cleanup_after_interrupt == true
  auto_cleanup.enabled = editable or auto_cleanup.state
  auto_cleanup.ignored_by_interaction = not editable
  elements[Constants.GUI.CONFIGURATION_LOCKED].visible = not editable
end

local function capture_diagnostics(player_index, instance)
  local values = Debug.snapshot()
  values.tick = game.tick
  values.debug_enabled = settings.global[Constants.SETTING_DEBUG].value == true
  diagnostics_by_player[player_index] = {unit_number = instance.unit_number, values = values}
  return values
end

local function update_diagnostics(elements, player_index, instance)
  local cached = diagnostics_by_player[player_index]
  local values = cached and cached.unit_number == instance.unit_number and cached.values
    or capture_diagnostics(player_index, instance)
  elements[Constants.GUI.DIAGNOSTIC_ENTITY].caption = {
    "batch-request-combinator.gui-diagnostic-entity",
    instance.unit_number,
    Gui.state_caption(instance),
  }
  elements[Constants.GUI.DIAGNOSTIC_PRIMARY].caption = {
    "batch-request-combinator.gui-diagnostic-primary",
    primary_output_caption(instance),
  }
  local _, warning_output = Gui.output_presentation(instance)
  elements[Constants.GUI.DIAGNOSTIC_WARNING].caption = warning_output
    and {"batch-request-combinator.gui-diagnostic-warning-active"}
    or {"batch-request-combinator.gui-diagnostic-warning-none"}
  elements[Constants.GUI.DIAGNOSTIC_SETTINGS].caption = {
    "batch-request-combinator.gui-diagnostic-settings",
    values.poll_interval,
    values.debug_enabled and {"batch-request-combinator.gui-enabled"}
      or {"batch-request-combinator.gui-disabled"},
  }
  elements[Constants.GUI.DIAGNOSTIC_SNAPSHOT].caption = {
    "batch-request-combinator.gui-diagnostic-snapshot",
    values.tick,
  }
  elements[Constants.GUI.DIAGNOSTIC_COUNTS].caption = {
    "batch-request-combinator.gui-diagnostic-counts",
    values.registered,
    values.active,
    values.requesting,
  }
  elements[Constants.GUI.DIAGNOSTIC_STATES].caption = {
    "batch-request-combinator.gui-diagnostic-states",
    values.settling,
    values.ready,
    values.error,
  }
  elements[Constants.GUI.DIAGNOSTIC_PROCESSED].caption = {
    "batch-request-combinator.gui-diagnostic-processed",
    string.format("%.2f", values.average_processed),
    values.maximum_processed,
  }
  elements[Constants.GUI.DIAGNOSTIC_PROFILER].caption = {
    "batch-request-combinator.gui-diagnostic-profiler",
    tostring(values.last_profiler),
    values.cleanup_pending,
  }
end

local function update_technical(elements, instance, layout)
  local error = Gui.error_presentation(instance)
  elements[Constants.GUI.TECHNICAL_ERROR].caption = {
    "",
    "[virtual-signal=" .. Constants.STATUS_SIGNAL.error .. "] ",
    {
      "batch-request-combinator.gui-technical-error",
      instance.error_code or 0,
      error.title,
    },
  }
  local detail = elements[Constants.GUI.TECHNICAL_DETAIL]
  detail.visible = instance.error_detail ~= nil
  if detail.visible then
    detail.caption = {"batch-request-combinator.gui-technical-detail", instance.error_detail}
  end
  local guidance = elements[Constants.GUI.TECHNICAL_GUIDANCE]
  local guidance_key = ERROR_TECHNICAL_CAPTIONS[instance.error_code]
  guidance.visible = guidance_key ~= nil
  if guidance_key then
    guidance.caption = {"batch-request-combinator." .. guidance_key}
  end
  elements[Constants.GUI.TECHNICAL_OUTPUT].caption = {
    "batch-request-combinator.gui-diagnostic-primary",
    primary_output_caption(instance),
  }
  elements[Constants.GUI.TECHNICAL_BATCH].visible = layout.retained
end

local function update_batch_details(elements, frame, instance)
  local tags = frame.tags or {}
  local current_plan_signature = plan_signature(instance)
  if tags[PLAN_SIGNATURE_TAG] ~= current_plan_signature then
    update_list(elements[Constants.GUI.ITEMS], instance.captured or {}, item_caption)
    update_allocations(elements[Constants.GUI.ALLOCATIONS], instance.targets or {})
    elements[Constants.GUI.ITEMS_HEADING].caption = {"batch-request-combinator.gui-captured-items"}
    elements[Constants.GUI.ALLOCATIONS_HEADING].caption = {
      "batch-request-combinator.gui-allocation-count",
      #(instance.targets or {}),
    }
    tags[PLAN_SIGNATURE_TAG] = current_plan_signature
    frame.tags = tags
  end
  elements[Constants.GUI.ITEMS_SECTION].visible = #(instance.captured or {}) > 0
  elements[Constants.GUI.ALLOCATIONS_SECTION].visible = #(instance.targets or {}) > 0
end

local function update_maintenance(elements, player_index)
  local preview = drain_preview_by_player[player_index]
  local confirmation = elements[Constants.GUI.DRAIN_CONFIRMATION]
  confirmation.visible = preview ~= nil
  local invalid = preview ~= nil and type(preview.scope_signature) ~= "string"
  if not preview then return end
  elements[Constants.GUI.DRAIN_CONFIRMATION_TEXT].caption = preview.caption
  elements[Constants.GUI.DRAIN_CONFIRM].enabled = not invalid
  elements[Constants.GUI.DRAIN_CONFIRM].tooltip = invalid and preview.caption or nil
end

local function update_inspector(player, frame, elements, instance, layout)
  local selected = inspector_by_player[player.index]
  if selected and not inspector_available(layout, selected) then
    selected = nil
    inspector_by_player[player.index] = nil
  end
  local navigation_visible = false
  for _, entry in ipairs(NAVIGATION) do
    local button = elements[entry[2]]
    local visible = layout[entry[3]] == true
    button.visible = visible
    button.style = selected == entry[1] and "green_button" or "button"
    navigation_visible = navigation_visible or visible
  end
  elements[Constants.GUI.NAVIGATION].visible = navigation_visible
  local host = elements[Constants.GUI.INSPECTOR_HOST]
  host.visible = selected ~= nil
  for inspector_name, element_name in pairs(PANELS) do
    elements[element_name].visible = selected == inspector_name
  end
  if not selected then return end
  elements[Constants.GUI.INSPECTOR_TITLE].caption = {
    "batch-request-combinator." .. INSPECTOR_CAPTION[selected],
  }
  if selected == INSPECTOR.CONFIGURATION then
    update_configuration(elements, instance)
  elseif selected == INSPECTOR.BATCH then
    update_batch_details(elements, frame, instance)
  elseif selected == INSPECTOR.MAINTENANCE then
    update_maintenance(elements, player.index)
  elseif selected == INSPECTOR.DIAGNOSTICS then
    update_diagnostics(elements, player.index, instance)
  elseif selected == INSPECTOR.TECHNICAL then
    update_technical(elements, instance, layout)
  end
end

function Gui.refresh_player(player, instance)
  local frame = frame_for(player)
  if not frame or not frame.valid then return end
  local tags = frame.tags or {}
  if tags[GUI_SCHEMA_TAG] ~= GUI_SCHEMA_VERSION then
    frame = build(player, instance, true)
    tags = frame.tags or {}
  end
  local elements = elements_for(player, frame)
  local presentation = Gui.status_presentation(instance)
  local status_icon = elements[Constants.GUI.STATUS_ICON]
  local status_text = elements[Constants.GUI.STATUS_TEXT]
  local status_detail = elements[Constants.GUI.STATUS_DETAIL]
  local error = instance.state == Constants.STATE.ERROR and Gui.error_presentation(instance) or nil
  status_icon.caption = "[virtual-signal=" .. presentation.signal .. "]"
  status_text.caption = error and error.title or Gui.state_caption(instance)
  status_text.style.font_color = presentation.color
  status_detail.caption = error
    and error.detail
    or {"batch-request-combinator." .. presentation.detail}

  local remaining = instance.state == Constants.STATE.DRAINING
    and (instance.drain_remaining_total or 0)
    or ((instance.captured_total or 0) > 0 and Requests.remaining_source_count(instance) or 0)
  local layout = Gui.layout_presentation(instance, remaining)
  local total = layout.total

  local progress_section = elements[Constants.GUI.PROGRESS_SECTION]
  progress_section.visible = layout.progress
  local progress = elements[Constants.GUI.PROGRESS_BAR]
  progress.value = total > 0 and layout.progress_count / total or 0
  progress.style.color = presentation.color
  progress.tooltip = {"batch-request-combinator.gui-progress-value", layout.progress_count, total}
  elements[Constants.GUI.PROGRESS_LABEL].caption = layout.progress_caption
  elements[Constants.GUI.PROGRESS_VALUE].caption = {
    "batch-request-combinator.gui-progress-value",
    layout.progress_count,
    total,
  }

  local condition = Gui.condition_presentation(instance)
  local condition_row = elements[Constants.GUI.CONDITION_ROW]
  condition_row.visible = condition ~= nil
  if condition then
    condition_row.caption = {
      "",
      "[virtual-signal=" .. condition.signal .. "] ",
      {"batch-request-combinator." .. condition.caption},
    }
  end

  local warning = elements[Constants.GUI.WARNING_ROW]
  local input_warning = Gui.input_warning_presentation(instance)
  if input_warning then
    warning.caption = {
      "",
      "[virtual-signal=" .. Constants.STATUS_SIGNAL.warning .. "] ",
      {"batch-request-combinator." .. input_warning},
    }
    warning.visible = true
  else
    warning.visible = false
  end
  local information = elements[Constants.GUI.INFO_ROW]
  local snapshot_reset = Gui.snapshot_reset_presentation(instance)
  if snapshot_reset then
    information.caption = snapshot_reset
    information.visible = true
  else
    information.visible = false
  end

  local show_mode_summary = instance.state == Constants.STATE.ARMED
    or (layout.retained and instance.state ~= Constants.STATE.DRAINING and instance.state ~= Constants.STATE.RESET)
  elements[Constants.GUI.MODE_SUMMARY].visible = show_mode_summary
  if show_mode_summary then
    elements[Constants.GUI.MODE_SUMMARY].caption = mode_summary_caption(
      instance,
      instance.state ~= Constants.STATE.ARMED
    )
  end

  local pending = layout.draining and (instance.drain_pending_deliveries or 0)
    or (layout.retained and Requests.pending_delivery_count(instance) or 0)
  local summary_signature = table.concat({
    tostring(instance.state),
    tostring(pending),
    tostring(instance.planned_tail_count or 0),
    tostring(remaining),
    tostring(instance.tail_waiting_reason or ""),
    tostring(instance.drain_wait_reason or ""),
    tostring(maximum_tail_attempts(instance)),
    tostring(instance.drain_remaining_total or 0),
    tostring(#(instance.drain_targets or {})),
    tostring(#(instance.targets or {})),
  }, "|")
  if tags[SUMMARY_SIGNATURE_TAG] ~= summary_signature then
    update_operational_summary(elements[Constants.GUI.FACTS], instance, pending, remaining)
    tags[SUMMARY_SIGNATURE_TAG] = summary_signature
  end
  frame.tags = tags

  if instance.state ~= Constants.STATE.ARMED then drain_preview_by_player[player.index] = nil end
  update_inspector(player, frame, elements, instance, layout)

  local retry_relevant = instance.state == Constants.STATE.READY
    and (instance.tail_waiting_reason == "destination"
      or instance.tail_waiting_reason == "tail"
      or instance.tail_waiting_reason == "manual")
  local retry = elements[Constants.GUI.RETRY_TAIL]
  retry.visible = retry_relevant
  retry.enabled = instance.manual_tail_recovery == true
  if retry.enabled then
    retry.tooltip = nil
  elseif instance.tail_waiting_reason == "destination" then
    retry.tooltip = {"batch-request-combinator.gui-retry-tail-disabled-destination-tooltip"}
  else
    retry.tooltip = {"batch-request-combinator.gui-retry-tail-disabled-tooltip"}
  end
  local abort = elements[Constants.GUI.ABORT]
  abort.visible = layout.abort
  abort.caption = instance.state == Constants.STATE.ERROR
    and {"batch-request-combinator.gui-reset-batch"}
    or {"batch-request-combinator.gui-abort-batch"}
  abort.tooltip = instance.state == Constants.STATE.ERROR
    and {"batch-request-combinator.gui-reset-batch-tooltip"} or nil
  local drain_stop = elements[Constants.GUI.DRAIN_STOP]
  drain_stop.visible = layout.draining
  local actions_visible = retry_relevant or layout.abort or layout.draining
  elements[Constants.GUI.ACTION_BAR].visible = actions_visible
  elements[Constants.GUI.ACTIONS].visible = actions_visible
end

function Gui.on_display_changed(event)
  local player = game.get_player(event.player_index)
  local frame = player and frame_for(player) or nil
  if not frame or not frame.valid then return end
  local unit_number = Registry.root().gui_players[event.player_index]
  local instance = unit_number and Registry.instance(unit_number) or nil
  if not instance then
    Gui.close_player(event.player_index)
    return
  end
  build(player, instance, true)
  Gui.refresh_player(player, instance)
end

function Gui.refresh_instance(instance)
  for player_index in pairs(instance.gui_players or {}) do
    local player = game.get_player(player_index)
    if player and player.valid and frame_for(player) then
      Gui.refresh_player(player, instance)
    else
      clear_player_registration(player_index)
      instance.gui_players[player_index] = nil
    end
  end
end

function Gui.open(event)
  local entity = event.entity
  if event.gui_type ~= defines.gui_type.entity or not entity or not entity.valid
    or entity.name ~= Constants.ENTITY_NAME then return end
  local player = game.get_player(event.player_index)
  local instance = Registry.instance(entity.unit_number)
  if not player or not instance then return end
  player.opened = nil
  build(player, instance, false)
  Gui.refresh_player(player, instance)
end

function Gui.close_player(player_index)
  local player = game.get_player(player_index)
  if player then
    local frame = frame_for(player)
    if frame and frame.valid then frame.destroy() end
  end
  element_cache_by_player[player_index] = nil
  inspector_by_player[player_index] = nil
  drain_preview_by_player[player_index] = nil
  diagnostics_by_player[player_index] = nil
  clear_player_registration(player_index)
end

function Gui.close_instance(instance)
  local players = {}
  for player_index in pairs(instance.gui_players or {}) do players[#players + 1] = player_index end
  table.sort(players)
  for _, player_index in ipairs(players) do Gui.close_player(player_index) end
end

function Gui.on_closed(event)
  if event.element and event.element.valid and event.element.name == Constants.GUI.FRAME then
    Gui.close_player(event.player_index)
  end
end

local function instance_for_event(event)
  local unit_number = Registry.root().gui_players[event.player_index]
  return unit_number and Registry.instance(unit_number) or nil
end

local function show_drain_confirmation(player, caption, scope_signature)
  local frame = frame_for(player)
  if not frame or not frame.valid then return end
  local decorated_caption = {
    "",
    "[virtual-signal=" .. (type(scope_signature) == "string"
      and Constants.STATUS_SIGNAL.warning or Constants.STATUS_SIGNAL.error) .. "] ",
    caption,
  }
  drain_preview_by_player[player.index] = {
    caption = decorated_caption,
    scope_signature = scope_signature,
  }
  local elements = elements_for(player, frame)
  elements[Constants.GUI.DRAIN_CONFIRMATION_TEXT].caption = decorated_caption
  elements[Constants.GUI.DRAIN_CONFIRM].enabled = type(scope_signature) == "string"
  elements[Constants.GUI.DRAIN_CONFIRM].tooltip = type(scope_signature) == "string"
    and nil or decorated_caption
  elements[Constants.GUI.DRAIN_CONFIRMATION].visible = true
end

local function hide_drain_confirmation(player)
  local frame = frame_for(player)
  if not frame or not frame.valid then return end
  drain_preview_by_player[player.index] = nil
  local elements = elements_for(player, frame)
  elements[Constants.GUI.DRAIN_CONFIRMATION].visible = false
end

local function preview_drain(player, instance)
  local valid, error_code, error_detail, preview = StateMachine.preview_drain(instance)
  if valid then
    show_drain_confirmation(
      player,
      {"batch-request-combinator.gui-drain-confirm", preview.target_count, preview.item_count},
      preview.scope_signature
    )
  else
    show_drain_confirmation(player, Util.localised_error(error_code, error_detail), nil)
  end
end

local NAVIGATION_EVENTS = {
  [Constants.GUI.NAV_CONFIGURATION] = INSPECTOR.CONFIGURATION,
  [Constants.GUI.NAV_BATCH] = INSPECTOR.BATCH,
  [Constants.GUI.NAV_MAINTENANCE] = INSPECTOR.MAINTENANCE,
  [Constants.GUI.NAV_DIAGNOSTICS] = INSPECTOR.DIAGNOSTICS,
  [Constants.GUI.NAV_TECHNICAL] = INSPECTOR.TECHNICAL,
}

function Gui.on_click(event)
  local element = event.element
  if not element or not element.valid then return end
  if element.name == Constants.GUI.CLOSE then
    Gui.close_player(event.player_index)
    return
  end
  local instance = instance_for_event(event)
  if not instance then return end
  local player = game.get_player(event.player_index)
  local requested_inspector = NAVIGATION_EVENTS[element.name]
  if requested_inspector then
    local previous_inspector = inspector_by_player[event.player_index]
    inspector_by_player[event.player_index] = previous_inspector == requested_inspector and nil or requested_inspector
    if previous_inspector == INSPECTOR.MAINTENANCE
      and inspector_by_player[event.player_index] ~= INSPECTOR.MAINTENANCE then
      hide_drain_confirmation(player)
    end
    if inspector_by_player[event.player_index] == INSPECTOR.MAINTENANCE then
      preview_drain(player, instance)
    end
    if inspector_by_player[event.player_index] == INSPECTOR.DIAGNOSTICS then
      capture_diagnostics(event.player_index, instance)
    end
  elseif element.name == Constants.GUI.TECHNICAL_BATCH then
    inspector_by_player[event.player_index] = INSPECTOR.BATCH
  elseif element.name == Constants.GUI.DIAGNOSTICS_REFRESH then
    capture_diagnostics(event.player_index, instance)
  elseif element.name == Constants.GUI.DIAGNOSTICS_PRINT then
    Debug.print(event.player_index)
  elseif element.name == Constants.GUI.DRAIN_CANCEL then
    hide_drain_confirmation(player)
    inspector_by_player[event.player_index] = nil
  elseif element.name == Constants.GUI.DRAIN_CONFIRM then
    local preview = drain_preview_by_player[event.player_index]
    local expected_scope_signature = preview and preview.scope_signature or nil
    local started, error_code, error_detail = StateMachine.start_drain(
      instance,
      expected_scope_signature
    )
    if not started and instance.state == Constants.STATE.ARMED then
      show_drain_confirmation(player, Util.localised_error(error_code, error_detail), nil)
      return
    end
    hide_drain_confirmation(player)
    inspector_by_player[event.player_index] = nil
  elseif element.name == Constants.GUI.DRAIN_STOP then
    StateMachine.stop_drain(instance)
  elseif element.name == Constants.GUI.ABORT then
    StateMachine.manual_abort(instance)
  elseif element.name == Constants.GUI.RETRY_TAIL then
    StateMachine.retry_tail(instance)
  else
    return
  end
  Gui.refresh_instance(instance)
end

function Gui.on_checked_changed(event)
  local element = event.element
  if not element or not element.valid then return end
  local instance = instance_for_event(event)
  if not instance or instance.state ~= Constants.STATE.ARMED then return end
  if element.name == Constants.GUI.AUTO_CLEANUP_AFTER_INTERRUPT then
    instance.auto_cleanup_after_interrupt = element.state == true
    Gui.refresh_instance(instance)
    return
  end
  if not element.state then return end
  local sign_modes = {
    [Constants.GUI.SIGN_ANY] = Constants.SIGN_MODE.ANY,
    [Constants.GUI.SIGN_POSITIVE] = Constants.SIGN_MODE.POSITIVE,
    [Constants.GUI.SIGN_NEGATIVE] = Constants.SIGN_MODE.NEGATIVE,
  }
  local input_modes = {
    [Constants.GUI.INPUT_FOLLOW] = Constants.INPUT_MODE.FOLLOW,
    [Constants.GUI.INPUT_SNAPSHOT] = Constants.INPUT_MODE.SNAPSHOT,
  }
  local tail_modes = {
    [Constants.GUI.TAIL_NONE] = Constants.TAIL_MODE.NO_TAIL,
    [Constants.GUI.TAIL_SINGLE] = Constants.TAIL_MODE.SINGLE,
    [Constants.GUI.TAIL_PARALLEL] = Constants.TAIL_MODE.PARALLEL,
  }
  if sign_modes[element.name] then instance.sign_mode = sign_modes[element.name] end
  if input_modes[element.name] then instance.input_mode = input_modes[element.name] end
  if tail_modes[element.name] then instance.tail_mode = tail_modes[element.name] end
  Gui.refresh_instance(instance)
end

function Gui.on_player_removed(event)
  inspector_by_player[event.player_index] = nil
  drain_preview_by_player[event.player_index] = nil
  diagnostics_by_player[event.player_index] = nil
  clear_player_registration(event.player_index)
end

function Gui.on_load()
  element_cache_by_player = {}
  inspector_by_player = {}
  drain_preview_by_player = {}
  diagnostics_by_player = {}
end

function Gui.restore_after_load()
  local player_indices = {}
  for player_index in pairs(Registry.root().gui_players) do
    player_indices[#player_indices + 1] = player_index
  end
  table.sort(player_indices)
  for _, player_index in ipairs(player_indices) do
    local player = game.get_player(player_index)
    local unit_number = Registry.root().gui_players[player_index]
    local instance = unit_number and Registry.instance(unit_number) or nil
    local frame = player and frame_for(player) or nil
    if player and player.valid and instance and frame and frame.valid then
      build(player, instance, true)
      Gui.refresh_player(player, instance)
    else
      Gui.close_player(player_index)
    end
  end
end

return Gui
