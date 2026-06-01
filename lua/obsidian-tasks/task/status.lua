-- lua/obsidian-tasks/task/status.lua
-- Default status table + cycle logic.
--
-- Status type enum strings (mirror TS plugin):
--   TODO | DONE | IN_PROGRESS | CANCELLED | ON_HOLD | NON_TASK | EMPTY

local M = {}

--- Default statuses matching obsidian-tasks TS plugin defaults.
--- @type table[]
local DEFAULT_STATUSES = {
  { symbol = " ", name = "Todo", next = "x", type = "TODO" },
  { symbol = "x", name = "Done", next = " ", type = "DONE" },
  { symbol = "/", name = "In Progress", next = "x", type = "IN_PROGRESS" },
  { symbol = "-", name = "Cancelled", next = " ", type = "CANCELLED" },
  { symbol = "h", name = "On Hold", next = " ", type = "ON_HOLD" },
}

--- Active status list (defaults + user overrides after merge).
--- @type table[]
M.statuses = {}

--- Lookup: symbol char → status entry.
--- @type table<string, table>
M.by_symbol = {}

--- Lookup: name string → status entry.
--- @type table<string, table>
M.by_name = {}

--- Lookup: type string → status entry.
--- @type table<string, table>
M.by_type = {}

--- Rebuild all lookup tables from M.statuses.
local function rebuild_lookups()
  M.by_symbol = {}
  M.by_name = {}
  M.by_type = {}
  for _, s in ipairs(M.statuses) do
    M.by_symbol[s.symbol] = s
    M.by_name[s.name] = s
    M.by_type[s.type] = s
  end
end

--- Deep-copy a status entry.
local function copy_status(s)
  return { symbol = s.symbol, name = s.name, next = s.next, type = s.type }
end

--- Initialize from defaults (called at module load).
local function init()
  M.statuses = {}
  for _, s in ipairs(DEFAULT_STATUSES) do
    M.statuses[#M.statuses + 1] = copy_status(s)
  end
  rebuild_lookups()
end

init()

--- Merge user status overrides into the active table.
--- `opts_statuses` is keyed by symbol char; each value is a partial entry whose
--- fields override an existing entry or define a new one.
--- Idempotent: calling merge multiple times with the same opts is safe.
---
--- @param opts_statuses table<string, table>  e.g. { ['>'] = { name = 'Forwarded', next = ' ', type = 'ON_HOLD' } }
function M.merge(opts_statuses)
  if not opts_statuses then
    return
  end
  -- Reset to defaults first so merge is idempotent.
  M.statuses = {}
  for _, s in ipairs(DEFAULT_STATUSES) do
    M.statuses[#M.statuses + 1] = copy_status(s)
  end
  for symbol, overrides in pairs(opts_statuses) do
    local existing = nil
    for _, s in ipairs(M.statuses) do
      if s.symbol == symbol then
        existing = s
        break
      end
    end
    if existing then
      -- Override fields of existing entry.
      if overrides.name ~= nil then
        existing.name = overrides.name
      end
      if overrides.next ~= nil then
        existing.next = overrides.next
      end
      if overrides.type ~= nil then
        existing.type = overrides.type
      end
    else
      -- Add new entry.
      M.statuses[#M.statuses + 1] = {
        symbol = symbol,
        name = overrides.name or symbol,
        next = overrides.next or symbol,
        type = overrides.type or "TODO",
      }
    end
  end
  rebuild_lookups()
end

--- Register obsidian.nvim's `Obsidian.opts.checkbox.order` symbols as
--- known statuses so that <CR> (smart_action) toggles on a rendered task
--- row land on a symbol our revert/status-edit detector accepts.
---
--- Each obsidian-only symbol is added as a TODO-type entry with name
--- "Obsidian: <symbol>" and a self-cycle (next=symbol). User overrides
--- via opts.statuses still take precedence — call status.merge AFTER this
--- if both are in play, or this AFTER merge if you want user opts to win.
---
--- Safe to call when obsidian.nvim is not loaded — no-op.
--- Idempotent: registering the same symbol twice is a no-op.
function M.bridge_obsidian_checkbox_order()
  if type(Obsidian) ~= "table" then
    return
  end
  local checkbox = Obsidian.opts and Obsidian.opts.checkbox
  local order = checkbox and checkbox.order
  if type(order) ~= "table" then
    return
  end

  local changed = false
  for _, sym in ipairs(order) do
    if type(sym) == "string" and sym ~= "" and not M.by_symbol[sym] then
      M.statuses[#M.statuses + 1] = {
        symbol = sym,
        name = "Obsidian: " .. sym,
        next = sym,
        type = "TODO",
      }
      changed = true
    end
  end
  if changed then
    rebuild_lookups()
  end
end

--- Status types still "actively pending": a task in one of these is NOT
--- considered done by the `done` / `is blocked` query filters.
local PENDING_TYPES = { TODO = true, IN_PROGRESS = true, ON_HOLD = true }

--- Return true when *entry* (a status table) is an actively-pending type.
--- A nil entry (unknown symbol) is treated as pending.
---
--- @param entry table|nil  status entry from M.by_symbol
--- @return boolean
function M.is_pending(entry)
  return entry == nil or PENDING_TYPES[entry.type] == true
end

--- Return true when *symbol* maps to a terminal "completed" status
--- (DONE or CANCELLED).  Used by the layout pipeline to dim completed
--- tasks in place (they keep their sort-by position).
---
--- @param symbol string  single character
--- @return boolean
function M.is_completed(symbol)
  local entry = M.by_symbol[symbol]
  if not entry then
    return false
  end
  return entry.type == "DONE" or entry.type == "CANCELLED"
end

--- Return the next symbol in the cycle for the given symbol.
--- If the symbol is unknown, returns it unchanged (no-op for caller).
---
--- @param symbol string  single character
--- @return string
function M.next(symbol)
  local entry = M.by_symbol[symbol]
  if not entry then
    return symbol
  end
  return entry.next
end

return M
