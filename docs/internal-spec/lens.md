# `rigor lens` output: `lens/v0`, revision 1

Status: **Draft, experimental.** This is the binding description of what `rigor lens` computes and emits.
[ADR-113](../adr/113-rigor-lens.md) records why; the shape was agreed with ZARD, the first consumer, in
[#1907](https://github.com/rigortype/rigor/issues/1907). `lens/v0` is not frozen: a breaking change bumps
`revision`, and the command and its flags are excluded from the compatibility contract until `lens/v1`
ships in a Rigor release ([`docs/compatibility.md`](../compatibility.md)). Type strings and which
diagnostics fire are never part of the contract (ADR-50 § Decision 3).

The keywords MUST, MUST NOT, SHOULD and MAY are used as in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).

## Computation

A lens is `rigor check` for its targets, rendered as a map.

- The session is the `--incremental` session, rooted at the configuration's `paths:` exactly as `check`
  roots it, so a lens and `rigor check --incremental` read and write the same snapshot.
- The targets are forced into the run's analysed set and analysed in the lens process. Their rows are
  computed inside the run, from the same seeded scope index the check rules read.
- A lens MUST report, for each target, the diagnostics `rigor check --no-cache` reports for that file
  (before the baseline filter).
- A lens cannot be answered from the run-result slot. A cold lens costs a full `check`; a warm lens costs
  the engine's warm recheck floor once per invocation, whatever the number of targets.

## Invocation

```text
rigor lens [--format text|json] [--config FILE] [--workers N] FILE...
```

- Every `FILE` is resolved against the working directory. Several targets in one invocation share one run.
- `--format json` writes exactly one JSON document to stdout, after all computation. Human-readable
  progress and errors go to stderr. The text format is for agents and people; its layout is not a
  contract, but the anchor token syntax inside it is (§ Anchors).
- Exit status:

  | Status | Meaning |
  | --- | --- |
  | 0 | At least one target has `status: "ok"`. Code diagnostics never change the exit status. |
  | 1 | No target produced a result (every target is `not_found`, `outside_project`, `not_ruby`, `parse_error` or `failed`). The JSON document is still written. |
  | 64 | Usage error (no target, unknown flag, bad config). No document is written. |
  | 70 | Internal error. No document is written. |

  Exit 2 is reserved for an ambiguous symbol query, which revision 1 does not have.

## Serialization conventions

- **Paths** are relative to the project root, with `/` separators. The project root is the directory of
  the configuration file in effect, or the working directory when there is none. No absolute path
  appears in the document.
- **Spans** are objects `{start_line, start_column, end_line, end_column, start_offset, end_offset}`.
  Lines are 1-based. Columns and offsets count **bytes** of the file as read, with no newline
  normalisation (a CRLF is two bytes), 0-based, end-exclusive. They are Prism's locations, so a
  consumer that parses with Prism gets the same numbers.
- **Digests** are spelled `xxh3-64:<16 lowercase hex>` and are taken over exact bytes.
- An **absent field** means the capability is not available in this revision, never "the answer is
  empty". A field that the revision supports but that has no value is `null` or `[]`.

## Document

```json
{
  "schema": "lens/v0",
  "revision": 1,
  "producer": { "name": "rigor", "version": "0.4.3", "engine_source": null },
  "context": { "...": "§ Context" },
  "capabilities": ["class", "module", "method", "attribute", "body_return", "diagnostics", "inputs"],
  "files": [ { "...": "§ Files" } ],
  "members": [ { "...": "§ Members" } ]
}
```

- `producer.engine_source` is the engine's source identity when Rigor runs from a checkout rather than
  an installed gem (`EngineSource.process_identity`), and `null` otherwise. Two runs whose `version`
  matches but whose `engine_source` differs used different engines.
- `capabilities` lists the row kinds and optional fields this revision emits. A consumer MUST NOT read
  a missing capability as an empty answer.

## Context

`context` documents the analysis inputs that apply to every target. It contains no absolute path.

| Field | Content |
| --- | --- |
| `config` | The configuration file, relative to the root, or `null`. |
| `target_ruby` | The configured `target_ruby`. |
| `signature_roots` | The project signature roots in effect, relative to the root. |
| `signature_digest` | A digest over every `.rbs` under those roots: each relative path and its file digest, sorted by path. |
| `plugins` | `[{id, version}]` for every loaded plugin, sorted by `id`. |
| `lockfiles` | `[{path, digest}]` for `Gemfile.lock` and `rbs_collection.lock.yaml` when present. Gem and stdlib RBS are identified through these and `producer`, not by installation path. |
| `digest` | A digest over the canonical JSON of the other `context` fields. |

