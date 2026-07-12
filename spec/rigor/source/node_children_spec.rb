# frozen_string_literal: true

require "prism"

RSpec.describe Rigor::Source::NodeChildren do
  # Real analyzer source — large files whose ASTs exercise a broad span of node classes, so the equivalence corpus
  # tracks the shapes Rigor actually walks.
  let(:corpus_files) do
    root = File.expand_path("../../..", __dir__)
    %w[
      lib/rigor/inference/statement_evaluator.rb
      lib/rigor/inference/expression_typer.rb
      lib/rigor/inference/scope_indexer.rb
    ].map { |rel| File.join(root, rel) }
  end

  # Hand-written source adding the node classes the analyzer files happen not to contain — pattern matching, every
  # abbreviated-assignment variant (`&&= ||= +=` on ivar/cvar/gvar/constant/const-path/call/index), multiple-assignment
  # targets, flip-flops, alias/undef, BEGIN/END, argument forwarding, numbered / `it` block params, xstring, and the
  # regexp-in-condition match nodes — so the contract is proven over (close to) the whole Prism node zoo, not only what
  # the three analyzer files use. Single-quoted heredoc so `#{…}` stays literal source text.
  let(:exotic_source) do
    <<~'RUBY'
      case obj
      in [1, *rest, last] then a
      in {name: String => n, **opts} then b
      in [Integer, Float] | String then c
      in ^pinned then d
      in ^(1 + 2) then e
      in Point(x:, y:) then f
      in [*, 3, *post] then g
      end
      for i in 1..10 do puts i end
      x = 1 if (a..b)
      y = 1 if (a...b)
      BEGIN { init }
      END { teardown }
      alias foo bar
      alias $g1 $g2
      undef meth1, meth2
      @iv &&= 1; @iv ||= 2; @iv += 3
      @@cv &&= 1; @@cv ||= 2; @@cv += 3
      $gv &&= 1; $gv ||= 2; $gv += 3
      CONST &&= 1; CONST ||= 2; CONST += 3
      Mod::Path &&= 1; Mod::Path ||= 2; Mod::Path += 3
      recv.attr &&= 1; recv.attr ||= 2; recv.attr += 3
      arr[0] &&= 1; arr[0] ||= 2; arr[0] += 3
      r = 1r; i = 2i; ri = 3ri
      nums = [1, 2].map { _1 + _2 }
      it_blk = [1].each { it.to_s }
      cmd = `echo hi`
      /regexp #{x}/ =~ line
      "str" =~ /lit/
      %w[a b c]
      ->(a, b) { a + b }
      h => {key:}
      val in Integer
      class C
        @@cvar = 1
        @@cvar2 = @@cvar
        def m(...) = other(...)
        def n(**nil); end
        def blk = [1].each { |x; local| x }
      end
      $global_w = 42
      a, b.attr, c::Path, d[0], @@cv, $gv, Const = *arr
      if /(?<name>\w+)/ =~ input then name end
      if /literal/ then aa end
      if /interp #{y} end/ then bb end
      __ENCODING__
    RUBY
  end

  # each_child's output as an array, so the spec can compare it against compact_child_nodes.
  def collect_children(node)
    out = []
    described_class.each_child(node) { |child| out << child }
    out
  end

  # each_child MUST be element-for-element identical (object identity + order) to compact_child_nodes for this node,
  # and a leaf class MUST have no children.
  def verify_node(node, label)
    expected = node.compact_child_nodes
    actual = collect_children(node)
    expect(actual.length).to eq(expected.length), -> { "#{label}: #{node.class} arity — #{actual} vs #{expected}" }
    actual.each_index { |i| expect(actual[i]).to be(expected[i]) }
    expect(expected).to be_empty if described_class::LEAF_CLASSES.include?(node.class)
  end

  # Walk `root` in pre-order, verifying every node. Returns the node count.
  def assert_equivalent(source, label)
    count = 0
    stack = [Prism.parse(source).value]
    until stack.empty?
      node = stack.pop
      next unless node.is_a?(Prism::Node)

      count += 1
      verify_node(node, label)
      node.compact_child_nodes.each { |child| stack.push(child) }
    end
    count
  end

  describe "reflection-derived tables" do
    it "maps every leaf class to the shared empty entry and every non-leaf to a non-empty frozen array" do
      described_class::NODE_CLASSES.each do |klass|
        readers = described_class::CHILD_READERS.fetch(klass)
        expect(readers).to be_frozen
        if described_class::LEAF_CLASSES.include?(klass)
          expect(readers).to be(described_class::EMPTY)
        else
          expect(readers).not_to be_empty
          readers.each do |reader, kind|
            expect(reader).to be_a(Symbol)
            expect(kind).to(satisfy { |k| %i[node list].include?(k) })
          end
        end
      end
    end

    it "recognises the expected order of magnitude of leaf classes" do
      # ~43 in prism 1.x; asserted as a loose band so a prism upgrade that adds/removes a leaf does not break the
      # contract (ADR-79 — Rigor tracks the installed prism).
      expect(described_class::LEAF_CLASSES.size).to be_between(30, 60)
    end
  end

  describe ".each_child" do
    it "is object-identical to compact_child_nodes for every node in the analyzer corpus" do
      total = corpus_files.sum { |path| assert_equivalent(File.read(path), File.basename(path)) }
      expect(total).to be > 10_000 # the corpus really is large — guards against a silently-empty walk
    end

    it "is object-identical to compact_child_nodes across the exotic-syntax corpus" do
      expect(assert_equivalent(exotic_source, "exotic")).to be > 100
    end

    it "exercises the full breadth of node classes across both corpora" do
      seen = Set.new
      (corpus_files.map { |path| File.read(path) } + [exotic_source]).each do |src|
        stack = [Prism.parse(src).value]
        until stack.empty?
          node = stack.pop
          next unless node.is_a?(Prism::Node)

          seen << node.class
          node.compact_child_nodes.each { |child| stack.push(child) }
        end
      end
      # The corpora between them must reach the large majority of the node zoo, otherwise the equivalence claim is
      # thin. (Not every class is reachable from parseable source — some are synthesised only in edge cases.)
      expect(seen.size).to be >= 130
    end

    it "yields nothing for a leaf node" do
      leaf = Prism.parse("42").value.statements.body.first
      expect(leaf).to be_a(Prism::IntegerNode)
      expect(collect_children(leaf)).to be_empty
    end

    it "yields nothing for non-node input (defensive nil child slot)" do
      expect { |probe| described_class.each_child(nil, &probe) }.not_to yield_control
    end

    it "propagates break out of the yielder, stopping early like compact_child_nodes.each" do
      array = Prism.parse("[10, 20, 30]").value.statements.body.first
      expect(array.compact_child_nodes.length).to eq(3)
      seen = []
      described_class.each_child(array) do |child|
        seen << child
        break if seen.size == 2
      end
      expect(seen.size).to eq(2) # broke at the 2nd of 3 children — break unwound out of each_child
    end
  end
end
