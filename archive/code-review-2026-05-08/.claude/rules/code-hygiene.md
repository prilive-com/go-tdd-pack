# Code Hygiene Rules

These apply regardless of language.

## Errors are values

- Errors are not exceptions-to-log-and-continue. Propagate them, handle
  them, or explicitly decide to drop them with a comment explaining why.
- Never silently catch-and-swallow errors. At minimum log them; usually
  propagate them with context.
- Error messages must be actionable. "Something went wrong" is not an
  error message; "failed to connect to orders DB at host X: connection
  refused" is.

## Explicit over implicit

- Prefer explicit parameters over global state.
- Prefer explicit types over stringly-typed APIs.
- Prefer explicit time zones (UTC by default in persistence paths).
- Prefer named constants over magic numbers.

## Comments say "why", not "what"

- The code should say what it does. Comments should say why it does it
  that way, especially when the choice isn't obvious.
- Delete commented-out code. Git remembers.
- TODO/FIXME comments must include the author and a tracking reference
  (issue number, ticket) or be removed.

## No dead code

- Remove unused imports, unused variables, unused functions, unused
  exports on discovery.
- Dead code is a maintenance cost; it looks alive and gets refactored
  even though no one uses it.
- `deadcode` and `unused` linters run in CI — do not regress them.

## Small units of change

- Functions should do one thing. If you need "and" in the function
  description, split it.
- Files should be cohesive. A single 1000-line file is almost always
  several related concerns that could be separated.
- Commits should be focused. One logical change per commit.

## Platform and portability

- Don't assume a specific OS, shell, or terminal unless the code is
  explicitly scoped to one.
- Don't use the current working directory as a reference; use explicit
  paths relative to a known root.
- Handle time zones, encoding, and locale explicitly; never rely on
  system defaults for correctness.

## Documentation

- Every non-trivial public API has docstrings.
- README covers: what the repo is, how to build it, how to run tests,
  how to contribute.
- CHANGELOG belongs in the repo, not buried in commit messages.

## When in doubt

Choose the option that is easier for the next person to understand.
That person might be you, six months from now, at 2am during an
incident.
