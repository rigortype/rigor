# `rigor lens --claims`: documentation claim checking, revision 1

Status: **Accepted contract, not implemented.** This is the binding description of what `rigor lens
--claims` will compute and emit. [ADR-113](../adr/113-rigor-lens.md) § "Amendment 2026-11-04" records
why; the boundary was agreed with ZARD, the first consumer, in
[#2737](https://github.com/rigortype/rigor/issues/2737). No Rigor release carries it yet. ZARD enables its
claim-mismatch diagnostics only against a released producer that advertises the capability and passes
the conformance fixtures below. The surrounding document, its context, its targets and its exit status
are [`lens.md`](lens.md)'s; this file adds one section to it and changes nothing there.

The keywords MUST, MUST NOT, SHOULD and MAY are used as in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).

## What a claim is

A **documentation claim** is the type written in an API documentation tag (`@param text [String]`,
`@return [Integer]`). It is an optional statement about an API, not a contract: the contract is the
member's authored signature (`sig/` or inline `@rbs` / `#:`). A claim check asks whether the contract
supports the documented promise.

Claims never enter Rigor's analysis. A claim MUST NOT become a signature, refine or widen an inferred
type, change a diagnostic, or reach the incremental snapshot or any cache. Every field of a lens document
produced with `--claims` other than `claims` MUST equal the one produced for the same targets without it.

## Invocation

```text
rigor lens --format json --claims REQUEST [--config FILE] [--workers N] FILE...
```

- `REQUEST` is a path to the request file (§ Request), resolved against the working directory. The request
  is checked in the same run that produces the lens document, so a documentation build pays the engine once.
- `--claims` requires `--format json`; with the text format it is a usage error.
- The lens `capabilities` list gains `claims`. The document gains a top-level `claims` field (§ Response),
  `null` when `--claims` was not passed. A producer whose `capabilities` lacks `claims` cannot check claims.
- Exit status is `lens.md`'s, with one addition to exit 64: a request Rigor cannot answer as written
  (§ Integrity errors) writes no document. A claim that Rigor answers `unknown` or `unavailable` never
  changes the exit status, and neither does a `conflict`: the consumer decides what fails its build.

## Request

The request file is UTF-8 JSON:

```json
{
  "schema": "lens-claims-request/v0",
  "revision": 1,
  "grammar": "rbs",
  "files": [{ "path": "lib/widget.rb", "digest": "xxh3-64:0123456789abcdef" }],
  "claims": [
    {
      "id": "widget-result:tag-0",
      "file": "lib/widget.rb",
      "declaration": {
        "kind": "method", "owner": "Widget", "scope": "instance", "name": "result",
        "span": { "start_offset": 80, "end_offset": 110 }
      },
      "tag": { "name": "return", "subject": null, "span": { "start_offset": 40, "end_offset": 79 } },
      "claim": "String"
    }
  ]
}
```

The offsets and digest are illustrative.

- `grammar` names how `claim` text is read. Revision 1 supports `rbs` only (§ Grammar).
- `files` lists each file the claims refer to, once, with the digest of the exact bytes the consumer read,
  spelled and computed as `lens.md`'s file `digest`. Each `path` is root-relative and MUST name one of the
  invocation's `FILE` targets: some `FILE` argument, resolved against the working directory, is that path,
  whether or not the file exists. A path several arguments name refers to the first of them; the later ones
  read `duplicate` in the lens document and answer no claim.
- `claims` lists the claims to check. `id` is the caller's opaque identifier, unique within the request;
  Rigor echoes it and assigns it no meaning.
