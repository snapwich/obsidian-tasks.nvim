-- tests/integration_real/test_same_buffer_toggle.lua
-- Real-deps regression tests for the same-buffer dashboard case: a file
-- contains both task source lines AND a ```tasks block that queries them.
-- Toggling a rendered row must mutate the source row inside the same buffer
-- WITHOUT clobbering the rendered region or leaving disk/buffer/index out
-- of sync.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

--- Write *lines* to a fresh file in the fixture vault; return its path.
local function make_vault_file(lines, name)
  local path = fixture_vault .. "/" .. name
  vim.fn.writefile(lines, path)
  return path
end

local function read_disk(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

-- ── apply_source_edit dashboard branch round-trip ────────────────────────────

T["same-buffer toggle: disk + buffer + index all synchronized after edit"] = function()
  local path = make_vault_file({
    "# repro",
    "",
    "- [ ] tA #task 📅 2026-05-20",
    "- [ ] tB #task 📅 2026-05-21",
    "",
    "```tasks",
    "not done",
    "sort by due",
    "```",
  }, "_samebuf_round.md")

  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"
  require("obsidian-tasks.render").render_buffer(bufnr, Obsidian.workspace)
  eq(vim.b[bufnr].obsidian_tasks_dashboard, true)
  eq(vim.bo[bufnr].buftype, "") -- regression: must NOT be "acwrite"

  local cmd = require("obsidian-tasks.cmd")
  local ok = cmd.apply_source_edit(path, 2, { "- [x] tA #task 📅 2026-05-20" }, { dashboard_bufnr = bufnr })
  eq(ok, true)

  -- (a) Source row in buffer mutated.
  eq(vim.fn.getline(3), "- [x] tA #task 📅 2026-05-20")

  -- (b) Disk file reflects the same mutation.
  local disk = read_disk(path)
  eq(disk[3], "- [x] tA #task 📅 2026-05-20")
  eq(disk[4], "- [ ] tB #task 📅 2026-05-21")

  -- (c) Index reflects post-mutation state.
  local idx = require("obsidian-tasks.index")
  local raw = idx._raw() or {}
  local entry = raw[path] or {}
  local tasks = entry.tasks or {}
  local found_x = false
  for _, item in ipairs(tasks) do
    if item.task and item.task.raw_line == "- [x] tA #task 📅 2026-05-20" then
      found_x = true
      break
    end
  end
  eq(found_x, true)

  eq(vim.bo[bufnr].modified, false)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(path)
end

T["same-buffer toggle: rendered region not clobbered by source edit"] = function()
  local path = make_vault_file({
    "# repro",
    "",
    "- [ ] tA #task 📅 2026-05-20",
    "",
    "```tasks",
    "not done",
    "```",
  }, "_samebuf_render.md")

  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"
  require("obsidian-tasks.render").render_buffer(bufnr, Obsidian.workspace)
  local before_count = vim.api.nvim_buf_line_count(bufnr)
  eq(before_count > 7, true, "rendered region added lines below the fence")

  local cmd = require("obsidian-tasks.cmd")
  cmd.apply_source_edit(path, 2, { "- [x] tA #task 📅 2026-05-20" }, { dashboard_bufnr = bufnr })

  -- Buffer line count unchanged (narrow row replace, not full-buffer sync).
  eq(vim.api.nvim_buf_line_count(bufnr), before_count)

  -- Fence still at the same place.
  eq(vim.fn.getline(5), "```tasks")

  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(path)
end

-- ── Second toggle on rendered row after first toggle ─────────────────────────

T["same-buffer toggle: second toggle on rendered row round-trips back"] = function()
  local path = make_vault_file({
    "# repro",
    "",
    "- [ ] tA #task 📅 2026-05-20",
    "",
    "```tasks",
    "not done",
    "```",
  }, "_samebuf_second.md")

  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"
  require("obsidian-tasks.render").render_buffer(bufnr, Obsidian.workspace)
  local cmd = require("obsidian-tasks.cmd")

  -- First toggle: [ ] → [x].
  cmd.apply_source_edit(path, 2, { "- [x] tA #task 📅 2026-05-20" }, { dashboard_bufnr = bufnr })
  eq(vim.fn.getline(3), "- [x] tA #task 📅 2026-05-20")
  eq(read_disk(path)[3], "- [x] tA #task 📅 2026-05-20")

  -- Second toggle: [x] → [ ].  Resolves against the now-up-to-date index.
  cmd.apply_source_edit(path, 2, { "- [ ] tA #task 📅 2026-05-20" }, { dashboard_bufnr = bufnr })
  eq(vim.fn.getline(3), "- [ ] tA #task 📅 2026-05-20")
  eq(read_disk(path)[3], "- [ ] tA #task 📅 2026-05-20")

  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(path)
end

-- ── Undo round-trips through the same-buffer branch ─────────────────────────

T["same-buffer toggle: dashboard_undo replays via same-buffer branch"] = function()
  local path = make_vault_file({
    "# repro",
    "",
    "- [ ] tA #task 📅 2026-05-20",
    "",
    "```tasks",
    "not done",
    "```",
  }, "_samebuf_undo.md")

  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"
  require("obsidian-tasks.render").render_buffer(bufnr, Obsidian.workspace)
  local cmd = require("obsidian-tasks.cmd")

  cmd.apply_source_edit(path, 2, { "- [x] tA #task 📅 2026-05-20" }, { dashboard_bufnr = bufnr })
  eq(read_disk(path)[3], "- [x] tA #task 📅 2026-05-20")

  local ok = cmd.dashboard_undo(bufnr)
  eq(ok, true)
  eq(read_disk(path)[3], "- [ ] tA #task 📅 2026-05-20", "undo wrote original to disk")
  eq(vim.fn.getline(3), "- [ ] tA #task 📅 2026-05-20", "buffer reverted too")

  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(path)
end

return T
