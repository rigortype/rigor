# Mastodon opacity attribution (2026-09-01)

Target: /Users/megurine/repo/ruby/rigor-survey/mastodon (paths app+lib, 1,325 files, 0 parse errors).
Config: .rigor.dist.yml — target_ruby 3.3, plugins actionpack/activerecord/actionmailer/rails-routes/rails-i18n/activesupport-core-ext/devise/pundit/sidekiq. `parameter_inference` NOT enabled. No `libraries:` override (defaults only).

## Headline numbers

| Metric | Value |
| --- | --- |
| Expressions typed | 150,145 |
| Official precision (`rigor coverage`, plugin-free lens) | **48.9%** (73,418) |
| Probe precision (plugin-aware environment) | **52.12%** (78,260) |
| Protection (`coverage --protection`) | **33.96%** (10,599 / 31,209 receiver sites; 20,610 unprotected) |
| Tractability | engine_gap 14,611 / add_rbs 616 |

Cause split of the 20,610 unprotected sites (receiver provenance): unsupported_syntax **9,070 (44.0%)**, inferred_return_untyped 5,541 (26.9%), none 5,383 (26.1%), external_gem_without_rbs 351 (1.7%), explicit_untyped 265 (1.3%).

Opaque-expression census (probe, plugin-aware; 71,885 opaque = 47.9%):
- CallNode 39,863 — receiver tiers: implicit-self 14,797, dynamic receiver 19,864 (propagation), PRECISE receiver but Dynamic result 5,202 (1,839 distinct pairs)
- LocalVariableReadNode 11,164 — def_param 5,118 + block_param 2,507 (= 7,625 **category A**, ADR-67, closed) + assigned_local 3,539
- InstanceVariableReadNode 3,789 (ADR-58 territory)
- ConstantRead/Path 5,532
- join/mirror nodes (If/And/Or/Block/EmbeddedStatements/Begin/Parens/local+ivar writes) ~8,900 — **category G**, each mirrors an inner opaque expression

## F — the unsupported_syntax construct histogram (the top-priority deliverable)

`unsupported_syntax` on mastodon is a **misnomer bucket: 99.9% of its introductions are name-resolution misses, not syntax**. `DynamicOrigin::UNSUPPORTED_SYNTAX` is attached by the single `ExpressionTyper#fallback_for` funnel (lib/rigor/inference/expression_typer.rb:960), which is reached from three very different places: (1) a Prism node class with no PRISM_DISPATCH handler, (2) an unresolvable constant not owned by a locked RBS-less gem (expression_typer.rb:441), and (3) `unresolved_call_result` — a call that exhausted every dispatch tier (expression_typer.rb:1204). A dedicated probe (probe run over all 1,325 files; introduction-site classification mirroring `OriginLookup`) decomposes the 26,505 nodes carrying the cause:

| Construct | Nodes | Share |
| --- | --- | --- |
| Unresolved implicit-self send (DSL macros, framework helpers, concern methods) | 11,257 | 42.5% |
| Chain-inherited (ADR-82 WD6 carry — propagation, not an introduction) | 9,948 | 37.5% |
| Unresolved constant read — 1,920 child-reads inside a RESOLVING ConstantPath (artifact) + 3,284 terminal | 5,204 | 19.6% |
| Unresolved dispatch on a PRECISELY-typed receiver | 4,164 | 15.7% |
| Call on untracked-dynamic receiver | 905 | 3.4% |
| **Genuinely unmodeled Prism constructs** | **27** | **0.1%** |

(Shares overlap the 26,505 total because chain-inherited double-counts introductions downstream.)

The complete unmodeled-syntax list on this 1,325-file Rails app: `CallOperatorWriteNode` (`uri.path += '/'`, app/lib/content_security_policy.rb:56) — 20 nodes; `CallOrWriteNode` (`self._named_contexts ||= {}`, app/lib/activitypub/serializer.rb:8) — 7 nodes. Nothing else. Implication: renaming/splitting the cause (`unresolved_name` vs `unsupported_syntax`) would change the protection report's story from "44% intractable syntax" to "40+% name-resolution engine gaps", which routes to mechanisms below.

Top unresolved implicit-self sends: object 875 (AMS serializers + SimpleForm inputs), before_action 593, render 379, current_account 320, authorize 317 (Pundit), scope 228, options 212, belongs_to 201, attributes 198, current_user 196, validates 193, has_many 188, redirect_to 185, say/option (thor CLI) 284, redis 153.

Top terminal unresolved constants: Api 184, ActiveModel 165, Sidekiq 117, Api::V1 116, ActiveRecord::RecordNotFound 115, Addressable 106, Addressable::URI 99, ActiveModel::Serializer 98, Sidekiq::Worker 97, ActiveSupport 96, REST 90, ActiveSupport::Concern 87. Three families: Zeitwerk implicit namespace modules (Api, REST — no `module X` exists anywhere in source), rails-family/gem constants that the loaded plugins don't declare, and true no-RBS gems (Addressable, Sidekiq) that SHOULD carry `external_gem_without_rbs` but the ADR-82 WD9 missing-gem index did not claim (labeling gap).

