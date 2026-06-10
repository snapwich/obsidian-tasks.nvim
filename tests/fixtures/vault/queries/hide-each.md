# Hide subkeys

One query block per hide variant. Each query is identical except for which display element is hidden.

## hide priority

```tasks
not done
limit 3
hide priority
```

## hide due date

```tasks
not done
has due date
limit 3
hide due date
```

## hide scheduled date

```tasks
has scheduled date
limit 3
hide scheduled date
```

## hide start date

```tasks
has start date
limit 3
hide start date
```

## hide done date

```tasks
done
limit 3
hide done date
```

## hide created date

```tasks
has created date
limit 3
hide created date
```

## hide cancelled date

```tasks
has cancelled date
limit 3
hide cancelled date
```

## hide recurrence rule

```tasks
is recurring
limit 3
hide recurrence rule
```

## hide on completion

```tasks
not done
limit 3
hide on completion
```

## hide tags

```tasks
not done
limit 3
hide tags
```

## hide id

```tasks
not done
limit 3
hide id
```

## hide depends on

```tasks
not done
limit 3
hide depends on
```

## hide backlinks (i.e. trailing wikilink)

```tasks
not done
limit 3
hide backlinks
```

## hide task count

```tasks
not done
limit 3
hide task count
```

## hide tree

`hide tree` is the default (flat), so it only demonstrates anything next to a
`show tree` block over the same data. Scoped to `#project/web` because
`projects/web/web-roadmap.md` is the only vault file with nested tasks.

```tasks
tag includes #project/web
hide tree
```

## show tree (contrast for hide tree)

```tasks
tag includes #project/web
show tree
```
