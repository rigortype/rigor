# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# The `call.argument-type-mismatch` family's *unobserved* half — check_rules.rb ~L2095-2506. Two per-topic
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
RSpec.describe "argument-type mismatch (provenance gate, param overrides, acceptance walk)" do
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
        def plain_pick: (String value) -> void
                      | (Integer value) -> void
        %a{rigor:v1:param: value is non-empty-string}
        def pick: (String value) -> void
                | (Integer value) -> void
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
        Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
                               .run(%w[app.rb])
                               .diagnostics
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

  describe "argument_check_eligible?" do
    it "declines a method whose overload carries an optional keyword" do
      # `take_opt_kw`'s `?name:` makes `optional_keywords` non-empty, so the whole method is ineligible and
      # its blatantly wrong `nil` positional is never checked. The `take_int(nil)` example above is the
      # adjacent must-still-fire: identical call shape, identical param type, no keyword.
      expect(arg_mismatches(%(Sink.new.take_opt_kw(nil)\n))).to be_empty
    end
  end

  describe "translate_param_type" do
    # The `rescue StandardError` arm (survivor L2488) is a defensive fallback with no fixture that reaches
    # it — every RBS type the analyzer hands it is translatable — so this one method is observed by a direct
    # call rather than through the rule.
    it "translates a well-formed RBS type" do
      translated = Rigor::Analysis::CheckRules.send(:translate_param_type, RBS::Parser.parse_type("Integer"), nil)
      expect(translated.describe(:short)).to eq("Integer")
    end

    it "falls back to untyped when the translator raises" do
      # A non-RBS object makes `RbsTypeTranslator.translate` raise; the rescue must yield gradual `untyped`,
      # which every caller reads as "admits everything" and declines on. A mutant that let the exception
      # escape would crash the whole run.
      translated = Rigor::Analysis::CheckRules.send(:translate_param_type, Object.new, nil)
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
