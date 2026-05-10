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
index/                in-memory task index + vault watcher
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

## Convention

Append to this file only when a future agent would otherwise miss a non-obvious
project-specific pattern. Do NOT document things derivable by reading the code.
