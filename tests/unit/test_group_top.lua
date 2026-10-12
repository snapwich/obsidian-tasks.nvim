-- tests/unit/test_group_top.lua
-- Plan D2 (group-top insert, step 3): the group-header move behind insert
-- intent (render/group_top.lua + draw.move_group_header).
--
-- These cases call group_top.on_pure_insert directly after a programmatic line
-- insert, to pin the extmark contract (which header moves, where, and which
-- rows are flagged group-top).  The real gestures (`O`, `P`, `:put!`, …) are
-- covered with real keypresses in
-- tests/integration_real/test_real_group_top_intent.lua.

local T = MiniTest.new_set()

local draw = require("obsidian-tasks.render.draw")
local group_top = require("obsidian-tasks.render.group_top")
local NS = require("obsidian-tasks.util.extmark").NS

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

local FENCE = { "```tasks", "group by heading", "```" }

--- Draw a two-group dashboard in the current window:
---   row 3: "- [ ] A"   (group "## g1")
---   row 4: "- [ ] B"   (group "## g2", first task)
---   row 5: "- [ ] C"
local function setup_dashboard()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, FENCE)
  vim.api.nvim_set_current_buf(bufnr)
  local function task(text, line)
    return { kind = "task", text = text, src_path = "/v/n.md", src_line = line, src_hash = text }
  end
  draw.draw(bufnr, { 0, 2 }, {
    { kind = "group_header", text = "## g1" },
    task("- [ ] A", 1),
    { kind = "group_header", text = "## g2" },
    task("- [ ] B", 2),
    task("- [ ] C", 3),
    { kind = "footer", text = "3 tasks" },
  })
  group_top.attach(bufnr)
  return bufnr
end

local function header_row(bufnr, label)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })) do
    for _, chunks in ipairs(m[4].virt_lines or {}) do
      if chunks[1][1] == label then
        return m[2]
      end
    end
  end
  return -1
end

--- Put the cursor on *row* (0-indexed) and let the tracker see it.
local function cursor_on(bufnr, row)
  vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
end

--- Insert *n* lines before *row* the way a pure line insert does, then run the
--- on_lines intent hook for it.
local function insert_at(bufnr, row, n)
  local lines = {}
  for i = 1, n do
    lines[i] = "- [ ] new " .. i
  end
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, lines)
  return group_top.on_pure_insert(bufnr, row, row, row + n)
end

local function cleanup(bufnr)
  draw.clear(bufnr)
  group_top.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["tracker: CursorMoved stores the 0-indexed row; attach seeds it"] = function()
  local bufnr = setup_dashboard()
  eq(group_top.tracked_row(bufnr), 0)
  cursor_on(bufnr, 4)
  eq(group_top.tracked_row(bufnr), 4)
  cleanup(bufnr)
end

