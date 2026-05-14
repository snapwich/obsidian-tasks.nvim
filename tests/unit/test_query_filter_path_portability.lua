-- tests/unit/test_query_filter_path_portability.lua
-- Regression test for the obsidian-app vs obsidian-tasks.nvim divergence on
-- `path includes /<dir>` queries.
--
-- Upstream's `task.path` is the vault-relative path (e.g. `daily/2024-03-15.md`).
-- Our index stores absolute paths (e.g. `/home/user/MyVault/daily/...`).
-- Without a workspace-root strip, `path includes /daily` matches our absolute
-- path's `/daily` substring but does NOT match upstream's `daily/2024-03-15.md`.
--
-- Run.run() must strip the workspace_root prefix before passing the path to
-- filter / sort / group so query results match Obsidian's behaviour.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local run_mod = require("obsidian-tasks.query.run")

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

local function make_index(items)
  return {
    tasks_in = function(path_filter)
      local i = 0
      return function()
        while true do
          i = i + 1
          local item = items[i]
          if not item then
            return nil
          end
          if path_filter == nil or path_filter(item.path) then
            return item.task, item.path
          end
        end
      end
    end,
  }
end

local function run(query, items, workspace_root)
  return run_mod.run(qp.parse(query), make_index(items), workspace_root)
end

local TASK = pt("- [ ] Task #task")
local WS = "/home/user/MyVault"
local PATH_DAILY = WS .. "/daily/2024-03-15.md"
local PATH_PROJ = WS .. "/projects/web.md"

-- ── `path includes /daily` should NOT match a vault-relative `daily/...` ──

T["path includes /daily: does NOT match (upstream parity)"] = function()
  local r = run("path includes /daily", { { task = TASK, path = PATH_DAILY } }, WS)
  eq(r.total, 0)
end

T["path includes daily/: matches (no leading slash)"] = function()
  local r = run("path includes daily/", { { task = TASK, path = PATH_DAILY } }, WS)
  eq(r.total, 1)
end

T["path includes daily: matches (substring)"] = function()
  local r = run("path includes daily", { { task = TASK, path = PATH_DAILY } }, WS)
  eq(r.total, 1)
end

T["path includes /home/user: does NOT match (workspace prefix stripped)"] = function()
  -- Critical for portability: a user's local vault path must not leak into query results.
  local r = run("path includes /home/user", { { task = TASK, path = PATH_DAILY } }, WS)
  eq(r.total, 0)
end

T["path includes projects/web: matches deep-nested directory portion"] = function()
  local r = run("path includes projects/web", { { task = TASK, path = PATH_PROJ } }, WS)
  eq(r.total, 1)
end

-- ── folder field: vault-relative semantics ────────────────────────────────

T["folder includes daily: matches (folder = vault-relative dir portion)"] = function()
  local r = run("folder includes daily", { { task = TASK, path = PATH_DAILY } }, WS)
  eq(r.total, 1)
end

T["folder includes /home: does NOT match (workspace prefix stripped)"] = function()
  local r = run("folder includes /home", { { task = TASK, path = PATH_DAILY } }, WS)
  eq(r.total, 0)
end

-- ── root field: vault-relative semantics ──────────────────────────────────

T["root includes daily: matches (root = first directory below vault)"] = function()
  local r = run("root includes daily", { { task = TASK, path = PATH_DAILY } }, WS)
  eq(r.total, 1)
end

T["root: file directly in vault root has empty-string root"] = function()
  local path = WS .. "/note.md"
  local r = run("root includes anything", { { task = TASK, path = path } }, WS)
  eq(r.total, 0)
end

T["root includes home: does NOT match (workspace prefix stripped)"] = function()
  local r = run("root includes home", { { task = TASK, path = PATH_DAILY } }, WS)
  eq(r.total, 0)
end

return T
