# Boolean combinators

## AND: due before tomorrow AND not done

```tasks
(due before tomorrow) AND (not done)
```

## OR: high priority OR has #bug tag

```tasks
(priority above medium) OR (tag includes #bug)
not done
```

## NOT: not high-priority

```tasks
NOT (priority above medium)
not done
```

## Complex: open work that is high-priority OR has a near-term due date

```tasks
(path includes work) AND (not done) AND ((priority above medium) OR (due before 2026-05-20))
```
