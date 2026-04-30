# Specifications

Every non-trivial change starts with a spec here.

Lifecycle: **Specify → Plan → Tasks → Implement.**

Each gate requires explicit human approval (`APPROVED` reply).
Do not advance unless the prior gate is signed off.

## Layout

- `specs/<feature>/spec.md` — what and why (Specify gate)
- `specs/<feature>/plan.md` — how (Plan gate)
- `specs/<feature>/tasks.md` — broken-down work items
- Implementation references the tasks file in commit messages

## Use the `specify` skill

Run the `specify` skill before starting any change spanning >1 hour or
touching public API.

## Tier 1 paths

For changes to paths matching `tier1_path_regexes` in
`.tdd/tdd-config.json`, the spec gate is FOLLOWED BY the TDD ceremony
(`go-tdd-feature` or `go-tdd-bugfix` skill). Both gates apply.

The full chain for high-stakes work:

1. **Layer 0** (this directory): spec.md → plan.md → tasks.md
   (3 human gates total)
2. **Layer 1** (`.tdd/`): bugfix-plan or feature-plan + red-proof.md
   (2 more human gates)
3. **Layer 2–4**: in-session rules, mechanical floor (CI), review

For ordinary code (non-Tier 1), use only Layer 0 +
`minimal-go-change` skill.
