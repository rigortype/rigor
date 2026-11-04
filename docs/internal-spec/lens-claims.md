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
  spelled and computed as `lens.md`'s file `digest`. Each `path` MUST be the root-relative `path` of one of
  the invocation's `FILE` targets.
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

A claim's `declaration` resolves against the lens sites of its target, never against a neighbour:

1. When its `span` equals the `span` of exactly one site, and that site's `kind`, `owner`, `scope` and `name`
   equal the request's, the claim is bound to that site. Sites that share a span (`attr_reader :a, :b`) never
   bind: the claim is `unknown` with `unsupported_declaration`.
2. When its `span` equals the `span` of an omission (`lens.md` § Omissions), the claim is `unknown` with
   `unsupported_declaration`: the declaration exists, but revision 1 does not model it.
3. Otherwise the request is inconsistent with the source it says it read, which is an integrity error.

The result names the bound site by its lens `key`, so the consumer can join it to the lens document of the
same run. A site key is not stable across runs and MUST NOT be stored.

### Integrity errors

Each of these is exit 64 with no document, because no per-claim answer could be trusted:

- the request file cannot be read, is not UTF-8 JSON, or lacks a field revision 1 requires;
- an unsupported `schema`, `revision` or `grammar`;
- a duplicate `id`, a duplicate `files` path, or a claim whose `file` is not in `files`;
- a `files` path that is not one of the invocation's targets;
- a `files` digest that differs from the digest of the bytes the analysis read, for a target that has one;
- a `declaration` or `tag` span outside its file, or a declaration that does not resolve (§ Resolving the
  declaration, step 3).

