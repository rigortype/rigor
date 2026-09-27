# frozen_string_literal: true

require "spec_helper"
require "yaml"

# #1507 — ADR-119 WD1's admission census (proposed). For each `Scope::DiscoveryIndex` member, the files outside the
# table owners that read the whole table or copy it: `DiscoveryReadScan` parses `lib/` and `plugins/*/lib/` with
# Prism, so a short key (`index[:def_sources]`, `def_index.fetch(:def_nodes)`), a `public_send(:discovered_x)`, a
# keyword or hash key naming a member, and a Symbol list of members count, and a `with(**seed)` or `new(**seed)` on a
# discovery index, a computed `send` on one and a `:"discovered_#{slot}"` are recorded apart as whole-index copies.
# The census is compared with `admission_census.yml`, so a new raw read or copy path fails until it is recorded; the
# ADR admits a member to `possible` facts only once its entry here is empty.
#
# What is not built: a read through a local holding a table (`t = scope.discovered_extends; t[x]` counts once, at the
# call), a short slot name on a receiver not named like an index (`:methods` and `:classes` are ordinary words), and
# a `with` on a discovery index held in a variable named otherwise.
RSpec.describe "Discovery-table admission census" do
  let(:snapshot) { File.join(__dir__, "admission_census.yml") }
  let(:header) do
    <<~YAML
      # Discovery-table admission census (#1507, ADR-119 WD1): per Scope::DiscoveryIndex member, the files outside
      # scope.rb, scope/discovery_index.rb, scope_indexer.rb and runner/project_pre_passes.rb that read the whole
      # table ("reads") or copy it ("copies"), and the files that copy every member at once through a splat or a
      # computed name ("whole_index_copies"). admission_census_spec.rb computes it with Prism and compares it with
      # this file; `RIGOR_REGENERATE_GATES=1` rewrites it.

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
    whole = recorded.fetch("whole_index_copies", [])
    lines + (found.fetch("whole_index_copies") - whole).map { |file| "whole-index copy: #{file} is not recorded" } +
      (whole - found.fetch("whole_index_copies")).map { |file| "whole-index copy: #{file} is recorded but gone" }
  end

  it "records exactly the reads and copies the tree has" do
    found = DiscoveryReadScan.census(DeclarationFactSources.parsed_under, members)
    DeclarationFactSources.write_yaml(snapshot, header, found) if DeclarationFactSources.regenerate?

    problems = census_problems(found, YAML.load_file(snapshot))
    expect(problems).to eq([]),
                        "#{problems.join("\n")}\n#{DeclarationFactSources.regenerate_hint('admission_census.yml')}"
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
      end.to_h.merge("whole" => found.fetch("whole_index_copies"))
    end

    it "counts short keys, sends, splats and computed names" do
      source = <<~RUBY
        index[:extends]
        def_index.fetch(:def_nodes)
        scope.discovery.public_send(:discovered_prepends)
        scope.discovery.with(**seed)
      RUBY

      expect(census_of(source)).to eq(
        "discovered_def_nodes" => ["reads"], "discovered_extends" => ["reads"], "discovered_prepends" => ["reads"],
        "whole" => ["lib/rigor/probe.rb"]
      )
    end

    it "counts keyword copies, member lists and interpolated names" do
      source = <<~RUBY
        base.discovery.with(discovered_classes: classes)
        FIELDS = { def_nodes: :discovered_def_nodes }.freeze
        tables[:constant_writers] = writers
        key = :"discovered_\#{slot}"
      RUBY

      expect(census_of(source)).to eq(
        "discovered_classes" => ["copies"], "discovered_def_nodes" => ["copies"], "constant_writers" => ["copies"],
        "whole" => ["lib/rigor/probe.rb"]
      )
    end

    it "does not count a keyed reader, an ordinary word on another receiver, or a longer name" do
      source = <<~RUBY
        scope.discovered_method_visibility(klass, name)
        rule[:methods]
        ScopeIndexer.discovered_classes_for_paths(paths)
      RUBY

      expect(census_of(source)).to eq("whole" => [])
    end

    it "reports a new raw read and a vanished one" do
      found = { "members" => { "discovered_extends" => { "reads" => ["lib/new.rb"], "copies" => [] } },
                "whole_index_copies" => [] }
      recorded = { "members" => { "discovered_extends" => { "reads" => ["lib/old.rb"], "copies" => [] } } }

      expect(census_problems(found, recorded))
        .to eq(["discovered_extends reads: lib/new.rb is not recorded",
                "discovered_extends reads: lib/old.rb is recorded but no longer found"])
    end
  end
end
