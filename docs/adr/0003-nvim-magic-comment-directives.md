---
status: accepted
---

# Neovim-only query directives use a strict `# nvim:` comment namespace

Neovim-only query instructions (first one: `# nvim: sort groups by <key> [reverse]`)
are written as `# nvim: <directive>` comment lines. Upstream obsidian-tasks
ignores all `#` lines but treats an unknown bare instruction as a fatal query
error, so a comment is the only form that keeps the same query block valid in
the Obsidian desktop app. On our side the namespace is strict: a `# nvim:` line
that does not parse is a fatal parse error, so typos show instead of becoming
silent comments. Plain `#` comments stay free-form.

## Consequences

- The carve-out in `query/parse.lua` must run before the blank / `#` skip.
- Cross-directive checks (for example sort-groups without `group by`) must run
  after the line loop, because directives can come in any order.
