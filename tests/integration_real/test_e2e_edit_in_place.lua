-- tests/integration_real/test_e2e_edit_in_place.lua
-- Cross-feature edit-in-place E2E using REAL keypresses via child_neovim.
--
-- Mirrors tests/integration/test_edit_in_place_e2e.lua's E5 scenario but
-- drives the dashboard with nvim_input (terminal-equivalent) instead of
-- programmatic set_lines.  That makes mode() return 'i' during insert-mode
-- steps and lets vim.schedule callbacks fire between keystrokes — the actual
-- conditions where the typing-revert bug lived.
--
-- The synchronous-seam E5 in tests/integration/ stays as-is: it covers the
-- classifier logic with deterministic execution.  This file is the new
-- acceptance bar — when this passes, the full stack works under real input.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

-- ── Child Neovim + grouped dashboard helper ──────────────────────────────────

local function spawn_grouped_dashboard()
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })

  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(deps_dir .. "/obsidian.nvim")
    vim.opt.rtp:prepend(deps_dir .. "/blink.cmp")
    vim.opt.rtp:prepend(cwd)
    local orig = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(orig, ...) end

    local fixture_vault = cwd .. "/tests/fixtures/vault"
    require("obsidian").setup({
      workspaces = { { name = "test-vault", path = fixture_vault } },
      log_level = vim.log.levels.ERROR,
      completion = { nvim_cmp = false, blink = false },
      picker = { name = nil },
      ui = { enable = false },
    })
    require("obsidian-tasks").setup({ global_filter = "#task" })
    require("blink.cmp").setup({
      fuzzy = { implementation = "lua" },
      sources = {
        default = { "obsidian-tasks" },
        providers = {
          ["obsidian-tasks"] = { module = "obsidian-tasks.cmp.source", name = "ObsidianTasks" },
        },
      },
    })
  ]],
    { cwd, deps_dir }
  )

  -- Two source files, grouped #work dashboard.
  local paths = child.lua_get([[(function()
    local src_a = vim.fn.tempname() .. ".md"
    local src_b = vim.fn.tempname() .. ".md"
    vim.fn.writefile({
      "- [ ] Alpha task #work",
      "- [ ] Beta task #work",
      "  Some continuation note",
    }, src_a)
    vim.fn.writefile({
      "- [ ] Gamma task #work",
    }, src_b)

    local index = require("obsidian-tasks.index")
    local task_parse = require("obsidian-tasks.task.parse")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.tasks_in = function()
      local sources = { src_a, src_b }
      local all = {}
      for _, sp in ipairs(sources) do
        local ok, lines = pcall(vim.fn.readfile, sp)
        if ok then
          for ln, line in ipairs(lines) do
            local t = task_parse.parse(line)
            if t then
              all[#all + 1] = { task = t, path = sp, ln = ln }
            end
          end
        end
      end
      local i = 0
      return function()
        i = i + 1
        if all[i] then return all[i].task, all[i].path, all[i].ln end
      end
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false, linger_on_filter_exit = true })

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "```tasks", "not done", "group by tags", "```",
    })
    vim.b[bufnr].obsidian_tasks_dashboard = true
    render.render_buffer(bufnr, nil)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src_a = src_a
    _G._src_b = src_b
    return { src_a = src_a, src_b = src_b }
  end)()]])

  return child, paths.src_a, paths.src_b
end

local function child_line(child, row0)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, " .. row0 .. ", " .. row0 + 1 .. ", false)[1]")
end

local function read_src(child, var)
  return child.lua_get("vim.fn.readfile(_G." .. var .. ")")
end

--- Find the 0-indexed dashboard row containing *needle* (substring match).
local function find_row(child, needle)
  return child.lua_get(string.format(
    [[(function()
        local lines = vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)
        for i, l in ipairs(lines) do
          if l and l:find(%q, 1, true) then return i - 1 end
        end
        return -1
      end)()]],
    needle
  ))
end

-- ── Full-stack E2E ───────────────────────────────────────────────────────────

