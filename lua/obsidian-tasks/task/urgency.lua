-- lua/obsidian-tasks/task/urgency.lua
-- Compute a numeric urgency score for a task.
--
-- Formula mirrors upstream's src/Task/Urgency.ts:
--   urgency = due_term + scheduled_term + start_term + priority_term
--
-- Coefficients (upstream parity):
--   dueCoefficient        = 12.0
--   scheduledCoefficient  =  5.0
--   startedCoefficient    = -3.0  (negative: future-start tasks are de-prioritised)
--   priorityCoefficient   =  6.0
--
-- The score is used by:
--   • `filter:` (urgency above/below N)  — see query/filter.lua
--   • `sort by urgency`                  — see query/sort.lua
--   • `group by urgency`                 — see query/group.lua

local M = {}

M.DUE_COEFFICIENT = 12.0
M.SCHEDULED_COEFFICIENT = 5.0
M.STARTED_COEFFICIENT = -3.0
M.PRIORITY_COEFFICIENT = 6.0

local PRIORITY_MULTIPLIER = {
  highest = 1.5,
  high = 1.0,
  medium = 0.65,
  none = 0.325,
  low = 0.0,
  lowest = -0.3,
}

--- Today's date as a Unix-time number (midnight, local).  Cached at module
--- load — fine for typical render passes that complete in milliseconds.  If
--- you need to recompute (e.g. across midnight), call M._set_today(time_t).
local function today_midnight()
  local t = os.date("*t") --[[@as osdate]]
  t.hour = 0
  t.min = 0
  t.sec = 0
  return os.time(t)
end

--- Override "today" for testing.  Pass nil to reset to real time.
--- @param time_t number|nil  Unix-time seconds (midnight)
function M._set_today(time_t)
  M._today = time_t
end

local function today()
  return M._today or today_midnight()
end

--- Parse an ISO date string to a Unix-time number (noon, local) or nil.
--- @param iso string
--- @return number|nil
local function iso_to_time(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local y, mo, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
end

local SECONDS_PER_DAY = 86400

--- Calculate the urgency score for a task.
--- @param task table  parsed Task (with task.fields = { due?, scheduled?, start?, priority? })
--- @return number  urgency score
function M.calculate(task)
  local urgency = 0.0
  local now = today()

  -- ── Due date term ──────────────────────────────────────────────────────
  local due_t = iso_to_time(task.fields and task.fields.due)
  if due_t then
    -- daysOverdue = today - due  (positive = overdue, negative = future)
    local days_overdue = math.floor((now - due_t) / SECONDS_PER_DAY + 0.5)
    local mult
    if days_overdue >= 7 then
      mult = 1.0 -- a week or more overdue
    elseif days_overdue >= -14 then
      -- Linear interpolation from -14 (mult=0.2) to +7 (mult=1.0).
      mult = ((days_overdue + 14) * 0.8) / 21.0 + 0.2
    else
      mult = 0.2 -- more than two weeks in the future
    end
    urgency = urgency + mult * M.DUE_COEFFICIENT
  end

  -- ── Scheduled term ─────────────────────────────────────────────────────
  local sched_t = iso_to_time(task.fields and task.fields.scheduled)
  if sched_t and now >= sched_t then
    urgency = urgency + M.SCHEDULED_COEFFICIENT
  end

  -- ── Start term (future start → urgency penalty) ────────────────────────
  local start_t = iso_to_time(task.fields and task.fields.start)
  if start_t and now < start_t then
    urgency = urgency + M.STARTED_COEFFICIENT
  end

  -- ── Priority term ──────────────────────────────────────────────────────
  local pri = task.fields and task.fields.priority or "none"
  local mult = PRIORITY_MULTIPLIER[pri]
  if mult then
    urgency = urgency + mult * M.PRIORITY_COEFFICIENT
  end

  return urgency
end

return M
