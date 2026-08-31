# rubocop-ast — opacity attribution (2026-09-01)

Target: /Users/megurine/repo/ruby/rigor-survey/rubocop-ast (paths: lib)

## Numbers

| metric | value |
| --- | --- |
| files | 101 (0 parse errors) |
| expressions | 11,433 |
| precision | 65.58% (constant 5226, nominal 1775, shaped 368, refined 18, bot 111; opaque 3935) |
| protection | 26.04% (371/1425; lower_bound_typed 1) |
| cause_site_counts | unsupported_syntax 435 (41.3%), none 317 (30.1%), inferred_return_untyped 289 (27.4%), external_gem_without_rbs 12 (1.1%), explicit_untyped 1 |
| tractability | engine_gap 724, add_rbs 13 |

Opaque split: calls 1974 (50.2% of opaque), local reads 868 (def_param 472 / block_param 152 / assigned_local 244), ivars 91, ConstantPathNode 72, EmbeddedStatementsNode 183.
Call receiver tiers: precise 60, dynamic 993, implicit_self 921. Named-receiver-opaque pairs: only 60 sites — the story here is implicit-self and dynamic-receiver, not named receivers.

## The single root: `class Node < Parser::AST::Node`

`RuboCop::AST::Node < Parser::AST::Node` (lib/rubocop/ast/node.rb:21). The `parser`/`ast` gems have no RBS in the environment, so the ancestor chain of the class that ~80 of the 101 files subclass stops dead. Every inherited send — `children` (37), `type` (53), `loc` (46), `parent` (27), `to_a`, `source` — is unresolved, and `alias node_parts to_a` (node.rb:291) forwards to the missing superclass so all 62 `node_parts` sends are Dynamic too. Everything downstream (`node_parts[1]` in alias_node.rb:13, `in_pattern_branches.map(&:body)` in case_match_node.rb:39) is C-propagation of that one B hole.

**Attribution bug worth reporting:** cause_site_counts tags only 12 sites `external_gem_without_rbs` while realistically several hundred trace to the parser/ast gems. The ADR-82 WD9 tagging keys on the *constant read* of a no-RBS gem; a send that reaches the gem through an unresolvable *superclass* of a project class (receiver types Nominal fine) falls back to generic `unsupported_syntax`. That is why unsupported_syntax is 41.3% here: it is mostly missing-gem-RBS in disguise, not grammar.

## Cases

1. **Inherited parser/ast methods (`node_parts` 62, `type` 53, `loc` 46, `children` 37, `parent` 27, `source` 22, ...) — ~300+ implicit-self sites — B.**
   Mechanism above. Verified: no `def children`/`def type`/`def loc` in rubocop-ast's lib for Node (only `type?` node.rb:174, whose body calls the inherited `type` → return Dynamic). Fix: `parser` + `ast` RBS via gem_rbs_collection / `libraries:`; engine-side, carry the `external_gem_without_rbs` cause through an unresolvable superclass constant so the protection lens routes these to add_rbs instead of engine_gap.

2. **NodePattern macro-generated matchers (`def_node_matcher` 19, `def_node_search`) — E.**
   rubocop-ast's own compile-to-method DSL; callers of the generated matchers dispatch Dynamic. Plugin territory (recognizer for the NodePattern compiler), same shape as Rails scopes. Example: lib/rubocop/ast/node.rb uses def_node_matcher throughout.

3. **`def_callback` class-macro invocations — 24 sites — E/G.**
   lib/rubocop/ast/traversal.rb:38 defines the macro; lines 133+ invoke it at class-body level to generate `on_*` visitor methods. The opaque sites are the macro *calls themselves* (class-body expressions), not downstream value uses — half metric artifact, half DSL.

4. **rexical-generated lexer state (`ss` 32, `LexerRex#ss=/#state=/#filename=`, `action`, `emit`) — A-family (known ivar roadmap).**
   lib/rubocop/ast/node_pattern/lexer.rex.rb:43-53 `attr_accessor`; control (same file): `attr_accessor :ss; self.ss = 5; ss` → Dynamic — the accessor resolves to an untyped @ivar, ADR-58 territory. Compounded: the assigned value `scanner_class.new str` needs StringScanner RBS (`strscan` not in `libraries:`) → B.

5. **Singleton attr_reader over class-level ivar (`Subcompiler.registry`, `self.class.registry.fetch`) — A-family/known.**
   lib/rubocop/ast/node_pattern/compiler/subcompiler.rb:35-41 (`@registry = {}`, `class << self; attr_reader :registry`). Control `B.registry` → Dynamic. Class-level ivar typing (ADR-58 WD1 covers cross-file class_ivars — this one flows through `class << self` + attr_reader, still Dynamic).

6. **Optional receiver `Array[Thread::Backtrace::Location]?#first` — 2 sites — D (repeat).**
   lib/rubocop/ast/node_pattern/method_definer.rb:51 (`caller_locations.first`): same nilable-receiver dispatch gap verified on concurrent-ruby.

7. **Bare/`Hash[Dynamic,Dynamic]#[]` (10) and Dynamic-tuple `#[]` — C.** Container-of-Dynamic reads.

8. **F unsupported_syntax 435 (41.3%).** Sampled: dominated by unresolved sends/constant paths into parser/ast (ConstantPathNode 72 opaque; `Parser::Source::Range`, `Parser::AST::Node`). Not grammar-level constructs — see the attribution bug above.
