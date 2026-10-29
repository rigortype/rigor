# ADR-126 — One CLI grammar, versioned JSON documents, and a gated command catalogue

Status: **Proposed, 2026-10-30.** Nothing implemented. The work is filed as
[#2503](https://github.com/rigortype/rigor/issues/2503) (versioned JSON documents, WD2),
[#2504](https://github.com/rigortype/rigor/issues/2504) (grammar convergence, WD1) and
[#2505](https://github.com/rigortype/rigor/issues/2505) (catalogue and gate, WD3), each held
`ready-for-human` until this ADR is Accepted. The one defect that needs no decision,
[#2502](https://github.com/rigortype/rigor/issues/2502) (`--format` validated after analysis or
never), is `ready-for-agent` and lands independently.

Grounding: Cloudflare's [`cf` CLI launch](https://blog.cloudflare.com/cloudflare-cf-cli-launch/)
(2026), which replaced Wrangler's hand-grown commands — `d1 info`, `hyperdrive get`,
`workflows describe` for one act — with commands generated from one schema, made JSON the default
output, and added a command search for agents; and a survey of `lib/rigor/cli/` against it (this
ADR's Context).

## Context

Rigor's 26 commands were added one at a time, each by the change that needed it, and they drifted
the way Wrangler's did:

- **One act, two grammars.** `rigor skill` and `rigor docs` browse bundled assets with a
  positional name and flags (`--list`, `--path`), the grammar
  [ADR-73](73-skill-driven-user-experience.md)'s 2026-06-21 amendment and
  [ADR-74](74-offline-doc-access-and-llms-txt.md) moved them to; `rigor plugin` does the same job
  with verbs (`list`, `path`, `print`, `root`).
- **One word, two things.** `rigor baseline` manages `.rigor-baseline.yml` (rule-ID buckets,
  [ADR-22](22-baseline-and-project-onboarding.md), the [`CONTEXT.md`](../../CONTEXT.md) meaning);
  `rigor diff` calls a saved `check --format=json` document `rigor.baseline.json`
  (`lib/rigor/cli/diff_command.rb` ~L24). They match differently and are not interchangeable.
- **Rules applied to some commands only.** `--format` is rejected at parse time by 11 commands,
  after the whole analysis by 4 (`check`, `coverage`, `type-of`, `type-scan`), and never by 2
  (`trace` and `unused` print text for any value but `json`).
- **JSON documents without a contract.** [ADR-61](61-agent-friendly-diagnostic-statistics.md)
  made structured JSON the surface agents aggregate on, but
  [ADR-50](50-release-engineering-and-stability-strategy.md) WD1's v1.0 table lists "CLI commands +
  flags" and is silent on the documents. Only `baseline dump` (`version`) and `lens` (`schema:
  lens/v0`, `revision`) carry a marker. Three documents have no stable top-level shape: `type-of` is
  an object for one position and `{ "results": [...] }` for several (`type_of_renderer.rb` ~L93),
  `explain` is an array for the index or a rule and an object for a sig-gen skip reason
  (`explain_command.rb` ~L64–L109), and `trace` is a bare array (`trace_command.rb` ~L84).
- **Four hand-kept descriptions** of the surface — `CLI#help`, each command's banner,
  `docs/manual/02-cli-reference.md`, the MCP `inputSchema`s. Command *names* are gated against
  `HANDLERS` (`spec/docs/manual_drift_spec.rb`, `spec/rigor/cli_spec.rb`); flags, formats and the MCP
  tools are not.

Why now: ADR-50 freezes commands and flags at v1.0.0. Until then a rename costs one deprecation
minor (WD7's pre-1.0 rehearsal); after, a major.

## Decision

Converge the grammar on two criteria, make each JSON document a versioned contract, and hold the
surface to both with a catalogue-backed gate rather than by generating commands.

**Criterion A — who owns the names decides the grammar.** A command that browses a namespace Rigor
ships (skills, doc pages, plugins), whose members grow with every release, takes the member name
positionally and its modes as flags, so a future member can never collide with a verb. A command
that acts on project state takes a verb subcommand (`baseline generate|…|prune`,
`effects update|check|diff|explain`); a project path that collides with a verb is written
`./update`. No new spelling is added for an existing act, `rigor help <command>` (WD3) excepted as
the conventional alias of `--help`; spellings an Accepted ADR keeps (`rigor describe`,
`skill describe`, `skill --describe` under ADR-73) stay.

**Criterion B — what a consumer branches on is a versioned field.** ADR-61's "message text is
presentation" rule, lifted from fields to documents: a JSON document's top-level shape must not
depend on input, and the document says which shape it is. Where a flag selects a different
document (`coverage` plain / `--protection` / `--mutation` / fused; `plugins --capabilities`), a
top-level `"mode"` string names it, and `schema_version` counts per mode.

### WD1 — Grammar changes ([#2504](https://github.com/rigortype/rigor/issues/2504))

- `rigor plugin` adopts the `skill`/`docs` grammar (Criterion A): `rigor plugin <name>`,
  `--path <name>`, `--list` (default), `--root`. The verbs are deprecated (WD4).
- `diff`'s input is "a saved `rigor check --format=json` result", never a baseline; the example file
  becomes `rigor-check.json`. No behaviour change.
- An unknown command, or an unknown `baseline` / `effects` verb, suggests the nearest name, which
  covers `plugin`/`plugins` without a rename.

### WD2 — JSON documents are contract ([#2503](https://github.com/rigortype/rigor/issues/2503))

ADR-50 WD1 gains a row: the key set of each `--format=json` document is contract at v1.0.0; adding a
key is allowed in a minor, removing or renaming one is major-only. Whitespace is not contract, so
`lens` and `annotate` keep their compact output. The documents Rigor defines gain a top-level
integer `schema_version` starting at `1`, with three exceptions:

- a document already versioned by its own spec keeps that marker and gains no second one — `lens`
  (`schema`/`revision`, outside the contract until `lens/v1` per
  [`docs/internal-spec/lens.md`](../internal-spec/lens.md)) and `baseline dump` (`version`);
- `check`'s external formats (`sarif`, `gitlab`, …) keep their own schemas;
- a reader of saved documents (`rigor diff`) accepts one without `schema_version` as version `1`.

The three documents without a stable top-level object — `type-of`, `explain`, `trace` — become
`{ "schema_version": 1, "<plural noun>": [...] }`. That is a shape change no stdout can preserve, so
it follows WD4's second path.

### WD3 — The catalogue and its gate ([#2505](https://github.com/rigortype/rigor/issues/2505))

`CLI::Catalogue` holds one entry per `HANDLERS` command plus `help` and `version`. Flags come from
each command's `OptionParser`, built without parsing; the commands that parse `argv` by hand
(`skill`, `docs`, `plugin`, `describe`) declare theirs, and `playground`, which delegates to the
optional `rigor-playground` gem, is listed without flags. `CLI#help` renders from it,
`rigor help --format=json` prints it, and `rigor help <command>` becomes `rigor <command> --help`.
The existing name gates (`manual_drift_spec.rb`, `cli_spec.rb`) switch to the catalogue; a new spec
adds the MCP tools and the grammar rules: every non-delegated command's `--help` exits 0 (today
`rigor describe --help` exits 64), and every command that accepts `json` rejects an unknown
`--format` with 64 before analysis.

### WD4 — Deprecation mechanics

- **A spelling** keeps working for one minor, prints one notice on stderr, and leaves stdout
  byte-identical so a pipeline that consumes it does not break; it is removed in the next minor with
  a `changelog.d/removed/` fragment.
- **A JSON shape** cannot keep its old stdout. The minor before the change ships a `deprecated`
  fragment and a stderr notice on every `--format=json` run of the affected command; the next minor
  switches with a `changed` fragment. An MCP tool result keeps stdout and drops stderr
  (`lib/rigor/mcp/server.rb` `tool_result`), so the MCP tools that wrap an affected command
  (`rigor_type_of`, `rigor_explain`) carry the notice as an extra `text` content block, the way
  they already carry `config_warnings`.

Both are ADR-50 WD7's pre-1.0 cadence; after v1.0.0 either needs a major.

## Rejected / deferred alternatives

| Alternative | Verdict | Reason |
| --- | --- | --- |
| JSON as the default output (`cf`) | Rejected | `check`'s readers are people and CI, and CI already picks a format ([ADR-51](51-ci-diagnostic-output-formats.md)). Agents have the MCP server ([ADR-33](33-mcp-server.md)) and `--format=json`. |
| Compact JSON when stdout is not a TTY | Rejected | `check --format=json > file` is committed for `rigor diff`; one-line JSON makes that file's history unreadable. |
| Natural-language command search (`cf cli search`) | Rejected | Built for 3,000 operations; 26 commands fit one listing. The catalogue serves the same need. |
| `check --format=jsonl` / reviewdog `rdjsonl` | Deferred | `check` prints after the run completes, so lines buy no streaming; `rdjsonl`'s edge over `checkstyle` is fix suggestions Rigor does not emit. Revisit when diagnostics carry fixes. |
| Generate commands from a declarative spec (`cf`'s Forge) | Rejected | A rewrite of 26 working commands. A gate over introspected parsers enforces the same consistency. |
| Deprecate one of the three `describe` spellings | Rejected | ADR-73's amendment keeps `skill describe` and `skill --describe` first-class at the maintainer's request; reversing it is a separate decision. |
| Rename `plugins` or `plugin` | Rejected | Both are widely documented and cross-reference each other; did-you-mean addresses the typo. |
| Merge `diff` into `baseline` | Rejected | Per-site versus per-rule identity; merging would change what either one matches. |
| A typed configuration format (`cloudflare.config.ts`) | Not needed | `rigor init` already writes a `yaml-language-server` schema reference into `.rigor.yml`. |

## Consequences

- Positive: one grammar per kind of command before the freeze; JSON consumers can detect shape changes; a new
  command that skips the grammar rules fails a spec instead of shipping.
- Negative: the `plugin` verbs warn for one minor, and the `type-of`, `explain` and `trace` JSON
  shapes break for every consumer, announced a minor ahead. Commands that parse by hand keep a
  declared flag list beside their parser, which the gate can check only for presence, not
  completeness.
- Order: #2502 first (no decision needed), then #2505 so its gate checks #2503 and #2504 as they land.

## Relationship to other ADRs

- [ADR-50](50-release-engineering-and-stability-strategy.md) — WD2 adds a WD1 table row; WD4
  applies WD7's pre-1.0 deprecation cadence.
- [ADR-61](61-agent-friendly-diagnostic-statistics.md) — Criterion B generalises its Criterion A.
- [ADR-22](22-baseline-and-project-onboarding.md) — owns the word "baseline", which WD1 stops `diff`
  borrowing.
- [ADR-73](73-skill-driven-user-experience.md), [ADR-74](74-offline-doc-access-and-llms-txt.md) —
  the flag grammar Criterion A generalises; ADR-73's `describe` spellings are left as they are.
- [ADR-113](113-rigor-lens.md) — `lens/v0` keeps its own versioning and stays outside the contract.
- [ADR-33](33-mcp-server.md) — the MCP tools the catalogue indexes.
