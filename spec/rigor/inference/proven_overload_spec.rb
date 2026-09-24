# frozen_string_literal: true

require "spec_helper"

# Issue #1344 — `OverloadSelector`'s pass 0 takes an overload in declared order when a plain argument proves it,
# ahead of the receiver-affinity order that moved `Rational#+`'s `(Numeric)` arm in front of its `(Float)` arm. It
# stops at the first arm the argument does not rule out and answers only when that arm names the argument's own class
# with a `yes`. Otherwise the call keeps the affinity-ordered answer. Each example here is a shape an earlier cut
# of pass 0 answered wrongly.
RSpec.describe "proven overload pass", type: :runner do
  def dumped_types(source, sig: {})
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig)
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def rules(source, sig: {})
    analyze(source, sig: sig).diagnostics.map(&:rule).reject { |rule| rule.to_s.start_with?("dump") }
  end

  # Runtime: `1` for every call. The analyzer process cannot load `Base` or `Sub`, so `(Base)` only `maybe` accepts
  # a `Sub`; a later `(top)`, `[T] (T)` or `(Sub)` arm accepts it with a `yes`, and taking that arm typed the call
  # `String` and reported `even?` on it.
  let(:subclass_sig) do
    { "svc.rbs" => <<~RBS }
      class Base
      end
      class Sub < Base
      end
      class Svc
        def handle: (Base) -> Integer
                  | (top) -> String
        def pick: (Base) -> Integer
                | [T] (T) -> T
        def exact: (Base) -> Integer
                 | (Sub) -> String
      end
    RBS
  end

  # Runtime: `"p"` for both. `*Printable` and `printable` (an alias of `Printable`) take the Integer through project
  # RBS, which acceptance cannot see.
  let(:spelled_sig) do
    { "money.rbs" => <<~RBS }
      module Printable
      end
      class Integer
        include Printable
      end
      type printable = Printable
      class Money
        def rest: (*Printable) -> String
                | (Integer) -> Integer
                | (Object) -> Symbol
        def ali: (printable) -> String
               | (Integer) -> Integer
               | (Object) -> Symbol
      end
    RBS
  end

  it "types Rational + Float as the Float core RBS declares first" do
    # Runtime: `Float`.
    expect(dumped_types(<<~RUBY)).to eq(%w[Float Complex])
      def run(v)
        r = Rational(Integer(v), 3)
        dump_type(r + 0.5)
        dump_type(r - Complex(Integer(v), 1))
      end
    RUBY
  end

  it "keeps a project subclass on the first arm that may take it, not a later arm that surely does" do
    source = <<~RUBY
      class Base; end
      class Sub < Base; end
      class Svc
        def handle(x) = 1
        def pick(x) = 1
        def exact(x) = 1
      end
      s = Svc.new
      s.handle(Sub.new).even?
      s.pick(Sub.new).even?
      s.exact(Sub.new).even?
    RUBY
    expect(rules(source, sig: subclass_sig)).not_to include("call.undefined-method")
  end

  it "does not skip an earlier arm the argument's class includes through project RBS" do
    # Runtime: `"p"`. The analyzer process cannot load `Printable`, so acceptance reads `Integer`'s host ancestors
    # and rules `(Printable)` out; taking the `(Integer)` arm after it typed the call `Integer` and reported `upcase`.
    sig = { "money.rbs" => <<~RBS }
      module Printable
      end
      class Integer
        include Printable
      end
      class Money
        def show: (Printable) -> String
                | (Integer) -> Integer
                | (Object) -> Symbol
      end
    RBS
    source = <<~RUBY
      module Printable; end
      class Integer; include Printable; end
      class Money
        def show(x) = "p"
      end
      Money.new.show(1).upcase
    RUBY
    expect(rules(source, sig: sig)).not_to include("call.undefined-method")
  end

  %w[rest ali].each do |method_name|
    it "does not skip an earlier arm spelled as #{method_name == 'rest' ? 'a rest parameter' : 'a type alias'}" do
      source = <<~RUBY
        module Printable; end
        class Integer; include Printable; end
        class Money
          def #{method_name}(*x) = "p"
        end
        Money.new.#{method_name}(1).upcase
      RUBY
      expect(rules(source, sig: spelled_sig)).not_to include("call.undefined-method")
    end
  end

  it "does not skip an earlier arm naming a core module that project RBS includes into a core class" do
    # Runtime: `"p"`. The host class registry answers `Integer` / `Enumerable` as disjoint; the RBS says otherwise.
    sig = { "money.rbs" => <<~RBS }
      class Integer
        include Enumerable[Integer]
        def each: () { (Integer) -> void } -> self
      end
      class Money
        def show: (Enumerable[untyped]) -> String
                | (Integer) -> Integer
                | (Object) -> Symbol
      end
    RBS
    source = <<~RUBY
      class Integer
        include Enumerable
        def each = yield(self)
      end
      class Money
        def show(x) = "p"
      end
      Money.new.show(1).upcase
    RUBY
    expect(rules(source, sig: sig)).not_to include("call.undefined-method")
  end

  it "does not skip an earlier arm naming a project class that the source, not the RBS, includes" do
    # Runtime: `"p"`. The RBS never includes `Printable` into `Integer`, so both orderings call them disjoint; only
    # the source does (#1351). A project-declared parameter class is never proven out.
    sig = { "money.rbs" => <<~RBS }
      module Printable
      end
      class Money
        def show: (Printable) -> String
                | (Integer) -> Integer
                | (Object) -> Symbol
      end
    RBS
    source = <<~RUBY
      module Printable; end
      class Integer; include Printable; end
      class Money
        def show(x) = "p"
      end
      Money.new.show(1).upcase
    RUBY
    expect(rules(source, sig: sig)).not_to include("call.undefined-method")
  end

  it "does not take a union arm, where upstream RBS can be wrong, for Rational#divmod(Float)" do
    # Runtime: `Rational(3, 2).divmod(0.5)` is `[3, 0.0]`, a Float remainder. rbs declares
    # `(Integer | Float | Rational) -> [Integer, Rational]` first, and taking it made `when Float` unreachable.
    source = <<~RUBY
      def calc(v)
        r = Rational(Integer(v), 3)
        _q, rem = r.divmod(0.5)
        case rem
        when Float then :float
        when Rational then :rational
        end
      end
    RUBY
    expect(rules(source)).not_to include("flow.unreachable-clause")
  end
end
