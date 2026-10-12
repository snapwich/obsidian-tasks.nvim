---
status: accepted
---

# Dashboards save through a buffer-local BufWriteCmd

A dashboard buffer holds rendered rows that must never reach disk. A
buffer-local `BufWriteCmd` (`render/save.lua`) writes only the non-managed rows
and never changes the buffer; it fires `BufWritePost` itself so re-render
propagation still runs. Because `BufWriteCmd` replaces the built-in write,
`BufWritePre` does not fire, so no other plugin can change the buffer just
before our filter.

## Considered Options

- Strip rendered rows in `BufWritePre` (later `User:ObsidianNoteWritePre`, so
  obsidian.nvim could update frontmatter first), write, then re-render.
  Rejected: flicker, undo pollution, and races.
- `buftype=acwrite`. Rejected: plugins such as trouble.nvim treat only
  `buftype == ""` as a normal file buffer.
