# Heading queries

Exercises the `heading` field for filtering, sorting, and grouping.
Tasks inherit the nearest ATX heading above their source line; tasks above
any heading group under `(No heading)`.

## Group by heading

```tasks
not done
group by heading
```

## Sort by heading

```tasks
not done
sort by heading
```

## Heading includes "Stretch"

```tasks
heading includes Stretch
```

## Heading does not include "Stretch"

```tasks
heading does not include Stretch
not done
```

## Heading regex matches

```tasks
heading regex matches /Sprint|Stretch/
```
