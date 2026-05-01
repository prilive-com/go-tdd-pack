//go:build ignore

// Package payments contains money handling primitives. All amounts are
// represented in integer minor units (Cents) to avoid float64 rounding bugs.
package payments

import (
	"errors"
	"math"
)

// Cents is money expressed in integer minor units (cents, satoshis, ...).
// The zero value is zero. Direct arithmetic (`a + b`) is allowed when overflow
// is impossible by construction; use Add() when callers may sum arbitrary
// caller-provided amounts.
type Cents int64

// ErrOverflow is returned by Add when the sum would exceed the int64 range.
var ErrOverflow = errors.New("payments: cents addition overflows int64")

// Add returns the sum of c and other, or (0, ErrOverflow) if the sum would
// overflow int64. Add is commutative and associative.
//
// Example:
//
//	got, err := payments.Cents(100).Add(payments.Cents(250))
//	// got == Cents(350), err == nil
func (c Cents) Add(other Cents) (Cents, error) {
	maxAddend := Cents(math.MaxInt64) - other
	minAddend := Cents(math.MinInt64) - other
	if other > 0 && c > maxAddend {
		return 0, ErrOverflow
	}
	if other < 0 && c < minAddend {
		return 0, ErrOverflow
	}
	return c + other, nil
}
