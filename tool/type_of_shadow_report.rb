# frozen_string_literal: true

# ADR-129 stage 3 — reads the reports `RIGOR_TYPE_OF_SHADOW_REPORT` collected (one JSON line per process) and judges
# them as G1's stage-3 gate: it fails when a report is missing or empty, when no would-be hit was checked (a run that
# shadowed nothing proves nothing), or when any mismatch was found. Prints the totals per phase, the stale misses by
# slot and the first mismatch samples, and appends the same to `$GITHUB_STEP_SUMMARY` when CI sets it.
#
#   ruby tool/type_of_shadow_report.rb REPORT.jsonl...
require "json"

failures = []
lines = ARGV.flat_map do |path|
  unless File.exist?(path)
    failures << "#{path}: no report written"
    next []
  end

  parsed = File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
  failures << "#{path}: empty report" if parsed.empty?
  parsed
end
counts = Hash.new { |hash, phase| hash[phase] = Hash.new(0) }
stale = Hash.new { |hash, phase| hash[phase] = Hash.new(0) }
lines.each do |line|
  line.fetch("counts").each { |phase, counters| counters.each { |name, n| counts[phase][name] += n } }
  line.fetch("stale").each { |phase, slots| slots.each { |names, n| stale[phase][names] += n } }
end
checked = counts.sum { |_, counters| counters["checked"] }
mismatches = counts.sum { |_, counters| counters["mismatch"] }
failures << "no would-be hit was checked" if checked.zero?
failures << "#{mismatches} mismatch(es)" if mismatches.positive?

out = ["### ADR-129 type_of shadow (G1, stage 3)", ""]
counts.sort.each do |phase, counters|
  out << "- #{phase}: #{counters.sort.map { |name, n| "#{name}=#{n}" }.join(' ')}"
end
stale.sort.each { |phase, slots| out << "- stale #{phase}: #{slots.sort.map { |names, n| "#{names}=#{n}" }.join(' ')}" }
samples = lines.flat_map { |line| line.fetch("samples") }
samples.first(10).each { |sample| out << "- mismatch: `#{JSON.generate(sample)[0, 400]}`" }
out << "" << (failures.empty? ? "OK: #{checked} would-be hits checked, no mismatch." : "FAIL: #{failures.join('; ')}")
text = out.join("\n")
puts text
File.write(ENV["GITHUB_STEP_SUMMARY"], "#{text}\n", mode: "a") if ENV["GITHUB_STEP_SUMMARY"]
exit(failures.empty? ? 0 : 1)
