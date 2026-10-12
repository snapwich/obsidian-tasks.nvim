-- tests/unit/test_daily_note.lua
-- Plan D5 (group-top insert, step 2c): the daily-note resolver and the
-- `daily_note` option.
--
-- opts.daily_note:
--   nil      → default resolver: obsidian.nvim's daily_note_path when the
--              `Obsidian` global is set, else nil (feature off);
--   function → custom resolver `function(date) -> abs_path|nil`;
--   false    → feature disabled.
-- util/daily_note.resolve(date, opts) gives the absolute path or nil.

local daily = require("obsidian-tasks.util.daily_note")
local config = require("obsidian-tasks.config")

local function eq(actual, expected, msg)
  MiniTest.expect.equality(actual, expected, msg)
end

local DATE = os.time({ year = 2026, month = 10, day = 11, hour = 12 })

-- Stub obsidian.nvim: the `Obsidian` global and the obsidian.daily module.
-- daily_note_path returns an obsidian.Path-like object (tostring → path).
local saved = {}
local calls = {}

local function stub_obsidian(path_fn)
  _G.Obsidian = { dir = "/vault", opts = {} }
  package.loaded["obsidian.daily"] = {
    daily_note_path = function(dt)
      calls[#calls + 1] = dt
      local p = path_fn(dt)
      return setmetatable({}, {
        __tostring = function()
          return p
        end,
      }), "id"
    end,
  }
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved.obsidian = _G.Obsidian
      saved.daily = package.loaded["obsidian.daily"]
      calls = {}
    end,
    post_case = function()
      _G.Obsidian = saved.obsidian
      package.loaded["obsidian.daily"] = saved.daily
    end,
  },
})

-- ── default resolver ────────────────────────────────────────────────────────

T["resolver: obsidian.nvim present → its daily_note_path"] = function()
  stub_obsidian(function()
    return "/vault/daily/2026-10-11.md"
  end)
  eq(daily.resolve(DATE, {}), "/vault/daily/2026-10-11.md")
  eq(calls, { DATE })
end

T["resolver: obsidian.nvim absent (no Obsidian global) → nil"] = function()
  _G.Obsidian = nil
  -- Even a loadable obsidian.daily module is ignored without the global.
  package.loaded["obsidian.daily"] = {
    daily_note_path = function()
      error("must not be called")
    end,
  }
  eq(daily.resolve(DATE, {}), nil)
end

T["resolver: Obsidian global set but obsidian.daily not loadable → nil"] = function()
  _G.Obsidian = { opts = {} }
  package.loaded["obsidian.daily"] = nil
  local saved_preload = package.preload["obsidian.daily"]
  package.preload["obsidian.daily"] = function()
    error("no module")
  end
  local ok, res = pcall(daily.resolve, DATE, {})
  package.preload["obsidian.daily"] = saved_preload
  package.loaded["obsidian.daily"] = nil
  eq(ok, true)
  eq(res, nil)
end

T["resolver: daily_note_path errors → nil, no throw"] = function()
  stub_obsidian(function()
    error("daily notes date_format is required")
  end)
  local ok, res = pcall(daily.resolve, DATE, {})
  eq(ok, true)
  eq(res, nil)
end

T["resolver: default path is normalized"] = function()
  stub_obsidian(function()
    return "/vault//daily/./2026-10-11.md"
  end)
  eq(daily.resolve(DATE, {}), vim.fs.normalize("/vault//daily/./2026-10-11.md"))
end

T["resolver: date defaults to now"] = function()
  stub_obsidian(function()
    return "/vault/d.md"
  end)
  local before = os.time()
  daily.resolve(nil, {})
  eq(type(calls[1]), "number")
  eq(calls[1] >= before, true)
end

-- ── custom resolver ─────────────────────────────────────────────────────────

T["resolver: custom function gets the date and wins over obsidian.nvim"] = function()
  stub_obsidian(function()
    return "/vault/obsidian.md"
  end)
  local got
  local res = daily.resolve(DATE, {
    daily_note = function(date)
      got = date
      return "/notes/custom.md"
    end,
  })
  eq(res, "/notes/custom.md")
  eq(got, DATE)
  eq(#calls, 0)
end

T["resolver: custom function returning nil → nil"] = function()
  eq(
    daily.resolve(DATE, {
      daily_note = function()
        return nil
      end,
    }),
    nil
  )
end

T["resolver: custom function returning a non-string or '' → nil"] = function()
  eq(
    daily.resolve(DATE, {
      daily_note = function()
        return 42
      end,
    }),
    nil
  )
  eq(
    daily.resolve(DATE, {
      daily_note = function()
        return ""
      end,
    }),
    nil
  )
end

T["resolver: custom function that errors → nil + warn, no throw"] = function()
  local log = require("obsidian-tasks.log")
  local orig = log.warn
  local warned = {}
  log.warn = function(msg)
    warned[#warned + 1] = msg
  end
  local ok, res = pcall(daily.resolve, DATE, {
    daily_note = function()
      error("boom")
    end,
  })
  log.warn = orig
  eq(ok, true)
  eq(res, nil)
  eq(#warned, 1)
  eq(warned[1]:find("boom", 1, true) ~= nil, true)
end

-- ── disabled ────────────────────────────────────────────────────────────────

T["resolver: daily_note = false disables it, even with obsidian.nvim"] = function()
  stub_obsidian(function()
    return "/vault/d.md"
  end)
  eq(daily.resolve(DATE, { daily_note = false }), nil)
  eq(#calls, 0)
end

T["resolver: opts nil → uses the resolved plugin opts"] = function()
  _G.Obsidian = nil
  local ot = require("obsidian-tasks")
  local saved_opts = ot.opts
  ot.opts = config.merge({
    daily_note = function()
      return "/from/plugin/opts.md"
    end,
  })
  local res = daily.resolve(DATE)
  ot.opts = saved_opts
  eq(res, "/from/plugin/opts.md")
end

-- ── config ──────────────────────────────────────────────────────────────────

T["config: daily_note defaults to nil"] = function()
  eq(config.merge({}).daily_note, nil)
end

T["config: daily_note accepts a function and false"] = function()
  local fn = function()
    return nil
  end
  eq(config.merge({ daily_note = fn }).daily_note, fn)
  eq(config.merge({ daily_note = false }).daily_note, false)
end

T["config: daily_note rejects true and strings"] = function()
  MiniTest.expect.error(function()
    config.merge({ daily_note = true })
  end, "daily_note")
  MiniTest.expect.error(function()
    config.merge({ daily_note = "daily/today.md" })
  end, "daily_note")
end

T["config: daily_note is a known key (no unknown-key warning)"] = function()
  local log = require("obsidian-tasks.log")
  local orig = log.warn
  local warned = {}
  log.warn = function(msg)
    warned[#warned + 1] = msg
  end
  config.merge({ daily_note = false })
  log.warn = orig
  eq(warned, {})
end

return T
