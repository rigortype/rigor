# frozen_string_literal: true

require "spec_helper"

# Issue #1727 — overload selection reads a call's keyword arguments.
#
# The selector matched overloads on positional argument types only: it skipped every overload that requires a keyword,
# and the call's keyword hash reached it as one trailing positional `HashShape`. A call passing a positional argument
# and a keyword therefore matched no overload and took the first declared one, so the result depended on declaration
# order: `GC.stat(:count, scope: :global) + 1` reported `+` undefined on `Hash`. Now, when the call's last argument is
# a keyword hash, an overload that declares keywords takes it as its keywords.
RSpec.describe "Keyword arguments in overload selection (#1727)", type: :runner do
  let(:sig) do
    { "picker.rbs" => <<~RBS }
      class Picker
        def pick: (Symbol key, scope: Symbol) -> Integer
                | (?Hash[Symbol, untyped]? hash, scope: Symbol) -> Hash[Symbol, untyped]
                | (?Hash[Symbol, untyped]? hash) -> String
        def opt: (Integer x) -> String
               | (?verbose: bool) -> Integer
        def flag: (exception: false) -> Integer?
                | (?exception: true) -> Integer
        def rest: (**Integer) -> Integer
                | (String) -> String
        def positional_hash: (Hash[Symbol, Integer] options) -> Integer
                           | () -> String
        def either: [T] (?default: T) { () -> T } -> T
      end
    RBS
  end

  def dumped_types(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\np = Picker.new\n#{source}), sig: sig)
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  it "selects an overload whose required keyword the call passes, by its positional arguments" do
    expect(dumped_types(<<~RUBY)).to eq(["Integer", "Hash[Symbol, Dynamic[top]]", "Hash[Symbol, Dynamic[top]]"])
      dump_type(p.pick(:count, scope: :global))
      dump_type(p.pick({}, scope: :global))
      dump_type(p.pick(scope: :global))
    RUBY
  end

  it "skips an overload whose required keyword the call does not pass" do
    expect(dumped_types(<<~RUBY)).to eq(%w[String String])
      dump_type(p.pick({}))
      dump_type(p.pick)
    RUBY
  end

  # A braced hash is a positional argument in Ruby 3, never keywords.
  it "reads a braced hash as a positional argument" do
    expect(dumped_types(<<~RUBY)).to eq(%w[String])
      dump_type(p.pick({ scope: :global }))
    RUBY
  end

  it "selects an overload by its optional keywords" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Integer String Integer])
      dump_type(p.opt(verbose: true))
      dump_type(p.opt(1))
      dump_type(p.opt)
    RUBY
  end

  it "rejects an overload whose keyword does not accept the passed value" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Integer? Integer Integer])
      dump_type(p.flag(exception: false))
      dump_type(p.flag(exception: true))
      dump_type(p.flag)
    RUBY
  end

  it "rejects an overload that does not declare a passed keyword, unless **rest takes it" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Integer String])
      dump_type(p.rest(a: 1, b: 2))
      dump_type(p.rest("x"))
    RUBY
  end

  # An overload that declares no keywords reads the keyword hash as a trailing positional `Hash`, as Ruby passes it.
  it "passes keywords to an overload that declares none as a positional Hash" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Integer])
      dump_type(p.positional_hash(a: 1))
    RUBY
  end

  # The keyword hash is an argument that reaches the block's variable through a keyword parameter, so the variable
  # does not bind to the block's type alone: `either(default: 1) { "s" }` may return `1`.
  it "lets a keyword argument reach a block-return variable" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]", %("s")])
      dump_type(p.either(default: 1) { "s" })
      dump_type(p.either { "s" })
    RUBY
  end

  it "reports nothing on the correct uses the first-overload fallback used to mistype" do
    result = analyze(<<~RUBY, sig: sig)
      p = Picker.new
      p.pick(:count, scope: :global) + 1
      p.pick({}, scope: :global).each_key { |key| key }
    RUBY
    expect(result.diagnostics.select(&:error?).map(&:message)).to eq([])
  end
end
