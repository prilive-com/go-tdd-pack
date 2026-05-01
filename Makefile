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
	@deadcode ./... | tee /tmp/deadcode.txt; \
	if [ -s /tmp/deadcode.txt ]; then \
	  if [ "$${DEADCODE_ALLOW_FAILURE:-true}" = "true" ]; then \
	    echo "deadcode: findings present (advisory; set DEADCODE_ALLOW_FAILURE=false to hard-fail)"; \
	  else \
	    echo "deadcode: findings present and DEADCODE_ALLOW_FAILURE=false; failing."; \
	    exit 1; \
	  fi; \
	fi

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
