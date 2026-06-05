# ADR-51 — CI-native diagnostic output formats

Status: **Accepted, 2026-06-06; partially implemented (v0.1.18).** Six
CI-native renderings of the existing diagnostic stream land behind
`rigor check --format`: **`sarif`** (SARIF 2.1.0, the cross-platform
anchor), **`github`** (GitHub Actions workflow commands), **`gitlab`**
(GitLab Code Quality report JSON), **`checkstyle`** (Checkstyle XML — the
reviewdog / Jenkins lint-interchange format), **`junit`** (JUnit XML —
the broad test-report format), and **`teamcity`** (TeamCity inspection
service messages). Each is a presentation layer over the same
`Analysis::Diagnostic` fields `--format json` already exposes — no new
analysis, no new diagnostic information. On top of the formats, **runtime
CI auto-detection** (WD7) emits the platform-native form automatically on the
default output when a first-class CI is detected. The formatters and the
detector live in
[`lib/rigor/cli/diagnostic_formats.rb`](../../lib/rigor/cli/diagnostic_formats.rb)
+ [`lib/rigor/cli/ci_detector.rb`](../../lib/rigor/cli/ci_detector.rb); the
copy-paste CI setup templates (ADR-27 § WD3), the
[`rigor-ci-setup`](../../skills/rigor-ci-setup/SKILL.md) bundled skill, and
the manual update ship in the same cut.

Grounding: [ADR-27](27-tool-distribution-model.md) (distribution / CI
channel — this ADR is its diagnostic-output sibling) and
[ADR-50](50-release-engineering-and-stability-strategy.md) WD1 (a new
output format is a public-contract surface).

## Context

Today `rigor check` renders to `text` (human) or `json` (the generic
machine stream). In CI, both land **only in the job log** — a developer
must open the failed job and read it. CI platforms can instead surface a
finding *inline on the changed code* (a PR/MR annotation, a code-scanning
alert, a Code Quality widget) — but each platform reads a *specific*
format to do so, and `--format json` is none of them. The integration gap
is the v0.1.18 cycle's headline (ROADMAP § "v0.1.18 — CI-environment
support"): without a platform-native rendering, Rigor's CI value stops at
the exit code.

The formats that cover the field:

- **SARIF 2.1.0** — the OASIS interchange standard. GitHub's
  `upload-sarif` ingests it for the PR diff and Security tab; many other
  tools consume it too. It is the *cross-platform* option — one format,
  multiple consumers.
- **GitHub Actions workflow commands** — `::error file=…,line=…::` lines
  the runner parses out of stdout into inline annotations, with **no
  upload step**. Cheapest possible GitHub integration.
- **GitLab Code Quality** — the CodeClimate-subset JSON GitLab reads from
  a `codequality` artifact to populate the MR Code Quality widget; the
  GitLab-native equivalent of SARIF-on-GitHub.
- **Checkstyle XML** — the long-standing lint-interchange format a wide
  range of tools read. Most usefully **reviewdog** consumes it
  (`-f=checkstyle`) and then posts to *any* of its reporters (GitHub PR
  review, GitLab MR discussion, Gerrit, Bitbucket, Gitea); Jenkins and
  other tools read it too.
- **JUnit XML** — the test-report format GitHub test reporting, GitLab,
  Jenkins, and CircleCI render natively.