A per-claim problem inside a valid request is a result, never an integrity error (§ Verdicts).

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
      "evidence": [{ "rule": "unrelated_classes", "subset_arm": "::Integer", "superset": "::String" }]
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
| `evidence` | `[{rule, subset_arm, superset}]`, the arms that decided a `compatible` or `conflict` (one entry per arm for `compatible`, the deciding arm for `conflict`); `[]` otherwise. Types are display text: they explain the verdict and are not a contract (ADR-50 § Decision 3). The consumer MUST NOT re-derive a verdict from them. |

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
| `unsupported_declaration` | The declaration is an omission, or shares its span with another site. |
| `unsupported_subject` | The tag is not `@param` or `@return`, a `@param` has no `subject`, or the declaration is not a `method` site. |
| `no_authored_contract` | The slot has no `sig` or `inline` contract: the member's `basis` is not `contract`, the slot is inferred (an `inferred-return` member's return), or the slot reads `unavailable`. |
| `unsupported_contract_source` | The contract slot's provenance is `library` or `plugin:<id>`. |
| `extrbs_contract` | The site carries an `@extrbs` contract comment. Rigor does not read `@extrbs` yet ([#1073](https://github.com/rigortype/rigor/issues/1073)), so the contract it holds may be an erasure of the authored one. |
| `refined_contract` | The contract slot carries an authored `%a{rigor:v1:…}` refinement. Its erasure is wider than the contract, so it proves nothing for a parameter; revision 1 reads neither direction through an erasure. |
| `unsupported_overloads` | The contract has more than one overload, or a forwarding parameter list (`params` is `null`). |
| `no_such_parameter` | No parameter of the site is named `subject`. |
| `unsupported_parameter_kind` | The named parameter is not a required positional or required keyword. |
| `unmatched_parameter` | The site's parameter kinds and the contract overload's do not line up position by position, so the positional parameter cannot be found in the contract. |
| `unsupported_grammar_feature` | The claim is not a plain RBS type but is a Rigor extended type (`non-empty-string`). |
| `unresolved_name` | A type name in the claim does not resolve. |
| `dynamic_type` | The claim or the contract slot contains `untyped`, anywhere. |
| `unsupported_type` | The claim or the contract slot contains a form § Relation does not reason about. |
| `unproven` | Every input was supported, and neither inclusion nor its refutation was proved. |

For a claim in a target whose `status` is `ok`, `invalid_claim` is decided first and wins over every
`unknown` reason. The `unknown` reasons are then checked in the order listed; the first that applies is
reported. A later revision MAY add
reason codes; a consumer MUST treat an unrecognised code as `unknown` with no further meaning.

## Grammar

`rbs` reads `claim` as one RBS type expression, as the loaded `rbs` gem parses a type (`context.rbs_version`
names it).

- Text the RBS parser rejects but Rigor's refinement grammar accepts (the type names and
  parameterised forms of `%a{rigor:v1:…}` payloads) is `unknown` with `unsupported_grammar_feature`. Only
  text both reject is `invalid_claim`. A type that parses but is ill-formed (an unknown name, a wrong number
  of type arguments) is not `invalid_claim` in revision 1.
- Type names resolve as they would in an inline `@rbs` annotation on the bound declaration: relative names
  against the owner's namespace, then upward. A type alias is expanded; a generic alias is `unsupported_type`.
- Type variables are not in scope: a claim naming one fails to resolve.

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
  (`nil` is a `NilClass`);
- a **class instance**: a class or module name, with or without type arguments.

Any other form, anywhere in either type (`top`, `bot`, `void`, `self`, `instance`, `class`, `singleton(…)`,
an interface, a tuple, a record, a proc type, an intersection, a type variable), makes the claim
`unknown` with `unsupported_type`, checked after `dynamic_type`.

### Inclusion: `compatible`

An arm `s` of `S` is **included** in `P` when some arm `p` of `P`:

- equals `s` after name resolution and alias expansion, type arguments included (`equal`);
- is a class instance without type arguments whose class is an RBS ancestor of the literal `s`'s class
  (`literal_class_ancestor`); or
- is a class instance without type arguments, of a non-generic class or module, that is an RBS ancestor of
  the class instance `s` (`class_ancestor`). `s` may carry type arguments.

Ancestry is the RBS environment's, project declarations included: the authored contract is authoritative, so
`class B < A` in it proves `B ⊆ A`. The verdict is `compatible` when every arm of `S` is included.

### Non-inclusion: `conflict`

An arm `s` of `S` is **disjoint** from `P` when it shares no value with any arm `p` of `P`, by the rules of
`rbs.contradicting-signature` (`Environment::MemberConsistency::Comparator#disjoint?`):

- two distinct literals (`distinct_literals`);
- a literal whose class has no RBS ancestor `p` (`literal_outside_class`);
- two class instances neither of whose classes is an RBS ancestor of the other (`unrelated_classes`).

A class counts only when it is a Ruby core or stdlib **class** (never a module) whose RBS ancestry Rigor
trusts: `MemberConsistency::RbsProof#class_ancestors` answers it. A project class, a gem class or a module
never proves disjointness, because a reopening or an `include` elsewhere can change what it shares. Type
arguments are ignored here: classes that share no instance share none with any arguments. Every arm in this
fragment has a value, so a disjoint arm of `S` is a value outside `P`. The verdict is `conflict` when some
arm of `S` is disjoint from `P` and `compatible` does not hold.

Overlap alone proves neither: a `String` return documented as `"hello"` is `unproven`, and so is
`Project::A | Project::B` documented as `Project::B | Project::C`.

## Subjects

- **Return.** The contract overload's `return` slot.
- **Required positional parameter.** The bound site's own parameter list (`lens.md` § Sites, `params`) gives
  the index of the parameter named `subject`; it MUST be `required`. The contract overload's parameter at the
  same index is read only when the two lists have the same length and the same `kind` at every position;
  otherwise `unmatched_parameter`. Contract parameter names are not consulted: RBS names a positional
  parameter for documentation only.
- **Required keyword parameter.** The contract overload's `keyreq` parameter whose name is `subject`; the
  site MUST declare a `keyreq` of that name.

The contract is the member's, after Rigor's own merge of `sig/` and inline declarations (the one `check` reads,
which `lens.md` § Members reports). It is read only when the member's `basis` is `contract` and it has
exactly one overload.

## Conformance fixtures

Before a release advertises `claims`, the producer's spec suite MUST run the real CLI over an isolated
project and check in each request, the source and signature files, the expected document, stderr and the
exit status, so ZARD's adapter can pin them. The fixtures cover:

- `compatible` and `conflict` in both directions, including the five rows of #2737's table;
- equal types spelled differently (a relative name, an absolute name, a type alias);
- a narrower parameter claim and a broader return claim (`compatible`), and overlap only (`unproven`);
- project-class inclusion through declared ancestry (`compatible`), and project classes that cannot be
  ranked (`unproven`, never `conflict`);
- each `unknown` reason, and `unavailable` for a failed target;
- `invalid_claim` against a valid extended payload (`unsupported_grammar_feature`);
- each integrity error (exit 64, no document), including a stale digest and a locator that matches no site;
- a lens document equal to the one produced without `--claims`, apart from `claims`.
