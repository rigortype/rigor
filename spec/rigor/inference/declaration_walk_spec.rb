# frozen_string_literal: true

require "spec_helper"
require "open3"
require "prism"
require "rigor/inference/declaration_walk"

# ADR-116 WD5 — the shared declaration-context walk. These examples pin the context each arm hands its
# children and the collector protocol (events, per-collector decline); the equivalence of a ported table
# with the walker it replaced is `scope_indexer_class_cvars_equivalence_spec`'s.
RSpec.describe Rigor::Inference::DeclarationWalk do
  # Records every event with the context it arrived under. `decline` names `[event, label]` pairs the
  # collector answers DECLINE to.
  let(:recorder_class) do
    Class.new do
      include Rigor::Inference::DeclarationWalk::Collector

      attr_reader :events

      def initialize(decline: [])
        @events = []
        @decline = decline
      end

      def on_declaration(node, context, body)
        record(:declaration, node.constant_path.slice, context, body: body)
      end

      def on_def(node, context)
        record(:def_node, node.name.to_s, context)
      end

      def on_call(node, context)
        record(:call, node.name.to_s, context)
      end

      def on_constant_write(node, context)
        label = node.respond_to?(:target) ? node.target.slice : node.name.to_s
        record(:constant_write, label, context)
      end

      private

      def record(event, label, context, body: nil)
        @events << { event: event, label: label, context: context, body: body }
        verdicts = Rigor::Inference::DeclarationWalk
        @decline.include?([event, label]) ? verdicts::DECLINE : verdicts::DESCEND
      end
    end
  end

  def walk(source, collectors = [recorder_class.new], context = described_class::Context.root(nesting: []))
    described_class.run(Prism.parse(source).value, collectors, context)
  end

  def events(source, **)
    walk(source, [recorder_class.new(**)]).first.events
  end

  def context_of(source, event, label)
    found = events(source).find { |entry| entry[:event] == event && entry[:label] == label }
    raise "no #{event} #{label} event" unless found

    found[:context]
  end

  def fields(context)
    { prefix: context.prefix, self_owner: context.self_owner, singleton_cref: context.singleton_cref,
      nesting: context.nesting }
  end

  # Every node the traversal visits, whichever collectors (if any) it still carries there.
  def walked_nodes(source, collectors)
    visited = []
    trace = TracePoint.new(:call) do |tp|
      next unless tp.method_id == :walk && tp.defined_class == described_class::Traversal

      visited << tp.binding.local_variable_get(:node)
    end
    trace.enable { walk(source, collectors) }
    visited
  end

  describe "class and module bodies" do
    it "qualifies nested, compact and rooted headers and resets a rebound self" do
      source = <<~RUBY
        module Outer
          class Inner
            def nested; end
          end
          class Admin::Widget
            def compact; end
          end
          class ::Rooted
            def rooted; end
          end
        end
      RUBY
      expect(fields(context_of(source, :def_node, "nested")))
        .to eq(prefix: %w[Outer Inner], self_owner: nil, singleton_cref: false, nesting: %w[Outer::Inner Outer])
      expect(fields(context_of(source, :def_node, "compact")))
        .to eq(prefix: %w[Outer Admin::Widget], self_owner: nil, singleton_cref: false,
               nesting: %w[Outer::Admin::Widget Outer])
      expect(fields(context_of(source, :def_node, "rooted")))
        .to eq(prefix: %w[Rooted], self_owner: nil, singleton_cref: false, nesting: %w[Rooted Outer])
    end

    it "hands on_declaration the enclosing context and the body's, even for a body-less header" do
      declaration = events("module M\n  class Leaf < Base; end\nend\n").find { |e| e[:label] == "Leaf" }
      expect(fields(declaration[:context])[:prefix]).to eq(%w[M])
      expect(fields(declaration[:body])).to eq(prefix: %w[M Leaf], self_owner: nil, singleton_cref: false,
                                               nesting: %w[M::Leaf M])
    end

    it "walks neither the header's constant path nor its superclass expression" do
      labels = events("class Foo < Base.build(arg)\n  helper\nend\n").map { |e| e[:label] }
      expect(labels).to eq(%w[Foo helper])
    end

    it "anchors a `self::` header on a rebound self and pushes that name on the nesting" do
      source = <<~RUBY
        module M
          X.class_eval do
            class self::D
              def m; end
            end
          end
        end
      RUBY
      expect(fields(context_of(source, :def_node, "m")))
        .to eq(prefix: %w[X D], self_owner: nil, singleton_cref: false, nesting: %w[X::D M])
    end
  end

  describe "`class <<` bodies" do
    it "walks the expression in the enclosing context and the body with an unnameable self and cref" do
      source = <<~RUBY
        class C
          class << Registry.lookup
            def m; end
          end
        end
      RUBY
      expect(fields(context_of(source, :call, "lookup")))
        .to eq(prefix: %w[C], self_owner: nil, singleton_cref: false, nesting: %w[C])
      expect(fields(context_of(source, :def_node, "m")))
        .to eq(prefix: %w[C], self_owner: [], singleton_cref: true, nesting: %w[C])
      expect(context_of(source, :def_node, "m").unnameable_self?).to be(true)
    end

    it "keeps a bare header below it unnameable and re-anchors at a nameable one" do
      source = <<~RUBY
        class C
          class << self
            class D
              def bare; end
            end
            class ::E
              def rooted; end
            end
            class C::F
              def pathed; end
            end
          end
        end
      RUBY
      expect(fields(context_of(source, :def_node, "bare")))
        .to eq(prefix: [], self_owner: nil, singleton_cref: true, nesting: %w[C])
      expect(fields(context_of(source, :def_node, "rooted")))
        .to eq(prefix: %w[E], self_owner: nil, singleton_cref: false, nesting: %w[E C])
      # Wrong, pinned because the walk reproduces the legacy walkers: Ruby opens `C::F` here (the header's `C`
      # is the top-level class). Flip this when #1519 is fixed.
      expect(fields(context_of(source, :def_node, "pathed")))
        .to eq(prefix: %w[C C::F], self_owner: nil, singleton_cref: false, nesting: %w[C::C::F C])
    end
  end

  describe "meta-new writes" do
    it "walks the factory's receiver and arguments in the enclosing context and rebinds the block's self" do
      source = <<~RUBY
        class C
          K = Class.new(Base.pick) do
            def m; end
          end
        end
      RUBY
      found = events(source)
      expect(found.map { |e| [e[:event], e[:label]] })
        .to eq([[:declaration, "C"], [:constant_write, "K"], [:call, "pick"], [:def_node, "m"]])
      expect(fields(context_of(source, :call, "pick"))[:self_owner]).to be_nil
      expect(fields(context_of(source, :def_node, "m")))
        .to eq(prefix: %w[C], self_owner: %w[C K], singleton_cref: false, nesting: %w[C])
    end

    it "sees through a `.freeze` tail, an or-write and a `K = K || …` guard" do
      source = <<~RUBY
        Frozen = Struct.new(:a) do
          def frozen; end
        end.freeze
        Memo ||= Module.new do
          def memo; end
        end
        Guarded = Guarded || Data.define(:x) do
          def guarded; end
        end
      RUBY
      expect(fields(context_of(source, :def_node, "frozen"))[:self_owner]).to eq(%w[Frozen])
      expect(fields(context_of(source, :def_node, "memo"))[:self_owner]).to eq(%w[Memo])
      expect(fields(context_of(source, :def_node, "guarded"))[:self_owner]).to eq(%w[Guarded])
    end

    it "leaves a write whose rvalue is not the idiom to the ordinary descent" do
      source = "K = build { def m; end }\n"
      expect(fields(context_of(source, :def_node, "m"))[:self_owner]).to be_nil
      expect(events(source).map { |e| e[:event] }).to eq(%i[constant_write call def_node])
    end
  end

  describe "bare factory blocks" do
    it "walks the arguments in the enclosing context and the body with an unnamed self, skipping the parameters" do
      source = <<~RUBY
        class C
          Class.new(pick_parent) do |x = default_value|
            def m; end
          end
        end
      RUBY
      labels = events(source).map { |e| e[:label] }
      expect(labels).to eq(%w[C new pick_parent m])
      expect(fields(context_of(source, :def_node, "m")))
        .to eq(prefix: %w[C], self_owner: [], singleton_cref: false, nesting: %w[C])
    end
  end

  describe "eval-family blocks" do
    it "rebinds self to the receiver and keeps the cref lexical" do
      source = <<~RUBY
        module M
          Target.class_eval do |x = default_value|
            def m; end
          end
          Target.instance_exec(arg) { def n; end }
        end
      RUBY
      expect(events(source).map { |e| e[:label] }).to eq(%w[M class_eval m instance_exec arg n])
      expect(fields(context_of(source, :def_node, "m")))
        .to eq(prefix: %w[M], self_owner: %w[Target], singleton_cref: false, nesting: %w[M])
      expect(fields(context_of(source, :def_node, "n"))[:self_owner]).to eq(%w[Target])
    end

    it "leaves a receiver no name reaches unnamed" do
      source = "class C\n  records.first.class_eval { def m; end }\nend\n"
      expect(fields(context_of(source, :def_node, "m"))[:self_owner]).to eq([])
    end
  end

  describe "the collector protocol" do
    let(:source) do
      <<~RUBY
        class C
          def m
            inside
          end
        end
      RUBY
    end

    # A collector overriding the one event `event`, recording the name of each node it sees.
    def only_class(event)
      Class.new do
        include Rigor::Inference::DeclarationWalk::Collector

        attr_reader :seen

        def initialize
          @seen = []
        end

        define_method(event) do |node, *|
          @seen << node.name
          Rigor::Inference::DeclarationWalk::DESCEND
        end
      end
    end

    def labels(collector)
      collector.events.map { |e| e[:label] }
    end

    it "stops descending for a collector that declines, and only for that collector" do
      declining = recorder_class.new(decline: [[:def_node, "m"]])
      plain = recorder_class.new
      walk(source, [declining, plain])
      expect(labels(declining)).to eq(%w[C m])
      expect(labels(plain)).to eq(%w[C m inside])
    end

    it "keeps the subtree for a collector listed before a decliner, in a pair and in a larger run" do
      pair = [recorder_class.new, recorder_class.new(decline: [[:def_node, "m"]])]
      walk(source, pair)
      expect(pair.map { |collector| labels(collector) }).to eq([%w[C m inside], %w[C m]])

      trio = [recorder_class.new, recorder_class.new(decline: [[:def_node, "m"]]), recorder_class.new]
      walk(source, trio)
      expect(trio.map { |collector| labels(collector) }).to eq([%w[C m inside], %w[C m], %w[C m inside]])
    end

    it "prunes the walk at a node every collector declines" do
      alone = walked_nodes(source, [recorder_class.new(decline: [[:def_node, "m"]])])
      both = walked_nodes(source, Array.new(2) { recorder_class.new(decline: [[:def_node, "m"]]) })
      [alone, both].each do |visited|
        expect(visited.grep(Prism::DefNode).size).to eq(1)
        expect(visited.grep(Prism::CallNode)).to be_empty
      end
      expect(walked_nodes(source, [recorder_class.new]).grep(Prism::CallNode).size).to eq(1)
    end

    it "skips a declaration's body when the collector declines the declaration" do
      found = events("class C\n  def m; end\nend\nhelper\n", decline: [[:declaration, "C"]])
      expect(found.map { |e| e[:label] }).to eq(%w[C helper])
    end

    it "dispatches only the events a collector of the run overrides" do
      defs_only = only_class(:on_def).new
      # A stub would override `on_call` itself, so the dispatch is observed from outside instead.
      default_calls = 0
      trace = TracePoint.new(:call) { |tp| default_calls += 1 if tp.method_id == :on_call }
      trace.enable { walk("class C\n  def m = helper\nend\nhelper\n", [defs_only]) }
      expect(defs_only.seen).to eq(%i[m])
      expect(default_calls).to eq(0)
    end

    it "dispatches an event to the one collector of a mixed run that overrides it" do
      defs_only = only_class(:on_def).new
      calls_only = only_class(:on_call).new
      walk("class C\n  def m = helper\nend\ntop_level\n", [defs_only, calls_only])
      expect(defs_only.seen).to eq(%i[m])
      expect(calls_only.seen).to eq(%i[helper top_level])
    end

    it "names the events a collector class overrides, inherited overrides included" do
      collector = Rigor::Inference::ScopeIndexer::ClassCvarsCollector
      expect(described_class::Collector.events_of(collector)).to eq(%i[on_def])
      expect(described_class::Collector.events_of(Class.new(collector))).to eq(%i[on_def])
      expect(described_class::Collector.events_of(only_class(:on_call))).to eq(%i[on_call])
    end

    it "loads the walk and the rules it applies from its own entry point" do
      # A fresh process: the suite has loaded every file already, which would hide a missing require.
      script = <<~RUBY
        require "rigor/inference/declaration_walk"
        walk = Rigor::Inference::DeclarationWalk
        source = "class C\\n  X.class_eval { def m; end }\\n  K = Class.new { def n; end }\\nend\\n"
        walk.run(Prism.parse(source).value, [Class.new { include walk::Collector }.new])
        print "walked"
      RUBY
      lib = File.expand_path("../../../lib", __dir__)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
      expect([status.success?, stdout, stderr]).to eq([true, "walked", ""])
    end

    it "carries a second decline through what is left of a larger run" do
      source = "class C\n  def m\n    inside\n    other\n  end\nend\n"
      trio = [recorder_class.new(decline: [[:call, "inside"]]), recorder_class.new(decline: [[:def_node, "m"]]),
              recorder_class.new]
      walk(source, trio)
      expect(trio.map { |collector| labels(collector) })
        .to eq([%w[C m inside other], %w[C m], %w[C m inside other]])
    end

    it "keeps every collector that descends where several of a larger run decline the same node" do
      run = Array.new(5) { |index| recorder_class.new(decline: index.odd? ? [[:def_node, "m"]] : []) }
      walk(source, run)
      expect(run.map { |collector| labels(collector) })
        .to eq([%w[C m inside], %w[C m], %w[C m inside], %w[C m], %w[C m inside]])
      declined_first = Array.new(2) { recorder_class.new(decline: [[:def_node, "m"]]) }.push(recorder_class.new)
      walk(source, declined_first)
      expect(declined_first.map { |collector| labels(collector) }).to eq([%w[C m], %w[C m], %w[C m inside]])
    end

    # Objects a run of three allocates over two sources that differ only in how many nodes it dispatches
    # events for: the extra nodes must cost nothing, whether no collector declines or one declines every
    # `def`. The best of three runs is taken, and the tolerance is far below one object per extra node.
    it "allocates nothing per node in a run of three, with no decline and with one collector declining each def" do
      counting = Class.new do
        include Rigor::Inference::DeclarationWalk::Collector

        def initialize(decline) = (@decline = decline)

        # Named parameters: a rest parameter would allocate its own Array per event.
        def on_def(_node, _context)
          @decline ? Rigor::Inference::DeclarationWalk::DECLINE : Rigor::Inference::DeclarationWalk::DESCEND
        end

        def on_call(_node, _context) = Rigor::Inference::DeclarationWalk::DESCEND
      end
      roots = [20, 200].map do |defs|
        Prism.parse("class C\n#{Array.new(defs) { |i| "  def m#{i}\n    helper(#{i})\n  end\n" }.join}end\n").value
      end
      [false, true].each do |decline|
        run = -> { [counting.new(false), counting.new(decline), counting.new(false)] }
        small, large = roots.map do |root|
          described_class.run(root, run.call)
          Array.new(3) do
            collectors = run.call
            before = GC.stat(:total_allocated_objects)
            described_class.run(root, collectors)
            GC.stat(:total_allocated_objects) - before
          end.min
        end
        expect(large - small).to be <= 4, "#{large - small} more objects for 180 more defs (decline: #{decline})"
      end
    end

    it "hands each decliner of a larger run its own remainder, however often each declines" do
      source = "def a\n  x\nend\ndef b\n  y\nend\ndef a\n  z\nend\n"
      trio = [recorder_class.new(decline: [[:def_node, "a"]]), recorder_class.new(decline: [[:def_node, "b"]]),
              recorder_class.new]
      walk(source, trio)
      expect(trio.map { |collector| labels(collector) }).to eq([%w[a b y a], %w[a x b a z], %w[a x b y a z]])
    end
  end

  describe "variants" do
    let(:factory_source) do
      <<~RUBY
        class C
          Class.new(pick) do |x = default_value|
            class self::E; end
            def m; end
          end
        end
      RUBY
    end

    # A recorder following the `:ordinary_call` variant of the `factory_block` rule.
    let(:ordinary_class) do
      Class.new(recorder_class) do
        const_set(:VARIANTS, { factory_block: :ordinary_call }.freeze)
      end
    end
    # Sources whose factory blocks the two variants walk differently, nested in each other and in the other
    # arms: parameters with calls in them, a factory inside a factory, inside an eval block and inside a
    # meta-new body, and one whose receiver and arguments are calls.
    let(:fork_sources) do
      [
        factory_source,
        "Class.new(a.b(c)) do |x = d(Class.new(e) { f })|\n  Class.new(g) { |y = h| i }\n  j\nend\n",
        "class C\n  X.class_eval { Class.new(k) { |z = l| m } }\n  K = Class.new { Class.new(n) { o } }\nend\n",
        "module M\n  class << self\n    Struct.new(:a) { |w = p| q }\n  end\nend\n"
      ]
    end
    # Rebound bodies whose `self` the two `lexical_prefix` variants agree on.
    let(:agreeing_source) do
      <<~RUBY
        module Admin
          class W
            W.class_eval do
              def same; end
            end
            K = Class.new { def k; end }
          end
        end
      RUBY
    end
    # Two eval bodies whose `self` the `lexical_prefix` variants answer differently: below a compact header,
    # and below an unnameable cref.
    let(:nesting_head_sources) do
      [<<~COMPACT, <<~UNNAMEABLE]
        class Admin::W
          W.class_eval do
            class self::U
              def u; end
            end
          end
        end
      COMPACT
        class C
          class X; end
          class << self
            class D
              X.class_eval do
                class self::V
                  def v; end
                end
              end
            end
          end
        end
      UNNAMEABLE
    end
    # `class foo` is a parse error Prism recovers from with a header that renders no name.
    let(:unrendered_source) do
      <<~RUBY
        class foo < Base
          def lost; end
          X.class_eval do
            class self::G
              def regrown; end
            end
          end
        end
      RUBY
    end

    def labelled(collector)
      collector.events.map { |e| [e[:event], e[:label]] }
    end

    it "walks a bare factory block as an ordinary call for a collector that names the variant" do
      ordinary = ordinary_class.new
      walk(factory_source, [ordinary])
      expect(labelled(ordinary)).to eq([[:declaration, "C"], [:call, "new"], [:call, "pick"],
                                        [:call, "default_value"], [:declaration, "self::E"], [:def_node, "m"]])
      e_header = ordinary.events.find { |e| e[:label] == "self::E" }
      expect(e_header[:body].prefix).to eq(%w[C E])
      expect(ordinary.events.find { |e| e[:label] == "m" }[:context].self_owner).to be_nil
    end

    it "gives each collector of a mixed run its own variant's walk of the block, once" do
      plain = recorder_class.new
      ordinary = ordinary_class.new
      [[plain, ordinary], [ordinary, plain]].each do |run|
        run.each { |collector| collector.events.clear }
        walk(factory_source, run)
        expect(labelled(plain)).to eq([[:declaration, "C"], [:call, "new"], [:call, "pick"],
                                       [:declaration, "self::E"], [:def_node, "m"]])
        expect(plain.events.find { |e| e[:label] == "self::E" }[:body].singleton_cref).to be(true)
        expect(labelled(ordinary)).to eq([[:declaration, "C"], [:call, "new"], [:call, "pick"],
                                          [:call, "default_value"], [:declaration, "self::E"], [:def_node, "m"]])
      end
    end

    # Every event a collector saw, with the context fields a collector reads, in order.
    def trace(collector)
      collector.events.map do |e|
        context = e[:context]
        [e[:event], e[:label], context.prefix, context.self_owner, context.singleton_cref, context.nesting]
      end
    end

    it "gives every collector of a mixed run exactly the events, in order, of a run of its own" do
      fork_sources.each do |source|
        solo = [recorder_class.new, ordinary_class.new].each { |collector| walk(source, [collector]) }
        [[recorder_class.new, ordinary_class.new], [ordinary_class.new, recorder_class.new, recorder_class.new]]
          .each do |run|
            walk(source, run)
            run.each do |collector|
              alone = solo.find { |candidate| candidate.instance_of?(collector.class) }
              expect(trace(collector)).to eq(trace(alone))
            end
          end
      end
    end

    it "walks a factory's receiver and arguments once in a mixed run, and only the block per variant" do
      visited = walked_nodes(factory_source, [recorder_class.new, ordinary_class.new])
      calls = visited.grep(Prism::CallNode).map(&:name)
      expect(calls.tally).to include(pick: 1, new: 1, default_value: 1)
      expect(visited.grep(Prism::ConstantReadNode).map(&:name).tally).to include(Class: 1)
      expect(visited.grep(Prism::ClassNode).map { |node| node.constant_path.slice }.tally)
        .to eq("C" => 1, "self::E" => 2)
    end

    it "walks a factory call without a literal block like any call, under either variant" do
      source = "class C\n  Class.new(Base).new(arg)\n  Module.new(&blk)\n  Class.new(pick) { body }\nend\n"
      [[recorder_class.new], [ordinary_class.new], [recorder_class.new, ordinary_class.new]].each do |run|
        walk(source, run)
        run.each do |collector|
          expect(collector.events.map { |e| e[:label] }).to eq(%w[C new new arg new blk new pick body])
        end
      end
    end

    def variant_class(variants)
      Class.new(recorder_class) { const_set(:VARIANTS, variants.freeze) }
    end

    def nestings(collector)
      collector.events.map { |e| e[:context].nesting }
    end

    it "walks a header that renders no name per each collector's unrendered_header variant" do
      children, skip, lost = [{}, { unrendered_header: :skip }, { unrendered_header: :body_with_lost_nesting }]
                             .map { |variants| variant_class(variants).new }
      walk(unrendered_source, [children, skip, lost])
      expect(labelled(children)).to eq([[:call, "foo"], [:def_node, "lost"], [:call, "class_eval"],
                                        [:declaration, "self::G"], [:def_node, "regrown"]])
      expect(skip.events).to be_empty
      expect(labelled(lost)).to eq(labelled(children).drop(1))
      expect(nestings(children)).to eq([[], [], [], [], %w[X::G]])
      expect(nestings(lost)).to eq([nil, nil, nil, %w[X::G]])
      expect(lost.events.map { |e| e[:context].self_owner }).to eq([nil, nil, %w[X], nil])
    end

    it "keeps the chain below `class <<` under the lost-nesting variant, with self the class again" do
      source = "class C\n  class << self\n    class foo\n      def kept; end\n    end\n  end\nend\n"
      children, lost = [{}, { unrendered_header: :body_with_lost_nesting }].map { |v| variant_class(v).new }
      walk(source, [children, lost])
      kept = ->(collector) { fields(collector.events.find { |e| e[:label] == "kept" }[:context]) }
      expect(kept.call(lost)).to eq(prefix: %w[C], self_owner: nil, singleton_cref: true, nesting: %w[C])
      expect(kept.call(children)).to eq(prefix: %w[C], self_owner: [], singleton_cref: true, nesting: %w[C])
    end

    it "splits an eval body against the head of the chain for a collector that names nesting_head" do
      plain = recorder_class.new
      head = variant_class(lexical_prefix: :nesting_head).new
      compact, unnameable = nesting_head_sources
      walk(compact, [plain, head])
      expect(plain.events.last[:context].nesting).to eq(%w[W::U Admin::W])
      expect(head.events.last[:context].nesting).to eq(%w[Admin::W::U Admin::W])
      [plain, head].each { |collector| collector.events.clear }
      walk(unnameable, [head, plain])
      expect(plain.events.last[:context].nesting).to eq(%w[X::V C])
      expect(head.events.last[:context].nesting).to eq(%w[C::X::V C])
    end

    it "walks a rebound body once where the lexical_prefix variants agree on its self, and once per self otherwise" do
      run = -> { [recorder_class.new, variant_class(lexical_prefix: :nesting_head).new] }
      expect(walked_nodes(agreeing_source, run.call).grep(Prism::DefNode).map(&:name).tally).to eq(same: 1, k: 1)
      expect(walked_nodes(nesting_head_sources.first, run.call).grep(Prism::DefNode).map(&:name).tally)
        .to eq(u: 2)
    end

    it "gives every collector of a run mixing every rule's variants the events, in order, of a run of its own" do
      classes = [recorder_class, ordinary_class, variant_class(unrendered_header: :skip),
                 variant_class(unrendered_header: :body_with_lost_nesting),
                 variant_class(lexical_prefix: :nesting_head),
                 variant_class(factory_block: :ordinary_call, lexical_prefix: :nesting_head,
                               unrendered_header: :body_with_lost_nesting)]
      sources = fork_sources + nesting_head_sources + [unrendered_source, agreeing_source,
                                                       "module\n  def swallowed; end\nend\n"]
      sources.each do |source|
        solo = classes.map { |klass| walk(source, [klass.new]).first }
        [classes, classes.reverse, classes.values_at(0, 3), classes.values_at(4, 1, 2)].each do |run_classes|
          run = walk(source, run_classes.map(&:new))
          run.each do |collector|
            expect(trace(collector)).to eq(trace(solo[classes.index(collector.class)]))
          end
        end
      end
    end

    it "refuses a variant no rule has, as a broken walk contract" do
      misspelt = Class.new(recorder_class) { const_set(:VARIANTS, { factory_block: :ordinary }.freeze) }
      unknown = Class.new(recorder_class) { const_set(:VARIANTS, { nesting: :ordinary_call }.freeze) }
      unknown_variant = described_class::UnknownVariant
      expect(unknown_variant.ancestors).to include(described_class::ContractError)
      expect { walk("1", [misspelt.new]) }.to raise_error(unknown_variant, /no :factory_block variant :ordinary/)
      expect { walk("1", [unknown.new]) }.to raise_error(unknown_variant, /no :nesting variant/)
    end

    it "answers the walk's own rule for a collector that names no variant" do
      collector = described_class::Collector
      expect(collector.variant_of(recorder_class, :factory_block)).to eq(:unnamed_self)
      expect(collector.variant_of(ordinary_class, :factory_block)).to eq(:ordinary_call)
      expect(collector.variant_of(ordinary_class, :anonymous_class_path)).to eq(:whole_file)
      expect(collector.variant_of(ordinary_class, :unrendered_header)).to eq(:children)
      expect(collector.variant_of(ordinary_class, :lexical_prefix)).to eq(:prefix)
    end
  end

  describe described_class::Context do
    it "answers the anonymous-class path under each variant, dropping it only in class-like bodies" do
      source = <<~RUBY
        class C
          class << self
            X.class_eval { K = Class.new { } }
          end
        end
      RUBY
      declaration = Prism.parse(source).value.statements.body.first
      root = described_class.root(source_path: "app/x.rb")
      c_body = root.declaration_body(declaration)
      singleton = root.singleton_class_body
      paths = lambda do |context|
        %i[whole_file outside_class_bodies].map { |variant| context.anonymous_class_path(variant) }
      end
      expect(paths.call(root)).to eq(["app/x.rb", "app/x.rb"])
      expect(paths.call(singleton)).to eq(["app/x.rb", "app/x.rb"])
      expect(paths.call(root.factory_body)).to eq(["app/x.rb", "app/x.rb"])
      expect(paths.call(root.meta_new_body(%w[K]))).to eq(["app/x.rb", nil])
      expect(paths.call(root.eval_body(%w[X]))).to eq(["app/x.rb", nil])
      expect(paths.call(c_body)).to eq(["app/x.rb", nil])
      expect(paths.call(c_body.singleton_class_body)).to eq(["app/x.rb", nil])
      expect(paths.call(c_body.factory_body)).to eq(["app/x.rb", nil])
      expect { root.anonymous_class_path(:nowhere) }.to raise_error(ArgumentError)
    end

    it "answers the prefix a split resolves against under each lexical_prefix variant" do
      compact = Prism.parse("class Admin::W; end").value.statements.body.first
      body = described_class.root(nesting: []).declaration_body(compact)
      expect(body.lexical_prefix).to eq(%w[Admin::W])
      expect(body.lexical_prefix(:nesting_head)).to eq(%w[Admin W])
      expect(described_class.root(nesting: []).lexical_prefix(:nesting_head)).to eq([])
      expect(described_class.root.lexical_prefix(:nesting_head)).to eq([])
      expect { body.lexical_prefix(:nowhere) }.to raise_error(Rigor::Inference::DeclarationWalk::UnknownVariant)
    end

    it "loses the chain below a header that renders no name, except below `class <<`" do
      root = described_class.root(nesting: %w[Outer])
      expect(fields(root.lost_header_body)).to eq(prefix: [], self_owner: nil, singleton_cref: false, nesting: nil)
      expect(fields(root.singleton_class_body.lost_header_body))
        .to eq(prefix: [], self_owner: nil, singleton_cref: true, nesting: %w[Outer])
      expect(root.eval_body(%w[X]).lost_header_body.class_body).to be(true)
    end

    it "grows a lost chain again only at a `self::` header below a rebound self" do
      self_header, plain = Prism.parse("class self::G; end\nclass Plain; end\n").value.statements.body
      lost = described_class.root(nesting: %w[Outer]).lost_header_body
      expect(lost.eval_body(%w[X]).declaration_body(self_header).nesting).to eq(%w[X::G])
      expect(lost.declaration_body(plain).nesting).to be_nil
      expect(lost.eval_body(%w[X]).declaration_body(plain).nesting).to be_nil
    end

    it "tracks no nesting when the root carries none" do
      context = described_class.root
      body = context.declaration_body(Prism.parse("class C; end").value.statements.body.first)
      expect(body.nesting).to be_nil
      expect(body.singleton_class_body.nesting).to be_nil
    end

    it "stamps the header chain on the scope it carries" do
      declaration = Prism.parse("class Admin::Census; end").value.statements.body.first
      body = described_class.root(scope: Rigor::Scope.empty).declaration_body(declaration)
      expect(body.scope.lexical_nesting).to eq(%w[Admin::Census])
    end

    it "pushes the scope's chain at a header the ancestry nesting leaves alone" do
      # The census scope's chain is pushed at every header, the unnameable one below `class <<` included;
      # the ancestry chain is not. Both answers are kept (see the class comment).
      source = "class C\n  class << self\n    class D\n    end\n  end\nend\n"
      outer = Prism.parse(source).value.statements.body.first
      inner = outer.body.body.first.body.body.first
      c_body = described_class.root(scope: Rigor::Scope.empty, nesting: []).declaration_body(outer)
      d_body = c_body.singleton_class_body.declaration_body(inner)
      expect(d_body.nesting).to eq(%w[C])
      expect(d_body.scope.lexical_nesting).to eq(%w[C::D C])
    end
  end
end
