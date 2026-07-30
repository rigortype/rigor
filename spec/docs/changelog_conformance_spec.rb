# frozen_string_literal: true

# Gate the changelogs against the format they declare. `CHANGELOG.md`'s own header says it follows
# Keep a Changelog 1.1.0, which defines exactly six section types — Added, Changed, Deprecated,
# Removed, Fixed, Security — and a canonical order for them.
#
# The rule was already written down, in the `rigor-release-prep` skill's release mechanics ("Use Keep a
# Changelog section headings verbatim"), and it drifted anyway: by 2026-07-30 the four changelog files
# carried six `### Performance` sections plus `### Internal`, `### Documentation`, and one heading that
# was a sentence. A `Performance` heading is the tempting one — it reads informative — but it splits
# what Keep a Changelog puts under `Changed`, so a reader scanning for behaviour changes has to know to
# look in two places, and tooling that consumes the format sees an unknown section.
#
# Same lesson as ADR-97 and `agent_index_spec.rb`: a format rule with no mechanical gate is a temporary
# state, not a decision. Where an entry belongs is a judgement call the author still makes — this only
# holds the vocabulary and the order.
require "spec_helper"

CHANGELOG_FILES = [
  File.expand_path("../../CHANGELOG.md", __dir__),
  *Dir[File.expand_path("../../docs/CHANGELOG-*.md", __dir__)]
].freeze

# Keep a Changelog 1.1.0's types, in the order the spec lists them.
CHANGELOG_SECTIONS = %w[Added Changed Deprecated Removed Fixed Security].freeze

RSpec.describe "CHANGELOG conformance to Keep a Changelog 1.1.0" do
  # [release heading, [section names in document order]] for one file.
  def releases_in(path)
    releases = []
    File.readlines(path, chomp: true).each do |line|
      releases << [line, []] if line.start_with?("## ")
      releases.last[1] << line.delete_prefix("### ").strip if line.start_with?("### ") && releases.any?
    end
    releases
  end

  it "covers every changelog file, so a new archive cannot slip the gate" do
    expect(CHANGELOG_FILES.size).to be >= 4
    expect(CHANGELOG_FILES).to all(satisfy { |path| File.file?(path) })
  end

  CHANGELOG_FILES.each do |path|
    context File.basename(path) do
      let(:releases) { releases_in(path) }

      it "uses only the six Keep a Changelog section types" do
        offenders = releases.flat_map do |heading, sections|
          (sections - CHANGELOG_SECTIONS).map { |name| "#{heading} → ### #{name}" }
        end
        expect(offenders).to be_empty, <<~MSG
          Non-standard changelog sections:
            #{offenders.join("\n  ")}
          A speed-up is `Changed`; a docs correction is `Fixed`. Say which it is in the entry text.
        MSG
      end

      it "declares each section at most once per release" do
        offenders = releases.filter_map do |heading, sections|
          duplicated = sections.tally.select { |_name, count| count > 1 }.keys
          "#{heading} → #{duplicated.join(', ')}" if duplicated.any?
        end
        expect(offenders).to be_empty, "Duplicated sections (merge them):\n  #{offenders.join("\n  ")}"
      end

      it "orders the sections as Keep a Changelog lists them" do
        offenders = releases.filter_map do |heading, sections|
          known = sections.select { |name| CHANGELOG_SECTIONS.include?(name) }
          indexes = known.map { |name| CHANGELOG_SECTIONS.index(name) }
          "#{heading} → #{known.join(', ')}" if indexes != indexes.sort
        end
        expect(offenders).to be_empty, <<~MSG
          Sections out of order (expected #{CHANGELOG_SECTIONS.join(', ')}):
            #{offenders.join("\n  ")}
        MSG
      end
    end
  end
end
