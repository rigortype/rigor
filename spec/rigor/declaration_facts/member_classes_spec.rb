# frozen_string_literal: true

require "spec_helper"

# #1507 — every `Scope::DiscoveryIndex` member sits in exactly one of the five fact classes that
# `DiscoveryIndex::MEMBER_CLASSES` names, with a reason. A member added to the index fails here until someone
# decides what kind of fact it holds, so the gate that covers its class cannot silently miss it.
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
end
