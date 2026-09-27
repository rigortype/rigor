# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"

# ADR-116 WD5 slice 3 — the first shared walk. The def-nesting table and the two member-layout tables join the
# superclass tables on ONE {DeclarationWalk} run per file (`ScopeIndexer.declaration_walk_tables`), where the
# legacy walkers descended the file once per table. The legacy walkers stay as the oracles; these sources drive
# every arm they had, and every variant the new collectors declare, through the shared run and through each
# standalone builder. The corpus-scale half is `RIGOR_SHADOW_RULE_WALK=1`.
module SharedWalkCases
  CASES = {
    "nesting head: a compact header, and a receiver naming its last segment" => <<~RUBY,
      class Admin::W
        W.class_eval do
          class self::U
            def u; end
          end
        end
      end
    RUBY
    "nesting head: an unnameable cref, and a receiver the file declares under the enclosing class" => <<~RUBY,
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
    RUBY
    "a broken header: the chain is lost, and a self:: header grows it again" => <<~RUBY,
      class foo
        def lost; end
        X.class_eval do
          class self::G
            def regrown; end
          end
        end
        class Kept
          def still_lost; end
        end
      end
    RUBY
    "a broken header below class <<" => <<~RUBY,
      class C
        class << self
          class foo
            def kept; end
          end
        end
      end
    RUBY
    "a module header that swallowed a def" => "class Valid < Base; end\nmodule\n  def swallowed; end\nend\n",
    "member layouts in every form" => <<~RUBY,
      class Point < Data.define(:x, :y); end
      class Pair < Struct.new(:a, :b, keyword_init: true); end
      class Blocked < Data.define(:b) { def extra; end }; end
      class SBlocked < Struct.new(:s) { def extra; end }; end
      class Wrapped < Class.new(Data.define(:w)); end
      Kept = Class.new(Data.define(:q)) { def extra; end }
      Line = Data.define(:from, :to)
      Box ||= Struct.new(:w) do
        Inner = Data.define(:i)
      end.freeze
      module M
        class << self
          Lost = Data.define(:l)
          M::Found = Data.define(:f)
          class Hidden < Data.define(:h); end
        end
        X.class_eval { self::Evaled = Struct.new(:e) }
      end
      class foo < Data.define(:broken)
        Skipped = Data.define(:s)
      end
    RUBY
    "a bare factory block" => <<~RUBY,
      class C
        Class.new(Base) do |p = (Param = Data.define(:p))|
          class self::F < Data.define(:f)
            def f; end
          end
        end
      end
    RUBY
    "a top-level anonymous class, keyed with the file's path" => "Class.new(Base) { def m; end }\n",
    "defs nest where the chain says, and nothing below a def is recorded" => <<~RUBY
      def top; end
      module Outer
        class Inner < Base
          def m
            def nested; end
          end
          K = Class.new { def in_meta; end }
        end
        class ::Rooted
          def r; end
        end
      end
    RUBY
  }.freeze
end

