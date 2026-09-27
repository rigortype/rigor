# frozen_string_literal: true

require "spec_helper"
require "json"

# #1507 — the declaration-fact witness (`spec/support/declaration_witness.rb`) on the fixtures under
# `spec/integration/fixtures/declaration_witness/`. The control fixture exercises every relation and must agree with
# Ruby. Each issue fixture reproduces a filed bug and stays `pending` until that bug is fixed: RSpec fails the run
# the moment one starts passing, so the fix lands together with the removal of its `pending`.
RSpec.describe "Declaration-fact witness" do
  def fixture(name)
    File.expand_path("../../integration/fixtures/declaration_witness/#{name}.rb", __dir__)
  end

  it "agrees with Ruby on the control fixture, across every relation" do
    expect(DeclarationWitness.violations(fixture("control"))).to eq([])
  end

  describe "filed bugs" do
    it "#1518: declines a class self::X opened on a receiver no constant names" do
      pending "https://github.com/rigortype/rigor/issues/1518 — the index build raises 'anonymous class has no name'"

      expect(DeclarationWitness.violations(fixture("issue_1518"), relations: %i[classes])).to eq([])
    end

    it "#1519: keys a compact header whose leading segment names the enclosing class once" do
      pending "https://github.com/rigortype/rigor/issues/1519 — class C::Pathed inside class C is keyed C::C::Pathed"

      expect(DeclarationWitness.violations(fixture("issue_1519"))).to eq([])
    end

    it "#1520: types a constant under a class << self header through the nesting Ruby searches" do
      pending "https://github.com/rigortype/rigor/issues/1520 — @@ad is typed C::D::Bar where Ruby holds a ::Bar"

      expect(DeclarationWitness.violations(fixture("issue_1520"), relations: %i[class_cvars])).to eq([])
    end

    # Only the def identity is read here. The same fixture also shows that `discovered_methods` records no
    # singleton side for the named form, which is a separate gap.
    it "#1550: copies the def in effect at a named module_function call" do
      pending "https://github.com/rigortype/rigor/issues/1550 — Fmt.label resolves to the later def"

      expect(DeclarationWitness.violations(fixture("issue_1550"), relations: %i[singleton_def_nodes])).to eq([])
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
        .to eq(["instance_def_nodes: Rigor resolves Widget#render to the def at line 29; Ruby's is the def at line 99"])
    end

    it "reports a superclass and a mixin Ruby does not show" do
      changed = changed_runtime do |r|
        r["modules"]["Widget"]["superclass"] = "Object"
        r["modules"]["Widget"]["instance_mixins"] = []
      end

      expect(DeclarationWitness::Relations.superclasses_violations(changed, *tables))
        .to eq(["superclasses: Rigor records Widget < Base; Ruby's superclass is Object"])
      expect(DeclarationWitness::Relations.includes_violations(changed, *tables))
        .to eq(["includes: Rigor records Widget → Greeting, which Ruby does not show"])
    end

    it "reports a nesting Ruby disagrees with, and ignores the anonymous singleton-class entry" do
      changed = changed_runtime { |r| r["nestings"]["42"] = %w[Inner Outer] }

      expect(runtime.dig("nestings", "26")).to eq(["#<Class:Widget>", "Widget"])
      expect(DeclarationWitness::Relations.def_nestings_violations(changed, *tables))
        .to eq(["def_nestings: Rigor records [\"Outer::Inner\", \"Outer\"] for the def at line 42; " \
                "Ruby's is [\"Inner\", \"Outer\"]"])
    end

    it "reads a self-extend edge Ruby does not show as possible, and one it shows as certain" do
      extends = Struct.new(:discovered_extends).new({ "M" => ["M"] })
      facts = [%w[M instance a]]
      unconfirmed = { "modules" => { "M" => { "singleton_mixins" => [] } } }
      confirmed = { "modules" => { "M" => { "singleton_mixins" => ["M"] } } }

      expect(DeclarationWitness::Relations.self_extend_possible(unconfirmed, extends, facts)).to eq([%w[M singleton a]])
      expect(DeclarationWitness::Relations.self_extend_possible(confirmed, extends, facts)).to eq([])
    end

    it "admits a value whose class a typed entry names, and no other" do
      bar = Rigor::Type::Combinator.nominal_of("C::D::Bar")

      expect(DeclarationWitness::Relations.admits?(bar, %w[C::D::Bar Object])).to be(true)
      expect(DeclarationWitness::Relations.admits?(bar, %w[Bar Object])).to be(false)
    end
  end
end
