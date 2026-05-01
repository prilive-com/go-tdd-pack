# Feature Plan: cents-add — minor-units money type with safe addition

Status: active
Cycle ID: cents-add
Change type: feature
Tier: 1

Human approved spec: yes
Red phase confirmed: yes
Human approved implementation: yes
Green phase confirmed: yes
Refactor phase complete: no

## Feature goal

Introduce a `Cents` type representing money in integer minor units
(cents, satoshis, etc.) and an `Add` method that returns the sum.
The point of using an integer type is to make `float64` rounding
errors structurally impossible on the money paths.

User-visible behavior: callers can write
`payments.Cents(100).Add(payments.Cents(250)) == payments.Cents(350)`
and trust the result without rounding-error paranoia.

## Business/domain invariants

- `Add` is commutative and associative.
- `Add` does not silently overflow: if the sum exceeds `int64`
  range, it returns an error.
- The zero value of `Cents` is zero — usable without a constructor.

## Acceptance criteria

1. `Cents(100).Add(Cents(250))` returns `Cents(350), nil`. ✓
2. `Cents(0).Add(Cents(0))` returns `Cents(0), nil`. ✓
3. Adding two values whose sum exceeds `MaxInt64` returns
   `Cents(0), ErrOverflow`. ✓
4. The type is `int64`-backed so it round-trips JSON / DB without
   precision loss. ✓

## Non-goals

- Subtraction, multiplication, division — separate cycles.
- Currency tagging (USD vs EUR) — a different type, separate cycle.
- Formatting / parsing — separate cycle.

## Affected code

- New file: `internal/payments/cents.go` (38 lines)
- New test file: `internal/payments/cents_test.go` (43 lines)

## Test plan

| Test name | Scenario | Pins criterion # | Status |
|---|---|---|---|
| TestCents_Add_When_Normal_Then_Sum | 100 + 250 = 350 | 1 | green |
| TestCents_Add_When_BothZero_Then_Zero | 0 + 0 = 0 | 2 | green |
| TestCents_Add_When_Overflow_Then_Error | MaxInt64 + 1 → ErrOverflow | 3 | green |
| TestCents_JSONRoundTrip | marshal then unmarshal preserves value | 4 | green |

## API/compatibility impact

New package symbols `Cents`, `ErrOverflow`. Not breaking.

## Minimum implementation

Done. See sibling `cents.go`.

## Red proof pointer

Path: `.tdd/red-proof.md` (preserved in 02-red/).

## Risk register

| Risk | Mitigation | Status |
|---|---|---|
| Overflow check uses subtraction, which itself can underflow | Test the boundary at MaxInt64 explicitly | covered by TestCents_Add_When_Overflow_Then_Error |
| Future devs use `Cents` arithmetic outside the type's methods | Document that direct `+` is allowed for non-overflow-sensitive code, but Add() is required where overflow matters | doc comment on type added in green |

## Green commit

```
green(cents-add): implement Cents.Add with overflow check
```
