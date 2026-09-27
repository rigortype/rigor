# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/declaration_walk"

# PROTOTYPE for the ADR-116 WD5 amendment draft (#1197): the statement-sequence events. A collector that
# overrides `on_sequence`, `on_statement` or `on_sequence_end` is handed every statement list, each direct
# statement in order, and each list's end, so it can keep state that flows from one sibling to the next.
# Every other collector of the run sees exactly the events it saw before.
RSpec.describe Rigor::Inference::DeclarationWalk do
  let(:walk) { described_class }

  # Records the sequence events, and the calls and defs between them, by label.
  let(:sequence_recorder) do
    Class.new do
      include Rigor::Inference::DeclarationWalk::Collector

      attr_reader :events

      def initialize(decline_sequence: nil, decline_statement: nil)
        @events = []
        @decline_sequence = decline_sequence
        @decline_statement = decline_statement
      end

      def on_sequence(node, _context, body)
        @events << [:sequence, label(node.body.first), body && body.class.name.delete_prefix("Prism::")]
        label(node.body.first) == @decline_sequence ? Rigor::Inference::DeclarationWalk::DECLINE : descend
      end

      def on_statement(node, _context)
        @events << [:statement, label(node)]
        label(node) == @decline_statement ? Rigor::Inference::DeclarationWalk::DECLINE : descend
      end

      def on_sequence_end(node, _context)
        @events << [:end, label(node.body.first)]
        descend
      end

      def on_call(node, _context)
        @events << [:call, node.name.to_s]
        descend
      end

      def on_def(node, _context)
        @events << [:def, node.name.to_s]
        descend
      end

      private

      def descend = Rigor::Inference::DeclarationWalk::DESCEND

      def label(node)
        case node
        when Prism::CallNode, Prism::DefNode then node.name.to_s
        when Prism::ClassNode, Prism::ModuleNode then node.constant_path.slice
        else node.class.name.delete_prefix("Prism::")
        end
      end
    end
  end

  def run(source, collectors)
    walk.run(Prism.parse(source).value, collectors, walk::Context.root(nesting: []))
  end

  describe "the events" do
    it "hands each list, each direct statement in order, and each list's end" do
      recorder = sequence_recorder.new
      run("class C\n  a\n  if x\n    b\n  end\n  def m\n    c\n  end\nend\n", [recorder])
      expect(recorder.events).to eq(
        [[:sequence, "C", nil], [:statement, "C"],
         [:sequence, "a", "StatementsNode"],
         [:statement, "a"], [:call, "a"],
         [:statement, "IfNode"], [:call, "x"], [:sequence, "b", nil], [:statement, "b"], [:call, "b"], [:end, "b"],
         [:statement, "m"], [:def, "m"], [:sequence, "c", nil], [:statement, "c"], [:call, "c"], [:end, "c"],
         [:end, "a"],
         [:end, "C"]]
      )
    end

    it "names the body each body-level list belongs to, the clauses of a body-level begin included" do
      source = <<~RUBY
        class C
          a
        rescue
          r
        else
          e
        ensure
          f
        end
        class << self
          s
        end
        K = Class.new { k }
        X.class_eval { v }
        Class.new(B) { n }
        each { o }
      RUBY
      recorder = sequence_recorder.new
      run(source, [recorder])
      bodies = recorder.events.select { |event| event.first == :sequence }.to_h { |_, first, body| [first, body] }
      expect(bodies).to eq("C" => nil, "a" => "BeginNode", "r" => "BeginNode", "e" => "BeginNode",
                           "f" => "BeginNode", "s" => "StatementsNode", "k" => "StatementsNode",
                           "v" => "StatementsNode", "n" => "StatementsNode", "o" => nil)
    end

    it "gives a bare factory block no body for a collector walking it as an ordinary call" do
      ordinary = Class.new(sequence_recorder) { const_set(:VARIANTS, { factory_block: :ordinary_call }.freeze) }
      recorder = ordinary.new
      run("Class.new(B) { n }\n", [recorder])
      expect(recorder.events.select { |event| event.first == :sequence }).to eq([[:sequence, "new", nil],
                                                                                 [:sequence, "n", nil]])
    end

    it "skips a declined list and its end, and a declined statement, for that collector alone" do
      source = "class C\n  a\n  if x\n    b\n  end\n  c\nend\n"
      declining = sequence_recorder.new(decline_sequence: "b", decline_statement: "c")
      plain = sequence_recorder.new
      run(source, [declining, plain])
      expect(declining.events).not_to include([:call, "b"], [:end, "b"], [:call, "c"])
      expect(declining.events).to include([:statement, "c"])
      expect(plain.events).to include([:call, "b"], [:end, "b"], [:call, "c"])
    end
  end

  describe "the rest of the run" do
    # Each ported table with a sequence collector in the shared run, against the same table without one.
    it "builds every shared table byte-identically with a sequence collector in the run" do
      si = Rigor::Inference::ScopeIndexer
      source = File.read(File.expand_path("../../../lib/rigor/inference/scope_indexer.rb", __dir__))
      root = Prism.parse(source).value
      alone = si.declaration_walk_tables(root, "lib/x.rb")
      collectors = [si::SuperclassesCollector.new, si::MemberLayoutsCollector.new, si::DefNestingsCollector.new,
                    sequence_recorder.new]
      walk.run(root, collectors, walk::Context.root(nesting: [], source_path: "lib/x.rb"))
      supers, layouts, nestings = collectors
      shared = { superclasses: supers.tables.first, header_nestings: supers.tables.last,
                 def_nestings: nestings.table, data_member_layouts: layouts.tables.first,
                 struct_member_layouts: layouts.tables.last }
      expect(walk::Shadow.first_difference(alone, shared, "")).to be_nil
    end

    it "allocates nothing per statement for a sequence collector" do
      counting = Class.new do
        include Rigor::Inference::DeclarationWalk::Collector

        def on_sequence(_node, _context, _body) = Rigor::Inference::DeclarationWalk::DESCEND
        def on_statement(_node, _context) = Rigor::Inference::DeclarationWalk::DESCEND
        def on_sequence_end(_node, _context) = Rigor::Inference::DeclarationWalk::DESCEND
      end
      roots = [20, 200].map do |defs|
        Prism.parse("class C\n#{Array.new(defs) { |i| "  def m#{i}\n    helper(#{i})\n  end\n" }.join}end\n").value
      end
      small, large = roots.map do |root|
        walk.run(root, [counting.new, counting.new, counting.new])
        Array.new(3) do
          collectors = [counting.new, counting.new, counting.new]
          before = GC.stat(:total_allocated_objects)
          walk.run(root, collectors)
          GC.stat(:total_allocated_objects) - before
        end.min
      end
      expect(large - small).to be <= 4, "#{large - small} more objects for 180 more defs"
    end
  end

  # What the events are for: sibling-order state. `private` changes the default for the statements after it
  # in its own list, a nested list starts from the enclosing one's current default and hands nothing back, and
  # a class body starts afresh. The collector keeps the stack; the walk only hands it the cursor.
  describe "a sibling-order collector (a sketch, not a port)" do
    let(:visibility_sketch) do
      Class.new do
        include Rigor::Inference::DeclarationWalk::Collector

        attr_reader :table

        def initialize
          @table = {}
          @stack = []
          @statement = nil
        end

        def on_sequence(_node, _context, body)
          @stack.push(body ? :public : (@stack.last || :public))
          Rigor::Inference::DeclarationWalk::DESCEND
        end

        def on_statement(node, _context)
          @statement = node
          Rigor::Inference::DeclarationWalk::DESCEND
        end

        def on_sequence_end(_node, _context)
          @stack.pop
        end

        # Only a bare modifier written as a statement of its own changes the default.
        def on_call(node, _context)
          return Rigor::Inference::DeclarationWalk::DESCEND unless node.equal?(@statement) && modifier?(node)

          @stack[-1] = node.name
          Rigor::Inference::DeclarationWalk::DECLINE
        end

        def on_def(node, context)
          unless context.prefix.empty? || context.singleton_cref || node.receiver
            (@table[context.prefix.join("::")] ||= {})[node.name] = @stack.last
          end
          Rigor::Inference::DeclarationWalk::DECLINE
        end

        private

        def modifier?(node)
          node.receiver.nil? && node.arguments.nil? && %i[private public protected].include?(node.name)
        end
      end
    end

    [
      "class C\n  private\n  def a; end\n  if x\n    public\n    def b; end\n  end\n  def c; end\n  " \
      "class D\n    def d; end\n  end\n  def e; end\nend\n",
      "class C\n  private\n  def a; end\nrescue\n  def r; end\nelse\n  public\n  def s; end\n" \
      "ensure\n  def t; end\nend\n",
      "class C\n  foo(private)\n  def a; end\n  (protected)\n  def b; end\nend\n"
    ].each_with_index do |source, index|
      it "agrees with the legacy visibility walker on sibling order (case #{index})" do
        sketch = visibility_sketch.new
        root = Prism.parse(source).value
        walk.run(root, [sketch])
        expect(sketch.table).to eq(Rigor::Inference::ScopeIndexer.build_discovered_method_visibilities(root))
      end
    end
  end
end
