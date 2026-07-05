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

RSpec.describe "handbook executable snippets", :aggregate_failures do
  include RunnerHelpers

  def self.extract_snippets(path)
    content = File.read(path, encoding: "utf-8")
    idx = 0
    content.scan(/```ruby\n(.*?)```/m).filter_map do |block,|
      idx += 1
      next unless block.include?("assert_type(") || block.include?("dump_type(")

      { file: File.basename(path), index: idx, source: block }
    end
  end

  Dir[File.join(HANDBOOK_SNIPPETS_DIR, "**", "*.md")].each do |path|
    snippets = extract_snippets(path)
    next if snippets.empty?

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
end
