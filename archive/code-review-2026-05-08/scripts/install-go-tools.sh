#!/usr/bin/env bash
# Install Go developer tools required by the starter pack.
#
# Honest framing (per v1.1.1 review):
#   Defaults are @latest. The mechanism is parameterized — set any of the
#   *_VERSION env vars to a tag (e.g. STATICCHECK_VERSION=2026.1.1) and
#   that version will be installed instead.
#
#   For team-wide reproducibility, pin the env vars in your CI pipeline or
#   in a project-local wrapper script. This pack does NOT pin upstream
#   defaults because the right pinned version varies by Go release and
#   moves quarterly — a stale pinned default would silently rot.
#
# govulncheck is intentionally @latest with no override: vulnerability
# databases need fresh data; pinning the binary defeats the purpose.

set -euo pipefail

STATICCHECK_VERSION="${STATICCHECK_VERSION:-latest}"
DEADCODE_VERSION="${DEADCODE_VERSION:-latest}"
UNPARAM_VERSION="${UNPARAM_VERSION:-latest}"
GOIMPORTS_VERSION="${GOIMPORTS_VERSION:-latest}"
APIDIFF_VERSION="${APIDIFF_VERSION:-latest}"
GORELEASE_VERSION="${GORELEASE_VERSION:-latest}"
GOPLS_VERSION="${GOPLS_VERSION:-latest}"

echo "==> Installing Go developer tools"
echo "    (set *_VERSION env vars to pin to specific tags)"
go install "honnef.co/go/tools/cmd/staticcheck@${STATICCHECK_VERSION}"
go install "golang.org/x/tools/cmd/deadcode@${DEADCODE_VERSION}"
go install "mvdan.cc/unparam@${UNPARAM_VERSION}"
go install "golang.org/x/tools/cmd/goimports@${GOIMPORTS_VERSION}"
go install "golang.org/x/exp/cmd/apidiff@${APIDIFF_VERSION}"
go install "golang.org/x/exp/cmd/gorelease@${GORELEASE_VERSION}"
# gopls for the MCP server defined in .mcp.json (project root)
go install "golang.org/x/tools/gopls@${GOPLS_VERSION}"
# govulncheck always @latest for fresh vulnerability database
go install golang.org/x/vuln/cmd/govulncheck@latest

echo "==> Tools installed."
echo
echo "Required system tools (install separately):"
echo "  jq           : sudo apt-get install jq / brew install jq / apk add jq"
echo "  golangci-lint: https://golangci-lint.run/welcome/install/"
echo "  gitleaks     : (recommended) https://github.com/gitleaks/gitleaks"

# Optional: warn on missing system tools
for tool in jq golangci-lint; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "WARNING: $tool not found in PATH"
  fi
done
