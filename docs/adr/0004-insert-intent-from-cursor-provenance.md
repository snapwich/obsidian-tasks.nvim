---
status: accepted
---

# Insert intent comes from cursor provenance, not keymaps

A group header is a virtual line attached to the first task of its group, so a
line inserted between two groups is the same buffer change for `O` on the lower
task and `o` on the upper task. To know which group the user meant, we track the
cursor row before each change (`CursorMoved` / `CursorMovedI`) and compare it
with the insert row in `on_lines`: cursor on the pushed-down task means "above
it" (the header moves up to the new line), cursor on the row above means "below
it". We do not map `o` / `O` / `P`, so `:put!`, `<C-o>O`, counts, and plugins
that remap put (yanky, substitute) all work and nothing conflicts.

`CursorMoved` does not fire between the keys of one command, so `:normal! ko`
or a macro would compare against a stale row. A namespaced `vim.on_key`
listener also stores the cursor row just before each key. It sees the keys
that `:normal`, macros, and mappings execute, and it returns at once when the
current buffer is not a dashboard.

## Considered Options

- Buffer-local `O` / `P` mappings that record intent. Rejected: they override
  other plugins' mappings and miss `:put!` and remaps.
- Render group headers as real read-only buffer rows. Rejected for now: a large
  change across draw, save, folds, cursor, and delete handling.
- The cursor read inside the `on_lines` callback. Rejected: it is not reliable
  (`o` already shows the new row there).
- `CursorMoved` / `CursorMovedI` alone. Rejected: the row is stale when one
  command moves the cursor and inserts (`:normal! ko`).

## Consequences

- An insert from code with no relation to the cursor (`nvim_buf_set_lines` from
  another plugin) also uses the cursor rule. The result is harmless: the task
  goes to the group that shows on screen.
- Lua code that moves the cursor and changes the buffer in one call, with no
  key between (`nvim_win_set_cursor` then `nvim_buf_set_lines`, or a `:put!`
  run from Lua after a cursor move), compares against the row from before that
  call. `vim.on_key` sees only the key that started the call.
