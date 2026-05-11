# Invalid dates

Edge case: tasks with malformed date emoji values. Exercises `due date is invalid` filter.

- [ ] Task with bad due date #task #edge 📅 not-a-date
- [ ] Task with year-only due #task #edge 📅 2026
- [ ] Task with valid due #task #edge 📅 2026-06-15
- [ ] Task with bad scheduled #task #edge ⏳ tomorrow

## Query: tasks with invalid due dates

```tasks
due date is invalid
```