## Classified cases

Categories: A param-sourced (closed) · B missing RBS · C container-of-Dynamic · D engine dispatch gap · E plugin territory · F unsupported syntax · G metric artifact. Every D was verified by a controlled dispatch experiment in the mastodon plugin-aware environment (mastodon_dispatch_controls.rb / controls2 / controls3 in scratchpad).

| # | Pair / bucket | Sites | Cat | Mechanism | Example |
| --- | --- | --- | --- | --- | --- |
| 1 | def/block param local reads | 7,625 | A | ADR-67; note `parameter_inference` is OFF in this target's config | — |
| 2 | ActionController::Parameters#[] (+#expect 63, #slice 38, Request#format 21, Session#[] 17, FlashHash#[]= 29) | 475+ | E | rigor-actionpack types `params` as an RBS-less lenient nominal and re-types only require/permit/permit! chains; `[]`/`expect`/`slice` fall to Dynamic. Fix: extend STRONG_PARAMS_CHAIN_METHODS (actionpack.rb:208) with expect/slice/[] → Parameters, same FP-safety argument | app/controllers/accounts_controller.rb:28 |
| 3 | singleton(ActivityPub::TagManager)#instance + FeedManager/TagManager/... | ~380 | **D** | `include Singleton` on a discovered class: stdlib singleton.rbs declares `def self.instance: () -> instance` (references/rbs/stdlib/singleton/0/singleton.rbs:101) and `singleton` IS in DEFAULT_LIBRARIES, but discovered-class singleton dispatch never applies the RBS module-self-method transfer through the discovered `include` list. Fix: in the singleton tier, walk discovered includes into RBS modules, resolve `def self.` members with `instance` bound to the includer | app/lib/activitypub/tag_manager.rb:4 (verified control: Dynamic/unsupported) |
| 4 | singleton(Rails)#configuration 108 / #cache 81 / #logger 50 / #application 22 | 261 | E | `Rails` resolves to singleton(Rails) via a loaded plugin but no plugin declares these readers. Owner: rigor-rails / rigor-railties (logger → lenient Logger nominal, cache → lenient Cache::Store nominal, configuration/application → lenient nominals) | app/controllers/api/base_controller.rb:95 |
| 5 | Hash#[] 61, Hash[Dynamic,Dynamic]#[]= 23, Hash[Symbol,...|Dynamic]#[]= 22 | ~106 | C | unparameterized/Dynamic-valued Hash lookup propagates Dynamic | app/helpers/json_ld_helper.rb:30 |
| 6 | 1#day 47, 1#hour 25, 5#minutes 23, 3#minutes 22, 30#seconds 19, ... | ~265 | E | rigor-activesupport-core-ext deliberately declares Duration multipliers `-> untyped` (core_ext.rbs:304, cause = explicit_untyped). Fix: declare `ActiveSupport::Duration` as a lenient RBS-less nominal, Parameters-style | app/controllers/about_controller.rb:9 (control: origin=:explicit_untyped) |
| 7 | Account?#id 57, Account?#user 25 (optional receivers generally) | ~100+ | **D** | dispatch does not project through `T \| nil`: control shows `Account.new.id → Integer` (AR schema reader works) while the identical call on `Account \| nil` → Dynamic/unsupported. Fix: distribute dispatch over union constituents and join, with the nil arm handled per severity profile | app/controllers/admin/account_actions_controller.rb:25 |
| 8 | singleton(ActivityPub::DeliveryWorker)#perform_async 24, LocalNotificationWorker 22, +workers | ~90 | E | rigor-sidekiq discovers workers but does not type `perform_async` (→ String jid) | app/lib/activitypub/activity/feature_request.rb:61 |
| 9 | singleton(Account)#without_suspended 19 (+ concern-declared scopes generally) | 19+ | E | rigor-activerecord's model index folds scopes from the model file but NOT from a concern's `included do` block — `scope :without_suspended` lives in app/models/concerns/account/suspensions.rb:9. Fix: model index folds `included do` bodies of discovered concerns | app/controllers/activitypub/replies_controller.rb:33 (verified control) |
| 10 | UnfollowService#call 17, ResolveAccountService#call 16, Request#perform 18 (service objects) | ~100+ | **D** | the discovered tier declines because `user_def_for` holds a re-typable body (method_dispatcher.rb:315), body inference then declines on the block-taking tail (`with_redis_lock(...) { ... }`), and the site falls to `unresolved_call_result` → **mislabeled unsupported_syntax instead of inferred_return_untyped**. Fixes: (a) record inferred_return_untyped when a user def existed; (b) type a yield-and-return helper tail as the block's value | app/services/unfollow_service.rb:13 (verified control) |
| 11 | concern-included instance methods (Account.new.suspended? control) | large multiplier | **D** | a module-level `def` in an `extend ActiveSupport::Concern` module included by the model answers Dynamic/unsupported while same-class schema readers resolve — concern-method resolution/inference declines and carries the same mislabel as #10 | app/models/concerns/account/suspensions.rb:12 (verified control) |
| 12 | literal-string#squish | 28 | **D** | receiver-tier inconsistency: `'a b'.squish → String` (plugin RBS attaches) and single-line heredoc resolves, but the SAME Constant[String] produced by folding a multi-line heredoc (InterpolatedStringNode, multi-fragment) dispatches to Dynamic/unsupported. Minimal repro in mastodon_controls3.rb; `.upcase` on the same receiver folds fine, so it is squish's RBS-tier path after the constant-fold miss | app/helpers/formatting_helper.rb:4 |
| 13 | unresolved constants — child-of-resolving-path | 1,920 | G | inner `ConstantReadNode` of a ConstantPath that itself RESOLVES (`REST` inside `REST::AccountSerializer`) counted as its own opaque expression | app/controllers/api/v1/accounts/credentials_controller.rb:10 |
| 14 | unresolved constants — Zeitwerk implicit namespaces (Api 184, Api::V1 116, REST 90, +) | ~500 | **D** | no `module Api` exists in source (directory-derived). Engine already synthesizes missing-namespace stubs (ADR-5 stub tier) but not for namespaces implied by discovered compact class names. Fix: synthesize namespace modules from the discovery index's compact-name prefixes | app/controllers/activitypub/base_controller.rb:3 |
| 15 | unresolved constants — rails-family (ActiveModel 165, AR::RecordNotFound 115, AS::Concern 87, AR::Base 50, Arel 35, ActionController 37) | ~600 | E | owning plugins (rigor-activerecord / activesupport-core-ext / actionpack) should declare their framework's own top constants; RecordNotFound in a `rescue` clause is the modal use | app/controllers/activitypub/feature_authorizations_controller.rb:26 |
| 16 | unresolved constants — no-RBS gems (Sidekiq 214, Addressable 240, ActiveModelSerializers 54, Doorkeeper 30) | ~550 | B | true missing-RBS gems, but labeled unsupported_syntax because `missing_rbs_gem_owner` (ADR-82 WD9) did not claim them — a cause-labeling gap worth its own look; OpenSSL 36 → add `openssl` to `libraries:` | app/workers/account_deletion_worker.rb:4 |
| 17 | implicit-self DSL macros (before_action 593, validates 193, belongs_to 201, has_many 188, scope 228, attribute(s) 313, sidekiq_options 79, ...) | ~2,500 | E | class-level macro sends; owning plugins actionpack/activerecord/sidekiq could declare them (mostly statement-position, so precision-only impact) | app/controllers/accounts_controller.rb:12 |
| 18 | implicit-self controller/serializer helpers (object 875, render 379, current_account 320, authorize 317, current_user 196, redirect_to 185, redis 153) | ~2,400 | E/D | `object` → no AMS/SimpleForm plugin exists (largest single implicit-self method); authorize → rigor-pundit loaded but silent; current_user → rigor-devise loaded but silent; current_account/redis are app concern methods → same D as #11 | app/inputs/date_of_birth_input.rb:47 |
| 19 | CallOperatorWriteNode 20 + CallOrWriteNode 7 | 27 | **F** | the ONLY genuinely unmodeled syntax in 1,325 files: attribute op-assign `x.a += v` / or-assign `x.a \|\|= v` | app/lib/content_security_policy.rb:56 |
| 20 | join/mirror nodes (IfNode 1,760, BlockNode 1,779, LVarWrite 1,557, EmbeddedStatements 1,025, OrNode 971, AndNode 881, ...) | ~8,900 | G | mirror an inner opaque expression; not independent holes | — |
| 21 | opaque ivar reads | 3,789 | closed | ADR-58 territory (WD1 landed; cross-file class_ivars closed) | — |

## Surprises

1. **The 44% unsupported_syntax share is almost entirely mislabeled name-resolution misses** — 27 genuinely unmodeled syntax nodes in the whole app. The single largest correction available to the protection report is provenance taxonomy, not new syntax support.
2. Cases #10/#11: when the discovered tier defers to body inference and inference declines, the honest `inferred_return_untyped` label is lost — every service-object `#call` in mastodon reports as "unsupported syntax".
3. The multi-line-heredoc `#squish` receiver bug (#12) is a crisp, minimal, reproducible dispatch inconsistency.
4. ADR-82 WD9's missing-gem index misses Sidekiq/Addressable/Doorkeeper here, so `external_gem_without_rbs` under-reports (351 vs ~900 plausible).
5. `parameter_inference` is off in this target's config, so the A bucket (7,625 reads) is larger than it needs to be.

Instruments (scratchpad): probe_attrib.rb → mastodon.probe.json; probe_unsupported.rb (since overwritten by a sibling agent; results preserved) → mastodon.unsupported.json; mastodon_dispatch_controls.rb, mastodon_controls2.rb, mastodon_controls3.rb; mastodon.protection.json.
