---
status: accepted
---

# Source writes are disk-authoritative and refuse on unsaved buffers

All dashboard edits to a source note go through `cmd.apply_source_edit`. It
reads the file from disk, applies the change, writes it with `writefile`, and
then syncs any loaded buffer of that file. If the source note is open with
unsaved changes, the write is refused and the dashboard row is reverted, because
a disk write would discard those changes and a buffer edit would make the
dashboard show content that is not on disk. The dashboard's own buffer is the
one exception: it is always modified (rendered rows), so a narrow same-row
buffer edit is used there.

## Considered Options

- Edit the loaded buffer in place of the disk. Rejected for v1: it needs a
  second write path, and other dashboards do not see the change until the user
  saves. A follow-up to improve this UX is tracked in the project note.
