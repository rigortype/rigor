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

    it "refuses a variant no rule has" do
      misspelt = Class.new(recorder_class) { const_set(:VARIANTS, { factory_block: :ordinary }.freeze) }
      unknown = Class.new(recorder_class) { const_set(:VARIANTS, { nesting: :ordinary_call }.freeze) }
      expect { walk("1", [misspelt.new]) }.to raise_error(ArgumentError, /no :factory_block variant :ordinary/)
      expect { walk("1", [unknown.new]) }.to raise_error(ArgumentError, /no :nesting variant/)
    end

    it "answers the walk's own rule for a collector that names no variant" do
      collector = described_class::Collector
      expect(collector.variant_of(recorder_class, :factory_block)).to eq(:unnamed_self)
      expect(collector.variant_of(ordinary_class, :factory_block)).to eq(:ordinary_call)
      expect(collector.variant_of(ordinary_class, :anonymous_class_path)).to eq(:whole_file)
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
