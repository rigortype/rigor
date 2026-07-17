# frozen_string_literal: true

# `RBS::Types::UntypedFunction` is the `(?)` method type -- core RBS ships it on `Proc#call`,
# `Method#call`, `Ractor.select` and `IO.for_fd`, and a project may hand-write it. It exposes none of
# the per-arity accessors (`required_positionals` and friends), so every dispatcher site that reaches
# for them must bail rather than raise. Before these guards landed, `ReceiverAffinity.reorder` raised
# `NoMethodError` on the form; a broad `rescue StandardError` in the dispatcher swallowed it and the
# whole dispatch degraded to `Dynamic[top]`, silently discarding the declared return type.
RSpec.describe "(?) method types (RBS::Types::UntypedFunction)", type: :runner do
  let(:sig) do
    {
      "widget.rbs" => <<~RBS
        class Widget
          def untyped_fn: (?) -> String
          def normal: (Integer) -> String
          def overloaded: (?) -> String
                        | (Integer) -> Integer
        end
      RBS
    }
  end

  def undefined_method_diagnostics(result)
    result.diagnostics.select { |d| d.rule == "call.undefined-method" }
  end

  it "adopts the declared return type of a `(?)` method" do
    result = analyze(<<~RUBY, sig: sig)
      w = Widget.new
      w.untyped_fn.bogus_method
    RUBY

    diagnostic = undefined_method_diagnostics(result).first
    expect(diagnostic).not_to be_nil
    expect(diagnostic.message).to include("bogus_method")
    expect(diagnostic.message).to include("String")
  end

  it "constrains no arity or argument type at a `(?)` call site" do
    result = analyze(<<~RUBY, sig: sig)
      w = Widget.new
      w.untyped_fn
      w.untyped_fn(1)
      w.untyped_fn(1, 2, 3)
      w.untyped_fn("a", key: 2)
    RUBY

    expect(result.diagnostics).to be_empty
  end

  it "never lets a leading `(?)` overload beat a strictly-typed sibling" do
    result = analyze(<<~RUBY, sig: sig)
      w = Widget.new
      w.overloaded(1).bogus_method
    RUBY

    # `(Integer) -> Integer` must win over the `(?) -> String` arm that precedes it in the overload
    # list: `(?)` declares no params, so it would otherwise match vacuously in the strict pass.
    diagnostic = undefined_method_diagnostics(result).first
    expect(diagnostic).not_to be_nil
    expect(diagnostic.message).to include("Integer")
  end

  it "leaves a strictly-typed method's diagnostics unchanged" do
    result = analyze(<<~RUBY, sig: sig)
      w = Widget.new
      w.normal(1).bogus_method
      w.normal("wrong")
      w.normal(1, 2)
    RUBY

    rules = result.diagnostics.map(&:rule)
    expect(rules).to include("call.undefined-method")
    expect(rules).to include("call.argument-type-mismatch")
    expect(rules).to include("call.wrong-arity")
  end
end
