# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"

# #1507 — ADR-119 WD5's declaration-fact witness (proposed; `spec/support/declaration_witness.rb`) on the fixtures in
# `spec/integration/fixtures/declaration_witness/`, which it executes. The controls agree with Ruby. Each bug fixture
# has two examples: a `pending` one asserting agreement, which RSpec fails the moment the bug is fixed, and a pin of
# today's exact violations, which fails if the fixture starts failing for another reason (a broken fixture raises
# instead of recording). Both flip together when the bug is fixed.
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

  describe "filed bugs" do
    it "#1518: declines a class self::X opened on a receiver no constant names" do
      pending "https://github.com/rigortype/rigor/issues/1518 — the index build raises 'anonymous class has no name'"

      expect(violations("issue_1518", relations: %i[classes])).to eq([])
    end

    # Flip this when #1518 is fixed: the tables build, and the pending example above passes.
    it "#1518 today: Ruby loads the fixture and Rigor's index build raises" do
      expect(DeclarationWitness.record(fixture("issue_1518"))["modules"].keys).to include("Registry", "Foo::Bar")
      expect { DeclarationWitness.rigor_tables(fixture("issue_1518")) }
        .to raise_error(ArgumentError, "anonymous class has no name")
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

    # Flip this when #1520 is fixed. The def nesting half is #1305's family, like the anonymous-cref fixture below.
    it "#1520 today" do
      expect(violations("issue_1520")).to eq(
        ['def_nestings: Rigor records ["E", "C"] for the def at line 20; Ruby\'s nesting holds #<Class:C>, ' \
         "which owns constants the recorded chain cannot reach",
         "class_cvars: Rigor types E @@ad as C::D::Bar; Ruby holds a Bar"]
      )
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

    it "#1305: resolves a constant a class << self body owns from a class opened below it" do
      pending "https://github.com/rigortype/rigor/issues/1305 — the recorded nesting drops #<Class:C>, which owns X"

      expect(violations("anonymous_cref_constant")).to eq([])
    end

    # Flip this when #1305 is fixed for defs nested below a class << self body.
    it "#1305 today" do
      expect(violations("anonymous_cref_constant")).to eq(
        ['def_nestings: Rigor records ["E", "C"] for the def at line 15; Ruby\'s nesting holds #<Class:C>, ' \
         "which owns constants the recorded chain cannot reach"]
      )
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

    it "reports a nesting Ruby disagrees with, and ignores an anonymous entry that owns no constants" do
      changed = changed_runtime { |r| r["nestings"]["51"] = [["Outer::Inner", [["Inner", false], ["Outer", false]]]] }

      singleton_body = ["#<Class:Widget>", [["#<Class:Widget>", false], ["Widget", false]]]

      expect(runtime.dig("nestings", "35")).to include(singleton_body)
      expect(DeclarationWitness::Relations.def_nestings_violations(changed, *tables))
        .to eq(['def_nestings: Rigor records ["Outer::Inner", "Outer"] for the def at line 51; ' \
                'Ruby\'s is ["Inner", "Outer"]'])
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
