# Redmine opacity attribution (2026-09-01)

Target: /Users/megurine/repo/ruby/rigor-survey/redmine (Rails app; paths app+lib; plugins: actionpack,
activerecord, actionmailer, rails-routes, rails-i18n, activesupport-core-ext; no `libraries:` key).
Cache wiped before runs. Coverage exit code was 1 (1 parse error: a plugin generator TEMPLATE file,
`lib/generators/redmine_plugin_model/templates/migration.rb` — ERB placeholders, expected).

## Numbers

| metric | value |
| --- | --- |
| files processed | 346 (+1 parse error) |
| expressions typed | 128,495 |
| precise | 61,365 — **47.76%** official precision |
| protection | protected 9,901 / unprotected 18,366 — **35.03%** |
| tractability | engine_gap 11,034 · add_rbs 408 |

cause_site_counts (unprotected sites): none 6,924 · inferred_return_untyped 5,580 ·
unsupported_syntax 5,452 (29.7%) · external_gem_without_rbs 279 · explicit_untyped 129 · budget 2.

Opaque expression split (probe, 65,532 opaque nodes): CallNode 32,615 · LocalVariableReadNode 15,385
(def_param 6,942 + block_param 3,636 = **A/ADR-67, closed** · assigned_local 4,807) · ivar reads 2,155
(ADR-58 WD2/WD3 pending) · control-flow joins mirroring an opaque arm (If 2,573 + EmbeddedStatements
2,261 + And 1,025 + Or 677 + Parens 556 + Unless 246 + Begin 183 ≈ 7,521 = **G mirrors**) · writes
mirroring their RHS (LocalVariableWrite 2,527 + IVarWrite 848 + ...) . Call receiver tiers: Dynamic
receiver 17,635 (propagation) · implicit self 9,181 · precise receiver 5,799.

## Headline finding 1 (G, measurement): the coverage lens drops the cross-file class graph

`CoverageScan.discovery_seeded_scope` (rigor lib/rigor/cli/coverage_scan.rb:58-76) seeds ONLY
`discovered_classes` (+`param_inferred_types`). The `rigor check` runner seeds the full pre-pass trio —
`discovered_def_nodes`, `discovered_superclasses`, `discovered_includes`, `discovered_methods`,
visibilities, singleton defs (lib/rigor/analysis/runner.rb:1577-1596). Verified empirically on redmine:
the seeded coverage scope has **506 discovered_classes and 0 def_nodes / 0 superclasses / 0 includes**;
`user_def_for('ApplicationController', :render_404)` is nil in the seeded scope and non-nil only in
application_controller.rb's own per-file index. Consequence: in every coverage/protection/probe number,
**calls to user methods defined in another file (inherited methods, included user modules, sibling
classes) are measured as unresolved (`unsupported_syntax`) even though `rigor check` resolves them.**
This is the same lens-scope-mismatch family PR #505 fixed for `discovered_classes`, now for the
def-node trio, and it biases this entire corpus sweep on multi-file targets. Examples measured opaque
purely for this reason: `l` (647 implicit-self sites; def in lib/redmine/i18n.rb, included by
ApplicationController), `render_404` from subclass controllers, `scm_iconv` from SCM adapters
(bazaar_adapter.rb:106, def in abstract_adapter.rb:287 with 3 required params — bindable in-engine),
`singleton(Redmine::I18n)#t`, `singleton(Redmine::Configuration)#[]`, `User.current` (cross-file
singleton def). Fix direction: seed the same tables the runner seeds (or reuse
`project_scope_seed_tables`) in `discovery_seeded_scope`.

## Headline finding 2 (D1): the user-method binder declines every non-trivial parameter shape

