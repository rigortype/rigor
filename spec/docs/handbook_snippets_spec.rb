# frozen_string_literal: true

# Verify that every executable code block in docs/handbook/ stays accurate as the engine evolves.
# "Executable" means the block contains an `assert_type(...)` or `dump_type(...)` call — the two Rigor
# introspection helpers that pin inferred types in prose.
#
# A block that fires `assert.type-mismatch` is a documentation error: the prose claims a type that the engine
# no longer produces.
#
# Blocks that use only the `#=> dump_type: TypeString` annotation convention (documentation-only comments, not
# method calls) are not tested here — they are presentation markers for `rigor annotate`.

require "spec_helper"

HANDBOOK_SNIPPETS_DIR = File.expand_path("../../docs/handbook", __dir__)

module HandbookSnippets
  # Fences that may legitimately contain the text `assert_type(` without being a Ruby snippet: a block
  # quoting CLI output or a diagnostic. Everything else carrying an introspection call is either checked
  # (```ruby) or a mis-spelled snippet. A BARE fence is deliberately not on this list — a bare block
  # holding `assert_type(` is far more likely to be a snippet that lost its language tag than output, and
  # the repair is one word — but that is the one arm that could fail a correct document, so if a bare
  # block ever legitimately quotes such a diagnostic, move it to ```text rather than widening this list.
  OUTPUT_FENCES = %w[text sh diff].freeze

  module_function

  def markdown_files
    Dir[File.join(HANDBOOK_SNIPPETS_DIR, "**", "*.md")]
  end

  # ONE scanner, used for both the snippets that run and the fences that are audited. Two scans that
  # disagree about what a fence is was the original defect in miniature: a block one sees and the other
  # does not is either unverified or unflagged, and nothing says which. A line scanner also cannot phase
  # shift the way a regex pairing `^`-anchored closers does — a single indented closer left a later
  # block unmatched and silently disarmed the audit for the rest of the file.
  #
  # Marker handling is deliberately literal: `~~~ruby` is a Ruby fence and is run, while ````ruby (four
  # backticks, a wrapper for markdown that itself contains fences) is not, and is flagged if it carries
  # an introspection call. Neither spelling occurs in the handbook today.
  def blocks(path)
    found = []
    info = nil
    body = nil
    File.readlines(path, encoding: "utf-8").each do |line|
      # The markers are matched against the chomped line; the body keeps the raw one.
      marker = line.chomp
      if info
        if marker.match?(/\A\s*(?:```|~~~)\s*\z/)
          found << [info, body.join]
          info = nil
        else
          body << line
        end
      elsif (opener = marker.match(/\A\s*(?:```|~~~)(.*)\z/))
        info = opener[1].strip
        body = []
      end
    end
    found
  end

  # The blocks the gate runs: fenced exactly ```ruby, and calling an introspection helper. `index` counts
  # every ```ruby block in the file, executable or not, so a snippet's number matches what a reader counts.
  def extract_snippets(path)
    idx = 0
    blocks(path).filter_map do |info, block|
      next unless info == "ruby"

      idx += 1
      next unless executable?(block)

      { file: File.basename(path), index: idx, source: block }
    end
  end

  def executable?(block)
    block.include?("assert_type(") || block.include?("dump_type(")
  end

  # Executable blocks the scan above will not run, stated as an allow-list rather than a list of known
  # mis-spellings: ```rb was the spelling that prompted this, but ```irb and ```console were equally
  # invisible, and enumerating mistakes only ever covers the ones already made. (`~~~ruby` needs no
  # entry — the scanner accepts `~~~` as a fence marker, so such a block is RUN rather than flagged.)
  def misspelled_fences
    markdown_files.flat_map do |path|
      blocks(path).filter_map do |info, block|
        next unless executable?(block)
        next if info == "ruby"
        next if OUTPUT_FENCES.include?(info.split(/\s+/).first.to_s.downcase)

        "  → #{File.basename(path)}: ```#{info.empty? ? '(no language)' : info} — respell as ```ruby"
      end
    end
  end
end

HANDBOOK_SNIPPETS_BY_FILE = HandbookSnippets.markdown_files
                                            .to_h { |path| [path, HandbookSnippets.extract_snippets(path)] }
                                            .reject { |_, snippets| snippets.empty? }
                                            .freeze
HANDBOOK_SNIPPET_COUNT = HANDBOOK_SNIPPETS_BY_FILE.sum { |_, snippets| snippets.size }
HANDBOOK_MISSPELLED_FENCES = HandbookSnippets.misspelled_fences.freeze

RSpec.describe "handbook executable snippets", :aggregate_failures do
  include RunnerHelpers

  HANDBOOK_SNIPPETS_BY_FILE.each do |path, snippets|
    context File.basename(path) do
      snippets.each do |snip|
        it "snippet #{snip[:index]} — no assert.type-mismatch" do
          result = analyze(snip[:source])
          mismatches = result.diagnostics.select { |d| d.rule == "assert.type-mismatch" }
          expect(mismatches).to be_empty,
                                "#{snip[:file]} snippet #{snip[:index]}:\n" +
                                mismatches.map { |d| "  line #{d.line}: #{d.message}" }.join("\n")
        end
      end
    end
  end

  # The examples above are generated at load time from a glob, so a scan that matches nothing produces NO
  # example and this file reports green having checked nothing — moving `docs/handbook` aside took it from
  # 20 examples to 0 with no failure, and no one asserts the count (CI's shard-coverage job compares the
  # shards to each other, and `binpacker`'s "discovered" figure is a count of FILES, not examples).
  #
  # Exact, not a floor. The count has been 20 at every one of the last fourteen release tags while 33
  # commits touched `docs/handbook`, so this is a static corpus and an exact pin has never had anything to
  # churn on. A floor is what a GROWING corpus gets (`plugin_io_boundary_spec.rb` guards 169 files with a
  # floor of 50); carrying that shape over here bought nothing and cost everything — at `>= 15` any single
  # handbook file, or five snippets, could be deleted green. The edit that changes this number belongs in
  # the diff next to the edit that changes the handbook.
  it "runs every executable snippet in the handbook, and there are exactly 20 of them" do
    expect(HANDBOOK_SNIPPET_COUNT).to eq(20)
  end

  # The pin above catches a snippet that STOPS being counted. It cannot catch one that was never counted:
  # a newly written block fenced ```irb leaves the total at 20 while going unverified. That is the case
  # this guard exists for, and why it is an allow-list — see `OUTPUT_FENCES`.
  it "fences every executable snippet ```ruby, so none is silently left unverified" do
    expect(HANDBOOK_MISSPELLED_FENCES).to be_empty,
                                          "An executable snippet (one calling `assert_type` or " \
                                          "`dump_type`) is only run when its fence is exactly ```ruby; " \
                                          "these carry a fence the scan cannot see, so they are " \
                                          "silently unverified:\n" + HANDBOOK_MISSPELLED_FENCES.join("\n")
  end
end
