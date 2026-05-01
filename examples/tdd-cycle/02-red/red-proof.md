# Red Proof: cents-add — minor-units money type with safe addition

**Date:** 2026-05-01
**Plan:** `.tdd/current-plan.md`

## Command run

```bash
go test -race -count=1 ./internal/payments/...
```

## Output (verbatim)

```text
# example/internal/payments [example/internal/payments.test]
internal/payments/cents_test.go:11:13: undefined: Cents
internal/payments/cents_test.go:11:25: undefined: Cents
internal/payments/cents_test.go:14:31: undefined: Cents
internal/payments/cents_test.go:21:13: undefined: Cents
internal/payments/cents_test.go:21:25: undefined: Cents
internal/payments/cents_test.go:24:31: undefined: Cents
internal/payments/cents_test.go:31:13: undefined: Cents
internal/payments/cents_test.go:32:13: undefined: Cents
internal/payments/cents_test.go:38:18: undefined: ErrOverflow
internal/payments/cents_test.go:42:25: undefined: Cents
FAIL    example/internal/payments [build failed]
FAIL
```

## What this red proves

The 4 acceptance-criterion tests (`TestCents_Add_When_Normal_Then_Sum`,
`TestCents_Add_When_BothZero_Then_Zero`,
`TestCents_Add_When_Overflow_Then_Error`, `TestCents_JSONRoundTrip`)
all reference `Cents` and `ErrOverflow`, neither of which is defined
yet. The package fails to compile. After implementation, all four
tests must pass.

## Why this is not a false red

- The failure is a real compile error, not a missing-import or typo
  on the test side. The test file is syntactically valid; the
  package just lacks the symbols `Cents` and `ErrOverflow`.
- The test file is in the same package (`package payments`), not a
  `_test` external package, so the symbols would be visible if
  defined.
- Running `go vet ./internal/payments/...` reports the same undefined
  identifiers — independent confirmation the symbols truly don't
  exist, not a `-tags` filter quirk.
- The build error references the exact line numbers of the
  acceptance-pinned assertions, not unrelated code.

## Expected green signal

```bash
$ go test -race -count=1 ./internal/payments/...
ok      example/internal/payments    0.234s
```

All 4 tests PASS, no race detector warnings, no other packages broken.

## Reviewer confirmation

Human approved implementation at: 2026-05-01 (illustrative timestamp)
