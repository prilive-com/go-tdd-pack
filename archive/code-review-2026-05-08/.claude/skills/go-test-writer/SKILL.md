---
name: go-test-writer
description: Write or extend Go tests following team conventions — table-driven, race-enabled, with pgx (testcontainers / pgxmock) and HTTP (httptest) patterns. Use when the user asks to add tests, write a test, write a regression test, write a fuzz/property test, or extend test coverage. Verifies results before reporting done.
license: MIT
version: 1.1.0
---

# Go Test Writer

Write or extend tests for Go code in this repo.

## Conventions (non-negotiable)

- **Table-driven by default.** Unless the scenario is genuinely
  non-tabular, write a `tests := []struct{...}` slice with subtests.
- **Use `t.Run(tt.name, ...)` for subtests.** Enables
  `-run TestX/subname` filtering.
- **`require` for setup errors, `assert` for assertions.** Stop
  execution on setup failure (no point continuing); accumulate
  assertion failures. From `github.com/stretchr/testify/require` and
  `.../assert`.
- **`t.Helper()` in test helpers.** Points failures at the caller, not
  the helper.
- **`t.Cleanup(func(){...})` over `defer`.** Runs in reverse order of
  registration and survives `t.Parallel`.
- **`t.Parallel()` for leaf tests.** Not for tests that share mutable
  state.
- **`t.Setenv(...)`** when testing env-var-reading code.
- **`testdata/` for fixture files.** Go test runner ignores this
  directory name.

## Test types and when to use each

### Unit test

Pure functions, small struct methods, no I/O. Table-driven default.

### Integration test

Anything touching a DB, filesystem, network, or concurrency. Uses real
dependencies where feasible: `testcontainers-go` Postgres for pgx
code, `httptest.NewServer` for HTTP clients. Build tag
`//go:build integration` if the repo separates slow tests.

### Race test

Required when goroutines are involved. Run via `go test -race`. Test
body should exercise concurrent paths (spawn goroutines that hit the
shared state simultaneously).

### Fuzz test

Required for parsers, decoders, anything handling untrusted input.
`func FuzzXxx(f *testing.F)` with `f.Add(...)` seed corpus. Run via
`go test -fuzz=FuzzXxx -fuzztime=30s` locally. Corpus under
`testdata/fuzz/FuzzXxx/`.

### Property test

When a function has clear invariants (parsers: parse(format(x)) = x;
encoders: decode(encode(x)) = x). `pgregory.net/rapid` is the
preferred library.

### Benchmark

Only when performance matters to the change.
`func BenchmarkXxx(b *testing.B)` with `b.ReportAllocs()`.

## pgx/v5 testing patterns

### Preferred: testcontainers-go

```go
func setupTestDB(t *testing.T) *pgxpool.Pool {
    t.Helper()
    ctx := context.Background()
    container, err := postgres.Run(ctx, "postgres:16-alpine",
        postgres.WithDatabase("test"),
        postgres.WithUsername("test"),
        postgres.WithPassword("test"),
    )
    require.NoError(t, err)
    t.Cleanup(func() { _ = container.Terminate(ctx) })

    dsn, err := container.ConnectionString(ctx, "sslmode=disable")
    require.NoError(t, err)

    pool, err := pgxpool.New(ctx, dsn)
    require.NoError(t, err)
    t.Cleanup(pool.Close)

    require.NoError(t, applyMigrations(ctx, pool))
    return pool
}
```

### Acceptable: pgxmock for pure-logic tests

```go
mock, err := pgxmock.NewPool()
require.NoError(t, err)
defer mock.Close()

mock.ExpectQuery("SELECT id, name FROM users WHERE id = \\$1").
    WithArgs(42).
    WillReturnRows(pgxmock.NewRows([]string{"id", "name"}).
        AddRow(42, "alice"))
```

### Never

- SQLite as a Postgres stand-in. Dialect drift produces false positives
  and false negatives.
- Hand-rolled mocks of `pgxpool.Pool`. Always `pgxmock`.

## HTTP testing patterns

### Client code: `httptest.NewServer`

```go
srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    assert.Equal(t, "/orders", r.URL.Path)
    w.WriteHeader(http.StatusOK)
    _, _ = w.Write([]byte(`{"id":1}`))
}))
t.Cleanup(srv.Close)
client := NewClient(srv.URL)
```

### Handler code: `httptest.NewRecorder`

```go
rr := httptest.NewRecorder()
req := httptest.NewRequest(http.MethodGet, "/orders/42", nil)
req = req.WithContext(authCtx(t, userID))
router.ServeHTTP(rr, req)
assert.Equal(t, http.StatusOK, rr.Code)
```

## Context in tests

- Always pass a ctx with a timeout derived from `t.Context()` (Go 1.24+)
  or `context.WithTimeout(context.Background(), 5*time.Second)`.
- Never use `context.TODO()` in tests.

## Verification before done

Before reporting a test complete, run it:

```bash
go test -race -count=1 ./path/to/package/...
```

If the test uses goroutines, `-race` is mandatory.

Report:

- The exact command run
- PASS/FAIL
- If FAIL, the failure output verbatim — don't paraphrase

## Anti-patterns to avoid

- **Weakening an assertion to make a failing test pass.**
- **Mocking the code under test.**
- **`sleep`-based synchronization.** Use `sync.WaitGroup`, channels,
  or deadline-based ctx.
- **Skipping a failing test with `t.Skip`.** If it's broken, fix it or
  delete it.
- **Testing implementation details.**
- **No cleanup.** Every `Open`, `Connect`, `Dial`, `NewServer` needs a
  `Cleanup` or `Close` paired with it.
