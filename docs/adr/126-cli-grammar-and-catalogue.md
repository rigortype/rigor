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

- **One act, several spellings.** `rigor skill` and `rigor docs` browse bundled assets with a
  positional name and flags (`--list`, `--path`); `rigor plugin` does the same job with verbs
  (`list`, `path`, `print`, `root`). The next-step probe is spelled `rigor describe`,
  `rigor skill describe` and `rigor skill --describe`.
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
  flags" and is silent on the documents. Only `baseline dump` and the `lens` document carry a
  version; `type-of` changes shape with the number of positions (`type_of_renderer.rb` ~L93).
- **Four hand-kept descriptions** of the surface — `CLI#help`, each command's banner,
  `docs/manual/02-cli-reference.md`, the MCP `inputSchema`s — with no check that they agree.

Why now: ADR-50 freezes commands and flags at v1.0.0. Until then a rename costs one deprecation
minor (WD7's pre-1.0 rehearsal); after, a major.

## Decision

Converge the grammar on two criteria, make each JSON document a versioned contract, and hold the
surface to both with a catalogue-backed gate rather than by generating commands.

**Criterion A — the argument decides the grammar.** A command whose argument names a member of an
open set (a skill, a doc page, a plugin) takes the name positionally and its modes as flags, so a
member can never be shadowed by a verb. A command that performs one of a closed set of actions on
project state (`baseline generate|regenerate|dump|drift|prune`, `effects update|check|diff|explain`)
takes a verb subcommand. One act gets one spelling; others are deprecated, not kept as peers.

**Criterion B — what a consumer branches on is a versioned field.** ADR-61's "message text is
presentation" rule, lifted from fields to documents: a JSON document's shape must not depend on
input size, and the document says which shape it is.

### WD1 — Grammar changes ([#2504](https://github.com/rigortype/rigor/issues/2504))

- `rigor plugin` adopts the `skill`/`docs` grammar (Criterion A): `rigor plugin <name>`,
  `--path <name>`, `--list` (default), `--root`. The verbs are deprecated.
- `rigor skill --describe` is deprecated; `rigor skill describe` (about 100 uses in the repository)
  stays canonical and `rigor describe` its top-level alias. `describe` is an action, not a member
  name, so the verb form is consistent with Criterion A.
- `diff`'s input is "a saved `rigor check --format=json` result", never a baseline; the example file
  becomes `rigor-check.json`. No behaviour change.
- An unknown command suggests the nearest name, which covers `plugin`/`plugins` without a rename.

### WD2 — JSON documents are contract ([#2503](https://github.com/rigortype/rigor/issues/2503))

ADR-50 WD1 gains a row: the key set of each `--format=json` document is contract at v1.0.0; adding a
key is allowed in a minor, removing or renaming one is major-only. Whitespace is not contract, so
`lens` and `annotate` keep their compact output. Each such document gains a top-level integer
`schema_version` starting at `1`; `check`'s external formats (`sarif`, `gitlab`, …) keep their own
schemas. `type-of` always emits `{ "schema_version": 1, "results": [...] }`.

### WD3 — The catalogue and its gate ([#2505](https://github.com/rigortype/rigor/issues/2505))

`CLI::Catalogue` holds one entry per `HANDLERS` command. Flags come from each command's
`OptionParser`, built without parsing; the six commands that parse `argv` by hand (`skill`,
`docs`, `plugin`, `lsp`, `mcp`, `upgrade`) declare theirs. `CLI#help` renders from it,
`rigor help --format=json` prints it, and `rigor help <command>` becomes `rigor <command> --help`.
A spec gates the catalogue against `HANDLERS`, the manual's headings and the MCP tools, and checks
every command against the grammar rules: `--help` exits 0, and an unknown `--format` exits 64
before analysis.

### WD4 — Deprecation mechanics

A deprecated spelling keeps working for one minor, prints one notice on stderr, and leaves stdout
byte-identical so a pipeline that consumes it does not break; it is removed in the next minor with
a `changelog.d/removed/` fragment. This is ADR-50 WD7's pre-1.0 cadence applied to CLI spellings.

## Rejected / deferred alternatives

| Alternative | Verdict | Reason |
| --- | --- | --- |
| JSON as the default output (`cf`) | Rejected | `check`'s readers are people and CI, and CI already picks a format ([ADR-51](51-ci-diagnostic-output-formats.md)). Agents have the MCP server ([ADR-33](33-mcp-server.md)) and `--format=json`. |
| Compact JSON when stdout is not a TTY | Rejected | `check --format=json > file` is committed for `rigor diff`; one-line JSON makes that file's history unreadable. |
| Natural-language command search (`cf cli search`) | Rejected | Built for 3,000 operations; 26 commands fit one listing. The catalogue serves the same need. |
| `check --format=jsonl` / reviewdog `rdjsonl` | Deferred | `check` prints after the run completes, so lines buy no streaming; `rdjsonl`'s edge over `checkstyle` is fix suggestions Rigor does not emit. Revisit when diagnostics carry fixes. |
| Generate commands from a declarative spec (`cf`'s Forge) | Rejected | A rewrite of 26 working commands. A gate over introspected parsers enforces the same consistency. |
| Rename `plugins` or `plugin` | Rejected | Both are widely documented and cross-reference each other; did-you-mean addresses the typo. |
| Merge `diff` into `baseline` | Rejected | Per-site versus per-rule identity; merging would change what either one matches. |
| A typed configuration format (`cloudflare.config.ts`) | Not needed | `rigor init` already writes a `yaml-language-server` schema reference into `.rigor.yml`. |

## Consequences

- Positive: one spelling per act before the freeze; JSON consumers can detect shape changes; a new
  command that skips the grammar rules fails a spec instead of shipping.
- Negative: three deprecation notices for one minor, and a breaking `type-of` JSON change for
  single-position callers, announced a minor ahead. Commands that parse by hand keep a declared flag
  list beside their parser, which the gate can check only for presence, not completeness.
- Order: #2502 first (no decision needed), then #2505 so its gate checks #2503 and #2504 as they land.

## Relationship to other ADRs

- [ADR-50](50-release-engineering-and-stability-strategy.md) — WD2 adds a WD1 table row; WD4
  applies WD7's pre-1.0 deprecation cadence.
- [ADR-61](61-agent-friendly-diagnostic-statistics.md) — Criterion B generalises its Criterion A.
- [ADR-22](22-baseline-and-project-onboarding.md) — owns the word "baseline", which WD1 stops `diff`
  borrowing.
- [ADR-33](33-mcp-server.md), [ADR-73](73-skill-driven-user-experience.md) — the MCP tools and
  `skill describe` the catalogue indexes.