## Files

One entry per requested target, in request order.

| Field | Content |
| --- | --- |
| `path` | The target, relative to the root. When the target is outside the root, its argument as given. |
| `status` | `ok`, `not_found`, `outside_project` (not under the configured `paths:`), `not_ruby`, `parse_error` or `failed`. |
| `reason` | A human-readable message for any status other than `ok`. |
| `digest` | The file digest, over the bytes the analysis read, prose included. |
| `complete` | `true` when every declaration in the file is a row; `false` when `omissions` is non-empty. |
| `omissions` | `[{kind, name, span, reason}]`. Each declaration the revision does not model; `reason` is `unsupported_kind`. |
| `sites` | § Sites. |
| `diagnostics` | `[{rule, severity, message, span}]`, the target's check diagnostics in `check`'s order. |
| `inputs` | `[{path, digest}]`, the other project Ruby files whose facts this target's analysis read, from the incremental session's dependency record, sorted by path. It is not a complete input list: signature, gem and plugin inputs are covered only by `context`. A consumer MUST NOT treat an unchanged `inputs` list as proof that the target's facts are unchanged. |

Only `path`, `status` and `reason` are present when `status` is not `ok`.

### Kinds in revision 1

- Rows: `class` and `module` bodies; `method` for `def name`, `def self.name`, and `def` inside
  `class << self`; and `attribute` for each name of an `attr_reader`, `attr_writer` or `attr_accessor`
  call written directly in a class or module body.
- Omissions, each with `reason: "unsupported_kind"`: constant assignments; `alias` and `alias_method`;
  `define_method`; `def` with any other explicit receiver; any `def` or `attr_*` inside a block
  (`class_eval`, `included do`, `Class.new do`); `Data.define` and `Struct.new` classes;
  `module_function` (one site, two members); `refine` blocks and everything inside them; and the
  members a plugin synthesizes.

A declaration is never attached to a neighbouring row as a fallback.

## Sites

A site is one source declaration in a requested file.

| Field | Content |
| --- | --- |
| `key` | `<path>:<start_offset>-<end_offset>:<ordinal>`. Unique within the document. Not stable across edits and not a public identity. |
| `kind` | `class`, `module`, `method` or `attribute`. |
| `name` | For `class` / `module`, the qualified name. Otherwise the member name. |
| `owner` | For `method` / `attribute`, the qualified name of the class or module the member is defined on. |
| `scope` | For `method` / `attribute`, `instance` or `singleton`. |
| `attribute` | For `attribute`, `reader`, `writer` or `accessor`. |
| `ordinal` | The 0-based index among sites that share one declaration span (`attr_reader :a, :b` gives 0 and 1); 0 otherwise. |
| `span` | The declaration's span (the `class` / `def` / `attr_*` node). |
| `contract_span` | The span from the first to the last contract comment line of the site (§ Anchors), or `null`. |
| `anchor` | § Anchors. |
| `visibility` | For `method` / `attribute`, `public`, `protected` or `private`, as `check` resolves it. |
| `contract` | `inline` when the site carries contract comment lines; otherwise `null`. A `sig/` contract belongs to the member, not to a site. |
| `body_return` | For a `method` with a body, a slot (§ Slots): the type the body returns with its parameters as declared, or as unknown where none is declared. It is a fact about this body alone. |

## Members

A member is one `(owner, scope, name)` that has at least one site in a requested file. Members are
sorted by owner, scope and name.

| Field | Content |
| --- | --- |
| `owner`, `scope`, `name` | As on the sites. |
| `kind` | `method` or `attribute`. |
| `sites` | The keys of this member's sites in the requested files. |
| `also_defined_at` | `[{path, line}]`, the project files outside the requested set that also define the member, from cross-file discovery, sorted by path. Lines come from the discovery record and MAY be `null` for a member defined only by `attr_*`. |
| `basis` | Where the member's signature comes from, as a whole. See below. |
| `overloads` | `[{rbs, params, block, return}]`, each a signature in `sig-gen`'s spelling with its slots. |

`basis` is one of:

