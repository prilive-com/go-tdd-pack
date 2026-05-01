# Feature Plan: cents-add — minor-units money type with safe addition

Status: idle
Cycle ID: cents-add
Change type: feature
Tier: 1

Human approved spec: yes
Red phase confirmed: yes
Human approved implementation: yes
Green phase confirmed: yes
Refactor phase complete: yes

## Feature goal

Introduce a `Cents` type representing money in integer minor units
(cents, satoshis, etc.) and an `Add` method that returns the sum.
The point of using an integer type is to make `float64` rounding
errors structurally impossible on the money paths.

## Acceptance criteria

1. `Cents(100).Add(Cents(250))` returns `Cents(350), nil`. ✓
2. `Cents(0).Add(Cents(0))` returns `Cents(0), nil`. ✓
3. Overflow returns `Cents(0), ErrOverflow`. ✓
4. JSON / DB round-trip preserves precision. ✓

## Refactor notes

- Extracted overflow-check expressions into named helper variables
  for readability (`maxAddend`, `minAddend`). No behavior change.
- Added a doc comment example to `Add` for godoc discoverability.
- `go vet ./...` and `golangci-lint run` clean after refactor.
- All 4 tests still green; race detector clean.

## Cycle complete

```
red(cents-add):      add failing tests for Cents.Add overflow check
green(cents-add):    implement Cents.Add with overflow check
refactor(cents-add): extract addend bounds + add doc example
```

The `tdd-state-clean` CI check accepts this state (Status: idle OR
all 3 approval markers set; both are true here, so an MR can merge).

## Next cycles (intentionally NOT done in this scope)

- `cents-sub` — Cents.Sub method (separate cycle)
- `cents-mul` — Cents.Mul(int64) method (separate cycle)
- `currency-cents` — currency-tagged Cents (USD, EUR, ...) (separate cycle, separate type)

## Red proof

Preserved at `02-red/red-proof.md`. In a real cycle this lives at
`.tdd/red-proof.md` and gets committed alongside the red commit;
when the next cycle starts it gets overwritten.