- `declaration` locates the declaration the claim documents, from the consumer's own parse of the file; no
  earlier lens run is needed. `span` is the declaration's byte span as `lens.md` § Sites gives a site's
  `span` (Prism's `def` node, 0-based, end-exclusive). `kind`, `owner`, `scope` and `name` are spelled as
  that site's fields are.
- `tag` is the documentation tag: `name` (`param` or `return` in revision 1; any other name is accepted and
  answered `unknown`), `subject` (the parameter name a `@param` tag gives, or `null`), and the tag's byte
  `span` in the same file. Rigor checks that the tag span lies within the file. It does not check that the
  consumer attached the tag to the right declaration: that association is the consumer's, and the consumer
  re-checks it when it attaches the result.
- `claim` is the tag's type text, without its brackets.

### Resolving the declaration

A claim whose target's lens `status` is not `ok` is not resolved: it is `unavailable` (§ Verdicts). Otherwise
its `declaration` resolves against the lens sites of its target, never against a neighbour:

1. When its `span` equals the `span` of exactly one site of kind `method`, and the member
   `(owner, scope, name)` the request names lists that site (`lens.md` § Members, `sites`), the claim is bound
   to that site and that member. A module function's site binds under either scope, each to its own member.
2. When its `span` equals the `span` of a site, but step 1 does not bind it, the claim is `unknown`: with
   `unsupported_declaration` when the site is not a `method` site (an `attribute`, which a documentation tool
   may model as a method, or a `class`, `module` or `constant`), or when sites share the span
   (`attr_reader :a, :b`); with `declaration_mismatch` when the member the request names does not list it.
3. When its `span` equals the `span` of an omission (`lens.md` § Omissions), the claim is `unknown` with
   `unsupported_declaration`: the declaration exists, but revision 1 does not model it.
4. Otherwise the claim is `unknown` with `no_such_declaration`. The file's digest already matched, so the
   consumer and Rigor read the same bytes; a span Rigor has no declaration for is a declaration the consumer
   models and Rigor does not (a documentation directive attached to a DSL call, say), not a stale request.

The result names the bound site by its lens `key`, so the consumer can join it to the lens document of the
same run. A site key is not stable across runs and MUST NOT be stored.

### Integrity errors

Each of these is exit 64 with no document, because no per-claim answer could be trusted:

- the request file cannot be read, is not UTF-8 JSON, or lacks a field revision 1 requires;
- an unsupported `schema`, `revision` or `grammar`;
- a duplicate `id`, a duplicate `files` path, or a claim whose `file` is not in `files`;
- a `files` path that is not one of the invocation's targets;
- a `files` digest that differs from the digest of the file's bytes, for a file Rigor can read, whatever
  status its target ends with (a target with no readable file, `not_found`, answers `unavailable`);
- for such a file, a `declaration` or `tag` span outside it.

Rigor validates the request, and compares each digest with the file on disk, before analysis starts, so a
malformed or stale request costs no run. A file that changes during the run still makes its digest differ from
the bytes the analysis read, which is the same error. Fields revision 1 does not define are ignored. A
per-claim problem inside a valid request is a result, never an integrity error (§ Verdicts).

## Response

The lens document carries the answer as its `claims` field:

```json
{
  "schema": "lens-claims/v0",
  "revision": 1,
  "request_digest": "xxh3-64:fedcba9876543210",
  "grammar": "rbs",
  "capabilities": ["return", "required_param", "required_keyword"],
  "results": [
    {
      "id": "widget-result:tag-0",
      "verdict": "conflict",
      "reason": "proven_disjoint_arm",
      "relation": "documentation_coverage",
      "direction": "contract_within_claim",
      "site": "lib/widget.rb:80-110:0",
      "member": { "owner": "Widget", "scope": "instance", "name": "result" },
      "slot": { "kind": "return" },
      "contract": { "type": "::Integer", "provenance": "sig", "path": "sig/widget.rbs" },
      "evidence": [{ "rule": "unrelated_classes", "arm": "::Integer", "against": "::String" }]
    }
  ]
}
```

- `schema` and `revision` version the request and this section together, independently of `lens/v0`. A
  breaking change to either bumps `revision`.
- `request_digest` is the xxh3-64 of the request file's exact bytes. The consumer MUST compare it with the
  request it wrote before accepting any verdict.
- `capabilities` lists the claim subjects this revision checks: `return` (`@return`), `required_param` (a
  required positional `@param`) and `required_keyword` (a required keyword `@param`). A subject missing from
  it is answered `unknown`, never `compatible`.
- `results` holds exactly one result per request claim, in request order, with `id` echoed.

### Result fields

| Field | Content |
| --- | --- |
| `id` | The request's `id`. |
| `verdict` | § Verdicts. |
| `reason` | The verdict's reason code (§ Verdicts). Never `null`. |
| `relation` | `documentation_coverage` when a slot was resolved, `null` otherwise. |
| `direction` | `claim_within_contract` for a parameter, `contract_within_claim` for a return, `null` when no slot was resolved. |
| `site` | The bound site's lens `key`, or `null` when the declaration did not bind. |
| `member` | `{owner, scope, name}` of the member whose contract was read, or `null`. |
| `slot` | `{kind: "return"}`, or `{kind: "param", name, param_kind, index}` with `lens.md`'s parameter `kind` vocabulary and the 0-based index in the contract overload's `params`; `null` when no slot was resolved. |
| `contract` | The contract slot read: `{type, provenance, path}`, spelled as a `typed` lens slot; `null` when none was read. |
| `evidence` | `[{rule, arm, against}]`, the arms of `S` (§ Relation) that decided a `compatible` or `conflict`, each with the arm of `P` that included it, or all of `P` that it is disjoint from (one entry per arm for `compatible`, the deciding arm for `conflict`); `[]` otherwise. Types are display text: they explain the verdict and are not a contract (ADR-50 § Decision 3). The consumer MUST NOT re-derive a verdict from them. |

## Verdicts

| `verdict` | Meaning | `reason` |
| --- | --- | --- |
| `compatible` | Rigor proved the required inclusion. | `proven_inclusion` |
| `conflict` | Rigor proved the required inclusion false. | `proven_disjoint_arm` |
| `unknown` | The target was analysed, and Rigor proved neither. | One of the codes below. |
| `invalid_claim` | The claim text is not a type under `grammar` (§ Grammar). | `syntax_error` |
| `unavailable` | The claim's target has no analysis: its lens `status` is not `ok`. No semantic answer is given. | The target's `status` (`not_found`, `not_ruby`, `outside_project`, `parse_error`, `failed`). |

`unknown` reasons:

| `reason` | When |
| --- | --- |
| `no_such_declaration` | No site or omission of the analysed file has the declaration's span. |
| `unsupported_declaration` | The declaration is an omission, is not a `method` site, or shares its span with another site. |
| `declaration_mismatch` | A site has the declaration's span, but the member the request names does not list it. |
| `unsupported_subject` | The tag is not `@param` or `@return`, or a `@param` has no `subject`. |
| `no_authored_contract` | The slot has no `sig` or `inline` contract: the member's `basis` is not `contract`, the slot is inferred (an `inferred-return` member's return), or the slot reads `unavailable`. |
| `unsupported_contract_source` | The contract slot's provenance is `library` or `plugin:<id>`. |
| `extrbs_contract` | The site carries an `@extrbs` contract comment. Rigor does not read `@extrbs` yet ([#1073](https://github.com/rigortype/rigor/issues/1073)), so the contract it holds may be an erasure of the authored one. |
| `refined_contract` | The contract slot carries an authored `%a{rigor:v1:…}` refinement. Its erasure is wider than the contract, so it proves nothing for a parameter; revision 1 reads neither direction through an erasure. |
| `unsupported_overloads` | The contract has more than one overload, or a forwarding parameter list (`params` is `null`). |
| `no_such_parameter` | No parameter of the site is named `subject`. |
| `unsupported_parameter_kind` | The named parameter is not a required positional or required keyword. |
| `unmatched_parameter` | The site's positional parameter kinds and the contract overload's do not line up, or the contract does not declare the named keyword as required (§ Subjects). |
| `unsupported_grammar_feature` | The claim is not a plain RBS type but is a Rigor extended type (`non-empty-string`). |
| `unresolved_name` | A type name in the claim does not resolve. |
| `ambiguous_name` | A relative type name in the claim may name a class Rigor cannot see (§ Grammar, Name resolution), so the claim cannot be compared. |
| `dynamic_type` | The claim or the contract slot contains `untyped`, anywhere. |
| `unsupported_type` | The claim or the contract slot contains a form § Relation does not reason about. |
| `unproven` | Every input was supported, and neither inclusion nor its refutation was proved. |

For a claim in a target whose `status` is `ok`, `invalid_claim` is decided first and wins over every
`unknown` reason. The `unknown` reasons are then checked in the order listed, and the first that applies is
reported. Only when none of them applies is the relation computed, giving `compatible`, `conflict` or, last,
`unproven`: a claim with `untyped` anywhere is `dynamic_type` even when every arm would compare equal. A later
revision MAY add
reason codes; a consumer MUST treat an unrecognised code as `unknown` with no further meaning.

## Grammar

`rbs` reads `claim` as one RBS type expression, as the loaded `rbs` gem parses a type (`context.rbs_version`
names it).

- Text the RBS parser rejects but Rigor's refinement grammar accepts (the type names and
  parameterised forms of `%a{rigor:v1:…}` payloads) is `unknown` with `unsupported_grammar_feature`. Only
  text both reject is `invalid_claim`. A type that parses but is ill-formed (an unknown name, a wrong number
  of type arguments) is not `invalid_claim` in revision 1.
- A type alias is expanded; a generic alias is `unsupported_type`. Type variables are not in scope: a claim
  naming one fails to resolve.

**Name resolution.** An absolute name (`::String`) is read as written. A relative name is resolved twice, and
both answers must name the same class or module, or the claim is `unknown`:

- in RBS, as an inline `@rbs` annotation on the bound declaration resolves it (`unresolved_name` when it does
  not resolve);
- in Ruby, over the run's seeded project index, following Ruby's constant lookup from the declaration's body:
  the declaration's lexical nesting from its source file (innermost first, the top level excluded), then the
  ancestors of the innermost class or module, then `Object` when that is a module. The index is rooted at the
  configuration's `paths:` (`lens.md` § Computation), so the answer does not depend on which files were
  requested. When no constant the index records on that path has the name, the Ruby answer is the RBS answer:
  the index holds project Ruby only, and core, stdlib and gem classes are known through RBS. When the index
  finds a project constant the RBS answer does not name, the claim is `ambiguous_name`: a Ruby-only
  `App::Data < Hash` is not the core `::Data`.

Agreement is enough for `compatible`. It is not enough for `conflict`, because the index does not see every
constant a namespace may hold: a file outside `paths:` or matched by `exclude:`, a gem without RBS that reopens a
project namespace, `const_set` with a computed name, a `class_eval` string. `rbs.contradicting-signature`
refuses relative names outright for that reason (`Comparator#provable_names?`). So a relative name counts toward
a `conflict` (§ Relation, Non-inclusion) only in a top-level declaration (a `def` outside any class or module
body, owner `Object`). There the lexical nesting is empty and Ruby finds the name in `Object`'s own constant
table before any module `Object` includes, so a project or gem can shadow a core name only by reassigning the
core constant itself. Not even a reopened core class qualifies: a file outside `paths:` or a gem without RBS can
give `class Integer` a nested `Integer::Data`, which Ruby finds before `::Data`. Anywhere else a relative arm can
prove `compatible` but never `conflict`, and a conflict needs the absolute spelling (`::Integer`).

The same blind spot bounds `compatible`: agreement between the two lookups proves the inclusion for the classes
Rigor can see. A relative name that Ruby resolves to a constant only an unread file defines can read
`compatible` against the class RBS names. That is a missed finding, never a diagnostic, but a consumer MUST NOT
present a relative-name `compatible` as a proof against the running program.

## Relation

Let `C` be the claim's type and `F` the contract slot's type. `documentation_coverage` requires:

- for a parameter, `C ⊆ F`: every input the documentation advertises is accepted by the contract;
- for a return, `F ⊆ C`: every result the contract permits satisfies the documented promise.

Write the required inclusion as `S ⊆ P`: `S` is `C` for a parameter and `F` for a return, `P` the other.
Narrower advertised parameters and broader documented returns are compatible. Whether the documentation
describes the whole contract is not checked.

### Arms

Both types are read as unions of **arms**. `T?` is `T | nil`, and `bool` is `true | false`. An arm is one of:

- a **literal**: a string, symbol or integer literal, `true`, `false` or `nil`, whose class is its Ruby class
  (`nil` is a `NilClass`). The classes `TrueClass`, `FalseClass` and `NilClass` without type arguments are
  read as the one literal each holds, as the comparator reads them;
- a **class instance**: a class or module name, with or without type arguments.

Any other form, anywhere in either type (`top`, `bot`, `void`, `self`, `instance`, `class`, `singleton(…)`,
an interface, a tuple, a record, a proc type, an intersection, a type variable), makes the claim
`unknown` with `unsupported_type`, checked after `dynamic_type`.

### Inclusion: `compatible`

An arm `s` of `S` is **included** in `P` when some arm `p` of `P`:

- equals `s` after name resolution and alias expansion, type arguments included, where a union compares as
  the set of its arms (`Array[String | Integer]` equals `Array[Integer | String]`) (`equal`);
- is a class instance without type arguments whose class is an RBS ancestor of the literal `s`'s class
  (`literal_class_ancestor`); or
- is a class instance without type arguments, of a non-generic class or module, that is an RBS ancestor of
  the class instance `s` (`class_ancestor`). `s` may carry type arguments.

Ancestry is the RBS environment's, project declarations included: the authored contract is authoritative, so
`class B < A` in it proves `B ⊆ A`. A class whose RBS ancestry is known to disagree with Ruby's
(`MemberConsistency::RbsProof::UNRELIABLE_ANCESTRY`: rbs says `Tempfile < File`, Ruby `Tempfile < Delegator`)
proves no inclusion through its ancestry, on either side. The verdict is `compatible` when every arm of `S` is included.

### Non-inclusion: `conflict`

An arm `s` of `S` is **disjoint** from `P` when it shares no value with any arm `p` of `P`, by the rules of
`rbs.contradicting-signature` (`Environment::MemberConsistency::Comparator#disjoint?`):

- two distinct literals (`distinct_literals`);
- a literal whose class has no RBS ancestor `p` (`literal_outside_class`);
- two class instances neither of whose classes is an RBS ancestor of the other (`unrelated_classes`).

A class counts only when it is a Ruby core or stdlib **class** (never a module) whose RBS ancestry Rigor
trusts, `MemberConsistency::RbsProof#class_ancestors` answers it, and its name, if the claim wrote it
relatively, passes § Grammar's guard. A project class, a gem class or a module
never proves disjointness, because a reopening or an `include` elsewhere can change what it shares. Type
arguments are ignored here: classes that share no instance share none with any arguments. Every arm in this
fragment has a value, so a disjoint arm of `S` is a value outside `P`. The verdict is `conflict` when some
arm of `S` is disjoint from `P` and `compatible` does not hold.

Overlap alone proves neither: a `String` return documented as `"hello"` is `unproven`, and so is
`Project::A | Project::B` documented as `Project::B | Project::C`.

## Subjects

- **Return.** The contract overload's `return` slot.
- **Required positional parameter.** The bound site's own parameter list (`lens.md` § Sites, `params`) gives
  the index of the parameter named `subject` among its positional parameters (`required`, `optional`, `rest`,
  `post`); it MUST be `required`. The contract overload's positional parameter at the same index is read only
  when the two positional lists have the same length and the same `kind` at every position; otherwise
  `unmatched_parameter`. Keywords are not compared here: the contract lists required keywords before optional
  ones whatever the source order. Contract parameter names are not consulted: RBS names a positional
  parameter for documentation only.
- **Required keyword parameter.** The site declares a `keyreq` named `subject`, and the contract overload's
  `keyreq` of that name is read; when the contract declares that keyword optional, or not at all, the claim is
  `unmatched_parameter`.

The contract is the member's, after Rigor's own merge of `sig/` and inline declarations (the one `check` reads,
which `lens.md` § Members reports). It is read only when the member's `basis` is `contract` and it has
exactly one overload.

## Conformance fixtures

Before a release advertises `claims`, the producer's spec suite MUST run the real CLI over an isolated
project and check in each request, the source and signature files, the expected document, stderr and the
exit status, so ZARD's adapter can pin them. The fixtures cover:

- `compatible` and `conflict` in both directions, including the five rows of #2737's table (its `Formatter` is a
  project class, so its conflict rows read `conflict` spelled `::Integer` and `unproven` spelled `Integer`);
- equal types spelled differently (a relative name, an absolute name, a type alias);
- a narrower parameter claim and a broader return claim (`compatible`), and overlap only (`unproven`);
- project-class inclusion through declared ancestry (`compatible`), and project classes that cannot be
  ranked (`unproven`, never `conflict`);
- a relative name a project namespace shadows in Ruby alone (`Data` inside `module App` that defines
  `App::Data < Hash` with no RBS, `ambiguous_name`); the same shadow in a file outside `paths:`, which reads
  `unproven`, never `conflict`; a relative core name in a project class and in a reopened core class, each
  reading `unproven` where the absolute spelling reads `conflict`; and a relative core name in a top-level
  `def`, which reads `conflict`;
- a relative gem name with RBS (`Faraday::Response`) that compares `equal`;
- a span that matches a site under another identity (`declaration_mismatch`), an attribute site, and a span
  with no declaration (`no_such_declaration`);
- each `unknown` reason, and `unavailable` for a failed target;
- `invalid_claim` against a valid extended payload (`unsupported_grammar_feature`);
- each integrity error (exit 64, no document), including a stale digest and a span outside its file;
- a lens document equal to the one produced without `--claims`, apart from `claims`.
