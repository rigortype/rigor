# CLI command reference

Every Rigor command is a subcommand of the single `rigor`
executable:

```sh
rigor <command> [options] [arguments]
```

`rigor help` prints the command list; `rigor version` prints
the installed version. An unknown command, or a malformed
option, exits `64` — the conventional "usage error" code.

> **Commands**
> [check](#rigor-check) · [init](#rigor-init) ·
> [annotate](#rigor-annotate) · [type-of](#rigor-type-of) ·
> [trace](#rigor-trace) ·
> [type-scan](#rigor-type-scan) · [explain](#rigor-explain) ·
> [diff](#rigor-diff) · [sig-gen](#rigor-sig-gen) ·
> [lsp](#rigor-lsp) · [baseline](#rigor-baseline) ·
> [triage](#rigor-triage) · [coverage](#rigor-coverage) ·
> [mcp](#rigor-mcp) · [plugins](#rigor-plugins) ·
> [plugin](#rigor-plugin) · [playground](#rigor-playground) ·
> [skill](#rigor-skill) · [lsp vs mcp](#rigor-lsp-vs-rigor-mcp) ·
> [exit codes](#exit-codes)

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
| `--format=text\|json` | Output format. Default `text`. |
| `--explain` | Surface fail-soft fallback events as `info` diagnostics. |
| `--no-cache` | Skip the persistent cache for this run. |
| `--incremental` | Re-analyse only the files changed since the last run plus the files that depend on them, serving the rest from a cross-process disk snapshot (ADR-46). Diagnostics are identical to a full run; a config / gem / version change (or a file added or removed) transparently forces a full re-analysis. See [Caching](12-caching.md). |
| `--verify-incremental` | Acceptance gate: run the incremental analyzer against a full `--no-cache` run and assert the diagnostics are byte-identical, then exit (0 on match, 1 with the differing diagnostics on mismatch). Used in CI to guarantee `--incremental` never serves a stale result. |
| `--clear-cache` | Delete the cache directory before running. |
| `--cache-stats` | Print the on-disk cache inventory when finished. |
| `--[no-]stats` | Print a run summary (files, classes, memory, wall time) to stderr. Default on. |
| `--workers=N` | Dispatch analysis across `N` parallel worker processes (fork-based pool today; ADR-15). Default `0` (sequential). |
| `--baseline=PATH` | Load a baseline file, overriding config. |
| `--no-baseline` | Ignore any configured baseline. |
| `--baseline-strict` | Fail the run on any baseline drift — a CI gate. |
| `--treat-all-as-inline-rbs` | Force-load `rigor-rbs-inline` with `require_magic_comment: false`, so every analysed file is treated as inline-RBS without the `# rbs_inline: enabled` comment (ADR-32). |
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

Summarise a diagnostic stream — rule distribution, per-file
hotspots, and heuristic "why" hints — instead of dumping the
raw list. See [Baselines](06-baseline.md).

```sh
rigor triage [paths]
```

`--top=N` sets the hotspot count (default 10); `--hints-only`
and `--no-hints` select which sections print. `triage` is
advisory and always exits `0` — it never gates a build.

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

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success — no error-severity diagnostics. |
| `1` | Diagnostics found, or a per-command failure (parse error, missing file, new diagnostics on `diff`). |
| `64` | Usage error — unknown command, bad flag, malformed argument. |

`rigor triage` is the exception: it is advisory and always
exits `0`.