- `contract`: a contract (`sig/`, inline, or library RBS) declares the member. Slots the contract
  declares carry its provenance. A slot the contract leaves to inference (an inline contract with the
  `inferred-return` annotation) is filled as for the other two bases.
- `single_site`: no contract, and the member has exactly one project site. Its `return` slot is that
  site's `body_return`, with `from_site` naming the site.
- `contested`: no contract, and the member has more than one project site. Rigor does not know which
  definition Ruby will run, so an inferred slot is `unavailable` with reason `contested`; each site's own
  `body_return` remains on the site.

The same rule applies to a contract member whose inferred slot has more than one project site: that slot
is `unavailable` with reason `contested`, while the contract-declared slots stay typed.

Each param is `{name, kind, type}`. `kind` is `required`, `optional`, `rest`, `keyreq`, `key`,
`keyrest` or `block`; `type` is a slot. A parameter with no contract is a `dynamic` slot with cause
`inferred_return_untyped`, ADR-75's cause for an undeclared parameter.

## Slots

Every type position is a tagged slot:

| `state` | Fields | Meaning |
| --- | --- | --- |
| `typed` | `type`, `provenance`, optional `path`, optional `from_site` | A type Rigor resolved. |
| `dynamic` | `type: "untyped"`, `provenance`, `cause` | The effective type is `untyped`. `cause` is an ADR-75 dynamic-origin cause (`explicit_untyped`, `inferred_return_untyped`, `external_gem_without_rbs`, `framework_dsl_boundary`, `analyzer_budget_cutoff`, `unsupported_syntax`), or `null` when none was recorded. |
| `unavailable` | `reason` | Rigor has no type to report: `contested`, `not_computed`, or `definition_build_failed`. Never spelled `untyped`. |

- `type` is spelled as `sig-gen` writes RBS: the erasure, elaborated and alias-folded. A refined type
  reads as its erasure. Authored `%a{rigor:v1:…}` annotations on the declaring RBS member pass through
  in the overload's `rbs`; inferred refinements are not emitted in revision 1.
- `provenance` is one of `sig` (with `path`), `inline`, `inferred`, `plugin:<id>` and `library`. It is
  read from the RBS member's buffer: `virtual:rbs-inline:…` is `inline`, any other `virtual:<id>:…` is
  `plugin:<id>`, a buffer under a project signature root is `sig`, and anything else is `library`. A
  buffer whose name was not preserved reads `library` only when it is outside the project roots;
  otherwise the slot is `unavailable` with `not_computed`. `extrbs` is reserved until `@extrbs` is read
  ([#1073](https://github.com/rigortype/rigor/issues/1073)).
- `from_site` is set on an `inferred` slot and names the site whose body produced it.

## Anchors

A site's `anchor` is `<line>:<hash>`, where `line` is the first line of the hashed material and `hash`
is the xxh3-64 of that material, truncated to its low 16 bits and written as 4 lowercase hex digits.
Sites that share a span share an anchor and are told apart by `ordinal`. The token syntax
`<decimal line>:<4 hex>` is stable in both renderings.

The hashed material is built from the file's bytes:

1. **Contract comment lines.** Walk up from the line above the declaration through the contiguous run of
   comment-only lines (a blank line or code ends the run). Keep a line when, after `#` and at most one
   space, it starts with `:`, `@rbs` or `@extrbs`. Also keep a line that continues a kept `@rbs` or
   `@extrbs` line: a comment line directly below it whose text after `#` is indented further than the
   tag. Any other comment line, including documentation prose, is not part of the material.
2. **Trailing contract.** When a comment starts on the declaration's last line after the declaration
   ends, and it starts with `#:`, keep it.
3. **Material** is each kept leading line's bytes from its first non-space byte to the end of the line
   (without the newline), each followed by `\n`; then the declaration's bytes `[start_offset,
   end_offset)`; then, when step 2 kept a comment, `\n` and that comment's bytes to the end of its line.

A prose edit therefore leaves a row's anchor unchanged while the file `digest` changes. An unchanged
anchor never licenses reusing stale offsets, line numbers or documentation: a consumer re-associates on
the current file whenever its digest moved.

## What revision 1 does not carry

Named-type references, inherited members, symbol queries, plugin-synthesized members, `@extrbs`,
effect labels, source bodies and callers. Each is a later capability and appears in `capabilities` when
it ships.
