# frozen_string_literal: true

require "spec_helper"
require "yaml"

# #1507 — the read-side twin of the context-computer tripwire. For each `Scope::DiscoveryIndex` member, the files
# whose code calls a method of exactly that name read the whole table, not one of `Scope`'s keyed readers. This
# spec computes that census from the tree and compares it with `raw_readers.yml`, so a new raw read fails until it
# is recorded, and a read that moves behind a keyed reader must leave the file.
RSpec.describe "Raw readers of the discovery tables" do
  let(:members) { Rigor::Scope::DiscoveryIndex.members }
  let(:recorded) { YAML.load_file(File.join(__dir__, "raw_readers.yml")) }

  # The keyed readers' home and the index itself are the sanctioned raw readers.
  excluded = %w[lib/rigor/scope.rb lib/rigor/scope/discovery_index.rb].freeze

  define_method(:census) do |code, members|
    readers = code.except(*excluded)
    members.to_h do |member|
      call = /\.#{member}\b(?![?!:=])/
      [member.to_s, readers.select { |_, text| text.match?(call) }.keys.sort]
    end
  end

  define_method(:census_problems) do |found, listed|
    found.flat_map do |member, files|
      recorded_files = listed.fetch(member, [])
      (files - recorded_files).map { |file| "#{member}: #{file} reads it raw and is not in raw_readers.yml" } +
        (recorded_files - files).map { |file| "#{member}: #{file} is recorded but no longer reads it raw" }
    end
  end

  it "records one entry per member" do
    expect(recorded.keys).to eq(members.map(&:to_s))
  end

  it "records every file that reads a member raw, and no other" do
    expect(census_problems(census(DeclarationFactSources.code_under, members), recorded)).to eq([])
  end

  describe "the census itself" do
    it "counts a new raw read" do
      code = DeclarationFactSources.code_under.merge("lib/rigor/new_reader.rb" => "scope.discovered_extends[name]\n")

      expect(census_problems(census(code, members), recorded))
        .to eq(["discovered_extends: lib/rigor/new_reader.rb reads it raw and is not in raw_readers.yml"])
    end

    it "does not count a keyed reader, a keyword write or a longer name" do
      code = {
        "lib/a.rb" => "scope.discovered_method_visibility(c, m)\n" \
                      "index.with(discovered_extends: table)\n" \
                      "ScopeIndexer.discovered_classes_for_paths(paths)\n"
      }

      members = %i[discovered_method_visibilities discovered_extends discovered_classes]

      expect(census(code, members).values.flatten).to eq([])
    end
  end
end
