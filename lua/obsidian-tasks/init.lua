-- lua/obsidian-tasks/init.lua
-- Public API. setup() is the single entry point.

local M = {}

--- Merged opts stored after setup(). Available as obsidian-tasks.opts.
M.opts = {}

--- Resolve the foreground color of the colorscheme's markdown H2 heading.
--- Group headers borrow this *color* but not the heading background: real H2
--- lines get a full-row bg from render-markdown/headlines, so an fg-only
--- header stays visually distinct from the H2s a dashboard uses to separate
--- queries.
--- @return integer|nil  24-bit RGB fg, or nil if no heading group resolves
local function h2_fg()
  for _, name in ipairs({ "@markup.heading.2.markdown", "@markup.heading.2", "markdownH2", "Title" }) do
    local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and h and h.fg then
      return h.fg
    end
  end
  return nil
end

--- Blend two 24-bit RGB colors.  `ratio` is the weight of `a` (0 = all `b`,
--- 1 = all `a`).
--- @param a integer
--- @param b integer
--- @param ratio number
--- @return integer
local function blend(a, b, ratio)
  local function mix(shift)
    local ca = math.floor(a / shift) % 256
    local cb = math.floor(b / shift) % 256
    return math.floor(ca * ratio + cb * (1 - ratio) + 0.5)
  end
  return mix(65536) * 65536 + mix(256) * 256 + mix(1)
end

-- Group-header fg is dimmed this far toward the Normal background (1 = full
-- H2 color, 0 = invisible).
local GROUP_HEADER_DIM = 0.6

--- Register default highlight groups.  `default = true` lets user colorschemes
--- win — call this in setup AND on ColorScheme (some colorschemes nuke user
--- highlights on reload).
local function register_default_hls()
  vim.api.nvim_set_hl(0, "ObsidianTasksLinger", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "ObsidianTasksFieldInvalid", { link = "DiagnosticUnderlineError", default = true })
  -- Group-by header: H2 color dimmed toward the background, bold, no bg.
  local fg = h2_fg()
  local normal = select(2, pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false }))
  if fg and type(normal) == "table" and normal.bg then
    vim.api.nvim_set_hl(
      0,
      "ObsidianTasksGroupHeader",
      { fg = blend(fg, normal.bg, GROUP_HEADER_DIM), bold = true, default = true }
    )
  elseif fg then
    vim.api.nvim_set_hl(0, "ObsidianTasksGroupHeader", { fg = fg, bold = true, default = true })
  else
    vim.api.nvim_set_hl(0, "ObsidianTasksGroupHeader", { link = "Title", default = true })
  end
end

--- Bootstrap the plugin.
--- @param opts table? User configuration (see config.lua for schema).
function M.setup(opts)
  opts = opts or {}
  local config = require("obsidian-tasks.config")
  M.opts = config.merge(opts)
  register_default_hls()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("obsidian_tasks_highlights", { clear = true }),
    callback = register_default_hls,
  })
  -- Merge user status overrides so toggle/done/cancel respect custom statuses.
  local status_mod = require("obsidian-tasks.task.status")
  status_mod.merge(M.opts.statuses)
  -- Optional obsidian.nvim integration (the plugin does not require it):
  -- bridge obsidian.nvim's checkbox.order so symbols it cycles through (e.g.
  -- ~, !, > in the default { " ", "~", "!", ">", "x" }) are accepted by our
  -- status-edit detector instead of getting reverted as foreign edits.
  -- No-ops when obsidian.nvim is absent. If it sets up AFTER us, we re-bridge
  -- on its workspace event.
  status_mod.bridge_obsidian_checkbox_order()
  vim.api.nvim_create_autocmd("User", {
    pattern = "ObsidianWorkpspaceSet", -- typo intentional (matches obsidian.nvim)
    callback = function()
      status_mod.bridge_obsidian_checkbox_order()
    end,
  })
  -- Propagate opts to the render orchestrator (default_folded, etc.).
  require("obsidian-tasks.render").configure(M.opts)
  -- Wire autocmds (BufReadPost / FocusGained / BufWritePost / BufDelete).
  require("obsidian-tasks.autocmds").setup(M.opts)
  -- Register :ObsidianTask dispatcher (replaces plugin/ stub).
  require("obsidian-tasks.cmd").setup()
end

return M
