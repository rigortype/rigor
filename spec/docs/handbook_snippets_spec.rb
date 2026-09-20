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
  module_function

  def markdown_files
    Dir[File.join(HANDBOOK_SNIPPETS_DIR, "**", "*.md")]
  end

  # The scan the gate is built on: ```ruby blocks only, and of those only the ones that call an
  # introspection helper. `index` counts every ```ruby block in the file, executable or not, so a
  # snippet's number matches what a reader counts in the source.
  def extract_snippets(path)
    content = File.read(path, encoding: "utf-8")
    idx = 0
    content.scan(/```ruby\n(.*?)```/m).filter_map do |block,|
      idx += 1
      next unless executable?(block)

      { file: File.basename(path), index: idx, source: block }
    end
  end

  # Every fenced block with its info string — including the ones `extract_snippets` cannot see.
  def fenced_blocks(path)
    File.read(path, encoding: "utf-8").scan(/^```([^\n]*)\n(.*?)^```/m)
  end

  def executable?(body)
    body.include?("assert_type(") || body.include?("dump_type(")
  end

  # Executable blocks carrying a Ruby-ish fence that is not exactly ```ruby, so the scan above misses them.
  def misspelled_fences
    markdown_files.flat_map do |path|
      fenced_blocks(path).filter_map do |info, block|
        next unless executable?(block)
        next if info == "ruby"

        lang = info.strip.split(/\s+/).first.to_s.downcase
        next unless ["", "rb", "ruby"].include?(lang)

        "  → #{File.basename(path)}: ```#{info} — respell as ```ruby"
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
  # example and this file reports green having checked nothing — moving `docs/handbook` aside takes it from
  # 20 examples to 0, with no failure anywhere and no count anyone asserts (CI's shard-coverage job compares
  # the shards to each other, not to a baseline). A floor with slack, per the house style of
  # `plugin_io_boundary_spec.rb` and `packaged_link_integrity_spec.rb`: it catches a collapse, while the
  # fence guard below is what catches the loss of a single snippet.
  it "extracts a plausible number of executable snippets, so the examples above are not vacuous" do
    expect(HANDBOOK_SNIPPET_COUNT).to be >= 15
  end

  # `extract_snippets` matches ```ruby and nothing else. A snippet written with any other Ruby-ish fence —
  # ```rb, a bare ```, or ```ruby with a trailing info word — silently contributes no example: the count
  # drops by one and nothing goes red. This is a live spelling hazard, not a hypothetical one: docs/handbook
  # already carries both ```rb and bare fences for non-executable blocks, so the next author to reach for one
  # while writing an `assert_type` block gets no coverage and no warning.
  #
  # Deliberately narrow — only fences whose language token is absent, `rb`, or `ruby`. A ```text or ```sh
  # block quoting CLI output may legitimately contain `assert_type(`, and failing a correct document is the
  # error direction that matters here (AGENTS.md: false positives outrank worst-case static reading).
  it "spells every executable snippet's fence ```ruby, so none drops out of the scan above" do
    expect(HANDBOOK_MISSPELLED_FENCES).to be_empty,
                                          "An executable snippet (one calling `assert_type` or " \
                                          "`dump_type`) is only checked when its fence is exactly " \
                                          "```ruby; these carry a Ruby-ish fence the scan cannot see, " \
                                          "so they are silently unverified:\n" +
                                          HANDBOOK_MISSPELLED_FENCES.join("\n")
  end
end
