# frozen_string_literal: true

require "spec_helper"
require "yaml"

# #1507 — ADR-119 WD1's admission census (proposed). For each `Scope::DiscoveryIndex` member, the files outside the
# table owners that read the whole table or copy it: `DiscoveryReadScan` (`spec/support/declaration_fact_sources.rb`)
# parses `lib/` and `plugins/*/lib/` with Prism and counts a member's name wherever it appears as a method or a Symbol,
# its def-index slot name (`:def_sources`, `:refinements`) as a key in any argument position of a keyed read or write,
# or held in a constant or variable (`SLOT = :def_nodes`), and, apart from them, the whole-index reads and copies
# (`with(**x)`, `new(*x)`, `to_h`, `deconstruct`, iterating `DiscoveryIndex.members`, a computed `send`, a
# `discovered_`-prefixed interpolated name). The census is compared with `admission_census.yml`, so a new raw read or
# copy path fails until it is recorded; the ADR admits a member to `possible` facts only once its entry here is empty.
# `RIGOR_REGENERATE_GATES=1` rewrites the file.
#
# Threat model: the census catches a raw read or copy added in the codebase's normal styles, not a deliberate evasion.
# It does not see a slot named by a String (`fetch("def_nodes")`) or a computed Symbol not prefixed `discovered_`
# (`:"#{pre}_#{slot}"`); a slot Symbol reached some other way than a constant or variable assignment (a Hash value,
# a default argument); a discovery index held in a variable not named like one (`d = scope.discovery; d.with(**x)`,
# `d.deconstruct`); `members` on a bare `EMPTY` (only `DiscoveryIndex::EMPTY` counts, since a bare `EMPTY` names
# the index only inside its own class); `Marshal` round trips; iterating a def-index Hash
# (`index.each { |slot, table| … }`); or a read through a local holding a table, which counts once, where the local
# is assigned. `:methods` and `:classes` count only on a receiver named like an index (`index`, `def_index`, `seed`,
# `tables`, `bundle`, `summary`), because they are ordinary words, and not when held in a constant or variable.
RSpec.describe "Discovery-table admission census" do
  let(:snapshot) { File.join(__dir__, "admission_census.yml") }
  let(:header) do
    <<~YAML
      # Discovery-table admission census (#1507, ADR-119 WD1): per Scope::DiscoveryIndex member, the files outside
      # the table owners (scope.rb, scope/discovery_index.rb, scope_indexer.rb with its collectors under
      # scope_indexer/, and runner/project_pre_passes.rb) that read the whole table ("reads") or copy it ("copies"),
      # and the files that read or copy every member at once ("whole_index"). admission_census_spec.rb computes it
      # with Prism and compares it with this file; `RIGOR_REGENERATE_GATES=1` rewrites it.

    YAML
  end
  let(:members) { Rigor::Scope::DiscoveryIndex.members }

  define_method(:census_problems) do |found, recorded|
    lines = found.fetch("members").flat_map do |member, kinds|
      kinds.flat_map do |kind, files|
        listed = recorded.dig("members", member, kind) || []
        (files - listed).map { |file| "#{member} #{kind}: #{file} is not recorded" } +
          (listed - files).map { |file| "#{member} #{kind}: #{file} is recorded but no longer found" }
      end
    end
    whole = recorded.fetch("whole_index", [])
    lines + (found.fetch("whole_index") - whole).map { |file| "whole index: #{file} is not recorded" } +
      (whole - found.fetch("whole_index")).map { |file| "whole index: #{file} is recorded but gone" }
  end

  it "records exactly the reads and copies the tree has" do
    found = DiscoveryReadScan.census(DeclarationFactSources.parsed_under, members)
    DeclarationFactSources.write_yaml(snapshot, header, found) if DeclarationFactSources.regenerate?

    problems = census_problems(found, YAML.load_file(snapshot))
    expect(problems).to eq([]), "#{problems.join("\n")}\nRead the table through a Scope reader, or record the path " \
                                "in admission_census.yml (#{DeclarationFactSources::REGENERATE_ENV}=1 rewrites it)."
  end

  it "records one entry per member" do
    expect(YAML.load_file(snapshot).fetch("members").keys).to eq(members.map(&:to_s))
  end

  describe "the census itself" do
    def census_of(source)
      found = DiscoveryReadScan.census({ "lib/rigor/probe.rb" => Prism.parse(source).value },
                                       Rigor::Scope::DiscoveryIndex.members)
      found.fetch("members").filter_map do |member, kinds|
        [member, kinds.reject { |_, files| files.empty? }.keys] if kinds.values.any?(&:any?)
      end.to_h.merge("whole" => !found.fetch("whole_index").empty?)
    end

    it "counts slot keys on any receiver and in any argument position" do
      source = <<~RUBY
        index[:extends]
        def_index.fetch(:def_nodes)
        summary[:refinements]
        @seed_bundles.dig(path, :superclasses)
        def_index.values_at(:def_sources, :header_nestings)
        tables[:constant_writers] = writers
      RUBY

      expect(census_of(source)).to eq(
        "discovered_def_nodes" => ["reads"], "discovered_def_sources" => ["reads"],
        "discovered_superclasses" => ["reads"], "discovered_refinements" => ["reads"],
        "discovered_header_nestings" => ["reads"], "discovered_extends" => ["reads"],
        "constant_writers" => ["copies"], "whole" => false
      )
    end

    it "counts a full member name wherever it appears" do
      source = <<~RUBY
        scope.discovery.public_send(:discovered_prepends)
        seed.values_at(:discovered_def_nodes)
        tables.slice(:discovered_def_sources)
        scope.method(:discovered_includes)
        base.discovery.with(discovered_classes: classes)
        FIELDS = { def_nodes: :discovered_def_nestings }.freeze
      RUBY

      expect(census_of(source)).to eq(
        "discovered_classes" => ["copies"], "discovered_def_nodes" => ["reads"],
        "discovered_def_nestings" => ["copies"], "discovered_def_sources" => ["reads"],
        "discovered_includes" => ["reads"], "discovered_prepends" => ["reads"], "whole" => false
      )
    end

    it "records whole-index reads and copies apart" do
      [
        "scope.discovery.with(**seed)", "scope.discovery.to_h", "scope.discovery.deconstruct",
        "Rigor::Scope::DiscoveryIndex.new(*values)",
        "Rigor::Scope::DiscoveryIndex.members.each { |m| tables[m] = index.public_send(m) }",
        "index.public_send(\"discovered_\#{slot}\")", "key = :\"discovered_\#{slot}\""
      ].each { |source| expect(census_of(source)).to eq("whole" => true), source }
    end

    it "counts a slot name held in a constant or variable" do
      source = <<~RUBY
        SLOT = :def_nodes
        slot = :refinements
        WORD = :methods
      RUBY

      expect(census_of(source))
        .to eq("discovered_def_nodes" => ["copies"], "discovered_refinements" => ["copies"], "whole" => false)
    end

    it "does not count a keyed reader, an ordinary word on another receiver, or a longer name" do
      source = <<~RUBY
        scope.discovered_method_visibility(klass, name)
        rule[:methods]
        ScopeIndexer.discovered_classes_for_paths(paths)
        some_call(:includes)
      RUBY

      expect(census_of(source)).to eq("whole" => false)
    end

    it "reports a new raw read and a vanished one" do
      found = { "members" => { "discovered_extends" => { "reads" => ["lib/new.rb"], "copies" => [] } },
                "whole_index" => [] }
      recorded = { "members" => { "discovered_extends" => { "reads" => ["lib/old.rb"], "copies" => [] } } }

      expect(census_problems(found, recorded))
        .to eq(["discovered_extends reads: lib/new.rb is not recorded",
                "discovered_extends reads: lib/old.rb is recorded but no longer found"])
    end
  end
end
