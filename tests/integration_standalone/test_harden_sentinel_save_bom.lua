-- tests/integration_standalone/test_harden_sentinel_save_bom.lua
-- Phase-2 hardening, OPEN QUESTION: does the BufWriteCmd save path preserve a
-- UTF-8 BOM through a sentinel-bearing round-trip?
--
-- Runs in the STANDALONE (in-process) suite so we can drive the real save path
-- (render.save.on_write_cmd → filter_out_managed → vim.fn.writefile) directly on
-- a temp note with `bomb` set.  The sentinel is an empty string with no encoding
-- bytes of its own; the only risk is the writer dropping the BOM.
--
-- The writer uses `vim.fn.writefile(kept, filepath)` WITHOUT the "b" flag, so it
-- does not re-emit a BOM.  Best-guess EXPECTED behavior asserted below is that a
-- BOM-tagged note round-trips with its BOM intact; this case is EXPECTED to be a
-- real-bug find if the writer strips it.  We do not fix product code.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

-- ── helper: write a note with a UTF-8 BOM, edit it, render, return bufnr ──────

local function open_bom_dashboard()
  local note = vim.fn.tempname() .. ".md"
  -- Write the raw bytes with a leading UTF-8 BOM (EF BB BF) on the first line.
  local bom = string.char(0xEF, 0xBB, 0xBF)
  local fh = assert(io.open(note, "wb"))
  fh:write(bom .. "# Daily\n```tasks\nnot done\n```\n")
  fh:close()

  -- Stub the index so a single task renders (avoids needing a real vault walk).
  local index = require("obsidian-tasks.index")
  local tp = require("obsidian-tasks.task.parse")
  local src = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "- [ ] bom task #task" }, src)
  index.set_render_paths = function() end
  index.clear_render_paths = function() end
  index.refresh_all = function(_, d)
    if d then
      d()
    end
  end
  index.invalidate = function() end
  index.refresh_file = function() end
  index.nodes_for = function()
    return {}
  end
  index.tasks_in = function()
    local i = 0
    return function()
      i = i + 1
      if i == 1 then
        return tp.parse("- [ ] bom task #task"), src, 1
      end
    end
  end

  local render = require("obsidian-tasks.render.init")
  render.configure({ default_folded = false })
  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(note))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "markdown"
  -- Do NOT pre-set the dashboard flag; first render's save.attach registers the
  -- BufWriteCmd strip handler.
  render.render_buffer(buf, nil)
  return buf, note, src
end

-- ── (open) BOM survives the sentinel-bearing save round-trip ─────────────────

T["bom: a UTF-8 BOM survives the BufWriteCmd strip-and-write round-trip"] = function()
  local buf, note, src = open_bom_dashboard()

  -- Neovim should have detected the BOM on read.
  eq(vim.bo[buf].bomb, true, "BOM detected on read (bomb option)")

  -- The dashboard rendered a task row + an EOF sentinel.  :w strips them.
  vim.cmd("silent write")

  -- Read the raw on-disk bytes back and check the BOM is still the first 3 bytes.
  local fh = assert(io.open(note, "rb"))
  local raw = fh:read("*a")
  fh:close()
  local first3 = raw:sub(1, 3)

  eq(
    first3,
    string.char(0xEF, 0xBB, 0xBF),
    "BOM must be preserved on write; got first bytes: "
      .. string.format("%02X %02X %02X", raw:byte(1) or 0, raw:byte(2) or 0, raw:byte(3) or 0)
  )

  -- And the managed rows are gone: the kept content is fences + prose only.
  local kept = vim.fn.readfile(note)
  -- readfile strips the BOM from the first line's displayed content; assert the
  -- structural lines round-tripped (no rendered task, no sentinel).
  local joined = table.concat(kept, "\n")
  eq(joined:find("bom task", 1, true), nil, "rendered task stripped on save: " .. vim.inspect(kept))
  eq(kept[#kept], "```", "no trailing sentinel persisted to disk: " .. vim.inspect(kept))

  vim.api.nvim_buf_delete(buf, { force = true })
  pcall(vim.fn.delete, note)
  pcall(vim.fn.delete, src)
end

return T
