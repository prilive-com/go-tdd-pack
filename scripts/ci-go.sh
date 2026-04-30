#!/usr/bin/env bash
set -euo pipefail

echo "== go version =="
go version

echo "== go mod tidy check =="
cp go.mod /tmp/go.mod.before
[ -f go.sum ] && cp go.sum /tmp/go.sum.before
go mod tidy
diff -u /tmp/go.mod.before go.mod
[ -f /tmp/go.sum.before ] && diff -u /tmp/go.sum.before go.sum

echo "== gofmt check =="
unformatted="$(gofmt -l $(find . -name '*.go' -not -path './vendor/*'))"
if [[ -n "$unformatted" ]]; then
  echo "Unformatted files:"
  echo "$unformatted"
  exit 1
fi

echo "== go vet =="
go vet ./...

echo "== go test =="
go test ./...

echo "== go test -race =="
go test -race -count=1 ./...

echo "== allowed modules =="
bash scripts/check-allowed-modules.sh

if command -v staticcheck >/dev/null 2>&1; then
  echo "== staticcheck =="
  staticcheck ./...
fi

if command -v govulncheck >/dev/null 2>&1; then
  echo "== govulncheck =="
  govulncheck ./...
fi

if command -v deadcode >/dev/null 2>&1; then
  echo "== deadcode =="
  deadcode ./... | tee /tmp/deadcode.txt
  test ! -s /tmp/deadcode.txt
fi

if command -v golangci-lint >/dev/null 2>&1; then
  echo "== golangci-lint =="
  golangci-lint run ./...
fi

echo "All checks passed."