T["tracker: detach removes the state and the autocmds"] = function()
  local bufnr = setup_dashboard()
  group_top.detach(bufnr)
  eq(group_top.tracked_row(bufnr), nil)
  eq(#vim.api.nvim_get_autocmds({ event = "CursorMoved", buffer = bufnr }), 0)
  cleanup(bufnr)
end

T["above: the header of the pushed-down first task moves up to the new line"] = function()
  local bufnr = setup_dashboard()
  eq(header_row(bufnr, "## g2"), 4)
  cursor_on(bufnr, 4)
  eq(insert_at(bufnr, 4, 1), "above")
  eq(header_row(bufnr, "## g2"), 4)
  eq(draw.moved_group_header_rows(bufnr), { 4 })
  eq(group_top.has_moved_header(bufnr), true)
  cleanup(bufnr)
end

T["above: a multi-line insert moves the header to the FIRST inserted row"] = function()
  local bufnr = setup_dashboard()
  cursor_on(bufnr, 4)
  eq(insert_at(bufnr, 4, 3), "above")
  eq(header_row(bufnr, "## g2"), 4)
  cleanup(bufnr)
end

T["above on a non-top task: no header there, nothing moves"] = function()
  local bufnr = setup_dashboard()
  cursor_on(bufnr, 5)
  eq(insert_at(bufnr, 5, 1), "above")
  eq(header_row(bufnr, "## g2"), 4)
  eq(group_top.has_moved_header(bufnr), false)
  cleanup(bufnr)
end

T["below: o on the last task of the group above leaves the header on its task"] = function()
  local bufnr = setup_dashboard()
  cursor_on(bufnr, 3)
  eq(insert_at(bufnr, 4, 1), "below")
  eq(header_row(bufnr, "## g2"), 5)
  eq(group_top.has_moved_header(bufnr), false)
  cleanup(bufnr)
end

T["moved header is left-gravity: text typed on the line and a split keep it"] = function()
  local bufnr = setup_dashboard()
  cursor_on(bufnr, 4)
  -- `O` opens an EMPTY line; typing then inserts at the header mark's column.
  vim.api.nvim_buf_set_lines(bufnr, 4, 4, false, { "" })
  group_top.on_pure_insert(bufnr, 4, 4, 5)
  vim.api.nvim_buf_set_text(bufnr, 4, 0, 4, 0, { "- [ ] typed" })
  -- Split at the end of the line (<CR> / the repeat of 3O).
  vim.api.nvim_buf_set_text(bufnr, 4, 11, 4, 11, { "", "" })
  eq(header_row(bufnr, "## g2"), 4)
  cleanup(bufnr)
end

T["above again at a moved header: it stays above the newest line"] = function()
  local bufnr = setup_dashboard()
  cursor_on(bufnr, 4)
  insert_at(bufnr, 4, 1)
  -- `O` on the group-top line itself.
  eq(insert_at(bufnr, 4, 1), "above")
  eq(header_row(bufnr, "## g2"), 4)
  cleanup(bufnr)
end

T["below at a moved header: the header follows the pushed-down row"] = function()
  local bufnr = setup_dashboard()
  cursor_on(bufnr, 4)
  insert_at(bufnr, 4, 1)
  -- `p` on A (row 3): a pure insert at the moved header's row, intent below.
  cursor_on(bufnr, 3)
  eq(insert_at(bufnr, 4, 1), "below")
  eq(header_row(bufnr, "## g2"), 5)
  eq(draw.moved_group_header_rows(bufnr), { 5 })
  cleanup(bufnr)
end

T["rows: from the moved header down to the next managed row, inside its region"] = function()
  local bufnr = setup_dashboard()
  cursor_on(bufnr, 4)
  insert_at(bufnr, 4, 2)
  -- B is now row 6, C row 7; the region snapshot grew to { 3, 7 }.
  local meta = { [3] = {}, [6] = {}, [7] = {} }
  eq(group_top.rows(bufnr, meta, { { 3, 7 } }), { [4] = true, [5] = true })
  -- A header outside every region flags nothing.
  eq(group_top.rows(bufnr, meta, { { 6, 7 } }), {})
  cleanup(bufnr)
end

T["rows: empty when no header moved"] = function()
  local bufnr = setup_dashboard()
  eq(group_top.rows(bufnr, { [3] = {}, [4] = {}, [5] = {} }, { { 3, 5 } }), {})
  cleanup(bufnr)
end

T["redraw resets every header to unmoved"] = function()
  local bufnr = setup_dashboard()
  cursor_on(bufnr, 4)
  insert_at(bufnr, 4, 1)
  eq(group_top.has_moved_header(bufnr), true)
  draw.clear(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, FENCE)
  draw.draw(bufnr, { 0, 2 }, {
    { kind = "group_header", text = "## g2" },
    { kind = "task", text = "- [ ] B", src_path = "/v/n.md", src_line = 2, src_hash = "b" },
  })
  eq(group_top.has_moved_header(bufnr), false)
  cleanup(bufnr)
end

return T
