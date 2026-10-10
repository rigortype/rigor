# frozen_string_literal: true

require "spec_helper"

# Issue #1800 — an overload that declares and takes the call's keywords answers before one that would read the keyword
# hash as a positional argument. `ReceiverAffinity` moved `(Object)` ahead of `(a: Integer)`, the strict pass took it,
# and `ob(a: 1)` was typed `String`. RBS takes the first overload in declared order that takes the call, and a method
# accepting keywords binds `a: 1` to them (`def m(x = nil, a: nil)`; `m(a: 1)` is `[nil, 1]`), so both read the
# keyword overload. A positional reader declared first is what RBS takes while the runtime may bind keywords, so the
# two returns join.
RSpec.describe "Keyword overloads over positional readers of the keyword hash (#1800)", type: :runner do
  let(:sig) do
    { "r.rbs" => <<~RBS }
      class R
        def ob: (a: Integer) -> Integer
              | (Object) -> String
        def bo: (a: Integer) -> Integer
              | (BasicObject) -> String
        def blk: (a: Integer) { (Integer) -> void } -> void
               | (Object) { (String) -> void } -> void
        def first_positional: (Object) -> String
                            | (a: Integer) -> Integer
        def untyped_value: () -> untyped
        def opts: () -> Hash[Symbol, Integer]
      end
    RBS
  end

  def dumped_types(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\nr = R.new\n#{source}), sig: sig)
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  it "reports nothing on a call the keyword overload takes" do
    result = analyze(<<~RUBY, sig: sig)
      r = R.new
      r.ob(a: 1).even?
      r.bo(a: 1).even?
      r.blk(a: 1) { |n| n.even? }
    RUBY
    expect(result.diagnostics.select(&:error?).map(&:message)).to eq([])
  end

  it "types a keyword call by the keyword overload and a positional call by the positional one" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Integer String Integer String])
      dump_type(r.ob(a: 1))
      dump_type(r.ob(Object.new))
      dump_type(r.bo(a: 1))
      dump_type(r.bo({ a: 1 }))
    RUBY
  end

  it "binds block parameters by the keyword overload" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Integer String])
      r.blk(a: 1) { |n| dump_type(n) }
      r.blk(Object.new) { |s| dump_type(s) }
    RUBY
  end

  # A value the keyword declares no room for leaves the positional reading, as Ruby passes the hash to `(Object)`.
  it "keeps the positional overload for keywords the keyword overload does not take" do
    expect(dumped_types(<<~RUBY)).to eq(%w[String String])
      dump_type(r.ob(a: "s"))
      dump_type(r.ob(b: 1))
    RUBY
  end

  # RBS takes the `(Object)` overload declared first; a method accepting keywords binds `a: 1` to them.
  it "joins a positional overload declared before the keyword overload" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[Integer | String]"])
      dump_type(r.first_positional(a: 1))
    RUBY
  end

  # An untyped value or an unshaped `**opts` takes the keyword overload only gradually, which proves nothing.
  it "joins the overloads where the keyword overload takes the hash only gradually" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[Integer | String]", "Dynamic[Integer | String]"])
      dump_type(r.ob(a: r.untyped_value))
      dump_type(r.ob(**r.opts))
    RUBY
  end
end
