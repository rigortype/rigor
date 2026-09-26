# frozen_string_literal: true

# Verify that every executable code block in docs/handbook/ stays accurate as the engine evolves.
# "Executable" means the block CALLS `assert_type(...)` or `dump_type(...)` — the two Rigor introspection
# helpers that pin inferred types in prose. "Calls" is decided by parsing the block, not by searching its
# text: an occurrence inside a comment, a string, a heredoc or after `__END__` is not an assertion, and
# each of those is a separate rule for a line scanner but the same answer for a parser.
#
# A block that fires `assert.type-mismatch` is a documentation error: the prose claims a type that the engine
# no longer produces. A block that does not PARSE is worse than either, because it evaluates none of its own
# assertions and so passes a mismatch check trivially — that is checked first, and against Prism directly
# rather than against the analyzer's diagnostics, which are silenced entirely for a source that fails to
# parse and contains `%>` (`Rigor::Analysis::ErbTemplateDetector`).
#
# Blocks that use only the `#=> dump_type: TypeString` annotation convention (documentation-only comments, not
# method calls) are not tested here — they are presentation markers for `rigor annotate`.

require "spec_helper"
require "prism"

HANDBOOK_SNIPPETS_DIR = File.expand_path("../../docs/handbook", __dir__)

module HandbookSnippets
  HELPERS = %i[assert_type dump_type].freeze

  # Fences that may legitimately contain a call to an introspection helper without being a Ruby snippet: a
  # block quoting CLI output or a diagnostic. Everything else carrying such a call is either run (```ruby)
  # or a mis-spelled snippet. A BARE fence is deliberately not on this list — a bare block calling
  # `assert_type` is far more likely to be a snippet that lost its language tag than output, and the repair
  # is one word — but that is the one arm that could fail a correct document, so if a bare block ever
  # legitimately quotes such a call, move it to ```text rather than widening this list.
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
  # Marker handling is deliberately literal: ```` ``` ```` and `~~~` are both fences and both close a
  # block, so `~~~ruby` is run like ```ruby, while ````ruby (four backticks, a wrapper for markdown that
  # itself contains fences) is neither. Neither spelling occurs in the handbook today.
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
    # A fence left unclosed at end of file is NOT dropped. Dropping it is the silent direction — the
    # block is then neither run nor audited, which is the whole defect this file exists for. Kept, so
    # it reaches the audit below, or the parse check in the example, or the count pin. One of the
    # three is always loud.
    found << [info, body.join] if info

    found
  end

  # The blocks the gate runs: fenced `ruby` (either marker), and calling an introspection helper. `index`
  # counts every `ruby`-fenced block in the file, executable or not, so a snippet's number matches what a
  # reader counts in the source.
  def extract_snippets(path)
    idx = 0
    blocks(path).filter_map do |info, block|
      next unless info == "ruby"

      idx += 1
      next unless executable?(block)

      { file: File.basename(path), index: idx, source: block }
    end
  end

  # Whether the block CALLS a helper, decided from the AST. A textual test counted an assertion that had
  # been disabled: first `#`-commented, then — once `#` was special-cased — `=begin`/`=end`, a trailing
  # comment, a heredoc, a string, `__END__`. Each is a separate rule to write and the next one is always
  # the one nobody thought of; a parser answers all of them at once. A block that does not parse still
  # yields a partial tree, so a ```ruby snippet broken by a typo is still counted and still reaches the
  # parse check rather than quietly leaving the corpus.
  def executable?(block)
    calls_helper?(Prism.parse(block).value)
  end

  def calls_helper?(node)
    return false unless node.is_a?(Prism::Node)
    return true if node.is_a?(Prism::CallNode) && node.receiver.nil? && HELPERS.include?(node.name)

    node.compact_child_nodes.any? { |child| calls_helper?(child) }
  end

  # Executable blocks the scan above will not run, stated as an allow-list rather than a list of known
  # mis-spellings: ```rb was the spelling that prompted this, but ```irb and ```console were equally
  # invisible, and enumerating mistakes only ever covers the ones already made. The allow-list is consulted
  # BEFORE the block is parsed, so a ```text block quoting a diagnostic is never even inspected.
  def misspelled_fences
    markdown_files.flat_map do |path|
      blocks(path).filter_map do |info, block|
        next if info == "ruby"
        next if OUTPUT_FENCES.include?(info.split(/\s+/).first.to_s.downcase)
        next unless executable?(block)

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
        it "snippet #{snip[:index]} — parses, and no assert.type-mismatch" do
          # Checked FIRST, separately, and against Prism rather than the analyzer. A snippet that does not
          # parse evaluates none of its own assertions, so the mismatch filter below finds nothing and the
          # example passes having verified nothing — a deliberately wrong assertion behind a stray `def (`
          # was green. Asking the analyzer is not enough: for a source that fails to parse AND contains
          # `%>`, `ErbTemplateDetector` makes it return no diagnostics at all, so even a rule-less-
          # diagnostic check reports clean.
          parse_errors = Prism.parse(snip[:source]).errors
          expect(parse_errors).to be_empty,
                                  "#{snip[:file]} snippet #{snip[:index]} does not parse, so its " \
                                  "assertions were never evaluated:\n" +
                                  parse_errors.map { |e| "  line #{e.location.start_line}: #{e.message}" }
                                              .join("\n")

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
  # Exact, not a floor. The count is not static — it moved eight times between 2026-05-07 and 2026-06-11
  # (17 → 19 → 21 → 22 → 17 → 18 → 20 → 24 → 20), was 20 until #1429 added three narrowing examples (a disjoint
  # `is_a?`, a disjoint `when`, and `respond_to?`), and every one of those moves belonged in the diff that caused
  # it. A floor is what a GROWING corpus gets
  # (`plugin_io_boundary_spec.rb` guards 169 files with a floor of 50, one per plugin); carrying that
  # shape over here bought nothing and cost everything — at `>= 15` any single handbook file, or five
  # snippets, could be deleted green.
  it "runs every executable snippet in the handbook, and there are exactly 23 of them" do
    expect(HANDBOOK_SNIPPET_COUNT).to eq(23)
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
