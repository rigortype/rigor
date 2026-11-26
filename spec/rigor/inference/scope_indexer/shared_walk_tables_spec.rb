# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (U4) — `ScopeIndexer::SharedWalkTables` holds the tables one shared walk builds for a file: the
# as-written superclasses with the nesting each header is written in, the def nestings, and the `Data.define` and
# `Struct.new` member layouts. The examples hand its functions a parsed snippet and, for the four the collectors
# call, a table, and read the table back: no index is built and no body evaluated. `.declaration_walk_tables` is
# the collectors' one run. The builders that run one collector alone and the walkers the collectors replaced are
# private and reached through `send`, as the two equivalence specs (`scope_indexer_shared_walk_spec.rb` and
# `scope_indexer_superclasses_equivalence_spec.rb`) reach them to compare the two over every arm and variant. What
# an index and a run make of the tables is pinned in `scope_indexer_spec.rb` and `spec/integration/`.
RSpec.describe Rigor::Inference::ScopeIndexer::SharedWalkTables do
  let(:indexer) { Rigor::Inference::ScopeIndexer }
  let(:any_name) { Rigor::Scope::DiscoveryIndex::UNKEYED_HEADER_NESTING }

  around do |example|
    saved = ENV.fetch("RIGOR_SHADOW_RULE_WALK", nil)
    ENV.delete("RIGOR_SHADOW_RULE_WALK")
    example.run
  ensure
    saved.nil? ? ENV.delete("RIGOR_SHADOW_RULE_WALK") : ENV.store("RIGOR_SHADOW_RULE_WALK", saved)
  end

  def parse(source) = Prism.parse(source).value

  def statement(source) = parse(source).statements.body.first

  # A def-nesting table by the name of each `def`.
  def by_name(table) = table.to_h { |node, chain| [node.name, chain] }

  describe ".declaration_walk_tables" do
    let(:source) do
      <<~RUBY
        def top; end
        module Outer
          class Inner < Base
            include Mix
            def m; end
          end
          Point = Data.define(:x, :y)
          Pair = Struct.new(:a, :b, keyword_init: true)
        end
        Class.new(Parent) { def anon; end }
      RUBY
    end

    it "answers five empty tables for a file that declares nothing, and for a root that is no node" do
      nothing = { superclasses: {}, header_nestings: {}, def_nestings: {}, data_member_layouts: {},
                  struct_member_layouts: {} }

      expect(described_class.declaration_walk_tables(parse("x = 1\n"))).to eq(nothing)
      expect(described_class.declaration_walk_tables(nil)).to eq(nothing)
    end

    it "freezes each table" do
      expect(described_class.declaration_walk_tables(parse(source)).values.map(&:frozen?)).to eq([true] * 5)
    end

    it "builds the superclass table, and the nesting each header is written in under every name it wrote" do
      walked = described_class.declaration_walk_tables(parse(source), "app/x.rb")

      expect(walked.fetch(:superclasses)).to eq("Outer::Inner" => "Base", "#<Class:app/x.rb:10:0>" => "Parent")
      expect(walked.fetch(:header_nestings))
        .to eq("Outer::Inner" => { any_name => ["Outer"], "Base" => ["Outer"], "Mix" => ["Outer"] })
    end

    it "keys an anonymous class without a path when the file is given none" do
      expect(described_class.declaration_walk_tables(parse(source)).fetch(:superclasses).keys)
        .to eq(["Outer::Inner", "#<Class:10:0>"])
    end

    it "builds the def-nesting table, keyed by the def node itself" do
      table = described_class.declaration_walk_tables(parse(source)).fetch(:def_nestings)

      expect(table.compare_by_identity?).to be(true)
      expect(by_name(table)).to eq(top: [], m: %w[Outer::Inner Outer], anon: [])
    end

    it "builds the two member-layout tables" do
      walked = described_class.declaration_walk_tables(parse(source))

      expect(walked.fetch(:data_member_layouts)).to eq("Outer::Point" => %i[x y])
      expect(walked.fetch(:struct_member_layouts)).to eq("Outer::Pair" => { members: %i[a b], keyword_init: true })
    end

    describe "under RIGOR_SHADOW_RULE_WALK" do
      let(:walkers) do
        %i[legacy_superclass_tables legacy_def_nestings legacy_data_member_layouts legacy_struct_member_layouts]
      end

      before { walkers.each { |walker| allow(described_class).to receive(walker).and_call_original } }

      it "runs no walker a collector replaced while the flag is unset" do
        described_class.declaration_walk_tables(parse(source), "app/x.rb")

        walkers.each { |walker| expect(described_class).not_to have_received(walker) }
      end

      it "runs each once when the flag is set, on the root and, for the superclasses, the path it was given" do
        ENV.store("RIGOR_SHADOW_RULE_WALK", "1")
        root = parse(source)
        described_class.declaration_walk_tables(root, "app/x.rb")

        expect(described_class).to have_received(:legacy_superclass_tables).with(root, "app/x.rb").once
        walkers.drop(1).each { |walker| expect(described_class).to have_received(walker).with(root).once }
      end

      it "checks the table of a builder that runs one collector alone, too" do
        ENV.store("RIGOR_SHADOW_RULE_WALK", "1")
        root = parse(source)
        described_class.send(:build_superclass_tables, root, "app/x.rb")
        described_class.send(:build_def_nestings, root)
        described_class.send(:member_layout_tables, root)

        expect(described_class).to have_received(:legacy_superclass_tables).with(root, "app/x.rb").once
        walkers.drop(1).each { |walker| expect(described_class).to have_received(walker).with(root).once }
      end

      # A walker that answers a table the collector did not build, for each of the three checks.
      { def_nestings: [:legacy_def_nestings, { ghost: [] }.compare_by_identity.freeze],
        superclass_tables: [:legacy_superclass_tables, [{ "Ghost" => "Base" }.freeze, {}.freeze]],
        member_layouts: [:legacy_data_member_layouts, { "Ghost" => %i[g] }.freeze] }.each do |table, (walker, answer)|
        it "names `#{table}` and the file when a collector and its walker disagree" do
          ENV.store("RIGOR_SHADOW_RULE_WALK", "1")
          allow(described_class).to receive(walker).and_return(answer)

          expect { described_class.declaration_walk_tables(parse("x = 1\n"), "app/c.rb") }
            .to raise_error(Rigor::Inference::DeclarationWalk::Shadow::Divergence,
                            %r{divergence: discovery table `#{table}` for app/c\.rb: .*ghost.* only in legacy\z}i)
        end
      end
    end
  end

  describe ".record_declaration_ancestry" do
    # As `SuperclassesCollector#on_declaration` calls it: the header, the nesting outside it, the prefix its body
    # opens, and the collector's two tables.
    def ancestry(source, nesting, prefix)
      tables = { superclasses: {}, header_nestings: {} }
      described_class.record_declaration_ancestry(statement(source), nesting, prefix, tables)
      tables
    end

    it "records a class's superclass as written, and the nesting under it and under the unkeyed entry" do
      expect(ancestry("class W < N::Base; end", ["Outer"], %w[Outer W]))
        .to eq(superclasses: { "Outer::W" => "N::Base" },
               header_nestings: { "Outer::W" => { any_name => ["Outer"], "N::Base" => ["Outer"] } })
    end

    it "keeps the `::` of a superclass written with one, in the table and in the key" do
      expect(ancestry("class W < ::Base; end", [], %w[W]))
        .to eq(superclasses: { "W" => "::Base" }, header_nestings: { "W" => { any_name => [], "::Base" => [] } })
    end

    it "keys the nesting by each mixin the body names, and records no superclass for a module" do
      expect(ancestry("module Mod\n  include I, N::J\n  prepend P\n  extend E\nend\n", ["A"], %w[A Mod]))
        .to eq(superclasses: {},
               header_nestings: { "A::Mod" => { any_name => ["A"], "I" => ["A"], "N::J" => ["A"], "P" => ["A"] } })
    end

    it "records nothing for a header that names no ancestor" do
      expect(ancestry("class C\n  def m; end\nend\n", ["A"], %w[A C])).to eq(superclasses: {}, header_nestings: {})
    end

    it "records the unkeyed entry alone for a mixin call that names nothing it can render" do
      expect(ancestry("class C\n  include helper\nend\n", ["A"], %w[A C]).fetch(:header_nestings))
        .to eq("A::C" => { any_name => ["A"] })
    end

    # The scan stops where `self` is no longer the class: a nested header, a `class <<` body, and a block
    # `ScopeIndexer.rebound_block_self` says rebinds it. A block that rebinds nothing is still the class's.
    it "leaves out a mixin written where `self` is another class" do
      source = <<~RUBY
        class C
          class Nested; include InNested; end
          module NestedModule; include InNestedModule; end
          class << self; include InSingleton; end
          K = Class.new { include InFactory }
          X.class_eval { include InEval }
          tap { include InPlainBlock }
        end
      RUBY

      expect(ancestry(source, [], %w[C]).fetch(:header_nestings))
        .to eq("C" => { any_name => [], "InPlainBlock" => [] })
    end

    # The merge is `ScopeIndexer.add_header_nesting`'s: the recorder hands it each site.
    it "reads only a call with no receiver as a mixin" do
      expect(ancestry("class C\n  self.include M\n  other.prepend N\nend\n", [], %w[C]))
        .to eq(superclasses: {}, header_nestings: {})
    end

    it "merges a second site into the class's bucket, the deeper chain first, and keeps the last superclass" do
      tables = { superclasses: {}, header_nestings: {} }
      described_class.record_declaration_ancestry(statement("class C < Base; end"), ["A"], %w[A C], tables)
      described_class.record_declaration_ancestry(statement("class C < Later; end"), %w[A::B A], %w[A C], tables)

      expect(tables.fetch(:superclasses)).to eq("A::C" => "Later")
      expect(tables.fetch(:header_nestings))
        .to eq("A::C" => { any_name => %w[A::B A], "Base" => ["A"], "Later" => %w[A::B A] })
    end
  end

  describe ".recorded_ancestor_name" do
    # As `CvarHierarchy.record` asks it for a header's superclass.
    it "renders a constant as written, with the `::` of a rooted one" do
      names = %w[Base A::Base ::Base ::A::Base]

      expect(names.map { |name| described_class.recorded_ancestor_name(statement(name)) }).to eq(names)
    end

    it "answers nil for an expression that is no constant" do
      expect(%w[base Struct.new(:a)].map { |source| described_class.recorded_ancestor_name(statement(source)) })
        .to eq([nil, nil])
    end
  end

  describe ".record_anonymous_meta_superclass" do
    # As `SuperclassesCollector#on_call` calls it: the call, the superclass table, and the path.
    def anonymous(source, path = "app/x.rb")
      table = {}
      described_class.record_anonymous_meta_superclass(statement(source), table, path)
      table
    end

    it "records the first argument of a `Class.new` with a block, under the name of the call site" do
      expect(anonymous("Class.new(Parent) { }")).to eq("#<Class:app/x.rb:1:0>" => "Parent")
      expect(anonymous("Class.new(A::P) do end", nil)).to eq("#<Class:1:0>" => "A::P")
    end

    it "does not mark a rooted argument" do
      expect(anonymous("Class.new(::P) { }")).to eq("#<Class:app/x.rb:1:0>" => "P")
    end

    it "records nothing without a block, without an argument, or for an argument that is no constant" do
      expect(["Class.new(Parent)", "Class.new { }", "Class.new(parent) { }"].map { |source| anonymous(source) })
        .to eq([{}, {}, {}])
    end

    it "records nothing for another factory or another call" do
      sources = ["Module.new(Parent) { }", "Struct.new(Parent) { }", "build(Parent) { }"]

      expect(sources.map { |source| anonymous(source) }).to eq([{}, {}, {}])
    end
  end

  describe ".record_data_member_layout" do
    # As `MemberLayoutsCollector` calls it: the table, the prefix of the class, and a header's superclass
    # (`allow_outer_block: false`) or a write's value.
    def data(source, **)
      table = {}
      described_class.record_data_member_layout(table, %w[N P], statement(source), **)
      table
    end

    it "records the literal members of a `Data.define` call, in order, under the class, frozen" do
      expect(data("Data.define(:x, :y)")).to eq("N::P" => %i[x y])
      expect(data("::Data.define(:r)")).to eq("N::P" => %i[r])
      expect(data("Data.define(:x)").fetch("N::P")).to be_frozen
    end

    it "unwinds `Class.new` wrappers of one argument each to the factory" do
      expect(data("Class.new(Class.new(Data.define(:w)))")).to eq("N::P" => %i[w])
      expect(data("Class.new(Data.define(:w), 1)")).to eq({})
    end

    it "records nothing for a member list that is empty or holds a splat, or for another call" do
      sources = ["Data.define", "Data.define(*F)", "Data.define(:x, *F)", "Struct.new(:a)", "x.define(:q)", "nil"]

      expect(sources.map { |source| data(source) }).to eq([{}] * 6)
    end

    it "takes the block of the outermost call for a write's value, and not for a header's superclass" do
      expect(data("Data.define(:x) { def e; end }")).to eq("N::P" => %i[x])
      expect(data("Data.define(:x) { def e; end }", allow_outer_block: false)).to eq({})
      expect(data("Class.new(Data.define(:w)) { }", allow_outer_block: false)).to eq({})
    end

    it "never takes the block of a factory inside a wrapper" do
      expect(data("Class.new(Data.define(:w) { })")).to eq({})
    end
  end

  describe ".record_struct_member_layout" do
    # As `MemberLayoutsCollector` calls it, beside `.record_data_member_layout`.
    def struct(source, **)
      table = {}
      described_class.record_struct_member_layout(table, %w[N P], statement(source), **)
      table
    end

    it "records the literal members of a `Struct.new` call and its `keyword_init:` flag, under the class" do
      expect(struct("Struct.new(:a, :b)")).to eq("N::P" => { members: %i[a b], keyword_init: false })
      expect(struct("::Struct.new(:a, keyword_init: true)")).to eq("N::P" => { members: %i[a], keyword_init: true })
    end

    it "freezes the entry and its members" do
      entry = struct("Struct.new(:a)").fetch("N::P")

      expect([entry.frozen?, entry.fetch(:members).frozen?]).to eq([true, true])
    end

    it "reads `keyword_init:` as true only for a literal `true` under the Symbol key" do
      options = ["keyword_init: false", "keyword_init: flag", "'keyword_init' => true", "other: true",
                 "other: true, keyword_init: true"]
      flags = options.map { |option| struct("Struct.new(:a, #{option})").fetch("N::P").fetch(:keyword_init) }

      expect(flags).to eq([false, false, false, false, true])
    end

    it "leaves a leading class-name String out of the members" do
      expect(struct("Struct.new('Named', :a)")).to eq("N::P" => { members: %i[a], keyword_init: false })
    end

    it "records nothing for a member list that is empty or holds a splat, or for another call" do
      sources = ["Struct.new", "Struct.new('Named')", "Struct.new(*F)", "Struct.new(:a, *F)", "Data.define(:a)", "nil"]

      expect(sources.map { |source| struct(source) }).to eq([{}] * 6)
    end

    it "takes the block of the outermost call for a write's value, and not for a header's superclass" do
      expect(struct("Struct.new(:a) { def e; end }").keys).to eq(["N::P"])
      expect(struct("Struct.new(:a) { def e; end }", allow_outer_block: false)).to eq({})
      expect(struct("Class.new(Struct.new(:w)) { }", allow_outer_block: false)).to eq({})
    end
  end

  describe ".meta_member_names and .meta_members_open?" do
    # As `ScopeIndexer.record_meta_member_names` asks them, for the readers the class of a factory call has.
    def members(source)
      call = statement(source)
      [described_class.meta_member_names(call), described_class.meta_members_open?(call)]
    end

    it "names the literal Symbol arguments of a factory call, whose list is then closed" do
      expect(members("Data.define(:a, :b)")).to eq([%i[a b], false])
      expect(members("Data.define")).to eq([[], false])
    end

    it "leaves the options and a leading class name of a `Struct.new` out of the members" do
      expect(members("Struct.new('Named', :a)")).to eq([%i[a], false])
      expect(members("Struct.new(:a, keyword_init: true)")).to eq([%i[a], false])
    end

    it "opens the list for a splat, and still names the literal members beside it" do
      expect(members("Data.define(*F)")).to eq([[], true])
      expect(members("Data.define(:a, *F)")).to eq([%i[a], true])
      expect(members("Struct.new(*F, keyword_init: true)")).to eq([[], true])
    end
  end

  # #1097 — inside a `*_eval` / `*_exec` block, `Module.nesting` stays LEXICAL while `def` binds to the receiver.
  # These four came out of the group of that name in `scope_indexer_spec.rb`: each builds one table of this
  # module alone, through the builder that runs its collector.
  describe "eval-block dual context (#1097)" do
    it "threads `self::`-anchored nestings through an eval below `class <<`" do
      nestings = described_class.send(:build_def_nestings, parse(<<~RUBY))
        class X
          class Y; end
        end
        class S
          class << self
            X.class_eval do
              self::Y.class_eval do
                class self::D
                  def m; Inner; end
                end
              end
            end
          end
        end
      RUBY
      expect(nestings.values).to include(["X::Y::D", "S"])
    end

    it "records a `self::`-anchored Data/Struct layout through an eval below `class <<`" do
      data = described_class.send(:build_data_member_layouts, parse(<<~RUBY))
        class X; end
        class S
          class << self
            X.class_eval do
              class self::D < Data.define(:a)
              end
            end
          end
        end
      RUBY
      expect(data["X::D"]).to eq([:a])
    end

    it "files `class D` under `class <<` nowhere in the superclass and def-nesting tables" do
      # `#<Class:C>::D`'s ancestry and the defs' `Module.nesting` would publish a `C::D`
      # rung MRI never creates.
      program = parse(<<~RUBY)
        class C
          class << self
            class D < Base
              def m; end
            end
          end
        end
      RUBY
      supers, header_nestings = described_class.send(:build_superclass_tables, program)
      expect(supers).not_to have_key("C::D")
      expect(header_nestings).not_to have_key("C::D")
      nestings = described_class.send(:build_def_nestings, program)
      def_node = program.statements.body.first.body.body.first.body.body.first.body.body.first
      expect(nestings[def_node]).to eq(["C"])
    end

    it "files meta-new member layouts under `class <<` nowhere" do
      data = described_class.send(:build_data_member_layouts, parse(<<~RUBY))
        class C
          class << self
            K = Data.define(:x)
            class D < Data.define(:y); end
          end
        end
      RUBY
      struct = described_class.send(:build_struct_member_layouts, parse(<<~RUBY))
        class C
          class << self
            K = Struct.new(:x)
            class D < Struct.new(:y); end
          end
        end
      RUBY
      expect(data).not_to have_key("C::K")
      expect(data).not_to have_key("C::D")
      expect(struct).not_to have_key("C::K")
      expect(struct).not_to have_key("C::D")
    end
  end

  # #682 — the per-declaration table `Scope#ancestor_name_candidates` reads. It records the nesting the
  # HEADER is written in, so the two spellings of one qualified name are distinguishable afterwards, which
  # is exactly what the peel it replaces could not do.
  describe ".build_superclass_tables" do
    def unkeyed = Rigor::Scope::DiscoveryIndex::UNKEYED_HEADER_NESTING

    def header_nestings(source)
      described_class.send(:build_superclass_tables, parse(source)).last
    end

    # #728 — the chain the ancestor spelled `raw` resolves in. `raw` defaults to the UNKEYED entry, the
    # union over every ancestor-naming site, which is what a name no site wrote falls back to.
    def chain_for(source, class_name, raw = unkeyed)
      header_nestings(source).fetch(class_name)[raw]
    end

    it "records an empty header nesting for a compact declaration written at the top level" do
      expect(header_nestings("class Admin::Widget < Base; end"))
        .to eq({ "Admin::Widget" => { unkeyed => [], "Base" => [] } })
    end

    it "records the enclosing namespace for the nested spelling of the same class" do
      table = header_nestings("module Admin
  class Widget < Base; end
end
")
      expect(table).to eq({ "Admin::Widget" => { unkeyed => ["Admin"], "Base" => ["Admin"] } })
    end

    it "records one entry per declaration keyword for a doubly nested declaration" do
      source = "module A
  module B
    class C < Base; end
  end
end
"
      expect(chain_for(source, "A::B::C", "Base")).to eq(["A::B", "A"])
    end

    # #708 review — a site that writes NO ancestor name has no ancestor for its cref to govern, so it
    # contributes nothing. Recording it anyway is what let a rooted reopen inside another namespace put a
    # foreign chain ahead of the right one for a class it named no ancestor of.
    it "records nothing for a declaration that writes no ancestor name" do
      expect(header_nestings("module Admin\n  class Widget; end\nend\n")).to eq({})
    end

    it "records a site whose only ancestor name is a mixin call, keyed by the module it names" do
      source = "module Admin\n  class Widget\n    include Trackable\n  end\nend\n"
      expect(chain_for(source, "Admin::Widget", "Trackable")).to eq(["Admin"])
    end

    # #708 — a rooted header resets the class's NAME but not the cref its superclass name resolves in:
    # Ruby evaluates `Base` there at `Module.nesting == [Outer]`.
    it "keys a rooted declaration by its reset name and keeps the enclosing cref for its ancestors" do
      source = "module Outer
  class ::Rooted::Bar < Base; end
end
"
      expect(chain_for(source, "Rooted::Bar", "Base")).to eq(["Outer"])
      expect(header_nestings(source)).not_to have_key("Outer::Rooted::Bar")
    end

    it "still records the as-written superclass beside it" do
      supers = described_class.send(:build_superclass_tables, parse("class Admin::Widget < Base; end")).first
      expect(supers).to eq({ "Admin::Widget" => "Base" })
    end

    # Rails' own `ActiveRecord::Relation` is the corpus case: the library declares it inside
    # `module ActiveRecord` and a test file reopens it as the compact `class ActiveRecord::Relation`.
    # Last-writer-wins hands the library site the test file's EMPTY chain and its nine `include`s stop
    # resolving — the false-positive direction. The reopen names no ancestor, so it records no chain at all
    # and the declaring site's survives by construction rather than by a merge rule.
    it "keeps the declaring site's chain when a later site reopens the class and names no ancestor" do
      source = "module Admin\n  class Widget\n    include Trackable\n  end\nend\nclass Admin::Widget; end\n"
      expect(chain_for(source, "Admin::Widget", "Trackable")).to eq(["Admin"])
      expect(chain_for(source, "Admin::Widget")).to eq(["Admin"])
    end

    # #728 — the defect the per-name keying exists for, at the table. Both sites name an ancestor, so both
    # are recorded; a single chain per class then gives the top-level site's `Base` the reopen's `["Outer"]`
    # and resolves it as `Outer::Base`, which is a WRONG class rather than a wider list.
    it "gives each site's ancestor name that site's own chain when the sites disagree" do
      source = "class Foo < Base; end\nmodule Outer\n  class ::Foo\n    include Helper\n  end\nend\n"
      expect(chain_for(source, "Foo", "Base")).to eq([])
      expect(chain_for(source, "Foo", "Helper")).to eq(["Outer"])
    end

    # The unkeyed entry stays the pre-#728 per-class union, because it is what answers a name neither site
    # wrote — the mixin `walk_class_includes` attributes to a class from outside its declaration.
    it "unions every ancestor-naming site under the unkeyed entry" do
      source = "class Foo < Base; end\nmodule Outer\n  class ::Foo\n    include Helper\n  end\nend\n"
      expect(chain_for(source, "Foo")).to eq(["Outer"])
    end

    it "unions two sites that write the SAME ancestor name, most-qualified first" do
      source = "module A\n  module B\n    class C\n      include M\n    end\n  end\nend\n" \
               "module A\n  class B::C\n    include M\n  end\nend\n"
      expect(chain_for(source, "A::B::C", "M")).to eq(["A::B", "A"])
    end

    # A mixin call the walk cannot render an argument for still marks the site as ancestor-naming, so the
    # site's chain reaches the unkeyed entry that such a name is answered from.
    it "records a chain for a site whose only mixin argument is dynamic" do
      source = "module A\n  class Widget\n    include helper_module\n  end\nend\n"
      expect(chain_for(source, "A::Widget")).to eq(["A"])
    end
  end

  # Each runs one collector on a walk of its own, where `.declaration_walk_tables` runs the three on one.
  describe "the builders that run one collector alone" do
    it "keys an anonymous class with the path the superclass builder is given" do
      root = parse("Class.new(Parent) { }\n")

      expect(described_class.send(:build_superclass_tables, root, "app/x.rb").first.keys)
        .to eq(["#<Class:app/x.rb:1:0>"])
      expect(described_class.send(:build_superclass_tables, root).first.keys).to eq(["#<Class:1:0>"])
    end

    it "answers each member-layout table from its own builder" do
      root = parse("P = Data.define(:x)\nS = Struct.new(:a)\n")

      expect(described_class.send(:build_data_member_layouts, root)).to eq("P" => %i[x])
      expect(described_class.send(:build_struct_member_layouts, root))
        .to eq("S" => { members: %i[a], keyword_init: false })
    end
  end

  # Each walker below is the oracle `RIGOR_SHADOW_RULE_WALK` compares a collector with. The tables are explicit, so
  # that a change to an arm fails here and not only where the two are compared.
  describe "the walkers the collectors replaced" do
    describe "the def-nesting walker" do
      def nestings(source) = by_name(described_class.send(:legacy_def_nestings, parse(source)))

      it "records each def under the chain of the headers around it, and the empty chain at the top level" do
        source = "def top; end\nmodule M\n  class C\n    def a; end\n  end\n  class A::B\n    def b; end\n  end\n  " \
                 "class ::R\n    def r; end\n  end\nend\n"

        expect(nestings(source)).to eq(top: [], a: %w[M::C M], b: %w[M::A::B M], r: %w[R M])
      end

      it "keys the table by the def node, and freezes it" do
        root = parse("class C\n  def a; end\n  def a; end\nend\n")
        table = described_class.send(:legacy_def_nestings, root)

        expect([table.compare_by_identity?, table.frozen?]).to eq([true, true])
        expect(table.keys).to eq(root.statements.body.first.body.body)
      end

      it "goes no further in below a def" do
        expect(nestings("class C\n  def a\n    def inner; end\n    Class.new { def never; end }\n  end\nend\n"))
          .to eq(a: %w[C])
      end

      it "keeps the chain below `class <<`, where only a rooted header pushes an entry" do
        source = <<~RUBY
          class C
            class << self
              def s; end
              class D
                def d; end
                class Deeper
                  def deeper; end
                end
              end
              class self::E
                def e; end
              end
              class ::F
                def f; end
              end
            end
            class << (def in_operand; end; self)
            end
          end
        RUBY

        expect(nestings(source))
          .to eq(s: %w[C], d: %w[C], deeper: %w[C], e: %w[C], f: %w[F C], in_operand: %w[C])
      end

      it "anchors a `self::` header in a factory block on the class the write names, the chain staying lexical" do
        source = <<~RUBY
          module M
            K = Class.new(Base) do
              def k; end
              class self::S
                def s; end
              end
              class T
                def t; end
              end
            end
            J = Class.new((def in_arg; end; Base))
          end
        RUBY

        expect(nestings(source)).to eq(k: %w[M], s: %w[M::K::S M], t: %w[M::T M], in_arg: %w[M])
      end

      it "anchors a `self::` header in an eval block on the receiver, and walks the call's other parts as they are" do
        source = <<~RUBY
          class X; end
          module M
            X.class_eval do
              def x; end
              class self::D
                def d; end
              end
              class L
                def l; end
              end
            end
            X.instance_eval do
              class self::I
                def i; end
              end
            end
            foo(def in_receiver; end).class_eval(def in_argument; end) { def body; end }
            X.tap { class self::O; def o; end; end }
          end
        RUBY

        expect(nestings(source))
          .to eq(x: %w[M], d: %w[X::D M], l: %w[M::L M], i: %w[X::I M], in_receiver: %w[M], in_argument: %w[M],
                 body: %w[M], o: %w[M::O M])
      end

      it "pushes nothing for a `self::` header in the block of an eval whose receiver renders no path" do
        source = "module M\n  foo.class_eval do\n    class self::Unnamed\n      def unnamed; end\n    end\n  end\nend\n"

        expect(nestings(source)).to eq(unnamed: %w[M])
      end

      # A header that renders no name is a parse error. The walker loses the chain there and walks the body on:
      # the answer `DefNestingsCollector` keeps as `unrendered_header: :body_with_lost_nesting` (#1521 item 3).
      it "records no def under a chain it lost, until a `self::` header gives it one again" do
        source = <<~RUBY
          class foo
            def lost; end
            X.class_eval do
              class self::G
                def regrown; end
              end
            end
          end
        RUBY

        expect(nestings(source)).to eq(regrown: %w[X::G])
      end

      it "names an eval's receiver below `class <<`, and nothing for the `self` of a bare eval there" do
        source = <<~RUBY
          class X; end
          class S
            class << self
              X.class_eval do
                class self::D
                  def d; end
                end
              end
              class_eval do
                class self::U
                  def u; end
                end
              end
              self::Y.class_eval do
                class self::W
                  def w; end
                end
              end
            end
          end
        RUBY

        expect(nestings(source)).to eq(d: %w[X::D S], u: %w[S], w: %w[S])
      end

      # The walker threads no prefix: it splits the head of the chain. Below a compact header that names the
      # receiver by its last segment, where the walk's own prefix (`["Admin::W"]`) would find the top-level `W`:
      # the answer `DefNestingsCollector` keeps as `lexical_prefix: :nesting_head` (#1521 item 1).
      it "resolves an eval's receiver against the head of the chain, split into its segments" do
        source = "class Admin::W\n  W.class_eval do\n    class self::U\n      def u; end\n    end\n  end\nend\n"

        expect(nestings(source)).to eq(u: %w[Admin::W::U Admin::W])
      end
    end

    describe "the superclass walker" do
      def tables(source, path = "app/x.rb") = described_class.send(:legacy_superclass_tables, parse(source), path)

      # The nesting each class's header is written in, as its unkeyed entry holds it.
      def chains(source) = tables(source).last.transform_values { |bucket| bucket.fetch(any_name) }

      it "records each class header's superclass and the nesting outside it, and a module's mixins" do
        source = <<~RUBY
          class A < Base; end
          module M
            class B < ::Root; end
            class C::D < N::P; end
            module Mixed; include Mix; end
            class ::R < Up; end
            class E; end
          end
        RUBY

        expect(tables(source).first).to eq("A" => "Base", "M::B" => "::Root", "M::C::D" => "N::P", "R" => "Up")
        expect(chains(source)).to eq("A" => [], "M::B" => %w[M], "M::C::D" => %w[M], "M::Mixed" => %w[M], "R" => %w[M])
        expect(tables(source).last.fetch("M::Mixed")).to eq(any_name => %w[M], "Mix" => %w[M])
      end

      it "freezes both tables" do
        expect(tables("class A < Base; end").map(&:frozen?)).to eq([true, true])
      end

      it "files a header below `class <<` only when it is rooted, and its operand in the enclosing class" do
        source = <<~RUBY
          class C
            class << self
              class D < Base
                class Deeper < Base; end
              end
              class self::E < Base; end
              class ::F < Base; end
              class_eval { class self::U < Base; end }
            end
            class << (class InOperand < Base; end; self)
            end
          end
        RUBY

        expect(tables(source).first).to eq("F" => "Base", "C::InOperand" => "Base")
        expect(chains(source)).to eq("F" => %w[C], "C::InOperand" => %w[C])
      end

      it "anchors a `self::` header in a factory block on the class the write names" do
        source = <<~RUBY
          module M
            K = Class.new(Base) do
              class self::S < P; end
              class T < P; end
            end
            J = Class.new((class InArgument < P; end; Base))
            ::Q = Class.new { class self::U < P; end }
          end
        RUBY

        expect(tables(source).first).to eq("M::K::S" => "P", "M::T" => "P", "M::InArgument" => "P", "Q::U" => "P")
        expect(chains(source).values.uniq).to eq([%w[M]])
      end

      it "anchors a `self::` header in an eval block on the receiver, `instance_eval` included" do
        source = <<~RUBY
          class X; end
          module M
            X.class_eval do
              class self::D < P; end
              class L < P; end
            end
            X.instance_eval { class self::I < P; end }
            foo((class InReceiver < P; end)).class_eval { class self::W < P; end }
          end
        RUBY

        expect(tables(source).first).to eq("X::D" => "P", "M::L" => "P", "X::I" => "P", "M::InReceiver" => "P")
        expect(chains(source).values.uniq).to eq([%w[M]])
      end

      # The path is dropped once the walker is in a class, factory or eval body: the answer `SuperclassesCollector`
      # keeps as `anonymous_class_path: :outside_class_bodies` (#1521 item 11).
      it "records the superclass of a `Class.new` with a block, with the path only outside every body" do
        source = <<~RUBY
          Class.new(Top) { }
          K = Class.new(Named) { Class.new(InFactory) { } }
          X.class_eval { Class.new(InEval) { } }
          class C
            Class.new(InClass) { }
            class << self
              Class.new(InSingleton) { }
            end
            Class.new(NoBlock)
            Module.new(NotAClass) { }
          end
        RUBY

        expect(tables(source).first)
          .to eq("#<Class:app/x.rb:1:0>" => "Top", "#<Class:2:23>" => "InFactory", "#<Class:3:15>" => "InEval",
                 "#<Class:5:2>" => "InClass", "#<Class:7:4>" => "InSingleton")
      end
    end

    describe "the member-layout walkers" do
      def layouts(source)
        root = parse(source)
        [described_class.send(:legacy_data_member_layouts, root),
         described_class.send(:legacy_struct_member_layouts, root)]
      end

      def struct(*members, keyword_init: false) = { members: members, keyword_init: keyword_init }

      it "records a class header whose superclass is a factory call, without a block of its own" do
        source = <<~RUBY
          class P < Data.define(:x, :y); end
          module M
            class Q < Data.define(:q); end
            class S < Struct.new(:a, keyword_init: true); end
            class A::B < Struct.new(:b); end
            class ::R < Data.define(:r); end
            class Blocked < Data.define(:b) { }; end
            class W < Class.new(Data.define(:w)); end
          end
        RUBY

        expect(layouts(source))
          .to eq([{ "P" => %i[x y], "M::Q" => %i[q], "R" => %i[r], "M::W" => %i[w] },
                  { "M::S" => struct(:a, keyword_init: true), "M::A::B" => struct(:b) }])
      end

      it "freezes both tables" do
        expect(layouts("P = Data.define(:x)\nS = Struct.new(:a)\n").map(&:frozen?)).to eq([true, true])
      end

      it "records a constant written with a factory call, and walks the call's block as that class" do
        source = <<~RUBY
          L = Data.define(:from, :to)
          module M
            N = Struct.new(:n)
            ::T = Struct.new(:t)
            U ||= Data.define(:u)
            A::V ||= Struct.new(:v)
            K = Data.define(:k) do
              Inner = Struct.new(:i)
              self::Own = Data.define(:own)
              self::Mine = Struct.new(:m)
            end
            Z = Class.new(Struct.new(:z)) { }
            J = Class.new((InArgument = Data.define(:ia); SArgument = Struct.new(:sa); Base)) { }
          end
        RUBY

        expect(layouts(source))
          .to eq([{ "L" => %i[from to], "M::U" => %i[u], "M::K" => %i[k], "M::K::Own" => %i[own],
                    "M::InArgument" => %i[ia] },
                  { "M::N" => struct(:n), "T" => struct(:t), "M::A::V" => struct(:v), "M::Inner" => struct(:i),
                    "M::K::Mine" => struct(:m), "M::Z" => struct(:z), "M::SArgument" => struct(:sa) }])
      end

      it "records below `class <<` only what is rooted, and the operand in the enclosing class" do
        source = <<~RUBY
          class C
            class << self
              Lost = Data.define(:l)
              ::Top = Struct.new(:t)
              class Hidden < Data.define(:h)
                Deeper = Struct.new(:dd)
              end
              class self::Own < Struct.new(:o); end
              class ::Rooted < Data.define(:r); end
            end
            class << (InOperand = Data.define(:io); self)
            end
          end
        RUBY

        expect(layouts(source)).to eq([{ "Rooted" => %i[r], "C::InOperand" => %i[io] }, { "Top" => struct(:t) }])
      end

      it "anchors a `self::` write or header in an eval block on the receiver, a bare one staying lexical" do
        source = <<~RUBY
          class X; end
          module M
            X.class_eval do
              self::E = Struct.new(:e)
              Lexical = Data.define(:lex)
              class self::D < Data.define(:d); end
            end
            X.instance_eval { self::I = Data.define(:i) }
            foo(InReceiver = Data.define(:ir)).class_eval { }
            foo.class_eval { class self::Unnamed < Data.define(:u); end }
          end
        RUBY

        expect(layouts(source))
          .to eq([{ "M::Lexical" => %i[lex], "X::D" => %i[d], "X::I" => %i[i], "M::InReceiver" => %i[ir] },
                  { "X::E" => struct(:e) }])
      end

      it "names an eval's receiver below `class <<`, and nothing for the `self` of a bare eval there" do
        source = <<~RUBY
          class X; end
          class S
            class << self
              X.class_eval do
                self::E = Struct.new(:e)
                class self::D < Data.define(:d); end
              end
              class_eval { self::N = Data.define(:n) }
              self::Y.class_eval { self::V = Data.define(:v); self::T = Struct.new(:t) }
            end
          end
        RUBY

        expect(layouts(source)).to eq([{ "X::D" => %i[d] }, { "X::E" => struct(:e) }])
      end
    end
  end

  # What another file of `lib/` calls: `scope_indexer.rb` the entry and the two readers of a member list, the two
  # collectors the four recorders, `CvarHierarchy` the ancestor name. A ninth name here is a new way into the module.
  it "exposes the entry and the seven functions another file calls, and no constant" do
    expect(described_class.singleton_methods(false).sort)
      .to eq(%i[declaration_walk_tables meta_member_names meta_members_open? record_anonymous_meta_superclass
                record_data_member_layout record_declaration_ancestry record_struct_member_layout
                recorded_ancestor_name])
    expect(described_class.constants(false)).to eq([])
  end

  it "leaves none of its 44 functions on ScopeIndexer, public or private" do
    functions = described_class.private_instance_methods(false)

    expect(functions.size).to eq(44)
    expect(functions.select { |name| indexer.respond_to?(name, true) }).to eq([])
  end

  # The #3318 cut-off counts the functions a moved cluster calls back in what stays, and allows four. This one
  # calls three: the insert of the header-nesting table, which block rebinds `self`, and the factory call an
  # expression unwinds to.
  it "calls three functions of the indexer, at four sites" do
    path = File.join(DeclarationFactSources::REPO_ROOT, "lib/rigor/inference/scope_indexer/shared_walk_tables.rb")
    calls = DeclarationFactSources.each_node(Prism.parse_file(path).value).filter_map do |node|
      node.name if node.is_a?(Prism::CallNode) && DeclarationFactSources.constant_name(node.receiver) == "ScopeIndexer"
    end

    expect(calls).to eq(%i[add_header_nesting rebound_block_self resolve_meta_factory_call
                           resolve_meta_factory_call])
  end

  # The module reads `EMPTY_NESTING`, `EMPTY_PREFIX`, `RECEIVER_EVAL_CALLS` and `MIXIN_CALL_NAMES` through
  # `ScopeIndexer`'s own names and calls three of its functions, all of which `scope_indexer.rb` defines: the file
  # requires what else it names, and until the indexer has loaded only a call that reaches none of the seven answers.
  def alone_probe
    <<~RUBY
      require "rigor/inference/scope_indexer/shared_walk_tables"
      indexer = Rigor::Inference::ScopeIndexer
      tables = indexer::SharedWalkTables
      walk = Rigor::Inference::DeclarationWalk
      named = [defined?(indexer::SuperclassesCollector), defined?(indexer::MemberLayoutsCollector),
               defined?(indexer::DefNestingsCollector), defined?(walk::Rules), defined?(walk::Shadow),
               walk.respond_to?(:run), defined?(Rigor::Inference::AnonymousMetaClass),
               defined?(Rigor::Source::ConstantPath), Prism::ProgramNode.method_defined?(:rigor_each_child)]
      statement = ->(source) { Prism.parse(source).value.statements.body.first }
      failure = lambda do |&call|
        call.call
      rescue NameError => e
        [e.class.name, e.name]
      end
      header = ->(source) { [statement.call(source), [], %w[C], { superclasses: {}, header_nestings: {} }] }
      entry = failure.call { tables.declaration_walk_tables(Prism.parse("x = 1").value) }
      bodiless = failure.call { tables.record_declaration_ancestry(*header.call("class C < B; end")) }
      with_body = failure.call { tables.record_declaration_ancestry(*header.call("class C; include M; end")) }
      layout = failure.call { tables.record_data_member_layout({}, %w[P], statement.call("Data.define(:x)")) }
      anonymous = {}
      tables.record_anonymous_meta_superclass(statement.call("Class.new(P) { }"), anonymous, nil)
      factory = statement.call("Data.define(:a, *F)")
      answers = [anonymous, tables.meta_member_names(factory), tables.meta_members_open?(factory),
                 tables.recorded_ancestor_name(statement.call("::B"))]
      print [indexer.respond_to?(:index), named, entry, bodiless, with_body, layout, answers].inspect
    RUBY
  end

  it "loads without the indexer, with what it names, and answers only what needs nothing of the indexer" do
    lib = File.join(DeclarationFactSources::REPO_ROOT, "lib")
    out, err, status = RubyRun.capture("-I", lib, "-e", alone_probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, ["constant", "constant", "constant", "constant", "constant", true, "constant", ' \
                      '"constant", true], ["NameError", :EMPTY_NESTING], ' \
                      '["NoMethodError", :add_header_nesting], ["NameError", :EMPTY_PREFIX], ' \
                      '["NoMethodError", :resolve_meta_factory_call], ' \
                      '[{"#<Class:1:0>" => "P"}, [:a], true, "::B"]]')
  end
end
