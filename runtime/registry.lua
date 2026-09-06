local Constants = require("runtime.constants")

local Registry = {}
local cached_root
local EMPTY_BUCKET = {}

local function poll_interval()
  local setting = settings.global[Constants.SETTING_POLL_INTERVAL]
  return setting and setting.value or 12
end

function Registry.ensure_storage()
  storage.batch_request_combinator = storage.batch_request_combinator or {}
  local root = storage.batch_request_combinator
  root.schema_version = root.schema_version or Constants.SCHEMA_VERSION
  root.instances = root.instances or {}
  root.buckets = root.buckets or {}
  root.bucket_positions = root.bucket_positions or {}
  root.chest_owners = root.chest_owners or {}
  root.inserter_owners = root.inserter_owners or {}
  root.temporary_overrides = root.temporary_overrides or {}
  root.override_tombstones = root.override_tombstones or {}
  root.destroyed = root.destroyed or {}
  root.active_batches = root.active_batches or {}
  root.gui_players = root.gui_players or {}
  root.open_gui_instances = root.open_gui_instances or {}
  root.cleanup_tombstones = root.cleanup_tombstones or {}
  root.cleanup_order = root.cleanup_order or {}
  root.drain_tombstones = root.drain_tombstones or {}
  root.drain_order = root.drain_order or {}
  root.debug = root.debug or {bucket_ticks = 0, processed = 0, maximum = 0}
  root.poll_interval = root.poll_interval or poll_interval()
  cached_root = root
  return root
end

function Registry.root()
  local root = storage.batch_request_combinator
  if cached_root and cached_root == root then return cached_root end
  if root then
    cached_root = root
    return root
  end
  return Registry.ensure_storage()
end

local function bucket_for(root, unit_number)
  return (unit_number % root.poll_interval) + 1
end

local function add_to_bucket(root, unit_number)
  local bucket_index = bucket_for(root, unit_number)
  local bucket = root.buckets[bucket_index]
  if not bucket then
    bucket = {}
    root.buckets[bucket_index] = bucket
  end
  if not root.bucket_positions[unit_number] then
    bucket[#bucket + 1] = unit_number
    root.bucket_positions[unit_number] = {bucket = bucket_index, index = #bucket}
  end
end

local function remove_from_bucket(root, unit_number)
  local position = root.bucket_positions[unit_number]
  if not position then return end
  local bucket = root.buckets[position.bucket]
  if bucket then
    table.remove(bucket, position.index)
    for index = position.index, #bucket do
      root.bucket_positions[bucket[index]].index = index
    end
  end
  root.bucket_positions[unit_number] = nil
end

function Registry.remove_stale_bucket_entry(unit_number)
  local root = Registry.ensure_storage()
  if root.bucket_positions[unit_number] then
    remove_from_bucket(root, unit_number)
    return
  end
  for bucket_index, bucket in pairs(root.buckets) do
    for index = #bucket, 1, -1 do
      if bucket[index] == unit_number then table.remove(bucket, index) end
    end
    for index, current_unit in ipairs(bucket) do
      root.bucket_positions[current_unit] = {bucket = bucket_index, index = index}
    end
  end
end

function Registry.add(entity, configuration)
  local root = Registry.ensure_storage()
  local unit_number = entity.unit_number
  local sign_mode = type(configuration) == "table" and configuration.sign_mode or configuration
  local input_mode = type(configuration) == "table" and configuration.input_mode or nil
  local tail_mode = type(configuration) == "table" and configuration.tail_mode or nil
  local auto_cleanup_after_interrupt
  if type(configuration) == "table" then
    auto_cleanup_after_interrupt = configuration.auto_cleanup_after_interrupt
  end
  local instance = root.instances[unit_number]
  if instance then
    instance.entity = entity
    if sign_mode then instance.sign_mode = sign_mode end
    if input_mode then instance.input_mode = input_mode end
    if tail_mode then instance.tail_mode = tail_mode end
    if type(auto_cleanup_after_interrupt) == "boolean" then
      instance.auto_cleanup_after_interrupt = auto_cleanup_after_interrupt
    end
    add_to_bucket(root, unit_number)
    return instance, false
  end

  instance = {
    unit_number = unit_number,
    entity = entity,
    state = Constants.STATE.ARMED,
    sign_mode = sign_mode or Constants.SIGN_MODE.ANY,
    input_mode = input_mode or Constants.INPUT_MODE.FOLLOW,
    tail_mode = tail_mode or Constants.TAIL_MODE.PARALLEL,
    auto_cleanup_after_interrupt = auto_cleanup_after_interrupt == true,
    requests_started = false,
    captured = {},
    captured_total = 0,
    captured_signature = "",
    plan_revision = 0,
    targets = {},
    monitored_inserters = {},
    inserters = {},
    drain_targets = {},
    drain_initial_total = 0,
    drain_remaining_total = 0,
    drain_pending_deliveries = 0,
    drain_last_remaining_total = 0,
    drain_last_progress_tick = nil,
    drain_last_diagnostic_tick = nil,
    drain_wait_reason = nil,
    drain_diagnostic_cursor = 1,
    drain_input_observed = false,
    drain_restore_blocked = false,
    warning_input_changed = false,
    error_code = nil,
    error_detail = nil,
    ready_counts = nil,
    cleanup_complete = false,
    owner_anchor = {
      surface_index = entity.surface.index,
      force_index = entity.force.index,
      x = entity.position.x,
      y = entity.position.y,
    },
  }
  root.instances[unit_number] = instance
  add_to_bucket(root, unit_number)
  local registration = script.register_on_object_destroyed(entity)
  instance.destroy_registration = registration
  root.destroyed[registration] = {kind = "combinator", owner = unit_number}
  return instance, true
end

function Registry.remove(instance)
  local root = Registry.ensure_storage()
  remove_from_bucket(root, instance.unit_number)
  root.instances[instance.unit_number] = nil
  root.active_batches[instance.unit_number] = nil
  root.open_gui_instances[instance.unit_number] = nil
  if instance.destroy_registration then root.destroyed[instance.destroy_registration] = nil end
  if instance.helper_destroy_registration then root.destroyed[instance.helper_destroy_registration] = nil end
end

function Registry.set_active(instance, active)
  local root = Registry.ensure_storage()
  root.active_batches[instance.unit_number] = active and true or nil
end

function Registry.rebuild_buckets()
  local root = Registry.ensure_storage()
  root.poll_interval = poll_interval()
  root.buckets = {}
  root.bucket_positions = {}
  local units = {}
  for unit_number in pairs(root.instances) do units[#units + 1] = unit_number end
  table.sort(units)
  for _, unit_number in ipairs(units) do add_to_bucket(root, unit_number) end
end

function Registry.bucket_for_tick(tick)
  local root = Registry.root()
  local index = (tick % root.poll_interval) + 1
  return root.buckets[index] or EMPTY_BUCKET
end

function Registry.instance(unit_number)
  return Registry.ensure_storage().instances[unit_number]
end

function Registry.destroy_record(registration_number)
  return Registry.ensure_storage().destroyed[registration_number]
end

function Registry.clear_destroy_record(registration_number)
  Registry.ensure_storage().destroyed[registration_number] = nil
end

return Registry
