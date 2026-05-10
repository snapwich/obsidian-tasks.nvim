# obsidian-tasks.nvim

A Neovim port of the [obsidian-tasks](https://github.com/obsidian-tasks-group/obsidian-tasks) plugin.
Render, filter, and edit tasks across your Obsidian vault — directly in Neovim.

> **Status:** v1 in development.

## Requirements

- Neovim ≥ 0.10
- [obsidian.nvim](https://github.com/epwalsh/obsidian.nvim)
- [blink.cmp](https://github.com/saghen/blink.cmp)

## Installation

### lazy.nvim

```lua
{
  "YOUR_USER/obsidian-tasks.nvim",
  dependencies = {
    "obsidian-nvim/obsidian.nvim",
    "saghen/blink.cmp",
  },
  opts = {},
}
```

## Configuration

```lua
require("obsidian-tasks").setup({
  auto_render           = true,
  watcher               = true,
  watcher_debounce_ms   = 300,
  done_date_format      = "%Y-%m-%d",
  statuses              = nil,   -- override default cycle table
  blink_cmp             = { enabled = true },
})
```

## blink.cmp setup

obsidian-tasks ships a [blink.cmp](https://github.com/saghen/blink.cmp) source that offers
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

## Keymaps

No default keymaps are provided. Wire your own under `<leader>t`:

```lua
vim.keymap.set("n", "<leader>tt", "<cmd>ObsidianTask toggle<cr>",    { desc = "Toggle task status" })
vim.keymap.set("n", "<leader>td", "<cmd>ObsidianTask done<cr>",      { desc = "Mark task done" })
vim.keymap.set("n", "<leader>tD", "<cmd>ObsidianTask due<cr>",       { desc = "Set due date" })
vim.keymap.set("n", "<leader>te", "<cmd>ObsidianTask edit<cr>",      { desc = "Jump to task source" })
vim.keymap.set("n", "<leader>tr", "<cmd>ObsidianTask refresh<cr>",   { desc = "Refresh task queries" })
```
