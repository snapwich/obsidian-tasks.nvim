---
status: accepted
---

# Group-top inserts go to today's daily note through a pluggable resolver

A task typed in the group-top slot has no anchor, so it has no source note. We
write it to today's daily note: in the matching heading section for a heading
group, with the group attribute for a tag / priority / status group. A filename
group uses that file, and folder / path / root groups keep the below-fence
fallback, because a daily note would put the task in a different group. A
no-anchor line in a dashboard with no `group by`, or with zero results, also
goes to the daily note (end of file). Group keys that name no place (dates,
backlink, urgency, …) keep the below-fence fallback. Daily notes belong to
obsidian.nvim, not to this plugin, so the path comes from
`opts.daily_note = function(date) -> path|nil`. The default resolver uses
obsidian.nvim when it is loaded (and its templates when it creates a note);
without a resolver the daily-note targets are off (a filename group still uses
its file).

## Considered Options

- Insert before the first task of the group, in that task's note. Rejected: the
  user's flow is to capture new work in the day's note, and the position, not
  the key, decides placement.
- Read `.obsidian/daily-notes.json` ourselves. Deferred: it needs moment.js
  format conversion and template support. It can become another default
  resolver later.

## Consequences

- When the target note is the dashboard itself, or is open as another
  dashboard, the line keeps the below-fence fallback: a source write cannot map
  into a dashboard buffer whose rendered rows are not on disk.
