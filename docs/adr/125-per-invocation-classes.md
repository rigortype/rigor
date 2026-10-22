# ADR-125 — Plugin-declared per-invocation classes

Status: **Accepted, 2026-10-22.** The maintainer chose this design (option A) for v0.4.6 on #575. The
manifest field, the `Registry` aggregate, the narrowed `def.ivar-write-mismatch` and rigor-actionpack's
declaration land together in the PR that closes #575. rigor-actionmailer declares nothing yet.

Archetype: deliberative. Stakes: mid. The change is additive to the plugin contract and only ever
withholds a finding, but it widens what plugins can say to an engine rule.

## Context

`def.ivar-write-mismatch` compares every write of an instance variable in a class against the first
concrete one, whatever method each write sits in. That premise is "all of a class's instance methods may
run on one instance". A Rails controller breaks it. Each request instantiates a fresh controller and
runs exactly one action, so `@roles = Role.sorted.to_a` in `index` and `@roles = Role.sorted` in
`permissions` are never live together. The divergence has no runtime consequence, and the warning is a
false positive on correct code.

The #569 landing gate surfaced 4 such firings on redmine (`roles_controller.rb`,
`workflows_controller.rb`). The 2026-09-26 triage on #575 measured 9 firings across redmine, gitlab and
mastodon; 4 of them were divergent writes in two different public actions. The firings appeared once the
Relation types became concrete; before that, both arms were `Dynamic`, which the rule skips. Every
precision lever that lands on Rails apps will add more.

The engine cannot see this on its own. Whether an instance serves one entry point is a framework fact,
and the plugin that models the framework is where Rigor keeps framework facts
([ADR-2](2-extension-api.md)).

## Decision

A plugin may declare **per-invocation classes**: classes whose every instance serves exactly one
public-method entry point. Ivar writes in two distinct public methods of such a class (or a descendant)
are never live together.

- **Manifest field.** `per_invocation_classes: [String]` is a list of class names. Validation requires an
  Array of non-empty Strings, and a leading `::` is dropped (`Plugin::Manifest`).
- **Aggregate and predicate.** `Registry#per_invocation_classes` and `Registry#per_invocation_class?`
  mirror `open_receivers` / `open_receiver?` ([ADR-26](26-activerecord-relation-typing.md)): a flat,
  de-duplicated list compiled at construction, and an exact-name membership test.
- **Descent.** `CheckRules::IvarWriteCollector` reads the class's instance `Scope::ResolutionChain`, so a
  project superclass chain (`RolesController < ApplicationController < ActionController::Base`) counts.
  An external superclass the environment cannot resolve matches by its written name, because
  rigor-actionpack leaves `ActionController::Base` undeclared on purpose. A truncated chain does not
  match.
- **Rule semantics.** A divergent write W is withheld when W's class is per-invocation, W sits in a
  public method, and every conflicting write (non-nil, a different concrete class) sits in a *different*
  public method of the same class. A write in a private or protected helper, a non-public callback
  target, `initialize`, or W's own method keeps the finding. A public callback target counts as an
  action.
- **First declaration.** rigor-actionpack declares `ActionController::Base` and `ActionController::API`.

**Criterion:** the engine stops comparing two writes only when one framework invariant keeps them out of
the same object's lifetime, and a plugin vouches for that invariant. A write that may share an invocation
with another (a helper, a callback, the constructor) stays checked. The rule does not try to prove which
helper an action reaches, so the carve-out never grows past what the declaration states.

### Working decisions

- **WD1 — a class list, not a per-class method list.** The issue's triage draft had plugins enumerate
  action methods. Public visibility already names the entry points Rails dispatches to, and the engine
  already records visibility (`Scope#discovered_method_visibility`). So the plugin states only the class
  fact, and the engine supplies the method fact.
- **WD2 — an unsettled visibility is not public.** A slot the discovery table lacks or contests, and
  `initialize` / `respond_to_missing?` and the other implicitly private hooks, are treated as shared by
  every invocation. An unproved premise keeps the finding.
- **WD3 — a narrowing of one rule, not a general suppression hook.** The field feeds
  `def.ivar-write-mismatch` alone. A general "plugin declines engine rule X" hook is out of scope (#575).

## Rejected alternatives

| Option | Why rejected |
| --- | --- |
| **B — a value object per action** (plugins publish per-action write scopes as an ADR-9 fact, or as an `actions:` list per class constraint) | More contract surface for the same answer. Plugins would re-derive the visibility the engine already knows, and two mechanisms (fact store and rule) would have to agree on what an action is. |
| **C — status quo** (leave the firings in each project's acknowledge-mode baseline) | Keeps a false positive on correct code in every Rails project, and the count grows with each precision lever. That inverts the false-positive discipline ([ADR-0](0-concept.md), [ADR-5](5-robustness-principle.md)). |
| Degrade the Relation type in the plugin | Trades real precision for silence on an unrelated rule; #575 calls it the wrong trade. |

## Consequences

- The redmine and gitlab public-action firings drop out. Divergences that involve a helper, a callback,
  the constructor or one action keep firing, so the rule's true positives stay.
- A private helper that genuinely runs in only one action still reports. Proving helper reach (option
  A2 in #575) is deferred.
- rigor-actionmailer (a mailer instance also serves one action) can adopt the field without an engine
  change. That is a follow-up.
- The manifest's `to_h` gains a key, so each plugin's cache identity moves once.

## Relationship to other ADRs

- [ADR-2](2-extension-api.md) — the manifest is the plugin contract. This adds one optional, additive
  field to it.
- [ADR-26](26-activerecord-relation-typing.md) — `open_receivers:` is the shape copied here: a
  plugin-vouched class list that only withholds findings.
- [ADR-50](50-release-engineering-and-stability-strategy.md) and
  [ADR-60](60-pre-freeze-plugin-contract-consolidation.md) — the contract freezes at v1.0.0. An additive
  field before then is within the pre-1.0 trial. It avoids the defect ADR-60 removed `external_files:`
  for, a field with no engine consumer: this one has a consumer from day one.
- [ADR-38](38-additional-initializers.md) — the sibling lifecycle fact. Additional initializers say "this
  method runs before the others"; per-invocation classes say "these methods never share an instance".
- [ADR-0](0-concept.md) / [ADR-5](5-robustness-principle.md) — false positives on correct programs
  outrank worst-case reading, and that is what justifies the carve-out.
