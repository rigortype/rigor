# ADR-125 — Plugin-declared per-invocation classes

Status: **Accepted, 2026-10-22.** The maintainer chose this design (option A) for v0.4.6 on #575. Two
manifest fields, the `Registry` aggregates, the narrowed `def.ivar-write-mismatch` and rigor-actionpack's
declarations land together for #575. rigor-actionmailer's declaration followed in #2308.

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

The engine cannot see this on its own. Whether an instance serves one entry point, and which methods are
entry points, are framework facts, and the plugin that models the framework is where Rigor keeps
framework facts ([ADR-2](2-extension-api.md)).

## Decision

A plugin may declare **per-invocation classes**: classes whose every instance serves exactly one entry
point, an *action*. Ivar writes in two distinct actions of such a class (or a descendant) are never live
together.

An action is what the maintainer's A1 decision on #575 says it is: a public instance method that no
callback macro (`before_action`, `after_action`, `around_action` and their `prepend_`, `append_` and
`skip_` forms) and no `helper_method` names.

- **Manifest fields.**
  - `per_invocation_classes: [String]` lists class names. Validation requires an Array of non-empty
    Strings, and a leading `::` is dropped (`Plugin::Manifest`).
  - `per_invocation_non_action_macros: [Symbol]` lists the class-body macros whose literal Symbol / String
    arguments name a method that is not an action. They apply to the same manifest's classes, so a list
    without classes is refused.
- **Aggregates.** `Registry#per_invocation_classes` and `#per_invocation_class?` mirror `open_receivers` /
  `open_receiver?` ([ADR-26](26-activerecord-relation-typing.md)): a flat, de-duplicated list compiled at
  construction and an exact-name membership test. `Registry#per_invocation_non_action_macros(name)`
  answers the macros of the manifests that declare `name`.
- **Descent.** `CheckRules::IvarWriteCollector` reads the class's instance `Scope::ResolutionChain`, so a
  project superclass chain (`RolesController < ApplicationController < ActionController::Base`) counts.
  - An external superclass the environment knows matches by name or by an RBS `:subclass` ordering.
  - One it cannot resolve matches by its written name, because rigor-actionpack leaves
    `ActionController::Base` undeclared on purpose. That fallback is skipped when any candidate spelling
    names a class the project declares (`MyApp::ActionController::Base`).
  - A truncated chain does not match.
- **Actions.** The collector records each write's enclosing method, its visibility, and the names the
  declared macros spell in a class body of the same file: Symbol and String arguments and an inline
  `def` (`helper_method def current_user`). A write is in an action when its method is
  public and no such macro names it.
- **Rule semantics.** A divergent write W is withheld when W sits in an action and every conflicting write
  (non-nil, a different concrete class) sits in a *different* action of the same class.
- **First declaration.** rigor-actionpack declares `ActionController::Base` and `ActionController::API`,
  and the twelve callback macros plus `helper_method`.

**Criterion:** the engine stops comparing two writes only when a framework invariant keeps them out of
the same object's lifetime and a plugin vouches for that invariant. Each of these may run inside any
action, so a conflicting write in one keeps the finding:

- a private or protected method;
- a public method a callback macro or `helper_method` names;
- `initialize`;
- W's own method.

The rule does not try to prove which helper an action reaches, so the carve-out never grows past what
the declarations state.

### Working decisions

- **WD1 — the plugin names the class and the non-action macros; the engine names the methods.** Rails
  dispatches only to public methods, and the engine already records visibility
  (`Scope#discovered_method_visibility`). What visibility cannot say is that a public method is a
  callback or a view helper. The plugin knows which macros declare those, so it lists them as data, and
  the engine reads their literal arguments. A per-class action list would need project knowledge that a
  static manifest cannot carry.