A new output format is a **public-contract surface** under ADR-50 WD1
(a consumer's CI pipeline parses it), which is why this is an ADR and not
a CHANGELOG line — the format shapes are something we commit to.

## Decision

Add the formats as `--format` values, dispatched from the existing
`write_result` case in [`lib/rigor/cli.rb`](../../lib/rigor/cli.rb) (~L864)
to small per-format renderer classes (`lib/rigor/cli/diagnostic_formats.rb`). The discriminating **criterion** for
what belongs here: *a format earns a `--format` value when a CI platform
renders the diagnostic stream inline from it.* That is the boundary — a
format consumed by a platform's PR/MR surface is in scope; a format that is
merely "another way to serialize" (CSV, a custom shape) is not, because
`--format json` already serves generic machine consumption. SARIF is the
**primary** target precisely because it satisfies the criterion for more
than one platform at once.

Each formatter is a pure function of an `Analysis::Result` — it reads
`path` / `line` / `column` / `severity` / `qualified_rule` / `message` and
adds nothing. Severity and identifier mapping is defined **once per format**
(WD2). This keeps the surface additive: `text` / `json` are untouched, and
a project that never sets `--format` sees no change.

## Working decisions

### WD1 — Six formats; SARIF is the anchor, the rest are reach

The format set is chosen by the criterion above plus *reach per unit cost*:

- **`github`** and **`gitlab`** ship alongside SARIF rather than deferring
  to SARIF-only because each is the *zero-friction* path for its platform.
  SARIF-on-GitHub needs the separate `upload-sarif` step and code-scanning
  enabled; the `github` format needs neither (one `run:` line). GitLab does
  not consume SARIF for its MR widget at all — Code Quality is its only
  native MR surface. So SARIF being cross-platform does not make these two
  redundant.
- *Default vs anchor.* SARIF is the cross-platform **anchor** (one report,
  many consumers — GitHub code scanning, reviewdog, other tools), but it is
  *not* the universal per-platform default. On GitHub specifically the
  **default surface is `github` (annotations)**: SARIF upload to code
  scanning requires GitHub Advanced Security / Code Security on **private**
  repos (it is free only on public repos), so a private repo without GHAS
  cannot use it — whereas `github` annotations work on every repo with no
  upload, no permissions, no paid feature. The `rigor-ci-setup` skill and
  the manual therefore lead GitHub users with `github` and present SARIF as
  the "code scanning available" upgrade. (PHPStan likewise leads GitHub
  Actions with its `github` format.)
- **`checkstyle`** and **`junit`** are cheap XML formats with *broad*
  reach. `checkstyle` is the key to **reviewdog**: `rigor check --format
  checkstyle | reviewdog -f=checkstyle` posts to any reviewdog reporter
  (GitHub PR *review* comments, GitLab MR discussion, Gerrit, Bitbucket,
  Gitea) — reporters Rigor would otherwise need bespoke formats for. (SARIF
  also feeds reviewdog via `-f=sarif`; `checkstyle` is the lighter, no-code-
  scanning bridge and the one Jenkins reads too.) `junit` covers the
  test-report consumers (GitHub test reporting, GitLab, CircleCI, Jenkins).
  Neither costs more than a small serializer, and together they let Rigor
  reach reviewdog's whole reporter matrix without writing reviewdog's
  native `rdjson` — which would only add code-suggestion payloads Rigor
  does not produce.
- **`teamcity`** (TeamCity inspection service messages) is the other
  stdout-native format, added so TeamCity is a genuine first-class platform
  for CI auto-detection (WD7) rather than a hollow tier — it is auto-emitted
  under a detected TeamCity build just as `github` is under GitHub Actions.

Comparator: PHPStan ships `github` / `gitlab` / `checkstyle` / `junit` /
`teamcity` and **no SARIF**; Rigor leads with SARIF (PHPStan's gap) and adds
the same broad-reach set (`checkstyle` / `junit` / `teamcity`).

### WD2 — Severity + identifier mapping (the contract table)

Each format maps Rigor's `:error` / `:warning` / `:info` and the qualified
rule id into its own vocabulary. The mappings, fixed here as contract:

| Rigor | SARIF `level` | GitHub command | GitLab `severity` | Checkstyle `severity` | JUnit `failure type` | TeamCity `SEVERITY` |
| --- | --- | --- | --- | --- | --- | --- |
| `:error` | `error` | `::error` | `major` | `error` | `error` | `ERROR` |
| `:warning` | `warning` | `::warning` | `minor` | `warning` | `warning` | `WARNING` |
| `:info` | `note` | `::notice` | `info` | `info` | `info` | `INFO` |

Identifier: the **qualified rule** (`<source_family>.<rule>`, or the bare
rule for the `:builtin` family — `Diagnostic#qualified_rule`) is the stable
id. It carries into SARIF `ruleId` (+ a deduped `tool.driver.rules`),
GitHub `title=`, GitLab `check_name`, Checkstyle `source` (the rule code
reviewdog surfaces), and JUnit `classname`. The ruleless producers (parse /
internal errors, `qualified_rule == nil`) degrade per format: SARIF omits
`ruleId` (valid), GitHub omits `title=`, GitLab uses `check_name: "rigor"`,
Checkstyle omits `source`, JUnit uses `classname="rigor"`. GitLab's
`critical` / `blocker` are left unused — a louder future tier, not mapped
today, because Rigor has no severity above `:error`.

### WD3 — GitLab fingerprint = hash of the locating tuple

GitLab dedups and tracks findings across runs by a `fingerprint` it
requires to be stable for an unchanged finding and unique per finding.
We hash (`SHA256`) the tuple `(path, qualified_rule, line, column,
message)`. This is stable (no run-volatile input — not the array index,
which would churn on reordering) and unique enough in practice. A genuine
collision (two findings identical on all five) drops one from the widget —
an acceptable, rare loss versus an unstable index-based id that would make
every finding look "new" on any reordering.

### WD4 — Exit code unchanged; file output via shell redirect

No `--format` value changes the exit code — it stays `0` on no errors, `1`
otherwise (and `1` on `--baseline-strict` drift), the same as `text` /
`json`. Reports are written to a file with an ordinary `>` redirect
(`rigor check --format sarif > rigor.sarif`); the upload step runs
`if: always()` so the non-zero exit still publishes the report. A dedicated
`--output FILE` flag is **deferred** (Rejected/deferred) — redirect covers
the need, and the flag is a pure ergonomic addable later without a contract
change. The `github` format prints nothing for a clean run (no empty
annotation line); the document formats always emit a document (JUnit a
single passing `testcase`, Checkstyle an empty `<checkstyle>`).

### WD5 — JUnit maps every diagnostic to a `failure` (surfacing, not gating)

The `junit` format emits one `<testcase>` per diagnostic, each carrying a
`<failure>` typed by severity — so warnings and info appear as JUnit
failures even though they do not fail the run. This follows the established
linter-to-JUnit convention (rubocop, eslint, PHPStan all do it): a JUnit
report of a linter is a *visibility* surface, and hiding the non-error
findings would defeat it. It does **not** conflict with the false-positive
discipline — the exit code (errors only) remains the gate, JUnit is opt-in
via `--format junit`, and the `type` attribute preserves the real severity
so a consumer can distinguish. (Contrast: PHPStan marks all as failures
without preserving severity; Rigor keeps the severity in `type`.)

### WD6 — The setup-template + skill half (ADR-27 § WD3)

This ADR also ships the copy-paste CI templates ADR-27 § WD3 designed and
left queued, now wired to the new formats — a `.github/workflows/rigor.yml`
(Rigor in its own isolated Ruby-4.0 job, `--format sarif` + `upload-sarif`,
with the `github` one-liner as the no-upload alternative), a `.gitlab-ci.yml`
(`--format gitlab` → a `codequality` report artifact), and a reviewdog
variant (`--format checkstyle | reviewdog -f=checkstyle` via
[`reviewdog/action-setup`](https://github.com/reviewdog/action-setup)) — plus
the bundled [`rigor-ci-setup`](../../skills/rigor-ci-setup/SKILL.md) skill
that walks a user through choosing a platform, format, and (optional)
reviewdog path. The templates, the skill, and the manual's CI chapter
([`docs/manual/11-ci.md`](../manual/11-ci.md)) are the onboarding face of
this ADR; the formats are its engine.

### WD7 — Runtime CI auto-detection (first-class native / second-class reviewdog)

Modelled on PHPStan's `CiDetectedErrorFormatter` (which uses
`OndraM/ci-detector`): `rigor check` detects the CI environment at runtime
from its env vars (`Rigor::CLI::CiDetector`) and, **on the default `text`
output only**, surfaces diagnostics the platform-native way without the user
choosing a `--format`. This is the "it just works in CI" default and the
formal home of the *first-class / second-class* split:

- **First-class, stdout-native** (GitHub Actions → `github`, TeamCity →
  `teamcity`): the native annotations are emitted **on top of** the human
  text (so the readable log *and* the inline surface both appear, exactly as
  PHPStan augments its `table`). These are the platforms whose native format
  renders purely from stdout.
- **First-class, artifact-based** (GitLab CI → `gitlab`): the Code Quality
  report needs a CI-wired artifact, not stdout, so auto-detection cannot
  emit it onto the log; instead a one-line stderr hint tells the user to run
  `--format gitlab` and publish the artifact.
- **Second-class** (CircleCI, Jenkins, Travis, Azure, Bitbucket, Buildkite,
  Drone, …): no native Rigor format, so a one-line stderr hint routes the
  user to **reviewdog** (`--format checkstyle | reviewdog`) or `--format
  junit`. The hint is the runtime expression of the second-class tier.

Guardrails: it augments **only** the default `text` output — an explicit
`--format` means the caller is in control and is left byte-for-byte
untouched (so machine consumers are never polluted). Hints fire only when
there are diagnostics (a clean run stays quiet). It is on by default but
fully suppressible with `--no-ci-detect` or `RIGOR_CI_DETECT=0` — the latter
is the seam Rigor's own `make check` / spec suite use so that running under
GitHub Actions does not change their output. The augmentation of `text`
under a detected CI is the one behavioural change here; it is additive
(annotations on top, never replacing the human lines), gated to CI, and
opt-out, so it does not regress the false-positive-discipline posture.

## Rejected / deferred alternatives

| Option | Disposition | Reason |
| --- | --- | --- |
| Fold into ADR-27 as a new WD | Rejected | ADR-27 is *distribution* (how Rigor is installed); this is *output* (how it reports into CI). Distinct public-contract surface → its own ADR keeps each decision legible. |
| SARIF only (defer GitHub/GitLab) | Rejected | SARIF leaves both zero-friction paths (GitHub annotations without upload; GitLab's only MR surface) on the table — WD1. |
| `--output FILE` flag | Deferred | `>` redirect covers file output; the flag is an additive ergonomic with no contract impact, addable on demand. |
| reviewdog native `rdjson` / `rdjsonl` | Deferred | reviewdog already consumes the shipped `sarif` *and* `checkstyle`, so its whole reporter matrix is reachable without it. `rdjson`'s extra payload is code suggestions + multiline ranges — Rigor produces neither today. Revisit if Rigor gains fix-its. |
| TeamCity service messages | Deferred | PHPStan ships `teamcity`; demand-gated for Rigor (no observed TeamCity user). |
| Rich SARIF rule metadata (`shortDescription`, `helpUri`) | Deferred | Id-only `tool.driver.rules` is valid SARIF and avoids coupling the formatter to the `CheckRule` registry; enrich when the GitHub Security-tab UX demands it. |
| Exit-code mode (e.g. always 0 in report mode) | Rejected | A consumer wanting the gate green uses `continue-on-error` / `if: always()`; baking it into the format would couple presentation to gating policy. |

## Consequences

### Positive

- Diagnostics surface **inline in the PR/MR** on the three dominant CI
  platforms — Rigor's CI value no longer stops at the job log + exit code.
- Additive and isolated: `text` / `json` unchanged, no `.rigor.yml` change,
  no analysis change. A project not using `--format` sees nothing new.
- SARIF is reusable beyond GitHub (any SARIF tool), so the cross-platform
  investment is not GitHub-specific.

### Negative

- Three more output shapes are now **public contract** (ADR-50 WD1) — the
  severity/identifier mappings (WD2) and the SARIF/GitLab JSON shapes must
  stay stable within a line. The contract table here is the pin.
- More to document and keep current as the platforms evolve their schemas
  (SARIF revisions, GitLab Code Quality field changes).

### Carry-over

- `--output FILE`, JUnit XML, and richer SARIF rule metadata are
  demand-gated follow-ups (Rejected/deferred).
- The enumerated-public-surface document (ADR-50 WD1, drafted at v0.2.0)
  should list these three `--format` values + their contract table.

## Relationship to other ADRs

- [ADR-27](27-tool-distribution-model.md) — distribution + the CI channel;
  WD5 here ships its § WD3 setup templates. This ADR is the output sibling.
- [ADR-50](50-release-engineering-and-stability-strategy.md) — WD1 makes a
  new output format public contract; the WD2 table is what gets frozen.
- [ADR-8](8-steep-inspired-improvements.md) — severity profiles, the source
  of the `:error` / `:warning` / `:info` levels these formats map from.
- [ADR-22](22-baseline-and-project-onboarding.md) — the baseline / strict
  gate that shapes the exit code these formats leave unchanged (WD4).
