//go:build ignore

package payments

import (
	"encoding/json"
	"errors"
	"math"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCents_Add_When_Normal_Then_Sum(t *testing.T) {
	got, err := Cents(100).Add(Cents(250))
	require.NoError(t, err)
	assert.Equal(t, Cents(350), got)
}

func TestCents_Add_When_BothZero_Then_Zero(t *testing.T) {
	got, err := Cents(0).Add(Cents(0))
	require.NoError(t, err)
	assert.Equal(t, Cents(0), got)
}

func TestCents_Add_When_Overflow_Then_Error(t *testing.T) {
	got, err := Cents(math.MaxInt64).Add(Cents(1))
	assert.Equal(t, Cents(0), got)
	require.Error(t, err)
	assert.True(t, errors.Is(err, ErrOverflow), "expected ErrOverflow, got %v", err)
}

func TestCents_JSONRoundTrip(t *testing.T) {
	original := Cents(1234567890)
	data, err := json.Marshal(original)
	require.NoError(t, err)

	var roundTripped Cents
	require.NoError(t, json.Unmarshal(data, &roundTripped))
	assert.Equal(t, original, roundTripped)
}
