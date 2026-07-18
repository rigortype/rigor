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
pull / merge request**, not just in the job log. This skill is the
*workflow* — detect the platform, choose the surface, apply the matching
template, pin, gate, verify. It does **not** copy the CI YAML inline: the
authoritative, version-matched templates live in the manual's CI chapter
(`rigor docs ci`) and as ready-to-copy files, so this skill cannot drift
out of date as `--format` surfaces and action versions move.

This is for **users running Rigor on their own project** with the
published `rigor` executable — Rigor is a tool, not a library, so it is
**not** added to the project's `Gemfile`.

## First: load the version-current copy

Follow the copy that ships with the **installed** Rigor, not any vendored
or frozen copy of this file. Two version-matched sources, both offline once
Rigor is installed:

```sh
rigor skill --full rigor-ci-setup   # this skill's current workflow, in one call
rigor docs ci                       # the manual's CI chapter — the actual templates
rigor docs --list manual | grep ci-templates   # ready-to-copy template files
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
in `rigor docs ci` does this.

## Phase 0 — Detect the project's CI platform

**Inspect the repository first; do not ask what you can detect.** Look for
these markers from the project root and let them drive the platform choice:

| Marker (check existence) | Platform |
| --- | --- |
| `.github/workflows/` directory exists | **GitHub Actions** |
| `.gitlab-ci.yml` exists | **GitLab CI** |
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
  project already pins Rigor — keep it (Phase 3).
- Check for `.rigor-baseline.yml` — if present, the project is in baseline
  adoption mode, which changes the gate advice (Phase 4).
- Grep existing CI files for `reviewdog` — if already used, prefer the
  reviewdog surface for consistency.

**Routing:** exactly one platform marker → use it, state what you found, and
proceed. Multiple (e.g. both `.github/workflows/` and `.gitlab-ci.yml`) →
tell the user both were found and ask which to wire (or do both). None → ask.

## Phase 1 — Pick the surface (what the reviewer should see)

All `--format` surfaces are pure renderings of the same diagnostics; the
exit code is unchanged (`0` clean, `1` on errors), so the job still gates.
The full format→platform table and severity mapping are in `rigor docs ci`;
this is the *decision*:

- **GitHub → lead with `github` (annotations).** It works on **every**
  repository with zero setup — no upload, no permissions, no paid features.
  In fact Rigor **auto-detects** GitHub Actions / TeamCity and emits native
  annotations even without `--format`, so a plain `rigor check` already
  annotates the PR (`--no-ci-detect` turns that off). Only upgrade when
  there is a concrete reason:
  - **`sarif`** (Security tab, deduped/persistent alerts) — *only when code
    scanning is available*: a **public** repo (free) or a private repo with
    **GitHub Advanced Security**. Without it `upload-sarif` fails. If you
    cannot tell, **do not default to SARIF** — use `github` and offer SARIF
    to a public-repo / GHAS user.
  - **reviewdog** when the team wants threaded **review comments** filtered
    to changed lines (works on private repos; needs a token — Phase 2).
  - Annotation caveat: the run UI caps annotations per type, so on a first
    adoption of a large codebase prefer the baseline gate (Phase 4) or
    SARIF/reviewdog, which page through everything.
- **GitLab →** `gitlab` (the MR Code Quality widget) or reviewdog.
- **Any test-report CI (CircleCI, Jenkins, …) →** `junit`.

## Phase 2 — Apply the matching template

Take the template for your (platform, surface) choice from `rigor docs ci`
— or copy a ready file listed by `rigor docs --list manual | grep
ci-templates` (GitHub annotations / SARIF / reviewdog, and GitLab). Copy it
in, adjust nothing but the trigger unless asked, and pin the version next
(Phase 3).

**reviewdog is platform-specific.** It reads Rigor's `checkstyle`
(preferred — light, no code scanning) or `sarif`, but the `-reporter` must
match the platform: `github-pr-review` posts only to GitHub,
`gitlab-mr-discussion` only to GitLab — there is **no cross-platform
reporter**. So a reviewdog setup is tied to one platform; for a repo
mirrored across two, wire one reviewdog job per platform (or use each
platform's native format). The reporter table, tokens, and the
`-fail-level` / `-filter-mode` knobs are in `rigor docs ci` — keep
`-filter-mode=added` to adopt on an existing codebase (the reviewdog
analogue of a baseline).

## Phase 3 — Pin Rigor's version (reproducible CI)

The templates install the latest `rigortype` at run time. To pin it, use a
**CI-only `Gemfile`** (`.github/rigor/Gemfile`, read only by the Rigor job,
Dependabot-updatable) or a **pinned `gem install rigortype -v "X.Y.Z"`**.
The exact recipe (the `BUNDLE_GEMFILE` wiring, the Dependabot entry) is in
`rigor docs ci` § "Pinning Rigor's version".

## Phase 4 — Gate behaviour (optional, with the user)

- **Baseline adoption.** If the project uses `.rigor-baseline.yml`, the same
  `rigor check` honours it — CI fails only on *new* diagnostics. Add
  `--baseline-strict` to also fail when the baseline drifts loose (forces
  regeneration). With reviewdog, `-filter-mode=added` plays the analogous
  role.
- **Determinism.** Add `--no-cache` in CI if you want each run independent
  of any persisted `.rigor/cache`.
- **Cache persistence (opposite trade).** When the Rigor job's runtime
  matters, persist `.rigor/cache` with the CI's cache facility **and set
  `RIGOR_STRICT_VALIDATION=1` on the job** — a fresh checkout regenerates
  every stat tuple, and without strict mode the plugin watch-glob cache
  slots read as stale on every run. Never persist the cache without the
  env var. Snippets: `rigor docs ci` § "Persisting the analysis cache
  across runs".

## Verify

1. The Rigor job runs on `ruby-version: "4.0"` in its own job (not merged
   into a test matrix job).
2. On a PR that introduces a type error, the finding appears inline (an
   annotation / review comment / widget entry, per the chosen surface) and
   the job fails (exit 1).
3. On a clean PR the job passes (exit 0).

## References

- Manual: `rigor`'s CI chapter — the authoritative templates, severity
  mapping, and pinning recipe, **offline and version-matched** with
  `rigor docs ci` (ready files: `rigor docs --list manual | grep
  ci-templates`). Web fallback, before Rigor is installed:
  <https://github.com/rigortype/rigor/blob/master/docs/manual/11-ci.md>.
- [ADR-51](https://github.com/rigortype/rigor/blob/master/docs/adr/51-ci-diagnostic-output-formats.md)
  — the output-format surface (the severity / identifier contract).
- [ADR-27](https://github.com/rigortype/rigor/blob/master/docs/adr/27-tool-distribution-model.md)
  — why Rigor installs standalone and runs in its own job.
- [reviewdog](https://github.com/reviewdog/reviewdog) /
  [action-setup](https://github.com/reviewdog/action-setup).
