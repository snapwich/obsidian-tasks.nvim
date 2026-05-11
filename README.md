# obsidian-tasks.nvim

A Neovim port of the [obsidian-tasks](https://github.com/obsidian-tasks-group/obsidian-tasks) plugin.
Render, filter, and edit tasks across your Obsidian vault — directly in Neovim.

> **Status:** v1 in development. See [v1 Features & Limitations](#v1-features--limitations).

## Requirements

- Neovim ≥ 0.10
- [obsidian.nvim](https://github.com/obsidian-nvim/obsidian.nvim)
- [blink.cmp](https://github.com/saghen/blink.cmp)

## Installation

### lazy.nvim

```lua
{
  "snapptpod/obsidian-tasks.nvim",  -- replace with actual repo URL at first publish
  dependencies = {
    "obsidian-nvim/obsidian.nvim",
    "saghen/blink.cmp",
  },
  config = function()
    require("obsidian-tasks").setup({})
  end,
}
```

## Setup

Call `setup()` once during Neovim startup (e.g. inside the lazy.nvim `config` function).

```lua
require("obsidian-tasks").setup({})
```

All options are optional — the empty call above gives you sensible defaults.

### Full opts schema

````lua
require("obsidian-tasks").setup({
  -- Only parse/render tasks whose description contains this string.
  -- nil means no filter (show all tasks).
  global_filter = nil,             -- string | nil

  -- Automatically render task extmarks when a vault markdown buffer is opened.
  auto_render = true,              -- boolean

  -- Fold each ```tasks block by default when a dashboard file is opened.
  -- The foldtext shows a query summary and result count, e.g. "📋 not done  (3)".
  -- Press `i` (or `zo`) to expand a fold; press `zc` to collapse it again.
  default_folded = true,           -- boolean

  -- Install buffer-local leader keymaps (<leader>tt, <leader>te, etc.) on
  -- dashboard buffers.  Set false to manage keymaps yourself.
  setup_keymaps = true,            -- boolean

  -- Watch vault files for changes and refresh the in-memory index automatically.
  watcher = true,                  -- boolean

  -- Debounce delay (ms) applied to file-watcher events before re-indexing.
  watcher_debounce_ms = 300,       -- positive integer

  -- strftime pattern used when stamping the done date (✅) on task completion.
  done_date_format = "%Y-%m-%d",   -- string (must contain %)

  -- Timezone used when stamping the done date.
  -- "local" uses the system timezone; "utc" forces UTC (prepends "!" to the format).
  done_date_tz = "local",          -- "local" | "utc"

  -- Default file for :ObsidianTask new when no heading context is found.
  capture_file = nil,              -- string | nil  (absolute or vault-relative path)

  -- Override the default status cycle (Todo → InProgress → Done → Cancelled → OnHold).
  -- Each entry: { char = "x", name = "Done", next = "todo" }
  statuses = nil,                  -- table | nil

  -- Hide the `tasks:` / `filter:` metadata lines in rendered query blocks.
  hide_query_metadata = false,     -- boolean

  -- blink.cmp source integration.
  blink_cmp = {
    enabled = true,                -- boolean: set false to disable the cmp source entirely
  },

  -- Natural-language date input in the cmp source.
  date_input = {
    natural_language = true,       -- boolean: enable NL parsing (e.g. "next monday")
    -- Suggestion phrases shown in the date-field dropdown.
    -- Override to shorten or localise the list.
    suggestions = {                -- string[]
      "today",
      "tomorrow",
      "next monday",
      "next week",
      "in 3 days",
    },
  },

  -- Minimum log level: "debug" | "info" | "warn" | "error"
  log_level = "info",              -- string

  -- Files larger than this (bytes) are skipped by the vault scanner.
  max_file_bytes = 1048576,        -- positive integer (default 1 MiB)
})
````

## Rendering

Dashboard files contain ` ```tasks ` query blocks. When a dashboard buffer is opened,
obsidian-tasks renders matching tasks as **real buffer text** below each fence and wraps
each block in a **manual fold** so the dashboard stays compact.

### Default-folded layout

With `default_folded = true` (the default), every query block opens collapsed:

```
📋 not done  (3)
```

The foldtext shows a summary of the query filter and the result count. Expand a fold to
see the rendered task lines:

| Key         | Action                                   |
| ----------- | ---------------------------------------- |
| `i`         | Open fold and enter insert mode on query |
| `zo` / `zO` | Open fold (stay in normal mode)          |
| `zc`        | Close fold                               |
| `zR`        | Open all folds in the buffer             |
| `zM`        | Close all folds in the buffer            |

### Rendered regions are read-only

Rendered task lines below the fence are managed by the plugin. **Direct edits are
reverted** on the next event-loop tick. To mutate a task, use the leader keymaps or
jump to the source file with `<CR>`.

### Save semantics (BufWriteCmd)

Saving a dashboard buffer (`:w`) writes **only the source content** — query blocks and
prose — to disk. Rendered task lines are never written to the file. Reopening the file
produces the same visual state.

## Keymaps

### Dashboard buffer keymaps (auto-installed when `setup_keymaps = true`)

These are installed automatically on every rendered dashboard buffer:

| Keymap        | Action                                              |
| ------------- | --------------------------------------------------- |
| `<CR>` / `gf` | Jump to the source file at the task's original line |
| `<leader>tt`  | Toggle done/not-done                                |
| `<leader>te`  | Edit task description (vim.ui.input prompt)         |
| `<leader>tp`  | Cycle priority (none → highest → … → lowest → none) |
| `<leader>td`  | Set/edit due date (YYYY-MM-DD prompt)               |
| `<leader>tT`  | Edit tags (comma-separated prompt)                  |
| `<leader>tg`  | Jump to source (same as `<CR>`)                     |
| `<leader>tD`  | Delete task (confirm prompt, removes source line)   |
| `<leader>tr`  | Force re-render all query regions in this buffer    |

Set `setup_keymaps = false` in your `setup()` call to opt out of auto-installed keymaps.
`<CR>` and `gf` are always installed regardless of this setting.

### Global keymaps (not shipped — wire your own)

For source buffers (regular task files) you may want:

```lua
vim.keymap.set("n", "<leader>tt", "<cmd>ObsidianTask toggle<cr>",    { desc = "Toggle task status" })
vim.keymap.set("n", "<leader>td", "<cmd>ObsidianTask done<cr>",      { desc = "Mark task done" })
vim.keymap.set("n", "<leader>tc", "<cmd>ObsidianTask cancel<cr>",    { desc = "Cancel task" })
vim.keymap.set("n", "<leader>tD", "<cmd>ObsidianTask due<cr>",       { desc = "Set due date" })
vim.keymap.set("n", "<leader>ts", "<cmd>ObsidianTask scheduled<cr>", { desc = "Set scheduled date" })
vim.keymap.set("n", "<leader>tn", "<cmd>ObsidianTask new<cr>",       { desc = "New task" })
vim.keymap.set("n", "<leader>tr", "<cmd>ObsidianTask refresh<cr>",   { desc = "Refresh task queries" })
```

## Commands

| Command                   | Description                                                   |
| ------------------------- | ------------------------------------------------------------- |
| `:ObsidianTask toggle`    | Cycle the status of the task under the cursor                 |
| `:ObsidianTask done`      | Mark task done and stamp done date                            |
| `:ObsidianTask cancel`    | Mark task cancelled                                           |
| `:ObsidianTask due`       | Set / edit the due date (📅)                                  |
| `:ObsidianTask scheduled` | Set / edit the scheduled date (⏳)                            |
| `:ObsidianTask new`       | Create a new task (appends to `capture_file` or current file) |
| `:ObsidianTask refresh`   | Re-render all open query blocks                               |
| `:ObsidianTask edit`      | Jump to the source line of a rendered task                    |

## blink.cmp Registration

obsidian-tasks ships a [blink.cmp](https://github.com/saghen/blink.cmp) source that provides
field-icon completions, per-field value suggestions (dates, recurrence patterns, …), and
natural-language date parsing on every task line.

Register the source in your blink.cmp config:

```lua
require("blink.cmp").setup({
  sources = {
    default = { "lsp", "path", "snippets", "buffer", "obsidian-tasks" },
    providers = {
      ["obsidian-tasks"] = {
        module = "obsidian-tasks.cmp.source",
        name = "ObsidianTasks",
      },
    },
  },
})
```

The source activates automatically on task lines (`- [ ] …`) inside obsidian.nvim vault
buffers. No additional configuration is required beyond `require("obsidian-tasks").setup({})`.

To disable the source without removing it from blink, set `blink_cmp = { enabled = false }` in
your `setup()` call.

## Troubleshooting

### Rendered tasks not appearing

1. Confirm obsidian.nvim is set up and the file is inside a configured workspace.
   Run `:lua print(require("obsidian").get_client())` — it should return a client table, not nil.
2. Try `:ObsidianTask refresh` to force a re-render.
3. Increase `log_level = "debug"` in `setup()` and check `:messages` for errors.
4. Check that your dashboard file contains a ` ```tasks ` fence block with a valid query.

### Query block appears collapsed with "(0)" count

Expand the fold with `zo` or `zO` to see whether tasks are rendered. If the count
is truly 0, check that your filter matches existing tasks. Try an empty query (just
` ```tasks ` and ` ``` `) to see all tasks.

### File watcher not refreshing (Linux)

The watcher uses libuv `fs_event` (inotify on Linux). If you have many vault files you may hit
the kernel inotify watch limit:

```
FATAL: inotify limit reached — increase fs.inotify.max_user_watches
```

Raise the limit temporarily:

```sh
sudo sysctl fs.inotify.max_user_watches=524288
```

To persist across reboots, add to `/etc/sysctl.conf`:

```
fs.inotify.max_user_watches=524288
```

### obsidian-tasks source not appearing in blink.cmp

1. Confirm the provider is registered under the key `"obsidian-tasks"` (see [blink.cmp Registration](#blinkcmp-registration)).
2. Confirm `sources.default` includes `"obsidian-tasks"`.
3. Confirm you are on a task line (`- [ ] …`) inside a vault markdown file.
4. Confirm `blink_cmp.enabled` is not set to `false` in your `setup()` call.
5. Check `:lua print(require("obsidian-tasks").opts.blink_cmp.enabled)` — should print `true`.

### Permission errors indexing vault files

If the scanner logs permission-denied errors for some files, those files are silently skipped.
Check that Neovim has read access to all vault directories.

### Newly created files not appearing in query results

Queries against an empty result set are not re-evaluated when new files are added to the vault
(v1 limitation). Run `:ObsidianTask refresh` after creating a new note to force a full re-index.

## v1 Features & Limitations

**What works in v1:**

- Emoji-field and Dataview-field task parsing and serialization
- Real-text task rendering in dashboard buffers with manual fold per query block
- BufWriteCmd save handler — only source content (queries + prose) written to disk
- In-memory vault index with libuv file watcher
- Query blocks: filter, sort, group, limit, hide
- Status cycling with customizable statuses
- Leader keymaps for task mutation directly from the dashboard
- blink.cmp source: field-icon completion, value suggestions, NL date parsing
- `:ObsidianTask` command suite

**v1 limitations:**

- **Recurrence (🔁):** parsed and preserved as opaque text; `next_occurrence` computation
  is a v2 feature and raises an error if called directly.
- **Dependency filter queries:** `depends_on:` filter keyword is not yet implemented.
- **Language:** English-only NL date phrases.
- **Newly created files:** require a manual `:ObsidianTask refresh` to appear in queries
  (reverse-index not updated on file creation).