`ExpressionTyper#user_method_param_shape_simple?` (rigor lib/rigor/inference/expression_typer.rb:2427-2435)
and `build_user_method_body_scope` (:2388-2392): inter-procedural user-method return inference binds ONLY
defs whose parameters are all required positionals. **Any optional, rest, keyword, keyword-rest, or block
parameter makes the tier decline**, and the dispatcher's discovered tier deliberately deferred to it
(method_dispatcher.rb:212), so the call falls all the way to `Dynamic[top]`. Verified same-file (lens gap
excluded): `render_404` (def `(options={})`) called at application_controller.rb:348 → tier=dynamic_top
cause=:unsupported_syntax with self correctly `ApplicationController`; `scm_cmd(*args, &)` same-class at
lib/redmine/scm/adapters/bazaar_adapter.rb:71 → same; `def self.accept_atom_auth(*actions)` via
`self.class` receiver at application_controller.rb:639 → same. On a Rails codebase `def m(options={})`
and `def m(*args)` are the default idiom, so this cliff is a first-order precision lever. Fix direction:
bind what matches — optionals from their default expression's type when the arg is omitted, rest as
`Array[join(remaining)]`, keywords by name from the KeywordHashNode, block param as untyped-proc — and
still infer the body instead of declining wholesale.

## Headline finding 3 (D2): the decline path mislabels its cause

When a user def IS found but the binder declines (or body inference aborts via the
`rescue StandardError` in `try_user_method_inference`, expression_typer.rb:1339), no cause is recorded
and the fall-through lands in `unresolved_call_result` → `UNSUPPORTED_SYNTAX`. ADR-82 WD2/WD3 already
routes "resolved but uninferable" to `inferred_return_untyped` for the discovered/fallback tiers
(method_dispatcher.rb:210-216); the binder-decline path escaped that rule. Cheap fix: record
`INFERRED_RETURN_UNTYPED` whenever `resolve_user_def_with_owner` found a def. This materially corrects
the cause histogram: much of redmine's 5,452-site `unsupported_syntax` block is actually inference-gap.

## unsupported_syntax construct histogram (the F deliverable)

Probe over all 19,408 opaque nodes carrying the cause (protection counts 5,452 unprotected SITES):

| construct | nodes | reading |
| --- | --- | --- |
| chain-carried (call on already-Dynamic receiver, ADR-82 WD6) | 6,309 | propagation, not introduction |
| introduction-site calls (implicit-self 9,18x + named-receiver) | 12,569 | decomposes into: cross-file user defs invisible to the lens (G above); non-simple param shapes (D1); Rails/AR/AS metaprogrammed methods — associations, scopes, `class_eval` Settings, CurrentAttributes (E); framework methods without plugin RBS (E) |
| unresolved constants (ConstantPathNode 333 + ConstantReadNode 160) | 493 | `RedmineApp::Application` (defined in config/, outside analyzed paths), gem constants (`Doorkeeper`), plugin constants |
| `x.attr ||= v` (CallOrWriteNode) | 34 | the ONLY unhandled Prism node classes in the corpus — |
| `x.attr += v` (CallOperatorWriteNode) | 3 | attribute-call compound assignment; e.g. imports_controller.rb:132 `@import.settings ||= {}`, member.rb:211 `member.role_ids |= role_ids` |

**Genuinely unmodeled Ruby syntax is 37 nodes (0.2%).** "unsupported_syntax" on redmine is ~97% exhausted
method dispatch, not syntax. The two attr-assign node classes are a trivial handler to add (type as the
RHS/mirror of the write, like the local-variable equivalents already handled).

## Classified cases (named_receiver_opaque_pairs + aggregates)

