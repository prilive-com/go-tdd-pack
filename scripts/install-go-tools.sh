#!/usr/bin/env bash
# Install Go developer tools required by the starter pack.
set -euo pipefail

echo "==> Installing Go developer tools"

go install honnef.co/go/tools/cmd/staticcheck@latest
go install golang.org/x/vuln/cmd/govulncheck@latest
go install golang.org/x/tools/cmd/deadcode@latest
go install mvdan.cc/unparam@latest
go install golang.org/x/tools/cmd/goimports@latest
go install golang.org/x/exp/cmd/apidiff@latest
go install golang.org/x/exp/cmd/gorelease@latest

# gopls for the MCP server defined in .claude/mcp.json
go install golang.org/x/tools/gopls@latest

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
