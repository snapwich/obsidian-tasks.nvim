# Sub-item filter

The roadmap (`projects/web/web-roadmap.md`) contains parent tasks with indented sub-tasks. This query excludes the indented children.

## Top-level only (exclude sub-items)

```tasks
not done
path includes roadmap
exclude sub-items
```

## All tasks for comparison (sub-items included)

```tasks
not done
path includes roadmap
```
