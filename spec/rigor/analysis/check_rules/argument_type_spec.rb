# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# The `call.argument-type-mismatch` family's *unobserved* half — `CheckRules::ArgumentType`. Two per-topic
# specs already cover the two firing channels through core-library signatures: `nil_argument_mismatch_spec`
# (a pure-`nil` argument no overload admits) and `non_nil_argument_mismatch_spec` (ADR-64's single-concrete-
# class channel, driven through `Array#fetch`'s `int` interface-alias). Neither drives the **provenance gate**,
# the **`rigor:v1:param` override arms**, or the interface / eligibility branches, because none of those are
# reachable through the core signatures those two specs use. This spec supplies its own `sig/sink.rbs`, which
# is what makes them reachable.
#
# #135 checkbox-1 wave 2. Mutation recon measured 8 de-noised survivors in this family; the dense cluster
# (three of them) sits in `declaration_sourced_nil_only_mismatch?`, the ADR-58 ivar-provenance gate — entirely
# unexecuted before this file, since suppressing it needs a class-ivar-index-seeded `T | nil` ivar read passed
# as an argument to a param that rejects the union but accepts `T`. `build_arity_diagnostic` (the 8th) is
# deliberately not covered here: it belongs to `call.wrong-arity` and is already observed by
# `wrong_arity_spec.rb`'s "build_arity_diagnostic message shape" block (PR #311).
RSpec.describe Rigor::Analysis::CheckRules::ArgumentType do
  describe "argument-type mismatch (provenance gate, param overrides, acceptance walk)" do
    # One signature file for every example. `Sink`'s methods are deliberately hand-shaped: the core library has
    # no single-overload method with a plain `ClassInstance` param that a nilable ivar can be threaded into, and
    # no `rigor:v1:param`-annotated method at all.
    def sink_rbs
      <<~RBS
        interface _Stringish
          def to_s: () -> String
        end

        class Sink
          def take_int: (Integer value) -> void
          def take_string: (String value) -> void
          def take_nilable: (Integer? value) -> void
          def take_name_plain: (String? value) -> void
          %a{rigor:v1:param: value is non-empty-string}
          def take_name: (String? value) -> void
          def take_tos: (_Stringish value) -> void
          def take_tostr: (_ToStr value) -> void
          def take_opt_kw: (Integer value, ?name: String) -> void
          def take_kwsplat: (Integer value, **untyped opts) -> void
          def take_req_kw: (Integer value, name: String) -> void
          def take_rest: (Integer value, *Integer more) -> void
          def plain_pick: (String value) -> void
                        | (Integer value) -> void
          %a{rigor:v1:param: value is non-empty-string}
          def pick: (String value) -> void
                  | (Integer value) -> void
          %a{rigor:v1:param: value is non-empty-array[Integer]}
          def take_ids: (Array[Integer] value) -> void
          %a{rigor:v1:param: value is non-empty-hash[Symbol, Integer]}
          def take_attrs: (Hash[Symbol, Integer] value) -> void
        end

        class Nums
          def label: (Integer i) -> String
        end
      RBS
    end

    def configuration
      Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => %w[app.rb], "signature_paths" => %w[sig])
      )
    end

    def diagnostics_for(source)
      Dir.mktmpdir("check-rules-argument-type-") do |dir|
        Dir.chdir(dir) do
          FileUtils.mkdir_p("sig")
          File.write(File.join("sig", "sink.rbs"), sink_rbs)
          File.write("app.rb", source)
          runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
          guarded_run(runner, %w[app.rb]).diagnostics
        end
      end
    end

    def arg_mismatches(source)
      diagnostics_for(source).select { |d| d.rule == "call.argument-type-mismatch" }
    end

    # A class whose `@count` is seeded `nil` by the ctor and written `1` by another method, so the class-ivar
    # pre-pass unions the two into `1 | nil` and the method-entry seed marks the read declaration-sourced
    # (ADR-58 WD1). `body` is spliced into `flush`, always starting at line 11.
    def holder(body)
      <<~RUBY
        class Holder
          def initialize
            @count = nil
          end

          def bump
            @count = 1
          end

          def flush
            #{body}
          end
        end
      RUBY
    end

    describe "declaration_sourced_nil_only_mismatch? (the ADR-58 ivar-provenance gate)" do
      it "suppresses when stripping the declaration-sourced nil yields a type the param accepts" do
        # The prize. `@count` reads `1 | nil` here and the mark is intact (no method-local write in `flush`), so
        # `Integer` rejects the union but accepts the nil-stripped `1` — ADR-58's "declaration-sourced nil is
        # real type information but not diagnostic fuel". A mutant that drops the `Combinator.union` /
        # `Union#members` strip (survivor L2466) or inverts the final `accepts(...).yes?` (L2469) makes this
        # example fire.
        expect(arg_mismatches(holder("Sink.new.take_int(@count)"))).to be_empty
      end

      it "still fires when the nil-stripped type is rejected too (the gate's negative verdict)" do
        # Same declaration-sourced `1 | nil` ivar, `String` param: stripping nil leaves `1`, which `String`
        # still rejects, so `accepts(...).yes?` is false and the mismatch survives the gate. Paired with the
        # decline above — identical provenance, opposite verdict — this is what keeps the gate from degrading
        # into "any declaration-sourced ivar argument is excused".
        diagnostics = arg_mismatches(holder("Sink.new.take_string(@count)"))
        expect(diagnostics.size).to eq(1)

        diagnostic = diagnostics.first
        expect(diagnostic.rule).to eq("call.argument-type-mismatch")
        expect(diagnostic.severity).to eq(:error)
        expect(diagnostic.error?).to be(true)
        expect(diagnostic.receiver_type).to eq("Sink")
        expect(diagnostic.method_name).to eq("take_string")
        expect(diagnostic.line).to eq(11)
        expect(diagnostic.column).to eq(26) # the `@count` ARGUMENT, not the `Sink.new` receiver at column 5
        expect(diagnostic.message).to eq(
          "argument type mismatch at parameter `value' of `take_string' on Sink: expected String, got 1?"
        )
      end

      it "still fires once a method-local conditional write makes the nil flow-live" do
        # `@count = nil if flag` inside the reading method drops the declaration-sourced mark upstream
        # (`Scope#with_ivar`), so the gate's `DeclarationSourcedGuard.marked?` lookup returns false and the SAME
        # `1 | nil` argument that is excused above now fires. A mutant that skipped the mark lookup and gated on
        # "is an ivar read" alone would silently excuse this.
        source = holder("@count = nil if flag\n    Sink.new.take_int(@count)").sub("def flush", "def flush(flag)")
        diagnostics = arg_mismatches(source)
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.message).to include("expected Integer, got 1?")
      end

      it "suppresses a LOCAL COPY of the same declaration-sourced ivar (issue #324)" do
        # `c = @count` inherits the `:local` provenance mark (`Scope#with_declaration_sourced_local`), so the
        # copy carries exactly the provenance the direct read above carries. Before #324 the gate opened with
        # `arg.is_a?(Prism::InstanceVariableReadNode)` and this fired, disagreeing with `possible-nil-receiver`
        # — which has honoured the `:local` mark since ADR-58 WD1 — about the copied-into-a-local shape the
        # ADR's own survey names as the motivating case (`r = @right; r.key`). Both rules now ask one predicate,
        # `DeclarationSourcedGuard.marked?`, so they cannot drift apart again.
        expect(arg_mismatches(holder("c = @count\n    Sink.new.take_int(c)"))).to be_empty
      end

      it "still fires on a local copy whose nil-stripped type the param rejects anyway" do
        # The #324 widening moves the copy INTO the gate; it does not make the gate say yes. Same
        # declaration-sourced local, `String` param: stripping nil leaves `1`, which `String` still rejects.
        # Paired with the decline above exactly as the ivar pair is — identical provenance, opposite verdict.
        diagnostics = arg_mismatches(holder("c = @count\n    Sink.new.take_string(c)"))
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.message).to include("expected String, got 1?")
      end

      it "still fires on a local copy taken after a method-local write made the nil flow-live" do
        # The ADR-58 boundary, restated on the copy path: `@count = nil if flag` drops the ivar's mark, so
        # `c = @count` lands on the plain `with_local` path and carries NO `:local` mark. Losing this would be
        # a soundness regression, not a parity fix.
        source = holder("@count = nil if flag\n    c = @count\n    Sink.new.take_int(c)")
                 .sub("def flush", "def flush(flag)")
        diagnostics = arg_mismatches(source)
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.message).to include("expected Integer, got 1?")
      end

      it "still fires on a SECOND-hop copy, which the scope does not mark" do
        # The mark is deliberately not transitive: `eval_local_write` stamps `:local` only when the RHS is a
        # pure read of a declaration-sourced IVAR, so `d = c` is an ordinary local write. #324 widened the gate
        # to the shapes the scope actually models and invented no propagation of its own — this pins that
        # boundary, so a later "make it transitive" change has to be a deliberate decision rather than a slip.
        diagnostics = arg_mismatches(holder("c = @count\n    d = c\n    Sink.new.take_int(d)"))
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.message).to include("expected Integer, got 1?")
      end

      it "still fires on a copy joined out of a conditional" do
        # `c = nil; c = @count if flag` joins a declaration-sourced arm with a flow-live one; the join carries
        # no mark, so the union is flow-observed nil and fires. The other half of the not-transitive boundary.
        source = holder("c = nil\n    if flag\n      c = @count\n    end\n    Sink.new.take_int(c)")
                 .sub("def flush", "def flush(flag)")
        diagnostics = arg_mismatches(source)
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.message).to include("expected Integer, got 1?")
      end

      it "still fires on a plainly wrong local with no declaration-sourced provenance at all" do
        # The floor. Nothing about #324 touches an argument whose rejection has no provenance story — a mutant
        # that made `DeclarationSourcedGuard.marked?` unconditionally true would keep every decline above and
        # lose exactly this.
        diagnostics = arg_mismatches("c = \"x\"\nSink.new.take_int(c)\n")
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.message).to include("expected Integer, got \"x\"")
      end

      it "never reaches the gate when the param admits nil outright" do
        # `Integer?` accepts `1 | nil` whole, so the rejection the gate exists to re-examine never happens.
        # Adjacent to the firing cases above: same argument, a param that simply takes it.
        expect(arg_mismatches(holder("Sink.new.take_nilable(@count)"))).to be_empty
      end
    end

    describe "declaration_sourced_nil_argument? (a PURE-nil declaration-sourced ivar argument)" do
      # `@label` is only ever written `nil`, so the read types exactly `nil` — the pure-nil channel, which is
      # gated by `declaration_sourced_nil_argument?` (survivor L2392) rather than by the union gate above.
      def nil_only_holder(body)
        <<~RUBY
          class Holder
            def initialize
              @label = nil
            end

            def flush
              #{body}
            end
          end
        RUBY
      end

      it "suppresses a pure-nil declaration-sourced ivar on the single-overload path" do
        expect(arg_mismatches(nil_only_holder("Sink.new.take_int(@label)"))).to be_empty
      end

      it "fires on a literal nil in the same position (adjacent to the decline above)" do
        # Identical param, identical argument TYPE — only the provenance differs. A mutant that made
        # `declaration_sourced_nil_argument?` unconditionally true would keep the decline and lose this.
        diagnostics = arg_mismatches("Sink.new.take_int(nil)\n")
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.line).to eq(1)
        expect(diagnostics.first.column).to eq(19) # the `nil` argument
        expect(diagnostics.first.message).to eq(
          "argument type mismatch at parameter `value' of `take_int' on Sink: expected Integer, got nil"
        )
      end

      it "fires once a method-local write makes the pure nil flow-live" do
        # The `arg.name` half of the survivor: re-writing `@label = nil` inside `flush` drops the mark for that
        # exact name, so the read is flow-live nil and fires.
        diagnostics = arg_mismatches(nil_only_holder("@label = nil\n    Sink.new.take_int(@label)"))
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.message).to include("expected Integer, got nil")
      end

      it "suppresses a pure-nil declaration-sourced ivar on the MULTI-overload path too" do
        # `nil_arg_overload_mismatch` consults the same predicate before the per-overload admission scan, so
        # the ADR-58 parity holds across both channels.
        expect(arg_mismatches(nil_only_holder("Sink.new.plain_pick(@label)"))).to be_empty
      end

      it "fires on a literal nil against the same multi-overload method (adjacent to the decline above)" do
        diagnostics = arg_mismatches("Sink.new.plain_pick(nil)\n")
        expect(diagnostics.size).to eq(1)
        # No `name:` in a multi-overload mismatch, so the label is the bare method — and `expected` is the
        # per-overload RBS types joined, not a translated Rigor type.
        expect(diagnostics.first.message).to eq(
          "argument type mismatch at `plain_pick' on Sink: expected String | Integer, got nil"
        )
      end

      it "suppresses a LOCAL COPY of the pure-nil ivar on BOTH channels (issue #324)" do
        # The pure-nil channel had the same parity hole as the union gate above, on both the single-overload
        # and the multi-overload path, because both consult `declaration_sourced_nil_argument?`. Routing that
        # predicate through `DeclarationSourcedGuard.marked?` closes all three call sites at once.
        expect(arg_mismatches(nil_only_holder("c = @label\n    Sink.new.take_int(c)"))).to be_empty
        expect(arg_mismatches(nil_only_holder("c = @label\n    Sink.new.plain_pick(c)"))).to be_empty
      end

      it "still fires on a local holding a flow-observed nil" do
        # `@label = nil` inside `flush` drops the ivar mark, so the copy taken after it is an ordinary local
        # binding a flow-observed nil. The must-still-fire sibling of the decline above.
        diagnostics = arg_mismatches(nil_only_holder("@label = nil\n    c = @label\n    Sink.new.take_int(c)"))
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.message).to include("expected Integer, got nil")
      end

      it "still fires on a local bound to a literal nil" do
        # No ivar anywhere in the story, so no provenance to inherit. The floor for the pure-nil channel.
        diagnostics = arg_mismatches("c = nil\nSink.new.take_int(c)\n")
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.message).to include("expected Integer, got nil")
      end
    end

    describe "param_admits_nil? / rigor_type_admits_nil? (the rigor:v1:param override arm)" do
      it "fires when a refinement override rejects nil that the RBS param type would have admitted" do
        # `take_name`'s RBS param is `String?` — it admits nil — but the `non-empty-string` override takes
        # precedence, and a refinement is neither Dynamic/Top nor nil-bearing, so `rigor_type_admits_nil?`
        # returns false. Pairs with the control below, which is the SAME `String?` param without the
        # annotation.
        diagnostics = arg_mismatches(%(Sink.new.take_name(nil)\n))
        expect(diagnostics.size).to eq(1)
        # OBSERVATION: `expected` renders the RBS-declared `String?`, not the override that actually refuted —
        # `overload_param_expected_label` reads `param.type`, which the override never replaces. The message is
        # therefore self-contradictory ("expected String?, got nil"). Recorded, not endorsed.
        expect(diagnostics.first.message).to eq(
          "argument type mismatch at parameter `value' of `take_name' on Sink: expected String?, got nil"
        )
      end

      it "stays clean on the same param shape WITHOUT the override (non-vacuity control)" do
        expect(arg_mismatches(%(Sink.new.take_name_plain(nil)\n))).to be_empty
      end

      it "stays clean when the argument satisfies the override" do
        expect(arg_mismatches(%(Sink.new.take_name("abc")\n))).to be_empty
      end
    end

    # A `non-empty-array[T]` / `non-empty-hash[K, V]` override is a `Difference` whose removed value is itself a
    # shape (`Tuple[]`, the closed `{}`), so a literal argument proves it absent through its arity or a required
    # key. The empty literal is the removed value and still fires on the same parameter.
    describe "empty-witness collection overrides (a shape argument proves the witness absent)" do
      it "stays clean on a non-empty array literal and a hash literal with a key" do
        expect(arg_mismatches(%(Sink.new.take_ids([1, 2])\nSink.new.take_attrs({ a: 1 })\n))).to be_empty
      end

      it "fires on the empty literal each override removes" do
        diagnostics = arg_mismatches(%(Sink.new.take_ids([])\nSink.new.take_attrs({})\n))
        expect(diagnostics.map(&:message)).to contain_exactly(
          "argument type mismatch at parameter `value' of `take_ids' on Sink: " \
          "expected non-empty-array[Integer], got []",
          "argument type mismatch at parameter `value' of `take_attrs' on Sink: " \
          "expected non-empty-hash[Symbol, Integer], got {}"
        )
      end
    end

    # `Integer#to_s` on the `Nums#label` parameter infers `decimal-int-string`, a predicate refinement
    # that can never hold `""` — the disjointness proof the `non-empty-string` param override reads off
    # the carrier (#1264). An argument that may still be `""` keeps firing on the same parameter.
    describe "empty-witness string override (a predicate refinement proves the witness absent)" do
      it "stays clean on Integer#to_s" do
        expect(arg_mismatches(<<~RUBY)).to be_empty
          class Nums
            def label(i)
              Sink.new.take_name(i.to_s)
              i.to_s
            end
          end
        RUBY
      end

      it "still fires on an argument that may be empty" do
        diagnostics = arg_mismatches(<<~RUBY)
          class Nums
            def label(i)
              Sink.new.take_name(i.even? ? i.to_s : "")
            end
          end
        RUBY
        expect(diagnostics.size).to eq(1)
      end

      # The refinement is a proof only until the buffer changes: `clear` empties it, so it widens to `String`.
      it "fires once a mutator may have emptied the refined buffer" do
        diagnostics = arg_mismatches(<<~RUBY)
          class Nums
            def label(i)
              s = i.to_s
              s.clear
              Sink.new.take_name(s)
              s
            end
          end
        RUBY
        expect(diagnostics.size).to eq(1)
      end
    end

    describe "interface_admits_nil? (an interface parameter on the nil channel)" do
      it "admits nil for an interface every one of whose methods NilClass implements" do
        # `_Stringish` requires only `to_s`, and `NilClass#to_s` exists — so `nil` genuinely satisfies it and
        # the rule must stay silent. The conservative half of the pair below.
        expect(arg_mismatches(%(Sink.new.take_tos(nil)\n))).to be_empty
      end

      it "fires for an interface NilClass does not satisfy (adjacent to the decline above)" do
        # `_ToStr` requires `to_str`, which NilClass lacks. Same syntactic shape as `_Stringish`, opposite
        # verdict — a mutant that returned a constant from `interface_admits_nil?` loses one of the two.
        diagnostics = arg_mismatches(%(Sink.new.take_tostr(nil)\n))
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.message).to eq(
          "argument type mismatch at parameter `value' of `take_tostr' on Sink: expected _ToStr, got nil"
        )
      end
    end

    describe "rigor_type_accepts_arg? (the override arm of the multi-overload NON-nil channel)" do
      it "fires when the override refutes an argument the RBS param type would have accepted" do
        # Survivor L2318 — the `Inference::Acceptance.accepts(param_type, arg_type, mode: :gradual)` call
        # reached only through a `rigor:v1:param` override. `""` is a String, so `pick`'s declared `String`
        # overload accepts it; the `non-empty-string` refinement does not. The control below runs the same
        # argument against the un-annotated `plain_pick` and stays clean, which is what proves the override —
        # not the RBS type — is doing the refuting.
        diagnostics = arg_mismatches(%(Sink.new.pick("")\n))
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.column).to eq(15) # the `""` argument
        expect(diagnostics.first.message).to eq(
          %(argument type mismatch at `pick' on Sink: expected String | Integer, got "")
        )
      end

      it "stays clean on the same argument against the un-annotated overload set (non-vacuity control)" do
        expect(arg_mismatches(%(Sink.new.plain_pick("")\n))).to be_empty
      end

      it "fires on an Integer argument once the override replaces BOTH overloads' param type" do
        # `param_type_override_map` is keyed by param NAME, and both overloads name their positional `value`,
        # so the `non-empty-string` override applies to the `(Integer value)` overload too and `42` is refuted
        # by every arm. The un-annotated `plain_pick(42)` control below accepts it.
        expect(arg_mismatches(%(Sink.new.pick(42)\n)).map(&:message))
          .to contain_exactly("argument type mismatch at `pick' on Sink: expected String | Integer, got 42")
      end

      it "stays clean on the Integer argument against the un-annotated overload set" do
        expect(arg_mismatches(%(Sink.new.plain_pick(42)\n))).to be_empty
      end

      it "stays clean when the argument satisfies the override on one overload" do
        expect(arg_mismatches(%(Sink.new.pick("abc")\n))).to be_empty
      end
    end

    describe "class_instance_accepts_arg? / single_concrete_arg_class?" do
      it "fires on a plain ClassInstance overload set no arm accepts" do
        # The existing `non_nil_argument_mismatch_spec` drives this channel through `Array#fetch`'s `int`
        # ALIAS, so acceptance is decided by `interface_accepts_arg?`. Here both overload params are plain
        # `ClassInstance`s, translated faithfully and handed to `class_instance_accepts_arg?` instead — the
        # sibling branch of `rbs_type_accepts_arg?`, unobserved until now.
        diagnostics = arg_mismatches(%(Sink.new.plain_pick(:sym)\n))
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.message).to eq(
          "argument type mismatch at `plain_pick' on Sink: expected String | Integer, got :sym"
        )
      end

      it "skips a class-object argument on the multi-overload channel (single_concrete_arg_class?)" do
        # `String` types as `Singleton[String]`, which the WD3 guard excludes outright — a class object has its
        # own acceptance surface. Same overload set as the firing example above.
        expect(arg_mismatches(%(Sink.new.plain_pick(String)\n))).to be_empty
      end

      it "still fires on the SINGLE-overload path for the same class-object argument" do
        # The Singleton exclusion lives in `single_concrete_arg_class?`, which only the multi-overload channel
        # consults; `single_argument_mismatch` runs the translated-acceptance check directly and refutes it.
        # This asymmetry is what the decline above would otherwise be mistaken for.
        diagnostics = arg_mismatches(%(Sink.new.take_int(String)\n))
        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.message).to eq(
          "argument type mismatch at parameter `value' of `take_int' on Sink: expected Integer, got singleton(String)"
        )
      end
    end

    # Issue #673 rewrote this envelope. A keyword parameter used to make the WHOLE signature ineligible, so
    # the positional arguments of every keyword-bearing signature in the bundle went unchecked:
    # `time.beginning_of_week("monday")` fired while `time.next_week("monday")` — `(?Symbol, ?same_time:
    # bool)`, the same runtime error — did not. Keywords cannot shift a positional argument's index, and a
    # call that PASSES keywords never reaches the signature at all (`WrongArity.plain_positional_call?` rejects a
    # `KeywordHashNode` first), so the class-refutation half is now checked. The nullability half stays
    # behind the old envelope: see `keyword_bearing?`'s note in argument_type.rb for the two corpus witnesses.
    describe "argument_check_eligible? (#673)" do
      it "checks the positional arguments of an optional-keyword signature" do
        diagnostics = arg_mismatches(%(Sink.new.take_opt_kw("x")\n))

        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.message).to eq(
          "argument type mismatch at parameter `value' of `take_opt_kw' on Sink: expected Integer, got \"x\""
        )
      end

      it "checks them for a keyword-splat signature too" do
        expect(arg_mismatches(%(Sink.new.take_kwsplat("x")\n)).size).to eq(1)
      end

      it "checks them for a required-keyword signature too" do
        expect(arg_mismatches(%(Sink.new.take_req_kw("x")\n)).size).to eq(1)
      end

      # The staged half. A `nil` positional against a keyword-bearing signature stays silent, because the two
      # verdicts the widening produced on correct corpus code both rested on nullability rather than class.
      it "still declines a nil positional on a keyword-bearing signature" do
        expect(arg_mismatches(%(Sink.new.take_opt_kw(nil)\n))).to be_empty
      end

      # ...and the carve-out is scoped to keyword-bearing signatures, not applied to the rule at large:
      # `take_int` has no keywords and its `nil` verdict is unchanged.
      it "keeps firing on a nil positional when the signature carries no keyword" do
        expect(arg_mismatches(%(Sink.new.take_int(nil)\n)).size).to eq(1)
      end

      # A rest positional is still a disqualifier, and for a reason keywords never had: arguments past it do
      # not bind to a later positional parameter, so `params[index]` would read the wrong contract.
      it "still declines a signature with a rest positional" do
        expect(arg_mismatches(%(Sink.new.take_rest("x")\n))).to be_empty
      end
    end

    describe "translate_param_type" do
      # The `rescue StandardError` arm (survivor L2488) is a defensive fallback with no fixture that reaches
      # it — every RBS type the analyzer hands it is translatable — so this one method is observed by a direct
      # call rather than through the rule.
      it "translates a well-formed RBS type" do
        translated = described_class.send(:translate_param_type,
                                          RBS::Parser.parse_type("Integer"), nil)
        expect(translated.describe(:short)).to eq("Integer")
      end

      it "falls back to untyped when the translator raises" do
        # A non-RBS object makes `RbsTypeTranslator.translate` raise; the rescue must yield gradual `untyped`,
        # which every caller reads as "admits everything" and declines on. A mutant that let the exception
        # escape would crash the whole run.
        translated = described_class.send(:translate_param_type, Object.new, nil)
        expect(translated).to be_a(Rigor::Type::Dynamic)
      end
    end

    it "leaves a correct program using every signature above clean" do
      source = <<~RUBY
        sink = Sink.new
        sink.take_int(1)
        sink.take_string("a")
        sink.take_nilable(nil)
        sink.take_name("abc")
        sink.take_tos(nil)
        sink.take_tostr("s")
        sink.plain_pick("a")
        sink.plain_pick(2)
        sink.pick("a")
      RUBY
      expect(diagnostics_for(source).select(&:error?)).to be_empty
    end
  end

  describe "without the runner (ADR-116 WD1 / C4)" do
    # ADR-116 WD1 / C4 — {CheckRules::ArgumentType.diagnostic} on a parsed snippet and its scope index, with no
    # runner: the examples above pin the rule through the whole run at 200-400 ms an example, these at a millisecond
    # or two. The snippet is indexed against an empty scope whose environment loads the core RBS and a project
    # signature, so a call is judged against those signatures and what the snippet itself records.
    #
    # Mutation-proved: each guard line (a `return` / `next` modifier) of `diagnostic` and of the helpers it calls was
    # blanked in turn and an example in this file failed, except these, which no input here distinguishes (one line on
    # what was tried each):
    #
    # - `return nil if call_node.receiver.nil?` and `return nil if class_name.nil?`: an implicit-self
    #   call has a nil receiver type, so each is backed by the other; `return nil if scope.nil?`: every
    #   call of an indexed snippet has a scope.
    # - `rbs_class_known?`, `definition_available?` (and, with `receiver.nil?` / `class_name.nil?` above, each
    #   other) in `diagnostic`: a project class no signature declares has no signature, which the
    #   `method_def.nil?` guard declines (pinned). Blanking each of the four in turn changed no row for
    #   `Module.new.const_get(1)`, `Class.new.new(1, 2)`, `BasicObject.new.instance_eval(1)`, `__id__(1)`,
    #   `Object.new.instance_variable_get(1)`, `singleton_class.const_get(1)`, `Module.new.module_eval(1)`,
    #   `Kernel.puts(1)`, `Comparable.instance_method(1)`, `proc { }.call(1, 2)` (an untyped `(?)`
    #   signature), `Object.new.equal?(1)`, `String.new(1)` or a receiver-less call.
    # - `inferred_param_mismatch_verdict?`: true only for a parameter whose type the whole-project run
    #   infers from its call sites; a one-file snippet leaves the parameter `Dynamic`, which the earlier
    #   `Dynamic` test declines.
    # - `next false unless function.respond_to?(:required_keywords)` in `keyword_bearing?`: reached only
    #   after a mismatch, and an `untyped` `(?)` signature (`take_any`, `pick_untyped`, as `Proc#call`
    #   has) never mismatches.
    # - `rbs_class_known?(arg_type.class_name)` and the `ClassSingleton` test in
    #   `class_object_overload_mismatch`: an unknown project class object (`Foo`) and a class object
    #   against an overload that takes an instance are both refused to fire by
    #   `class_singleton_refuses?` itself (`Acceptance` answers `maybe`, and an instance parameter
    #   translates to a nominal, not a singleton).
    # - `return param if bounded.empty?` in `resolve_param_bounds`: with no bounded type parameter the
    #   substitution it builds maps every type to itself.
    # - `return true if type.is_a?(Type::Dynamic) || ...Top` and the `union_contains_nil?` arm of
    #   `rigor_type_admits_nil?`, and `rigor_type_accepts_arg?`'s `Dynamic` / `Top` test: a `rigor:v1:param`
    #   override carries only a refinement carrier or a class name (`NilClass` reaches the `nil_member?` arm and is
    #   pinned); `untyped` and `non-empty-string | nil` were tried and the parameter kept its RBS type.
    # - `return true if loader.nil?` and `return true if methods.nil? || methods.empty?` in the two
    #   interface helpers: the environment of an indexed snippet always has a loader, and an interface
    #   with no methods (`_Empty`, tried) makes `all?` true exactly as the guard does.
    # - `return false if arg_type.is_a?(Type::Union)`, `...Singleton)` and `return false if
    #   class_name.nil?` in `single_concrete_arg_class?`: a union (two classes, tried), a `Dynamic`
    #   argument and a class object each reach one of the others, or the class-object channel that
    #   precedes it.
    # - the `Dynamic` / `Top` short circuits of `class_instance_accepts_arg?`, `read_argument_mismatch`
    #   (both) and `plain_argument_rejects?` (both): `Acceptance.accepts` answers yes for either side,
    #   so the line after answers as they do (tried `untyped`, `top` and `Object` parameters and
    #   arguments).
    # - the `nil_member?` line of `plain_argument_rejects?`: a written nil reaches the same verdict through the
    #   translated parameter (`$VERBOSE = nil` read against `Integer`, `Integer?` and an overload set, tried).
    # - `return true if class_name.nil?` and `return true if definition.nil?` in
    #   `interface_accepts_arg?` / `arg_class_has_method?`: `single_concrete_arg_class?` has already
    #   required a concrete RBS-known class.
    # - `return false unless DeclarationSourcedGuard.gradual_narrowed?`, `return true if rest.empty?`
    #   and `return true if rest.size == members.size`: widening a parameter keeps its classes, so an
    #   argument that is not a narrowed `Dynamic` is rejected before and after; an empty `rest` is the
    #   empty union, which every parameter accepts.
    # - `return false unless arg_type.is_a?(Type::Union)`, `... union_contains_nil?` and `return false
    #   if non_nil.is_a?(Type::Bot)` in `declaration_sourced_nil_only_mismatch?`: a read marked
    #   declaration-sourced is a union of nil and something else, never a bare nil, a nil-free union or
    #   a nil-only remainder.
    def calls_in(node, found = [])
      found << node if node.is_a?(Prism::CallNode)
      node.compact_child_nodes.each { |child| calls_in(child, found) }
      found
    end

    def indexed(program, sig)
      environment = Rigor::Environment.for_project(
        signature_paths: [RunnerHelpers.materialise_sig("sink.rbs" => sig || no_runner_sig)]
      )
      Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty(environment: environment))
    end

    # `[line, message]` for each call of `source` the rule reports.
    def fired(source, sig = nil)
      program = Prism.parse(source).value
      scope_index = indexed(program, sig)
      sites = Rigor::Analysis::CheckRules::LexicalMethodSites.new(program)
      calls_in(program).filter_map do |call|
        facts = Rigor::Analysis::CheckRules::CallFacts.new(call, scope_index)
        row = described_class.diagnostic("mem.rb", call, facts, sites)
        [call.location.start_line, row.message] if row
      end
    end

    def no_runner_sig
      <<~RBS
        interface _Stringish
          def to_s: () -> String
        end
        type name_or_id = String | Integer
        class Sink
          def take_int: (Integer value) -> void
          def take_string: (String value) -> void
          def take_nilable: (Integer? value) -> void
          def take_union: (String | Integer value) -> void
          def take_opt: (Integer first, ?Integer second) -> void
          def take_alias: (name_or_id value) -> void
          def take_untyped: (untyped value) -> void
          def take_tos: (_Stringish value) -> void
          def take_tostr: (_ToStr value) -> void
          def take_gen: (Array[Integer] value) -> void
          def take_kw: (Integer value, ?name: String) -> void
          def take_rest: (Integer value, *Integer more) -> void
          def take_tuple: ([Integer, String] value) -> void
          def take_record: ({ a: Integer } value) -> void
          def take_cls: (singleton(String) value) -> void
          def take_missing: (Missing::Thing value) -> void
          def take_mode: ("r" | "w" value) -> void
          def take_num: (1 | 2 value) -> void
          def two: (Integer a, String b) -> void
          %a{rigor:v1:param: value is non-empty-string}
          def take_name: (String? value) -> void
          def pick: (String value) -> void
                  | (Integer value) -> void
          def pick_cls: (singleton(String) value) -> void
                      | (singleton(Symbol) value) -> void
          def take_any: (?) -> void
          %a{rigor:v1:param: value is non-empty-string}
          def take_stub_override: (Missing::Thing value) -> void
          def mix: (Integer a) -> void
                 | (Integer a, String b) -> void
          def pick_rest: (String v) -> void
                       | (Integer v, *Integer more) -> void
          def pick_untyped: (String v) -> void
                          | (?) -> void
          def pick_missing: (Missing::Thing v) -> void
                          | (Integer v) -> void
          def pick_nilable: (String? v) -> void
                          | (Integer v) -> void
          def pick_cls_mix: (singleton(String) v) -> void
                          | (Integer v) -> void
          %a{rigor:v1:param: value is non-empty-string}
          def pick_ov: (String value) -> void
                     | (Integer value) -> void
          %a{rigor:v1:param: value is NilClass}
          def pk_nc: (String value) -> void
                   | (Integer value) -> void
          def ==: (Sink other) -> bool
          def +: (Sink other) -> Sink
          def self.build: (Integer n) -> Sink
        end
      RBS
    end

    def msg(line, parameter, expected, got, method: "take_int", on: "Sink")
      label = parameter ? "parameter `#{parameter}' of `#{method}' on #{on}" : "`#{method}' on #{on}"
      [line, "argument type mismatch at #{label}: expected #{expected}, got #{got}"]
    end

    let(:sink) { "s = Sink.new\n" }

    describe "the single-overload channel" do
      it "reports a class the parameter rejects, at the argument, with the parameter's name" do
        expect(fired(%(#{sink}s.take_int("a")\n))).to eq([msg(2, "value", "Integer", '"a"')])
      end

      it "carries the rule id, the error severity, the receiver class, the method name and the argument's position" do
        program = Prism.parse(%(#{sink}s.take_int("a")\n)).value
        call = calls_in(program).find { |c| c.name == :take_int }
        row = described_class.diagnostic(
          "mem.rb", call, Rigor::Analysis::CheckRules::CallFacts.new(call, indexed(program, nil))
        )

        expect([row.rule, row.severity, row.receiver_type, row.method_name, row.path, row.line, row.column]).to eq(
          [Rigor::Analysis::CheckRules::RULE_ARGUMENT_TYPE, :error, "Sink", "take_int", "mem.rb", 2, 12]
        )
      end

      it "is silent for an accepted argument" do
        expect(fired("#{sink}s.take_int(1)\n")).to eq([])
      end

      it "reports a pure nil the parameter does not admit" do
        expect(fired("#{sink}s.take_int(nil)\n")).to eq([msg(2, "value", "Integer", "nil")])
      end

      it "is silent for a nil the parameter admits" do
        expect([fired("#{sink}s.take_nilable(nil)\n"), fired("#{sink}s.take_untyped(nil)\n")]).to eq([[], []])
      end

      it "reports a nil against a union parameter that has no nil arm, labelled as the RBS wrote it" do
        expect(fired("#{sink}s.take_union(nil)\n")).to eq([msg(2, "value", "String | ::Integer", "nil",
                                                               method: "take_union")])
      end

      it "reports a class outside a union parameter" do
        expect(fired("#{sink}s.take_union(:a)\n")).to eq([msg(2, "value", "Integer | String", ":a",
                                                              method: "take_union")])
      end

      it "checks an optional parameter at its own position" do
        expect([fired(%(#{sink}s.take_opt(1, "x")\n)), fired("#{sink}s.take_opt(1, 2)\n")]).to eq(
          [[msg(2, "second", "Integer", '"x"', method: "take_opt")], []]
        )
      end

      it "reports a nil against a type alias parameter, and a class outside it" do
        expect([fired("#{sink}s.take_alias(nil)\n"), fired("#{sink}s.take_alias(:a)\n")]).to eq(
          [[msg(2, "value", "name_or_id", "nil", method: "take_alias")],
           [msg(2, "value", "Integer | String", ":a", method: "take_alias")]]
        )
      end

      it "reports a nil against an interface the nil class does not implement, and not one it does" do
        expect([fired("#{sink}s.take_tostr(nil)\n"), fired("#{sink}s.take_tos(nil)\n")]).to eq(
          [[msg(2, "value", "_ToStr", "nil", method: "take_tostr")], []]
        )
      end

      it "reports a class against a generic parameter, and a nil, and not a matching argument" do
        expect([fired(%(#{sink}s.take_gen("a")\n)), fired("#{sink}s.take_gen(nil)\n"),
                fired("#{sink}s.take_gen([1])\n")])
          .to eq([[msg(2, "value", "Array[Integer]", '"a"', method: "take_gen")],
                  [msg(2, "value", "Array[::Integer]", "nil", method: "take_gen")], []])
      end

      it "reports a Tuple argument and a HashShape argument the parameter's shape rejects" do
        expect([fired("#{sink}s.take_tuple([1, 2])\n"), fired(%(#{sink}s.take_record({ a: "x" })\n))]).to eq(
          [[msg(2, "value", "[Integer, String]", "[1, 2]", method: "take_tuple")],
           [msg(2, "value", "{ a: Integer }", '{ a: "x" }', method: "take_record")]]
        )
      end

      it "reports a class object the singleton parameter refuses, and not the class it names" do
        expect([fired("#{sink}s.take_cls(Integer)\n"), fired("#{sink}s.take_cls(String)\n")]).to eq(
          [[msg(2, "value", "singleton(String)", "singleton(Integer)", method: "take_cls")], []]
        )
      end

      it "reports one member of a union argument, with the whole union as the actual" do
        source = "def t(c)\n  s = Sink.new\n  v = c ? \"a\" : 1\n  s.take_int(v)\nend\n"

        expect(fired(source)).to eq([msg(4, "value", "Integer", '"a" | 1')])
      end

      it "reports a nilable argument to a non-nil parameter" do
        source = "def t(c)\n  s = Sink.new\n  v = c ? 1 : nil\n  s.take_int(v)\nend\n"

        expect(fired(source)).to eq([msg(4, "value", "Integer", "1?")])
      end

      it "reports a call on a singleton receiver" do
        expect(fired(%(Sink.build("a")\n))).to eq([msg(1, "n", "Integer", '"a"', method: "build", on: "Sink")])
      end

      it "reports through safe navigation, and a block-pass beside the argument" do
        expect([fired(%(#{sink}s&.take_int("a")\n)).size, fired(%(#{sink}b = proc {}\ns.take_int("a", &b)\n)).size])
          .to eq([1, 1])
      end

      it "judges a refinement-typed parameter by its refinement, not its RBS class" do
        expect([fired("#{sink}s.take_name(nil)\n"), fired(%(#{sink}s.take_name("")\n))]).to eq(
          [[msg(2, "value", "String?", "nil", method: "take_name")],
           [msg(2, "value", "non-empty-string", '""', method: "take_name")]]
        )
      end
    end

    describe "the shapes the rule declines" do
      it "is silent for an implicit-self call" do
        expect(fired(%(class Sink\n  def go = take_int("a")\nend\n))).to eq([])
      end

      it "is silent for a call with a splat" do
        expect(fired(%(#{sink}a = ["x"]\ns.take_int(*a)\n))).to eq([])
      end

      it "is silent for a call passing keywords" do
        expect(fired(%(#{sink}s.take_kw("a", name: "n")\n))).to eq([])
      end

      it "is silent for a call forwarding `...`" do
        expect(fired(%(def t(...) = Sink.new.take_int(...)\n))).to eq([])
      end

      it "is silent for a signature with a rest positional" do
        expect(fired(%(#{sink}s.take_rest("a")\n))).to eq([])
      end

      it "is silent for the universal-equality methods, whatever their signature says" do
        expect(fired("#{sink}s == 1\n")).to eq([])
      end

      it "is silent for an argument or a parameter that is `Dynamic`" do
        expect([fired("#{sink}s.take_untyped(1)\n"), fired("def t(x)\n  Sink.new.take_int(x)\nend\n")]).to eq([[], []])
      end

      it "is silent for a parameter naming a class nothing declares" do
        expect(fired("#{sink}s.take_missing(1)\n")).to eq([])
      end

      it "is silent for an `untyped` signature, which has no per-arity accessors" do
        expect([fired(%(#{sink}s.take_any("a")\n)), fired("#{sink}s.pick_untyped(:a)\n")]).to eq([[], []])
      end

      it "is silent for an argument beyond the signature's last positional, which `call.wrong-arity` owns" do
        expect(fired("#{sink}s.take_int(1, 2)\n")).to eq([])
      end

      it "is silent for a receiver whose class the project declares but no signature does" do
        expect(fired(%(class Foo\n  def f(a) = a\nend\nFoo.new.f(1)\n))).to eq([])
      end

      it "is silent for a method the signature does not declare" do
        expect(fired(%(#{sink}s.nothing("a")\n))).to eq([])
      end

      it "judges a parameter naming an undeclared class by its `rigor:v1:param` override" do
        expect(fired(%(#{sink}s.take_stub_override("")\n))).to eq(
          [msg(2, "value", "non-empty-string", '""', method: "take_stub_override")]
        )
      end

      it "reports a `Class` whose identity inference lost against a parameter that is not a class object" do
        source = "def t(n)\n  c = Object.const_get(n)\n  Sink.new.take_int(c) if c.is_a?(Class)\nend\n"

        expect(fired(source)).to eq([msg(3, "value", "Integer", "Class")])
      end

      it "is silent for a global the file writes a nil to when the parameter admits nil" do
        expect(fired("$VERBOSE = nil\n#{sink}s.take_nilable($VERBOSE)\n")).to eq([])
      end

      it "is silent for a nil against overloads whose `rigor:v1:param` override is `NilClass`" do
        expect(fired("#{sink}s.pk_nc(nil)\n")).to eq([])
      end

      it "judges a read of a builtin global by what the file wrote to it, in the message too" do
        source = %($PROGRAM_NAME = "x"\nclass Q\n  def f\n    Sink.new.take_int($PROGRAM_NAME)\n  end\nend\n)

        expect(fired(source)).to eq([msg(4, "value", "Integer", '"x"')])
      end

      it "is silent for a builtin global the file wrote a value the parameter accepts" do
        source = %($PROGRAM_NAME = "x"\nclass Q\n  def f\n    Sink.new.take_string($PROGRAM_NAME)\n  end\nend\n)

        expect(fired(source)).to eq([])
      end

      it "withholds the members of a joined global the file never writes" do
        source = %($PROGRAM_NAME = "r"\ndef f\n  Sink.new.take_mode(rand > 0.5 ? $PROGRAM_NAME : "w")\nend\n)

        expect(fired(source)).to eq([])
      end

      it "is silent for a nil read from a constructor-seeded ivar that no method writes" do
        holder = "class Holder\n  def initialize\n    @c = nil\n  end\n\n  def f\n    BODY\n  end\nend\n"

        expect([fired(holder.sub("BODY", "Sink.new.take_int(@c)")), fired(holder.sub("BODY", "Sink.new.pick(@c)")),
                fired(holder.sub("BODY", "c = @c\n    Sink.new.pick(c)"))]).to eq([[], [], []])
      end

      it "judges a builtin global by the file's writes to it: a written value reports, a bare seed does not" do
        expect([fired("#{sink}s.take_int($VERBOSE)\n"),
                fired("$VERBOSE = true\n#{sink}s.take_int($VERBOSE)\n"),
                fired("$VERBOSE = true\nv = $VERBOSE\n#{sink}s.take_int(v)\n"),
                fired("$VERBOSE = nil\n#{sink}s.pick($VERBOSE)\n"),
                fired("$VERBOSE = true\n#{sink}s.pick($VERBOSE)\n")]).to eq(
                  [[], [msg(3, "value", "Integer", "true")], [msg(4, "value", "Integer", "true")],
                   [msg(3, nil, "String | Integer", "nil", method: "pick")],
                   [msg(3, nil, "String | Integer", "true", method: "pick")]]
                )
      end

      it "is silent for a receiver whose class the environment does not know" do
        expect(fired(%(Nowhere.new.take_int("a")\n))).to eq([])
      end

      it "is silent under a refinement of the receiver's class that redefines the method" do
        source = "module R\n  refine Sink do\n    def take_int(a) = a\n  end\nend\nusing R\nSink.new.take_int(\"a\")\n"

        expect(fired(source)).to eq([])
      end

      it "reports under a refinement of the class that does not touch the method" do
        source = "module R\n  refine Sink do\n    def other = 1\n  end\nend\nusing R\nSink.new.take_int(\"a\")\n"

        expect(fired(source).map(&:first)).to eq([7])
      end

      it "is silent for a nil argument beside a keyword-bearing signature, and still reports a wrong class" do
        source = "def t(c)\n  s = Sink.new\n  v = c ? 1 : nil\n  s.take_kw(v)\nend\n"

        expect([fired("#{sink}s.take_kw(nil)\n"), fired(source), fired(%(#{sink}s.take_kw("a")\n)).size]).to eq(
          [[], [], 1]
        )
      end

      it "is silent for a nil read from a class's constructor-seeded ivar, and reports one the method wrote itself" do
        holder = "class Holder\n  def initialize\n    @count = nil\n  end\n\n  def bump\n    @count = 1\n  end\n\n  " \
                 "def flush\n    BODY\n  end\nend\n"

        expect([fired(holder.sub("BODY", "Sink.new.take_int(@count)")),
                fired(holder.sub("BODY", "@count = nil\n    Sink.new.take_int(@count)")).map(&:first)]).to eq(
                  [[], [12]]
                )
      end

      it "judges a class-guarded local by its class, not by the literals the parameter names" do
        guarded = "def t(x)\n  Sink.new.%s(x) if x.is_a?(String)\nend\n"

        expect([fired(guarded % "take_mode"), fired(guarded % "take_num").size]).to eq([[], 1])
      end
    end

    describe "the multi-overload channels" do
      it "reports a nil no overload admits, and a single class no overload admits" do
        expect([fired("#{sink}s.pick(nil)\n"), fired("#{sink}s.pick(:a)\n"), fired("#{sink}s.pick(1.5)\n")]).to eq(
          [[msg(2, nil, "String | Integer", "nil", method: "pick")],
           [msg(2, nil, "String | Integer", ":a", method: "pick")],
           [msg(2, nil, "String | Integer", "1.5", method: "pick")]]
        )
      end

      it "is silent when one overload accepts the argument" do
        expect([fired(%(#{sink}s.pick("a")\n)), fired("#{sink}s.pick(1)\n")]).to eq([[], []])
      end

      it "reports a class object every singleton overload refuses, and not one an overload names" do
        expect([fired("#{sink}s.pick_cls(Integer)\n"), fired("#{sink}s.pick_cls(Symbol)\n"),
                fired(%(#{sink}s.pick_cls("x")\n))])
          .to eq([[msg(2, nil, "singleton(String) | singleton(Symbol)", "singleton(Integer)", method: "pick_cls")], [],
                  []])
      end

      it "decides an interface-alias parameter on what the argument's class implements" do
        expect([fired("a = [1]\na.fetch(nil)\n"), fired("a = [1]\na.fetch(:a)\n"),
                fired("a = [1]\na.fetch(1.5)\n")]).to eq(
                  [[[2, "argument type mismatch at `fetch' on Array: expected int | _ToInt, got nil"]],
                   [[2, "argument type mismatch at `fetch' on Array: expected int | _ToInt, got :a"]], []]
                )
      end

      it "is silent for a union argument, which the non-nil channel defers" do
        expect(fired("def t(c)\n  a = [1]\n  a.fetch(c ? :a : \"s\")\nend\n")).to eq([])
      end

      it "judges every overload's parameter by the `rigor:v1:param` override, whatever its RBS class says" do
        expect([fired(%(#{sink}s.pick_ov("")\n)), fired(%(#{sink}s.pick_ov("abc")\n))]).to eq(
          [[msg(2, nil, "String | Integer", '""', method: "pick_ov")], []]
        )
      end

      it "is silent for a method whose overloads disagree on the arity at the argument's position" do
        expect([fired("#{sink}s.mix(1, 2)\n"), fired(%(#{sink}s.mix("a")\n))]).to eq(
          [[], [msg(2, nil, "Integer", '"a"', method: "mix")]]
        )
      end

      it "is silent when an overload takes a rest positional or names an undeclared class" do
        expect([fired("#{sink}s.pick_rest(:a)\n"), fired("#{sink}s.pick_missing(:a)\n"),
                fired("#{sink}s.pick_missing(nil)\n")]).to eq([[], [], []])
      end

      it "is silent for a nil an overload admits, and for a class an optional overload may admit" do
        expect([fired("#{sink}s.pick_nilable(nil)\n"), fired("#{sink}s.pick_nilable(:a)\n")]).to eq([[], []])
      end

      it "is silent for a union argument of two classes and for an argument typed `Dynamic`" do
        union = "def t(c)\n  Sink.new.pick(c ? :a : 1.5)\nend\n"

        expect([fired(union), fired("def t(x)\n  Sink.new.pick(x)\nend\n")]).to eq([[], []])
      end

      it "is silent for a class object when any overload takes something else, or the class is not RBS-known" do
        expect([fired("#{sink}s.pick_cls_mix(Integer)\n"), fired("class Foo; end\nSink.new.pick_cls_mix(Foo)\n")])
          .to eq([[], []])
      end

      it "reports a nil on a coerce-dispatched operator, and no other argument" do
        expect([fired("x = 5\nx * nil\n").size, fired(%(x = 5\nx * "y"\n)), fired(%(x = 5\nx + :a\n))]).to eq(
          [1, [], []]
        )
      end
    end
  end
end
