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
| `--format=text\|json` | Output format. Default `text`. |
| `--explain` | Surface fail-soft fallback events as `info` diagnostics. |
| `--no-cache` | Skip the persistent cache for this run. |
| `--clear-cache` | Delete the cache directory before running. |
| `--cache-stats` | Print the on-disk cache inventory when finished. |
| `--[no-]stats` | Print a run summary (files, classes, memory, wall time) to stderr. Default on. |
| `--workers=N` | Dispatch analysis across `N` Ractor workers. Default `0` (sequential). |
| `--baseline=PATH` | Load a baseline file, overriding config. |
| `--no-baseline` | Ignore any configured baseline. |
| `--baseline-strict` | Fail the run on any baseline drift — a CI gate. |
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
expression it evaluates to, as a trailing `#=> dump_type:`
comment. See [Inspecting inferred types](05-inspecting-types.md).

```sh
rigor annotate [--no-color] [--config=PATH] FILE
```

`FILE` is required. Colour is auto-detected for a tty and
honours `NO_COLOR`; `--color` / `--no-color` override.
Exit `1` on a parse error or a missing file.

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

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success — no error-severity diagnostics. |
| `1` | Diagnostics found, or a per-command failure (parse error, missing file, new diagnostics on `diff`). |
| `64` | Usage error — unknown command, bad flag, malformed argument. |

`rigor triage` is the exception: it is advisory and always
exits `0`.
