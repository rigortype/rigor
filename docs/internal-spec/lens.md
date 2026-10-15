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
  (before the baseline filter). Declaration facts (sites, members, contracts) MUST agree with what `check`
  uses. An inferred type is narrower than `check`'s: § Sites defines it.
- A lens cannot be answered from the run-result slot. A cold lens costs a full `check`; a warm lens costs
  the engine's warm recheck floor once per invocation, whatever the number of targets.

## Invocation

```text
rigor lens [--format text|json] [--config FILE] [--workers N] FILE...
```

- Every `FILE` is resolved against the working directory. Several targets in one invocation share one run.
  A file requested more than once, in any spelling, has one `files` entry per argument; the first carries
  the answer and the later ones read `duplicate`, so every site key is unique in the document.
- `--format json` writes exactly one JSON document to stdout, after all computation. Human-readable
  progress and errors go to stderr. The text format is for agents and people; its layout is not a
  contract, but the anchor token syntax inside it is (§ Anchors).
- Exit status:

  | Status | Meaning |
  | --- | --- |
  | 0 | At least one target has `status: "ok"`. Code diagnostics never change the exit status. |
  | 1 | No target has `status: "ok"`. The JSON document is still written. |
  | 64 | Usage error (no target, unknown flag, unreadable configuration). No document is written. |
  | 70 | The run itself crashed (`CLI::FATAL_ERRORS`). No document is written. A failure confined to one target is that target's `failed` status, not exit 70. |

  Exit 2 is reserved for an ambiguous symbol query, which revision 1 does not have.

## Serialization conventions

- **Root.** The project root is the working directory. Rigor auto-detects `sig/`, `Gemfile.lock` and
  `rbs_collection.lock.yaml` there, and a configured path resolves to an absolute one first, so every
  input has one spelling relative to it.
- **Paths** are relative to the root, with `/` separators. They, the site keys and `context.digest`
  therefore depend on the working directory: a consumer MUST NOT reuse a document produced from another
  one. A path outside the root is written relative
  to it with `..` segments. No absolute path that Rigor computed appears in the document; a target's
  `argument` echoes what the caller passed.
- **Spans** are objects `{start_line, start_column, end_line, end_column, start_offset, end_offset}`.
  Lines are 1-based. Columns and offsets count **bytes** of the file as read, with no newline
  normalisation (a CRLF is two bytes), 0-based, end-exclusive. They are Prism's locations.
- **Digests** are spelled `xxh3-64:<16 lowercase hex>` and are taken over exact bytes. `context.digest` is
  opaque: compare it for equality only.
- **Field presence.** Every field a section lists is present on every object of that kind, with `null`
  or `[]` when it has no value; a section names the fields that apply only to some kinds or statuses, and
  those are `null` elsewhere. A field that a later revision adds is absent here, and an absent field
  means the capability is unavailable, never an empty answer.

## Document

```json
{
  "schema": "lens/v0",
  "revision": 1,
  "producer": { "name": "rigor", "version": "0.4.3", "engine_source": null },
  "context": { "...": "§ Context" },
  "capabilities": ["class", "module", "method", "attribute", "module_function", "body_return", "diagnostics", "inputs"],
  "files": [ { "...": "§ Files" } ],
  "members": [ { "...": "§ Members" } ]
}
```

- `producer.engine_source` is the engine's source identity when Rigor runs from a checkout rather than
  an installed gem (`EngineSource.process_identity`). It is `null` for an installed gem, and `"unknown"` when
  the identity cannot be computed. Two runs whose `version` matches but whose `engine_source` differs, or is
  `"unknown"`, may have used different engines.
- `capabilities` lists the row kinds and optional fields this revision emits. A consumer MUST NOT read
  a missing capability as an empty answer.

## Context

`context` documents the analysis inputs that apply to every target.

