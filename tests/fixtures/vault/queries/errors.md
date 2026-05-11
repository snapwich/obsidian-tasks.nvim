# Errors & unsupported syntax

These blocks intentionally use unsupported or malformed syntax to verify the plugin surfaces errors gracefully (does not crash).

## `where filter by function` — unsupported in nvim port

```tasks
where filter by function task.urgency > 5
```

## v2-deferred features: `is blocked` / `is blocking`

```tasks
is blocked
```

```tasks
is blocking
```

## Malformed: unknown keyword

```tasks
xyzzy not a real keyword
```

## Malformed: invalid date

```tasks
due before notarealdate
```
