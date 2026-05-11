---
tasks-plugin:
  ignore: true
title: Second ignored note
---

# Second ignored note

A second file with `tasks-plugin.ignore: true` in frontmatter. Both this and `ignored_note.md` must be excluded from the index — useful as a smoke test that one ignore doesn't mask another.

(Note: the flat-key form `tasks-plugin.ignore: true` is NOT supported because obsidian.nvim's YAML parser collapses dotted keys.)

- [ ] This task must NOT appear in any query #task #edge
- [ ] Neither should this one #task #edge
