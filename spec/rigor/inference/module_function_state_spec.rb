# frozen_string_literal: true

require "spec_helper"
require "prism"

# The `module_function` probes P1–P13 from the #1507 declaration-fact review, each a single declaration.
# Ruby 4.0.5's answer is in each example's comment. The examples pin what each reader answers TODAY, which
# `Rigor::Inference::ModuleFunctionState` reproduces for all four of them: the singleton def-node table,
# the deferred ranges, the extends table and sig-gen. Where today's answer contradicts Ruby and a fix is
# planned, the example says what to flip.
module ModuleFunctionStateProbes
  SOURCES = {
    "P1" => <<~RUBY,
      module P1
        module_function
        public
        def x; end
      end
    RUBY
    "P2" => <<~RUBY,
      module P2
        module_function
        private
        def x; end
      end
    RUBY
    "P3" => <<~RUBY,
      module P3
        module_function
        def self.x; end
      end
    RUBY
    "P4" => <<~RUBY,
      module P4
        module_function
        class << self
          def y; end
        end
        def z; end
      end
    RUBY
    "P5" => <<~RUBY,
      module P5
        class << self
          module_function
        end
      end
    RUBY
    "P6" => <<~RUBY,
      module P6
        module_function :a
        def a; end
      end
    RUBY
    "P7" => <<~RUBY,
      class P7
        module_function
        def q; end
      end
    RUBY
    "P8" => <<~RUBY,
      module P8
        extend self
        def a; end
        private def b; end
      end
    RUBY
    "P9" => <<~RUBY,
      module P9
        def a; 1; end
        module_function :a
        def a; 2; end
      end
    RUBY
    "P10" => <<~RUBY,
      module P10
        module_function
        def a; 1; end
        public
        def b; end
        module_function
        def c; end
      end
    RUBY
    "P11" => <<~RUBY,
      module P11
        def self.k; {}; end
        module_function
        def k; "x"; end
      end
    RUBY
    "P12" => <<~RUBY,
      module P12
        module_function
        protected
        def x; end
      end
    RUBY
    "P13" => <<~RUBY
      module P13
        module_function
        def x; end
        alias y x
        attr_reader :r
        define_method(:dm) {}
      end
    RUBY
  }.freeze
end

