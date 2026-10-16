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
# A pin comment belongs to the nearest enclosing block above it (a line indented less than the comment).
# When that block is an example (`it`, `specify`, `example`), the pin is that example; when it is a group, the
# pin introduces the example or group that follows at the comment's own indentation, and failing that it
# covers the enclosing group. Fixture files are skipped: the specs that load them are already among the
# whole-engine drift specs.
#
# Usage: ruby tool/pin_examples.rb [SPEC_DIR]   (prints one location per line)
module PinExamples
  PIN = /\A\s*#.*flip this when/i
  EXAMPLE = /\A\s*(?:it|specify|example)\b/
  OPENER = /\A\s*(?:it|specify|example|describe|context|RSpec\.describe)\b/

  module_function

  def locations(spec_dir)
    Dir.glob(File.join(spec_dir, "**", "*_spec.rb")).flat_map { |path| in_file(path) }.uniq
  end

  def in_file(path)
    lines = File.readlines(path)
    pins = lines.each_index.select { |i| lines[i].match?(PIN) }
    pins.filter_map { |i| target_line(lines, i)&.then { "#{path}:#{it}" } }.uniq
  end

  # The 1-based line RSpec should run for the pin comment at index `pin`, or nil for a comment outside every
  # block (a file header that only mentions the phrase).
  def target_line(lines, pin)
    indent = indent_of(lines[pin])
    enclosing = (pin - 1).downto(0).find { |i| code?(lines[i]) && indent_of(lines[i]) < indent }
    return nil if enclosing.nil?
    return enclosing + 1 if lines[enclosing].match?(EXAMPLE)

    following = ((pin + 1)...lines.size).find { |i| code?(lines[i]) }
    if following && indent_of(lines[following]) == indent && lines[following].match?(OPENER)
      following + 1
    else
      enclosing + 1
    end
  end

  def code?(line)
    stripped = line.strip
    !stripped.empty? && !stripped.start_with?("#")
  end

  def indent_of(line) = line[/\A */].size

  def main(argv)
    spec_dir = argv.first || "spec"
    locations(spec_dir).each { |location| puts location }
    0
  end
end

exit PinExamples.main(ARGV) if $PROGRAM_NAME == __FILE__
