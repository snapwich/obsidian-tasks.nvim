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

## Keymaps

No default keymaps are provided. Wire your own under `<leader>t`:

```lua
vim.keymap.set("n", "<leader>tt", "<cmd>ObsidianTask toggle<cr>",    { desc = "Toggle task status" })
vim.keymap.set("n", "<leader>td", "<cmd>ObsidianTask done<cr>",      { desc = "Mark task done" })
vim.keymap.set("n", "<leader>tD", "<cmd>ObsidianTask due<cr>",       { desc = "Set due date" })
vim.keymap.set("n", "<leader>te", "<cmd>ObsidianTask edit<cr>",      { desc = "Jump to task source" })
vim.keymap.set("n", "<leader>tr", "<cmd>ObsidianTask refresh<cr>",   { desc = "Refresh task queries" })
```
