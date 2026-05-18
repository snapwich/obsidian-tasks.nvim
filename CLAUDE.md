# obsidian-tasks.nvim — agent context

## Project

Neovim plugin (Lua), v1 in development. Port of the obsidian-tasks desktop plugin.
No vimdoc, no docs site for v1.

## Hard dependencies

- **obsidian.nvim** — vault/workspace/frontmatter/file-walker/path APIs
- **blink.cmp** — field suggestor source

## Module layout (`lua/obsidian-tasks/`)

```
init.lua              setup(opts), public API, M.opts
config.lua            opts schema, defaults, validation
log.lua               vim.notify wrapper

task/
  fields.lua          emoji + dataview field spec (single source of truth)

  parse.lua           line → Task
  serialize.lua       Task → line
  status.lua          default statuses + cycle (Todo/Done/InProgress/Cancelled/OnHold)
  recurrence.lua      v1: parse+preserve; v2: compute next

query/                filter/sort/group/limit/hide AST + evaluation
index/                in-memory task index (refresh on demand)
render/               extmark-based render + edit-through
cmd/                  :ObsidianTask dispatcher + subcommand modules
cmp/                  blink.cmp source + date NL parser
util/                 buf, extmark, fs, obsidian adapter
```

## Dev loop

```sh
make lint    # selene + stylua --check
make format  # stylua (in-place)
make test    # headless nvim + mini.test
make ci      # lint + test
```

## Testing

Framework: **mini.test**. Test files in `tests/unit/test_*.lua`.
Fixture vault: `tests/fixtures/vault/` (marked by `.obsidian/`).
Run locally: `make test` (clones mini.nvim to `.deps/` on first run).

## Style

- **stylua**: 2-space indent, 120 col, `call_parentheses = "Always"` (see `stylua.toml`)
- **selene**: `std = "vim+lua51"` (see `selene.toml`)

## Source of truth

- `.jr/plans/requirements_v1.md` — confirmed scope decisions
- `.jr/plans/implementation.md` — module layout, phase plan, risks

## BufWritePre ordering

We subscribe to `User:ObsidianNoteWritePre` (not raw `BufWritePre`) so our render-strip fires AFTER obsidian.nvim has finished updating frontmatter; any future feature that must mutate the buffer before write should also use this User event.

## Convention

Append to this file only when a future agent would otherwise miss a non-obvious
project-specific pattern. Do NOT document things derivable by reading the code.

# Notes

nvim --headless ... -c q is not reliably terminating in this project when foldtext expressions are set. Prefer nvim --headless ... -c 'qa!' or run via a script with an explicit vim.cmd('quitall!') after assertions.\_

## Insert-mode tests must use real keypresses

Tests that simulate edits via `vim.api.nvim_buf_set_lines()` (or `set_line()` helpers) do NOT exercise the real-mode path: `vim.fn.mode()` returns `'n'` during programmatic edits, so the on_lines_hook / flush / do_revert mode gates never take the insert-mode branch. Calling such tests "insert-mode tests" is misleading.

Real insert-mode tests must drive a `MiniTest.new_child_neovim()` with `child.type_keys(...)` (which uses `nvim_input` under the hood — terminal-equivalent), then `vim.loop.sleep(...)` so `vim.schedule` callbacks drain. Examples: `tests/integration_real/test_real_insert_mode.lua`, `tests/integration_real/test_e2e_edit_in_place.lua`.

## vim.schedule fires between keystrokes

`vim.schedule()` callbacks fire on the main event loop, which yields between user keystrokes while in insert/replace mode. Anything scheduled from `on_lines` will run mid-typing — `do_revert` rerendering or `flush` writing a half-typed line will corrupt the user's in-flight edit. The fix is to gate **at execution time** inside `flush()` / `do_revert()`: check `vim.fn.mode():match("[iR]")` and bail (resetting any debounce flag), then drain explicitly from the InsertLeave autocmd. See `lua/obsidian-tasks/render/edit.lua` and `render/revert.lua`.

## `require("obsidian-tasks.render")` vs `require("obsidian-tasks.render.init")`

Lua's `package.loaded` cache normally treats these two require strings as separate keys, so each would load `render/init.lua` into a fresh module instance with its own `_buffer_state`. `lua/obsidian-tasks/render/init.lua` aliases both keys at the top to a single M to prevent this — if you ever split that file, restore the alias or expect "empty `_buffer_state[bufnr]`" / "nil `_lingers`" type bugs.
