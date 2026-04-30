#!/usr/bin/env bash
# Smoke-test the TDD hooks. Run with `make tdd-test`.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed; cannot test TDD hooks"
  exit 0
fi

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "Testing route-to-tdd.sh..."

out=$(echo '{"prompt": "Implement a new payment processor"}' | bash .claude/hooks/route-to-tdd.sh 2>&1)
if [[ "$out" == *"TDD router"* ]]; then
  pass "feature request with Tier 1 keyword emits notice"
else
  fail "feature request with Tier 1 keyword should emit notice (got: '$out')"
fi

out=$(echo '{"prompt": "Fix typo in CHANGELOG"}' | bash .claude/hooks/route-to-tdd.sh 2>&1)
if [ -z "$out" ]; then
  pass "doc request silent"
else
  fail "doc request should be silent (got: '$out')"
fi

out=$(echo '{"prompt": "What is the capital module structure?"}' | bash .claude/hooks/route-to-tdd.sh 2>&1)
if [ -z "$out" ]; then
  pass "question request silent"
else
  fail "question request should be silent (got: '$out')"
fi

echo
echo "Testing require-tdd-state.sh..."

out=$(echo '{"tool_input": {"file_path": "CHANGELOG.md"}}' | bash .claude/hooks/require-tdd-state.sh 2>&1; echo "exit:$?")
if [[ "$out" == *"exit:0"* ]]; then
  pass "CHANGELOG.md allowed"
else
  fail "CHANGELOG.md should be allowed (got: '$out')"
fi

out=$(echo '{"tool_input": {"file_path": "internal/foo/bar_test.go"}}' | bash .claude/hooks/require-tdd-state.sh 2>&1; echo "exit:$?")
if [[ "$out" == *"exit:0"* ]]; then
  pass "_test.go allowed"
else
  fail "_test.go should be allowed (got: '$out')"
fi

out=$(echo '{"tool_input": {"file_path": "internal/utils/helper.go"}}' | bash .claude/hooks/require-tdd-state.sh 2>&1; echo "exit:$?")
if [[ "$out" == *"exit:0"* ]]; then
  pass "non-Tier 1 Go file allowed"
else
  fail "non-Tier 1 should be allowed (got: '$out')"
fi

out=$(echo '{"tool_input": {"file_path": "internal/payments/charge.go"}}' | bash .claude/hooks/require-tdd-state.sh 2>&1; echo "exit:$?")
if [[ "$out" == *"exit:2"* ]] && [[ "$out" == *"BLOCKED"* ]]; then
  pass "Tier 1 file with no plan blocked"
else
  fail "Tier 1 file should be blocked (got: '$out')"
fi

# Two-segment layout: internal/<feature>/file.go
out=$(echo '{"tool_input": {"file_path": "internal/auth/handler.go"}}' | bash .claude/hooks/require-tdd-state.sh 2>&1; echo "exit:$?")
if [[ "$out" == *"exit:2"* ]] && [[ "$out" == *"BLOCKED"* ]]; then
  pass "Tier 1 two-segment layout blocked"
else
  fail "two-segment Tier 1 should be blocked (got: '$out')"
fi

# Three-segment layout: internal/<group>/<feature>/file.go
out=$(echo '{"tool_input": {"file_path": "internal/modules/payments/charge.go"}}' | bash .claude/hooks/require-tdd-state.sh 2>&1; echo "exit:$?")
if [[ "$out" == *"exit:2"* ]] && [[ "$out" == *"BLOCKED"* ]]; then
  pass "Tier 1 three-segment layout blocked"
else
  fail "three-segment Tier 1 should be blocked (got: '$out')"
fi

echo
echo "Testing guard-dangerous-bash.sh..."

out=$(echo '{"tool_input": {"command": "git commit --no-verify"}}' | bash .claude/hooks/guard-dangerous-bash.sh)
decision="$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')"
if [ "$decision" = "deny" ]; then
  pass "git commit --no-verify denied"
else
  fail "git commit --no-verify should be denied (got: $decision)"
fi

out=$(echo '{"tool_input": {"command": "go test ./..."}}' | bash .claude/hooks/guard-dangerous-bash.sh)
if [ "$(echo "$out" | jq 'has("hookSpecificOutput")')" = "false" ]; then
  pass "go test passes through"
else
  fail "go test should pass (got: $out)"
fi

out=$(echo '{"tool_input": {"command": "terraform destroy"}}' | bash .claude/hooks/guard-dangerous-bash.sh)
decision="$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')"
if [ "$decision" = "deny" ]; then
  pass "terraform destroy denied"
else
  fail "terraform destroy should be denied (got: $decision)"
fi

echo
echo "Testing scan-for-secrets.sh..."

out=$(echo '{"tool_name":"Write","tool_input":{"content":"AKIAIOSFODNN7EXAMPLE","file_path":"x"}}' | bash .claude/hooks/scan-for-secrets.sh)
decision="$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"')"
if [ "$decision" = "deny" ]; then
  pass "AWS access key denied"
else
  fail "AWS access key should be denied (got: $decision)"
fi

out=$(echo '{"tool_name":"Write","tool_input":{"content":"hello world","file_path":"x"}}' | bash .claude/hooks/scan-for-secrets.sh)
if [ "$(echo "$out" | jq 'has("hookSpecificOutput")')" = "false" ]; then
  pass "harmless content passes"
else
  fail "harmless content should pass (got: $out)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
