# Feature Plan: cents-add — minor-units money type with safe addition

Status: active
Cycle ID: cents-add
Change type: feature
Tier: 1

Human approved spec: no
Red phase confirmed: no
Human approved implementation: no
Green phase confirmed: no
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
  range, it returns an error (caller decides what to do).
- The zero value of `Cents` is zero — usable without a constructor.

## Acceptance criteria

1. `Cents(100).Add(Cents(250))` returns `Cents(350), nil`.
2. `Cents(0).Add(Cents(0))` returns `Cents(0), nil`.
3. Adding two values whose sum exceeds `MaxInt64` returns
   `Cents(0), ErrOverflow`.
4. The type is `int64`-backed so it round-trips JSON / DB without
   precision loss.

## Non-goals

- Subtraction, multiplication, division — separate cycles.
- Currency tagging (USD vs EUR) — a different type, separate cycle.
- Formatting / parsing — separate cycle.
- Decimal points (this is **minor units**, integer arithmetic only).

## Affected code

- New file: `internal/payments/cents.go`
- New test file: `internal/payments/cents_test.go`

## Test plan

| Test name | Scenario | Pins criterion # |
|---|---|---|
| TestCents_Add_When_Normal_Then_Sum | 100 + 250 = 350 | 1 |
| TestCents_Add_When_BothZero_Then_Zero | 0 + 0 = 0 | 2 |
| TestCents_Add_When_Overflow_Then_Error | MaxInt64 + 1 → ErrOverflow | 3 |
| TestCents_JSONRoundTrip | marshal then unmarshal preserves value | 4 |

## API/compatibility impact

New package symbol. Not breaking. Library projects would need to
treat this as a one-way door (deliberate Tier 1 reason here is the
money invariant, not API stability).

## Minimum implementation

- `type Cents int64`
- `func (c Cents) Add(other Cents) (Cents, error)` — uses
  `math.MaxInt64` overflow check before returning.
- `var ErrOverflow = errors.New(...)`

Do NOT pre-implement subtraction or multiplication. Cycle scope is
addition only.

## Red proof pointer

Path: `.tdd/red-proof.md`

## Risk register

| Risk | Mitigation |
|---|---|
| Overflow check uses subtraction, which itself can underflow | Test the boundary at MaxInt64 explicitly |
| Future devs use `Cents` arithmetic outside the type's methods (e.g. `Cents(a) + Cents(b)`) | Document that direct `+` is allowed for non-overflow-sensitive code, but Add() is required where overflow matters |
