# frozen_string_literal: true

require "spec_helper"

# ADR-119 WD1 — the extends fold copies an extended module's instance defs onto the extender's singleton, and the
# copy follows the siblings: a slot the copy wrote is contested when its edge is listed in `unpositioned_mixins` (or
# the source slot is contested), the singleton name is possible when the edge is listed (or the source name is
# possible), and a certain copy makes the name certain. Driven through `accumulate_project_index` and
# `finalize_def_index`, the pair the project-wide fold runs in.
RSpec.describe "ScopeIndexer extends fold siblings (ADR-119 WD1)" do
  let(:indexer) { Rigor::Inference::ScopeIndexer }
  let(:helpers) { "module Helpers\n  def fmt = 1\nend\n" }
  let(:other) { "module Other\n  def fmt = 2\nend\n" }
  let(:seeded) { {} }

  def finalize(source)
    acc = indexer.new_def_index_accumulator
    indexer.accumulate_project_index(acc, "lib/probe.rb", Prism.parse(source).value)
    seeded.each { |name, table| acc[:siblings] = acc[:siblings].merge(name => table) }
    indexer.finalize_def_index(acc)
  end

  def contested(finalized) = finalized.fetch(:siblings).fetch(:contested_discovered_singleton_def_nodes).to_a

  def possible(finalized) = finalized.fetch(:siblings).fetch(:possible_discovered_methods)

  it "contests the slot and makes the name possible for a conditional extend" do
    finalized = finalize("#{helpers}class Widget\n  extend Helpers if ENV[\"X\"]\nend\n")

    expect(contested(finalized)).to eq([["Widget", :fmt]])
    expect(possible(finalized)).to eq("Widget" => { fmt: :singleton })
    expect(finalized.fetch(:methods).dig("Widget", :fmt)).to eq(:singleton)
  end

  it "records neither for a plain extend" do
    finalized = finalize("#{helpers}class Widget\n  extend Helpers\nend\n")

    expect(contested(finalized)).to eq([])
    expect(possible(finalized)).to eq({})
    expect(finalized.fetch(:methods).dig("Widget", :fmt)).to eq(:singleton)
  end

  it "records neither when the class defines the name on its own singleton" do
    finalized = finalize("#{helpers}class Widget\n  def self.fmt = 0\n  extend Helpers if ENV[\"X\"]\nend\n")

    expect(contested(finalized)).to eq([])
    expect(possible(finalized)).to eq({})
  end

  it "contests but does not make possible a name a certain module supplies after a possible one" do
    source = "#{helpers}#{other}class Widget\n  extend Other\n  extend Helpers if ENV[\"X\"]\nend\n"
    finalized = finalize(source)

    expect(contested(finalized)).to eq([["Widget", :fmt]])
    expect(possible(finalized)).to eq({})
  end

  it "records neither when the certain module comes first" do
    source = "#{helpers}#{other}class Widget\n  extend Helpers if ENV[\"X\"]\n  extend Other\nend\n"
    finalized = finalize(source)

    expect(contested(finalized)).to eq([])
    expect(possible(finalized)).to eq({})
  end

  it "contests only, for a contested source reached through a certain edge" do
    seeded[:contested_discovered_def_nodes] = Set[["Helpers", :fmt]]
    finalized = finalize("#{helpers}class Widget\n  extend Helpers\nend\n")

    expect(contested(finalized)).to eq([["Widget", :fmt]])
    expect(possible(finalized)).to eq({})
  end

  it "makes the name possible, and does not contest, for a possible source reached through a certain edge" do
    seeded[:possible_discovered_methods] = { "Helpers" => { fmt: :instance } }
    finalized = finalize("#{helpers}class Widget\n  extend Helpers\nend\n")

    expect(contested(finalized)).to eq([])
    expect(possible(finalized)).to eq("Widget" => { fmt: :singleton })
  end

  it "never writes :both from the singleton fold" do
    seeded[:possible_discovered_methods] = { "Helpers" => { fmt: :both } }
    finalized = finalize("#{helpers}class Widget\n  extend Helpers if ENV[\"X\"]\nend\n")

    expect(possible(finalized).fetch("Widget")).to eq(fmt: :singleton)
  end

  it "treats a name list the walk could not read in full as listing every edge" do
    finalized = finalize("#{helpers}class Widget\n  extend Helpers, mixin_for_env\nend\n")

    expect(contested(finalized)).to eq([["Widget", :fmt]])
    expect(possible(finalized)).to eq("Widget" => { fmt: :singleton })
  end

  it "strips :singleton from a :both possible entry a certain copy now supplies" do
    seeded[:possible_discovered_methods] = { "Widget" => { fmt: :both } }
    finalized = finalize("#{helpers}class Widget\n  extend Helpers\nend\n")

    expect(possible(finalized)).to eq("Widget" => { fmt: :instance })
  end

  it "does not write the tables it was handed" do
    table = { "Helpers" => { fmt: :instance } }.freeze
    seeded[:possible_discovered_methods] = table
    finalize("#{helpers}class Widget\n  extend Helpers\nend\n")

    expect(table).to eq("Helpers" => { fmt: :instance })
  end
end
