# frozen_string_literal: true

# rigor-regression-sweep — tabulate a sweep (Phase 7 of SKILL.md).
# Reads reports/<tag>.json + <tag>.err produced by sweep.sh and
# prints the error-increase curve relative to the frozen baseline.
#
# Edit SWEEP + TAGS for the target, then:
#   nix … develop --command ruby <this-script>
require "json"

# --- configure -------------------------------------------------------
SWEEP = "/Users/megurine/repo/ruby/rigor-survey/_mastodon-sweep"
TAGS = %w[
  v4.5.0-beta.1 v4.5.0-beta.2 v4.5.0-rc.1 v4.5.0-rc.2 v4.5.0-rc.3
  v4.5.0 v4.5.1 v4.5.2 v4.5.3 v4.5.4 v4.5.5 v4.5.6 v4.5.7 v4.5.8
  v4.5.9 v4.5.10
].freeze
# ---------------------------------------------------------------------

rows = []
TAGS.each do |tag|
  jf = "#{SWEEP}/reports/#{tag}.json"
  ef = "#{SWEEP}/reports/#{tag}.err"
  next unless File.exist?(jf) && File.size(jf).positive?

  diags = (JSON.parse(File.read(jf))["diagnostics"] || [])
  sev = Hash.new(0)
  diags.each { |d| sev[d["severity"]] += 1 }
  silenced = (File.exist?(ef) ? File.read(ef) : "")[/(\d+) diagnostic\(s\) silenced/, 1].to_i
  rows << { tag: tag, surfaced: diags.size, silenced: silenced,
            raw: diags.size + silenced, error: sev["error"],
            warning: sev["warning"], info: sev["info"], diags: diags }
end

puts format("%-17s %6s %9s %9s %7s %7s %6s",
            "tag", "raw", "silenced", "SURFACED", "error", "warn", "info")
puts "-" * 64
rows.each do |r|
  puts format("%-17s %6d %9d %9d %7d %7d %6d",
              r[:tag], r[:raw], r[:silenced], r[:surfaced],
              r[:error], r[:warning], r[:info])
end

puts "\nSurfaced-diagnostic rule breakdown (tags with surfaced > 0):"
hit = false
rows.each do |r|
  next if r[:surfaced].zero?

  hit = true
  by_rule = r[:diags].group_by { |d| d["rule"] || "(none)" }
                     .transform_values(&:size)
                     .sort_by { |a| -a[1] }
  puts "  #{r[:tag]}: #{by_rule.map { |rule, c| "#{rule}×#{c}" }.join('  ')}"
end
puts "  (none — surfaced stayed 0 across every tag)" unless hit
