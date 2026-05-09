# Bugfix Plan: f9-skill-md-template-extraction — extract Step 6 inline templates to .tdd/templates/

Status: active
Cycle ID: f9-skill-md-template-extraction
Change type: cleanup + bugfix
Tier: 1

<!-- TDD ceremony markers. Set each ONLY after the matching operator APPROVED reply. -->
Bug reproduced: yes
Human approved spec: yes
Red phase confirmed: yes
Green phase authorized: yes
Implementation reviewed: yes
Fix applied: yes
Regression tests added: yes
Bug-elsewhere check complete: yes

## Bug

`.claude/skills/second-opinion/SKILL.md` is 917 lines. Step 6 inlines
two templates as `cat > <path> <<EOF` heredocs:

  Step 6a (lines 740-767, ~28 lines): the adjudication file template
  Step 6b (lines 775-808, ~34 lines): the disposition matrix template

The disposition matrix template ALSO exists standalone at
`.tdd/templates/disposition-matrix-template.md` (76 lines) — and the
standalone version is MORE COMPLETE: it carries the F8 fix where
placeholder row IDs use `F-EXAMPLE-N` instead of literal `F1`/`F2`/`F3`.

Per the F8 commit comment: "the hook's row-count regex
(`^\|[[:space:]]+F[0-9]+[[:space:]]+\|`) does NOT match `F-EXAMPLE-N`.
When Claude writes real adjudication rows, use F1, F2, F3, ... — those
WILL be counted by the regex."

But SKILL.md's inlined version uses `F1` as the placeholder. An operator
who follows SKILL.md (instead of the template file) would copy the
literal `F1` row → the row-count regex DOES match → unedited matrix
falsely passes the count check. This silently re-opens F8.

The adjudication template file does not exist standalone yet; only the
inlined version in SKILL.md.

## Reproduction

```
grep -A1 "^\| F1" .claude/skills/second-opinion/SKILL.md
# Output: | F1 | Codex | <P0..P3> | <one line> | <ACCEPT|PARTIAL|...> | ...
# This row matches the hook's count regex.

grep -A1 "^\| F-EXAMPLE-1" .tdd/templates/disposition-matrix-template.md
# Output uses F-EXAMPLE-1 (correct).
```

So an operator who copies SKILL.md's inline template and submits an
unedited matrix would slip through the row-count gate. F8 only fixed
the standalone file.

## Acceptance criteria

1. New file `.tdd/templates/second-opinion-adjudication-template.md`
   exists with full structure (date, scope, model, diff_sha256,
   plan_sha256, files_in_scope, findings_total, adjudication_summary,
   findings list, adjudicated_by) including PARTIAL discipline
   placeholders (accepted, rejected, why_split, why_correct).
2. SKILL.md Step 6a no longer contains an inline `cat > .tdd/second-
   opinion-completed.md <<EOF` heredoc.
3. SKILL.md Step 6a references `.tdd/templates/second-opinion-
   adjudication-template.md` and explains: copy template, compute
   hashes, fill in placeholders.
4. SKILL.md Step 6b no longer contains an inline `cat > .tdd/codex/
   disposition-matrix.md <<EOF` heredoc.
5. SKILL.md Step 6b references `.tdd/templates/disposition-matrix-
   template.md` (the F8-correct version).
6. SKILL.md line count drops by ≥50 lines.
7. Existing 230 smoke tests still pass (no regression — hook reads
   the produced files, not the templates).
8. New smoke tests assert:
   - The new adjudication template file exists.
   - SKILL.md's Step 6 no longer contains the inline template
     placeholder pattern (`F1.*Codex.*P0..P3`).
   - SKILL.md references both template files by path.

## Non-goals

- Splitting Step 3 (532 lines) — the bash machinery there is
  operationally tight; extracting prompt heredocs with shell variable
  interpolation needs envsubst or similar; defer to follow-up cycle.
- Restructuring the workflow steps. Keep Steps 1-7 narrative.
- Changing SKILL.md frontmatter version (still 1.2.0; this is internal
  cleanup, not an API change).

## Affected code

- `.tdd/templates/second-opinion-adjudication-template.md` — NEW file
- `.claude/skills/second-opinion/SKILL.md` — Step 6 rewritten
- `scripts/tdd-test-hooks.sh` — new self-tests

## Test plan

| Test name | Pins criterion # |
|---|---|
| f9_adjudication_template_file_exists | 1 |
| f9_adjudication_template_has_required_fields | 1 |
| f9_skill_md_step6a_no_inline_heredoc | 2,3 |
| f9_skill_md_step6b_no_inline_heredoc | 4,5 |
| f9_skill_md_references_adjudication_template | 3 |
| f9_skill_md_references_matrix_template | 5 |
| f9_skill_md_line_count_dropped | 6 |

## Risk register

| Risk | Mitigation |
|---|---|
| Existing test fixtures write adjudication files via inline content; if SKILL.md changes the recommended approach, fixtures may go out of sync. | The hook checks the produced file's CONTENT (hashes, fields, PARTIAL discipline), not how it was produced. Tests writing the file directly continue to work. |
| Operators in flight have memorized the SKILL.md heredoc; new flow requires reading template file. | Documented in SKILL.md update; the new instruction is more discoverable (one canonical template). |
| Standalone adjudication template doesn't exist yet; need to create. | Spec covers creation explicitly. Audit against existing in-cycle adjudication files (F5, F6) for completeness. |
| Renaming/moving SKILL.md alters the skill's behavior for Claude Code. | Frontmatter unchanged; only body content edited. Skill still loads from same path. |
