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
        def mode: (Integer x, mode: Symbol) -> :a
                | (Integer x, mode: Integer) -> :b
        def loose: (Integer x, mode: untyped) -> :loose
                 | (Integer x, mode: Symbol) -> :sym
        def yielding: (Integer x, as: Symbol) { (Symbol) -> void } -> void
                    | (Integer x) { (Integer) -> void } -> void
        def untyped_value: () -> untyped
        def flag_value: () -> bool
        def joined_flag: (Integer x) -> true
                       | (String x) -> false
        def maybe_flag: (Integer x) -> true
                      | (String x) -> nil
        def maybe_false: (Integer x) -> false
                       | (String x) -> nil
        def joined_number: (Integer x) -> Integer
                         | (String x) -> nil
        def visit: (String x, ?mode: Symbol) { (String) -> void } -> void
                 | (Integer x, ?mode: Symbol) { (Integer) -> void } -> void
        def optional_flag: (?flag: bool) { (String) -> void } -> void
        def each_row: (headers: true) { (Symbol) -> void } -> void
                    | (?headers: false) { (Array[String]) -> void } -> void
        def ret: (headers: true) -> Symbol
               | (?headers: false) -> Integer
        def single: (?a: Integer | String | Symbol, ?b: Integer | String | Symbol) -> Float
        def wide_value: () -> (Integer | String | Symbol)
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

  # #1737 — an untyped keyword value reaches every overload's keyword, as an untyped positional reaches every
  # positional parameter, so the #521 union answers rather than the first arm by position. A value-pinned keyword
  # (`exception: false`) joins that union instead of declining the untyped value outright.
  it "joins the overloads an untyped keyword value reaches" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[:a | :b]", ":a", "Dynamic[Integer?]"])
      dump_type(p.mode(1, mode: p.untyped_value))
      dump_type(p.mode(1, mode: :q))
      dump_type(p.flag(exception: p.untyped_value))
    RUBY
  end

  it "does not let an untyped keyword win the strict pass over a typed one" do
    expect(dumped_types(<<~RUBY)).to eq([":sym"])
      dump_type(p.loose(1, mode: :q))
    RUBY
  end

  # The block-parameter probe reads the call's keywords as the return path does.
  it "selects the block-bearing overload by its keywords when typing block parameters" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Symbol Integer])
      p.yielding(1, as: :x) { |value| dump_type(value) }
      p.yielding(1) { |value| dump_type(value) }
    RUBY
  end

  # A block parameter has one type per binding, so where the overloads a keyword call may reach disagree on it, the
  # probe answers no information rather than the first overload's: an untyped keyword value reaches every arm (#521),
  # and each member of a `bool` value selects its own.
  it "binds a block parameter only where every overload the keywords may reach agrees" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Symbol Array[String] Dynamic[top] Dynamic[top]])
      p.each_row(headers: true) { |row| dump_type(row) }
      p.each_row { |row| dump_type(row) }
      p.each_row(headers: p.untyped_value) { |row| dump_type(row) }
      p.each_row(headers: p.flag_value) { |row| dump_type(row) }
    RUBY
  end

  # A `Dynamic[bool]` (what the #521 join answers) splits like a `bool`; a member no overload takes (`nil` here)
  # answers no information rather than lending the first-overload fallback to the agreement.
  it "reports nothing in a block whose keyword value may select either overload" do
    result = analyze(<<~RUBY, sig: sig)
      p = Picker.new
      p.each_row(headers: p.untyped_value) { |row| row.join(",") }
      p.each_row(headers: p.flag_value) { |row| row.join(",") }
      p.each_row(headers: p.joined_flag(p.untyped_value)) { |row| row.join(",") }
      p.each_row(headers: [true, nil].sample) { |row| row.join(",") }
      p.each_row(headers: p.maybe_false(p.untyped_value)) { |row| row.join(",") }
    RUBY
    expect(result.diagnostics.select(&:error?).map(&:message)).to eq([])
  end

  # A faceted positional argument (`Dynamic[Integer]`, the #521 join of `Integer` and `nil`) is read member-wise as
  # the return path reads it, and a `Dynamic` keyword value's `nil` (which the join carries) is not a member.
  it "reads a faceted positional argument member-wise and a Dynamic keyword value without its nil" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Integer String])
      p.visit(p.joined_number(p.untyped_value), mode: :a) { |value| dump_type(value) }
      p.optional_flag(flag: p.maybe_flag(p.untyped_value)) { |value| dump_type(value) }
    RUBY
  end

  # #1746 — the return path reads a union keyword value per member as the block probe does: each member of a `bool`
  # selects its own overload and the returns join. A member no overload takes (`nil` here) answers no information
  # rather than the first overload's return, and a `Dynamic[bool]` (the #521 join) keeps the answer `Dynamic`.
  it "joins the returns of the overloads each member of a union keyword value selects" do
    expected = ["Integer | Symbol", "Symbol", "Integer", "Dynamic[top]", "Dynamic[Integer | Symbol]"]
    expect(dumped_types(<<~RUBY)).to eq(expected)
      dump_type(p.ret(headers: p.flag_value))
      dump_type(p.ret(headers: true))
      dump_type(p.ret)
      dump_type(p.ret(headers: [true, nil].sample))
      dump_type(p.ret(headers: p.joined_flag(p.untyped_value)))
    RUBY
  end

  # A method with one overload has nothing to select between, so its keywords are not spelled out member by member,
  # where a wide union (nine lists here) would pass the distribution limit and lose the declared return.
  it "keeps the return of a single overload whatever its union keyword values" do
    expect(dumped_types(<<~RUBY)).to eq(%w[Float])
      dump_type(p.single(a: p.wide_value, b: p.wide_value))
    RUBY
  end

  it "reports nothing on a call the member the first overload skipped makes correct" do
    result = analyze(<<~RUBY, sig: sig)
      p = Picker.new
      r = p.ret(headers: p.flag_value)
      r + 1
      r.no_such_method
    RUBY
    expect(result.diagnostics.select(&:error?).map(&:message)).to contain_exactly(a_string_including("no_such_method"))
  end

  # A keyword hash no overload takes as keywords is a positional `Hash`, so its untyped values are not the call's
  # imprecision.
  it "keeps a positional reading precise when no overload declares keywords" do
    expect(dumped_types(<<~RUBY)).to eq(["Hash[Dynamic[top], Dynamic[top]]"])
      dump_type(Hash[a: p.untyped_value])
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
