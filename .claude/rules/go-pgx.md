# pgx/v5 Rules

Rules specific to `github.com/jackc/pgx/v5` — the database driver
assumed by this starter pack. If your project uses `database/sql` with
lib/pq, or a different driver, adapt these or supersede them with a
project rules file.

## Context is mandatory

- Every pgx call takes a `ctx context.Context` as its first argument.
  There is no "context-less" variant.
- The ctx MUST be the caller's. Never `context.Background()` inside a
  query path — the caller's timeout and cancellation signal need to
  reach the DB layer.
- A ctx timeout should be set at the request boundary (handler entry)
  and propagate through. Don't add per-query timeouts unless the
  operation is expected to take longer than the request budget.

## Parameterized queries, always

- Every query uses `$1`, `$2`, ... placeholders. Never `fmt.Sprintf`
  into a SQL string with user input.
- For `IN (...)` clauses where the length varies, use
  `pgx.QueryRewriter` or `= ANY($1)` with an array parameter. Never
  build a comma-separated list of placeholders dynamically from
  user-controlled input.
- Dynamic identifiers (table names, column names) cannot be parameterized.
  If they come from user input, validate against an allowlist and use
  `pgx.Identifier.Sanitize()`. If they come from trusted config, a
  simple allowlist check is sufficient.

## Pool vs connection

- `*pgxpool.Pool` is the default. Every package that talks to the DB
  takes a `*pgxpool.Pool` as a dependency.
- `pool.Acquire(ctx)` only when you need a dedicated connection (LISTEN,
  advisory locks, prepared statement reuse across multiple queries).
  Always `defer conn.Release()`.
- Pool size: `pool.Config().MaxConns`. Default is `max(4, runtime.NumCPU())`.
  Explicit configuration in startup code is preferred over defaults.

## Transactions

### The canonical pattern

```go
err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
    if _, err := tx.Exec(ctx, "INSERT ...", args...); err != nil {
        return err
    }
    if _, err := tx.Exec(ctx, "UPDATE ...", args...); err != nil {
        return err
    }
    return nil
})
```

`pgx.BeginFunc` handles commit on success and rollback on error.
Use this pattern unless you need manual control.

### Manual transaction control (use only when necessary)

```go
tx, err := pool.Begin(ctx)
if err != nil {
    return err
}
defer func() { _ = tx.Rollback(ctx) }()  // safe after commit; no-op

// ... work ...

return tx.Commit(ctx)
```

The `defer tx.Rollback(ctx)` is important: it catches panics and early
returns. Rollback after a successful commit is a no-op (returns
`pgx.ErrTxClosed`), which we ignore.

### Transaction boundaries

- A transaction should be short. No HTTP calls, no waits, no log flushes
  inside a transaction. Transactions hold row locks; long-running
  transactions cause contention.
- If you need a multi-step operation that includes external calls,
  split it: do the external work first, then a quick transaction to
  persist the result. Or use outbox patterns.
- Never span a transaction across a goroutine boundary. pgx
  transactions are not safe to share between goroutines.

### Savepoints and nested transactions

- pgx does not support true nested transactions, but supports savepoints
  via `tx.Begin(ctx)` (which starts a savepoint if called on a Tx).
- Useful for "try this, rollback to before if it fails, continue the
  outer transaction." Rare pattern. Don't reach for it by default.

## Query result handling

### Single row

```go
var id int64
var name string
err := pool.QueryRow(ctx, "SELECT id, name FROM users WHERE email = $1", email).
    Scan(&id, &name)
if errors.Is(err, pgx.ErrNoRows) {
    return nil, ErrUserNotFound
}
if err != nil {
    return nil, fmt.Errorf("query user: %w", err)
}
```

`pgx.ErrNoRows` is the sentinel. Check for it explicitly when no-rows
is a valid outcome (vs. an error).

### Multiple rows

```go
rows, err := pool.Query(ctx, "SELECT id, name FROM users WHERE active = true")
if err != nil {
    return nil, fmt.Errorf("query users: %w", err)
}
defer rows.Close()

users, err := pgx.CollectRows(rows, pgx.RowToStructByName[User])
if err != nil {
    return nil, fmt.Errorf("collect users: %w", err)
}
```

