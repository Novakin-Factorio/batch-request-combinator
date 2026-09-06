local Constants = {}

Constants.MOD_NAME = "batch-request-combinator"
Constants.ENTITY_NAME = "batch-request-combinator"
Constants.OUTPUT_ENTITY_NAME = "batch-request-combinator-output"
Constants.SCHEMA_VERSION = 5
Constants.BLUEPRINT_SCHEMA_VERSION = 3

Constants.DRAIN_STALL_TICKS = 300
Constants.DRAIN_DIAGNOSTIC_INTERVAL_TICKS = 120
Constants.DEFERRED_RETRY_INTERVAL_TICKS = 60

Constants.DRAIN_WAIT_REASON = {
  NETWORK = "network",
  ROBOTS = "robots",
  AVAILABLE_ROBOTS = "available-robots",
  DESTINATION = "destination",
  MOVEMENT = "movement",
}

Constants.SETTING_POLL_INTERVAL = "batch-request-combinator-poll-interval"
Constants.SETTING_DEBUG = "batch-request-combinator-debug"

Constants.STATE = {
  ARMED = "armed",
  DRAINING = "draining",
  REQUESTING = "requesting",
  SETTLING = "settling",
  READY = "ready",
  COMPLETE = "complete",
  RESET = "reset",
  ERROR = "error",
  ABORTED = "aborted",
}

Constants.INPUT_MODE = {
  FOLLOW = "follow",
  SNAPSHOT = "snapshot",
}

Constants.INPUT_MODE_ORDER = {
  Constants.INPUT_MODE.FOLLOW,
  Constants.INPUT_MODE.SNAPSHOT,
}

Constants.TAIL_MODE = {
  NO_TAIL = "no-tail",
  SINGLE = "single",
  PARALLEL = "parallel",
}

Constants.TAIL_MODE_ORDER = {
  Constants.TAIL_MODE.NO_TAIL,
  Constants.TAIL_MODE.SINGLE,
  Constants.TAIL_MODE.PARALLEL,
}

Constants.SIGN_MODE = {
  ANY = "any",
  POSITIVE = "positive",
  NEGATIVE = "negative",
}

Constants.SIGN_MODE_ORDER = {
  Constants.SIGN_MODE.ANY,
  Constants.SIGN_MODE.POSITIVE,
  Constants.SIGN_MODE.NEGATIVE,
}

Constants.STATUS_SIGNAL = {
  armed = "batch-request-combinator-armed",
  requesting = "batch-request-combinator-requesting",
  settling = "batch-request-combinator-settling",
  ready = "batch-request-combinator-ready",
  complete = "batch-request-combinator-complete",
  error = "batch-request-combinator-error",
  aborted = "batch-request-combinator-aborted",
  warning = "batch-request-combinator-warning",
}

Constants.ERROR = {
  NO_TARGETS = 1,
  TARGET_CONFLICT = 2,
  TARGET_INCOMPATIBLE = 3,
  CONTAMINATION = 4,
  EXCESS_ITEMS = 5,
  INSUFFICIENT_CAPACITY = 6,
  INSUFFICIENT_FILTERS = 7,
  REQUEST_WRITE_FAILED = 8,
  TARGET_LOST = 9,
  DELIVERY_MISMATCH = 10,
  INSERTER_NOT_EMPTY = 11,
  EXTERNAL_REQUEST = 12,
  EXTERNAL_DELIVERY = 13,
  OUTPUT_UNAVAILABLE = 14,
  INVALID_QUANTITY = 15,
  SECTION_LOST = 16,
  INTERNAL = 17,
  INACCESSIBLE_ITEMS = 18,
  TAIL_PLAN_UNSAFE = 19,
  INSERTER_CONFIGURATION = 20,
  INSERTER_OWNERSHIP = 21,
  TAIL_RESTORE_FAILED = 22,
  DRAIN_WRITE_FAILED = 23,
  DRAIN_RESTORE_FAILED = 24,
  DRAIN_INPUT_ACTIVE = 25,
  DRAIN_SCOPE_CHANGED = 26,
  INSERTER_SETUP_FAILED = 27,
  INSERTER_SETUP_SCOPE_CHANGED = 28,
  INSERTER_SETUP_INPUT_ACTIVE = 29,
}

