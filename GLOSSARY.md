# obsidian-tasks.nvim

A Neovim port of the Obsidian Tasks plugin: it finds tasks in an Obsidian vault
and shows live, editable query results inside notes.

## Language

### Vault and tasks

**Vault**:
A folder tree that has a `.obsidian/` marker folder at its root.
_Avoid_: workspace (an obsidian.nvim term for a configured vault)

**Note**:
A markdown file in a vault.
_Avoid_: page, document

**Task**:
A list item with a checkbox (`- [ ] …`) whose description contains the global filter, if one is set.
_Avoid_: todo, item, checkbox

**Description bullet**:
A list item with no checkbox inside a task's subtree.
_Avoid_: sub-item, note line

**Status**:
The meaning of a task's checkbox symbol (Todo, Done, In Progress, Cancelled, On Hold).
_Avoid_: state

**Global filter**:
A string that a list item's description must contain to count as a task.

**Daily note**:
The note for one calendar day, found by the daily-note resolver.
_Avoid_: journal, today file

**Daily-note resolver**:
The configured function that gives the path of the daily note for a date.

### Queries and dashboards

**Query block**:
A ` ```tasks ` fenced block in a note that holds query instructions.
_Avoid_: query, code block

**Directive**:
One instruction line in a query block (`not done`, `group by heading`, `# nvim: sort groups by …`).
_Avoid_: rule, clause

**Dashboard**:
A note buffer that shows the results of one or more query blocks.
_Avoid_: view, query page

**Source note**:
The note where a task really is, as opposed to its copy in a dashboard.
_Avoid_: origin file, backing file

**Managed row**:
A dashboard row that shows a task (or tree row) from a source note; it exists only in the buffer and is never saved to the dashboard's file.
_Avoid_: rendered line, virtual task

**Edit-through**:
The behavior where an edit to a managed row is written to the task's source note.
_Avoid_: sync, write-back

**Linger**:
A task that stopped matching its query (for example, just completed) and stays visible, dimmed, until the next refresh.
_Avoid_: ghost, stale row

### Groups

**Group**:
The tasks of a query result that share one value of a `group by` key.

**Group header**:
The label shown above the first task of a group; it is not a buffer row.
_Avoid_: heading (that is a markdown heading in a note)

**Location group**:
A group whose key is a place (heading, filename, folder, path, root), so membership comes from where the task is, not from its attributes.

**Group attribute**:
The tag, priority, or status that defines a group; it is added to a task inserted into that group.

**Group-top slot**:
The position directly below a group header and above the first task of the group — the only position with no task above it in that group.
_Avoid_: top of group (ambiguous: can mean the end of the group above)

**Anchor**:
The task directly above an inserted line in the same group; the new task is written after it, in its source note.

### Tree mode

**Matched task**:
A task in a `show tree` result that satisfies the query itself.
_Avoid_: lit row, hit

**Breadcrumb**:
A dimmed ancestor of a matched task, shown for context, that does not satisfy the query.
_Avoid_: dim row, connector

**Subtree drag**:
The rule that a matched task's descendants show in the task's group, whatever their own attributes.
