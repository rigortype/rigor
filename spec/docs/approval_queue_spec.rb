# frozen_string_literal: true

# Gate the approval queue (ADR-123). A decision an agent made without waiting for the maintainer
# lands as `approval-queue.d/<slug>.md` with its PR, and `/rigor-release-prep` asks the maintainer
# to ratify each one before a release. The entry is all the maintainer has to judge it by, so this
# gate holds its sections at landing; and a release must ship only ratified decisions, so a
# `release/**` pull request fails while any entry remains.
#
# The validator is pinned by inline examples below so the format holds even while the directory is
# empty (the steady state right after a release).
require "spec_helper"

APPROVAL_QUEUE_DIR = File.expand_path("../../approval-queue.d", __dir__)

RSpec.describe "approval-queue.d entries (ADR-123)" do
  classes = %w[gate-row open-choice scope process].freeze
  sections = ["Background", "Options and trade-offs", "Decision", "To undo"].freeze
  link = %r{\A\[#\d+\]\(https://github\.com/rigortype/rigor/(?:pull|issues)/\d+\)\z}
  pr_link = %r{\A\[#\d+\]\(https://github\.com/rigortype/rigor/pull/\d+\)\z}
  adr_link = %r{\A\[ADR-\d+\]\(\.\./docs/adr/\d+-[a-z0-9-]+\.md\)\z}
  slug = /\A[a-z0-9][a-z0-9._-]*\.md\z/

  field_rules = {
    "PR" => ->(v) { v == "none" || v.match?(pr_link) },
    "Issue" => ->(v) { v == "none" || v.match?(link) },
    "Class" => ->(v) { classes.include?(v) },
    "Precedent" => ->(v) { v == "none — sets one" || v.match?(link) || v.match?(adr_link) },
    "Decided" => ->(v) { v.match?(/\A\d{4}-\d{2}-\d{2}\z/) }
  }.freeze

  # Offense strings for the `- **Field:** value` lines.
  define_method(:field_offenses) do |name, lines|
    fields = lines.filter_map { |line| line.match(/\A- \*\*(\w+):\*\* (.+)\z/)&.captures }.to_h
    offenses = field_rules.filter_map do |field, valid|
      value = fields[field]&.strip
      if value.nil?
        "#{name}: missing `- **#{field}:** …`"
      elsif !valid.call(value)
        "#{name}: `#{field}: #{value}` does not match approval-queue.d/README.md"
      end
    end
    # A gate row with no precedent is a serious decision (contribution-flow.md), never a queued one.
    if fields["Class"]&.strip == "gate-row" && fields["Precedent"]&.strip == "none — sets one"
      offenses << "#{name}: a gate-row needs a precedent; without one it is serious, so ask first"
    end
    offenses
  end

  # Offense strings for the `## ` sections: exactly the four, in order, none empty.
  define_method(:section_offenses) do |name, lines|
    headings = lines.each_index.select { |i| lines[i].start_with?("## ") }
    found = headings.map { |i| lines[i].delete_prefix("## ").strip }
    offenses = []
    offenses << "#{name}: sections must be exactly #{sections.join(' / ')}, in order" unless found == sections
    headings.each_with_index do |start, n|
      body = lines[(start + 1)...(headings[n + 1] || lines.size)]
      offenses << "#{name}: section `#{lines[start]}` is empty" if body.all? { |line| line.strip.empty? }
    end
    offenses
  end

  # Offense strings for one entry, or [] when it conforms.
  define_method(:entry_offenses) do |name, content|
    lines = content.lines(chomp: true)
    offenses = []
    offenses << "#{name}: slug must be lowercase [a-z0-9._-] ending in .md" unless name.match?(slug)
    offenses << "#{name}: first line must be `# <the decision>`" unless lines.first&.match?(/\A# \S/)
    offenses + field_offenses(name, lines) + section_offenses(name, lines)
  end

  # Offense strings for the release rule: on a `release/**` pull request, the queue must be empty.
  define_method(:release_offenses) do |head_ref, entry_names|
    return [] unless head_ref.to_s.start_with?("release/")

    entry_names.map { |name| "#{name}: ratify, revise or revert it before the release (rigor-release-prep)" }
  end

  describe "the validator (inline examples, so the format holds while the directory is empty)" do
    let(:good) do
      <<~MD
        # Allow the guard-shape reader in producers.yml

        - **PR:** [#2140](https://github.com/rigortype/rigor/pull/2140)
        - **Issue:** none
        - **Class:** gate-row
        - **Precedent:** [#2093](https://github.com/rigortype/rigor/pull/2093)
        - **Decided:** 2026-10-19

        ## Background

        The producers gate stopped.

        ## Options and trade-offs

        Add the row, or reshape the code.

        ## Decision

        Add the row.

        ## To undo

        Remove the row and the reader.
      MD
    end

    it "accepts a conforming entry" do
      expect(entry_offenses("guard-shape.md", good)).to be_empty
    end

    it "accepts `none` for the PR and `none — sets one` for a process precedent" do
      content = good.sub(/PR:\*\* .+$/, "PR:** none").sub(/Precedent:\*\* .+$/, "Precedent:** none — sets one")
                    .sub("gate-row", "process")
      expect(entry_offenses("guard-shape.md", content)).to be_empty
    end

    it "accepts an ADR as the precedent" do
      content = good.sub(/Precedent:\*\* .+$/, "Precedent:** [ADR-119](../docs/adr/119-discovery-fact-certainty.md)")
      expect(entry_offenses("guard-shape.md", content)).to be_empty
    end

    it "rejects a precedent that is neither a link nor `none — sets one`" do
      expect(entry_offenses("guard-shape.md",
                            good.sub(/Precedent:\*\* .+$/, "Precedent:** see #2093"))).not_to be_empty
    end

    it "rejects a gate row that sets its own precedent" do
      content = good.sub(/Precedent:\*\* .+$/, "Precedent:** none — sets one")
      expect(entry_offenses("guard-shape.md", content)).not_to be_empty
    end

    it "rejects a date that is not YYYY-MM-DD" do
      expect(entry_offenses("guard-shape.md", good.sub("2026-10-19", "19 Oct 2026"))).not_to be_empty
    end

    it "rejects a link to another repository" do
      content = good.sub("rigortype/rigor/pull/2093", "rigortype/other/pull/2093")
      expect(entry_offenses("guard-shape.md", content)).not_to be_empty
    end

    it "rejects a missing field" do
      expect(entry_offenses("guard-shape.md", good.sub(/^- \*\*Precedent:.*\n/, ""))).not_to be_empty
    end

    it "rejects a bare issue number where a link is required" do
      expect(entry_offenses("guard-shape.md", good.sub("Issue:** none", "Issue:** #2121"))).not_to be_empty
    end

    it "rejects an issue link in the PR field" do
      content = good.sub(%r{rigor/pull/2140}, "rigor/issues/2140")
      expect(entry_offenses("guard-shape.md", content)).not_to be_empty
    end

    it "rejects a class outside the README's list" do
      expect(entry_offenses("guard-shape.md", good.sub("gate-row", "misc"))).not_to be_empty
    end

    it "rejects a missing section and an empty one" do
      expect(entry_offenses("guard-shape.md", good.sub(/## To undo\n\n.*\n/, ""))).not_to be_empty
      expect(entry_offenses("guard-shape.md", good.sub("Add the row.\n", ""))).not_to be_empty
    end

    it "rejects an entry with no title line and an uppercase slug" do
      expect(entry_offenses("guard-shape.md", good.sub(/\A# .*\n/, ""))).not_to be_empty
      expect(entry_offenses("Guard-Shape.md", good)).not_to be_empty
    end

    it "fails a release pull request that still has entries, and nothing else" do
      expect(release_offenses("release/0.4.5", ["guard-shape.md"])).not_to be_empty
      expect(release_offenses("release/0.4.5", [])).to be_empty
      expect(release_offenses("merge-queue-approval-queue", ["guard-shape.md"])).to be_empty
      expect(release_offenses(nil, ["guard-shape.md"])).to be_empty
    end
  end

  describe "the live directory" do
    let(:entry_paths) { Dir.glob("#{APPROVAL_QUEUE_DIR}/*").reject { |path| File.basename(path) == "README.md" } }

    it "keeps its README (the directory stays tracked and self-describing)" do
      expect(File).to exist(File.join(APPROVAL_QUEUE_DIR, "README.md"))
    end

    it "contains only conforming entries, and no subdirectories" do
      offenses = entry_paths.flat_map do |path|
        next ["#{File.basename(path)}: entries are files directly under approval-queue.d/"] unless File.file?(path)

        entry_offenses(File.basename(path), File.read(path))
      end
      expect(offenses).to be_empty, <<~MSG
        Non-conforming approval-queue entries (see approval-queue.d/README.md / ADR-123):
          #{offenses.join("\n  ")}
      MSG
    end

    # GITHUB_HEAD_REF is the pull request's branch on a `pull_request` run and empty elsewhere, so
    # this bites on the release PR's CI run (rigor-release-prep), which is what ships.
    it "is empty on a release pull request" do
      offenses = release_offenses(ENV.fetch("GITHUB_HEAD_REF", nil), entry_paths.map { |path| File.basename(path) })
      expect(offenses).to be_empty, <<~MSG
        The approval queue must be empty before a release (ADR-123):
          #{offenses.join("\n  ")}
      MSG
    end
  end
end