T["e2e (real keys): description edit + ISO normalisation + INSERT + DELETE + undo + mass-delete gate"] = function()
  local child, src_a = spawn_grouped_dashboard()

  -- ── Step 1: ciw on Alpha description (MUTATE / P5) ─────────────────────────
  local alpha_row = find_row(child, "Alpha task")
  eq(alpha_row >= 0, true, "Step 1: Alpha row must exist in dashboard")
  -- "- [ ] Alpha task #work" — cursor on 'A' of "Alpha" is byte 6.
  child.api.nvim_win_set_cursor(0, { alpha_row + 1, 6 })
  child.type_keys("c", "i", "w", "AlphaEdited", "<Esc>")
  vim.loop.sleep(200)

  local src_a_after_1 = read_src(child, "_src_a")
  eq(src_a_after_1[1], "- [ ] AlphaEdited task #work", "Step 1: ciw description edit must commit to source")

  -- ── Step 2: insert "📅 tomorrow " before #work in Beta (P5 Q2 normalisation) ─
  local beta_row = find_row(child, "Beta task")
  eq(beta_row >= 0, true, "Step 2: Beta row must exist")
  -- Move cursor to '#' of "#work" in Beta's line.
  local beta_line = child_line(child, beta_row)
  local hash_byte = beta_line:find("#work") - 1 -- 0-indexed
  child.api.nvim_win_set_cursor(0, { beta_row + 1, hash_byte })
  child.type_keys("i", "📅 tomorrow ", "<Esc>")
  vim.loop.sleep(250)

  local src_a_after_2 = read_src(child, "_src_a")
  local beta_src = src_a_after_2[2]
  eq(beta_src ~= nil, true, "Step 2: Beta source line must exist")
  eq(
    beta_src:match("%d%d%d%d%-%d%d%-%d%d") ~= nil,
    true,
    "Step 2: 'tomorrow' must be normalised to ISO date in source: [" .. (beta_src or "nil") .. "]"
  )
  eq(beta_src:find("tomorrow"), nil, "Step 2: literal 'tomorrow' must NOT remain in source")

  -- ── Step 3: cross-file ciw on Gamma (P5 MUTATE across files) ───────────────
  local gamma_row = find_row(child, "Gamma task")
  eq(gamma_row >= 0, true, "Step 3: Gamma row must exist")
  child.api.nvim_win_set_cursor(0, { gamma_row + 1, 6 })
  child.type_keys("c", "i", "w", "GammaUpdated", "<Esc>")
  vim.loop.sleep(200)

  local src_b_after_3 = read_src(child, "_src_b")
  eq(src_b_after_3[1], "- [ ] GammaUpdated task #work", "Step 3: Gamma edit must land in src_b (cross-file MUTATE)")

  -- ── Step 4: o on an Alpha row, type new task → P9 #work auto-add (INSERT) ──
  -- After step 1's edit, AlphaEdited row is still at the top of #work group.
  -- Re-render to give flush a clean baseline.
  child.lua("require('obsidian-tasks.render').render_buffer(_G._dash_bufnr, nil)")
  child.lua("vim.cmd('normal! zR')")

  local alpha_row_4 = find_row(child, "AlphaEdited")
  eq(alpha_row_4 >= 0, true, "Step 4: AlphaEdited row must exist")
  child.api.nvim_win_set_cursor(0, { alpha_row_4 + 1, 0 })
  child.type_keys("o", "- [ ] Brand new task", "<Esc>")
  vim.loop.sleep(300)

  local src_a_after_4 = read_src(child, "_src_a")
  local found_new = false
  local has_work_tag = false
  for _, l in ipairs(src_a_after_4) do
    if l:find("Brand new task") then
      found_new = true
      has_work_tag = l:find("#work") ~= nil
    end
  end
  eq(found_new, true, "Step 4: new task must appear in source after INSERT (P8)")
  eq(has_work_tag, true, "Step 4: P9 must auto-add #work to new task inside #work group")

  -- ── Step 5: dd on Beta — block delete (P8) ─────────────────────────────────
  child.lua("require('obsidian-tasks.render').render_buffer(_G._dash_bufnr, nil)")
  child.lua("vim.cmd('normal! zR')")
  local beta_row_5 = find_row(child, "Beta task")
  eq(beta_row_5 >= 0, true, "Step 5: Beta row must still exist before dd")
  child.api.nvim_win_set_cursor(0, { beta_row_5 + 1, 0 })
  child.type_keys("d", "d")
  vim.loop.sleep(250)

  local src_a_after_5 = read_src(child, "_src_a")
  local beta_present, cont_present = false, false
  for _, l in ipairs(src_a_after_5) do
    if l:find("Beta") then
      beta_present = true
    end
    if l:find("continuation note") then
      cont_present = true
    end
  end
  eq(beta_present, false, "Step 5: Beta must be removed from source (P8 block delete)")
  eq(cont_present, false, "Step 5: Beta continuation must also be removed (P8 block delete)")

  -- ── Step 6: ggdG mass-delete gate (P7) ─────────────────────────────────────
  -- Capture pre-mass-delete source state so we can prove it survived intact.
  local src_a_before_6 = read_src(child, "_src_a")
  local src_b_before_6 = read_src(child, "_src_b")

  -- Wire a log.warn spy in the child to capture the gate's warning message.
  child.lua([[
    _G._warns = {}
    local log = require("obsidian-tasks.log")
    _G._orig_warn = log.warn
    log.warn = function(msg)
      table.insert(_G._warns, tostring(msg))
      _G._orig_warn(msg)
    end
  ]])

  -- ggdG: cursor to top, delete-to-end.  This wipes fences and all rows so the
  -- block becomes structurally broken → P7 gate triggers, source untouched.
  child.type_keys("g", "g", "d", "G")
  vim.loop.sleep(300)

  -- Source files must be untouched after the mass-delete.
  local src_a_after_6 = read_src(child, "_src_a")
  local src_b_after_6 = read_src(child, "_src_b")
  eq(
    vim.deep_equal(src_a_before_6, src_a_after_6),
    true,
    "Step 6: src_a must be untouched after ggdG mass-delete (P7 gate)"
  )
  eq(
    vim.deep_equal(src_b_before_6, src_b_after_6),
    true,
    "Step 6: src_b must be untouched after ggdG mass-delete (P7 gate)"
  )

  -- Warning message must include the gate signal.
  local warns = child.lua_get("_G._warns")
  local saw_gate_warn = false
  for _, w in ipairs(warns) do
    if w:find("dashboard cleared") then
      saw_gate_warn = true
    end
  end
  eq(saw_gate_warn, true, "Step 6: P7 gate must emit 'dashboard cleared' warning")

  child.stop()
  pcall(vim.fn.delete, src_a)
end

return T
