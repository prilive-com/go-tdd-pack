load_redact_patterns() {
  # Read raw .claude/redact-patterns.txt; emit only non-comment,
  # non-blank, regex-validated lines into a mktemp file. Bad lines
  # are logged to DEBUG_LOG and skipped. Always returns 0 — a bad
  # patterns file never blocks the hook; the redactor falls back to
  # universal-only patterns.
  local raw="$1"
  [ -f "$raw" ] || return 0
  local validated; validated="$(mktemp 2>/dev/null || echo "/tmp/redact.$$")"
  local total=0 bad=0 rc=0
  while IFS= read -r p || [ -n "$p" ]; do
    # Skip blank lines and comments (allow leading whitespace).
    printf '%s\n' "$p" | grep -qE '^[[:space:]]*[^[:space:]#]' || continue
    total=$((total+1))
    # grep -E exits 0 (match) or 1 (no match) on valid regex; >=2 on
    # syntax error. Anything > 1 means the pattern is malformed.
    rc=0
    echo '' | grep -E -- "$p" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -le 1 ]; then
      printf '%s\n' "$p" >> "$validated"
    else
      bad=$((bad+1))
      printf '[redact-patterns] WARN: invalid regex skipped: %s\n' "$p" \
        >> "$DEBUG_LOG" 2>/dev/null || true
    fi
  done < "$raw"
  if [ "$bad" -gt 0 ]; then
    printf '[redact-patterns] %d/%d custom pattern(s) skipped as invalid; see %s.\n' \
      "$bad" "$total" "$DEBUG_LOG" >&2
  fi
  printf '%s\n' "$validated"
}
