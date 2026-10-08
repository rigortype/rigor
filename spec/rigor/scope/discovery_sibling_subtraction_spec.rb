# frozen_string_literal: true

require "spec_helper"

# ADR-119 WD1 — `subtract_def_methods` drops a name that has a project `def` from `methods`. The `possible` copy of
# `methods` (`possible_discovered_methods`) loses only the instance half of such a name in `subtract_sibling_methods!`
# (a singleton-only entry stays), so the sibling stays a subset of its member. Driven through `finalize_def_index`, the
# pass that runs both.
RSpec.describe "ScopeIndexer sibling subtraction (ADR-119 WD1)" do
  let(:indexer) { Rigor::Inference::ScopeIndexer }
  let(:def_node) { Prism.parse("def run = 1\n").value.statements.body.first }

  let(:acc) do
    indexer.new_def_index_accumulator.tap do |a|
      a[:def_nodes] = { "Gadget" => { run: def_node, stop: def_node } }
      a[:methods] = { "Gadget" => { run: :instance, ghost: :instance, stop: :both } }
      a[:siblings] = a[:siblings].merge(
        possible_discovered_methods: { "Gadget" => { run: :instance, ghost: :instance, stop: :both } }
      )
    end
  end

  let(:finalized) { indexer.finalize_def_index(acc) }

  it "drops an instance-side possible entry whose name has an instance def, and keeps the rest" do
    expect(finalized.fetch(:siblings).fetch(:possible_discovered_methods)).to eq(
      "Gadget" => { ghost: :instance, stop: :singleton }
    )
  end

  it "keeps the singleton half of a :both possible entry whose name has an instance def" do
    expect(finalized.fetch(:siblings).fetch(:possible_discovered_methods).dig("Gadget", :stop)).to eq(:singleton)
  end

  it "keeps a singleton-only possible entry whose name also has an instance def" do
    acc[:methods] = { "Gadget" => { run: :both } }
    acc[:siblings] = acc[:siblings].merge(possible_discovered_methods: { "Gadget" => { run: :singleton } })

    expect(finalized.fetch(:siblings).fetch(:possible_discovered_methods)).to eq("Gadget" => { run: :singleton })
    expect(finalized.fetch(:methods)).to eq("Gadget" => { run: :singleton })
  end

  it "keeps a conditional singleton extend possible beside an instance def of the name" do
    source = "module M\n  def foo = 1\nend\nclass C\n  def foo = 2\n  extend M if ENV[\"X\"]\nend\n"
    acc = indexer.new_def_index_accumulator
    indexer.accumulate_project_index(acc, "lib/probe.rb", Prism.parse(source).value)
    result = indexer.finalize_def_index(acc)

    expect(result.fetch(:methods).dig("C", :foo)).to eq(:singleton)
    expect(result.fetch(:siblings).fetch(:possible_discovered_methods)).to eq("C" => { foo: :singleton })
    expect(result.fetch(:siblings).fetch(:contested_discovered_singleton_def_nodes)).to eq(Set[["C", :foo]])
  end

  it "keeps every possible entry inside its member" do
    possible = finalized.fetch(:siblings).fetch(:possible_discovered_methods)
    member = finalized.fetch(:methods)

    possible.each do |class_name, table|
      table.each { |method_name, kind| expect(member.dig(class_name, method_name)).to eq(kind) }
    end
  end

  it "leaves the other siblings alone" do
    acc[:siblings] = acc[:siblings].merge(
      possible_discovered_deferred_ranges: { "lib/gadget.rb" => [[0, 1, :run, :instance, "Gadget"]] }
    )

    expect(finalized.fetch(:siblings).fetch(:possible_discovered_deferred_ranges)).to eq(
      "lib/gadget.rb" => [[0, 1, :run, :instance, "Gadget"]]
    )
  end
end
