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

## Considered Options

- Buffer-local `O` / `P` mappings that record intent. Rejected: they override
  other plugins' mappings and miss `:put!` and remaps.
- Render group headers as real read-only buffer rows. Rejected for now: a large
  change across draw, save, folds, cursor, and delete handling.
- The cursor read inside the `on_lines` callback. Rejected: it is not reliable
  (`o` already shows the new row there).

## Consequences

- An insert from code with no relation to the cursor (`nvim_buf_set_lines` from
  another plugin) also uses the cursor rule. The result is harmless: the task
  goes to the group that shows on screen.
