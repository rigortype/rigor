# frozen_string_literal: true

require "spec_helper"
require "yaml"

# #1507 — ADR-119 WD1's admission census (proposed). For each `Scope::DiscoveryIndex` member, the files outside the
# table owners that read the whole table or copy it: `DiscoveryReadScan` (`spec/support/declaration_fact_sources.rb`)
# parses `lib/` and `plugins/*/lib/` with Prism and counts a member's name wherever it appears as a method or a Symbol,
# its def-index slot name (`:def_sources`, `:refinements`) as a key in any argument position of a keyed read or write,
# or held in a constant or variable of any kind (`SLOT = :def_nodes`, `slot ||= %i[def_nodes]`,
# `@@slot = :def_nodes.freeze`, a multi-write), and, apart from them, the whole-index reads and copies (`with(**x)`,
# `new(*x)`, `to_h`, `deconstruct`, iterating `DiscoveryIndex.members`, a computed `send`, a `discovered_`-prefixed
# interpolated name). The census is compared with `admission_census.yml`, so a new raw read or copy path fails until
# it is recorded. The ADR admits a single-valued member to `possible` facts only once every read recorded for it
# consults its `contested_*` sibling, goes through a `Scope` reader, or is justified (WD1(ii)): a member with a
# `contested_*` sibling carries, per recorded file, a `justified:` classification (`existence`, `identity`,
# `cache_key`, `paired_copy` or `consults_contested`, the reads WD2 allows beside #1600's paired copies), which
# this spec checks is complete and names no unrecorded file. `RIGOR_REGENERATE_GATES=1` rewrites the file and
# keeps the `justified:` entries of files still recorded.
#
# Threat model: the census catches a raw read or copy added in the codebase's normal styles, not a deliberate evasion.
# It does not see a slot named by a String (`fetch("def_nodes")`) or a computed Symbol not prefixed `discovered_`
# (`:"#{pre}_#{slot}"`); a slot Symbol reached some other way than a constant or variable assignment (a Hash value,
# a default argument, a one-slot list passed straight to a call); a discovery index held in a variable not named like
# one (`d = scope.discovery; d.with(**x)`, `d.deconstruct`); `members` on a bare `EMPTY` (only
# `DiscoveryIndex::EMPTY` counts, since a bare `EMPTY` names the index only inside its own class); `Marshal` round
# trips; iterating a def-index Hash (`index.each { |slot, table| … }`); or a read through a local holding a table,
# which counts once, where the local is assigned. `:methods` and `:classes` count only on a receiver named like an
# index (`index`, `def_index`, `seed`, `tables`, `bundle`, `summary`), because they are ordinary words, and not when
# held in a constant or variable.
RSpec.describe "Discovery-table admission census" do
  let(:snapshot) { File.join(__dir__, "admission_census.yml") }
  let(:header) do
    <<~YAML
      # Discovery-table admission census (#1507, ADR-119 WD1): per Scope::DiscoveryIndex member, the files outside
      # the table owners (scope.rb, scope/discovery_index.rb, scope_indexer.rb with its collectors under
      # scope_indexer/, and runner/project_pre_passes.rb) that read the whole table ("reads") or copy it ("copies"),
      # and the files that read or copy every member at once ("whole_index"). A member with a `contested_*` sibling
      # also carries "justified": per recorded file, why that read or copy may stay once the member admits possible
      # facts (WD1(ii)) -- existence, identity, cache_key, paired_copy or consults_contested. admission_census_spec.rb
      # computes the rest with Prism and compares it with this file; `RIGOR_REGENERATE_GATES=1` rewrites it and keeps
      # the "justified" entries of files still recorded.

    YAML
  end
  let(:members) { Rigor::Scope::DiscoveryIndex.members }
  let(:kinds_allowed) { %w[existence identity cache_key paired_copy consults_contested] }
  let(:contested_members) do
    Rigor::Scope::DiscoveryIndex::SIBLINGS.filter_map do |member, sibling|
      member.to_s if sibling.start_with?("contested_")
    end
  end

  # `found` with each recorded member's `justified:` carried over, files no longer read or copied dropped.
  define_method(:with_justified) do |found, recorded|
    members = found.fetch("members").to_h do |member, kinds|
      justified = recorded&.dig("members", member, "justified")
      next [member, kinds] if justified.nil?

      files = kinds.values.flatten
      [member, kinds.merge("justified" => justified.slice(*files))]
    end
    found.merge("members" => members)
  end

  define_method(:justification_problems) do |recorded|
    contested_members.flat_map do |member|
      entry = recorded.dig("members", member) || {}
      files = %w[reads copies].flat_map { |kind| entry[kind] || [] }.uniq
      justified = entry["justified"] || {}
      files.reject { |file| justified.key?(file) }.map { |file| "#{member}: #{file} has no justified entry" } +
        (justified.keys - files).map { |file| "#{member}: justified names #{file}, which is not recorded" } +
        justified.flat_map do |file, kinds|
          (Array(kinds) - kinds_allowed).map { |kind| "#{member}: #{file} is justified as #{kind.inspect}" } +
            (Array(kinds).empty? ? ["#{member}: #{file} is justified as nothing"] : [])
        end
    end
  end

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
    if DeclarationFactSources.regenerate?
      existing = File.exist?(snapshot) ? YAML.load_file(snapshot) : nil
      DeclarationFactSources.write_yaml(snapshot, header, with_justified(found, existing))
    end

    problems = census_problems(found, YAML.load_file(snapshot))
    expect(problems).to eq([]), "#{problems.join("\n")}\nRead the table through a Scope reader, or record the path " \
                                "in admission_census.yml (#{DeclarationFactSources::REGENERATE_ENV}=1 rewrites it)."
  end

  it "justifies every read and copy of a member that has a contested sibling" do
    problems = justification_problems(YAML.load_file(snapshot))
    expect(problems).to eq([]), "#{problems.join("\n")}\nClassify each file as one of #{kinds_allowed.join(', ')} " \
                                "under `justified:` in admission_census.yml."
  end

  it "records one entry per member" do
    expect(YAML.load_file(snapshot).fetch("members").keys).to eq(members.map(&:to_s))
  end

  describe "the justification check" do
    def recorded(justified, reads: ["lib/a.rb"], copies: [])
      { "members" => { "discovered_def_nodes" => { "reads" => reads, "copies" => copies, "justified" => justified } } }
    end

    def problems_for(data) = justification_problems(data).select { |line| line.start_with?("discovered_def_nodes:") }

    it "accepts a complete classification" do
      expect(problems_for(recorded({ "lib/a.rb" => ["existence"] }))).to eq([])
    end

    it "reports a file without an entry, a stale path and an unknown kind" do
      expect(problems_for(recorded({}))).to eq(["discovered_def_nodes: lib/a.rb has no justified entry"])
      expect(problems_for(recorded({ "lib/a.rb" => ["existence"], "lib/gone.rb" => ["identity"] })))
        .to eq(["discovered_def_nodes: justified names lib/gone.rb, which is not recorded"])
      expect(problems_for(recorded({ "lib/a.rb" => ["reads_value"] })))
        .to eq(["discovered_def_nodes: lib/a.rb is justified as \"reads_value\""])
    end

    it "keeps a recorded classification across regeneration and drops a file that is gone" do
      found = { "members" => { "discovered_def_nodes" => { "reads" => ["lib/a.rb"], "copies" => [] } },
                "whole_index" => [] }
      carried = with_justified(found, recorded({ "lib/a.rb" => ["identity"], "lib/gone.rb" => ["existence"] }))

      expect(carried.dig("members", "discovered_def_nodes", "justified")).to eq("lib/a.rb" => ["identity"])
    end
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

    it "counts a slot name held in a constant or variable of any kind" do
      source = <<~RUBY
        SLOT = :def_nodes
        slot ||= :refinements
        @@slot = :extends.freeze
        $slot = %i[includes]
        Holder::SLOT = :prepends
        first, second = :superclasses, :other
        WORD = :methods
      RUBY

      expect(census_of(source)).to eq(
        "discovered_def_nodes" => ["copies"], "discovered_refinements" => ["copies"],
        "discovered_extends" => ["copies"], "discovered_includes" => ["copies"],
        "discovered_prepends" => ["copies"], "discovered_superclasses" => ["copies"], "whole" => false
      )
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