| Field | Content |
| --- | --- |
| `config` | The configuration file, relative to the root, or `null`. |
| `target_ruby` | The Ruby version the run parsed as: the configured `target_ruby`, or the default the configuration resolved. |
| `rbs_version` | The loaded `rbs` gem's version. Core and stdlib signatures come from it. |
| `signature_roots` | The project signature roots in effect, relative to the root. |
| `signature_digest` | A digest over every `.rbs` under those roots: each relative path and its file digest, sorted by path. |
| `plugins` | `[{id, version}]` for every plugin the run loaded, by manifest id (the id `plugin:<id>` provenance uses), sorted by `id`. A plugin bundled with Rigor reports Rigor's version; any other reports the version of the gem whose files define it, or `null`. A plugin id is not a gem name. `[]` when no target was read. |
| `lockfiles` | `[{path, digest}]` for the Bundler lockfile and the `rbs collection` lockfile the run resolved, at their configured or auto-detected paths, when present. Gem RBS is identified through these. |
| `digest` | A digest over the other `context` fields. |

## Files

One entry per requested target, in request order.

| Field | Content |
| --- | --- |
| `argument` | The target as the caller passed it. |
| `path` | The target relative to the root, or `null` when it does not resolve to a file. |
| `status` | `ok`, `not_found` (no such file, or not a regular file), `not_ruby` (not a `.rb` file; view templates included), `outside_project` (not in the run's analysed set: outside `paths:`, or matched by `exclude:`), `duplicate` (the same file as an earlier argument, which `reason` names), `parse_error`, or `failed`. |
| `reason` | A human-readable message, or `null` for `ok`. For `failed` it names the error that stopped Rigor reading the file; that error never changes `check`'s answer or the snapshot. |
| `digest` | The file digest over every byte the analysis read, prose included. `null` unless `ok` or `parse_error`. |
| `complete` | `true` when every declaration in the file is a site; `false` when `omissions` is non-empty. `null` unless `ok`. |
| `omissions` | § Omissions. `null` unless `ok`. |
| `sites` | § Sites, in file order. `null` unless `ok`. |
| `diagnostics` | `[{rule, severity, message, line, column}]` as `rigor check --format json` reports them for this file (`line` 1-based, `column` 1-based, in `check`'s order). Present for `ok` and `parse_error`, `null` otherwise. |
| `inputs` | `[{path, digest}]`, the other project Ruby files whose facts this target's analysis read, from the incremental session's dependency record, sorted by path. `null` unless `ok`. It is not a complete input list: signatures, gems and plugins are covered only by `context`. A consumer MUST NOT treat an unchanged `inputs` list as proof that the target's facts are unchanged. |

### Kinds in revision 1

- Sites: `class` and `module` bodies; `method` for `def name`, `def self.name`, a `def` inside
  `class << self`, and a top-level `def` (owner `Object`, scope `instance`, visibility `private`); and
  `attribute` for each name of an `attr_reader`, `attr_writer` or `attr_accessor` call written directly in a
  class or module body.
  - "Directly" includes a visibility call wrapping it (`private def x`, `private attr_reader :x`), and
    the body of a class whose superclass expression is `Struct.new(…)` or `Data.define(…)`.
  - A `def` or `attr_*` inside a block, or inside `class << obj` for anything but `self`, is an omission.
  - A module function is a `method` site with `module_function: true` (capability `module_function`): a `def`
    written directly in a module body after a bare `module_function` there. That is the form Ruby and `check`'s
    singleton table read the same way.
- Omissions: constant assignments (`constant`); `Data.define` / `Struct.new` assigned to a constant
  (`data_class`, `struct_class`), with any member declared in their block; `alias` and `alias_method`
  (`alias`); `define_method`; a `def` with any receiver but `self`; any declaration inside a block;
  `class << obj`; the `module_function` cases Rigor cannot read the way both Ruby and `check` do
  (`module_function`): a `def` after a bare `module_function` once a bare `private` / `public` /
  `protected` follows it (Ruby ends the mode there, `check`'s tables do not), a `def` nested in the body
  (under an `if`, say) while the mode is on, every later `def` of a body whose bare `module_function` sits
  in control flow, a `def` wrapped in a visibility call while the mode is on, every `def` after a second bare
  `module_function` that follows such a toggle, any `module_function` in a class, and every named form
  (`module_function :x`, `module_function %i[x]`, `module_function def x`, a non-literal argument), whose
  reading differs between Ruby and `check` (a `def` nested in the body, a reopened module, a redefinition after
  the call). The instance members a named form names read `visibility: null`, and the omission counts as a
  project definition, so each such member is `contested`; `refine` blocks with everything inside them; and
  the members a plugin synthesizes, which revision 1 does not list at all (`capabilities` has no `plugin`).

A declaration is never attached to a neighbouring site as a fallback.

### Omissions

`[{kind, owner, scope, name, span, reason}]`. An omission with `owner` and `scope` set and `name` null may
define any member of that owner and scope (`module_function(*NAMES)`); it counts as a project definition of
each of them. `kind` is one of `class`, `module`, `method`, `attribute`
(each when written inside a block, and `method` also for a receiver other than `self`), `singleton_class`
(`class << obj`), `constant`, `data_class`, `struct_class`, `alias`, `define_method`, `module_function` and
`refine`. `owner` and `scope` are the member the declaration would
define when Rigor can tell (`alias_method :b, :a` in `class Foo` defines `Foo` / `instance` / `b`), and
`null` otherwise. `reason` is `unsupported_kind`.

## Sites

A site is one source declaration in a requested file.

| Field | Content |
| --- | --- |
| `key` | `<path>:<start_offset>-<end_offset>:<ordinal>`. Unique within the document. Not stable across edits and not a public identity. |
| `kind` | `class`, `module`, `method` or `attribute`. |
| `name` | For `class` / `module`, the qualified name. For `method`, the method name. For `attribute`, the attribute name as written (`name`, not `name=`). |
| `owner` | The qualified name of the class or module a `method` / `attribute` is defined on. `null` for `class` / `module`. |
| `scope` | `instance` or `singleton` for `method` / `attribute`; `null` otherwise. |
| `attribute` | `reader`, `writer` or `accessor` for `attribute`; `null` otherwise. |
| `members` | For `method` / `attribute`, the names of the members this site defines: one for a method, `name` and/or `name=` for an attribute. `[]` otherwise. |
| `module_function` | `true` for a module function: the `def` defines a private instance method and a singleton copy, so its name is a member under both scopes and both list this site. `scope` is then `instance` and `visibility` `private`. `false` otherwise. |
| `ordinal` | The 0-based index among sites that share one declaration span (`attr_reader :a, :b` gives 0 and 1); 0 otherwise. |
| `span` | The declaration's span (the `class` / `module` / `def` / `attr_*` node). |
| `contract_span` | The span from the first to the last contract comment of the site (§ Anchors, steps 1 and 2), or `null`. |
| `anchor` | § Anchors. |
| `visibility` | For `method` / `attribute`: `public`, `protected` or `private` as Ruby gives it from this file's own visibility calls: a wrapping `private def x` / `private attr_reader :x`, else the body's running default set by a bare `private` / `protected` / `public` written directly in the body, revised by a later `private :x` / `private %i[x y]` / `private_class_method :x` written directly in the body. A class body's default does not reach a `def self.x`, and a top-level `def` is `private`. `null` when Rigor cannot tell: a bare toggle under an `if`, a `begin` or a block leaves the default unknown; a named call written anywhere but directly in the body (an `if`, a block, a method body) leaves the members it names unknown; a non-literal argument (`private *NAMES`) leaves the body's members unknown; `private def self.x`, which Ruby rejects, is unknown; and so is an attribute site whose members a named call covers only in part. `null` for `class` / `module`. |
| `contract` | `inline` when the site carries a contract comment other than `@extrbs` and a member it defines has an inline declaration from this site's file that is not a defaulted one (`inferred-signature`, § Members); otherwise `null`. When one file holds several such sites for a member, each reads `inline`: the cached environment keeps the file, not the position. A `sig/` or library contract belongs to the member, not to a site. |
| `params`, `block` | For `method`: this definition's own parameter list as written, in the shape of an overload's `params` and `block` (§ Members) but with every `type` `null`: the shape only. Types are on the member's overloads; the cached environment keeps which file an inline contract came from, not which definition. `null` for every other kind. |
| `body_return` | For `method`: a slot (§ Slots), the type this body returns with its parameters as declared, or unknown where none is declared. Its calls resolve against the same seeded index `check` uses, so a call to another member reads that member as `check` reads it. A body-less `def` returns `nil`; `initialize` reads `void`. `null` for every other kind. |

## Members

A member is one `(owner, scope, name)` that a site in a requested file defines. An `attr_accessor :a`
site defines the members `a` and `a=`, and both list it. A module-function site defines `(owner, instance,
name)` and `(owner, singleton, name)`. The singleton member's `visibility` is `public`, revised by a later
`private_class_method :name` or a `private :name` inside `class << self`, written directly in the body, and
`null` under the rules § Sites gives for named calls written anywhere else. Its inferred return is the site's
`body_return`, except where that return may depend on `self`, which the singleton copy runs with as the module:
when the body reads `self`, `super`, an instance variable or a class variable, or the return's type names the
owner (a `self` that flowed through `itself`, `tap` or another module function), the singleton return is
`unavailable` with `not_computed`. Members are sorted by owner, scope and name.

| Field | Content |
| --- | --- |
| `owner`, `scope`, `name` | `name` is the Ruby method name (`a=` for a writer). |
| `kind` | `method` or `attribute`. |
| `visibility` | The common `visibility` of its sites, or `null` when they differ or any is `null`. |
| `sites` | The keys of the sites in the requested files that define it. |
| `also_defined_at` | `[{path, line}]`: every other definition the engine's cross-file discovery records for the member, in project files outside the requested set, of any kind (`def`, `attr_*`, `alias`, `define_method`, …), sorted by path. `line` is the line discovery recorded, or `null` when it recorded none (`attr_*`, `define_method`). For an alias, discovery records the aliased `def`, so the line points there, not at the `alias`. |
| `basis` | Where the member's signature comes from, as a whole. See below. |
| `overloads` | `[{rbs, params, block, return}]`. See below. |

The member's **project definitions** are its sites, the omissions in the requested files that name the same
`(owner, scope, name)`, and its `also_defined_at` entries. For owner `Object` and scope `instance` they
include top-level `def`s, which discovery records apart from `class Object`. `basis` is one of:

- `contract`: a declaration written for the member's own class (in `sig/`, inline, a plugin's signatures,
  or a library) declares it, and it is not a defaulted inline declaration (below). Slots the contract
  declares carry its provenance.
- `single_site`: no contract, and exactly one project definition, which is a site. Its inferred slots come
  from that site.
- `contested`: no contract, and more than one project definition. Rigor does not know which definition Ruby
  runs, so every inferred slot is `unavailable` with reason `contested`, and each site keeps its own
  `body_return`.

**Defaulted inline declarations.** Wherever the rbs-inline plugin reads a file (`rbs_inline: enabled`, or
the annotation-gated mode), it declares every `def` and marks what it defaulted. The rule keys on the mark,
not on the magic comment:

- A member marked `rigor:v1:inferred-signature` was not annotated at all. It is not a contract; its basis
  follows from its project definitions.
- A member marked `rigor:v1:inferred-return` has authored parameters and a defaulted return, but the
  engine cannot tell an authored `untyped` parameter from a defaulted one. Its basis is `contract`; a
  parameter that reads `untyped` is `unavailable` with `not_computed`; its return is inferred as for
  `single_site`, or `unavailable` with `contested` when the member has more than one project definition.

**Overloads.**

- A contract member has one overload per declared method type. A `single_site` member has one overload
  built from its site's parameter list. A `contested` member, of either kind, has no overloads (`[]`): its
  definitions may differ in arity, and each method site carries its own `params` and `block`.
- A `single_site` `attribute` member has one overload whose slots are `unavailable` with `not_computed`
  (a reader takes no parameters; a writer takes one unnamed `required` parameter); revision 1 does not
  report an instance variable's type.
- `params` is `[{name, kind, type}]` in declaration order. `kind` is `required`, `optional`, `rest`,
  `post` (a positional after the rest), `keyreq`, `key` or `keyrest`; `name` is `null` when the
  declaration names none; `type` is a slot. A parameter with no contract is a `dynamic` slot with provenance
  `inferred` and cause `inferred_return_untyped`, ADR-75's cause for an undeclared parameter. `params` is `null` for an
  argument-forwarding list (`...`, or RBS `(?)`), and for a contract Rigor cannot read (its `return` is then
  `unavailable` with `not_computed` or `definition_build_failed`).
- `block` is `{required, type}` when the member takes a block: `required` is a boolean and `type` a slot
  whose type is the block's RBS function type (`(Integer) -> void`). Without a contract, a definition takes a
  block when it declares `&blk` or its body (outside nested `def`s, lambdas and `define_method` blocks)
  contains `yield`; it then reads `{required: false, type: <dynamic slot>}`. `null` means no block was
  declared or detected.
- `return` is a slot.
- `rbs` is the overload as RBS in `sig-gen`'s spelling, authored `%a{rigor:v1:…}` annotations of the
  declaring member first. It is `null` when any slot of the overload is `unavailable`: an `untyped` there
  would read as an assertion.

## Slots

Every type position is a tagged slot:

| `state` | Fields | Meaning |
| --- | --- | --- |
| `typed` | `type`, `provenance`, `path`, `from_site` | A type Rigor resolved. |
| `dynamic` | `type: "untyped"`, `provenance`, `path`, `from_site`, `cause` | The effective type is `untyped`. `cause` is an ADR-75 dynamic-origin cause (`explicit_untyped`, `inferred_return_untyped`, `external_gem_without_rbs`, `framework_dsl_boundary`, `analyzer_budget_cutoff`, `unsupported_syntax`), or `null` when none was recorded. |
| `unavailable` | `reason` | Rigor has no type to report: `contested`, `not_computed` or `definition_build_failed`. Never spelled `untyped`. |

- An inferred `type` is spelled as `sig-gen` writes RBS: the erasure, elaborated and alias-folded. A
  contract `type` is spelled as its declaration reads in the environment, with absolute names (`::Integer`).
  A refined type reads as its erasure; inferred refinements are not emitted in revision 1.
- `provenance` is one of `sig`, `inline`, `inferred`, `plugin:<id>` and `library`. A contract slot reads
  it from the declaring RBS member's buffer name:
  - `virtual:rbs-inline:…` is `inline`; any other `virtual:<id>:…` is `plugin:<id>`;
  - a file under a loaded plugin's `signature_paths:` is `plugin:<id>`;
  - a file under a project signature root is `sig`, with `path` set;
  - any other file is `library` (gem, `rbs collection`, stdlib and core signatures);
  - a buffer whose name did not survive the environment cache (`<cached>`, or empty) cannot be
    classified, so the member's slots are `unavailable` with `not_computed`.

  `extrbs` is reserved until `@extrbs` is read ([#1073](https://github.com/rigortype/rigor/issues/1073)).
- `path` is set for `sig` provenance and `null` otherwise. `from_site` is set on an `inferred` slot of a
  member and names the site whose body produced it; it is `null` on a site's own `body_return`.

Examples, one per state:

```json
{ "state": "typed", "type": "String", "provenance": "sig", "path": "sig/shop.rbs", "from_site": null }
{ "state": "typed", "type": "Integer", "provenance": "inferred", "path": null, "from_site": "lib/shop.rb:99-126:0" }
{ "state": "dynamic", "type": "untyped", "provenance": "inline", "path": null, "from_site": null, "cause": "explicit_untyped" }
{ "state": "dynamic", "type": "untyped", "provenance": "inferred", "path": null, "from_site": "lib/shop.rb:99-126:0", "cause": null }
{ "state": "unavailable", "reason": "contested" }
```

A member with an authored parameter, a defaulted return, and a second definition elsewhere:

```json
{
  "owner": "Shop", "scope": "instance", "name": "label", "kind": "method", "visibility": "public",
  "sites": ["lib/shop.rb:70-97:0"],
  "also_defined_at": [{ "path": "lib/legacy/shop.rb", "line": 12 }],
  "basis": "contract",
  "overloads": [
    {
      "rbs": null,
      "params": [{ "name": "n", "kind": "required", "type": { "state": "typed", "type": "Integer", "provenance": "inline", "path": null, "from_site": null } }],
      "block": null,
      "return": { "state": "unavailable", "reason": "contested" }
    }
  ]
}
```

The shared fixture is the project `spec/integration/fixtures/lens/project/` and its expected document
`spec/integration/fixtures/lens/expected.json`, which the producer's spec regenerates and compares. ZARD's
adapter pins that file at a Rigor commit as its revision-1 fixture.

## Anchors

A site's `anchor` is `<line>:<hash>`, where `line` is the first line of the hashed material and `hash`
is the xxh3-64 of that material, truncated to its low 16 bits and written as 4 lowercase hex digits
(`Hashing::XXH3.anchor_hash`). Sites that share a span share an anchor and are told apart by `ordinal`.
The token syntax `<decimal line>:<4 hex>` is stable in both renderings.

A **contract comment** is an inline comment whose text, from its `#`, matches rbs-inline's annotation
grammar or names `@extrbs`: it starts with `#:`, `#[`, `#` followed by optional whitespace and `@rbs` as a
word, or `#` followed by optional whitespace and `@extrbs` as a word. A `#:word:` RDoc directive (`#:nodoc:`) is not
one, as the rbs-inline plugin neutralises it. `=begin` blocks never contain one.

The hashed material is built from the file's bytes:

1. **Leading contract comments.** Walk up from the line above the declaration through the contiguous run of
   comment-only lines; a blank line or a line with code ends the run. Keep each contract comment. Also keep
   a comment-only line directly below a kept `@rbs` or `@extrbs` comment, or below a line kept this way,
   when the number of spaces between its `#` and its first non-space byte is greater than that number on
   the `@rbs` / `@extrbs` line: rbs-inline's continuation lines. Every other line of the run, including
   documentation prose and magic comments, is not part of the material.
2. **Trailing contract comment.** When a comment starts on the declaration's last line after the
   declaration ends and is a contract comment starting with `#:`, keep it. It counts for `contract_span`.
3. **Material** is each line kept in step 1, from its `#` to the end of the line without the line
   terminator (`\n`, or `\r\n` for a CRLF line), followed by `\n`; then the declaration's bytes
   `[start_offset, end_offset)`; then, when step 2 kept a comment, `\n` and that comment's bytes to the end
   of its line without the terminator.

The rule is the same for every kind. For a `class`, `module` or `def` the declaration's bytes are its whole
body, so an edit anywhere inside it, prose included, moves its anchor; prose in the leading comment run
does not. The file `digest` changes on every edit. An unchanged anchor never licenses reusing stale offsets,
line numbers or documentation: a consumer re-associates on the current file whenever its digest moved.

## What revision 1 does not carry

Named-type references, inherited members, symbol queries, plugin-synthesized members, `@extrbs`,
inferred refinements, effect labels, source bodies and callers. Each is a later capability and appears in
`capabilities` when it ships.
