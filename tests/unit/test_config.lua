-- tests/unit/test_config.lua
-- Unit tests for config.lua: defaults, validation, merge, unknown-key warning.

local T = MiniTest.new_set()
local config = require("obsidian-tasks.config")

-- ── defaults ────────────────────────────────────────────────────────────────

T["defaults round-trip: merge({}) returns defaults"] = function()
  local merged = config.merge({})
  MiniTest.expect.equality(merged.auto_render, true)
  MiniTest.expect.equality(merged.watcher, true)
  MiniTest.expect.equality(merged.watcher_debounce_ms, 300)
  MiniTest.expect.equality(merged.done_date_format, "%Y-%m-%d")
  MiniTest.expect.equality(merged.done_date_tz, "local")
  MiniTest.expect.equality(merged.hide_query_metadata, false)
  MiniTest.expect.equality(merged.log_level, "info")
  MiniTest.expect.equality(merged.max_file_bytes, 1048576)
  MiniTest.expect.equality(merged.blink_cmp.enabled, true)
  MiniTest.expect.equality(merged.date_input.natural_language, true)
  MiniTest.expect.equality(type(merged.date_input.suggestions), "table")
end

T["defaults: global_filter and capture_file are nil"] = function()
  local merged = config.merge({})
  MiniTest.expect.equality(merged.global_filter, nil)
  MiniTest.expect.equality(merged.capture_file, nil)
  MiniTest.expect.equality(merged.statuses, nil)
end

-- ── user overrides ───────────────────────────────────────────────────────────

T["user override: scalar fields"] = function()
  local merged = config.merge({
    auto_render = false,
    watcher_debounce_ms = 500,
    done_date_format = "%d/%m/%Y",
    log_level = "debug",
    max_file_bytes = 2097152,
  })
  MiniTest.expect.equality(merged.auto_render, false)
  MiniTest.expect.equality(merged.watcher_debounce_ms, 500)
  MiniTest.expect.equality(merged.done_date_format, "%d/%m/%Y")
  MiniTest.expect.equality(merged.log_level, "debug")
  MiniTest.expect.equality(merged.max_file_bytes, 2097152)
end

T["user override: global_filter and capture_file strings"] = function()
  local merged = config.merge({ global_filter = "#task", capture_file = "inbox.md" })
  MiniTest.expect.equality(merged.global_filter, "#task")
  MiniTest.expect.equality(merged.capture_file, "inbox.md")
end

-- ── deep-merge of nested tables ──────────────────────────────────────────────

T["deep-merge: blink_cmp = { enabled = false } does not nuke date_input"] = function()
  local merged = config.merge({ blink_cmp = { enabled = false } })
  MiniTest.expect.equality(merged.blink_cmp.enabled, false)
  -- date_input must still be present with its defaults
  MiniTest.expect.equality(merged.date_input.natural_language, true)
  MiniTest.expect.equality(type(merged.date_input.suggestions), "table")
end

T["deep-merge: date_input partial override preserves other date_input keys"] = function()
  local merged = config.merge({ date_input = { natural_language = false } })
  MiniTest.expect.equality(merged.date_input.natural_language, false)
  -- suggestions still present from defaults
  MiniTest.expect.equality(type(merged.date_input.suggestions), "table")
  MiniTest.expect.equality(#merged.date_input.suggestions > 0, true)
end

-- ── validation errors ────────────────────────────────────────────────────────

T["validate: auto_render must be boolean"] = function()
  MiniTest.expect.error(function()
    config.merge({ auto_render = "yes" })
  end, "auto_render")
end

T["validate: watcher must be boolean"] = function()
  MiniTest.expect.error(function()
    config.merge({ watcher = 1 })
  end, "watcher")
end

T["validate: watcher_debounce_ms must be positive integer"] = function()
  MiniTest.expect.error(function()
    config.merge({ watcher_debounce_ms = 0 })
  end, "watcher_debounce_ms")
  MiniTest.expect.error(function()
    config.merge({ watcher_debounce_ms = -5 })
  end, "watcher_debounce_ms")
  MiniTest.expect.error(function()
    config.merge({ watcher_debounce_ms = 1.5 })
  end, "watcher_debounce_ms")
  MiniTest.expect.error(function()
    config.merge({ watcher_debounce_ms = "fast" })
  end, "watcher_debounce_ms")
end

T["validate: done_date_format must be string"] = function()
  MiniTest.expect.error(function()
    config.merge({ done_date_format = 42 })
  end, "done_date_format")
end

T["validate: done_date_format must contain % (strftime pattern)"] = function()
  MiniTest.expect.error(function()
    config.merge({ done_date_format = "YYYY-MM-DD" })
  end, "done_date_format")
end

T["validate: done_date_format accepts valid strftime strings"] = function()
  MiniTest.expect.no_error(function()
    config.merge({ done_date_format = "%Y/%m/%d" })
  end)
end

T["validate: log_level must be one of allowed values"] = function()
  MiniTest.expect.error(function()
    config.merge({ log_level = "verbose" })
  end, "log_level")
  MiniTest.expect.error(function()
    config.merge({ log_level = 0 })
  end, "log_level")
end

T["validate: max_file_bytes must be positive integer"] = function()
  MiniTest.expect.error(function()
    config.merge({ max_file_bytes = -1 })
  end, "max_file_bytes")
  MiniTest.expect.error(function()
    config.merge({ max_file_bytes = 0 })
  end, "max_file_bytes")
  MiniTest.expect.error(function()
    config.merge({ max_file_bytes = 1.5 })
  end, "max_file_bytes")
end

T["validate: global_filter nil is valid"] = function()
  MiniTest.expect.no_error(function()
    config.merge({ global_filter = nil })
  end)
end

T["validate: global_filter non-string is invalid"] = function()
  MiniTest.expect.error(function()
    config.merge({ global_filter = true })
  end, "global_filter")
end

T["validate: statuses nil is valid"] = function()
  MiniTest.expect.no_error(function()
    config.merge({ statuses = nil })
  end)
end

T["validate: statuses table is valid"] = function()
  MiniTest.expect.no_error(function()
    config.merge({ statuses = {} })
  end)
end

T["validate: statuses non-table/non-nil is invalid"] = function()
  MiniTest.expect.error(function()
    config.merge({ statuses = "todo" })
  end, "statuses")
end

-- ── unknown-key warning ──────────────────────────────────────────────────────

T["unknown key emits warning via log.warn and does not error"] = function()
  local warnings = {}
  local log = require("obsidian-tasks.log")
  local original_warn = log.warn
  log.warn = function(msg)
    table.insert(warnings, msg)
  end

  local ok, err = pcall(function()
    config.merge({ totally_unknown_key = "surprise" })
  end)

  log.warn = original_warn

  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(#warnings > 0, true)
  -- warning message should mention the key
  local found = false
  for _, w in ipairs(warnings) do
    if w:find("totally_unknown_key") then
      found = true
      break
    end
  end
  MiniTest.expect.equality(found, true)
end

return T
