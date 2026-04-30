# Go Style Rules

These are the Go-specific conventions Claude should follow when writing or
reviewing Go code in this project. They supplement (do not replace)
`golangci-lint`, which enforces the mechanical ones automatically.

## Errors

- Wrap errors crossing package boundaries with `fmt.Errorf("context: %w",
  err)`. Use `%w`, not `%v` or `%s`. `%w` is the only form that preserves
  chain compatibility with `errors.Is` / `errors.As`.
- Match errors with `errors.Is(err, ErrSentinel)` or `errors.As(err,
  &typedErr)`. Never string-match on `err.Error()` — that breaks the
  moment someone adds context wrapping.
- Library code returns errors. It does not `panic`. Panic is for
  programmer errors (invariant violations), not for recoverable runtime
  conditions.
- Errors that callers are meant to distinguish should be exported
  sentinels (`var ErrNotFound = errors.New("not found")`) or exported
  types. Errors that are purely informational don't need to be exported.
- Never log an error and then return it. The caller logs, or the handler
  at the top of the stack logs. Duplicate logging produces noise and
  makes tracing an error's path harder.
- Prefer `errors.AsType[T]` (Go 1.26+) over `errors.As` for new code.

## Context

- `context.Context` is the first parameter of any function that does I/O,
  waits, or may block. Including transaction helpers, HTTP clients, DB
  queries, and goroutine-spawning functions.
- Never `context.TODO()` or `context.Background()` inside a handler,
  worker, or anything with an ambient ctx. Only acceptable at process
  boundaries (`main`, tests, startup code).
- Do not store `context.Context` in a struct. Pass it as a parameter.
- Context values (`ctx.Value(key)`) are for request-scoped data that
  every layer needs (request ID, trace ID, user identity). Not for
  passing regular parameters.
- A timeout at the top of a request handler covers the whole request:
  `ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second); defer cancel()`.

## Formatting and names

- `gofmt` + `goimports` are not negotiable. The post-edit hook runs them
  automatically.
- Exported identifiers need doc comments that start with the identifier's
  name: `// OrderID identifies an order uniquely within...`
- Package names are short, lowercase, single-word where possible. No
  `orders_package`, no `OrdersPackage`, no `pkg_orders`.
- Receiver names are short and consistent within a type (one or two
  letters). `o *Order`, not `order *Order` or `this *Order`.
- Acronyms keep their case: `orderID`, `HTTPClient`, `userURL` — never
  `orderId`, `HttpClient`, `userUrl`.

## API design

- Keep public API minimal. Do not export unless externally needed.
- Do not create single-implementation interfaces "for testability". Use
  a fake struct in `_test.go` instead.
- Prefer accepting small interfaces at package boundaries; returning
  concrete types.
- Document concurrency safety for exported types.

## Money and precision

- Never `float64` for money, currency exchange rates, balances, prices,
  or quantities. Use `int64` (minor units), `math/big.Rat`, or
  `shopspring/decimal.Decimal`.
- `decimal.Decimal` zero value is usable (= zero), but compare with
  `d.IsZero()` not `d == decimal.Zero`.
- Decimal arithmetic: `d.Add`, `d.Sub`, `d.Mul`, `d.Div`. `Div` can
  return an error (division by zero) — handle it.

## Time

- `time.Now().UTC()` in persistence paths, not `time.Now()`. Local time
  in persisted values causes surprises across DST boundaries and across
  deployments.
- Parse times with explicit layouts (`time.RFC3339`, custom layouts).
- Durations as `time.Duration`, not `int` or `int64`. The type system
  prevents mixing seconds and milliseconds.

## Slices and maps

- Prefer `slices.Equal`, `slices.Contains`, `slices.Index`, `slices.Sort`,
  `slices.SortFunc` from the standard library.
- Prefer `maps.Keys`, `maps.Values`, `maps.Equal`, `maps.Clone`.
- `clear(m)` to empty a map in place; `clear(s)` to zero a slice.
- Preallocate slice capacity when the size is knowable: `s := make([]T, 0, n)`.
- `any` instead of `interface{}` everywhere.

## Concurrency

- Every `go func()` has a defined exit condition — otherwise it's a leak.
- `sync.Mutex` over `sync.RWMutex` unless the read/write ratio justifies
  the complexity. RWMutex is not free.
- `defer mu.Unlock()` directly after `mu.Lock()`. Never write code
  between the lock and the defer.
- `sync.Once` for one-time initialization inside a function. For
  package-level one-time init, use a plain `var` — Go guarantees
  single initialization of package-level variables.
- Pointer receivers on types containing sync primitives. Do not copy
  mutexes after first use.
- Stop tickers and timers in all paths.
- Sender closes channels, never receiver.
- `golang.org/x/sync/errgroup` for concurrent operations with error
  aggregation. Prefer `errgroup.WithContext(ctx)` so a single failure
  cancels siblings.

## Project layout

- `cmd/<name>/main.go` for each binary.
- `internal/` for packages not meant to be importable from other modules.
- `pkg/` only if a package is genuinely meant to be importable by
  third parties (rare).
- Interfaces live with the consumer, not the producer. A package that
  needs to call into something defines the interface; the implementation
  lives elsewhere and is injected via the constructor.
- Small interfaces. If you find yourself with an interface that has more
  than five methods, look for a narrower one.

## Logging

- Structured logging via `log/slog`.
- `slog.InfoContext(ctx, "msg", "key", value)` so context-carried fields
  (request ID, trace ID) flow through automatically.
- Log levels: `DEBUG` for development tracing, `INFO` for normal
  operation events, `WARN` for recoverable anomalies, `ERROR` for
  failures the caller should know about.
- Never log credentials, tokens, or request/response bodies that may
  contain them. `%+v` on a config struct is a common leak path.
- `slog.NewMultiHandler` (Go 1.26+) replaces ad-hoc multi-writer wrappers.

## Go 1.26+ specifics

- `new(expr)` is preferred for optional pointer fields. Run `go fix` to
  migrate.
- `errors.AsType[T]` is preferred over `errors.As` for new code.
- Crypto: do NOT rely on the random parameter to `crypto/*.GenerateKey`
  — it is ignored.
- `t.ArtifactDir()` for test artifacts to preserve.
- `testing.TB.Context()` for test contexts.

## Dependencies

- Every `go.mod require` should be a tagged release, not a
  `v0.0.0-timestamp-commitsha` pseudo-version (unless the package has
  no releases, which is itself a yellow flag).
- `go mod tidy` before every PR.
- Every new `require` line must be on `.claude/allowed-modules.txt`
  (slopsquatting defense). See `go-security.md`.
- `govulncheck ./...` clean in CI.
