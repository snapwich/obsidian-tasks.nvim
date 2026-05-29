-- lua/obsidian-tasks/health.lua
-- `:checkhealth obsidian-tasks` — reports standalone readiness and which
-- optional integrations are present.

local M = {}

--- True if a Lua module is installed on the runtimepath (without loading it).
--- @param init_rel string  e.g. "lua/obsidian/init.lua"
--- @return boolean
local function on_rtp(init_rel)
  return #vim.api.nvim_get_runtime_file(init_rel, false) > 0
end

function M.check()
  local h = vim.health
  h.start("obsidian-tasks")

  -- ── Neovim version ──────────────────────────────────────────────────────────
  -- vim.system (used by the native vault scan) requires Neovim 0.10+.
  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.10+ is required (vim.system is unavailable on this version)")
  end

  -- ── ripgrep (required) ──────────────────────────────────────────────────────
  if vim.fn.executable("rg") == 1 then
    h.ok("ripgrep (`rg`) found on PATH")
  else
    h.error("ripgrep (`rg`) not found on PATH — required for scanning the vault", {
      "Install ripgrep: https://github.com/BurntSushi/ripgrep#installation",
    })
  end

  -- ── obsidian.nvim (optional) ────────────────────────────────────────────────
  if type(Obsidian) == "table" then
    h.info("obsidian.nvim active — checkbox-symbol bridge enabled")
  elseif on_rtp("lua/obsidian/init.lua") then
    h.info("obsidian.nvim installed but not set up (optional integration)")
  else
    h.info("obsidian.nvim not installed (optional — provides the checkbox-symbol bridge)")
  end

  -- ── blink.cmp (optional) ─────────────────────────────────────────────────────
  if on_rtp("lua/blink/cmp/init.lua") then
    h.info("blink.cmp installed — register the 'obsidian-tasks' provider for task-field completion")
  else
    h.info("blink.cmp not installed (optional — enables task-field completion)")
  end
end

return M