| pair / bucket | sites | cat | mechanism | example |
| --- | --- | --- | --- | --- |
| def_param + block_param local reads | 10,578 | A | ADR-67 territory, closed | — |
| `ActionController::Parameters#[]` | 581 | E | rigor-actionpack owns; params store read | app/controllers/account_controller.rb:41 |
| `singleton(User)#current` | 494 | E (+G) | `CurrentUser < ActiveSupport::CurrentAttributes`, `attribute :user` metaprogramming (user.rb:894-904); owner: rigor-activesupport-core-ext CurrentAttributes recognizer. Cross-file singleton def also hits the lens gap | app/models/user.rb:902 |
| `singleton(*)#table_name` family (Issue 137, Project 98, TimeEntry 40, Journal 32, Member 29, Changeset 28, User 22, Attachment 21, Version 19, CustomValue 19, +7 more) | ~550 | E | AR class method → String; rigor-activerecord | app/controllers/versions_controller.rb:57 |
| `ActionDispatch::Flash::FlashHash#[]=` / `#now` | 147 | E | actionpack; `[]=` also mirrors its Dynamic RHS (`l(...)`) | app/controllers/account_controller.rb:67 |
| `Redmine::Export::PDF::ITCPDF#SetFontStyle/#RDMCell/#RDMMultiCell/#ln` | 106 | B | wrappers whose bodies end in RBPDF gem calls (`set_font`→`super`, `cell`), rbpdf has no RBS (pdf.rb:48-50,72-78); measured via the lens gap (cross-file), root is B | lib/redmine/export/pdf.rb:49 |
| `Hash[Dynamic,Dynamic]#[] / #[]= / #delete`, bare `Hash#[]`, `Array[Dynamic]#[] / #last`, union-hash `#[]=` | ~195 | C | container-of-Dynamic element reads / writes mirror | app/controllers/application_controller.rb:445 |
| `singleton(Redmine::Configuration)#[]` | 32 | C (+G) | `@config[name]`, @config = YAML load (configuration.rb:82-85) — irreducible container-of-Dynamic behind an ivar | lib/redmine/configuration.rb:84 |
| `singleton(Redmine::I18n)#t` | 29 | E | rigor-rails-i18n | lib/redmine/field_format.rb:51 |
| `ActionDispatch::Request#post?/#xhr?/#get?` | 64 | E | actionpack; should be bool — cheapest wins in the E column | app/controllers/account_controller.rb:32 |
| `ActionDispatch::Request::Session#[] / #[]=` | 49 | E | actionpack; session store values inherently untyped, but the label should be honest | app/controllers/account_controller.rb:59 |
| `Redmine::Helpers::Gantt#date_from/#date_to` | 42 | D | `attr_reader` over ivar assigned `Date.civil(...)` (gantt.rb:57, 86-87); needs ADR-58 ivar-field typing WD2/WD3 + stdlib `date` RBS (config has no `libraries:` — B component unverified) | lib/redmine/helpers/gantt.rb:381 |
| AR relation/scope pairs: `singleton(Issue)#visible/#where`, `singleton(Project)#visible/#where/#allowed_to_condition/#find`, `Group#givable`, `Tracker#sorted`, `User#active/#where`, etc. | ~200 | E | AR scope DSL + relation methods; rigor-activerecord | app/controllers/issues_controller.rb:425 |
| `singleton(Setting)#default_language/#app_title/#text_formatting/#notified_events` | 70 | E | accessors generated by `class_eval` from config/settings.yml (setting.rb:336-349); out of static reach — owner would be a redmine-local plugin / pre_eval | app/models/setting.rb:349 |
| `UserPreference#[] / #[]=` | 28 | E | body reads `read_attribute(:others)` hash — AR attribute root (user_preference.rb:85-92) | app/models/user_preference.rb:92 |
| `Issue#project`, `Issue?#project`, `Issue#id`, `Version#effective_date`, `AuthSourceLdap#account`, `User#pref` | ~60 | E | belongs_to association / column accessors; rigor-activerecord | app/models/issue.rb:173 |
| `singleton(Redmine::Notifiable)#new` | 15 | D | `class Notifiable < Struct.new(:name, :parent)` — in an isolated same-file dispatch probe this FOLDED PRECISELY to `Redmine::Notifiable(name:, parent:)`, yet the corpus scan recorded the same node opaque: order/memo-dependent instability worth a look | lib/redmine/notifiable.rb:29 |
| `IssueQuery#add_filter`, `singleton(Redmine::CodesetUtil)#replace_invalid_utf8` | 17 | A (+G) | bodies are param-sourced (`{:operator=>operator,...}`, `str.dup` on the param) — ADR-67; cross-file so also lens-gap in the measurement | app/models/query.rb:747 |
| `singleton(Mailer)#deliver_security_notification` | 8 | E | ActionMailer delivery wrapper; rigor-actionmailer | app/jobs/destroy_project_job.rb:55 |
| control-flow joins + writes mirroring an opaque arm | ~11,400 | G | IfNode/AndNode/OrNode/EmbeddedStatementsNode/writes reflect their inner Dynamic — same holes double-counted | — |

## Notes

- `rigor coverage` exits 1 on this target (parse-error file); the piped `tail` in the procedure masks it.
- Probe precision (0.490) vs official (0.4776): the probe's classifier counts a few node families
  differently; official number reported above.
- Parameter inference was OFF in the probe (`parameter_inference: false`), matching the target config.