- `defer rows.Close()` IMMEDIATELY after the successful query. Never
  after intermediate work — a panic between could leak the connection.
- `pgx.CollectRows` + `pgx.RowToStructByName[T]` is the idiomatic v5
  pattern. Prefer it over manual `for rows.Next() { ... Scan(...) }`
  unless you need streaming semantics.
- For streaming, check `rows.Err()` after the loop to catch iteration
  errors.

### Exec (no rows expected)

```go
tag, err := pool.Exec(ctx, "UPDATE users SET active = false WHERE id = $1", id)
if err != nil {
    return fmt.Errorf("deactivate user: %w", err)
}
if tag.RowsAffected() == 0 {
    return ErrUserNotFound
}
```

Always check `RowsAffected` when the update's success depends on the
row existing. Don't assume the `UPDATE` hit a row.

## pgtype — the typed value layer

pgx/v5 uses `pgtype` for Postgres-native types that don't map cleanly to
Go built-ins.

### Nullable fields

- `pgtype.Text` for nullable strings. Has `.Valid` bool and `.String`.
- `pgtype.Int4` / `pgtype.Int8` for nullable integers.
- `pgtype.Timestamptz` for nullable timestamps. Always prefer `timestamptz`
  over `timestamp` at the schema level — naive timestamps are a bug
  waiting to happen.
- `pgtype.UUID` for UUIDs. Has `.Bytes` and `.Valid`.

### When to use pgtype vs Go primitives

- If the column is `NOT NULL`, use the Go primitive (`string`, `int64`,
  `time.Time`).
- If the column allows `NULL` and you need to distinguish NULL from
  zero, use `pgtype`.
- For JSON columns, scan into `[]byte` and unmarshal — don't scan
  directly into a Go struct unless you've registered a custom type.

### UUIDs

- `pgtype.UUID` is the idiomatic scan target.
- For new UUIDs in Go code, `github.com/google/uuid` is the conventional
  library. `uuid.New()` for a random v4.

## Batching

- For bulk inserts, `pgx.Batch` + `pool.SendBatch(ctx, batch)` is much
  faster than a loop of individual `Exec`.
- For bulk loads, `pool.CopyFrom(ctx, ..., pgx.CopyFromRows(...))` is
  the fastest path.
- Don't batch across transaction boundaries unless you understand the
  implications. A batch is a single round-trip, but individual queries
  inside are still subject to the current transaction context.

## LISTEN / NOTIFY

- Requires a dedicated connection: `conn, err := pool.Acquire(ctx);
  defer conn.Release()`.
- `conn.Conn().WaitForNotification(ctx)` blocks until a notification
  arrives or ctx is done.
- The goroutine that calls `WaitForNotification` is blocked indefinitely
  otherwise — make sure your ctx has a deadline or shutdown signal.

## Prepared statements

- pgx automatically prepares and caches statements by default. You
  generally don't need to call `Prepare` yourself.
- If you do (for performance-critical paths), the cached statement is
  scoped to the connection — reuse requires the same connection.

## Migrations are out of scope

- This pack does not prescribe a migration tool. Common choices:
  `golang-migrate/migrate`, `pressly/goose`, `pgx/cli` + SQL files.
- Whatever tool you use, the `migrations/` directory is gated in
  `.claude/settings.json`'s `ask` list AND by `guard-protected-files.sh`.
  Migration edits require human approval.
- Migrations are also Tier 1 by default in `.tdd/tdd-config.json`.

## Common pitfalls

- **Not closing rows.** Every `rows, err := pool.Query(...)` must have
  a matching `defer rows.Close()`.
- **Using `pool.Query` when you want a single row.** `QueryRow` is
  ergonomically better and handles no-rows as an error you can check.
- **Scanning into pointers to primitives without handling NULL.** If
  the column can be NULL, scan into `pgtype.X`, not `*string` / `*int`.
- **Long-running transactions.** Transactions around HTTP calls,
  filesystem work, or logging flushes are a known production-incident
  pattern.
- **Mixing `pool.Exec` and `tx.Exec` inside what should be one
  transaction.** Easy to do when refactoring. The compiler won't catch
  this — only careful review will.
