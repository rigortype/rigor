# frozen_string_literal: true

require "spec_helper"

# #1507 — ADR-119 WD4 (proposed). Every `Scope::DiscoveryIndex` member sits in exactly one of the five classes
# `DiscoveryIndex::MEMBER_CLASSES` names, and each member's value has its class's shape on an index built from a
# fixture project (`spec/support/declaration_fact_fixture.rb`, checked by `spec/support/declaration_member_shapes.rb`).
# A member added to the index fails until someone classifies it, and a member filed under the wrong class fails the
# shape check.
#
# Not built yet: the ADR's `possible_*` / `contested_*` sibling checks, because no member admits `possible` facts; and
# for the syntactic members, the ADR-53 shadow oracle. A second, independent parse standing in for it is checked
# instead.
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

  # `classes` with `member` taken out of its class and filed under `klass`.
  def refiled(classes, member, klass)
    classes.to_h { |name, entries| [name, entries.except(member)] }
           .tap { |copy| copy[klass] = copy[klass].merge(member => "refiled") }
  end

  it "names exactly the five fact classes" do
    expect(classes.keys).to eq(%i[set_valued single_valued typed syntactic run_state])
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
    unfilled = members.select { |member| DeclarationMemberShapes.empty?(discovery.public_send(member)) }

    expect(unfilled).to eq(DeclarationMemberShapes::UNFILLED.keys)
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

    it "fails a single-valued member filed as typed" do
      expect(shape_problems_for(:discovered_def_nodes, :typed))
        .to eq(["discovered_def_nodes (typed): a leaf is not a Rigor::Type"])
    end

    it "fails a typed member filed as set-valued" do
      expect(shape_problems_for(:class_ivars, :set_valued))
        .to eq(["class_ivars (set_valued): holds something other than names, rows or flags"])
    end

    it "fails a set-valued member filed as single-valued" do
      expect(shape_problems_for(:discovered_includes, :single_valued))
        .to eq(["discovered_includes (single_valued): no slot kind is recorded for it"])
    end

    it "fails a member that rides a seed filed as syntactic or run state" do
      expect(shape_problems_for(:discovered_def_sources, :run_state))
        .to eq(["discovered_def_sources (run_state): it is persisted in a seed bundle"])
    end
  end
end