- **WD2 — an unsettled visibility is not public.** A slot the discovery table lacks or contests (#2013),
  and `initialize` / `respond_to_missing?` and the other implicitly private hooks, are treated as shared by
  every invocation. An unproved premise keeps the finding.
- **WD3 — a companion field, not a value object.** The precedent weighed against is
  [ADR-38](38-additional-initializers.md)'s `additional_initializers:`, a list of
  `{ receiver_constraint:, methods: }` value objects. The question it answers per entry is "which methods
  of this class". Here the macros are a property of the framework the plugin models, the same for every
  class it declares, so one list per manifest says it once. The field is tied to its manifest's
  classes, so one plugin's macros never apply to another plugin's classes. A value object stays available
  if a plugin ever needs different macros per class.
- **WD3a — the name says `macros`, not `methods`.** ADR-38's `methods:` lists the methods that are
  initializers. These entries are not the non-action methods; they are the class-body calls whose
  arguments name them. `per_invocation_non_action_macros` keeps that indirection visible.
- **WD4 — a narrowing of one rule, not a general suppression hook.** The fields feed
  `def.ivar-write-mismatch` alone. A general "plugin declines engine rule X" hook is out of scope (#575).

## Rejected alternatives

| Option | Why rejected |
| --- | --- |
| **B — a value object per action** (plugins publish per-action write scopes as an ADR-9 fact) | More contract surface for the same answer. Two mechanisms (the fact store and the rule) would have to agree on what an action is, and a fact is per-project data the rule would need ordering for. |
| **C — status quo** (leave the firings in each project's acknowledge-mode baseline) | Keeps a false positive on correct code in every Rails project, and the count grows with each precision lever. That inverts the false-positive discipline ([ADR-0](0-concept.md), [ADR-5](5-robustness-principle.md)). |
| Every public method is an action | Silences a divergence between an action and a public `before_action` target or `helper_method`, which do run inside the action. |
| Degrade the Relation type in the plugin | Trades real precision for silence on an unrelated rule; #575 calls it the wrong trade. |

## Consequences

- The redmine and gitlab public-action firings drop out. The findings listed under the Criterion keep
  firing, and so do two writes in one action.
- **Known silent cases.** Neither is reported:
  - an action that calls another action (`def show; index; @roles = {…}; end`), because both methods are
    actions;
  - a public callback target or `helper_method` named by a macro in another file (a reopening, a concern,
    or `ApplicationController`), because macro arguments are read from the file that holds the writes;
  - a public method a callback reaches through a block or lambda (`before_action -> { load_roles }`),
    because only literal names count: a Symbol, a String or an inline `def`.
- **Known limits that keep firing.** These are conservative:
  - a private helper that genuinely runs in only one action (proving helper reach, option A2 in #575, is
    deferred);
  - actions defined in a module, such as an `ActiveSupport::Concern` included into a controller, because
    the writes belong to the module;
  - a controller on `ActionController::Metal`, which is not declared.
- rigor-actionmailer (a mailer instance also serves one action) adopted the fields in #2308 without an
  engine change.
- The manifest's `to_h` gains two keys, so each plugin's cache identity moves once.

## Relationship to other ADRs

- [ADR-2](2-extension-api.md) — the manifest is the plugin contract. This adds two optional, additive
  fields to it.
- [ADR-26](26-activerecord-relation-typing.md) — `open_receivers:` is the shape copied here: a
  plugin-vouched class list that only withholds findings.
- [ADR-50](50-release-engineering-and-stability-strategy.md) and
  [ADR-60](60-pre-freeze-plugin-contract-consolidation.md) — the contract freezes at v1.0.0. Additive
  fields before then are within the pre-1.0 trial. They avoid the defect ADR-60 removed `external_files:`
  for, a field with no engine consumer: these have a consumer from day one.
- [ADR-38](38-additional-initializers.md) — the sibling lifecycle fact. Additional initializers say "this
  method runs before the others"; per-invocation classes say "these methods never share an instance".
- [ADR-0](0-concept.md) / [ADR-5](5-robustness-principle.md) — false positives on correct programs
  outrank worst-case reading, and that is what justifies the carve-out.
