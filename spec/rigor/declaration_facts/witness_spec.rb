# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"

# #1507 — ADR-119 WD5's declaration-fact witness (proposed; `spec/support/declaration_witness.rb`) on the fixtures in
# `spec/integration/fixtures/declaration_witness/`, which it executes. The controls agree with Ruby. Each bug fixture
# has two examples: a `pending` one asserting agreement, which RSpec fails the moment the bug is fixed, and a pin of
# today's exact violations, which fails if the fixture starts failing for another reason (a broken fixture raises
# instead of recording). Both flip together when the bug is fixed.
#
# Threat model: the witness finds only the bugs its fixtures exercise, and one run witnesses one execution; a
# deliberately misleading fixture defeats it. The limits of each relation are in the support file's header.
RSpec.describe "Declaration-fact witness" do
  def fixture(name)
    File.expand_path("../../integration/fixtures/declaration_witness/#{name}.rb", __dir__)
  end

  def violations(name, **)
    DeclarationWitness.violations(fixture(name), **)
  end

  # Writes `source` to a temporary fixture and yields its path.
  def with_fixture(source)
    Dir.mktmpdir("rigor-witness-") do |dir|
      path = File.join(dir, "probe.rb")
      File.write(path, source)
      yield path
    end
  end

  describe "controls" do
    it "agrees with Ruby on the control fixture, across every relation" do
      expect(violations("control")).to eq([])
    end

    it "fills the tables every relation reads, class variables and a prepend included" do
      tables, = DeclarationWitness.rigor_tables(fixture("control"))

      expect(DeclarationWitness::RELATIONS.select { |relation| tables_for(relation, tables).empty? }).to eq([])
      expect(tables.discovered_prepends).to eq("Widget" => ["Framed"])
    end

    it "agrees on a module_function module, reading the orderless self-extend as possible" do
      path = fixture("control_module_function")
      tables, = DeclarationWitness.rigor_tables(path)
      facts = DeclarationWitness::Relations.method_facts(tables)

      expect(DeclarationWitness::Relations.self_extend_possible(DeclarationWitness.record(path), tables, facts))
        .to eq([%w[Helpers singleton early], %w[Helpers singleton fmt]])
      expect(violations("control_module_function", relations: DeclarationWitness::RELATIONS - %i[visibilities]))
        .to eq([])
    end

    # Flip this when #1569 is fixed: the instance copy is recorded private, and the list is empty.
    it "pins the module_function visibility the tables get wrong today" do
      expect(violations("control_module_function", relations: %i[visibilities]))
        .to eq(["visibilities: Rigor records Helpers#fmt as public; Ruby makes it private"])
    end

    def tables_for(relation, tables)
      member = {
        classes: :discovered_classes, methods: :discovered_methods, visibilities: :discovered_method_visibilities,
        def_nodes: :discovered_def_nodes, singleton_def_nodes: :discovered_singleton_def_nodes,
        superclasses: :discovered_superclasses, includes: :discovered_includes, extends: :discovered_extends,
        def_nestings: :discovered_def_nestings, class_cvars: :class_cvars
      }.fetch(relation)
      tables.public_send(member)
    end
  end

  # ADR-119 WD3 — the possible definers, witnessed in the world where each runs and in the one where none does. Each
  # world alone would let a wrong classification through (a possible def read as certain agrees with the first, a
  # certain one read as possible with the second), so both must agree.
  #
  # Every relation is checked on both fixtures. The taken world holds the def-node relations strict (the contested
  # slot must name the def Ruby answers with), the skipped world relaxes a contested slot to any def of that name
  # the fixture writes, since the possible def did not run. One row is filtered from the visibilities relation:
  # the table does not record `private def hidden`'s wrap-around form as private. That is a gap in the value the
  # visibility walk records (`build_discovered_method_visibilities`), not in its certainty: `hidden` is a certain
  # def, and ADR-119 C1d-b contests slots without changing a recorded value.
  describe "possible definers" do
    def without_hidden(violations)
      violations.reject { |line| line.include?("Probe#hidden") }
    end

    it "agrees with Ruby in the world where every possible definer runs" do
      expect(without_hidden(violations("possible_defs_taken", relax_contested: false))).to eq([])
    end

    it "agrees with Ruby in the world where no possible definer runs" do
      expect(without_hidden(violations("possible_defs_skipped"))).to eq([])
    end

    it "records the wrap-around `private def hidden` as public today (a value gap C1d-b leaves)" do
      expect(violations("possible_defs_skipped", relations: %i[visibilities]))
        .to contain_exactly(a_string_including("Probe#hidden"))
    end

    it "reads the conditional definers as possible and the meta-new block and private def as certain" do
      tables, = DeclarationWitness.rigor_tables(fixture("possible_defs_skipped"))

      expect(tables.possible_discovered_methods).to eq(
        "Probe" => { gated: :instance, gated_reader: :instance, gated_alias: :instance, in_block: :instance,
                     rescued_main: :instance, gated_singleton: :singleton },
        "Reopened" => { reopened: :instance }
      )
      expect(tables.contested_discovered_def_nodes)
        .to include(["Probe", :both], ["Probe", :gated], ["Probe", :in_block])
      expect(tables.contested_discovered_singleton_def_nodes).to eq(Set[["Probe", :gated_singleton]])
      expect(tables.discovered_methods.fetch("Probe::Made")).to eq(made: :instance)
      expect(tables.discovered_methods.fetch("Probe")).to include(hidden: :instance)
    end
  end

  # ADR-119 C1d-b — the visibility relation skips a contested slot. A bare `module_function` under a condition
  # applies to `fmt2` in Ruby (an instance copy made private) while the walk records it public; the slot rests on
  # an uncertain toggle, so it is contested and the relation does not compare it. The singleton copy is recorded
  # `possible` through the module's self-extend edge, which the methods relation accepts.
  describe "a conditional bare module_function" do
    it "agrees with Ruby across every relation, the contested visibility skipped" do
      expect(violations("conditional_module_function")).to eq([])
    end

    it "contests the visibility the walk records public where Ruby makes it private" do
      tables, = DeclarationWitness.rigor_tables(fixture("conditional_module_function"))

      expect(tables.discovered_method_visibilities).to eq("Helpers2" => { fmt2: :public })
      expect(tables.contested_discovered_method_visibilities).to eq(Set[["Helpers2", :fmt2]])
      expect(tables.possible_discovered_methods).to eq("Helpers2" => { fmt2: :singleton })
    end
  end

  describe "filed bugs" do
    it "#1518: declines a class self::X opened on a receiver no constant names" do
      expect(violations("issue_1518", relations: %i[classes])).to eq([])
    end

    it "#1518: still opens Foo::Bar for a constant receiver" do
      tables, = DeclarationWitness.rigor_tables(fixture("issue_1518"))

      expect(tables.discovered_classes.keys).to include("Foo::Bar")
      expect(tables.discovered_classes.keys).not_to include("")
    end

    it "#1519: keys a compact header whose leading segment names the enclosing class once" do
      pending "https://github.com/rigortype/rigor/issues/1519 — class C::Pathed inside class C is keyed C::C::Pathed"

      expect(violations("issue_1519")).to eq([])
    end

    # Flip this when #1519 is fixed.
    it "#1519 today" do
      expect(violations("issue_1519")).to eq(
        ["methods: Rigor records C::C::Pathed instance h, which Ruby does not define",
         "methods: Ruby defines C::Pathed instance h, which Rigor does not record",
         "instance_def_nodes: Rigor resolves C::C::Pathed#h to the def at line 11; Ruby has no such def in the fixture",
         "superclasses: Rigor records C::C::Pathed < Base; Ruby's superclass is undefined",
         'def_nestings: Rigor records ["C::C::Pathed", "C"] for the def at line 11; Ruby\'s is ["C::Pathed", "C"]']
      )
    end

    it "#1520: types a constant under a class << self header through the nesting Ruby searches" do
      pending "https://github.com/rigortype/rigor/issues/1520 — @@ad is typed C::D::Bar where Ruby holds a ::Bar"

      expect(violations("issue_1520")).to eq([])
    end

    # Flip this when #1520 is fixed. The def's recorded nesting ["E", "C"] drops #<Class:C>, but the one constant the
    # def names, Bar, resolves to the top-level Bar either way, so the nesting is no violation.
    it "#1520 today" do
      expect(violations("issue_1520")).to eq(["class_cvars: Rigor types E @@ad as C::D::Bar; Ruby holds a Bar"])
    end

    it "#1550: copies the def in effect at a named module_function call" do
      pending "https://github.com/rigortype/rigor/issues/1550 — Fmt.label resolves to the later def"

      expect(violations("issue_1550")).to eq([])
    end

    # Flip this when #1550 is fixed. The `methods` line is a second gap: the named form records no singleton side in
    # `discovered_methods`.
    it "#1550 today" do
      expect(violations("issue_1550")).to eq(
        ["methods: Ruby defines Fmt singleton label, which Rigor does not record",
         "singleton_def_nodes: Rigor resolves Fmt.label to the def at line 10; Ruby's is the def at line 8"]
      )
    end

    it "#1573: keeps a repeated extend at its first position" do
      pending "https://github.com/rigortype/rigor/issues/1573 — fixed by the lane-2 record_extend_targets producer " \
              "change (ADR-119 WD7); today C.foo resolves to E1's def (line 8); fixed, E2's (line 12)"

      expect(violations("issue_1573")).to eq([])
    end

    # Flip this when #1573 is fixed: the extend table keeps E2 before E1, and the pending example above passes.
    it "#1573 today" do
      expect(violations("issue_1573")).to eq(
        ["singleton_def_nodes: Rigor resolves C.foo to the def at line 8; Ruby's is the def at line 12"]
      )
    end

    # #1305's family: a def whose innermost or enclosing cref is a singleton class, and a constant the def names
    # resolves elsewhere once the recorded chain of names drops it: through the singleton class or its ancestors, or
    # through the ancestors of the class that becomes innermost without it.
    {
      "anonymous_cref_constant" => ["a class opened below class << self", '["E", "C"]', 15, "X"],
      "anonymous_cref_late_constant" => ["the same, with the constant written after the class", '["E", "C"]', 11, "X"],
      "singleton_body_late_constant" => ["a def in class << self, the constant written after it", '["C"]', 10, "X"],
      "singleton_private_constant" => ["a def in class << self, the constant private", '["C"]', 13, "X"],
      "singleton_extend_constant" => ["a def in class << self of a class that extends M", '["C"]', 16, "Y"],
      "singleton_extend_private_constant" => ["the same, M's constant private", '["C"]', 17, "Y"],
      "singleton_superclass_constant" => ["a def in class << self, the constant in the superclass's", '["C"]', 16, "Z"],
      "singleton_include_top_constant" => ["a def in class << self of a class that includes M", '["C"]', 16, "X"],
      "singleton_superclass_top_constant" => ["a def in class << self, the superclass shadowing X", '["C"]', 15, "X"]
    }.each do |fixture_name, (shape, recorded, line, constant)|
      it "#1305: resolves constants through the singleton cref — #{shape}" do
        pending "https://github.com/rigortype/rigor/issues/1305 — the recorded nesting drops #<Class:C>"

        expect(violations(fixture_name)).to eq([])
      end

      # Flip this when #1305 is fixed.
      it "#1305 today — #{shape}" do
        expect(violations(fixture_name)).to eq(
          ["def_nestings: Rigor records #{recorded} for the def at line #{line}; dropping #<Class:C> from Ruby's " \
           "nesting makes #{constant} resolve elsewhere"]
        )
      end
    end
  end

  describe "the witness itself" do
    let(:path) { fixture("control") }
    let(:runtime) { DeclarationWitness.record(path) }
    let(:tables) { DeclarationWitness.rigor_tables(path) }

    # A deep copy of the control's runtime record with one fact changed, so each relation is shown to say "no".
    def changed_runtime
      copy = JSON.parse(JSON.generate(runtime))
      yield copy
      copy
    end

    it "reports a class Ruby defines and Rigor does not" do
      changed = changed_runtime { |r| r["modules"]["Ghost"] = r["modules"]["Loud"] }

      expect(DeclarationWitness::Relations.classes_violations(changed, *tables))
        .to eq(["classes: Ruby defines Ghost, which Rigor does not declare"])
    end

    it "reports a method Rigor records and Ruby does not define" do
      changed = changed_runtime { |r| r["modules"]["Widget"]["singleton_locations"].delete("build") }

      expect(DeclarationWitness::Relations.methods_violations(changed, *tables))
        .to eq(["methods: Rigor records Widget singleton build, which Ruby does not define"])
    end

    it "reports a visibility Ruby disagrees with" do
      changed = changed_runtime do |r|
        r["modules"]["Widget"]["private"].delete("secret")
        r["modules"]["Widget"]["public"] << "secret"
      end

      expect(DeclarationWitness::Relations.visibilities_violations(changed, *tables))
        .to eq(["visibilities: Rigor records Widget#secret as private; Ruby makes it public"])
    end

    it "reports a def Ruby places on another line" do
      changed = changed_runtime { |r| r["modules"]["Widget"]["instance_locations"]["render"] = 99 }

      expect(DeclarationWitness::Relations.def_nodes_violations(changed, *tables))
        .to eq(["instance_def_nodes: Rigor resolves Widget#render to the def at line 38; Ruby's is the def at line 99"])
    end

    it "reports a superclass and a mixin Ruby does not show" do
      changed = changed_runtime do |r|
        r["modules"]["Widget"]["superclass"] = "Object"
        r["modules"]["Widget"]["instance_mixins"] = ["Framed"]
      end

      expect(DeclarationWitness::Relations.superclasses_violations(changed, *tables))
        .to eq(["superclasses: Rigor records Widget < Base; Ruby's superclass is Object"])
      expect(DeclarationWitness::Relations.includes_violations(changed, *tables))
        .to eq(["includes: Rigor records Widget → Greeting, which Ruby does not show"])
    end

    it "reports a class variable whose runtime value the recorded type does not admit" do
      changed = changed_runtime { |r| r["modules"]["Widget"]["class_variables"]["@@label"] = %w[Integer Object] }

      expect(DeclarationWitness::Relations.class_cvars_violations(changed, *tables))
        .to eq(['class_cvars: Rigor types Widget @@label as "renamed"; Ruby holds a Integer'])
    end

    it "reports a nesting Ruby disagrees with, and ignores an anonymous entry no constant resolves through" do
      changed = changed_runtime { |r| r["nestings"]["51"] = [["Outer::Inner", [["Inner", []], ["Outer", []]]]] }

      singleton_body = ["#<Class:Widget>", [["#<Class:Widget>", []], ["Widget", []]]]

      expect(runtime.dig("nestings", "35")).to include(singleton_body)
      expect(DeclarationWitness::Relations.def_nestings_violations(changed, *tables))
        .to eq(['def_nestings: Rigor records ["Outer::Inner", "Outer"] for the def at line 51; ' \
                'Ruby\'s is ["Inner", "Outer"]'])
    end

    # The anonymous-entry rule compares, per constant the def names, the module Ruby resolves it in with and without
    # the anonymous entries, so a chain that reaches the same module is no violation.
    it "counts an anonymous entry only for a named constant the recorded chain resolves elsewhere" do
      agreeing = {
        "include M beside extend M" => "module M\n  X = :m\nend\n\nclass C\n  include M\n  extend M\n",
        "a lexical X in the named class" => "module M\n  X = :m\nend\n\nclass C\n  X = :c\n  extend M\n",
        "extend Forwardable, VERSION unnamed" => "require \"forwardable\"\n\nclass C\n  extend Forwardable\n"
      }
      agreeing.each do |shape, prelude|
        body = shape.include?("Forwardable") ? ":f" : "X"
        with_fixture("#{prelude}\n  class << self\n    def foo = #{body}\n  end\nend\n") do |probe|
          expect(DeclarationWitness.violations(probe, relations: %i[def_nestings])).to eq([]), shape
        end
      end
      with_fixture("#{agreeing.values.last}\n  class << self\n    def foo = VERSION\n  end\nend\n") do |probe|
        expect(DeclarationWitness.violations(probe, relations: %i[def_nestings]))
          .to eq(['def_nestings: Rigor records ["C"] for the def at line 7; dropping #<Class:C> from Ruby\'s ' \
                  "nesting makes VERSION resolve elsewhere"])
      end
    end

    it "keeps its const_added hook private and elides per-run addresses from a violation" do
      with_fixture("class Probe; end\nraise \"public hook\" if Probe.respond_to?(:const_added)\n") do |probe|
        expect { DeclarationWitness.record(probe) }.not_to raise_error
      end
      expect(DeclarationWitness::Relations.nesting_violation(["D"], [["#<Class:0x000123abc>::D", []]], 3, []))
        .to eq('def_nestings: Rigor records ["D"] for the def at line 3; Ruby\'s is ["#<Class:0x...>::D"]')
    end

    it "tells two statements on one line apart by their self" do
      with_fixture("class OneLine; def x = 1; end\n") do |one_line|
        expect(DeclarationWitness.record(one_line).dig("nestings", "1").map(&:first)).to eq(["(Object)", "OneLine"])
        expect(DeclarationWitness.violations(one_line)).to eq([])
      end
    end

    it "treats a fixture that exits early or runs too long as broken" do
      with_fixture("exit!(0)\n") do |early|
        expect { DeclarationWitness.record(early) }.to raise_error(RuntimeError, /printed no record/)
      end
      stub_const("DeclarationWitness::TIME_LIMIT", 1)
      with_fixture("sleep 30\n") do |slow|
        expect { DeclarationWitness.record(slow) }.to raise_error(RuntimeError, /ran past 1s/)
      end
    end

    it "admits a value whose class a typed entry names, and no other" do
      bar = Rigor::Type::Combinator.nominal_of("C::D::Bar")

      expect(DeclarationWitness::Relations.admits?(bar, %w[C::D::Bar Object])).to be(true)
      expect(DeclarationWitness::Relations.admits?(bar, %w[Bar Object])).to be(false)
    end
  end
end
