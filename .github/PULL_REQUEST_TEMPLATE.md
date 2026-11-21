<!--
The pull request title becomes the squash-merge commit subject on `main`, so it must
be a Conventional Commits header — `feat(routing): support ** wildcard segments`.
CI validates the title, every commit in the branch, and the lint/format/test gates.
See CONTRIBUTING.md for the type/scope vocabulary.
-->

## Summary

<!-- What changes, and why? Call out public API changes explicitly. -->

## Type of change

- [ ] `feat` — new capability
- [ ] `fix` — bug fix
- [ ] `docs` / `style` / `refactor` / `perf` / `test` / `build` / `ci` / `chore`

## Verification

- [ ] `mise run verify` passes locally
- [ ] `mise run test-release` for changes touching concurrency, locking, or timing
- [ ] Tests cover the new or changed behavior

## Checklist

- [ ] The title follows Conventional Commits and reads well as the commit subject
- [ ] Commits in the branch follow Conventional Commits (CI checks the whole range)
- [ ] Documentation updated when behavior or public API changed
