# Go Security Rules

These rules apply to any Go change in this repository.

## Secrets and credentials

- Never read, write, or print secrets unless the task explicitly requires
  a sanctioned secret-management flow.
- Never paste full credentials, signed headers, tokens, or private keys
  into chat, commits, logs, or error messages.
- Never hardcode credentials. Use environment variables, secret managers,
  or sealed secrets — never string literals in source.
- If a secret appears in your context (via Read, web search result, or
  user paste), treat it as compromised. Recommend the user rotate it;
  do not use it.
- The `scan-for-secrets.sh` PreToolUse hook blocks Write/Edit when the
  proposed content contains secret material. The hook prefers gitleaks
  if installed; install it for production-grade detection.

## Credential custodianship

If code handles tokens, API keys, passwords, cookies, or session values:

- Implement `String()`, `MarshalJSON`, `MarshalText`, `LogValue`
  returning `"[REDACTED]"`.
- Config structs must not accidentally print secrets via
  `fmt.Sprintf("%+v", cfg)`.
- Errors and panic dumps must not embed secret values.
- For high-value secret temporaries: consider `runtime/secret` (Go 1.26
  experimental, linux/amd64+arm64). Redaction (logs) != erasure (RAM).

## Logging hygiene

- Always log: authentication events, authorization failures, admin
  actions, rate-limit hits, start/stop of long operations, retry
  exhaustion.
- Never log: passwords, API keys, tokens (even partial), PII beyond
  what is operationally required, full request/response bodies from
  authenticated endpoints, database connection strings with credentials
  embedded.
- Prefer structured logging over string concatenation. Redact sensitive
  fields at the logger level.

## Taint-to-sink tracing

- user input -> SQL: parameterized queries only, never concatenation.
- user input -> shell/exec: `exec.Command` with explicit args, never
  `sh -c`. `exec.Command("sh", "-c", userInput)` is injection. Period.
- user input -> templates: `html/template`, not `text/template`.
- user input -> file paths: `os.Root` (Go 1.24+) or `filepath.IsLocal`.
  Path traversal (`../../../etc/passwd`) is a classic Go bug.
- user input -> logs/metrics: never include secrets/PII.

## HTTP client / URL handling

- User-controlled URLs passed to `http.Get` / `http.NewRequest`: SSRF
  protection (denylist of internal ranges like 169.254.169.254,
  10.0.0.0/8, 127.0.0.0/8).
- `http.Client` with no timeout is a reliability and security issue.
  Both `Timeout` and per-request ctx timeouts.
- TLS config: `MinVersion >= 1.2` in production. Never
  `InsecureSkipVerify` outside controlled tests, guarded by an explicit
  build tag or config check.

## Input validation and parsers

- New parsers (JSON, YAML, XML, binary, form data): size limit at the
  HTTP layer (`http.MaxBytesReader`) or in the parser itself.
- JSON: `DisallowUnknownFields()` if the schema is fixed.
- File paths derived from user input: `filepath.Clean` + prefix check
  against an allowed base directory.

## Cryptography

- `crypto/rand` for security randomness; never `math/rand`. Includes:
  session IDs, tokens, salts, nonces, password reset codes.
- Hashing passwords: `golang.org/x/crypto/bcrypt` or `argon2`. Never
  raw `sha256` or `md5`.
- HMAC for message authentication. Constant-time comparison via
  `hmac.Equal`, not `==` or `bytes.Equal`.
- TLS: set `MinVersion: tls.VersionTLS12` (or 1.3) explicitly.
- Go 1.26+: do NOT rely on the random parameter to
  `crypto/*.GenerateKey` — it is ignored.
- `govulncheck ./...` clean; justify any findings.

## Authentication and authorization

- New HTTP handlers: auth middleware applied in the router, per-handler,
  or forgotten? If per-handler, what's the pattern that prevents
  someone adding a handler without it?
- New gRPC methods: service-level interceptor handles auth, or each
  method calls it explicitly?
- Admin/operator endpoints: separate mux/interceptor stack so
  user-facing middleware can't leak in either direction.
- New database queries: include a tenant/user filter, or trust the
  caller to pass the right ID?
- Context-carried identity (`auth.UserFromContext(ctx)`): verify the
  context came from an authenticated source.

## Supply chain (slopsquatting defense)

A 2024 study found ~19.7% of LLM-recommended packages do not exist;
attackers pre-register the names with malware. This is not a theoretical
risk for AI-authored Go code.

- Every new `go.mod require` must be on `.claude/allowed-modules.txt`.
- Verify any new package on https://pkg.go.dev (publication date,
  maintainers, last activity).
- Pin to a tagged release, not `v0.0.0-*` pseudo-versions, unless
  unavoidable.
- `go.sum` committed; `GOFLAGS=-mod=readonly` in CI.
- `govulncheck ./...` run on the affected module before merge.

## CI and pipeline safety

- Treat CI, release pipelines, and admin/operator paths as high-risk.
- Changes to workflows, action triggers, or deployment scripts need
  explicit security review.
- Never commit secrets to CI logs; use the CI platform's secret-masking.
- New GitHub Actions: SHA-pinned, not version-tagged (`@v1` is mutable,
  `@abc123...` is not).
- `pull_request_target` + user-controlled code checkout is a well-known
  footgun — avoid unless strictly necessary.
- Workflow `permissions:` block scoped to minimum (`contents: read`
  by default).

## MCP and plugin trust

- Treat every MCP server as arbitrary code running with your credentials.
- `enableAllProjectMcpServers: false` is mandatory (CVE-2025-59536
  defense). `enabledMcpjsonServers` is an explicit allowlist.
- Prefer official Anthropic-maintained servers, OAuth-authenticated
  remote servers, and pinned versions.
- Prefer read-only MCP tools.

## When in doubt

If a security-relevant decision is ambiguous, propose the safer option
and explicitly flag the tradeoff for human review. Do not silently pick
the less safe path.
