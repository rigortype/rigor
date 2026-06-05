# CI setup templates

Copy-paste CI configuration for running Rigor in your project's pipeline.
Each runs Rigor in its **own isolated job** on Ruby 4.0 (see
[chapter 11, "Running Rigor in CI"](../11-ci.md) for why isolation is
required) and surfaces diagnostics inline on the pull / merge request via a
CI-native output format ([ADR-51](../../adr/51-ci-diagnostic-output-formats.md)).

| File | Copy it to | What it does |
| --- | --- | --- |
| [`github-actions-annotations.yml`](github-actions-annotations.yml) | `.github/workflows/rigor.yml` | **The default.** Workflow commands → inline PR annotations. No upload step, no permissions, works on every repo. |
| [`github-actions-sarif.yml`](github-actions-sarif.yml) | `.github/workflows/rigor.yml` | SARIF 2.1.0 → GitHub code scanning (Security tab + PR alerts). Needs code scanning — public repo, or private with GitHub Advanced Security. |
| [`github-actions-reviewdog.yml`](github-actions-reviewdog.yml) | `.github/workflows/rigor.yml` | reviewdog → inline PR **review comments**. Needs `pull-requests: write`. |
| [`gitlab-ci.yml`](gitlab-ci.yml) | `.gitlab-ci.yml` (or `include:` it) | GitLab Code Quality report → the merge-request widget. |

Pick **one** GitHub template. **Default to annotations** — it is the only
one that works on every repository with zero setup. Use SARIF when code
scanning is available (public repo, or private with GitHub Advanced
Security) and you want the Security tab; use reviewdog for threaded review
comments (it works the same way against GitLab, Gerrit, Bitbucket, and Gitea
— see the [`rigor-ci-setup`](../../../skills/rigor-ci-setup/SKILL.md) skill).
All run Rigor the same way — only the output format and publish step differ.

## Other runners (generic recipe)

On any CI system, the four steps are: provision Ruby 4.0, install
`rigortype`, run `rigor check`, and (optionally) publish the report.

```sh
# 1. Ruby 4.0 must be the active Ruby (rbenv/asdf/mise/container image).
# 2. Install Rigor — kept out of your project's Gemfile (see ADR-27).
gem install rigortype
# 3. Run it. Pick the format your platform renders, or plain text for logs.
rigor check                           # human-readable, exit 1 on errors
rigor check --format sarif      > rigor.sarif      # SARIF 2.1.0
rigor check --format gitlab     > codequality.json # GitLab Code Quality
rigor check --format checkstyle > checkstyle.xml   # reviewdog / Jenkins
rigor check --format junit      > junit.xml        # test-report CIs
rigor check --format json       > rigor.json       # generic machine stream
```

The exit code is `0` when there are no errors and `1` otherwise, so the
step gates the pipeline regardless of format. Redirect the report to a file
with `>`; if your platform fails the job on a non-zero exit before the
publish step runs, mark the check step "continue on error" and publish
unconditionally (the GitHub SARIF template shows the pattern).

## Pinning Rigor's version

These templates install the latest `rigortype` at run time. To pin it — and
keep CI reproducible — see [chapter 11 § "Pinning Rigor's version"](../11-ci.md#pinning-rigors-version)
(a CI-only `.github/rigor/Gemfile` that Dependabot can update, or a pinned
`gem install rigortype -v "X.Y.Z"`).
