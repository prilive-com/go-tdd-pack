## Tool grounding (pre-executed before this review)

**Summary:** 1 affected Go module(s), 1 affected file(s).

## Module: `.`

### gofmt -l .
(clean)

### go vet ./...
(clean)

### staticcheck -checks=all ./...
(skipped: staticcheck not installed)

### golangci-lint run --enable-all
(skipped: golangci-lint not installed)

### govulncheck ./...
(skipped: govulncheck not installed)

### gosec -no-fail -quiet ./...
(skipped: gosec not installed)

