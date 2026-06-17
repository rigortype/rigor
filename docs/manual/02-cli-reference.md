# CLI command reference

Every Rigor command is a subcommand of the single `rigor`
executable:

```sh
rigor <command> [options] [arguments]
```

`rigor help` prints the command list; `rigor version` prints
the installed version. An unknown command, or a malformed
option, exits `64` — the conventional "usage error" code.

## `rigor check`

Analyse Ruby source for type errors and report diagnostics.
This is the command you run day to day and in CI.

```sh
rigor check [paths...]
```

`paths` are files or directories; when omitted, Rigor checks
the `paths:` list from the configuration file.

| Option | Effect |
| --- | --- |
| `--config=PATH` | Use a specific config file instead of auto-discovery. |
| `--format=FORMAT` | Output format. Default `text`. Also `json` (structured stream), plus the CI-native renderings `sarif`, `github`, `gitlab`, `checkstyle`, `junit`, and `teamcity` — see [Running Rigor in CI](11-ci.md). |
| `--no-ci-detect` | Disable CI auto-detection — by default `text` output also emits the running CI's native annotations / hint (`RIGOR_CI_DETECT=0` does the same). See [Running Rigor in CI § auto-detection](11-ci.md). |
| `--explain` | Surface fail-soft fallback events as `info` diagnostics. |
| `--no-cache` | Skip the persistent cache for this run. |
| `--incremental` | Re-analyse only the files changed since the last run plus the files that depend on them, serving the rest from a cross-process disk snapshot (ADR-46). Diagnostics are identical to a full run; a config / gem / version change (or a file added or removed) transparently forces a full re-analysis. See [Caching](12-caching.md). |
| `--verify-incremental` | Acceptance gate: run the incremental analyzer against a full `--no-cache` run and assert the diagnostics are byte-identical, then exit (0 on match, 1 with the differing diagnostics on mismatch). Used in CI to guarantee `--incremental` never serves a stale result. |
| `--clear-cache` | Delete the cache directory before running. |
| `--cache-stats` | Print the on-disk cache inventory when finished. |
| `--[no-]stats` | Print a run summary (files, classes, memory, wall time) to stderr. Default on. |
| `--coverage` | Add a type-precision coverage block to the output (`coverage` object under `--format json`; a one-line summary in text mode). Off by default — it is a second precision pass over the analyzed files, the same scan [`rigor coverage`](#rigor-coverage) runs, so it is opt-in. |
| `--workers=N` | Dispatch analysis across `N` parallel worker processes (fork-based pool today; ADR-15). Default `0` (sequential). |
| `--baseline=PATH` | Load a baseline file, overriding config. |
| `--no-baseline` | Ignore any configured baseline. |
| `--baseline-strict` | Fail the run on any baseline drift — a CI gate. |
| `--treat-all-as-inline-rbs` | Force-load `rigor-rbs-inline` with `require_magic_comment: false`, so every analysed file is treated as inline-RBS without the `# rbs_inline: enabled` comment (ADR-32). |
| `--bleeding-edge[=ids]` | Adopt the bleeding-edge overlay for this run, overriding the configured [`bleeding_edge:`](03-configuration.md) selection (ADR-50 § WD2). Bare adopts every queued feature; `--bleeding-edge=a,b` adopts only the named feature ids. The overlay is empty in this release, so this is currently a no-op. Inspect it with [`rigor show-bleedingedge`](#rigor-show-bleedingedge). |
| `--no-bleeding-edge` | Ignore any configured `bleeding_edge:` selection for this run (adopt none). |
| `--tmp-file=PATH --instead-of=PATH` | Editor mode: analyse `PATH` using the buffer in `--tmp-file`. Both required together. |

Exit `0` when no error-severity diagnostics remain, `1` when
any are reported, `64` on a usage error.

## `rigor init`

Write a starter configuration file.

```sh
rigor init [--path=PATH] [--force]
```

Writes `.rigor.dist.yml` by default. `--path` chooses a
different target; `--force` overwrites an existing file.
Exit `1` if the file exists and `--force` was not given.

## `rigor annotate`

Reprint a file with every line tagged by the type of the
expression it evaluates to, as a trailing `#=>` comment. See
[Inspecting inferred types](05-inspecting-types.md).

```sh
rigor annotate [--[no-]color] [--[no-]bat] [--config=PATH] FILE
```

`FILE` is required. Colour is auto-detected for a tty and
honours `NO_COLOR`; `--color` / `--no-color` override. When
colour is on and [`bat`](https://github.com/sharkdp/bat) is on
`PATH`, highlighting goes through bat (`--no-bat` opts out;
`--bat` warns if bat is missing and falls back to the built-in
colorizer). Exit `1` on a parse error or a missing file.

## `rigor type-of`

Print the inferred type at one source position.

```sh
rigor type-of FILE:LINE:COL
rigor type-of FILE LINE COL
```

Accepts the position as a single `file:line:col` triple or as
three arguments. `--format=json` emits a machine-readable
form; `--trace` records fail-soft fallbacks. The editor-mode
`--tmp-file` / `--instead-of` pair is accepted as on `check`.

## `rigor trace`

Replay HOW the engine typed a file, step by step, as a
terminal animation — a teaching probe over the same inference
`rigor check` runs.

```sh
rigor trace [--delay=SECONDS] [--line=N] [--verbose] [--format=json] FILE
```

Each frame highlights the source range being evaluated next to
the scope's locals and describes one inference moment: a local
binding entering the scope (`bind`), branch types merging
(`union`), or a method call resolving — or fail-softening to
`Dynamic[top]` (`dispatch`). On a tty the replay steps on a key
press (`q` quits); `--delay` autoplays. `--verbose` adds every
expression enter/result frame, `--line=N` keeps only events on
one line, and `--format=json` dumps the raw event stream for
tooling or course material. See
[Inspecting inferred types](05-inspecting-types.md).

## `rigor type-scan`

Report `type_of` inference coverage across paths — a
diagnostic-of-the-diagnoser, useful when investigating why a
class infers poorly.

```sh
rigor type-scan PATH...
```

`--limit=N` caps the printed examples (default 10),
`--show-recognized` includes fully-covered classes, and
`--threshold=RATIO` makes the command exit non-zero when the
unrecognized-node ratio exceeds `RATIO`.

## `rigor explain`

Print the catalogue entry for a diagnostic rule, or list every
rule when called with no argument.

```sh
rigor explain [rule]
```

`rule` is a rule ID (`call.undefined-method`), a legacy alias,
or a family wildcard (`call`, `flow`, `def`, `assert`, `dump`).
`--format=json` is available. Exit `64` for an unknown rule.

## `rigor diff`

Compare the current diagnostics against a saved baseline JSON
and report only what is new.

```sh
rigor diff <baseline.json> [paths...]
```

`--current=PATH` compares against a saved diagnostics JSON
instead of running a fresh check. Exit `1` when new
diagnostics appear.

## `rigor sig-gen`

Emit RBS signatures inferred from your Ruby source. See
[handbook chapter 11](../handbook/11-sig-gen.md) for the
classification model and the `--params` policy.

```sh
rigor sig-gen [paths]
```

| Option | Effect |
| --- | --- |
| `--print` | Write RBS to stdout. Default. |
| `--diff` | Write a unified diff against existing RBS. |
| `--write` | Write RBS to `sig/<path>.rbs` files. |
| `--overwrite` | Allow tighter-return updates to replace user-authored RBS. |
| `--include-private` | Emit private and protected methods too. |
| `--params=untyped\|observed\|observed-strict` | Parameter-typing policy. Default `untyped`. |
| `--observe=PATH` | Scan `PATH` for call-site observations. Repeatable. |
| `--new-files` / `--new-methods` / `--tighter-returns` | Emit only that classification. |
| `--format=text\|json` | Output format. |

## `rigor lsp`

Run the Language Server over stdio. See
[Editor integration](09-editor-integration.md).

```sh
rigor lsp [--transport=stdio] [--log=PATH] [--config=PATH]
```

`stdio` is the only transport in v1. `--log=PATH` writes the
wire log to a file instead of stderr.

## `rigor baseline`

Manage diagnostic baselines. See [Baselines](06-baseline.md)
for the file format and workflow.

```sh
rigor baseline <generate|regenerate|dump|drift|prune> [options]
```

| Subcommand | Purpose |
| --- | --- |
| `generate` | Write a fresh baseline from the current diagnostics. Refuses to overwrite without `--force`. |
| `regenerate` | Rewrite the baseline unconditionally — use after a quality pass. |
| `dump` | Print the baseline contents, filterable by `--rule` and `--file`. |
| `drift` | Audit how each bucket has drifted; filter with `--only=within\|over\|cleared\|reducible`. |
| `prune` | Drop buckets that no longer match any diagnostic. `--dry-run` previews. |

`generate` and `regenerate` accept `--output=PATH` and
`--match-mode=rule|message`.

## `rigor triage`

Summarise a diagnostic stream — rule distribution, **class/method
selectors**, per-file hotspots, and heuristic "why" hints — instead
of dumping the raw list. See [Baselines](06-baseline.md).

```sh
rigor triage [paths]
```

`--top=N` sets the hotspot count (default 10); `--hints-only`,
`--selectors-only`, and `--no-hints` select which sections print.
`triage` is advisory and always exits `0` — it never gates a build.

The **`selectors`** section is the by-(class, method) axis: it
aggregates the structured `receiver_type` / `method_name` fields the
diagnostics carry into `{receiver, method, count, files, rules}`
rows, so you can ask "which method concentrates the diagnostics?"
without parsing message text. Under `--format json` the full list is
emitted, keyed on a normalised receiver class (literals fold to their
class), ready for a `jq` query:

```sh
# methods with diagnostics spread across ≥ 3 files (systemic clusters)
rigor triage --format json | jq '.selectors[] | select(.files >= 3)'
# everything Rigor flagged on String receivers, by method
rigor triage --format json | jq '[.selectors[] | select(.receiver == "String")]'
```

The same `receiver_type` / `method_name` fields ride on each
diagnostic of `rigor check --format json`, for per-site (rather than
aggregated) grouping.

## `rigor coverage`

Report type-precision coverage — the ratio of call sites that
resolve to a precise type versus those that fall back to
`Dynamic`. A quality gate for "how much is Rigor actually
inferring".

```sh
rigor coverage [paths]
```

`--format=text|json` selects the output format and
`--config=PATH` overrides config discovery. `--threshold=RATIO`
exits `1` when the precision ratio falls below `RATIO`
(`0.0`–`1.0`), making it a CI gate.

`--protection` switches to **type-protection coverage**: instead
of "how precise are my types", it reports "if I introduce a bug,
would Rigor catch it". Each dispatch site (a call with an
explicit receiver) is *protected* when the receiver types to a
concrete class — a site where Rigor's call rules can catch a
wrong method or argument — and *unprotected* when the receiver is
`Dynamic`. The report leads with the protected ratio, then a
ranked "add a type here" list (the methods most often called on
an untyped receiver), then the least-protected files;
`--threshold` and `--format=json` work the same. It is a sound
upper bound on real protection — a concrete receiver is necessary
but not sufficient for a diagnostic to fire.

Adding `--mutation` (with `--protection`) switches to the
**effectiveness** tier: instead of "could Rigor catch a bug
here", it measures whether Rigor *actually does*. It introduces
type-visible breakages at each dispatch site — dropping a
call-argument to `nil`, swapping its type, renaming a call to a
missing method — re-analyses the mutated source against a clean
baseline, and reports the kill rate (caught breakages). It
defaults to the git-changed `.rb` files (whole-project is
minutes; pass explicit paths to widen), and leads with the
effectiveness ratio, then the breakages Rigor missed ("add a type
here"), then the least-effective files. `--threshold` gates on
the effectiveness ratio and `--format=json` carries `mode`,
`killed`, `survived`, `effectiveness_ratio`, per-file rows, and
`add_a_type_here`. It is the truth tier behind the static
`--protection` proxy, at the cost of many analyses — an opt-in CI
deep-dive, not an interactive check.

```sh
rigor coverage --protection --mutation [paths]
```

Adding `--with-tests` (with `--protection --mutation`) turns
that into the **fused static∪dynamic** view: for each breakage
the type checker does *not* catch, it runs your test suite to see
whether a **test** catches it. Each site is then classified
`type-protected` (the type checker caught it), `test-protected`
(a test caught what the type checker missed), or `unprotected`
(neither — the actionable "add a type **or** a test here" list),
and the report names the cheaper missing axis. A type-killed
mutant never reaches the suite (a gradual short-circuit), so the
cost is proportional to the protection hole. `--format=json`
carries `mode` (`protection-fused`), `type_killed`,
`test_killed`, `unprotected`, `protected_ratio`, per-file rows,
and `add_protection_here`; `--threshold` gates on the fused
ratio.

`--test-command=CMD` is the runner hook (default
`bundle exec rake`). The suite must pass on clean code first, or
the run aborts — point it at a plain pass/fail runner (a coverage
floor that exits non-zero on a passing suite trips this). It runs
with Bundler's environment stripped, so a `bundle exec` command
resolves your project's bundle even when Rigor itself was
launched under its own — no env wrapper needed. The command runs
**without a shell** (it is split into an argv and executed
directly), so shell constructs are not interpreted — including an
inline `BUNDLE_GEMFILE=… ` prefix. For a non-default Gemfile, set
it with `bundle config set --local gemfile PATH` (it persists in
`.bundle/config`) or wrap the command in `bash -c '…'`.

`--include-dynamic` extends the overlay to `Dynamic`-receiver
(untyped) sites, where a test is the only possible protection —
completing the map to *every* dispatch site rather than only the
ones Rigor can type-check. Every such site is a type-survivor, so
it runs the suite far more; it is an explicit opt-in.

`--limit=N` (with `--seed=N`, default `1`) caps the measurement
to a deterministic sample of `N` mutations per file, bounding the
cost on large files. Per-file ratios then become estimates, noted
on stderr so `--format=json` stdout stays clean.

```sh
rigor coverage --protection --mutation --with-tests \
  --test-command "bundle exec rspec" --include-dynamic [paths]
```

## `rigor mcp`

Run the Rigor MCP (Model Context Protocol) server over stdio,
so AI coding assistants can call Rigor tools directly. See
[MCP server](10-mcp-server.md).

```sh
rigor mcp [--transport=stdio] [--config=PATH]
```

`stdio` is the only transport. The server is a pure-Ruby
JSON-RPC 2.0 implementation exposing seven read-only tools:
`rigor_check`, `rigor_type_of`, `rigor_triage`,
`rigor_annotate`, `rigor_sig_gen`, `rigor_explain`,
`rigor_coverage`.

## `rigor lsp` vs `rigor mcp`

`lsp` speaks the Language Server Protocol to editors; `mcp`
speaks the Model Context Protocol to AI assistants. Both run
over stdio and wrap the same analysis engine.

## `rigor plugins`

Report the activation status of every plugin configured in
`.rigor.yml` — loaded, load-error (with reason), and each
plugin's declared extension surfaces. See [Plugins](07-plugins.md).

```sh
rigor plugins [--format=text|json] [--strict] [--capabilities] [--config=PATH]
```

Without `--strict` the command always exits `0`; with
`--strict` it exits `1` when any plugin failed to load (a CI
gate).

`--capabilities` switches to the **extension-protocol
catalogue** ([ADR-37](../adr/37-plugin-interface-segregation.md)):
a focused, machine-readable map of what each loaded plugin
contributes — the AST node types its `node_rule`s match, the
receiver classes its `dynamic_return`s gate on, the methods its
`type_specifier`s narrow, and the facts it `produces` /
`consumes`. Combine with `--format=json` for tooling (an AI
agent can enumerate every plugin's behaviour without reading a
line of plugin source). The same narrow surfaces also appear in
the default full report. Not to be confused with the singular
`rigor plugin`.

## `rigor plugin`

Browse the on-disk source of the plugins bundled in the
toolchain, so you can read a real, working plugin as a worked
example when authoring your own.

```sh
rigor plugin <list|path|print|root> [name]
```

| Subcommand | Purpose |
| --- | --- |
| `list` | Table of every bundled plugin and example, name + absolute directory path (default when no subcommand given). |
| `path <name>` | One-line absolute path to the plugin's directory. |
| `print <name>` | A header (dir / lib / sig / README paths) followed by the plugin's main source body inlined. |
| `root` | The `rigortype` gem root and its key subdirectories. |

Paths resolve at runtime from the gem location (a documented
caveat for container / cross-filesystem setups).

## `rigor playground`

Start the browser playground (a CodeMirror editor with
real-time diagnostics). Requires the separate `rigor-playground`
gem; if it is not installed the command prints an install hint
and exits `64`.

```sh
rigor playground
```

## `rigor skill`

List or print the bundled Agent Skills shipped inside the
`rigortype` gem, so an AI coding agent installed alongside
Rigor can discover and follow them without a project-side
source checkout. See [Skills](08-skills.md).

```sh
rigor skill <list|print|path> [name]
```

| Subcommand | Purpose |
| --- | --- |
| `list` | Table of every bundled skill (name + absolute path); the default when no subcommand is given. |
| `print <name>` | Print the `SKILL.md` body to stdout, with a header pointing at the skill's `references/` directory. |
| `path <name>` | Print the single-line absolute `SKILL.md` path, suitable as input to a file-reading tool. |

## `rigor show-bleedingedge`

Print the **bleeding-edge overlay** — the Rigor-maintained set of
the next major's queued diagnostic disciplines ([ADR-50](../adr/50-release-engineering-and-stability-strategy.md)
§ WD2) — and report which of them the project's
[`bleeding_edge:`](03-configuration.md) configuration adopts. Read-only:
it loads `.rigor.yml` to resolve the active selection but runs no
analysis.

```sh
rigor show-bleedingedge [--config PATH] [--format text|json]
```

| Flag | Purpose |
| --- | --- |
| `--config PATH` | Use this `.rigor.yml` instead of auto-discovery. |
| `--format text\|json` | Output format. Default `text`. |

The overlay is **empty in this release** — the mechanism is wired and
ready, but no discipline has been queued for a major yet, so the command
currently reports an empty set. When a feature is queued it appears here
with its stable id, the severity it would impose, and whether your config
adopts it. See [`docs/compatibility.md`](../compatibility.md) for how
bleeding-edge fits the stability model.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success — no error-severity diagnostics. |
| `1` | Diagnostics found, or a per-command failure (parse error, missing file, new diagnostics on `diff`). |
| `64` | Usage error — unknown command, bad flag, malformed argument. |

`rigor triage` is the exception: it is advisory and always
exits `0`.
