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
`Gemfile` (see [ADR-27](https://github.com/rigortype/rigor/blob/master/docs/adr/27-tool-distribution-model.md)).

If the project has no `.rigor.yml` yet, run the **rigor-project-init** skill
first — this skill assumes `rigor check` already runs locally.

## First: load the version-current copy

The CI templates, `--format` surfaces, and reviewdog reporters below are the
fastest-moving detail in any skill (new output formats, changed flags, the
supported Ruby). Follow the copy that ships with the **installed** Rigor,
not any vendored or frozen copy of this file. Two version-matched sources,
both offline once Rigor is installed:

```sh
rigor skill --full rigor-ci-setup   # this skill's current workflow, in one call
rigor docs ci                       # the manual's CI chapter (authoritative templates)
```

If you already loaded this skill *via* `rigor skill` you have the current
copy — just proceed. If `rigor` is not on `PATH`, this task needs it: run
**`rigor-next-steps`** to install Rigor first, then come back.

## The one hard rule: Rigor gets its own job

Rigor runs on **Ruby 4.0**. `ruby/setup-ruby` sets the *job's* active Ruby,
so a job that provisions the project's test Ruby (often 3.x, or a matrix)
**cannot** also provision Rigor's 4.0 — the second `setup-ruby` clobbers the
first. Always give Rigor a **separate job** (better: a separate workflow
file, for its own triggers, concurrency, and status badge). Every template
below does this.

## Phase 0 — Detect the project's CI platform

**Inspect the repository first; do not ask what you can detect.** Look for
these markers from the project root and let them drive the platform choice:

| Marker (check existence) | Platform → template |
| --- | --- |
| `.github/workflows/` directory exists | **GitHub Actions** (Phase 2 GitHub templates) |
| `.gitlab-ci.yml` exists | **GitLab CI** (Phase 2 GitLab template) |
| `.circleci/config.yml` exists | **CircleCI** (generic recipe, `junit`) |
| `Jenkinsfile` exists | **Jenkins** (generic recipe, `junit` / `checkstyle`) |
| `bitbucket-pipelines.yml` / `azure-pipelines.yml` / `.drone.yml` | that platform (generic recipe) |
| none of the above | no CI yet — **ask** the user which platform they use |

Concretely (the agent has file tools — use them):

- List `.github/workflows/*.yml` and `.gitlab-ci.yml`. **If
  `.github/workflows/rigor.yml` already exists, read it** — this is an
  *update*, not a fresh add: preserve the user's triggers / pinning and only
  change the format / steps that are wrong or missing. The same applies to
  an existing `rigor` job inside `.gitlab-ci.yml`.
- Check for an existing pin: `.github/rigor/Gemfile` (+ lockfile) means the
  project already pins Rigor — keep it (Phase 4).
- Check for `.rigor-baseline.yml` — if present, the project is in baseline
  adoption mode, which changes the gate advice (Phase 5).
- Grep existing CI files for `reviewdog` — if already used, prefer the
  reviewdog path (Phase 3) for consistency.

**Routing:** exactly one platform marker → use it, state what you found, and
proceed. Multiple (e.g. both `.github/workflows/` and `.gitlab-ci.yml`) →
tell the user both were found and ask which to wire (or do both). None → ask.

## Phase 1 — Pick the surface (what the reviewer should see)

With the platform from Phase 0, pick the matching `--format` (confirm with
the user only when the platform offers more than one good surface). All
formats are pure renderings of the same diagnostics; the exit code is
unchanged (`0` clean, `1` on errors), so the job still gates.

| Platform / goal | `--format` | How it surfaces |
| --- | --- | --- |
| **GitHub — the default** | `github` | `::error file=…::` workflow commands → inline PR-diff annotations. No upload, no permissions, works on **every** repo. |
| GitHub — Security tab + persistent/deduped alerts | `sarif` | SARIF 2.1.0 via `upload-sarif`. **Requires code scanning** (see note) + `security-events: write`. |
| GitHub/GitLab/Gerrit/Bitbucket/Gitea — PR/MR **review comments** | `checkstyle` (or `sarif`) piped to **reviewdog** | reviewdog posts comments. See Phase 3. |
| GitLab — MR Code Quality widget | `gitlab` | Code Quality JSON published as a `codequality` report artifact. |
| Any test-report CI (CircleCI, Jenkins, …) | `junit` | JUnit XML; every diagnostic is a `testcase` failure. |

**The GitHub default is `github` (annotations).** It is the one path that
works on every repository with zero setup — no upload step, no extra
permissions, no paid features — so lead with it unless the user asks for
more. (It is also what PHPStan recommends for GitHub Actions.)

In fact, on GitHub Actions and TeamCity Rigor **auto-detects the CI and
emits the native annotations even without `--format`** (it augments the
default text output; ADR-51 WD7). So the simplest GitHub setup is the
minimal workflow — plain `rigor check`, no `--format` — and you still get
inline annotations. Pass `--format github` only when you want *just* the
annotation stream (e.g. piping elsewhere); use `--no-ci-detect` to turn the
augmentation off. Upgrade beyond annotations only when there is a concrete
reason:

- **`sarif`** *only when code scanning is available* — i.e. a **public**
  repo (free) or a **private** repo with **GitHub Advanced Security /
  Code Security** enabled. Without it, `upload-sarif` fails with
  *"GitHub Advanced Security must be enabled for this repository"*. When
  available it adds the Security tab, deduped + persistent alerts, and PR
  alerts. If you cannot tell whether the repo is public or has GHAS, **do
  not default to SARIF** — use `github`, and offer SARIF as an option to a
  public-repo / GHAS user.
- **reviewdog** when the team wants threaded **review comments** filtered to
  the changed lines (works on private repos; needs a token, Phase 3).

GitHub annotation caveat: the run UI shows only a limited number of
annotations per type, so on a first adoption of a large codebase prefer the
baseline gate (Phase 5) or SARIF/reviewdog, which page through everything.

Other platforms: **Code Quality** (`gitlab`) on GitLab; `junit` on the
test-report CIs.

## Phase 2 — Drop in the workflow

Pick **one** template, copy it into the project, and adjust nothing but the
trigger if asked. Pin the version later (Phase 4).

### GitHub — inline annotations (no setup) — the default

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

Use this **only if code scanning is available** for the repo — a public repo
(free), or a private repo with GitHub Advanced Security / Code Security.
Otherwise `upload-sarif` fails; use the annotations template above.

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

`--format gitlab` emits exactly the
[Code Quality report format](https://docs.gitlab.com/ci/testing/code_quality/)
GitLab requires: each finding carries `description`, `check_name`,
`fingerprint` (a stable SHA-256, so a finding keeps its identity across
runs), `severity` (`major`/`minor`/`info`), and `location.path` +
`location.lines.begin`. Paths are repo-relative with no `./` prefix and the
JSON has no BOM, both of which GitLab demands. For the MR widget to show a
*diff* of new vs resolved findings, the report must exist on **both** the
target (default) branch and the MR branch — the job above runs on each
pipeline, which satisfies that automatically once it has run once on the
default branch. (Note: a long-standing GitLab display bug can hide
`check_name`; Rigor already folds the rule id into `description` as
`… [rule]`, so the identifier shows regardless.)

### Other runners (generic)

Provision Ruby 4.0, `gem install rigortype`, then
`rigor check --format junit > junit.xml` (or `checkstyle`, `json`) and
publish the file with whatever artifact mechanism the platform offers.

## Phase 3 — reviewdog (inline review comments)

[reviewdog](https://github.com/reviewdog/reviewdog) turns Rigor's output
into PR/MR review comments. It reads Rigor's `checkstyle` (preferred — light,
no code scanning) or `sarif`, so the format is the same everywhere — **but
the `-reporter` is platform-specific, so it must match the platform you
detected in Phase 0.** Pick the reporter first, then the token/env it needs:

| Phase 0 platform | `-reporter` | Token / env | Other needs |
| --- | --- | --- | --- |
| GitHub | `github-pr-review` (threaded comments) · `github-pr-check` (Check run) · `github-pr-annotations` | `REVIEWDOG_GITHUB_API_TOKEN: ${{ secrets.GITHUB_TOKEN }}` | `permissions: pull-requests: write` |
| GitLab | `gitlab-mr-discussion` (threaded) · `gitlab-mr-commit` | `REVIEWDOG_GITLAB_API_TOKEN` (a project/personal token) + `CI_API_V4_URL` | runs on MR pipelines |
| Gerrit / Bitbucket / Gitea | `gerrit-change-review` · `bitbucket-code-report` · `gitea-pr-review` | the platform's token var (see reviewdog README) | — |

There is **no cross-platform reviewdog reporter** — `github-*` posts only to
GitHub, `gitlab-*` only to GitLab. So a reviewdog setup is always tied to one
platform; if a project targets two (e.g. a GitHub mirror of a GitLab repo),
wire one reviewdog job per platform, or use the platform-native format
(`sarif` / `gitlab`) on each.

Install reviewdog with
[`reviewdog/action-setup`](https://github.com/reviewdog/action-setup) (GitHub)
or `go install` / the binary (GitLab and others).

**GitHub** (`.github/workflows/rigor.yml`):

```yaml
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

**GitLab** (`.gitlab-ci.yml`) — install the reviewdog binary, then pipe:

```yaml
rigor:
  image: ruby:4.0
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
  variables:
    REVIEWDOG_GITLAB_API_TOKEN: $RIGOR_REVIEWDOG_TOKEN   # a CI/CD variable you set
  script:
    - gem install rigortype
    - wget -O - -q https://raw.githubusercontent.com/reviewdog/reviewdog/master/install.sh | sh -s -- -b /usr/local/bin
    - rigor check --format checkstyle | reviewdog -f=checkstyle -reporter=gitlab-mr-discussion -fail-level=error
```

Knobs (both platforms):

- **`-fail-level`** — `error` fails the step only on Rigor errors (matches
  Rigor's exit code); `any` fails on warnings too; `none` is comment-only.
  Default `error`.
- **`-filter-mode`** — reviewdog's default `added` comments only on lines
  the PR/MR changed; `nofilter` comments on everything. Keep `added` to adopt
  on an existing codebase (the reviewdog analogue of Rigor's baseline).
- **`checkstyle` vs `sarif`** — both work (`-f=checkstyle` / `-f=sarif`);
  prefer `checkstyle` (lighter, no code scanning). Use `sarif` only if the
  job *also* uploads to the GitHub Security tab and wants a single format.

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

- Manual: `rigor`'s CI chapter — read it **offline and version-matched**
  with `rigor docs ci` (the copy-paste template files: `rigor docs
  --list manual | grep ci-templates`). Web fallback, before Rigor is
  installed: <https://github.com/rigortype/rigor/blob/master/docs/manual/11-ci.md>.
- [ADR-51](https://github.com/rigortype/rigor/blob/master/docs/adr/51-ci-diagnostic-output-formats.md)
  — the output-format surface (the severity / identifier contract).
- [ADR-27](https://github.com/rigortype/rigor/blob/master/docs/adr/27-tool-distribution-model.md)
  — why Rigor installs standalone and runs in its own job.
- [reviewdog](https://github.com/reviewdog/reviewdog) /
  [action-setup](https://github.com/reviewdog/action-setup).
