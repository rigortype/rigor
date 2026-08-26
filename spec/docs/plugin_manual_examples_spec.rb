# frozen_string_literal: true

require "spec_helper"

# Drift guard for issue #488.
#
# Each `docs/manual/plugins/*.md` page shows a block of example diagnostics — the only place a reader sees
# what the plugin will actually say, and what they will match their own terminal against. Nothing checked
# them, and all five pages carrying such a block had drifted from the product in three ways at once:
#
# - the `[plugin.<id>.<rule>]` suffix was missing, although plugin diagnostics have carried it since
#   v0.1.0 slice 5 (the pages were never accurate on this point, not merely stale);
# - line numbers pointed at where the demo's code used to be (`demo.rb:14` for a call on line 12);
# - one page cited the wrong FILE entirely (`spec/user_spec.rb` for a diagnostic in `errors_spec.rb`).
#
# The checks here are STATIC on purpose. Running the five demos and diffing the real output is the
# complete answer and costs 6.3 s, which lands on `make verify` through `test-binpacker` — a ~10 % tax on
# the most-run gate against a drift opportunity that arises about monthly (11 commits touched a `demo/`
# in eight months). These three assertions cost nothing and catch the three shapes actually observed.
#
# What they deliberately do NOT catch: a line number that drifted but still exists in the file. That half
# needs execution, and #488 records the measurement behind leaving it out.
RSpec.describe "plugin manual example blocks" do
  def diagnostic_line
    %r{^(?<path>[A-Za-z0-9_/.-]+\.rb):(?<line>\d+):\d+: (?:error|warning|info): (?<rest>.*)$}
  end

  def pages
    Dir[File.expand_path("../../docs/manual/plugins/*.md", __dir__)]
  end

  def demo_root(page)
    File.expand_path("../../plugins/#{File.basename(page, '.md')}/demo", __dir__)
  end

  def examples_in(page)
    File.readlines(page, chomp: true).filter_map do |line|
      match = diagnostic_line.match(line)
      match && { path: match[:path], line: match[:line].to_i, rest: match[:rest] }
    end
  end

  it "shows at least one example block, so these checks are not vacuous" do
    total = pages.sum { |page| examples_in(page).length }

    expect(total).to be >= 14
  end

  it "carries the rule identifier on every example diagnostic" do
    offenders = pages.flat_map do |page|
      examples_in(page).reject { |row| row[:rest].match?(/\[[a-z0-9_.-]+\]$/) }
                       .map { |row| "#{File.basename(page)}: #{row[:path]}:#{row[:line]} — #{row[:rest][0, 60]}" }
    end

    expect(offenders).to be_empty, "a plugin diagnostic always prints `[plugin.<id>.<rule>]`; these " \
                                   "examples omit it:\n  #{offenders.join("\n  ")}"
  end

  it "cites a file that exists in the plugin's own demo, at a line that exists in it" do
    offenders = pages.flat_map do |page|
      root = demo_root(page)
      next [] unless File.directory?(root)

      examples_in(page).filter_map do |row|
        file = File.join(root, row[:path])
        next "#{File.basename(page)}: no such demo file #{row[:path]}" unless File.file?(file)

        length = File.readlines(file).length
        next if row[:line] <= length

        "#{File.basename(page)}: #{row[:path]}:#{row[:line]} is past the end of the file (#{length} lines)"
      end
    end

    expect(offenders).to be_empty, "regenerate the block from the plugin's demo:\n  #{offenders.join("\n  ")}"
  end
end