RSpec.describe Rigor::Inference::ScopeIndexer do
  let(:shadow) { Rigor::Inference::DeclarationWalk::Shadow }

  around do |example|
    saved = ENV.fetch("RIGOR_SHADOW_RULE_WALK", nil)
    ENV.delete("RIGOR_SHADOW_RULE_WALK")
    example.run
  ensure
    saved.nil? ? ENV.delete("RIGOR_SHADOW_RULE_WALK") : ENV.store("RIGOR_SHADOW_RULE_WALK", saved)
  end

  def parse(source)
    Prism.parse(source).value
  end

  def legacy_tables(root, path)
    superclasses, header_nestings = described_class.legacy_superclass_tables(root, path)
    { superclasses: superclasses, header_nestings: header_nestings,
      def_nestings: described_class.legacy_def_nestings(root),
      data_member_layouts: described_class.legacy_data_member_layouts(root),
      struct_member_layouts: described_class.legacy_struct_member_layouts(root) }
  end

  def standalone_tables(root, path)
    superclasses, header_nestings = described_class.build_superclass_tables(root, path)
    data, struct = described_class.member_layout_tables(root)
    { superclasses: superclasses, header_nestings: header_nestings,
      def_nestings: described_class.build_def_nestings(root), data_member_layouts: data,
      struct_member_layouts: struct }
  end

  def nestings_by_name(source)
    described_class.declaration_walk_tables(parse(source), "app/x.rb")
                   .fetch(:def_nestings).to_h { |node, chain| [node.name, chain] }
  end

  describe "the shared walk" do
    SharedWalkCases::CASES.each do |name, source|
      it "builds every legacy table in one run and in each standalone builder: #{name}" do
        root = parse(source)
        legacy = legacy_tables(root, "app/x.rb")
        expect(legacy.values.map(&:size).sum).to be_positive
        expect(shadow.first_difference(legacy, described_class.declaration_walk_tables(root, "app/x.rb"), "")).to be_nil
        expect(shadow.first_difference(legacy, standalone_tables(root, "app/x.rb"), "")).to be_nil
      end
    end

    it "records each def's chain, the empty one at the top level, and nothing below a def" do
      source = SharedWalkCases::CASES.fetch("defs nest where the chain says, and nothing below a def is recorded")
      expect(nestings_by_name(source))
        .to eq(top: [], m: %w[Outer::Inner Outer], in_meta: %w[Outer::Inner Outer], r: %w[Rooted Outer])
    end

    it "keys an anonymous class with the path the file is walked under" do
      source = SharedWalkCases::CASES.fetch("a top-level anonymous class, keyed with the file's path")
      walked = described_class.declaration_walk_tables(parse(source), "app/x.rb")
      expect(walked.fetch(:superclasses)).to eq("#<Class:app/x.rb:1:0>" => "Base")
      expect(nestings_by_name(source)).to eq(m: [])
    end

    it "keys a def-nesting entry by the def node itself" do
      root = parse("class C\n  def a; end\n  def a; end\nend\n")
      table = described_class.declaration_walk_tables(root).fetch(:def_nestings)
      expect(table.compare_by_identity?).to be(true)
      expect(table.keys).to eq(root.statements.body.first.body.body)
    end
  end

  # Each answer below is a variant a collector declares to stay byte-identical with its legacy walker; #1521
  # tracks converging them. Flip these when their #1521 items are fixed.
  describe "the def-nesting variants" do
    it "resolves meta-new and eval splits against the head of the chain (lexical_prefix: :nesting_head)" do
      # The walk's own prefix is `["Admin::W"]`, which resolves `W` to the top-level `W`; the head of the chain
      # splits to `["Admin", "W"]`, whose last segment is the receiver, so the eval reopens `Admin::W`.
      expect(nestings_by_name(SharedWalkCases::CASES.values[0])).to eq(u: %w[Admin::W::U Admin::W])
      # Below `class <<` the walk's prefix is `[]`; the chain's head is still `C`, which resolves `X` to `C::X`.
      expect(nestings_by_name(SharedWalkCases::CASES.values[1])).to eq(v: %w[C::X::V C])
    end

    it "walks only the body of a header that renders no name, with the chain lost outside class <<" do
      lost = SharedWalkCases::CASES.fetch("a broken header: the chain is lost, and a self:: header grows it again")
      expect(nestings_by_name(lost)).to eq(regrown: %w[X::G])
      expect(nestings_by_name(SharedWalkCases::CASES["a broken header below class <<"])).to eq(kept: %w[C])
      expect(nestings_by_name(SharedWalkCases::CASES["a module header that swallowed a def"])).to eq({})
    end

    it "walks a bare factory block as an ordinary call (factory_block: :ordinary_call)" do
      expect(nestings_by_name(SharedWalkCases::CASES["a bare factory block"])).to eq(f: %w[C::F C])
    end
  end

  describe "the member-layout variants" do
    let(:tables) do
      described_class.declaration_walk_tables(parse(SharedWalkCases::CASES["member layouts in every form"]))
    end

    it "records every form, and nothing below a header that renders no name (unrendered_header: :skip)" do
      # A header's factory may not carry a block (`Blocked`, `SBlocked`); a constant's may. `M::M::Found` is
      # the compact-header answer #1519 tracks; `Lost` and `Hidden` name nothing below `class <<`; `foo`'s
      # superclass and body are skipped.
      expect(tables.fetch(:data_member_layouts).keys).to eq(%w[Point Wrapped Kept Line Inner M::M::Found])
      expect(tables.fetch(:struct_member_layouts))
        .to eq("Pair" => { members: %i[a b], keyword_init: true }, "Box" => { members: %i[w], keyword_init: false },
               "X::Evaled" => { members: %i[e], keyword_init: false })
    end

    it "walks a bare factory block as an ordinary call, parameters included (factory_block: :ordinary_call)" do
      walked = described_class.declaration_walk_tables(parse(SharedWalkCases::CASES["a bare factory block"]))
      expect(walked.fetch(:data_member_layouts)).to eq("C::Param" => %i[p], "C::F" => %i[f])
    end
  end

  describe "the shadow harness on the shared walk" do
    before { ENV.store("RIGOR_SHADOW_RULE_WALK", "1") }

    it "names the def-nesting table when it diverges" do
      forgetful = Class.new(described_class::DefNestingsCollector) do
        def table = {}.compare_by_identity.freeze
      end
      instance = forgetful.new
      allow(described_class::DefNestingsCollector).to receive(:new).and_return(instance)
      # The file is named, and the node key is rendered by its class, name and start, not its subtree.
      expect { described_class.declaration_walk_tables(parse("class C\n  def m; end\nend\n"), "app/c.rb") }
        .to raise_error(Rigor::Inference::DeclarationWalk::Shadow::Divergence,
                        "RIGOR_SHADOW_RULE_WALK divergence: discovery table `def_nestings` for app/c.rb: " \
                        "the table: key #<DefNode m at 2:2> only in legacy")
    end

    it "names the member-layout tables when they diverge" do
      forgetful = Class.new(described_class::MemberLayoutsCollector) do
        def tables = [{}.freeze, {}.freeze]
      end
      instance = forgetful.new
      allow(described_class::MemberLayoutsCollector).to receive(:new).and_return(instance)
      expect { described_class.declaration_walk_tables(parse("Point = Data.define(:x)\n"), "app/c.rb") }
        .to raise_error(Rigor::Inference::DeclarationWalk::Shadow::Divergence,
                        /discovery table `member_layouts` for app\/c\.rb: \[0\]: key "Point" only in legacy\z/)
    end
  end

  describe "production" do
    let(:ported) do
      [described_class::SuperclassesCollector, described_class::MemberLayoutsCollector,
       described_class::DefNestingsCollector]
    end
    let(:source) do
      defs = SharedWalkCases::CASES.fetch("defs nest where the chain says, and nothing below a def is recorded")
      "Point = Data.define(:x)\n#{defs}"
    end

    # The collector classes of each `DeclarationWalk.run` the block makes, in order.
    def walk_runs(&)
      runs = []
      trace = TracePoint.new(:call) do |tp|
        next unless tp.method_id == :run && tp.defined_class == Rigor::Inference::DeclarationWalk.singleton_class

        runs << tp.binding.local_variable_get(:collectors).map(&:class)
      end
      trace.enable(&)
      runs
    end

    it "builds the ported tables in one walk of the file" do
      expect(walk_runs { described_class.declaration_walk_tables(parse(source), "app/x.rb") }).to eq([ported])
    end

    it "walks a file once for the ported tables in its own index" do
      runs = walk_runs { described_class.index(parse(source), default_scope: Rigor::Scope.empty) }
      expect(runs.select { |classes| classes.intersect?(ported) }).to eq([ported])
    end

    it "walks each file once for the ported tables in the project pre-pass" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "x.rb")
        File.write(path, source)
        %i[discovered_def_index_for_paths discovered_project_index_for_paths].each do |entry|
          runs = walk_runs { described_class.public_send(entry, [path]) }
          expect(runs.select { |classes| classes.intersect?(ported) }).to eq([ported])
        end
      end
    end
  end
end