Constants.ERROR_LOCALE = {
  [Constants.ERROR.NO_TARGETS] = "batch-request-combinator-error.no-targets",
  [Constants.ERROR.TARGET_CONFLICT] = "batch-request-combinator-error.target-conflict",
  [Constants.ERROR.TARGET_INCOMPATIBLE] = "batch-request-combinator-error.target-incompatible",
  [Constants.ERROR.CONTAMINATION] = "batch-request-combinator-error.contamination",
  [Constants.ERROR.EXCESS_ITEMS] = "batch-request-combinator-error.excess-items",
  [Constants.ERROR.INSUFFICIENT_CAPACITY] = "batch-request-combinator-error.insufficient-capacity",
  [Constants.ERROR.INSUFFICIENT_FILTERS] = "batch-request-combinator-error.insufficient-filters",
  [Constants.ERROR.REQUEST_WRITE_FAILED] = "batch-request-combinator-error.request-write-failed",
  [Constants.ERROR.TARGET_LOST] = "batch-request-combinator-error.target-lost",
  [Constants.ERROR.DELIVERY_MISMATCH] = "batch-request-combinator-error.delivery-mismatch",
  [Constants.ERROR.INSERTER_NOT_EMPTY] = "batch-request-combinator-error.inserter-not-empty",
  [Constants.ERROR.EXTERNAL_REQUEST] = "batch-request-combinator-error.external-request",
  [Constants.ERROR.EXTERNAL_DELIVERY] = "batch-request-combinator-error.external-delivery",
  [Constants.ERROR.OUTPUT_UNAVAILABLE] = "batch-request-combinator-error.output-unavailable",
  [Constants.ERROR.INVALID_QUANTITY] = "batch-request-combinator-error.invalid-quantity",
  [Constants.ERROR.SECTION_LOST] = "batch-request-combinator-error.section-lost",
  [Constants.ERROR.INTERNAL] = "batch-request-combinator-error.internal",
  [Constants.ERROR.INACCESSIBLE_ITEMS] = "batch-request-combinator-error.inaccessible-items",
  [Constants.ERROR.TAIL_PLAN_UNSAFE] = "batch-request-combinator-error.tail-plan-unsafe",
  [Constants.ERROR.INSERTER_CONFIGURATION] = "batch-request-combinator-error.inserter-configuration",
  [Constants.ERROR.INSERTER_OWNERSHIP] = "batch-request-combinator-error.inserter-ownership",
  [Constants.ERROR.TAIL_RESTORE_FAILED] = "batch-request-combinator-error.tail-restore-failed",
  [Constants.ERROR.DRAIN_WRITE_FAILED] = "batch-request-combinator-error.drain-write-failed",
  [Constants.ERROR.DRAIN_RESTORE_FAILED] = "batch-request-combinator-error.drain-restore-failed",
  [Constants.ERROR.DRAIN_INPUT_ACTIVE] = "batch-request-combinator-error.drain-input-active",
  [Constants.ERROR.DRAIN_SCOPE_CHANGED] = "batch-request-combinator-error.drain-scope-changed",
  [Constants.ERROR.INSERTER_SETUP_FAILED] = "batch-request-combinator-error.inserter-setup-failed",
  [Constants.ERROR.INSERTER_SETUP_SCOPE_CHANGED] = "batch-request-combinator-error.inserter-setup-scope-changed",
  [Constants.ERROR.INSERTER_SETUP_INPUT_ACTIVE] = "batch-request-combinator-error.inserter-setup-input-active",
}

