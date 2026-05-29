-- tests/unit/test_health.lua
-- Unit tests for health.lua. Replaces vim.health with a capturing stub so we can
-- assert which OK/INFO/ERROR lines :checkhealth obsidian-tasks would emit.

local T = MiniTest.new_set()

--- Run health.check() with a stubbed vim.health, returning captured calls.
--- @return table { start = {...}, ok = {...}, info = {...}, error = {...}, warn = {...} }
local function capture_check()
  local calls = { start = {}, ok = {}, info = {}, error = {}, warn = {} }
  local orig = vim.health
  vim.health = {
    start = function(s)
      calls.start[#calls.start + 1] = s
    end,
    ok = function(s)
      calls.ok[#calls.ok + 1] = s
    end,
    info = function(s)
      calls.info[#calls.info + 1] = s
    end,
    warn = function(s)
      calls.warn[#calls.warn + 1] = s
    end,
    error = function(s, _adv)
      calls.error[#calls.error + 1] = s
    end,
  }
  package.loaded["obsidian-tasks.health"] = nil
  require("obsidian-tasks.health").check()
  vim.health = orig
  return calls
end

--- True if any string in `list` contains `needle`.
local function any_contains(list, needle)
  for _, s in ipairs(list) do
    if type(s) == "string" and s:find(needle, 1, true) then
      return true
    end
  end
  return false
end

T["check: starts an obsidian-tasks section"] = function()
  local calls = capture_check()
  MiniTest.expect.equality(any_contains(calls.start, "obsidian-tasks"), true)
end

T["check: reports rg OK when present"] = function()
  -- rg is available in the test environment.
  local calls = capture_check()
  MiniTest.expect.equality(any_contains(calls.ok, "ripgrep"), true)
  MiniTest.expect.equality(any_contains(calls.error, "ripgrep"), false)
end

T["check: reports rg ERROR when missing"] = function()
  vim.fn.executable = function(name)
    if name == "rg" then
      return 0
    end
    return 1
  end
  local calls = capture_check()
  vim.fn.executable = nil -- restore builtin via __index

  MiniTest.expect.equality(any_contains(calls.error, "ripgrep"), true)
end

T["check: emits an INFO line for each optional integration"] = function()
  local calls = capture_check()
  MiniTest.expect.equality(any_contains(calls.info, "obsidian.nvim"), true)
  MiniTest.expect.equality(any_contains(calls.info, "blink.cmp"), true)
end

return T
