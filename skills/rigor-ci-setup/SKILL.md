---
name: rigor-ci-setup
description: |
  Wire Rigor type-checking into a project's CI pipeline: run it in its own isolated Ruby-4.0 job and surface diagnostics inline on the pull / merge request via a CI-native output format (SARIF, GitHub Actions annotations, GitLab Code Quality, Checkstyle, JUnit) or through reviewdog. Triggers: "add Rigor to CI", "run rigor in GitHub Actions / GitLab CI", "show Rigor errors on the PR", "set up reviewdog for rigor". NOT for first-time project configuration (use rigor-project-init to create `.rigor.yml` first) or reducing a baseline (use rigor-baseline-reduce).
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor CI Setup

Wire Rigor into a project's CI so type diagnostics appear **inline on the
pull / merge request**, not just in the job log. This skill is for **users
running Rigor on their own project** with the published `rigor` executable —
Rigor is a tool, not a library, so it is **not** added to the project's
`Gemfile` (see [ADR-27](https://github.com/rigortype/rigor/blob/main/docs/adr/27-tool-distribution-model.md)).

If the project has no `.rigor.yml` yet, run the **rigor-project-init** skill
first — this skill assumes `rigor check` already runs locally.

## The one hard rule: Rigor gets its own job

Rigor runs on **Ruby 4.0**. `ruby/setup-ruby` sets the *job's* active Ruby,
so a job that provisions the project's test Ruby (often 3.x, or a matrix)
**cannot** also provision Rigor's 4.0 — the second `setup-ruby` clobbers the
first. Always give Rigor a **separate job** (better: a separate workflow
file, for its own triggers, concurrency, and status badge). Every template
below does this.

## Phase 1 — Pick the surface (what the reviewer should see)

Ask the user which inline surface they want, then pick the matching
`--format`. All formats are pure renderings of the same diagnostics; the
exit code is unchanged (`0` clean, `1` on errors), so the job still gates.

| Platform / goal | `--format` | How it surfaces |
| --- | --- | --- |
| GitHub — zero setup, inline annotations | `github` | `::error file=…::` workflow commands → PR diff annotations. No upload, no permissions. |
| GitHub — Security tab + richer alerts | `sarif` | SARIF 2.1.0 uploaded via `upload-sarif`. Needs `security-events: write`. |
| GitHub/GitLab/Gerrit/Bitbucket/Gitea — PR/MR **review comments** | `checkstyle` (or `sarif`) piped to **reviewdog** | reviewdog posts comments. See Phase 3. |
| GitLab — MR Code Quality widget | `gitlab` | Code Quality JSON published as a `codequality` report artifact. |
| Any test-report CI (CircleCI, Jenkins, …) | `junit` | JUnit XML; every diagnostic is a `testcase` failure. |

Recommendation when unsure: **SARIF** on GitHub (cross-platform, reusable),
**Code Quality** on GitLab, **reviewdog** when the team wants threaded review
comments anywhere.

## Phase 2 — Drop in the workflow

Pick **one** template, copy it into the project, and adjust nothing but the
trigger if asked. Pin the version later (Phase 4).

### GitHub — inline annotations (no setup)

```yaml
# .github/workflows/rigor.yml
name: rigor
on: [push, pull_request]
jobs:
  rigor:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "4.0"
      - run: gem install rigortype
      - run: rigor check --format github
```

### GitHub — SARIF → code scanning

```yaml
# .github/workflows/rigor.yml
name: rigor
on: [push, pull_request]
permissions:
  contents: read
  security-events: write   # required by upload-sarif
jobs:
  rigor:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "4.0"
      - run: gem install rigortype
      - run: rigor check --format sarif > rigor.sarif
        continue-on-error: true        # so a non-zero exit still uploads
      - uses: github/codeql-action/upload-sarif@v3
        if: always()
        with:
          sarif_file: rigor.sarif
```

### GitLab — Code Quality widget

```yaml
# .gitlab-ci.yml
rigor:
  image: ruby:4.0
  script:
    - gem install rigortype
    - rigor check --format gitlab > gl-code-quality-report.json
  artifacts:
    reports:
      codequality: gl-code-quality-report.json
    when: always
```

### Other runners (generic)

Provision Ruby 4.0, `gem install rigortype`, then
`rigor check --format junit > junit.xml` (or `checkstyle`, `json`) and
publish the file with whatever artifact mechanism the platform offers.

## Phase 3 — reviewdog (inline review comments, any platform)

[reviewdog](https://github.com/reviewdog/reviewdog) turns Rigor's output
into PR/MR review comments on GitHub, GitLab, Gerrit, Bitbucket, and Gitea.
It reads Rigor's `checkstyle` or `sarif` output, so one format covers every
reporter. Install it with
[`reviewdog/action-setup`](https://github.com/reviewdog/action-setup):

```yaml
# .github/workflows/rigor.yml  (GitHub PR review comments)
name: rigor
on: [pull_request]
permissions:
  contents: read
  pull-requests: write          # required for github-pr-review
jobs:
  rigor:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "4.0"
      - run: gem install rigortype
      - uses: reviewdog/action-setup@v1
        with:
          reviewdog_version: latest
      - run: rigor check --format checkstyle | reviewdog -f=checkstyle -reporter=github-pr-review -fail-level=error
        env:
          REVIEWDOG_GITHUB_API_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Knobs to set with the user:

- **`-reporter`** — `github-pr-review` (threaded review comments, the
  default choice) · `github-pr-check` (a Check run) · `github-pr-annotations`
  (annotations) on GitHub; `gitlab-mr-discussion` on GitLab (set
  `REVIEWDOG_GITLAB_API_TOKEN` + `CI_API_V4_URL`); `gerrit-change-review`,
  `bitbucket-code-report`, `gitea-pr-review` elsewhere.
- **`-fail-level`** — `error` makes the step fail only on Rigor errors
  (matches Rigor's exit code); `any` fails on warnings too; `none` never
  fails (comment-only). Default to `error`.
- **`-filter-mode`** — reviewdog's default `added` comments only on lines
  the PR changed; `nofilter` comments on everything. Keep `added` for
  adopt-on-an-existing-codebase, like Rigor's baseline.
- **Token / permissions** — `github-pr-review` needs
  `permissions: pull-requests: write` and `REVIEWDOG_GITHUB_API_TOKEN:
  ${{ secrets.GITHUB_TOKEN }}`.

`checkstyle` vs `sarif` into reviewdog: both work (`-f=checkstyle` /
`-f=sarif`). Prefer `checkstyle` — it is lighter and needs no
code-scanning. Use `sarif` if the project *also* uploads to the Security
tab and wants one format.

## Phase 4 — Pin Rigor's version (reproducible CI)

The templates install the latest `rigortype` at run time. To pin it:

- **CI-only `Gemfile` (recommended, Dependabot-updatable).** Commit
  `.github/rigor/Gemfile` (`source "https://rubygems.org"` +
  `gem "rigortype", "~> 0.1"`) and its lockfile, set
  `env: BUNDLE_GEMFILE: .github/rigor/Gemfile` on the Rigor job, use
  `ruby/setup-ruby` with `bundler-cache: true`, and run `bundle exec rigor
  check …`. Add a Dependabot `bundler` entry scoped to `/.github/rigor`.
  This file is read only by the Rigor job — it never enters the project's
  resolution.
- **Pinned `gem install`.** `gem install rigortype -v "X.Y.Z"`. Simple, but
  Dependabot can't see it (manual updates).

## Phase 5 — Gate behaviour (optional, with the user)

- **Baseline adoption.** If the project uses `.rigor-baseline.yml`
  (rigor-project-init / rigor-baseline-reduce), the same `rigor check`
  honours it — CI fails only on *new* diagnostics. Add `--baseline-strict`
  to also fail when the baseline has drifted loose (a CI gate that forces
  regeneration). With reviewdog, `-filter-mode=added` plays the analogous
  role for review comments.
- **Determinism.** Add `--no-cache` in CI if you want each run independent
  of any persisted `.rigor/cache`.

## Verify

1. The Rigor job runs on `ruby-version: "4.0"` in its own job (not merged
   into a test matrix job).
2. On a PR that introduces a type error, the finding appears inline (an
   annotation / review comment / widget entry, per the chosen surface) and
   the job fails (exit 1).
3. On a clean PR the job passes (exit 0).

## References

- Manual: `rigor`'s CI chapter — `docs/manual/11-ci.md` in the repo, or
  <https://github.com/rigortype/rigor/blob/main/docs/manual/11-ci.md>. The
  copy-paste template files live at `docs/manual/ci-templates/`.
- [ADR-51](https://github.com/rigortype/rigor/blob/main/docs/adr/51-ci-diagnostic-output-formats.md)
  — the output-format surface (the severity / identifier contract).
- [ADR-27](https://github.com/rigortype/rigor/blob/main/docs/adr/27-tool-distribution-model.md)
  — why Rigor installs standalone and runs in its own job.
- [reviewdog](https://github.com/reviewdog/reviewdog) /
  [action-setup](https://github.com/reviewdog/action-setup).
