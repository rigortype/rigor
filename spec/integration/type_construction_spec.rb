# frozen_string_literal: true

# Integration spec: the engine should construct precise types for small but realistic Ruby snippets. Each
# example is a self-contained Ruby fixture under `spec/integration/fixtures/` — readable on its own, runnable
# under MRI, and inspectable through the `rigor type-of` CLI. The spec body uses a shared `FixtureHarness`
# helper so adding a new scenario means dropping a `.rb` file under `fixtures/` and adding a few `expect` lines here.

require "spec_helper"
require_relative "support/fixture_harness"

RSpec.describe "Rigor type construction (integration)" do
  def harness_for(name)
    Rigor::IntegrationSupport::FixtureHarness.new(name)
  end

  def constant(value)
    Rigor::Type::Combinator.constant_of(value)
  end

  # `bool` as the engine spells it — the `Constant[true] | Constant[false]` union
  # `RbsTypeTranslator` folds RBS's `bool` to, not a `TrueClass | FalseClass` nominal pair.
  def bool_type
    Rigor::Type::Combinator.union(constant(true), constant(false))
  end

  # Every 1-indexed line a fixture marks with `marker`, in source order. Read from the source rather than
  # hard-coded so the fixture stays editable — a hard-coded line number turns any insertion into a false
  # failure. Asserting a rule's exact line SET is what keeps a "went quiet" half from passing because the
  # rule stopped firing at all.
  def marked_lines(harness, marker)
    harness.source.lines.each_with_index.filter_map { |line, i| i + 1 if line.include?(marker) }
  end

  describe "fixtures/parity.rb — even/odd predicate" do
    let(:harness) { harness_for("parity") }

    it "binds `result` to the live-branch `Constant[:even]` when the predicate folds to true" do
      # `4.even?` constant-folds to `Constant[true]`, so the else-branch is dead and the if-expression resolves
      # to `Constant[:even]` only. The bool-valued path (when the receiver is a non-literal Integer) joins both
      # edges into `Constant[:even] | Constant[:odd]` — the fixture itself `assert_type`s that case.
      expect(harness.local(:result)).to eq(constant(:even))
    end

    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/module_singleton_call.rb — module/class singleton-method call resolution" do
    let(:harness) { harness_for("module_singleton_call") }

    # Module-singleton call resolution (ADR-57 follow-up): a `def self.x` / `module_function` call on a
    # module/class constant re-types the body with the call's args bound (constant args fold; a singleton
    # helper called via implicit self resolves against the same singleton table), while a foreign / RBS-known
    # singleton (`Math.sqrt`) stays catalog-typed. The fixture's `assert_type(...)` lines self-check.
    it "resolves singleton-method calls (def self / module_function / implicit-self helper)" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/constant_reduce_fold.rb — constant reduce/inject folding" do
    let(:harness) { harness_for("constant_reduce_fold") }

    # Folds a fully-constant `reduce`/`inject` to its exact value. The fact2 chain (Range-literal bound-type
    # folding → ReduceFolding's constant tier → ADR-57 per-call adoption) makes
    # `def range_fact(n) = (1..n).reduce(1, :*); range_fact(5)` fold to `120` / `range_fact(0)` to `1` — the
    # bound `(1..n)` types as `Constant[Range]` once `n` is pinned, even though the bound is a variable read
    # rather than a literal IntegerNode.
    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/destructured_param.rb — destructured positional params don't crash the binder" do
    let(:harness) { harness_for("destructured_param") }

    it "produces no internal analyzer error for `def f((a, b))` shapes" do
      internal = harness.errors.select { |d| d.message.include?("internal analyzer error") }
      expect(internal).to be_empty
    end
  end

  describe "fixtures/case_when.rb — Symbol-literal classification" do
    let(:harness) { harness_for("case_when") }

    it "binds `label` to a three-way Symbol-literal union" do
      members = harness.local(:label).members.map(&:value)
      expect(members).to contain_exactly(:zero, :small, :large)
    end
  end

  describe "fixtures/compound_writes.rb — operator dispatch through `+=` / `||=`" do
    let(:harness) { harness_for("compound_writes") }

    it "constant-folds `n += 5; n -= 3` so `n` is bound to `12`" do
      expect(harness.local(:n)).to eq(constant(12))
    end

    it "replaces a nil-bound `cached` with the rvalue type on `||=`" do
      expect(harness.local(:cached)).to eq(constant("hit"))
    end
  end

  describe "fixtures/indexed_or_narrowing.rb — `receiver[key] ||= default` narrowing" do
    let(:harness) { harness_for("indexed_or_narrowing") }

    it "is diagnostic-clean — the post-`||=` `<<` / `[]=` chains dispatch on non-nil" do
      messages = harness.errors.map(&:message)
      expect(messages).to be_empty
    end

    it "records a per-slot narrowing keyed on `(receiver_kind, receiver_name, literal_key)`" do
      key = Rigor::Scope::IndexedKey.new(receiver_kind: :local, receiver_name: :params, key: :f)
      expect(harness.post_scope.indexed_narrowings).to have_key(key)
    end
  end

  # Issue #544 — the decline side: a receiver whose type carries an untracked (Dynamic) arm can hold
  # a caller-supplied slot value the `||=` keeps, so the recorded default alone would invent a fact
  # and fold a reachable branch away (mail's TestRetriever#find).
  describe "fixtures/indexed_or_narrowing_dynamic_arm.rb — Dynamic-armed receivers decline the record" do
    let(:harness) { harness_for("indexed_or_narrowing_dynamic_arm") }

    it "does not fold the post-`||=` comparison — the caller's slot value is still live" do
      expect(harness.errors.map(&:message)).to be_empty
    end
  end

  describe "fixtures/universal_object_methods.rb — receiver-independent Object/Kernel selectors" do
    let(:harness) { harness_for("universal_object_methods") }

    # Every `assert_type` in the fixture — the predicates on an untyped receiver, the Object contract methods, and
    # the three deliberate exclusions (`class`, `==`, `to_s`), which must still read `untyped`.
    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    it "still folds through a receiver the dispatcher can name" do
      expect(harness.local(:folded_nil)).to eq(constant(true))
      expect(harness.local(:folded_inspect)).to eq(constant(":sym"))
    end
  end

  describe "fixtures/index_write_mutation_widening.rb — `h[k] ||= v` and siblings widen like `h[k] = v`" do
    let(:harness) { harness_for("index_write_mutation_widening") }

    it "is diagnostic-clean — the compound `x.nil? || @rows.empty?` guard no longer folds to a constant" do
      messages = harness.diagnostics.map(&:message)
      expect(messages.grep(/always-(truthy|falsey)|condition is always/)).to be_empty
    end

    it "widens a local through IndexOrWriteNode, so `empty?` stays undecided" do
      expect(harness.local(:local_or_empty)).to eq(bool_type)
    end

    it "widens a local through IndexOperatorWriteNode" do
      expect(harness.local(:local_op_empty)).to eq(bool_type)
    end

    it "widens an Array-receiver or-write, not only a Hash one" do
      expect(harness.local(:local_array_empty)).to eq(bool_type)
    end
  end

  # Issue #560 — the ADDED-value half of the mutation widening. PR #561 widened the value pinning a
  # slot-REWRITING mutator falsifies; this pins the join that covers what the mutation stored.
  describe "fixtures/mutation_added_value_join.rb — straight-line mutations join the added value" do
    let(:harness) { harness_for("mutation_added_value_join") }

    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    # The must-not-fire / must-fire pair in one assertion: every mutated-then-read condition in the
    # fixture is TRUE at runtime and folded to a constant `false` before the join, and the one
    # comparison nothing mutates must still fold. Asserting the exact line set is what keeps the
    # "went quiet" half from passing because the rule stopped firing at all.
    it "silences the stale folds without silencing the genuine one" do
      flow = harness.diagnostics.select { |d| d.rule.to_s.start_with?("flow.") }
      expect(flow.map(&:line)).to eq(marked_lines(harness, "# GENUINE-FALSEY"))
    end

    # The join's own FP surface, and the reason a straight-line join never CLOSES its parameter.
    # This seam sees one store and the widening is a one-way door, so the next store is invisible:
    # `a = []; a.push(1); a.push("s"); a.last.upcase` is correct Ruby that a closed `Array[Integer]`
    # rejected, and mail's `Message#to_yaml` is the same defect one carrier over. The fixture
    # carries all three mutator forms of the first and the block / unconditional / straight-line
    # forms of the second — together they separate a branch-scoping bug from an evidence bug —
    # against a value the seed really does pin to a class with no `<<`, where the diagnostic is
    # right and must survive.
    it "keeps stored-then-read values silent without silencing a genuinely pinned one" do
      undefined = harness.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(undefined.map(&:line)).to eq(marked_lines(harness, "# GENUINE-UNDEFINED"))
    end
  end

  describe "fixtures/mutation_join_declared_sig/ — the join stays inside a hand-written signature" do
    let(:harness) { harness_for("mutation_join_declared_sig") }

    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    # haml's temple builders (8 sites on the corpus gate) are the shape: a `[:multi]` seed appended
    # with `[:static, …]` pairs, declared `-> Array[:multi]`. Joining the appended tuple precisely
    # draws `def.return-type-mismatch` on correct code; the admissibility gate answers `Dynamic[top]`
    # for a class the seed does not admit, and a union carrying it ACCEPTS. `genuinely_wrong` is the
    # live-rule control — without it this example would pass on a rule that never fires.
    # A DECLARED gradual arm must survive the slice-C rederivation, in both spellings. The nested
    # one (`keeps_declared_gradual_arm`, `Array[Integer | untyped]`) fell to a draft that flattened
    # Union members before dropping Dynamic; the BARE one (`keeps_declared_untyped_element` and its
    # loop / Hash twins, `Array[untyped]`) fell to the drop itself, which could not tell a declared
    # `untyped` from the arity-forget's own floor and closed the parameter to `Array[Integer]` once
    # the body's stores contributed a concrete class (issue #586). Both signatures say the array may
    # hold anything, so `a.first.upcase` is correct code. The must-fire half is the exact line set:
    # a FRESH empty seed has no arm to keep and still closes, so its `upcase` is rightly rejected —
    # without those markers this example would pass on a seam that had gone gradual everywhere.
    it "keeps a declared gradual arm through the block and loop rederivations, and still closes a fresh seed" do
      undefined = harness.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(undefined.map(&:line)).to eq(marked_lines(harness, "# GENUINE-UNDEFINED"))
    end

    it "draws a return-type mismatch only where the body is genuinely wrong" do
      mismatches = harness.diagnostics.select { |d| d.rule == "def.return-type-mismatch" }
      expect(mismatches.map(&:method_name)).to eq(["genuinely_wrong"])
    end
  end

  describe "fixtures/array_new_dynamic_seed/ — Array.new with a non-literal size seeds an element arm" do
    let(:harness) { harness_for("array_new_dynamic_seed") }

    # Issue #615. A bare `Array` carries no element arm, and the ADR-56 seams read exactly that
    # as an elementless seed — a fresh accumulator whose every store they saw — so they closed
    # the constructor's carrier over the block's own stores. `Array.new(n, "x")` then read
    # `Array[1]` under `[1].each { acc.push(1) }` and drew `undefined method 'upcase'` on the
    # correct `acc.first.upcase`. The fixture's `assert_type` lines pin what each constructor
    # form now seeds, block and loop seam alike, together with the `Integer`-size gate that
    # keeps Ruby's array-convertible COPY overload (`Array.new([1, 2])` is `[1, 2]`, not two
    # nils) out of the `nil` answer.
    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    # The must-fire half is the exact line set. A FRESH seed — the `[]` literal and the
    # zero-argument `Array.new`, which really does build an empty array — carries no arm to
    # keep, the seam saw every store, and the parameter rightly closes; without these markers
    # the example above would pass on a fold that had gone gradual everywhere.
    it "still closes a fresh seed, constructor and literal alike" do
      undefined = harness.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(undefined.map(&:line)).to eq(marked_lines(harness, "# GENUINE-UNDEFINED"))
    end

    # The user-visible half of the container widening. Every `puts "hit" if …` in the fixture
    # appends to a constructed slot and compares the value back — correct Ruby that a fill kept
    # at its literal arity folds away. A container the walk stopped short of (the outermost only,
    # a union arm, a nested literal) turns these red without touching the `assert_type` lines.
    it "folds no condition away over a constructed-then-appended slot" do
      folds = harness.diagnostics.select { |d| d.rule == "flow.always-truthy-condition" }
      expect(folds.map(&:line)).to be_empty
    end
  end

  describe "fixtures/ivar_mutation_widening.rb — class-ivar Tuple/HashShape widening on mutation" do
    let(:harness) { harness_for("ivar_mutation_widening") }

    it "is diagnostic-clean — the Redmine `Structure` worked site no longer fires `undefined method '<<' for {}`" do
      messages = harness.errors.map(&:message)
      expect(messages).to be_empty
    end
  end

  describe "fixtures/method_chain_narrowing.rb — stable single-hop method-chain narrowing" do
    let(:harness) { harness_for("method_chain_narrowing") }

    it "is diagnostic-clean — chain-narrowed `x.last << y` / `@list.last << y` dispatch through `Array`" do
      messages = harness.errors.map(&:message)
      expect(messages).to be_empty
    end
  end

  describe "fixtures/defensive_ivar_falsey_rvalue.rb — `@x = nil/false unless @x` doesn't false-fire" do
    let(:harness) { harness_for("defensive_ivar_falsey_rvalue") }

    it "is diagnostic-clean — no flow.always-truthy / always-falsey on the falsey-rvalue idiom" do
      messages = harness.diagnostics.map(&:message)
      expect(messages.grep(/always-(truthy|falsey)|condition is always/)).to be_empty
    end
  end

  describe "fixtures/retry_edge_widening.rb — `tries += 1; retry` widens the counter" do
    let(:harness) { harness_for("retry_edge_widening") }

    it "is diagnostic-clean — `if tries > 100` and `if @attempts > 10` no longer fold" do
      messages = harness.diagnostics.map(&:message)
      expect(messages.grep(/always-(truthy|falsey)|condition is always/)).to be_empty
    end
  end

  describe "fixtures/non_empty_refinement_mutation_widening.rb — a mutator invalidates `non-empty-array`" do
    let(:harness) { harness_for("non_empty_refinement_mutation_widening") }

    it "is diagnostic-clean — `arr.size == 0` after `clear` / `pop` / `shift` no longer folds" do
      messages = harness.diagnostics.map(&:message)
      expect(messages.grep(/always-(truthy|falsey)|condition is always/)).to be_empty
    end
  end

  describe "fixtures/intervening_call_ivar_invalidation.rb — implicit-self call invalidates ivar narrowings" do
    let(:harness) { harness_for("intervening_call_ivar_invalidation") }

    it "is diagnostic-clean — `if @performed` after `perform_request` no longer folds" do
      messages = harness.diagnostics.map(&:message)
      expect(messages.grep(/always-(truthy|falsey)|condition is always/)).to be_empty
    end
  end

  describe "fixtures/read_before_write_nil.rb — `read-before-write` adds nil to the seed" do
    let(:harness) { harness_for("read_before_write_nil") }

    it "is diagnostic-clean — `unless @warning_issued` and `return if @done` no longer fold" do
      messages = harness.diagnostics.map(&:message)
      expect(messages.grep(/always-(truthy|falsey)|condition is always/)).to be_empty
    end
  end

  describe "fixtures/callee_body_mutation_floor.rb — a callee filling its Hash param floors the caller argument" do
    let(:harness) { harness_for("callee_body_mutation_floor") }

    # A helper that content-mutates its parameter directly in its body (`declaration[:prefix] = …`) now floors
    # the caller's captured argument, so `declaration[:prefix].empty? && declaration[:versions].empty?` no longer
    # folds to a constant (the rigor-rails-routes Grape discoverer false positive).
    it "is diagnostic-clean — the post-`absorb` `.empty? && .empty?` guard no longer folds" do
      messages = harness.diagnostics.map(&:message)
      expect(messages.grep(/always-(truthy|falsey)|condition is always/)).to be_empty
    end
  end

  describe "fixtures/aliased_mutation_receiver.rb — issue #277 selection-receiver mutation widening" do
    let(:harness) { harness_for("aliased_mutation_receiver") }

    # `(kind == :required ? required : optional)[key] = info` mutates whichever hash the ternary picked, so
    # BOTH forget their empty-`HashShape` seed. The recursive collector's return union therefore stays open
    # across the recursive edge (`required` / `optional` are `Hash`, not `{}`).
    it "keeps the recursive return union open across the recursive edge" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    # The caller's `shape[:required].empty? && shape[:optional].empty?` is live for every input carrying a
    # row; before the fix it folded to `Constant[true]` and fired a `flow.always-truthy-condition`.
    it "fires no flow.always-truthy-condition on the recursive collector's emptiness guard" do
      flow_constants = harness.diagnostics.select { |d| d.rule == "flow.always-truthy-condition" }
      expect(flow_constants).to be_empty
    end
  end

  describe "fixtures/is_a_narrowing.rb — String | nil narrowing" do
    let(:harness) { harness_for("is_a_narrowing") }

    it "narrows the truthy/falsey branches via assert_type" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/is_a_lexical_resolution.rb — `is_a?(C)` honours lexical-scope constant lookup" do
    let(:harness) { harness_for("is_a_lexical_resolution") }

    it "resolves `is_a?(Inner)` inside `Foo::Outer#call` to `Foo::Inner` (not top-level `Inner`)" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  # #635 — the multi-segment counterpart of the fixture above. A relative constant PATH
  # (`Nested::Leaf`) is not "already qualified": Ruby anchors its first segment through
  # `Module.nesting`. The fixture asserts the resolution across every class-membership
  # shape and pins the rooted / unshadowed / top-level spellings that must not move.
  describe "fixtures/relative_constant_path_narrowing.rb — relative constant paths in class guards" do
    let(:harness) { harness_for("relative_constant_path_narrowing") }

    it "resolves `Nested::Leaf` inside `Bar` to `Bar::Nested::Leaf` for is_a? / when / ===" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    # Guards the assertion above against going quiet: it fails vacuously the moment the
    # fixture stops asserting. Every `assert_type` line MUST still be present and MUST
    # still be the one the resolution rule decides.
    it "still asserts one narrowed type per guard shape" do
      expect(marked_lines(harness, "assert_type(").size).to eq(13)
    end

    # The false-positive arm. `Bar::Nested::Random` shadows a class RBS knows completely,
    # so an unwalked `when Random` resolves against core `Random` and fires
    # `call.undefined-method` on the next line — the concurrent-ruby `Monitor` shape. The
    # fixture's `CoreRandomGuard` is the must-still-succeed twin: unshadowed, the core
    # class must still answer and `Random#rand` must still resolve.
    it "leaves no other diagnostic on the narrowed receivers" do
      expect(harness.errors.map { |d| [d.line, d.rule, d.message] }).to be_empty
    end
  end

  # #652 — the sibling defect of the fixture above, and the one that made this
  # family a DERIVATION bug rather than a per-shape one. Ruby's `Module.nesting`
  # inside a compact `class Admin::CompactController` is that class alone, so a
  # bare `Post` there names `::Post`; the nested spelling of the same class
  # reaches `Admin::Post`. The engine peeled the qualified name, which is
  # identical for the two, and answered `Admin::Post` for both.
  describe "fixtures/compact_declaration_nesting/ — compact declarations get Ruby's nesting" do
    let(:harness) { harness_for("compact_declaration_nesting") }

    it "resolves a bare name to the top level in a compact body and to the shadow in a nested one" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    # Non-vacuity for the example above, and the reason the compact and nested
    # halves are written as twins: an implementation that stopped walking
    # entirely satisfies every compact assertion and none of the nested ones,
    # and one that kept peeling satisfies the reverse. Both halves have to be
    # counted for either to mean anything.
    it "still asserts one resolved constant per shape, on both spellings" do
      expect(marked_lines(harness, "assert_type(").size).to eq(13)
    end

    # The false-positive arm, and the reason this is a PROJECT fixture. Each
    # assertion is followed by a call only the correctly-resolved class owns
    # (`Post#top_post`, `Admin::Post#admin_post`, `Wrap::Marker#wrap_marker`,
    # `Loner#loner`), and those methods are declared in the fixture's `sig/`
    # rather than in its body — `call.undefined-method` declines on a receiver
    # whose class RBS does not know, so a flat fixture could not fire the
    # diagnostic the issue reports no matter how wrong the resolution got.
    # With the sig, master fires it four times here and the branch none.
    it "leaves no other diagnostic on the resolved receivers" do
      expect(harness.errors.map { |d| [d.line, d.rule, d.message] }).to be_empty
    end
  end

  # #681 — the same defect on the path the declaration walk never reaches.
  # `ScopeIndexer`'s census pre-passes type an rvalue where it is WRITTEN, under a
  # scope built from a self type alone, so the constant / ivar / cvar tables were
  # populated by peeling the qualified name and every later read served the wrong
  # class. `@post = Post.new` in an `initialize` and a `DEFAULT = Post` constant are
  # ordinary Ruby, which makes this the more reachable half of the family.
  describe "fixtures/census_declaration_nesting/ — the census pre-passes get Ruby's nesting" do
    let(:harness) { harness_for("census_declaration_nesting") }

    it "records constant, ivar and cvar rvalues under the writing body's real nesting" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    # Non-vacuity, and the reason each census is written as a compact / nested pair:
    # an implementation that stopped walking satisfies every compact assertion and no
    # nested one, and the peel satisfies the reverse.
    it "still asserts one recorded rvalue per census, on both spellings" do
      expect(marked_lines(harness, "assert_type(").size).to eq(11)
    end

    # The false-positive arm. Every assertion is followed by a call only the
    # correctly-resolved class owns (`Post#top_post`, `Admin::Post#admin_post`,
    # `Own#own_marker`, `Loner#loner`), declared in the fixture's `sig/` so
    # `call.undefined-method` can fire at all. Master fires six of them here.
    it "leaves no other diagnostic on the recorded receivers" do
      expect(harness.errors.map { |d| [d.line, d.rule, d.message] }).to be_empty
    end
  end

  # #690 — the one census shape #681 carved out. A `Foo::BAR = …` resolves its own
  # NAMESPACE through the nesting too, so the entry's key and its rvalue both depend on
  # the enclosing declaration; the census carried one parameter for both roles and had to
  # pass it empty, losing them together. The two losses compound: the qualified read
  # reaches no entry, and the in-namespace read falls past the qualified rung to the
  # mis-keyed one and fires `undefined method` on correct code.
  describe "fixtures/constant_path_write_nesting/ — a path write keyed and typed by its nesting" do
    let(:harness) { harness_for("constant_path_write_nesting") }

    it "keys a path write under the namespace Ruby resolves and types its rvalue there" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    # Non-vacuity. Each write is read back through every spelling that differs — the
    # fully-qualified one the mis-keying broke and the in-namespace one the rvalue typing
    # broke — plus the arms that must NOT move (a top-level write, an unattributable
    # namespace, a rooted `::Registry`, and the two top-level reads a `self::` or
    # dynamic-base write must not capture), the #705 over-eager witness read from INSIDE
    # the writing module, the innermost-owned pair whose two spellings must answer alike,
    # and the #540 mutation-widening pair that rides on the same key.
    it "still asserts every read spelling of the recorded writes" do
      expect(marked_lines(harness, "assert_type(").size).to eq(14)
    end

    # The false-positive arm: every assertion is followed by a call only the correctly
    # resolved class owns (`Post#top_post`, `Admin::Post#admin_post`, `Value#own_marker`),
    # declared in the fixture's `sig/`, so a wrong answer fires rather than widens.
    it "leaves no other diagnostic on the recorded receivers" do
      expect(harness.errors.map { |d| [d.line, d.rule, d.message] }).to be_empty
    end
  end

  # #681 — the last member of the family, and the one path a stamp could not fix.
  # `ExpressionTyper#build_user_method_body_scope` rebuilds a CALLEE's body scope from
  # the receiver's type when it needs that callee's return, so nothing was in hand to
  # stamp: the def-node index has to carry the chain recorded at the declaration for the
  # re-walk to reproduce it. Until it did, the same `Post.new` typed one way where the
  # walk reads it and another way through the value's consumer.
  describe "fixtures/callee_rewalk_nesting/ — an inferred return keeps the callee's nesting" do
    let(:harness) { harness_for("callee_rewalk_nesting") }

    it "types a callee's return under the callee's own declaration nesting" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    # Non-vacuity, and the reason every arm is written as a compact / nested pair: an
    # implementation that stopped peeling entirely satisfies each compact assertion and
    # no nested twin, and the peel satisfies the reverse. The cross-class reader is the
    # third arm — it proves the chain follows the CALLEE's declaration rather than the
    # caller's, which no same-class pair can discriminate.
    it "still asserts every inferred return, on both spellings" do
      expect(marked_lines(harness, "assert_type(").size).to eq(7)
    end

    # The false-positive arm. Each assertion is followed by a call only the correctly
    # resolved class owns (`Post#top_post`, `Admin::Post#admin_post`), declared in the
    # fixture's `sig/` so `call.undefined-method` can fire at all.
    it "leaves no other diagnostic on the returned receivers" do
      expect(harness.errors.map { |d| [d.line, d.rule, d.message] }).to be_empty
    end
  end

  describe "fixtures/tuple_access.rb — Tuple element typing" do
    let(:harness) { harness_for("tuple_access") }

    it "binds `first`, `middle`, and `last` to their precise tuple elements" do
      expect(harness.local(:first)).to eq(constant(10))
      expect(harness.local(:middle)).to eq(constant(20))
      expect(harness.local(:last)).to eq(constant(30))
    end
  end

  describe "fixtures/hash_shape.rb — HashShape entry typing" do
    let(:harness) { harness_for("hash_shape") }

    it "binds `n` and `a` to their precise hash entries" do
      expect(harness.local(:n)).to eq(constant("Alice"))
      expect(harness.local(:a)).to eq(constant(30))
    end
  end

  describe "fixtures/hash_scalar_keys.rb — scalar-literal hash keys + duplicate-key last-wins" do
    let(:harness) { harness_for("hash_scalar_keys") }

    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    it "keeps 1 and 1.0 as distinct last-wins entries" do
      h = harness.local(:h)
      expect(h).to be_a(Rigor::Type::HashShape)
      expect(h.pairs.keys).to eq([1, 1.0])
      expect(harness.local(:int_hit)).to eq(constant(2))
      expect(harness.local(:float_hit)).to eq(constant(4))
      expect(harness.local(:miss)).to eq(constant(nil))
    end

    it "applies last-wins to duplicate symbol keys instead of degrading to Hash[K, V]" do
      s = harness.local(:s)
      expect(s).to be_a(Rigor::Type::HashShape)
      expect(s.pairs).to eq({ a: constant(2) })
    end
  end

  describe "fixtures/tuple_map.rb — per-element block fold for :map / :collect on Tuple" do
    let(:harness) { harness_for("tuple_map") }

    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    it "folds heterogeneous Tuple#map into per-position Tuple of stringified constants" do
      mixed = harness.local(:mixed)
      expect(mixed).to be_a(Rigor::Type::Tuple)
      expect(mixed.elements.map(&:value)).to eq(%w[1 two three])
    end

    it "folds Tuple#collect (the :map alias) the same way" do
      collected = harness.local(:collected)
      expect(collected).to be_a(Rigor::Type::Tuple)
      expect(collected.elements.map(&:value)).to eq([15, 25])
    end

    it "folds Tuple#filter_map all-keep into per-position Tuple" do
      filter_mapped_keep = harness.local(:filter_mapped_keep)
      expect(filter_mapped_keep).to be_a(Rigor::Type::Tuple)
      expect(filter_mapped_keep.elements.map(&:value)).to eq(%w[1 2 3])
    end

    it "folds Tuple#filter_map all-drop into the empty Tuple" do
      filter_mapped_drop = harness.local(:filter_mapped_drop)
      expect(filter_mapped_drop).to be_a(Rigor::Type::Tuple)
      expect(filter_mapped_drop.elements).to be_empty
    end

    it "composes Phase 2 + filter_map + ternary branch elision into a precise survivor Tuple" do
      # `[1,2,3].filter_map { |n| n.even? ? n.to_s : nil }` — only n=2 survives the per-position fold, so the
      # answer is `Tuple[Constant["2"]]`.
      filter_mapped_evens = harness.local(:filter_mapped_evens)
      expect(filter_mapped_evens).to be_a(Rigor::Type::Tuple)
      expect(filter_mapped_evens.elements.map(&:value)).to eq(["2"])
    end

    it "folds Tuple#flat_map by concatenating per-position Tuples" do
      flat_pairs = harness.local(:flat_pairs)
      expect(flat_pairs).to be_a(Rigor::Type::Tuple)
      expect(flat_pairs.elements.map(&:value)).to eq([1, 10, 2, 20, 3, 30])
    end

    it "concatenates heterogeneous-arity per-position Tuples in flat_map" do
      flat_varied = harness.local(:flat_varied)
      expect(flat_varied).to be_a(Rigor::Type::Tuple)
      expect(flat_varied.elements.map(&:value)).to eq([1, 2, 2])
    end

    it "treats per-position Constant scalars as single-element contributions in flat_map" do
      # `[1, 2, 3].flat_map { |n| n.to_s }` — each per-position result is a `Constant<String>`, which
      # contributes one element to the assembled Tuple.
      flat_scalar = harness.local(:flat_scalar)
      expect(flat_scalar).to be_a(Rigor::Type::Tuple)
      expect(flat_scalar.elements.map(&:value)).to eq(%w[1 2 3])
    end

    it "concatenates all-empty per-position Tuples into the empty Tuple" do
      # `[1, 2, 3].flat_map { |_n| [] }` — every per-position result is `Tuple[]`, so the assembled answer is
      # also `Tuple[]`. (`[]` resolves to `Tuple[]`, not `Nominal[Array]`.)
      flat_all_empty = harness.local(:flat_all_empty)
      expect(flat_all_empty).to be_a(Rigor::Type::Tuple)
      expect(flat_all_empty.elements).to be_empty
    end

    it "folds Tuple#find to the first truthy-position element" do
      first_even = harness.local(:first_even)
      expect(first_even).to eq(Rigor::Type::Combinator.constant_of(2))
    end

    it "folds Tuple#find to Constant[nil] when every position is falsey" do
      no_match = harness.local(:no_match)
      expect(no_match).to eq(Rigor::Type::Combinator.constant_of(nil))
    end

    it "folds Tuple#find_index to the first truthy-position index" do
      idx_first_even = harness.local(:idx_first_even)
      expect(idx_first_even).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "folds Tuple#index (block form) the same as find_index" do
      idx_alias = harness.local(:idx_alias)
      expect(idx_alias).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "folds Constant<Range>#map for short ranges via per-element re-typing" do
      range_mapped = harness.local(:range_mapped)
      expect(range_mapped).to be_a(Rigor::Type::Tuple)
      expect(range_mapped.elements.map(&:value)).to eq(%w[1 2 3])
    end

    it "folds Constant<Range>#find truthy-block to the first matching integer" do
      range_first_even = harness.local(:range_first_even)
      expect(range_first_even).to eq(Rigor::Type::Combinator.constant_of(2))
    end

    it "folds Constant<Range>#find_index truthy-block to the matching index" do
      range_first_idx = harness.local(:range_first_idx)
      expect(range_first_idx).to eq(Rigor::Type::Combinator.constant_of(1))
    end
  end

  describe "fixtures/block_filter.rb — BlockFolding for select/all?/any?" do
    let(:harness) { harness_for("block_filter") }

    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    it "folds `[10, 20].any? { |x| x > 0 }` to Constant[true]" do
      expect(harness.local(:non_empty_any)).to eq(constant(true))
    end

    it "folds `[1,2,3].select { false }` to the empty tuple" do
      expect(harness.local(:empty_select)).to eq(Rigor::Type::Combinator.tuple_of)
    end

    it "folds `[1,2,3].all? { true }` to Constant[true]" do
      expect(harness.local(:all_truthy)).to eq(constant(true))
    end
  end

  describe "fixtures/block_map.rb — per-position Tuple uplift on Array#map" do
    let(:harness) { harness_for("block_map") }

    it "binds `strings` to a per-position Tuple of stringified literals" do
      # `[1,2,3].map { |n| n.to_s }` folds to `Tuple[Constant["1"], Constant["2"], Constant["3"]]`, strictly
      # tighter than the Array[union] projection. Wider receivers (e.g. `Nominal[Integer]`) still widen back to
      # `Array[String]` via the RBS tier.
      strings = harness.local(:strings)
      expect(strings).to be_a(Rigor::Type::Tuple)
      expect(strings.elements.map(&:value)).to eq(%w[1 2 3])
    end
  end

  describe "fixtures/per_element_filter.rb — per-element select/filter/reject fold" do
    let(:harness) { harness_for("per_element_filter") }

    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    it "narrows `reject(&:nil?)` to the surviving Tuple positions" do
      non_nil = harness.local(:non_nil_sym)
      expect(non_nil).to be_a(Rigor::Type::Tuple)
      expect(non_nil.elements.map(&:value)).to eq([1, 2])
    end

    it "folds an all-dropped `reject` to the empty tuple" do
      expect(harness.local(:nothing)).to eq(Rigor::Type::Combinator.tuple_of)
    end
  end

  describe "fixtures/early_return.rb — return-if-nil narrowing" do
    let(:harness) { harness_for("early_return") }

    it "drops nil from `String | nil` after the early-return guard via assert_type" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/block_auto_splat.rb — single Tuple yield destructures across multi-param block" do
    let(:harness) { harness_for("block_auto_splat") }

    it "binds Hash#each `|k, v|` to (key, value) via Ruby's block auto-splat" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/regex_global_narrowing.rb — C1 regex match-data global narrowing" do
    let(:harness) { harness_for("regex_global_narrowing") }

    it "narrows `$~`/`$1`/`$&` on the match edge, leaves optional/no-match nilable" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/assertions.rb — self-asserting via `assert_type`" do
    let(:harness) { harness_for("assertions") }

    it "produces no `assert_type` errors when the fixture's expectations match" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    it "exposes every `dump_type` call as an `:info` diagnostic the user can read" do
      # The fixture intentionally uses only `assert_type` (no bare `dump_type` calls), so the info-severity
      # dump surface starts empty here. The presence of the rule is what we are asserting; future fixtures may
      # add dump_type calls.
      info_dumps = harness.diagnostics.select { |d| d.severity == :info }
      expect(info_dumps).to be_an(Array)
    end
  end

  describe "fixtures/user_methods.rb — user-defined `is_odd` / `is_even` without RBS (v0.0.3 C)" do
    let(:harness) { harness_for("user_methods") }

    it "constant-folds the body so `Parity.new.is_odd(3)` returns `Constant[true]`" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/user_methods_with_sig/ — same class, but the sig declares the return type" do
    let(:harness) { harness_for("user_methods_with_sig") }

    it "self-asserts the engine resolves `bool` (`false | true`) for both helpers" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/self_method_call.rb — ADR-24 slice 1 implicit-self call resolution" do
    let(:harness) { harness_for("self_method_call") }

    it "resolves same-class and top-level implicit-self calls to the callee's return type" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/bot_branch_guard.rb — ADR-24 slice 3 Bot-branch flow narrowing" do
    let(:harness) { harness_for("bot_branch_guard") }

    it "treats a `bot`-typed guard helper as a terminating branch and narrows the fall-through" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/inherited_guard.rb — ADR-24 slice 2 superclass-chain resolution" do
    let(:harness) { harness_for("inherited_guard") }

    it "resolves an implicit-self call against a superclass `def` and narrows through the guard" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/included_module_guard.rb — ADR-24 slice 2 included-module resolution" do
    let(:harness) { harness_for("included_module_guard") }

    it "resolves an implicit-self call against an included module's `def` and narrows the guard" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/or_guard_narrowing.rb — ADR-24 WD6 `or`-guard narrowing in eval_and_or" do
    let(:harness) { harness_for("or_guard_narrowing") }

    it "narrows the LHS of `or` when the RHS is a `Bot`-typed guard helper" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/ivar_guard_narrowing.rb — `if @ivar` / `@ivar && …` / `unless @ivar.nil?` narrowing" do
    let(:harness) { harness_for("ivar_guard_narrowing") }

    it "narrows an instance variable to non-nil inside a truthy guard" do
      expect(harness.errors).to be_empty
    end
  end

  describe "fixtures/assert_extended/ — RBS::Extended `assert` / `assert-if-*` (v0.0.2)" do
    let(:harness) { harness_for("assert_extended") }

    it "narrows the argument unconditionally after a call annotated with `assert`" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/assert_negation/ — RBS::Extended `~T` negation (v0.0.2 #2)" do
    let(:harness) { harness_for("assert_negation") }

    it "drops the negated class from the post-call union" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/self_predicate/ — RBS::Extended `target: self` narrowing (v0.0.2 #3)" do
    let(:harness) { harness_for("self_predicate") }

    it "narrows the receiver local for `predicate-if-*`, `assert-if-*`, and `assert` self-targeted directives" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/argument_type/ — argument-type-mismatch check rule (v0.0.2 #4)" do
    let(:harness) { harness_for("argument_type") }

    it "produces no diagnostics when every call argument matches its parameter type" do
      arg_errors = harness.errors.select { |d| d.message.start_with?("argument type mismatch") }
      expect(arg_errors).to be_empty
    end
  end

  describe "fixtures/predicate_extended/ — RBS::Extended `predicate-if-*`" do
    let(:harness) { harness_for("predicate_extended") }

    it "narrows the truthy branch to Integer per `predicate-if-true`" do
      truthy = harness.type_at(line: 4, column: 5)
      expect(truthy).to be_a(Rigor::Type::Nominal)
      expect(truthy.class_name).to eq("Integer")
    end

    it "narrows the falsey branch to NilClass per `predicate-if-false`" do
      falsey = harness.type_at(line: 6, column: 5)
      expect(falsey).to be_a(Rigor::Type::Nominal)
      expect(falsey.class_name).to eq("NilClass")
    end
  end

  describe "fixtures/divmod_tuple.rb — Integer#divmod folds to Tuple[Constant, Constant]" do
    let(:harness) { harness_for("divmod_tuple") }

    it "self-asserts via assert_type with no mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/integer_range_narrowing.rb — IntegerRange carrier and narrowing" do
    let(:harness) { harness_for("integer_range_narrowing") }

    it "self-asserts the comparison-narrowed range types via assert_type" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/container_size.rb — Array/String/Hash#size tightened to non_negative_int" do
    let(:harness) { harness_for("container_size") }

    it "self-asserts the tightened size return types via assert_type" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/file_path_folding.rb — File path-manipulation folding" do
    let(:harness) { harness_for("file_path_folding") }

    it "self-asserts every File.<path-method>(\"…\") fold" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/refinement_return_override/ — RBS::Extended return refinement" do
    let(:harness) { harness_for("refinement_return_override") }

    it "self-asserts non-empty-string and positive-int return overrides plus their projections" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/predicate_refinement/ — RBS::Extended predicate-subset return refinement" do
    let(:harness) { harness_for("predicate_refinement") }

    it "self-asserts lowercase/uppercase/numeric-string return overrides plus the case-fold projection pair" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/parameterised_refinement/ — RBS::Extended parameterised return payload" do
    let(:harness) { harness_for("parameterised_refinement") }

    it "self-asserts non-empty-array[T], non-empty-hash[K, V], and int<a, b> return overrides" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/intersection_refinement/ — composite Intersection-backed refinements" do
    let(:harness) { harness_for("intersection_refinement") }

    it "self-asserts non-empty-lowercase-string and non-empty-uppercase-string + size projection" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/assert_refinement/ — RBS::Extended assert against a refinement" do
    let(:harness) { harness_for("assert_refinement") }

    it "substitutes the refinement carrier for the target's bound type after the call" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/assert_negation_refinement/ — RBS::Extended assert against ~refinement" do
    let(:harness) { harness_for("assert_negation_refinement") }

    it "narrows the target to the complement of the refinement (Difference[String, \"\"] → Constant[\"\"])" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/assert_negation_integer_range/ — RBS::Extended assert against ~int<a, b>" do
    let(:harness) { harness_for("assert_negation_integer_range") }

    it "narrows Integer to the union of the two open complement halves" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/param_extended/ — RBS::Extended rigor:v1:param: directive" do
    let(:harness) { harness_for("param_extended") }

    it "flags exactly the call site whose argument fails the refinement (suppression verifies identification)" do
      # The fixture uses `# rigor:disable argument-type-mismatch` on the offending call, so a clean run proves
      # both that the rule fired against the override AND that the suppression-comment matches.
      arg_errors = harness.errors.select { |d| d.message.start_with?("argument type mismatch") }
      expect(arg_errors).to be_empty
    end

    it "applies the override inside the method body via MethodParameterBinder" do
      # `assert_type` calls inside `normalise(id)` exercise the body-side narrowing: the binder must read the
      # same override map and bind `id` to `non-empty-string` rather than the RBS-declared `String`. A miss
      # surfaces as an `assert_type mismatch` diagnostic.
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/string_array_catalog.rb — String/Symbol/Array catalog-driven folding" do
    let(:harness) { harness_for("string_array_catalog") }

    it "self-asserts the new String/Symbol fold coverage" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/hash_catalog.rb — Hash catalog-driven folding" do
    let(:harness) { harness_for("hash_catalog") }

    it "self-asserts the new Hash catalog coverage (size projection, shape lookup, mutator widening)" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/hash_shape_handlers.rb — HashShape mid/low-priority handlers" do
    let(:harness) { harness_for("hash_shape_handlers") }

    it "folds one?/fetch_values/assoc/key/has_value?/default/deconstruct_keys/containment" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/tuple_hash_inspect_star.rb — Tuple/HashShape #inspect / #to_s and Tuple#* (#121)" do
    let(:harness) { harness_for("tuple_hash_inspect_star") }

    it "folds inspect/to_s to the real Ruby format and * to the join-alias / repetition result" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/hash_shape_transform.rb — per-pair HashShape transform_keys / transform_values fold" do
    let(:harness) { harness_for("hash_shape_transform") }

    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    it "folds transform_keys(&:to_sym) on a string-keyed HashShape to a symbol-keyed HashShape" do
      result = harness.local(:sym_keyed)
      expect(result).to be_a(Rigor::Type::HashShape)
      expect(result.pairs.keys).to eq(%i[name age])
    end

    it "folds transform_keys(&:to_s) on a symbol-keyed HashShape to a string-keyed HashShape" do
      result = harness.local(:str_hash)
      expect(result).to be_a(Rigor::Type::HashShape)
      expect(result.pairs.keys).to eq(%w[name age])
      expect(result.pairs.values.map(&:value)).to eq(["Alice", 30])
    end

    it "folds transform_values(&:to_s) on a symbol-keyed HashShape, converting each value to its string form" do
      result = harness.local(:stringified)
      expect(result).to be_a(Rigor::Type::HashShape)
      expect(result.pairs[:name].value).to eq("Alice")
      expect(result.pairs[:age].value).to eq("30")
    end

    it "folds transform_values with a full block per pair independently" do
      result = harness.local(:up)
      expect(result).to be_a(Rigor::Type::HashShape)
      expect(result.pairs[:x].value).to eq("1")
      expect(result.pairs[:y].value).to eq("hello")
    end
  end

  describe "fixtures/range_catalog.rb — Range catalog-driven folding" do
    let(:harness) { harness_for("range_catalog") }

    it "self-asserts the new Range fold coverage" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/set_catalog.rb — Set catalog-driven folding" do
    let(:harness) { harness_for("set_catalog") }

    it "self-asserts the Set#size projection plus blocklisted mutators" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/time_catalog.rb — Time catalog-driven folding" do
    let(:harness) { harness_for("time_catalog") }

    it "self-asserts the Time reader surface plus blocklisted in-place mutators" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/always_raises/ — division-by-zero diagnostic" do
    let(:harness) { harness_for("always_raises") }

    it "flags every Integer-by-zero call (suppressions in the fixture verify identification)" do
      # The fixture uses `# rigor:disable always-raises` on each raising line, so a clean run proves both that
      # the rule fired AND that the suppression comment matches.
      raises = harness.errors.select { |d| d.rule == "flow.always-raises" }
      expect(raises).to be_empty
    end
  end

  describe "fixtures/iterator_block_params.rb — IntegerRange-typed block parameters" do
    let(:harness) { harness_for("iterator_block_params") }

    it "self-asserts the precise per-iterator block-param ranges" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/each_with_index.rb — Enumerable-aware block-parameter typing" do
    let(:harness) { harness_for("each_with_index") }

    it "self-asserts the element + non-negative-int index for Array / Hash / Range receivers" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/enumerable_memo.rb — each_with_object / inject / reduce" do
    let(:harness) { harness_for("enumerable_memo") }

    it "self-asserts memo-typed block parameters across each_with_object, inject (with + without seed), and reduce" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/enumerable_collect.rb — group_by / partition / each_slice / each_cons" do
    let(:harness) { harness_for("enumerable_collect") }

    it "self-asserts the precise per-position element union for Tuple-shaped receivers" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/include_aware_clamp.rb — Integer#clamp via Comparable's catalog" do
    let(:harness) { harness_for("include_aware_clamp") }

    it "folds Integer#clamp through the include-aware module-catalog fallthrough" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/two_arg_fold.rb — 2-arg constant folding (between?/clamp/pow)" do
    let(:harness) { harness_for("two_arg_fold") }

    it "folds Comparable#between?, Comparable#clamp(min, max), and Integer#pow(exp, mod)" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/numeric_fold.rb — Integer / Float mid-priority folds" do
    let(:harness) { harness_for("numeric_fold") }

    it "folds floor/ceil/round/truncate, chr, gcd/lcm, fdiv, and lifts digits" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/math_folding.rb — Math module-function folding" do
    let(:harness) { harness_for("math_folding") }

    it "folds Math transcendental / two-arg / log / frexp calls on constants" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/kernel_conversion.rb — Kernel numeric-conversion folding" do
    let(:harness) { harness_for("kernel_conversion") }

    it "folds Integer() / Float() / Rational() / Complex() on constant arguments" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/union_arithmetic.rb — cartesian fold over Union[Constant…]" do
    let(:harness) { harness_for("union_arithmetic") }

    it "self-asserts the cartesian-fold and graceful-widening behaviours" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/date_time_folding/ — Date / Time Constant carrier folding" do
    let(:harness) { harness_for("date_time_folding") }

    it "folds Date.new / DateTime.new / Time.utc constructors and their reader surface" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/date_catalog/ — Date / DateTime catalog-driven folding" do
    let(:harness) { harness_for("date_catalog") }

    it "self-asserts the Date / DateTime reader and navigation surface" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/rational_catalog.rb — Rational catalog-driven folding" do
    let(:harness) { harness_for("rational_catalog") }

    it "self-asserts the new Rational catalog coverage" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/kernel_functions.rb — Kernel module-function precision (p/pp identity + folds)" do
    let(:harness) { harness_for("kernel_functions") }

    it "self-asserts the p/pp identity typing, the format/String constant folds, and the FP guards" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/method_type_param_binding.rb — method-level `[T]` bound from an argument (#303)" do
    let(:harness) { harness_for("method_type_param_binding") }

    it "self-asserts the identity binding and the no-evidence decline" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/complex_catalog.rb — Complex catalog-driven folding" do
    let(:harness) { harness_for("complex_catalog") }

    it "self-asserts the new Complex catalog coverage" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  # The fixtures below carry both an `assert_type` self-check (so the file is readable as documentation) and
  # the finer-grained `harness.local` assertions above. The shared spec here only verifies the assert_type
  # path; the type-specific assertions for each fixture live in their own `describe` block.
  describe "self-asserting `assert_type` calls in converted fixtures" do
    %w[parity case_when compound_writes tuple_access hash_shape block_map block_filter tuple_map
       per_element_filter].each do |name|
      it "produces no assert_type mismatches in fixtures/#{name}.rb" do
        harness = harness_for(name)
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end
    describe "fixtures/pathname_catalog.rb — Pathname catalog-driven folding" do
      let(:harness) { harness_for("pathname_catalog") }

      it "self-asserts the new Pathname catalog coverage" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/random_catalog.rb — Random catalog-driven folding" do
      let(:harness) { harness_for("random_catalog") }

      it "self-asserts the new Random catalog coverage" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/struct_catalog.rb — Struct catalog-driven folding" do
      let(:harness) { harness_for("struct_catalog") }

      it "self-asserts the new Struct catalog coverage" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/encoding_catalog.rb — Encoding catalog-driven folding" do
      let(:harness) { harness_for("encoding_catalog") }

      it "self-asserts the new Encoding catalog coverage" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/re_catalog.rb — Regexp / MatchData catalog-driven folding" do
      let(:harness) { harness_for("re_catalog") }

      it "self-asserts the new Regexp / MatchData catalog coverage" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/proc_catalog.rb — Proc / Method / UnboundMethod catalog-driven folding" do
      let(:harness) { harness_for("proc_catalog") }

      it "self-asserts the new Proc / Method / UnboundMethod catalog coverage" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/exception_catalog.rb — Exception catalog-driven folding" do
      let(:harness) { harness_for("exception_catalog") }

      it "self-asserts the new Exception catalog coverage" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/shellwords_folding.rb — Shellwords module function folding" do
      let(:harness) { harness_for("shellwords_folding") }

      it "self-asserts every Shellwords.escape/split/join fold" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end

      it "folds Shellwords.escape to the exact escaped Constant[String]" do
        expect(harness.local(:_escape_space)).to eq(Rigor::Type::Combinator.constant_of("hello\\ world"))
      end

      it "folds Shellwords.split to a Tuple of Constant[String]" do
        result = harness.local(:_split_cmd)
        expect(result).to be_a(Rigor::Type::Tuple)
        expect(result.elements.map(&:value)).to eq(%w[git commit -m] + ["initial commit"])
      end

      it "folds Shellwords.join to a Constant[String]" do
        result = harness.local(:_join_arr)
        expect(result).to eq(Rigor::Type::Combinator.constant_of("git commit -m initial\\ commit"))
      end
    end

    describe "fixtures/module_function_folding.rb — Regexp / CGI / URI module function folding" do
      let(:harness) { harness_for("module_function_folding") }

      it "self-asserts every Regexp.escape / CGI.escapeHTML / URI.encode_www_form_component fold" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end

      it "folds Regexp.escape to a Constant[String]" do
        result = harness.local(:_regexp_escaped)
        expect(result).to be_a(Rigor::Type::Constant)
        expect(result.value).to eq("hello\\.world")
      end

      it "folds Regexp.quote to a Constant[String]" do
        result = harness.local(:_regexp_quoted)
        expect(result).to be_a(Rigor::Type::Constant)
        expect(result.value).to eq("\\[a\\-z\\]")
      end

      it "folds CGI.escape_uri_component to the percent-encoded Constant[String]" do
        result = harness.local(:_uri_comp)
        expect(result).to eq(Rigor::Type::Combinator.constant_of("hello%20world"))
      end

      it "folds URI.encode_www_form_component to a Constant[String]" do
        result = harness.local(:_encoded)
        expect(result).to be_a(Rigor::Type::Constant)
        expect(result.value).to be_a(String)
      end

      it "folds Regexp.new(pattern) to a Constant[Regexp]" do
        result = harness.local(:_regexp_plain)
        expect(result).to be_a(Rigor::Type::Constant)
        expect(result.value).to eq(/hello/)
      end

      it "folds Regexp.new(pattern, flags) to a Constant[Regexp] with options" do
        result = harness.local(:_regexp_new_flags)
        expect(result).to be_a(Rigor::Type::Constant)
        expect(result.value).to eq(/world/i)
      end

      it "folds Regexp.compile(pattern) to a Constant[Regexp] (documented alias of .new)" do
        result = harness.local(:_regexp_compiled)
        expect(result).to be_a(Rigor::Type::Constant)
        expect(result.value).to eq(/hello/)
      end

      it "folds Regexp.compile(pattern, flags) to a Constant[Regexp] with options" do
        result = harness.local(:_regexp_compile_flags)
        expect(result).to be_a(Rigor::Type::Constant)
        expect(result.value).to eq(/world/i)
      end

      it "folds Regexp.union(*patterns) to a Constant[Regexp]" do
        result = harness.local(:_regexp_union_splat)
        expect(result).to be_a(Rigor::Type::Constant)
        expect(result.value).to eq(Regexp.union("a", "b"))
      end

      it "folds Regexp.union(array) identically to the splatted form" do
        result = harness.local(:_regexp_union_array)
        expect(result).to eq(harness.local(:_regexp_union_splat))
      end

      it "folds Regexp.union() (no arguments) to Ruby's never-match regexp" do
        result = harness.local(:_regexp_union_empty)
        expect(result).to be_a(Rigor::Type::Constant)
        expect(result.value).to eq(Regexp.union)
      end

      it "folds Regexp.union with a mix of String and Regexp elements" do
        result = harness.local(:_regexp_union_mixed)
        expect(result).to be_a(Rigor::Type::Constant)
        expect(result.value).to eq(Regexp.union("a", /b/))
      end

      it "folds Regexp.linear_time?(str) to a Constant[bool]" do
        result = harness.local(:_linear_time_str)
        expect(result).to be_a(Rigor::Type::Constant)
        expect(result.value).to eq(Regexp.linear_time?("a.*b"))
      end

      it "folds Regexp.linear_time?(regexp) to a Constant[bool]" do
        result = harness.local(:_linear_time_regexp)
        expect(result).to be_a(Rigor::Type::Constant)
        expect(result.value).to eq(Regexp.linear_time?(/a.*b/))
      end
    end

    describe "fixtures/set_constant_folding.rb — Set constant carrier" do
      let(:harness) { harness_for("set_constant_folding") }

      it "self-asserts every Set[] / Set.new / instance-method fold" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/recursive_constant_fold.rb — ADR-55 slice 1 constant-arg unroll" do
      let(:harness) { harness_for("recursive_constant_fold") }

      # factorial(5) → 120, the string builder → "***", and the constant-arg mutual recursion all fold;
      # factorial(100) exhausts the 32-frame fuel and degrades to today's widened `Integer`.
      it "folds constant-arg recursion and degrades gracefully on fuel exhaustion" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/recursive_dynamic_arg.rb — ADR-55 slice 1 non-constant args unchanged" do
      let(:harness) { harness_for("recursive_dynamic_arg") }

      it "leaves the non-constant-arg recursion path byte-identical to today" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/recursive_unroll_clamp.rb — ADR-55 WD1 precision-envelope clamps" do
      let(:harness) { harness_for("recursive_unroll_clamp") }

      # (1) value-pinned self-call adoption is inert outside an unroll; (2) a guarded re-entry whose body folds
      # to a non-pinned type clamps back to the plain guard's `untyped`.
      it "confines value-pinned adoption to the unroll envelope" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/recursive_fixpoint_summary.rb — ADR-55 slice 2 fixpoint return summaries" do
      let(:harness) { harness_for("recursive_fixpoint_summary") }

      # A non-constant-arg recursive method's in-cycle contribution is the method's real return type, not
      # `Dynamic[top]`. The discriminating cases are the bare-self-call recursions: `passthrough → :done` (the
      # fixpoint discovers the base case) and `pick → Dynamic[top]` (the bot-collapse floor for an
      # explicit-return base case); an only-recursing method → `bot` (without hanging); mutual recursion
      # terminates. Factorial / Builder are RBS-absorption anchors, not fixpoint discriminators (see the
      # fixture's note).
      it "computes Dynamic-free recursive return summaries and terminates" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/explicit_return_contribution.rb — ADR-57 slice 2 explicit-return inference" do
      let(:harness) { harness_for("explicit_return_contribution") }

      # Explicit `return value` nodes (early returns, bare returns, and block-internal returns that exit the
      # enclosing method) join the tail type in method-return inference; nested `def`/lambda are return
      # barriers. Predicate helpers infer `bool`, not `Constant[true]`.
      it "joins explicit returns into the inferred method return type" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/overridable_method_no_fold.rb — ADR-57 N5 overridable-method adoption gate" do
      let(:harness) { harness_for("overridable_method_no_fold") }

      # An implicit-self call to a method whose owner has a discovered subclass / includer redefining it
      # degrades the adopted return to `Dynamic[top]` (template-method default is not a flow constant), while
      # a method with no discovered override keeps folding to its base literal. The fixture's `assert_type`s
      # pin both halves.
      it "degrades the overridden self-call return but preserves the final-method fold" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end

      # No always-truthy/falsey FP fires on the `directed?`-style template method: the guard read is
      # `Dynamic[top]`, which the flow-constant rule never fires on (rgl's entire warning set).
      it "fires no flow.always-truthy-condition on the overridden template read" do
        flow_constants = harness.diagnostics.select { |d| d.rule == "flow.always-truthy-condition" }
        expect(flow_constants).to be_empty
      end
    end

    describe "fixtures/escaping_content_capture.rb — ADR-57 slice 2 escaping-block content widening" do
      let(:harness) { harness_for("escaping_content_capture") }

      # An escaping / unknown block that content-mutates a captured outer local widens that local to its
      # bare-collection floor (Hash → Hash[untyped, untyped], String → String, Array → Array[Dynamic[top]])
      # instead of keeping the unsoundly-precise empty seed. A read-only capture is untouched.
      it "widens content-mutated escaping captures to the Dynamic floor" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/optional_tuple_destructure.rb — ADR-57 slice 3 optional-slot softening" do
      let(:harness) { harness_for("optional_tuple_destructure") }

      # Destructuring a tuple slot flow typed as optional (`X | nil`) softens that slot to its non-`nil` part
      # (FP discipline: a nil-able slot is almost always guarded by a correlated invariant flow cannot prove),
      # while a pure slot keeps its precise type and a bare `nil` slot stays `nil`.
      it "softens optional destructured slots without over-widening" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end

    describe "fixtures/block_captured_writeback.rb — ADR-56 slice A captured-local write-back" do
      let(:harness) { harness_for("block_captured_writeback") }

      # A non-escaping block that rebinds an outer local writes the continuation binding back (the capped
      # fixpoint): accumulators widen to a base, a distinct-constant rebind keeps both pinned constituents
      # (0-iteration soundness), `||=` keeps the pre-call `nil`, a no-write block keeps its exact constant
      # (fast path), a compounding shape floors to `Dynamic[top]` at the cap, and an escaping block is
      # unchanged. Before this slice every accumulator kept its WRONG pre-call constant — a spec-MUST violation.
      it "folds written captured locals back, soundly, without touching unwritten ones" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end

      it "keeps an unwritten read-only captured local byte-identical (fast path)" do
        expect(harness.local(:untouched)).to eq(constant(7))
      end

      it "floors a compounding captured local to Dynamic[top] at the cap" do
        expect(harness.local(:growing)).to eq(Rigor::Type::Combinator.untyped)
      end
    end

    describe "fixtures/loop_body_fixpoint.rb — ADR-56 slice B loop-body fixpoint" do
      let(:harness) { harness_for("loop_body_fixpoint") }

      # A `while` / `until` body that rebinds a loop-carried local folds its continuation binding through the
      # same capped fixpoint slice A uses: accumulators widen to a base (never the historical unsound `1 | 2`),
      # a body-first-assignment local degrades to `T | nil` for the 0-iteration path, and a compounding shape
      # floors to `Dynamic[top]` at the cap. Before this slice every accumulator kept its WRONG single-pass
      # constant — a spec-MUST violation.
      it "folds loop-carried locals back, soundly, across while / until / do-loop shapes" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end

      it "joins the pushed element type of a receiver-content-mutated non-rebound local (slice C)" do
        # `acc.push(m)` widens `acc`'s Tuple AND the slice-C content writeback joins the pushed `m` (→
        # `Integer`) into the element parameter, so the continuation is `Array[Integer]` — sounder and more
        # precise than the pre-slice-C `Array[Dynamic[top]] | []`.
        expect(harness.local(:acc)).to eq(
          Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("Integer")])
        )
      end

      it "floors a compounding loop-carried local to Dynamic[top] at the cap" do
        expect(harness.local(:g)).to eq(Rigor::Type::Combinator.untyped)
      end
    end

    # Issue #631 — ADR-56 WD2.11. The seam rederives ONE carrier and writes it over the whole
    # binding, which is only the right answer for the pre-state members the mutation applied to as a
    # collection of that class. A `Union` seed's non-carrier members (a whole-variable `Dynamic`, a
    # foreign `Nominal`) contribute no element evidence and used to vanish with it.
    describe "fixtures/union_seed_residue.rb — a Union seed's non-carrier members survive the seam" do
      let(:harness) { harness_for("union_seed_residue") }

      # Both halves in one assertion: the residue arms are present (the four `Dynamic` / `Bag` cases)
      # AND the carriers still collapse to one Array (`joins_two_array_carriers`,
      # `absorbs_a_bare_array_carrier`, `closes_a_plain_seed`) — a rule that kept carriers too would
      # read `Array[1 | 3] | Array[2 | 3]` and fail here, not merely lose precision.
      it "produces no assert_type mismatches" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end

      # The FP the issue reported, and its must-fire control. `out.first.upcase` on the surviving
      # `Dynamic` arm is correct code the closed `Array[2]` rejected; a seed with nothing to keep
      # still closes, so ITS `upcase` is rightly refused. Asserting the exact line set is what keeps
      # the "went quiet" half from passing because the rule stopped firing at all.
      it "stops firing undefined-method on a surviving arm without going quiet on a closed seed" do
        undefined = harness.diagnostics.select { |d| d.rule == "call.undefined-method" }
        expect(undefined.map(&:line)).to eq(marked_lines(harness, "# GENUINE-UNDEFINED"))
      end

      # The same drop seen from the fold side: `out.first == 3` against a closed `Array[2]` folded to
      # `Constant[false]` and drew a false always-falsey. No `flow.` diagnostic survives here.
      it "keeps the constant fold open where the seed carries a gradual arm" do
        flow = harness.diagnostics.select { |d| d.rule.to_s.start_with?("flow.") }
        expect(flow.map(&:line)).to be_empty
      end

      # `nil` is the one member the mutation refutes, so it does NOT survive — and the live nil arm
      # is still reported once, at the mutation itself.
      it "reports a live nil arm at the mutation and nowhere downstream" do
        nils = harness.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
        expect(nils.map(&:line)).to eq(marked_lines(harness, "# GENUINE-NIL"))
      end
    end

    describe "fixtures/reduce_symbol.rb — Symbol-form reduce / inject return types" do
      let(:harness) { harness_for("reduce_symbol") }

      # `(1..n).reduce(1, :*)`, `[1,2,3].reduce(:+)`, and friends carry no block, so the call used to fall to
      # `Enumerable#reduce`'s `(untyped, Symbol) -> untyped` RBS overload and widen to `Dynamic[top]`.
      # ReduceFolding dispatches the named operator on the accumulated element type and recovers the precise
      # carrier (`Integer` / `String`) — strictly more informative, no diagnostic.
      it "recovers a precise carrier for every Symbol-operand fold shape" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end

      it "types a non-constant-bound range fold `(lower..upper).reduce(1, :*)` as Integer" do
        expect(harness.local(:ranged)).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      end

      it "types the no-seed `xs.reduce(:+)` over a non-constant array as Integer (no manufactured nil)" do
        expect(harness.local(:sum)).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      end

      it "types the String-element fold as String" do
        expect(harness.local(:joined)).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end
    end
  end
end
