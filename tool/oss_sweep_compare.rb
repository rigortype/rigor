#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare a fresh OSS sweep result against stored thresholds. Exits 0 (pass) or 1 (regression).
#
# Usage:
#   ruby tool/oss_sweep_compare.rb \
#     --diagnostics-json PATH \
#     --coverage-json PATH \
#     --thresholds-json PATH \
#     [--write-thresholds PATH]
#
# If --write-thresholds is given and the thresholds file is uncalibrated ("calibrated": false), this script writes fresh
# thresholds derived from the current run and exits 0.

require "json"
require "optparse"

options = { diagnostics: nil, coverage: nil, thresholds: nil, write: nil }

OptionParser.new do |opts|
  opts.on("--diagnostics-json PATH") { |v| options[:diagnostics] = v }
  opts.on("--coverage-json PATH")    { |v| options[:coverage] = v }
  opts.on("--thresholds-json PATH")  { |v| options[:thresholds] = v }
  opts.on("--write-thresholds PATH") { |v| options[:write] = v }
end.parse!

abort "Missing --diagnostics-json" unless options[:diagnostics]
abort "Missing --coverage-json"    unless options[:coverage]
abort "Missing --thresholds-json"  unless options[:thresholds]

diag_data     = JSON.parse(File.read(options[:diagnostics]))
coverage_data = JSON.parse(File.read(options[:coverage]))
thresholds    = JSON.parse(File.read(options[:thresholds]))

current_diagnostics     = diag_data["diagnostics"]&.size || 0
current_precision_ratio = coverage_data.dig("summary", "precise_ratio") || 0.0

# First-run calibration: thresholds not yet set from a real run.
unless thresholds["calibrated"]
  fresh = {
    "calibrated" => true,
    "calibrated_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "max_diagnostics" => current_diagnostics,
    "min_precision_ratio" => current_precision_ratio
  }
  out_path = options[:write] || options[:thresholds]
  File.write(out_path, JSON.pretty_generate(fresh) + "\n")
  puts "First run — thresholds calibrated:"
  puts "  max_diagnostics:    #{fresh['max_diagnostics']}"
  puts "  min_precision_ratio: #{fresh['min_precision_ratio']}"
  exit 0
end

max_diag    = thresholds["max_diagnostics"]
min_prec    = thresholds["min_precision_ratio"]
regressions = []

if current_diagnostics > max_diag
  regressions << "FAIL diagnostics: #{current_diagnostics} > threshold #{max_diag} " \
                 "(+#{current_diagnostics - max_diag} new)"
else
  puts "OK   diagnostics: #{current_diagnostics} ≤ #{max_diag}"
end

if current_precision_ratio < min_prec
  drop = ((min_prec - current_precision_ratio) * 100).round(2)
  regressions << "FAIL precision: #{(current_precision_ratio * 100).round(2)}% < " \
                 "threshold #{(min_prec * 100).round(2)}% (-#{drop}pp)"
else
  puts "OK   precision: #{(current_precision_ratio * 100).round(2)}% ≥ #{(min_prec * 100).round(2)}%"
end

if regressions.empty?
  puts "All OSS sweep checks passed."
  exit 0
else
  warn "OSS sweep regressions detected:"
  regressions.each { |r| warn "  #{r}" }
  exit 1
end