Constants.GUI = {
  FRAME = "batch_request_combinator_frame",
  TITLEBAR = "batch_request_combinator_titlebar",
  BODY = "batch_request_combinator_body",
  SETTINGS_GROUPS = "batch_request_combinator_settings_groups",
  ITEMS = "batch_request_combinator_items",
  ALLOCATIONS = "batch_request_combinator_allocations",
  CLOSE = "batch_request_combinator_close",
  ABORT = "batch_request_combinator_abort",
  STATUS = "batch_request_combinator_status",
  STATUS_ICON = "batch_request_combinator_status_icon",
  STATUS_TEXT = "batch_request_combinator_status_text",
  STATUS_DETAIL = "batch_request_combinator_status_detail",
  CONDITION_ROW = "batch_request_combinator_condition_row",
  INFO_ROW = "batch_request_combinator_info_row",
  MODE_SUMMARY = "batch_request_combinator_mode_summary",
  FACTS = "batch_request_combinator_facts",
  PROGRESS_SECTION = "batch_request_combinator_progress_section",
  PROGRESS_LABEL = "batch_request_combinator_progress_label",
  PROGRESS_VALUE = "batch_request_combinator_progress_value",
  PROGRESS_BAR = "batch_request_combinator_progress_bar",
  WARNING_ROW = "batch_request_combinator_warning_row",
  SIGN_ANY = "batch_request_combinator_sign_any",
  SIGN_POSITIVE = "batch_request_combinator_sign_positive",
  SIGN_NEGATIVE = "batch_request_combinator_sign_negative",
  INPUT_FOLLOW = "batch_request_combinator_input_follow",
  INPUT_SNAPSHOT = "batch_request_combinator_input_snapshot",
  TAIL_NONE = "batch_request_combinator_tail_none",
  TAIL_SINGLE = "batch_request_combinator_tail_single",
  TAIL_PARALLEL = "batch_request_combinator_tail_parallel",
  AUTO_CLEANUP_AFTER_INTERRUPT = "batch_request_combinator_auto_cleanup_after_interrupt",
  NAVIGATION = "batch_request_combinator_navigation",
  NAV_CONFIGURATION = "batch_request_combinator_navigation_configuration",
  NAV_BATCH = "batch_request_combinator_navigation_batch",
  NAV_MAINTENANCE = "batch_request_combinator_navigation_maintenance",
  NAV_DIAGNOSTICS = "batch_request_combinator_navigation_diagnostics",
  NAV_TECHNICAL = "batch_request_combinator_navigation_technical",
  INSPECTOR_HOST = "batch_request_combinator_inspector_host",
  INSPECTOR_TITLE = "batch_request_combinator_inspector_title",
  CONFIGURATION_PANEL = "batch_request_combinator_configuration_panel",
  CONFIGURATION_LOCKED = "batch_request_combinator_configuration_locked",
  BATCH_PANEL = "batch_request_combinator_batch_panel",
  MAINTENANCE_PANEL = "batch_request_combinator_maintenance_panel",
  DIAGNOSTICS_PANEL = "batch_request_combinator_diagnostics_panel",
  DIAGNOSTIC_ENTITY = "batch_request_combinator_diagnostic_entity",
  DIAGNOSTIC_PRIMARY = "batch_request_combinator_diagnostic_primary",
  DIAGNOSTIC_WARNING = "batch_request_combinator_diagnostic_warning",
  DIAGNOSTIC_SETTINGS = "batch_request_combinator_diagnostic_settings",
  DIAGNOSTIC_SNAPSHOT = "batch_request_combinator_diagnostic_snapshot",
  DIAGNOSTIC_COUNTS = "batch_request_combinator_diagnostic_counts",
  DIAGNOSTIC_STATES = "batch_request_combinator_diagnostic_states",
  DIAGNOSTIC_PROCESSED = "batch_request_combinator_diagnostic_processed",
  DIAGNOSTIC_PROFILER = "batch_request_combinator_diagnostic_profiler",
  DIAGNOSTICS_REFRESH = "batch_request_combinator_diagnostics_refresh",
  DIAGNOSTICS_PRINT = "batch_request_combinator_diagnostics_print",
  TECHNICAL_PANEL = "batch_request_combinator_technical_panel",
  TECHNICAL_ERROR = "batch_request_combinator_technical_error",
  TECHNICAL_DETAIL = "batch_request_combinator_technical_detail",
  TECHNICAL_GUIDANCE = "batch_request_combinator_technical_guidance",
  TECHNICAL_OUTPUT = "batch_request_combinator_technical_output",
  TECHNICAL_BATCH = "batch_request_combinator_technical_batch",
  ITEMS_SECTION = "batch_request_combinator_items_section",
  ITEMS_HEADING = "batch_request_combinator_items_heading",
  ALLOCATIONS_SECTION = "batch_request_combinator_allocations_section",
  ALLOCATIONS_HEADING = "batch_request_combinator_allocations_heading",
  RETRY_TAIL = "batch_request_combinator_retry_tail",
  DRAIN_CONFIRMATION = "batch_request_combinator_drain_confirmation",
  DRAIN_CONFIRMATION_TEXT = "batch_request_combinator_drain_confirmation_text",
  DRAIN_CONFIRM = "batch_request_combinator_drain_confirm",
  DRAIN_CANCEL = "batch_request_combinator_drain_cancel",
  DRAIN_STOP = "batch_request_combinator_drain_stop",
  ACTION_BAR = "batch_request_combinator_action_bar",
  ACTIONS = "batch_request_combinator_actions",
  INSERTER_SETUP = "batch_request_combinator_inserter_setup",
  INSERTER_SETUP_ERROR = "batch_request_combinator_inserter_setup_error",
  INSERTER_SETUP_DIALOG = "batch_request_combinator_inserter_setup_dialog",
  INSERTER_SETUP_DIALOG_CLOSE = "batch_request_combinator_inserter_setup_dialog_close",
  INSERTER_SETUP_CONFIRM = "batch_request_combinator_inserter_setup_confirm",
  INSERTER_SETUP_CANCEL = "batch_request_combinator_inserter_setup_cancel",
}

Constants.BLUEPRINT_SIGN_MODE_TAG = "batch-request-combinator-sign-mode"
Constants.BLUEPRINT_SCHEMA_TAG = "batch-request-combinator-config-version"
Constants.BLUEPRINT_INPUT_MODE_TAG = "batch-request-combinator-input-mode"
Constants.BLUEPRINT_TAIL_MODE_TAG = "batch-request-combinator-tail-mode"
Constants.BLUEPRINT_AUTO_CLEANUP_AFTER_INTERRUPT_TAG = "batch-request-combinator-auto-cleanup-after-interrupt"
Constants.TAIL_MAX_ATTEMPTS = 3
Constants.KEY_SEPARATOR = "\31"
Constants.SIGNATURE_SEPARATOR = "\30"
Constants.MAX_REQUEST_VALUE = 2147483647

return Constants
