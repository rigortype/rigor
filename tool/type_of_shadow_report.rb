# frozen_string_literal: true

# ADR-129 — reads the reports `RIGOR_TYPE_OF_SHADOW_REPORT` collected, one file per analysis run and one JSON line per
# process, and judges them as G1's gate (stage-3 shadow or stage-4 serve form). It fails when a report file is missing
# or holds no line, when a line does not parse, when a run checked no would-be hit (a run that shadowed nothing proves
# nothing, so each file is held to this on its own), or when any mismatch was found. Prints the totals per phase, the
# stale misses by slot and the first mismatch samples, and appends the same to `$GITHUB_STEP_SUMMARY` when CI sets it.
#
# `--status NAME=STATUS:MAX` records a run's exit status: above MAX (a crash, or `lib` not clean) is a failure, so a run
# that died before writing its report still shows in the summary.
#
#   ruby tool/type_of_shadow_report.rb [--status NAME=STATUS:MAX]... REPORT.jsonl...
require "json"

failures = []
while ARGV.first == "--status"
  ARGV.shift
  name, status, max = ARGV.shift.to_s.match(/\A(.+)=(\d+):(\d+)\z/)&.captures
  next failures << "malformed --status" unless name

  failures << "the #{name} run exited #{status}" if status.to_i > max.to_i
end
failures << "no report given" if ARGV.empty?
counts = Hash.new { |hash, phase| hash[phase] = Hash.new(0) }
stale = Hash.new { |hash, phase| hash[phase] = Hash.new(0) }
samples = []

ARGV.each do |path|
  unless File.exist?(path)
    failures << "#{path}: no report written"
    next
  end

  checked_here = 0
  lines = File.readlines(path, chomp: true).each_with_index.reject { |text, _| text.empty? }
  failures << "#{path}: empty report" if lines.empty?
  lines.each do |text, index|
    line = JSON.parse(text)
    line.fetch("counts").each do |phase, counters|
      counters.each { |name, n| counts[phase][name] += n }
      checked_here += counters.fetch("checked", 0)
    end
    line.fetch("stale").each { |phase, slots| slots.each { |names, n| stale[phase][names] += n } }
    samples.concat(line.fetch("samples"))
  rescue JSON::ParserError, KeyError, NoMethodError, TypeError => e
    failures << "#{path}:#{index + 1}: unreadable report line (#{e.class})"
  end
  failures << "#{path}: no would-be hit was checked" if !lines.empty? && checked_here.zero?
end
checked = counts.sum { |_, counters| counters["checked"] }
mismatches = counts.sum { |_, counters| counters["mismatch"] }
failures << "#{mismatches} mismatch(es)" if mismatches.positive?

out = ["### ADR-129 type_of shadow (G1)", ""]
counts.sort.each do |phase, counters|
  out << "- #{phase}: #{counters.sort.map { |name, n| "#{name}=#{n}" }.join(' ')}"
end
stale.sort.each { |phase, slots| out << "- stale #{phase}: #{slots.sort.map { |names, n| "#{names}=#{n}" }.join(' ')}" }
samples.first(10).each { |sample| out << "- mismatch: `#{JSON.generate(sample)[0, 400]}`" }
out << "" << (failures.empty? ? "OK: #{checked} would-be hits checked, no mismatch." : "FAIL: #{failures.join('; ')}")
text = out.join("\n")
puts text
File.write(ENV["GITHUB_STEP_SUMMARY"], "#{text}\n", mode: "a") if ENV["GITHUB_STEP_SUMMARY"]
exit(failures.empty? ? 0 : 1)
