SHELL := /usr/bin/env bash

.PHONY: fmt test race vet vuln lint staticcheck deadcode tidy ci tools tdd-test doctor

fmt:
	gofmt -w $$(find . -name '*.go' -not -path './vendor/*')

test:
	go test ./...

race:
	go test -race ./...

vet:
	go vet ./...

vuln:
	govulncheck ./...

staticcheck:
	staticcheck ./...

deadcode:
	deadcode ./... | tee /tmp/deadcode.txt
	test ! -s /tmp/deadcode.txt

lint:
	golangci-lint run ./...

tidy:
	go mod tidy

ci:
	bash scripts/ci-go.sh

tools:
	bash scripts/install-go-tools.sh

tdd-test:
	bash scripts/tdd-test-hooks.sh

doctor:
	bash scripts/doctor.sh
