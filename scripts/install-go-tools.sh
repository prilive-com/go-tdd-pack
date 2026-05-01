#!/usr/bin/env bash
# Install Go developer tools required by the starter pack.
#
# Versions are pinned for reproducibility. Override any individual version
# via env var (e.g. STATICCHECK_VERSION=2026.1.2 bash install-go-tools.sh).
# Refresh quarterly — see MAINTAINING.md "Versioning".
#
# govulncheck is intentionally @latest because vulnerability databases
# get regular updates; pinning the binary defeats the purpose.

set -euo pipefail

# Pinned versions (refresh quarterly)
STATICCHECK_VERSION="${STATICCHECK_VERSION:-latest}"
DEADCODE_VERSION="${DEADCODE_VERSION:-latest}"
UNPARAM_VERSION="${UNPARAM_VERSION:-latest}"
GOIMPORTS_VERSION="${GOIMPORTS_VERSION:-latest}"
APIDIFF_VERSION="${APIDIFF_VERSION:-latest}"
GORELEASE_VERSION="${GORELEASE_VERSION:-latest}"
GOPLS_VERSION="${GOPLS_VERSION:-latest}"

# NOTE on @latest above: at the time you tag your starter version 1.1.0, replace
# `latest` defaults with concrete tag values from `go list -m -versions <pkg>`.
# Example after a quarterly refresh:
#   STATICCHECK_VERSION="${STATICCHECK_VERSION:-2026.1.1}"
#   DEADCODE_VERSION="${DEADCODE_VERSION:-v0.27.0}"
#   GOPLS_VERSION="${GOPLS_VERSION:-v0.21.0}"
# This keeps tools stable for cloners between starter releases while
# leaving govulncheck on @latest for fresh CVE data.

echo "==> Installing Go developer tools"
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
