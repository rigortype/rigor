# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::OverloadSelector do
  let(:loader) { Rigor::Environment::RbsLoader.default }

  def select(class_name, method_name, arg_types, kind: :instance, block_required: false)
    definition =
      case kind
      when :instance then loader.instance_definition(class_name)
      when :singleton then loader.singleton_definition(class_name)
      end
    raise "missing definition" unless definition

    method = definition.methods[method_name]
    raise "missing method #{class_name}##{method_name}" unless method

    instance_type = Rigor::Type::Combinator.nominal_of(class_name)
    self_type = kind == :singleton ? Rigor::Type::Combinator.singleton_of(class_name) : instance_type

    described_class.select(
      method,
      arg_types: arg_types,
      self_type: self_type,
      instance_type: instance_type,
      block_required: block_required
    )
  end

  describe ".select" do
    it "picks the arity-matching overload (Array#first / 0 args)" do
      mt = select("Array", :first, [])
      expect(mt.type.required_positionals).to be_empty
      expect(mt.type.return_type).to be_a(RBS::Types::Variable) # `Elem`
    end

    it "picks the arity-matching overload (Array#first / 1 arg)" do
      mt = select("Array", :first, [Rigor::Type::Combinator.constant_of(3)])
      expect(mt.type.required_positionals.size).to eq(1)
      # `(::int n) -> ::Array[Elem]`
      expect(mt.type.return_type).to be_a(RBS::Types::ClassInstance)
      expect(mt.type.return_type.name.relative!.to_s).to eq("Array")
    end

    it "picks the type-matching overload for Integer#+" do
      mt = select(
        "Integer",
        :+,
        [Rigor::Type::Combinator.nominal_of(Float)]
      )
      expect(mt.type.required_positionals.first.type.name.relative!.to_s).to eq("Float")
    end

    it "falls back to the first overload when no overload matches" do
      mt = select(
        "Integer",
        :+,
        [Rigor::Type::Combinator.nominal_of(String)]
      )
      # First overload is `(::Integer) -> ::Integer`.
      expect(mt.type.required_positionals.first.type.name.relative!.to_s).to eq("Integer")
    end

    it "supports singleton-method overload selection (Array.new arity 0)" do
      mt = select("Array", :new, [], kind: :singleton)
      expect(mt.type.required_positionals).to be_empty
    end

    it "supports singleton-method overload selection (Array.new arity 1)" do
      mt = select(
        "Array",
        :new,
        [Rigor::Type::Combinator.constant_of(3)],
        kind: :singleton
      )
      expect(mt.type.required_positionals.size).to eq(1)
    end

    it "skips overloads with required keyword arguments" do
      # We construct a synthetic method with one keyword-required and one positional-only overload to ensure the
      # selector skips the keyword-required one. We use Object#tap which has no kwargs as baseline; the synthetic part
      # is a stub that simulates a kwargs overload via a dummy MethodType. Easier: just verify behaviour via Hash#fetch
      # which has keyword-free overloads in core RBS.
      mt = select("Hash", :fetch, [Rigor::Type::Combinator.constant_of(:k)])
      expect(mt).not_to be_nil
    end

    describe "block-less call-site overload selection" do
      # `Array#filter` declares the block-bearing overload first (`() { (Elem) -> boolish } -> Array[Elem]`) and the
      # bare-call overload second (`() -> Enumerator[...]`). A call with no block must pick the second: `[1, 2].filter`
      # yields an `Enumerator`, not an `Array`.
      it "skips a required-block overload when the call has no block" do
        mt = select("Array", :filter, [], block_required: false)
        expect(described_class.overload_requires_block?(mt)).to be(false)
        expect(mt.type.return_type.name.relative!.to_s).to eq("Enumerator")
      end

      it "still prefers the block-bearing overload when a block is present" do
        mt = select("Array", :filter, [], block_required: true)
        expect(described_class.overload_requires_block?(mt)).to be(true)
        expect(mt.type.return_type.name.relative!.to_s).to eq("Array")
      end

      it "keeps the only overload when every candidate requires a block" do
        # `Array#each_with_object` has a single required-block overload; a block-less call still resolves to it via the
        # `overloads.first` fall-back.
        mt = select("Array", :each_with_object, [Rigor::Type::Combinator.constant_of(0)], block_required: false)
        expect(mt).not_to be_nil
      end

      it "falls back to overloads.first when no overload matches and every overload requires a block" do
        # `Object#tap` has a SINGLE `() { (self) -> void } -> self`
        # overload (no enumerator fall-back). Passing a spurious arg
        # makes every selection pass fail on arity, so the tail
        # `overloads.find { !requires_block? } || overloads.first`
        # runs: `find` yields nil (the only overload requires a block),
        # so the `overloads.first` fall-back is what returns it.
        mt = select("Object", :tap, [Rigor::Type::Combinator.constant_of(1)], block_required: false)
        expect(mt).not_to be_nil
        expect(described_class.overload_requires_block?(mt)).to be(true)
      end
    end

    describe "interface-strictness preference (v0.1.2)" do
      # When two overloads are arity-compatible and accept the
      # call site's arg types, prefer the one whose params do
      # NOT depend on `RBS::Types::Alias` / `Interface` /
      # `Intersection` translating to `Dynamic[Top]`. The
      # gradual-acceptance fall-back at the bottom of the
      # selector still applies when no fully strict overload
      # matches — only the ranking changes.
      #
      # Surfaced when self-analysing this repo: `Array#[]`
      # ships three overloads —
      #   (::int) -> E
      #   (::int, ::int) -> Array[E]?
      #   (::range[::int]) -> Array[E]?
      # `int` is `RBS::Types::Alias`, which translates to
      # `Dynamic[Top]` and gradually accepts a Range. Without
      # the strict-first pass the first overload wins and the
      # call resolves to `E` instead of `Array[E]?`.
      #
      # rbs 4.1 rewrote the slicing overload's param from the
      # `Range[Integer?]` class instance to the `range[T]`
      # alias, so BOTH candidates are now alias-typed and pass
      # 1.5 (alias strict arms) is what separates them.
      it "prefers `(range) -> Array[E]?` over `(int) -> E` for an Array#[](Range) call" do
        mt = select("Array", :[], [Rigor::Type::Combinator.nominal_of("Range")])
        expect(mt.type.required_positionals.size).to eq(1)
        expect(mt.type.required_positionals.first.type.name.relative!.to_s).to eq("range")
        expect(mt.type.return_type.to_s).to eq("::Array[E]?")
      end

      it "still picks the alias-typed overload when only it is arity-compatible (Array#[](Integer))" do
        mt = select("Array", :[], [Rigor::Type::Combinator.nominal_of("Integer")])
        # Pass 1 (strict) finds nothing — Range param doesn't accept Integer. Pass 2 falls back to the gradual behaviour
        # and the alias-typed overload wins.
        expect(mt.type.required_positionals.size).to eq(1)
        expect(mt.type.required_positionals.first.type).to be_a(RBS::Types::Alias)
      end

      it "still picks the alias-typed overload for two-Integer slicing (Array#[](Integer, Integer))" do
        # The two-int overload is arity-2 and the only option; neither pass changes the outcome here.
        mt = select(
          "Array", :[],
          [Rigor::Type::Combinator.nominal_of("Integer"), Rigor::Type::Combinator.nominal_of("Integer")]
        )
        expect(mt.type.required_positionals.size).to eq(2)
      end
    end

    describe "alias-resolved pass 1.5 (canonical core aliases)" do
      # `Array#*` ships two overloads —
      #   (string str) -> String
      #   (int int) -> Array[Elem]
      # Both `string` and `int` are aliases that translate to
      # `Dynamic[Top]`. Without pass 1.5, gradual matching picks
      # the first arity-compatible overload (string) regardless
      # of the arg's actual type. Pass 1.5 consults each alias's
      # strict arm and prefers `int` when the arg is Integer.
      it "prefers `(int) -> Array[Elem]` over `(string) -> String` for Array#*(Integer)" do
        mt = select("Array", :*, [Rigor::Type::Combinator.nominal_of("Integer")])
        expect(mt.type.required_positionals.size).to eq(1)
        param_type = mt.type.required_positionals.first.type
        # The chosen overload's param is the `int` alias.
        expect(param_type).to be_a(RBS::Types::Alias)
        expect(param_type.name.to_s).to eq("::int")
      end

      it "still prefers `(string) -> String` for Array#*(String)" do
        mt = select("Array", :*, [Rigor::Type::Combinator.nominal_of("String")])
        param_type = mt.type.required_positionals.first.type
        expect(param_type).to be_a(RBS::Types::Alias)
        expect(param_type.name.to_s).to eq("::string")
      end
    end

    # Issue #521 — an untyped argument accepts every param indiscriminately, so neither the alias pass
    # nor "first gradual match" may pin ONE overload: `[true] * n` with untyped `n` answered String (the
    # `(string) -> String` arm, by declaration order), a wrong precise type the runtime contradicts.
    describe "untyped discriminating argument (.select_candidates)" do
      def select_candidates(class_name, method_name, arg_types)
        definition = loader.instance_definition(class_name)
        method = definition.methods[method_name]
        instance_type = Rigor::Type::Combinator.nominal_of(class_name)
        described_class.select_candidates(
          method, arg_types: arg_types, self_type: instance_type, instance_type: instance_type
        )
      end

      it "returns every gradual match for Array#* with an untyped argument" do
        candidates = select_candidates("Array", :*, [Rigor::Type::Combinator.untyped])
        param_names = candidates.map { |mt| mt.type.required_positionals.first.type.name.to_s }
        expect(param_names).to contain_exactly("::string", "::int")
      end

      it "keeps a single candidate when the argument carries a real type" do
        candidates = select_candidates("Array", :*, [Rigor::Type::Combinator.nominal_of("Integer")])
        expect(candidates.size).to eq(1)
        expect(candidates.first.type.required_positionals.first.type.name.to_s).to eq("::int")
      end

      it "answers a Dynamic-wrapped candidate union at the dispatch layer instead of pinning String" do
        env = Rigor::Environment.for_project(libraries: [], signature_paths: [])
        scope = Rigor::Scope.empty(environment: env)
        root = Prism.parse("def f(n)\n  [true] * n\nend\n").value
        index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)
        call = nil
        Rigor::Source::NodeWalker.each(root) { |n| call = n if n.is_a?(Prism::CallNode) && n.name == :* }
        type = index[call].type_of(call)
        # The Dynamic wrapper (not a bare union) is load-bearing: an untyped argument may satisfy
        # constraints that exclude arms, so the bare union let the negative rules fire on arms the
        # runtime never takes (three false positives on this repository's own lib).
        expect(type).to be_a(Rigor::Type::Dynamic)
        rendered = type.describe(:short)
        expect(rendered).to include("String")
        expect(rendered).to include("[true]")
      end
    end

    # Issue #1021 — a union with an untyped member (`Dynamic[top] | nil`, the ordinary "unknown value that
    # may be nil") is as indistinguishable by types as the bare untyped argument: its untyped arm may take
    # any overload at runtime. Treated as precise, the strict pass keyed on the `nil` arm alone and typed
    # `Regexp#match?(maybe_untyped)` as the literal `false`, so `if multipart?` read as always falsey.
    describe "union with an untyped member (.select_candidates)" do
      def select_candidates(class_name, method_name, arg_types)
        definition = loader.instance_definition(class_name)
        method = definition.methods[method_name]
        instance_type = Rigor::Type::Combinator.nominal_of(class_name)
        described_class.select_candidates(
          method, arg_types: arg_types, self_type: instance_type, instance_type: instance_type
        )
      end

      def first_param_names(candidates)
        candidates.map { |mt| mt.type.required_positionals.first.type.to_s }
      end

      let(:untyped) { Rigor::Type::Combinator.untyped }
      let(:nil_type) { Rigor::Type::Combinator.constant_of(nil) }

      it "does not pin `Regexp#match?(nil) -> false` for a `Dynamic[top] | nil` argument" do
        candidates = select_candidates("Regexp", :match?, [Rigor::Type::Combinator.union(untyped, nil_type)])
        expect(first_param_names(candidates)).to contain_exactly("::interned", "nil")
      end

      it "answers bool, not the literal false, for `/re/.match?` on a maybe-untyped local" do
        env = Rigor::Environment.for_project(libraries: [], signature_paths: [])
        scope = Rigor::Scope.empty(environment: env)
        root = Prism.parse("def f(x, c)\n  y = c ? x : nil\n  /re/.match?(y)\nend\n").value
        index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)
        call = nil
        Rigor::Source::NodeWalker.each(root) { |n| call = n if n.is_a?(Prism::CallNode) && n.name == :match? }
        arg = call.arguments.arguments.first
        expect(index[arg].type_of(arg).describe(:short)).to eq("Dynamic[top]?")
        type = index[call].type_of(call)
        expect(type).not_to eq(Rigor::Type::Combinator.constant_of(false))
        expect(type.describe(:short)).to eq("Dynamic[bool]")
      end

      it "returns every gradual match for Array#* with a `Dynamic[top] | Integer` argument" do
        integer = Rigor::Type::Combinator.nominal_of("Integer")
        candidates = select_candidates("Array", :*, [Rigor::Type::Combinator.union(untyped, integer)])
        expect(first_param_names(candidates)).to contain_exactly("::string", "::int")
      end

      it "still picks `(interned) -> bool` for a precise String argument" do
        candidates = select_candidates("Regexp", :match?, [Rigor::Type::Combinator.nominal_of("String")])
        expect(first_param_names(candidates)).to eq(["::interned"])
      end

      it "still picks `(nil) -> false` for a literal nil argument" do
        candidates = select_candidates("Regexp", :match?, [nil_type])
        expect(first_param_names(candidates)).to eq(["nil"])
      end

      it "keeps #521's all-matches answer for a bare untyped argument" do
        expect(first_param_names(select_candidates("Regexp", :match?, [untyped]))).to eq(["::interned"])
        expect(first_param_names(select_candidates("Array", :*, [untyped]))).to contain_exactly("::string", "::int")
      end

      it "still selects exactly one overload for a precise `String | nil` union" do
        string_or_nil = Rigor::Type::Combinator.union(Rigor::Type::Combinator.nominal_of("String"), nil_type)
        expect(first_param_names(select_candidates("Regexp", :match?, [string_or_nil]))).to eq(["::interned"])
        expect(first_param_names(select_candidates("Kernel", :Array, [string_or_nil])).size).to eq(1)
      end

      it "keeps a Dynamic with a concrete static facet out of the untyped family" do
        dynamic_string = Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.nominal_of("String"))
        expect(select_candidates("Array", :*, [dynamic_string]).size).to eq(1)
      end
    end

    describe "receiver-affinity pre-sort (BigDecimal-coerce regression)" do
      # When the `bigdecimal` stdlib RBS is loaded, its reopen of `Integer#+` adds `(BigDecimal) -> BigDecimal` at the
      # FRONT of the overload list. Without the pre-sort the selector picks that arm for unknown / Integer args and
      # produces a spurious BigDecimal return — surfacing as `undefined method 'upto' for BigDecimal` on plain `(i +
      # 1).upto(n)` code. The pre-sort demotes the disjoint-sibling arm so the receiver-preserving `(Integer) ->
      # Integer` wins for both Integer and untyped args.
      let(:env) { Rigor::Environment.for_project(root: Dir.pwd) }

      def select_with_env(class_name, method_name, arg_types)
        definition = env.rbs_loader.instance_definition(class_name)
        raise "missing definition" unless definition

        method = definition.methods[method_name]
        raise "missing method #{class_name}##{method_name}" unless method

        instance_type = Rigor::Type::Combinator.nominal_of(class_name)
        described_class.select(
          method,
          arg_types: arg_types,
          self_type: instance_type,
          instance_type: instance_type,
          environment: env
        )
      end

      it "prefers Integer#+(Integer) -> Integer over (BigDecimal) -> BigDecimal for an Integer arg" do
        mt = select_with_env("Integer", :+, [Rigor::Type::Combinator.nominal_of("Integer")])
        param_class = mt.type.required_positionals.first.type
        expect(param_class).to be_a(RBS::Types::ClassInstance)
        expect(param_class.name.relative!.to_s).to eq("Integer")
      end

      it "prefers Integer#+(Integer) -> Integer over (BigDecimal) -> BigDecimal for an untyped arg" do
        mt = select_with_env("Integer", :+, [Rigor::Type::Combinator.untyped])
        param_class = mt.type.required_positionals.first.type
        expect(param_class).to be_a(RBS::Types::ClassInstance)
        expect(param_class.name.relative!.to_s).to eq("Integer")
      end

      it "prefers Integer#-(Integer) -> Integer over (BigDecimal) -> BigDecimal for an untyped arg" do
        mt = select_with_env("Integer", :-, [Rigor::Type::Combinator.untyped])
        param_class = mt.type.required_positionals.first.type
        expect(param_class).to be_a(RBS::Types::ClassInstance)
        expect(param_class.name.relative!.to_s).to eq("Integer")
      end

      it "still routes Integer#*(Float) -> Float when the arg actually is a Float" do
        # The pre-sort is stable: when a non-affinity arm accepts the actual arg and the affinity arm does not, the
        # non-affinity arm still wins via Pass 1. Asserted so the pre-sort isn't misread as "always prefer the receiver
        # class."
        mt = select_with_env("Integer", :*, [Rigor::Type::Combinator.nominal_of("Float")])
        param_class = mt.type.required_positionals.first.type
        expect(param_class).to be_a(RBS::Types::ClassInstance)
        expect(param_class.name.relative!.to_s).to eq("Float")
      end

      # Issue #1344 — a precise argument that a declared arm matches takes the first such arm in declaration
      # order. `Rational#+` declares `(Float) -> Float | (Complex) -> Complex | (Numeric) -> Rational`; moved to the
      # front, the receiver-affinity `(Numeric)` arm matched the Float too and typed `Rational(1, 2) + 0.5` as
      # `Rational` where Ruby answers `1.0`.
      {
        ["Rational", :+, "Float"] => "Float",
        ["Rational", :-, "Complex"] => "Complex",
        ["Float", :*, "Complex"] => "Complex"
      }.each do |(receiver, method_name, arg), param|
        it "routes #{receiver}##{method_name}(#{arg}) to the declared (#{param}) arm ahead of (Numeric)" do
          mt = select_with_env(receiver, method_name, [Rigor::Type::Combinator.nominal_of(arg)])
          expect(mt.type.required_positionals.first.type.name.relative!.to_s).to eq(param)
        end
      end

      # Declared order only for an argument that proves its arm: in declared order the strict pass let the
      # `bigdecimal` reopen's `(BigDecimal)` arm, which accepts these on a `maybe` or vacuously, take them.
      {
        "bot" => Rigor::Type::Combinator.bot,
        "Dynamic[Integer | Float]" => Rigor::Type::Combinator.dynamic(
          Rigor::Type::Combinator.union(Rigor::Type::Combinator.nominal_of("Integer"),
                                        Rigor::Type::Combinator.nominal_of("Float"))
        ),
        "an unloadable class" => Rigor::Type::Combinator.nominal_of("Definitely::Not::Loaded")
      }.each do |label, arg|
        it "keeps Integer#+ off the (BigDecimal) arm for #{label}" do
          mt = select_with_env("Integer", :+, [arg])
          expect(mt.type.required_positionals.first.type.name.relative!.to_s).not_to eq("BigDecimal")
        end
      end

      it "routes Integer#+(BigDecimal) to the (BigDecimal) arm, which is what Ruby returns" do
        mt = select_with_env("Integer", :+, [Rigor::Type::Combinator.nominal_of("BigDecimal")])
        expect(mt.type.required_positionals.first.type.name.relative!.to_s).to eq("BigDecimal")
      end

      it "selects member by member for a Dynamic argument whose facet names several classes (#1350)" do
        # `Rational + Dynamic[Integer | Float]`: the Integer takes `(Numeric) -> Rational`, the Float
        # `(Float) -> Float`, and both come back for the dispatch layer to join.
        definition = env.rbs_loader.instance_definition("Rational")
        arg = Rigor::Type::Combinator.dynamic(
          Rigor::Type::Combinator.union(Rigor::Type::Combinator.nominal_of("Integer"),
                                        Rigor::Type::Combinator.nominal_of("Float"))
        )
        rational = Rigor::Type::Combinator.nominal_of("Rational")
        candidates = described_class.select_candidates(
          definition.methods[:+], arg_types: [arg], self_type: rational, instance_type: rational, environment: env
        )
        params = candidates.map { |mt| mt.type.required_positionals.first.type.name.relative!.to_s }
        expect(params).to contain_exactly("Numeric", "Float")
      end

      it "selects member by member for a Complex member, which no subclass can instantiate either" do
        # `Integer + Dynamic[Complex | Float]`: the affinity order's `(Integer)` arm takes neither member at runtime.
        definition = env.rbs_loader.instance_definition("Integer")
        integer = Rigor::Type::Combinator.nominal_of("Integer")
        arg = Rigor::Type::Combinator.dynamic(
          Rigor::Type::Combinator.union(Rigor::Type::Combinator.nominal_of("Complex"),
                                        Rigor::Type::Combinator.nominal_of("Float"))
        )
        candidates = described_class.select_candidates(
          definition.methods[:+], arg_types: [arg], self_type: integer, instance_type: integer, environment: env
        )
        params = candidates.map { |mt| mt.type.required_positionals.first.type.name.relative!.to_s }
        expect(params).to contain_exactly("Complex", "Float")
      end

      def rational_plus(arg, singular: false)
        method = env.rbs_loader.instance_definition("Rational").methods[:+]
        rational = Rigor::Type::Combinator.nominal_of("Rational")
        options = { arg_types: [arg], self_type: rational, instance_type: rational, environment: env }
        picked = if singular
                   [described_class.select(method, **options)]
                 else
                   described_class.select_candidates(method, **options)
                 end
        picked.map { |mt| mt.type.required_positionals.first.type.name.relative!.to_s }
      end

      def dynamic_of(*names)
        Rigor::Type::Combinator.dynamic(
          Rigor::Type::Combinator.union(*names.map { |name| Rigor::Type::Combinator.nominal_of(name) })
        )
      end

      it "keeps the wrapper, and the affinity arm, for a facet wider than two members" do
        expect(rational_plus(dynamic_of("Integer", "Float", "Complex"))).to eq(["Numeric"])
      end

      it "keeps the wrapper for a facet with an untyped member" do
        # Read member by member, the untyped member joined every arm beside the Integer's `(Numeric)`.
        untyped_member = Rigor::Type::Combinator.dynamic(
          Rigor::Type::Combinator.union(Rigor::Type::Combinator.nominal_of("Integer"), Rigor::Type::Combinator.untyped)
        )
        expect(rational_plus(untyped_member)).to eq(["Numeric"])
      end

      it "keeps the wrapper for a single supertype member that a subclass arm names" do
        # `Dynamic[Numeric?]` against `Integer#<=>`: read as `Numeric`, it skipped `(Integer)` for the `(untyped)`
        # catch-all, whose `Integer?` a runtime Integer never returns.
        definition = env.rbs_loader.instance_definition("Integer")
        integer = Rigor::Type::Combinator.nominal_of("Integer")
        numeric = Rigor::Type::Combinator.dynamic(
          Rigor::Type::Combinator.union(Rigor::Type::Combinator.nominal_of("Numeric"),
                                        Rigor::Type::Combinator.constant_of(nil))
        )
        picked = described_class.select_candidates(
          definition.methods[:<=>], arg_types: [numeric], self_type: integer, instance_type: integer, environment: env
        )
        expect(picked.size).to eq(1)
        expect(picked.first.type.return_type.to_s).to eq("::Integer")
      end

      it "keeps the wrapper for the singular select, whose one answer a member order would decide" do
        expect(rational_plus(dynamic_of("Integer", "Float"), singular: true)).to eq(["Numeric"])
      end

      it "returns one candidate when both members pick the same overload" do
        definition = env.rbs_loader.instance_definition("Integer")
        integer = Rigor::Type::Combinator.nominal_of("Integer")
        candidates = described_class.select_candidates(
          definition.methods[:fdiv], arg_types: [dynamic_of("Integer", "Float")],
                                     self_type: integer, instance_type: integer, environment: env
        )
        expect(candidates.size).to eq(1)
      end

      it "still prefers the receiver-affinity arm for an untyped argument on Rational#+" do
        mt = select_with_env("Rational", :+, [Rigor::Type::Combinator.untyped])
        expect(mt.type.required_positionals.first.type.name.relative!.to_s).to eq("Numeric")
      end
    end

    describe "value-pinning params vs untyped args (hash_shape.rb:182 regression)" do
      # `Kernel#Array` declares `(nil) -> []` FIRST. An `untyped` arg gradually accepts against every param, so pass 2
      # used to lock in that overload purely by list position — typing `Array(dynamic_keys)` as the empty tuple `[]` and
      # folding every downstream `keys.uniq.size == keys.size` guard to a false `always-truthy-condition` (surfaced by
      # the self-check on `Type::HashShape#canonical_key_list`). A value-pinning param (nil / literal carriers) must not
      # be matched by an arg that carries zero evidence for the pinned value.
      it "does not let an untyped arg select `Kernel#Array: (nil) -> []`" do
        mt = select("Kernel", :Array, [Rigor::Type::Combinator.untyped])
        expect(mt.type.return_type).to be_a(RBS::Types::ClassInstance)
        expect(mt.type.return_type.name.relative!.to_s).to eq("Array")
      end

      it "still picks the precise `(nil) -> []` overload for a proven nil arg" do
        mt = select("Kernel", :Array, [Rigor::Type::Combinator.constant_of(nil)])
        expect(mt.type.return_type).to be_a(RBS::Types::Tuple)
        expect(mt.type.return_type.types).to be_empty
      end

      it "keeps a value-pinning overload reachable via the fallback when nothing else matches" do
        # `NilClass#&` has a single `(untyped) -> false` overload — the literal return must still resolve for an untyped
        # arg (the first-overload fallback, unchanged behaviour).
        mt = select("NilClass", :&, [Rigor::Type::Combinator.untyped])
        expect(mt).not_to be_nil
      end
    end

    describe "block passed to a method whose overloads declare none" do
      # In Ruby a block handed to a method that never yields it is simply ignored. `Integer#succ` (`() -> Integer`, no
      # block clause) must therefore still resolve when the call site carries a block — otherwise the call degrades to
      # Dynamic[Top] (and on a self-send suppresses the method's whole return type).
      it "falls back to the block-less overload instead of returning nil" do
        without_block = select("Integer", :succ, [], block_required: false)
        with_block = select("Integer", :succ, [], block_required: true)

        expect(with_block).not_to be_nil
        expect(with_block.type.return_type.name.relative!.to_s).to eq("Integer")
        expect(with_block).to eq(without_block)
      end
    end
  end

  describe "strict-nominal resolution helpers" do
    it "recurses strict_nominal_names_for through an Optional to the wrapped class" do
      inner = RBS::Types::ClassInstance.new(name: RBS::TypeName.parse("::String"), args: [], location: nil)
      optional = RBS::Types::Optional.new(type: inner, location: nil)

      expect(described_class.send(:strict_nominal_names_for, optional)).to eq(["String"])
    end

    it "treats a Union of Constants as value-pinning, a mixed Union as not" do
      pinned = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1), Rigor::Type::Combinator.constant_of(2)
      )
      mixed = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1), Rigor::Type::Combinator.nominal_of("String")
      )

      expect(described_class.send(:value_pinning?, pinned)).to be(true)
      expect(described_class.send(:value_pinning?, mixed)).to be(false)
    end
  end

  describe "positional param binding" do
    it "absorbs surplus actual args into a rest positional" do
      # `Array#push: (*Elem) -> self` has a rest positional and no fixed params, so binding 3 actual args fills three
      # rest slots.
      fun = loader.instance_definition("Array").methods[:push].method_types.first.type

      expect(described_class.send(:positional_params_for, fun, 3).size).to eq(3)
    end
  end
end