RSpec.describe Rigor::Inference::ModuleFunctionState do
  def root_of(probe)
    Prism.parse(ModuleFunctionStateProbes::SOURCES.fetch(probe)).value
  end

  def body_of(probe)
    root_of(probe).statements.body.first.body
  end

  def label(node)
    "#{node.name}@#{node.location.start_line}"
  end

  def line_of(probe, offset)
    ModuleFunctionStateProbes::SOURCES.fetch(probe)[0, offset].count("\n") + 1
  end

  # `"name@line" => toggle on` for each direct def, and `"copy name" => "name@line"` for each def a named
  # call copies.
  def singleton_reading(probe)
    statements = Rigor::Inference::ScopeIndexer.statements_of(body_of(probe))
    answer = {}
    described_class.each_singleton_sibling(statements) do |stmt, module_function_on|
      if module_function_on == :named
        described_class.each_singleton_copy(stmt, statements) do |name, def_node|
          answer["copy #{name}"] = label(def_node)
        end
      elsif stmt.is_a?(Prism::DefNode)
        answer[label(stmt)] = module_function_on
      end
    end
    answer
  end

  # The prescan's named-call rows as `[name, line, kind, owner]` under `rows:`, and for each direct def
  # whether a bare call makes it a module function.
  def deferred_reading(probe)
    body = body_of(probe)
    offsets = []
    rows = []
    described_class.prescan_deferred(body, [probe], false, offsets, rows)
    answer = { rows: rows.map { |start, _end, name, kind, owner| [name, line_of(probe, start), kind, owner] } }
    Rigor::Inference::ScopeIndexer.statements_of(body).grep(Prism::DefNode).each do |def_node|
      answer[label(def_node)] = described_class.deferred_module_function?(offsets, def_node.location.start_offset)
    end
    answer
  end

  # `"module_function@line" => extends_self?` for every `module_function` call in the body.
  def extends_reading(probe)
    calls = []
    pending = [body_of(probe)]
    until pending.empty?
      node = pending.pop
      calls << node if node.is_a?(Prism::CallNode) && node.name == :module_function
      pending.concat(node.compact_child_nodes)
    end
    calls.to_h { |call| ["module_function@#{call.location.start_line}", described_class.extends_self?(call)] }
  end

  # `"name@line" => renders as self?` for each def in the body's statement list.
  def sig_gen_reading(probe)
    answer = {}
    described_class.each_sig_gen_statement(body_of(probe).body, false) do |stmt, active|
      next unless stmt.is_a?(Prism::DefNode)

      kind = stmt.receiver.is_a?(Prism::SelfNode) ? :singleton : :instance
      answer[label(stmt)] = described_class.sig_gen_module_function?(active, kind)
    end
    answer
  end

  def readings(probe)
    { singleton: singleton_reading(probe), deferred: deferred_reading(probe), extends: extends_reading(probe),
      sig_gen: sig_gen_reading(probe) }
  end

  # The three ScopeIndexer tables the readings feed, for the same probe.
  def tables(probe)
    root = root_of(probe)
    indexer = Rigor::Inference::ScopeIndexer
    {
      singleton_def_nodes: indexer.build_discovered_singleton_def_nodes(root)
                                  .transform_values { |table| table.transform_values { |node| label(node) } },
      deferred_ranges: indexer.build_deferred_ranges(root).filter_map do |start, _end, name, kind, owner|
        [name, line_of(probe, start), kind, owner] if name
      end,
      extends: indexer.build_discovered_extends(root)
    }
  end

  describe "a bare call followed by a bare visibility call" do
    # Ruby: `public` ends the module_function mode, so `x` is a public instance method and `P1.x` raises.
    # Every reader keeps the toggle on. Flip this when the reset semantics are fixed (#1550, "Related findings").
    it "P1 (`public`): every reader makes `x` a module function" do
      expect(readings("P1")).to eq(
        singleton: { "x@4" => true }, deferred: { :rows => [], "x@4" => true },
        extends: { "module_function@2" => true }, sig_gen: { "x@4" => true }
      )
      expect(tables("P1")).to eq(
        singleton_def_nodes: { "P1" => { x: "x@4" } }, deferred_ranges: [[:x, 4, :both, "P1"]],
        extends: { "P1" => ["P1"] }
      )
    end

    # Ruby: `x` is a private instance method with no singleton copy. Flip this when the reset semantics are
    # fixed (#1550, "Related findings").
    it "P2 (`private`): every reader makes `x` a module function" do
      expect(readings("P2")).to eq(
        singleton: { "x@4" => true }, deferred: { :rows => [], "x@4" => true },
        extends: { "module_function@2" => true }, sig_gen: { "x@4" => true }
      )
      expect(tables("P2")).to eq(
        singleton_def_nodes: { "P2" => { x: "x@4" } }, deferred_ranges: [[:x, 4, :both, "P2"]],
        extends: { "P2" => ["P2"] }
      )
    end

    # Ruby: `x` is a protected instance method with no singleton copy. Flip this when the reset semantics are
    # fixed (#1550, "Related findings").
    it "P12 (`protected`): every reader makes `x` a module function" do
      expect(readings("P12")).to eq(
        singleton: { "x@4" => true }, deferred: { :rows => [], "x@4" => true },
        extends: { "module_function@2" => true }, sig_gen: { "x@4" => true }
      )
      expect(tables("P12")).to eq(
        singleton_def_nodes: { "P12" => { x: "x@4" } }, deferred_ranges: [[:x, 4, :both, "P12"]],
        extends: { "P12" => ["P12"] }
      )
    end

    # Ruby: `a` and `c` are module functions, and `b`, after `public`, is a public instance method only.
    # `b@5 => true` in every reader is the reset bug. Flip this when the reset semantics are fixed (#1550,
    # "Related findings").
    it "P10 (a second bare call after `public`): every reader keeps `b` a module function" do
      expect(readings("P10")).to eq(
        singleton: { "a@3" => true, "b@5" => true, "c@7" => true },
        deferred: { :rows => [], "a@3" => true, "b@5" => true, "c@7" => true },
        extends: { "module_function@2" => true, "module_function@6" => true },
        sig_gen: { "a@3" => true, "b@5" => true, "c@7" => true }
      )
      expect(tables("P10")).to eq(
        singleton_def_nodes: { "P10" => { a: "a@3", b: "b@5", c: "c@7" } },
        deferred_ranges: [[:a, 3, :both, "P10"], [:b, 5, :both, "P10"], [:c, 7, :both, "P10"]],
        extends: { "P10" => ["P10"] }
      )
    end
  end

  describe "the named form" do
    # Ruby: `module_function :a` copies the def in effect at the call, so `P9.a` returns 1, and the later
    # `def a` redefines only the public instance method. The singleton reading copies the later def (`a@4`).
    # Flip this when #1550 is fixed: the copy is `a@2`.
    it "P9 (a redefinition after the call): the singleton reading copies the later def" do
      expect(readings("P9")).to eq(
        singleton: { "a@2" => false, "copy a" => "a@4", "a@4" => false },
        deferred: { :rows => [[:a, 3, :singleton, "P9"]], "a@2" => false, "a@4" => false },
        extends: { "module_function@3" => false }, sig_gen: { "a@2" => false, "a@4" => false }
      )
      expect(tables("P9")).to eq(
        singleton_def_nodes: { "P9" => { a: "a@4" } },
        deferred_ranges: [[:a, 3, :singleton, "P9"], [:a, 2, :instance, "P9"], [:a, 4, :instance, "P9"]],
        extends: {}
      )
    end

    # Ruby: the call raises `NameError`, because `a` is not defined yet. The singleton reading resolves the
    # later def. Flip this when #1550 is fixed: a name with no preceding def declines.
    it "P6 (the call before any def): the singleton reading copies the later def" do
      expect(readings("P6")).to eq(
        singleton: { "copy a" => "a@3", "a@3" => false },
        deferred: { :rows => [[:a, 2, :singleton, "P6"]], "a@3" => false },
        extends: { "module_function@2" => false }, sig_gen: { "a@3" => false }
      )
      expect(tables("P6")).to eq(
        singleton_def_nodes: { "P6" => { a: "a@3" } },
        deferred_ranges: [[:a, 2, :singleton, "P6"], [:a, 3, :instance, "P6"]],
        extends: {}
      )
    end
  end

  describe "defs the toggle does not change" do
    # Ruby: `def self.x` defines only `P3.x`, with no instance copy. Each reader already records `x` as
    # singleton-side; the toggle answer on it changes nothing.
    it "P3 (`def self.x`)" do
      expect(readings("P3")).to eq(
        singleton: { "x@3" => true }, deferred: { :rows => [], "x@3" => true },
        extends: { "module_function@2" => true }, sig_gen: { "x@3" => false }
      )
      expect(tables("P3")).to eq(
        singleton_def_nodes: { "P3" => { x: "x@3" } }, deferred_ranges: [[:x, 3, :singleton, "P3"]],
        extends: { "P3" => ["P3"] }
      )
    end

    # Ruby: `y` is a singleton method only, and `z` a module function. The `class << self` body is its own
    # body to every reader.
    it "P4 (a `class << self` body between the call and a def)" do
      expect(readings("P4")).to eq(
        singleton: { "z@6" => true }, deferred: { :rows => [], "z@6" => true },
        extends: { "module_function@2" => true }, sig_gen: { "z@6" => true }
      )
      expect(tables("P4")).to eq(
        singleton_def_nodes: { "P4" => { y: "y@4", z: "z@6" } },
        deferred_ranges: [[:y, 4, :singleton, "P4"], [:z, 6, :both, "P4"]],
        extends: { "P4" => ["P4"] }
      )
    end

    # Ruby: `module_function` copies the later `def k` onto the singleton, over `def self.k`, so `P11.k`
    # returns "x". The singleton table's last write is that copy.
    it "P11 (`def self.k`, then a module function `k`)" do
      expect(readings("P11")).to eq(
        singleton: { "k@2" => false, "k@4" => true }, deferred: { :rows => [], "k@2" => false, "k@4" => true },
        extends: { "module_function@3" => true }, sig_gen: { "k@2" => false, "k@4" => true }
      )
      expect(tables("P11")).to eq(
        singleton_def_nodes: { "P11" => { k: "k@4" } },
        deferred_ranges: [[:k, 2, :singleton, "P11"], [:k, 4, :both, "P11"]],
        extends: { "P11" => ["P11"] }
      )
    end

    # Ruby: `x` is a module function. `alias`, `attr_reader` and `define_method` are not defs, so no reader
    # classifies them; Ruby leaves `y` and `r` instance-only and gives `dm` a singleton copy.
    it "P13 (non-def definers after the call)" do
      expect(readings("P13")).to eq(
        singleton: { "x@3" => true }, deferred: { :rows => [], "x@3" => true },
        extends: { "module_function@2" => true }, sig_gen: { "x@3" => true }
      )
      expect(tables("P13")).to eq(
        singleton_def_nodes: { "P13" => { x: "x@3" } }, deferred_ranges: [[:x, 3, :both, "P13"]],
        extends: { "P13" => ["P13"] }
      )
    end

    # `extend self` is not `module_function`: the extends table records it through its own arm.
    it "P8 (`extend self`, no module_function call)" do
      expect(readings("P8")).to eq(
        singleton: { "a@3" => false }, deferred: { :rows => [], "a@3" => false }, extends: {},
        sig_gen: { "a@3" => false }
      )
      expect(tables("P8")).to eq(
        singleton_def_nodes: {}, deferred_ranges: [[:a, 3, :instance, "P8"], [:b, 4, :instance, "P8"]],
        extends: { "P8" => ["P8"] }
      )
    end
  end

  describe "calls Ruby rejects" do
    # Ruby raises `NameError`: a singleton class does not respond to `module_function`. `extends_self?`
    # answers for the call, but the extends walk never records a call inside `class << self`.
    it "P5 (`module_function` inside `class << self`)" do
      expect(readings("P5")).to eq(
        singleton: {}, deferred: { rows: [] }, extends: { "module_function@3" => true }, sig_gen: {}
      )
      expect(tables("P5")).to eq(singleton_def_nodes: {}, deferred_ranges: [], extends: {})
    end

    # Ruby raises `NameError`: a class does not respond to `module_function`. Every reader treats the class
    # body as a module's.
    it "P7 (`module_function` in a class body)" do
      expect(readings("P7")).to eq(
        singleton: { "q@3" => true }, deferred: { :rows => [], "q@3" => true },
        extends: { "module_function@2" => true }, sig_gen: { "q@3" => true }
      )
      expect(tables("P7")).to eq(
        singleton_def_nodes: { "P7" => { q: "q@3" } }, deferred_ranges: [[:q, 3, :both, "P7"]],
        extends: { "P7" => ["P7"] }
      )
    end
  end

  describe "where the readers disagree on nesting" do
    let(:source) do
      <<~RUBY
        module Nested
          if true
            module_function
          end
          def a; end
          [1].each do
            module_function
            def b; end
          end
          def c; end
        end
      RUBY
    end

    let(:body) { Prism.parse(source).value.statements.body.first.body }

    it "the sibling toggle misses a bare call inside control flow or a block, and the deferred prescan sees it" do
      statements = Rigor::Inference::ScopeIndexer.statements_of(body)
      sibling = []
      described_class.each_singleton_sibling(statements) { |stmt, on| sibling << [stmt.type, on] }
      offsets = []
      described_class.prescan_deferred(body, ["Nested"], false, offsets, [])
      defs = statements.grep(Prism::DefNode)

      expect(sibling).to eq([[:if_node, false], [:def_node, false], [:call_node, false], [:def_node, false]])
      expect(defs.map { |d| described_class.deferred_module_function?(offsets, d.location.start_offset) })
        .to eq([true, true])
    end

    it "sig-gen: a bare call in a nested statement list covers only that list" do
      outer = []
      described_class.each_sig_gen_statement(body.body, false) { |stmt, active| outer << [stmt.type, active] }
      inner = body.body.grep(Prism::CallNode).first.block.body.body
      inner_answers = []
      described_class.each_sig_gen_statement(inner, false) { |stmt, active| inner_answers << [stmt.type, active] }

      expect(outer).to eq([[:if_node, false], [:def_node, false], [:call_node, false], [:def_node, false]])
      expect(inner_answers).to eq([[:def_node, true]])
    end

    it "records the answers in the tables" do
      root = Prism.parse(source).value
      indexer = Rigor::Inference::ScopeIndexer
      rows = indexer.build_deferred_ranges(root).filter_map { |row| row.values_at(2, 3, 4) if row[2] }

      expect(indexer.build_discovered_singleton_def_nodes(root)).to eq({})
      expect(rows).to eq([[:a, :both, "Nested"], [:c, :both, "Nested"]])
      expect(indexer.build_discovered_extends(root)).to eq("Nested" => ["Nested"])
    end
  end
end
