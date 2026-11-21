# Contributing to Alamock

Thanks for taking the time to contribute. This document covers the development
workflow, the tooling gates, and the commit/pull-request conventions this repository
enforces.

- [Requirements](#requirements)
- [Setting up](#setting-up)
- [Everyday commands](#everyday-commands)
- [Formatting](#formatting)
- [Linting](#linting)
- [Commit messages](#commit-messages)
- [Pull requests](#pull-requests)
- [Project layout](#project-layout)

## Requirements

| Tool | Version CI pins | Notes |
|---|---|---|
| Swift | 6.4.2 | The package is in Swift 6 language mode (`swift-tools-version: 6.0`); any Swift 6.0+ toolchain builds it, CI uses 6.4.2. |
| Xcode | 27.2 | Ships the pinned Swift and `xcrun swift-format`; any Xcode 16+ builds the package. |
| [swift-format](https://github.com/swiftlang/swift-format) | 6.4.4 | Bundled with the toolchain: `xcrun swift-format`. |
| [mise](https://mise.jdx.dev/) | 2026.9.6 | Installs the non-Xcode tools and runs the tasks in [`.mise.toml`](.mise.toml). |
| [SwiftLint](https://github.com/realm/SwiftLint) | 0.65.1 | Pinned in `.mise.toml`; install it with `mise install`. CI installs the same pin through `jdx/mise-action`. |

CI selects `/Applications/Xcode_27.2.app` on the `xcode-27` runner image, installs the
tools pinned in `.mise.toml` through `jdx/mise-action`, prints the versions, and fails
when Swift or swift-format differs from `PINNED_*` in `.github/workflows/ci.yml`. That
is what keeps `mise run lint` meaningful: a different swift-format build would report
drift that does not exist, and a different SwiftLint would add rules mid-stream. A newer
SwiftLint can enable new rules: if a local run reports violations that CI does not,
update `.swiftlint.yml` in the same pull request rather than silently changing style.
See [README "Continuous integration and releases"](README.md#continuous-integration-and-releases).

## Setting up

```bash
git clone https://github.com/mo5tone/Alamock.git
cd Alamock
mise install     # installs SwiftLint 0.65.1 (Swift/swift-format come from Xcode)
mise run hooks   # installs the commit-msg hook (see below)
mise run verify  # should be green before you change anything
```

`mise run hooks` runs `git config core.hooksPath .githooks`, which enables the
repository's `commit-msg` hook for this clone. The hook is local configuration: it is
not committed to anyone else's clone, and CI re-validates the same rules. `mise run
setup` combines `mise install` and `mise run hooks`.

## Everyday commands

Run `mise tasks` with no arguments to print the list of tasks.

| Command | What it does |
|---|---|
| `mise run format` | Rewrite `Sources`, `Tests` and `Package.swift` with swift-format. |
| `mise run format-check` | Verify formatting without touching files (fails on drift). |
| `mise run lint` | `swiftlint lint --strict` followed by the swift-format check. |
| `mise run test` | `swift test --parallel`. |
| `mise run test-release` | `swift test -c release --parallel` (catches optimization-only issues). |
| `mise run verify` | `lint` + `test` — the gate CI runs. |
| `mise run hooks` | Install the repository git hooks. |

Each task is a thin wrapper around `scripts/`, so the same commands work when invoked
directly and can be exported to other tooling:

```bash
./scripts/format.sh check
./scripts/lint.sh
./scripts/validate-conventional-commits.sh --range origin/main..HEAD
```

## Formatting

swift-format owns formatting; do not hand-format around it. The configuration in
[`.swift-format`](.swift-format) is deliberately small:

- 120-column lines, 4-space indentation.
- Existing line breaks are respected, so a diff contains only the lines that actually
  need to move.
- Multiline string literals are never reflowed.
- `UseLetInEveryBoundCaseVariable` is off: this codebase writes `case let .foo(value)`,
  and the rule rewrites it to `case .foo(let value)` for no benefit.

Workflow:

```bash
mise run format       # rewrite
git diff              # review — formatting-only changes should be a separate commit
mise run format-check # confirm a clean tree afterwards
```

CI fails on `mise run lint`, which includes the format check, so an unformatted push is
a red build.

## Linting

SwiftLint runs with `--strict`, which turns warnings into failures: a green run means
exactly zero findings. The configuration lives in [`.swiftlint.yml`](.swiftlint.yml).

Three rules are disabled. Each has a reason, and the reason is what matters when
reviewing a change to the list:

| Disabled rule | Why |
|---|---|
| `trailing_comma` | swift-format's `multiElementCollectionTrailingCommas` inserts trailing commas in multi-element collection literals; the two tools would disagree on every file. |
| `static_over_final_class` | `URLProtocol` subclasses must override `class func canInit(with:)`; Swift rejects `static` for an overridable superclass method. |
| `optional_data_string_conversion` | The tests decode UTF-8 fixtures with `String(decoding:as:)`, which is the clearer, non-optional API for data the test itself produced. |

Thresholds are widened to fit the existing matchers and response builders rather than
the other way round:

| Rule | Warning | Error |
|---|---|---|
| `line_length` | 120 | 160 |
| `cyclomatic_complexity` | 15 | 25 |
| `file_length` (comments ignored) | 700 | 1200 |
| `type_body_length` | 700 | 1200 |
| `function_body_length` | 60 | 120 |
| `identifier_name` | min 1, max 50 | — |

Prefer a narrow, justified suppression over a broad one:

```swift
// swiftlint:disable:next cyclomatic_complexity
func matchesRequest(_ request: URLRequest) -> Bool {
```

File-wide `swiftlint:disable` comments and `disable_all` are not used in this repository.
If a rule is genuinely wrong for the project, disable it in `.swiftlint.yml` with a
comment that explains why, so the next reader does not have to rediscover it.

## Commit messages

Every commit message — and every pull request title, because we squash-merge — must
follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):

```
<type>[(<scope>)][!]: <description>

[optional body]

[optional footer(s)]
```

Rules enforced by `scripts/validate-conventional-commits.sh` (and therefore by the hook
and CI):

- **Header length** — at most 100 characters.
- **Type** — one of the types below. Lowercase.
- **Scope** — optional, lowercase letters, digits, `.`, `_`, `/`, `-`.
- **Separator** — exactly one colon and one space: `feat:`, not `feat:  ` or `Feat :`.
- **Description** — required, imperative mood, no trailing period.
- **Body** — when present, separated from the header by a blank line.
- **Breaking changes** — `!` after the type/scope (`feat!:`) and/or a
  `BREAKING CHANGE: <description>` footer.

Allowed types:

| Type | Use for |
|---|---|
| `feat` | A new public capability (route matching, response builders, verification helpers). |
| `fix` | A bug fix in library behavior. |
| `docs` | README, doc comments, CONTRIBUTING. |
| `style` | Formatting-only changes with no behavior change. |
| `refactor` | Internal restructuring with no behavior change. |
| `perf` | Performance improvements. |
| `test` | Test additions or fixes. |
| `build` | `Package.swift`, dependency bumps, build settings. |
| `ci` | GitHub Actions and release automation. |
| `chore` | Repository maintenance (hooks, scripts, tooling config). |
| `revert` | Reverting a previous commit. |

Suggested scopes: `routing`, `matching`, `responses`, `recording`, `verification`,
`transport`, `concurrency`, `tests`, `tooling`, `ci`, `deps`. The list is a convention,
not a whitelist — use the narrowest label that describes the touched area.

Examples:

```
feat(routing): support ** wildcard path segments
fix(transport): record redirect hops for GET requests
refactor(matching): share query-item parsing with verification
docs: document the recording and verification helpers
chore(tooling): add SwiftLint and swift-format configuration
fix!: drop the legacy matcher API
```

Git-generated commits are exempt: `Merge ...` from a merge, `Revert "..."` from
`git revert`, and autosquash subjects (`fixup!`, `squash!`, `amend!`) are validated on
the message they wrap.

### The commit-msg hook

```bash
mise run hooks                              # once per clone
git commit -m "feat(tooling): add lint and format tooling"   # accepted
git commit -m "update stuff"                                 # rejected
```

The hook runs `scripts/validate-conventional-commits.sh --message-file`. For an
emergency you can bypass it with `git commit --no-verify`, but CI validates the pushed
range with the same script, so the message has to be fixed (via `git rebase` or an
interactive `git commit --amend`) before the branch can merge.

Validate by hand:

```bash
scripts/validate-conventional-commits.sh --range origin/main..HEAD
scripts/validate-conventional-commits.sh --text "feat(ci): cache the SwiftPM build"
```

## Pull requests

1. Branch from `main`: `feat/wildcard-segments`, `fix/redirect-recording`.
2. Keep one logical change per pull request. Include tests for behavior changes.
3. Run `mise run verify` — the same gate CI runs — and add `mise run test-release` for
   changes that touch concurrency, locks, or anything optimization-sensitive.
4. **Title the pull request with a Conventional Commits header.** We squash-merge only:
   the pull request title becomes the commit subject on `main`, and the pull request body
   becomes the commit body. A title that fails the message validator fails CI.
   - Good: `feat(routing): support ** wildcard path segments`
   - Bad: `Add wildcard support`, `WIP: routing`, `feature(routing): add wildcards`
5. Describe the change in the body: what behavior changed, why, and how it was verified.
   Note any public API change explicitly.
6. Keep the diff reviewable. Mixed formatting+behavior changes are hard to review — land
   `style` commits separately.

Merging is squash-only — `allow_squash_merge` is on, merge commits and rebase merges are
off — so the pull request title becomes the commit subject on `main` and the body becomes
the commit body. Every commit in the branch is still validated by CI: run
`scripts/validate-conventional-commits.sh --range origin/main..HEAD` before pushing. Later
fixups can disappear in the squash, but the branch has to be green as pushed.

`main` is protected: a pull request is required, and the four checks (*Build & test*,
*Lint & format*, *Conventional Commits*, *Validate PR title*) must pass before it can
merge. The repository owner keeps a bypass for emergencies, and the bypass is recorded
in the branch protection audit log; direct pushes to `main` run the push CI but skip
the pull-request gates, so use them only when that trade-off is intentional.

## Project layout

```
Sources/Alamock/          # library
Sources/Alamock/Internal/ # locking + weak server registry
Tests/AlamockTests/       # integration and matcher tests
.mise.toml                # SwiftLint pin + task definitions
scripts/                  # format.sh, lint.sh, validate-conventional-commits.sh
.githooks/                # commit-msg hook (installed with `mise run hooks`)
.github/workflows/        # ci.yml, pr-title.yml, release.yml
.github/PULL_REQUEST_TEMPLATE.md  # PR body template (title becomes the squash subject)
.github/actionlint.yaml   # actionlint metadata for the xcode-27 runner label
```
