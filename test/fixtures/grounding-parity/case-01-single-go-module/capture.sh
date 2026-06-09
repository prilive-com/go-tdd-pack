#!/usr/bin/env bash
# capture.sh — regenerate expected.md for case-01-single-go-module.
#
# Use this when:
#   - the runner's output format changes (intentionally)
#   - the fixture project files change
#   - you're capturing on a new host with a different tool inventory
#
# Procedure (also runs as the script body):
#   1. Snapshot the current tool inventory to tool-inventory.txt.
#   2. Set up a fresh git repo in /tmp from project/.
#   3. Commit the initial state.
#   4. Add a NEW file (the "change" the runner sees as untracked).
#   5. Run runner/tool-grounding.sh against the repo.
#   6. Write stdout to expected.md.
#   7. Write the changed-files set to changed-files.txt for slice 2.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${HERE}/../../../.." && pwd)"
RUNNER="${PROJECT_ROOT}/runner/tool-grounding.sh"

[[ -x "${RUNNER}" ]] || { echo "✗ missing/non-executable: ${RUNNER}" >&2; exit 1; }

# 1. Tool inventory snapshot
{
  echo "# Tool inventory snapshot — captured by capture.sh"
  echo "# Slice 2's parity smoke compares the current host's inventory"
  echo "# against this. If they differ, the smoke skips with a clear note."
  echo ""
  for t in go gofmt staticcheck golangci-lint govulncheck gosec; do
    if command -v "${t}" >/dev/null 2>&1; then
      printf '%s=installed\n' "${t}"
    else
      printf '%s=missing\n' "${t}"
    fi
  done
} > "${HERE}/tool-inventory.txt"

# 2. Fresh temp git repo
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

cp -r "${HERE}/project/." "${TMP}/"
cd "${TMP}" || exit 1

# 3. Initial commit
git -c user.email=fixture@example.com -c user.name=fixture init -q
git add .
git -c user.email=fixture@example.com -c user.name=fixture commit -q -m "initial fixture state"

# 4. Add the "change" — a new untracked file. Untracked files show up in
#    tool-grounding.sh's collect_changed_files via `git ls-files --others
#    --exclude-standard`. No modification of existing tracked files →
#    output stays deterministic across hosts as long as the tool
#    inventory matches.
cat > calculator_div.go <<'EOF'
package fixture

// Divide returns a divided by b. Panics on division by zero.
func Divide(a, b int) int {
	if b == 0 {
		panic("division by zero")
	}
	return a / b
}
EOF

# 5+6. Run tool-grounding.sh and capture expected output
"${RUNNER}" "${TMP}" > "${HERE}/expected.md"

# 7. Changed-files list (what the runner saw as input)
{
  git diff --name-only HEAD 2>/dev/null
  git ls-files --others --exclude-standard 2>/dev/null
} | sort -u | grep -v '^$' > "${HERE}/changed-files.txt"

echo "✓ captured expected.md ($(wc -l < "${HERE}/expected.md") lines)"
echo "✓ tool-inventory.txt updated"
echo "✓ changed-files.txt: $(wc -l < "${HERE}/changed-files.txt") entries"
