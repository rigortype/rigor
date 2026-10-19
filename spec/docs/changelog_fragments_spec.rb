# frozen_string_literal: true

# Gate the `changelog.d/` fragment files (ADR-105). An `[Unreleased]` entry lands as
# `changelog.d/<section>/<slug>.md` instead of a direct `CHANGELOG.md` edit — GitHub ignores
# `.gitattributes merge=union` for PR mergeability, so same-anchor edits serialize otherwise
# independent PRs. The fragment IS the entry, so this gate holds the entry grammar at landing,
# including the PR/issue link the direct-edit flow only ever trusted.
#
# The validator is pinned by inline examples below so the grammar holds even while the directory
# is empty (the steady state right after a release cut).
require "spec_helper"

FRAGMENTS_DIR = File.expand_path("../../changelog.d", __dir__)

RSpec.describe "changelog.d fragment conformance (ADR-105)" do
  # Keep a Changelog 1.1.0's section types, downcased — the allowed subdirectory names.
  sections = %w[added changed deprecated removed fixed security].freeze
  entry_line = /\A- \*\*\[[^\]]+\]\*\* \S.*\z/
  child_line = /\A {2}- \S.*\z/
  repo_link = %r{\[#\d+\]\(https://github\.com/rigortype/rigor/(?:pull|issues)/\d+\)}
  slug = /\A[a-z0-9][a-z0-9._-]*\.md\z/

  # The entry line is the release note's bullet: one sentence, no em-dash clause (rigor-release-prep's rules).
  # A code span reads as the capitalised word `C`, so a sentence opening with one still counts; a link and the
  # Latin abbreviations drop out, so `1.."a"`, a link's text or `e.g. String` cannot read as a sentence break. A
  # period is the only break: a `?` or `!` here is far more often a Ruby method name than a sentence end.
  define_method(:entry_prose_offenses) do |relative, entry|
    prose = entry.to_s.gsub(/`[^`]*`/, "C").gsub(/\[[^\]]*\]\([^)]*\)/, "x")
    prose = prose.gsub(/\b(?:e\.?g|i\.e|vs|etc|cf|approx|a\.k\.a|dr|mr|u\.s)\./i, "abbr")
    prose = prose.gsub(/(?<=\d)–(?=\d)/, "-") # a numeric range (`1–3`) is not a clause
    offenses = []
    if prose.match?(/—|–| -- /)
      offenses << "#{relative}: the entry line carries a dash clause; move it to a `  - ` child item"
    end
    if prose.match?(/[A-Za-z0-9)"']\.[*"']* +[A-Z0-9]/)
      offenses << "#{relative}: the entry line holds more than one sentence; move the rest to `  - ` child items"
    end
    offenses
  end

  # Offense strings for one fragment, or [] when it conforms. `relative` is the path under
  # changelog.d/ (e.g. "fixed/my-branch.md").
  define_method(:fragment_offenses) do |relative, content|
    offenses = []
    segments = relative.split("/")
    unless segments.size == 2 && sections.include?(segments.first)
      offenses << "#{relative}: expected <section>/<slug>.md with section in #{sections.join(', ')}"
    end
    offenses << "#{relative}: slug must be lowercase [a-z0-9._-] ending in .md" unless segments.last.match?(slug)

    lines = content.lines(chomp: true)
    if lines.empty? || !lines.first.match?(entry_line)
      offenses << "#{relative}: first line must be a `- **[subsystem]** …` bullet on ONE line"
    end
    offenses.concat(entry_prose_offenses(relative, lines.first))
    lines.drop(1).each do |line|
      unless line.match?(child_line)
        offenses << "#{relative}: `#{line}` — only `  - ` child items may follow (no wrapping)"
      end
    end
    offenses << "#{relative}: entry must carry a full markdown PR/issue link" unless content.match?(repo_link)
    offenses
  end

  describe "the validator (inline examples, so the grammar holds while the directory is empty)" do
    let(:good) { "- **[engine]** One sentence. ([#42](https://github.com/rigortype/rigor/pull/42))\n" }

    it "accepts a conforming single-line entry" do
      expect(fragment_offenses("fixed/my-branch.md", good)).to be_empty
    end

    it "accepts child items under the entry line" do
      content = "#{good}  - Detail traced to ([#43](https://github.com/rigortype/rigor/pull/43)).\n"
      expect(fragment_offenses("added/my-branch.md", content)).to be_empty
    end

    it "rejects a column-wrapped entry (the continuation is neither bullet nor child)" do
      wrapped = "- **[engine]** A sentence that\nwraps. ([#42](https://github.com/rigortype/rigor/pull/42))\n"
      expect(fragment_offenses("fixed/my-branch.md", wrapped)).not_to be_empty
    end

    it "rejects a missing or bare link" do
      expect(fragment_offenses("fixed/my-branch.md", "- **[engine]** One sentence. (#42)\n")).not_to be_empty
    end

    it "rejects an unknown section directory and a top-level file" do
      expect(fragment_offenses("performance/my-branch.md", good)).not_to be_empty
      expect(fragment_offenses("my-branch.md", good)).not_to be_empty
    end

    it "rejects an em-dash clause on the entry line" do
      dashed = "- **[engine]** A fix — and why. ([#42](https://github.com/rigortype/rigor/pull/42))\n"
      expect(fragment_offenses("fixed/my-branch.md", dashed)).not_to be_empty
    end

    it "rejects a second sentence on the entry line, and keeps it for a child item" do
      two = "- **[engine]** A fix. It also does more. ([#42](https://github.com/rigortype/rigor/pull/42))\n"
      expect(fragment_offenses("fixed/my-branch.md", two)).not_to be_empty
      expect(fragment_offenses("fixed/my-branch.md", "#{good}  - It also does more. And more.\n")).to be_empty
    end

    it "rejects the second-sentence shapes a capital-letter test alone misses" do
      ["Fix the RBS. It loads now.", 'Report "x". It is fine.', "**Integer.** Then more.",
       "A fix. `rigor check` now passes.", "A fix. 3 rules move.", "A fix – and why."].each do |prose|
        entry = "- **[engine]** #{prose} ([#42](https://github.com/rigortype/rigor/pull/42))\n"
        expect(fragment_offenses("fixed/my-branch.md", entry)).not_to be_empty, prose
      end
    end

    it "does not read a code span, a link or an abbreviation as a sentence break" do
      code = "- **[engine]** `a. B` and `1..\"a\"`, e.g. this one, now type " \
             "([#42](https://github.com/rigortype/rigor/pull/42), [#43. X](https://github.com/rigortype/rigor/issues/43)).\n"
      expect(fragment_offenses("fixed/my-branch.md", code)).to be_empty
      ["Accept e.g. String and Array as keys.", "Read i.e. Integer here.", "Compare Array vs. Hash shapes.",
       "Skip globs, etc. Ruby files stay.", "Narrow ivars; Ruby 3.4 needs it.",
       "Keep `empty?` and any? And all? apart.", "Ship it in v0.4.5.", "Type Foo.bar calls.",
       "Accept E.g. String keys.", "Cut approx. 30% of allocations.", "Read a.k.a. Alias names.",
       "Fold 1–3 element tuples."].each do |prose|
        entry = "- **[engine]** #{prose} ([#42](https://github.com/rigortype/rigor/pull/42))\n"
        expect(fragment_offenses("fixed/my-branch.md", entry)).to be_empty, prose
      end
    end

    it "rejects an uppercase slug" do
      expect(fragment_offenses("fixed/My-Branch.md", good)).not_to be_empty
    end
  end

  describe "the live directory" do
    it "keeps its README (the directory stays tracked and self-describing)" do
      expect(File).to exist(File.join(FRAGMENTS_DIR, "README.md"))
    end

    it "contains only conforming fragments" do
      offenses = Dir.glob("#{FRAGMENTS_DIR}/**/*").filter_map do |path|
        next unless File.file?(path)

        relative = path.delete_prefix("#{FRAGMENTS_DIR}/")
        next if relative == "README.md"

        list = fragment_offenses(relative, File.read(path))
        list.join("\n  ") unless list.empty?
      end
      expect(offenses).to be_empty, <<~MSG
        Non-conforming changelog fragments (see changelog.d/README.md / ADR-105):
          #{offenses.join("\n  ")}
      MSG
    end
  end
end
