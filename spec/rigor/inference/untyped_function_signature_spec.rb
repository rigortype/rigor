# frozen_string_literal: true

# Issue #1430 — a `sig/` method declared with the untyped-parameters form `(?)` (`RBS::Types::UntypedFunction`)
# crashed analysis of the method body: `MethodParameterBinder` read `required_positionals` off the declared
# function, which `UntypedFunction` does not have, and the whole file failed with an internal analyzer error.
# The call-site paths are covered by `method_dispatcher/untyped_function_overload_spec.rb`; this file covers the
# body-binding path and the other readers that pair a declared parameter list with something.
RSpec.describe "(?) signatures on method bodies and effects (RBS::Types::UntypedFunction)", type: :runner do
  let(:sig) do
    {
      "c.rbs" => <<~RBS
        class C
          def uf2: (?) -> Integer
          def every_kind: (?) -> Integer

          %a{rigor:v1:assert value is String}
          def assert_string: (?) -> void

          %a{rigor:v1:predicate-if-true value is String}
          def string?: (?) -> bool

          %a{rigor:v1:assert value is String}
          def assert_mixed: (?) -> void
                          | (untyped value) -> void

          %a{rigor:v1:predicate-if-true value is String}
          def mixed_string?: (?) -> bool
                           | (untyped value) -> bool

          def with_block: () { (?) -> void } -> Integer
          def with_proc: (^(?) -> Integer callback) -> Integer
        end
      RBS
    }
  end

  it "analyses the body of a `(?)` method with every parameter bound to Dynamic[top]" do
    result = analyze(<<~RUBY, sig: sig)
      class C
        def uf2(a, b) = 1

        def every_kind(a, b = 1, *rest, c, d:, e: 1, **kw, &blk)
          a.bogus_a
          b.bogus_b
          rest.bogus_rest
          d.bogus_d
          kw.bogus_kw
          1
        end
      end
    RUBY

    expect(result.diagnostics).to be_empty
  end

  it "still applies the declared return type of a `(?)` method" do
    result = analyze(<<~RUBY, sig: sig)
      class C
        def uf2(a, b) = 1
      end

      C.new.uf2(1, 2).bogus_method
    RUBY

    diagnostic = result.diagnostics.find { |d| d.rule == "call.undefined-method" }
    expect(diagnostic).not_to be_nil
    expect(diagnostic.message).to include("bogus_method")
    expect(diagnostic.message).to include("Integer")
  end

  it "resolves no parameter for an `assert` effect targeting a `(?)` method's parameter" do
    result = analyze(<<~RUBY, sig: sig)
      def probe(x)
        c = C.new
        c.assert_string(x)
        x.upcase
      end
    RUBY

    expect(result.diagnostics).to be_empty
  end

  it "resolves no parameter for a predicate effect targeting a `(?)` method's parameter" do
    result = analyze(<<~RUBY, sig: sig)
      def probe(x)
        c = C.new
        x.upcase if c.string?(x)
      end
    RUBY

    expect(result.diagnostics).to be_empty
  end

  it "maps an effect's target through a named overload beside a `(?)` one" do
    result = analyze(<<~RUBY, sig: sig)
      def asserted(x)
        C.new.assert_mixed(x)
        x.bogus_asserted
      end

      def predicated(x)
        x.bogus_predicated if C.new.mixed_string?(x)
      end
    RUBY

    messages = result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:message)
    expect(messages).to contain_exactly(
      a_string_including("bogus_asserted").and(including("String")),
      a_string_including("bogus_predicated").and(including("String"))
    )
  end

  it "accepts `(?)` as a block type and as a proc parameter type" do
    result = analyze(<<~RUBY, sig: sig)
      class C
        def with_block(&blk) = 1
        def with_proc(callback) = callback.call(1)
      end

      c = C.new
      c.with_block { |a, b| a.bogus_a }
      c.with_proc(->(q) { 1 })
    RUBY

    expect(result.diagnostics).to be_empty
  end
end
