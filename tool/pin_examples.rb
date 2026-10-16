#!/usr/bin/env ruby
# frozen_string_literal: true

# Lists the RSpec examples that pin a known-wrong answer, as `path:line` locations `bin/verify-changed` runs
# for every engine change.
#
# A spec that records behaviour its author believes is wrong carries an in-place "flip this when #N is fixed"
# comment (contribution-flow.md). An engine change can fix #N as a side effect, and the pin then fails in a
# file the branch never touched, which only CI saw: #2003 fixed #1657 that way, and
# `ruby_order_resolution_spec.rb` went red on its first CI run. Running every pinned file whole costs about 75
# seconds, most of it in large files holding one pin each, so this names only the pinned examples.
#
# A pin is a comment paragraph (consecutive full-line comments, joined, so a phrase wrapped across lines
# counts) or a trailing comment that says "flip this/these/the …/each … when/if"; the spellings the tree
# actually uses, not only the convention's exact phrase. A full-line pin belongs to the nearest enclosing
# block above it (a line indented less than the comment). When that block is an example (`it`, `specify`,
# `example`), the pin is that example. Otherwise the pin introduces the example or group that follows at the
# comment's own indentation, and failing that the search climbs from the block to its nearest enclosing
# example or group: for a `let`, `before`, `subject` or helper `def`, RSpec would map the block's own line
# to an unrelated sibling. A trailing comment climbs the same way from its own line. Fixture files are
# skipped: the specs that load them are already among the whole-engine drift specs.
#
# Usage: ruby tool/pin_examples.rb [SPEC_DIR]   (prints one location per line; exits 1 when it finds none)
module PinExamples
  PIN = /\bflip\s+(?:this|these|the|each|them|it)\b[^.]*?\b(?:when|if)\b/i
  EXAMPLE = /\A\s*(?:it|specify|example)\b/
  OPENER = /\A\s*(?:it|specify|example|describe|context|RSpec\.describe)\b/
  COMMENT = /\A\s*#/

  module_function

  def locations(spec_dir)
    Dir.glob(File.join(spec_dir, "**", "*_spec.rb")).flat_map { |path| in_file(path) }.uniq
  end

  def in_file(path)
    lines = File.readlines(path)
    targets = paragraph_pins(lines).map { |first| comment_target(lines, first) }
    targets += trailing_pins(lines).map { |index| climb(lines, index) }
    targets.compact.uniq.sort.map { |line| "#{path}:#{line}" }
  end

  # The index of each comment paragraph's first line whose joined text holds a pin.
  def paragraph_pins(lines)
    lines.each_index.select do |i|
      next false unless comment?(lines[i]) && !(i.positive? && comment?(lines[i - 1]))

      last = i
      last += 1 while last + 1 < lines.size && comment?(lines[last + 1])
      lines[i..last].map { |line| line.strip.delete_prefix("#").strip }.join(" ").match?(PIN)
    end
  end

  # The index of each code line whose trailing comment holds a pin.
  def trailing_pins(lines)
    lines.each_index.select do |i|
      !comment?(lines[i]) && (comment = lines[i][/\s#\s.*/]) && comment.match?(PIN)
    end
  end

  # The 1-based line RSpec should run for the full-line pin paragraph starting at index `pin`, or nil for a
  # paragraph outside every block (a file header that only mentions the phrase).
  def comment_target(lines, pin)
    indent = indent_of(lines[pin])
    enclosing = enclosing_index(lines, pin, indent)
    return nil if enclosing.nil?
    return enclosing + 1 if lines[enclosing].match?(EXAMPLE)

    following = ((pin + 1)...lines.size).find { |i| code?(lines[i]) }
    return following + 1 if following && indent_of(lines[following]) == indent && lines[following].match?(OPENER)

    climb(lines, enclosing)
  end

  # The 1-based line of the example or group that contains the code line at `index` (the line itself when it
  # opens one), or nil when none does.
  def climb(lines, index)
    while index
      return index + 1 if lines[index].match?(OPENER)

      index = enclosing_index(lines, index, indent_of(lines[index]))
    end
    nil
  end

  def enclosing_index(lines, from, indent)
    (from - 1).downto(0).find { |i| code?(lines[i]) && indent_of(lines[i]) < indent }
  end

  def comment?(line) = line.match?(COMMENT)

  def code?(line)
    !line.strip.empty? && !comment?(line)
  end

  def indent_of(line) = line[/\A */].size

  def main(argv)
    found = locations(argv.first || "spec")
    found.each { |location| puts location }
    found.empty? ? 1 : 0
  end
end

exit PinExamples.main(ARGV) if $PROGRAM_NAME == __FILE__
