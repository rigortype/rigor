# textbringer — opacity attribution (2026-09-01)

Archetype: project shipping its own handwritten `sig/` RBS. Config: `.rigor.dist.yml` (paths `lib`, signature_paths `sig`), auto-discovered.

## Numbers

| metric | value |
| --- | --- |
| files | 77 |
| expressions | 32923 |
| precision | 66.52% (precise 21900 / opaque 11023) |
| tiers | constant 13121, nominal 7170, shaped 1041, refined 38, bot 530, dynamic_top 11009, top 14 |
| protection | 52.14% (protected 3277 / unprotected 3008) |
| cause_site_counts | none 1628, unsupported_syntax 692, inferred_return_untyped 632, explicit_untyped 56 |
| tractability | engine_gap 1324, add_rbs 56 |

Opaque split: calls 4372 (receiver: dynamic 2921, implicit_self 734, precise 717), local reads 2591 (block_param 1093, assigned_local 1055, def_param 443), ivar reads 1079, BlockNode 627, LocalVariableWrite 511, ConstantRead 405, control-flow joins (If/Or/And) 568, EmbeddedStatements 118 (G mirror), ClassVariableRead 116.

## Attribution split (approximate, by site)

- A (param-sourced, ADR-67, CLOSED): 1536 direct (block_param + def_param) + most of assigned_local 1055 downstream.
- B (missing RBS — dominated by textbringer's OWN sig/ incompleteness): ~600+ direct sites incl. the two biggest dynamic-receiver cascades (Theme DSL, GLOBAL_MAP).
- C (container-of-Dynamic): ~90 among precise-receiver pairs (Hash[Dynamic]/Array[Dynamic] element reads).
- D (engine dispatch gaps, verified): attribute-write result typing (~45+), refinement self-binding (14), module_function singleton lift (10+), optional-receiver dispatch (~20).
- E (framework/DSL): define_command block self-rehoming (the ~692 "unsupported_syntax" sites — see F/G note).
- ivars 1079: ADR-58 pipeline (WD1 landed, WD2/3 pending) — known, not re-derived.

## Classified cases

1. **Buffer attr_* getters — `Buffer#point` 34, `#file_name` 23, `#mode` 10, `#name` 10, `#keymap` 8, `#keymap=` 8 (93 sites) — B (own sig/).** `sig/lib/textbringer/buffer.rbs` declares only the `name=`/`file_name=` setters (lines 275/278); every attr_reader getter is absent, so the discovered-method tier deliberately answers Dynamic[Top] (the §6 FP-suppression trade in docs/notes/20260601-textbringer-coverage-survey.md). Example: /Users/megurine/repo/ruby/rigor-survey/textbringer/lib/textbringer/commands/buffers.rb:77. Confirms the prior finding: the coverage ceiling of an own-RBS project is its RBS completeness.
2. **Attribute-write result typing — `{}#[]=` 25, `Mark#location=` 7, plus `[]=`/setter share of dynamic-receiver bucket (`[]=` 32) — D (verified).** Ruby defines the value of `x[k] = v` / `x.attr = v` as the RHS, independent of dispatch. Rigor types the whole ATTRIBUTE_WRITE CallNode Dynamic even with a precise receiver and precise RHS: at /Users/megurine/repo/ruby/rigor-survey/textbringer/lib/textbringer/commands/ispell.rb:101 (`ISPELL_STATUS[:recursive_edit] = false`, ISPELL_STATUS = {} same file line 78), `type-of :101:20` answers `Prism::CallNode → Dynamic[top]` while the receiver types `{}` and the RHS `false`. Fix: evaluate attribute-write CallNodes to their RHS argument type syntactically (dispatch still runs for diagnostics); FP-free since it only adds precision on the expression value.
3. **Theme DSL cascade — `singleton(Theme)#define` 8 + dynamic-receiver `color` 236, `face` 200, `palette` 13 — B.** `Textbringer::Theme` has no .rbs at all (no sig/lib/textbringer/theme.rbs); `Theme.define "x" do |t| … t.palette :dark do |p| p.color …` makes t/p untyped block params, cascading over the whole themes/ directory. A sig entry with a block signature (`def self.define: (String) { (Theme) -> void } -> void`) closes ~450 sites. Example: /Users/megurine/repo/ruby/rigor-survey/textbringer/lib/textbringer/themes/catppuccin.rb:7.
4. **`GLOBAL_MAP.define_key` — 216 dynamic-receiver sites — B/E (metaprogrammed constant).** GLOBAL_MAP is created by `define_keymap :GLOBAL_MAP` (const_set macro, /Users/megurine/repo/ruby/rigor-survey/textbringer/lib/textbringer/keymap.rb:111) and sig/keymap.rbs declares the method but NOT the constant, so the ConstantRead is Dynamic and every define_key cascades. Cheapest close: `GLOBAL_MAP: Textbringer::Keymap` in sig (B); engine-side const_set folding is metaprogramming steered to plugins by policy.
5. **Container-of-Dynamic — `Hash[Dynamic,Dynamic]#[]` 31, `#[]=` 10, `Array[Dynamic]#[]` 19, `#first` 8, `#last` 6, bare `Array#[]` 9 — C.** Element reads of containers whose element type is already Dynamic; root is upstream (params/ivars). Example: /Users/megurine/repo/ruby/rigor-survey/textbringer/lib/textbringer/buffer.rb:363.
6. **`Controller?#overriding_map=` — 11 — B (+D note).** `attr_accessor :overriding_map` (controller.rb:7) is absent from sig/controller.rbs; receiver is `Controller.current: () -> Controller?` so even with RBS the optional receiver needs the D mechanisms (optional-receiver dispatch or case 2's setter-RHS rule, which closes it without RBS). Example: /Users/megurine/repo/ruby/rigor-survey/textbringer/lib/textbringer/commands/completion.rb:85.
7. **`{}#[]` — 10 — known design, not a gap.** KEYBOARD_MACROS = {} is mutated elsewhere, so the open-HashShape read reads untyped — the settled PR #249 contract. Example: /Users/megurine/repo/ruby/rigor-survey/textbringer/lib/textbringer/commands/keyboard_macro.rb:72.
8. **`singleton(Utils)#message` — 10 — D (module_function singleton lift).** utils.rb has `module_function` at module top (line 7); sig/utils.rbs declares `def message: (String, …) -> nil` instance-side only. A `Utils.message(…)` singleton dispatch finds nothing though both the source directive and the instance signature are in view. Fix: when the source marks a method module_function (or the module has a module-scope `module_function` directive), mirror the RBS instance signature onto the singleton (rbs `self?.` semantics). Example: /Users/megurine/repo/ruby/rigor-survey/textbringer/lib/textbringer/lsp/client.rb:48.
9. **`DabbrevExtension#[]` 7 / `#[]=` 7 — D (refinement self-binding).** The sites are `self[:dabbrev_stem]` inside `refine Buffer do … end` (/Users/megurine/repo/ruby/rigor-survey/textbringer/lib/textbringer/commands/dabbrev.rb:5,43). Rigor types self as the enclosing module `DabbrevExtension`; inside a refine-block self is the refined class, and `Buffer#[]`/`#[]=` ARE declared in sig/buffer.rbs (lines 31/144) — with the correct self-binding both resolve. Fix: bind self inside `refine C do` bodies to C.
10. **`String?#sub` — 6 — D (optional-receiver dispatch).** `class_name.slice(/…/)` yields String?; `.sub` on the union answers Dynamic instead of the String-arm result. Example: /Users/megurine/repo/ruby/rigor-survey/textbringer/lib/textbringer/global_minor_mode.rb:29. Fix direction: dispatch on `T?` receivers via the non-nil arm for the RESULT type (nil-arm handling stays a diagnostic concern).
11. **`singleton(Clipboard)#copy` — 8 — B (gem without RBS).** clipboard gem ships no RBS. Example: /Users/megurine/repo/ruby/rigor-survey/textbringer/lib/textbringer/commands/clipboard.rb:25.
12. **unsupported_syntax 692 (23% of causes) — F, and it is NOT syntax.** Among all opaque nodes only ONE node class lacks a PRISM_DISPATCH handler: `CallOperatorWriteNode`, 5 sites (`x.attr += v`). The remaining ~687 route through `unresolved_call_result` (lib/rigor/inference/expression_typer.rb:1204) — implicit-self calls the closed world cannot resolve, dominated by `define_command do … end` bodies (`message` 58, `number_prefix_arg` 25, `read_from_minibuffer` 23, `with_target_buffer` 21 …). Mechanism: `define_command` re-homes its block via `Commands.send(:define_method, name, &block)` (commands.rb:30), so the body's runtime self is a Commands INCLUDER; lexically self is the Commands module object, and `include Utils`'s instance methods do not apply to it. Classification: E (a textbringer-DSL plugin declaring the block self-type closes ~700 sites), with a D sliver — direct `define_method(name, &block)` self-rebinding is core-eligible. TAXONOMY ARTIFACT worth fixing: these closed-world-unresolved dispatches are counted as `unsupported_syntax`, which overstates "unmodeled syntax" in every protection report.
13. **Ivar reads — 1079 — known (ADR-58).** Counted, not re-derived; WD2/WD3 remain the lever.
14. **Local reads — block_param 1093 + def_param 443 — A (ADR-67, CLOSED).** assigned_local 1055 is mostly downstream cascade of A/B roots.
15. **G — EmbeddedStatements 118 + If/Or/And joins 568** mirror their inner expressions' opacity; no independent mechanism.
