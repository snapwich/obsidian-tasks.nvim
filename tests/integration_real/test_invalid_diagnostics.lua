-- tests/integration_real/test_invalid_diagnostics.lua
-- Real-deps test: each invalid task field produces a vim.diagnostic entry
-- under the obsidian-tasks namespace, with the parser's error message and
-- WARN severity.  The orchestrator flushes once per render; clear_buffer
-- and BufDelete reset the namespace.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

local function make_vault_file(lines, name)
  local path = fixture_vault .. "/" .. name
  vim.fn.writefile(lines, path)
  return path
end

T["invalid field diagnostics: one entry per malformed field"] = function()
  -- Tasks tagged #task to satisfy the plugin's default global_filter.
  local path = make_vault_file({
    "# repro",
    "",
    "- [ ] alpha #task 📅 someday",
    "- [ ] beta #task 📅 2026-13-01",
    "- [ ] gamma #task [priority:: bogus]",
    "- [ ] delta #task 📅 2026-05-20",
    "",
    "```tasks",
    "not done",
    "```",
  }, "_diag_test.md")

  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"
  -- Seed the index for the file before rendering; render_buffer queries the
  -- in-memory index and would otherwise produce zero rendered tasks for a
  -- freshly-written test fixture.  invalidate first so a stale entry from a
  -- prior test run (with matching mtime resolution) doesn't suppress reparse.
  require("obsidian-tasks.index").invalidate(path)
  require("obsidian-tasks.index").refresh_file(path)
  local render = require("obsidian-tasks.render")
  render.refresh_source_diagnostics(bufnr, path)
  render.render_buffer(bufnr, Obsidian.workspace)

  -- Aggregate diagnostics from both namespaces.  Same-buffer dashboards
  -- emit on the source namespace (with the rendered-region duplicate
  -- suppressed); cross-buffer queries emit on the rendered namespace.
  local diags = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr, { namespace = render._source_diag_ns })) do
    diags[#diags + 1] = d
  end
  for _, d in ipairs(vim.diagnostic.get(bufnr, { namespace = render._diag_ns })) do
    diags[#diags + 1] = d
  end

  -- The dashboard renders tasks from the whole vault, so other malformed
  -- fixture tasks also contribute diagnostics.  Verify *our* three expected
  -- entries are present rather than requiring an exact count.
  local seen_someday, seen_2026_13, seen_bogus = false, false, false
  for _, d in ipairs(diags) do
    eq(d.severity, vim.diagnostic.severity.WARN)
    eq(d.source, "obsidian-tasks")
    local line = vim.api.nvim_buf_get_lines(bufnr, d.lnum, d.lnum + 1, false)[1] or ""
    local slice = line:sub(d.col + 1, d.end_col)
    if slice == "someday" then
      seen_someday = true
    end
    if slice == "2026-13-01" then
      seen_2026_13 = true
    end
    if slice == "bogus" then
      seen_bogus = true
    end
  end
  eq(seen_someday, true)
  eq(seen_2026_13, true)
  eq(seen_bogus, true)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(path)
end

T["invalid field diagnostics: valid task in isolation produces no entries"] = function()
  -- Test the serialize → invalid_ranges → diagnostic plumbing on a task
  -- WITHOUT going through the dashboard render (which would pull in other
  -- vault tasks with their own malformed fields and pollute the count).
  local parse = require("obsidian-tasks.task.parse")
  local serialize = require("obsidian-tasks.task.serialize")
  local task = parse.parse("- [ ] alpha #task 📅 2026-05-20")
  local ser = serialize.serialize_with_meta(task)
  eq(#ser.invalid_ranges, 0)
end

T["invalid field diagnostics: clear_buffer resets the namespace"] = function()
  local path = make_vault_file({
    "# repro",
    "",
    "- [ ] alpha #task 📅 someday",
    "",
    "```tasks",
    "not done",
    "```",
  }, "_diag_clear.md")

  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"
  local render = require("obsidian-tasks.render")
  render.refresh_source_diagnostics(bufnr, path)
  render.render_buffer(bufnr, Obsidian.workspace)
  -- At least one diagnostic (across either namespace) from our malformed
  -- `someday`; same-buffer cases land on the source namespace, cross-buffer
  -- on the rendered namespace.
  local total_before = #vim.diagnostic.get(bufnr, { namespace = render._diag_ns })
    + #vim.diagnostic.get(bufnr, { namespace = render._source_diag_ns })
  eq(total_before > 0, true)

  render.clear_buffer(bufnr)
  eq(#vim.diagnostic.get(bufnr, { namespace = render._diag_ns }), 0)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(path)
end

-- ── Source-row diagnostics (any md in workspace, no dashboard required) ─────

T["source diagnostics: malformed task on a regular md file gets a diagnostic at its source row"] = function()
  local path = make_vault_file({
    "# notes",
    "",
    "- [ ] foo #task 📅 someday",
    "- [ ] bar #task 📅 2026-05-20",
    "",
  }, "_src_diag.md")

  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"

  local idx = require("obsidian-tasks.index")
  idx.invalidate(path)
  idx.refresh_file(path)

  local render = require("obsidian-tasks.render")
  render.refresh_source_diagnostics(bufnr, path)

  local diags = vim.diagnostic.get(bufnr, { namespace = render._source_diag_ns })
  -- Exactly one diagnostic — for "someday" on line 2 (0-indexed).
  eq(#diags, 1)
  local d = diags[1]
  eq(d.lnum, 2) -- source row 3 → 0-indexed 2
  eq(d.severity, vim.diagnostic.severity.WARN)
  eq(d.source, "obsidian-tasks")
  -- The slice over the buffer should be exactly "someday".
  local line = vim.api.nvim_buf_get_lines(bufnr, d.lnum, d.lnum + 1, false)[1] or ""
  eq(line:sub(d.col + 1, d.end_col), "someday")
  eq(d.message:find("date", 1, true) ~= nil, true)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(path)
end

T["source diagnostics: dataview-priority value range is exact"] = function()
  local path = make_vault_file({
    "# notes",
    "",
    "- [ ] thing #task [priority:: bogus]",
    "",
  }, "_src_diag_prio.md")

  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"

  local idx = require("obsidian-tasks.index")
  idx.invalidate(path)
  idx.refresh_file(path)

  local render = require("obsidian-tasks.render")
  render.refresh_source_diagnostics(bufnr, path)

  local diags = vim.diagnostic.get(bufnr, { namespace = render._source_diag_ns })
  eq(#diags, 1)
  local d = diags[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, d.lnum, d.lnum + 1, false)[1] or ""
  eq(line:sub(d.col + 1, d.end_col), "bogus")
  eq(d.message:find("priority", 1, true) ~= nil, true)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(path)
end

T["source diagnostics: fixing a malformed value clears its diagnostic"] = function()
  local path = make_vault_file({
    "- [ ] x #task 📅 someday",
  }, "_src_diag_clear.md")

  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"

  local idx = require("obsidian-tasks.index")
  idx.invalidate(path)
  idx.refresh_file(path)

  local render = require("obsidian-tasks.render")
  render.refresh_source_diagnostics(bufnr, path)
  eq(#vim.diagnostic.get(bufnr, { namespace = render._source_diag_ns }), 1)

  -- Replace `someday` with a valid date on disk and re-index; refresh should
  -- clear the diagnostic.
  vim.fn.writefile({ "- [ ] x #task 📅 2026-05-20" }, path)
  idx.invalidate(path)
  idx.refresh_file(path)
  render.refresh_source_diagnostics(bufnr, path)
  eq(#vim.diagnostic.get(bufnr, { namespace = render._source_diag_ns }), 0)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(path)
end

return T
