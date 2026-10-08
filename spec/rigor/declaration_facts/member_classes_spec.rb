# frozen_string_literal: true

require "spec_helper"

# #1507 — ADR-119 WD4 (proposed). Every `Scope::DiscoveryIndex` member sits in exactly one of the five classes
# `DiscoveryIndex::MEMBER_CLASSES` names, and each member's value has its class's shape on a fixture project's index
# (`spec/support/declaration_fact_fixture.rb`, checked by `spec/support/declaration_member_shapes.rb`). A member
# added to the index fails until someone classifies it.
#
# What the shape checks catch, measured by refiling every member into every other class: all misfilings but three,
# which the last example pins. Two of the three are Data and Struct layouts, which are ordered lists of member names
# (a set's shape) that readers use as one value. The third is `patched_line_readers`, a set of names read off the
# analysed file. Single-valued is checked against a slot kind recorded per member, so a member filed there without
# one fails because no kind is recorded, not because of its shape. Syntactic is checked as "the file's parse alone
# gives the same value": a table that depends on the project differs, because the fixture's second file contributes
# to every project table.
#
# Threat model: the checks catch an accidental misfiling, not a deliberate one. The `possible_*` / `contested_*`
# sibling class is checked against injected values, since no producer fills one yet. Not built yet: the ADR-53 shadow
# oracle for the syntactic members.
RSpec.describe "Rigor::Scope::DiscoveryIndex::MEMBER_CLASSES" do
  let(:members) { Rigor::Scope::DiscoveryIndex.members }
  let(:classes) { Rigor::Scope::DiscoveryIndex::MEMBER_CLASSES }

  # Every way `classes` can fail to partition `members`, as readable lines.
  def partition_problems(members, classes)
    owners = Hash.new { |hash, member| hash[member] = [] }
    classes.each { |klass, entries| entries.each_key { |member| owners[member] << klass } }
    problems = members.reject { |member| owners.key?(member) }.map { |member| "#{member}: unclassified" }
    owners.each do |member, klasses|
      problems << "#{member}: classified as #{klasses.join(' and ')}" if klasses.size > 1
      problems << "#{member}: not a DiscoveryIndex member" unless members.include?(member)
    end
    problems
  end

  def refiled(classes, member, klass)
    DeclarationMemberShapes.refiled(classes, member, klass)
  end

  it "names exactly the five fact classes and the sibling class" do
    expect(classes.keys).to eq(%i[set_valued single_valued typed syntactic run_state sibling])
  end

  it "puts every member in exactly one class, and names no other" do
    expect(partition_problems(members, classes)).to eq([])
  end

  it "gives every member a one-line reason" do
    reasons = classes.values.flat_map(&:to_a)

    expect(reasons.reject { |_, reason| reason.is_a?(String) && !reason.strip.empty? && !reason.include?("\n") })
      .to eq([])
  end

  it "gives every member its class's shape on the fixture project's index" do
    expect(DeclarationMemberShapes.problems(classes, DeclarationFactFixture.built)).to eq([])
  end

  it "leaves unfilled only the members another command or a whole run fills" do
    discovery, = DeclarationFactFixture.built.fetch(:discovery)
    unfilled = members.select do |member|
      DeclarationMemberShapes.empty?(discovery.public_send(member)) && !classes.fetch(:sibling).key?(member)
    end

    expect(unfilled).to eq(DeclarationMemberShapes::UNFILLED.keys)
  end

  # ADR-119 WD1. The fixture fills one sibling only, so the fixture check above is close to vacuous for them: these
  # examples inject values against the real member tables.
  describe "the sibling class" do
    let(:index) { DeclarationFactFixture.built.fetch(:discovery).first }
    let(:siblings) { Rigor::Scope::DiscoveryIndex::SIBLINGS }

    def problem(sibling, value)
      DeclarationMemberShapes.sibling_problem(sibling, value, index)
    end

    it "names exactly the sibling of each paired member, and each member is in its own class" do
      expect(classes.fetch(:sibling).keys).to eq(siblings.values)
      expect(siblings.keys.flat_map { |member| classes.except(:sibling).select { |_, e| e.key?(member) }.keys })
        .to all(satisfy { |klass| %i[set_valued single_valued].include?(klass) })
    end

    # The fixture's only possible contributions are the `def`s inside its two `refine` blocks, which the visibility
    # walk records on the refining module (ADR-119 C1d-b contests them, since a block's `def` is possible).
    it "fills on the fixture only the contested visibilities of the refine blocks' defs" do
      filled = siblings.values.reject { |sibling| index.public_send(sibling).empty? }

      expect(filled).to eq(%i[contested_discovered_method_visibilities])
      expect(index.contested_discovered_method_visibilities).to eq(Set[["Numbers", :half], ["Strings", :whisper]])
    end

    it "accepts a possible sibling that is a part of its member, and a contested one whose paths resolve" do
      klass, methods = index.discovered_methods.first
      def_class, defs = index.discovered_def_nodes.first

      expect(problem(:possible_discovered_methods, { klass => methods.slice(*methods.keys.first(1)) })).to be_nil
      expect(problem(:contested_discovered_def_nodes, Set[[def_class, defs.keys.first]])).to be_nil
    end

    it "rejects a possible entry the member lacks, and a contested path that does not resolve" do
      expect(problem(:possible_discovered_methods,
                     { "Nowhere" => { x: :instance } })).to eq("an entry is not in the member")
      expect(problem(:contested_discovered_def_nodes, Set[["Nowhere", :x]]))
        .to eq("a key path does not resolve in the member")
      expect(problem(:contested_discovered_def_nodes, [])).to eq("not a Set")
    end
  end

  describe "the partition check itself" do
    let(:sample) { { set_valued: { a: "one" }, typed: { b: "two" } } }

    it "accepts a partition" do
      expect(partition_problems(%i[a b], sample)).to eq([])
    end

    it "reports a member nobody classified" do
      expect(partition_problems(%i[a b dummy_member], sample)).to eq(["dummy_member: unclassified"])
    end

    it "reports a member classified twice" do
      doubled = sample.merge(typed: { a: "also typed", b: "two" })

      expect(partition_problems(%i[a b], doubled)).to eq(["a: classified as set_valued and typed"])
    end

    it "reports a classified name that is not a member" do
      expect(partition_problems(%i[a], sample)).to eq(["b: not a DiscoveryIndex member"])
    end
  end

  describe "the shape check itself" do
    def shape_problems_for(member, klass)
      DeclarationMemberShapes.problems(refiled(classes, member, klass), DeclarationFactFixture.built)
    end

    it "fails a single-valued member filed as typed, and a typed one filed as set-valued" do
      expect(shape_problems_for(:discovered_def_nodes, :typed))
        .to eq(["discovered_def_nodes (typed): a leaf is not a Rigor::Type"])
      expect(shape_problems_for(:class_ivars, :set_valued))
        .to eq(["class_ivars (set_valued): holds something other than names, rows or kind flags"])
    end

    it "fails a single-valued site or visibility table filed as set-valued" do
      expect(shape_problems_for(:discovered_def_sources, :set_valued))
        .to eq(["discovered_def_sources (set_valued): holds something other than names, rows or kind flags"])
      expect(shape_problems_for(:discovered_superclasses, :set_valued))
        .to eq(["discovered_superclasses (set_valued): an entry is a bare value, not a collection"])
    end

    it "fails a project table filed as syntactic, and a table filed as run state" do
      expect(shape_problems_for(:discovered_class_sources, :syntactic).first)
        .to start_with("discovered_class_sources (syntactic): the file's parse alone gives {}")
      expect(shape_problems_for(:discovered_def_sources, :run_state))
        .to eq(["discovered_def_sources (run_state): a table or a fact, not an opaque token"])
    end

    it "pins the misfilings the checks accept" do
      expect(DeclarationMemberShapes.accepted_misfilings(classes, DeclarationFactFixture.built))
        .to eq(data_member_layouts: [:set_valued], struct_member_layouts: [:set_valued],
               patched_line_readers: [:set_valued])
    end
  end
end
