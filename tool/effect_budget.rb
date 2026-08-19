#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR-103 WD13 / #409 — what does turning effect collection ON cost?
#
# The graduation criterion for effects-default-on is a re-verification of WD13's working budget,
# "≤ ~5 % wall / RSS on mastodon", **at the release** — the figures were measured when only opted-in
# projects paid the cost, and default-on changes the population the budget has to hold for.
#
# Method, and why each part is there:
#
# - **Interleaved A/B** (off, on, off, on, …) rather than blocked (off×N then on×N). A CI runner drifts
#   — a noisy neighbour, thermal state, a cache warming somewhere — and blocked runs charge all of that
#   drift to whichever arm ran during it. Interleaving splits it evenly. This was not hypothetical: the
#   first local attempt at this measurement was blocked, and an unrelated process taking a core partway
#   through moved one arm by 2x.
# - **Median, plus the full range.** One outlier run is normal on shared hardware and must not decide a
#   release gate; a range that OVERLAPS between the arms is the signal that the reps were too few, and
#   is reported rather than hidden behind the median.
# - **`--no-cache`, and the cache directory removed between runs.** A warm slot serves an unanalysed
#   result in milliseconds, which would read as a spectacular improvement (ADR-45).
# - **Both arms use the same config apart from `effects:`.** The variant configs are generated here from
#   one base file rather than committed as two, so they cannot drift apart.
#
# Usage:
#   ruby tool/effect_budget.rb --target /tmp/mastodon --base-config data/oss-sweep/mastodon-rigor.yml \
#     [--reps 5] [--bound-pct 5.0] [--json OUT] [--gate]
#
# Exits 0 unless `--gate` is given AND a metric exceeds the bound. Advisory by default, following the
# perf-bench precedent (ADR-50 WD6): a measurement earns the power to fail a release only once its band
# is known to be stable on the measuring host.

require "fileutils"
require "json"
require "optparse"
require "tmpdir"

options = {
  target: nil, base_config: nil, reps: 5, bound_pct: 5.0, json: nil, gate: false,
  rigor_root: File.expand_path("..", __dir__)
}
OptionParser.new do |o|
  o.on("--target PATH") { |v| options[:target] = v }
  o.on("--base-config PATH") { |v| options[:base_config] = v }
  o.on("--reps N", Integer) { |v| options[:reps] = v }
  o.on("--bound-pct F", Float) { |v| options[:bound_pct] = v }
  o.on("--json PATH") { |v| options[:json] = v }
  o.on("--gate") { options[:gate] = true }
end.parse!

abort("--target is required") unless options[:target]
abort("--base-config is required") unless options[:base_config]

ROOT = options[:rigor_root]
TARGET = File.expand_path(options[:target])
BASE = File.read(options[:base_config])

abort("base config already sets `effects:` — the A/B needs a base with it absent") if BASE.match?(/^effects:/)

# One config per arm, so the only difference is the one line under test.
#
# They are written INSIDE the target, not into a tmpdir: a config's relative `paths:` resolve against
# the config file's own directory, so a config parked elsewhere analyses nothing and the whole
# measurement completes in 0.2 s looking like a spectacular improvement. {assert_analysed!} exists
# because that is exactly what the first version of this script did.
def write_variants(target)
  off = File.join(target, ".rigor.budget-off.yml")
  on  = File.join(target, ".rigor.budget-on.yml")
  File.write(off, BASE)
  File.write(on, "#{BASE}\neffects: {}\n")
  [off, on]
end

# Rigor reports its own wall time and peak RSS, which is what "measured as the corpus perf notes
# measure" refers to; parsing them keeps this comparable with the notes rather than with `/usr/bin/time`.
WALL_RE  = /Wall time:\s*([0-9.]+)s/
RSS_RE   = /Memory peak:\s*([0-9.]+)\s*MB/
FILES_RE = /Ruby source files:\s*([0-9]+)/

# A measurement over zero files is not a fast run, it is no run. Both arms must actually analyse the
# corpus, and they must analyse the SAME corpus — an arm that silently sees a different file count is
# comparing two projects.
def assert_analysed!(arm, files, out)
  return if files&.positive?

  warn(out)
  abort("#{arm} arm analysed #{files.inspect} files — the config resolved no paths, so this measures nothing")
end

def run_once(config, cache_dir)
  FileUtils.rm_rf(cache_dir)
  cmd = [
    "bundle", "exec", File.join(ROOT, "exe", "rigor"), "check",
    "--config", config, "--no-cache", "--no-baseline"
  ]
  out = IO.popen({ "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile") }, cmd,
                 chdir: TARGET, err: [:child, :out], &:read)
  [out[WALL_RE, 1]&.to_f, out[RSS_RE, 1]&.to_f, out[FILES_RE, 1]&.to_i, out]
end

def median(values)
  sorted = values.compact.sort
  return nil if sorted.empty?

  mid = sorted.size / 2
  sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

def pct_delta(base, now)
  return nil if base.nil? || now.nil? || base.zero?

  ((now - base) / base) * 100.0
end

samples = { "off" => { wall: [], rss: [] }, "on" => { wall: [], rss: [] } }

off_config, on_config = write_variants(TARGET)
cache = File.join(TARGET, ".rigor", "cache")
file_counts = {}

begin
  options[:reps].times do |rep|
    { "off" => off_config, "on" => on_config }.each do |arm, config|
      wall, rss, files, out = run_once(config, cache)
      assert_analysed!(arm, files, out)
      (file_counts[arm] ||= []) << files
      samples[arm][:wall] << wall
      samples[arm][:rss] << rss
      warn(format("[rep %d %s] wall=%s rss=%s files=%d", rep + 1, arm, wall || "NA", rss || "NA", files))
    end
  end
ensure
  FileUtils.rm_f([off_config, on_config])
end

seen = file_counts.values.flatten.uniq
abort("arms analysed different file counts (#{seen.inspect}) — not a comparison") unless seen.size == 1

result = { "target" => File.basename(TARGET), "reps" => options[:reps],
           "bound_pct" => options[:bound_pct], "files" => seen.first }
%i[wall rss].each do |metric|
  off = samples["off"][metric]
  on = samples["on"][metric]
  m_off = median(off)
  m_on = median(on)
  result[metric.to_s] = {
    "off_median" => m_off, "on_median" => m_on,
    "off_range" => [off.compact.min, off.compact.max],
    "on_range" => [on.compact.min, on.compact.max],
    "delta_pct" => pct_delta(m_off, m_on),
    # Ranges that overlap mean the reps cannot separate the arms; the delta is then a number without a
    # finding behind it, and saying so is the whole point of carrying the ranges.
    "separated" => [off.compact.max, on.compact.min].none?(&:nil?) && off.compact.max < on.compact.min
  }
end

puts JSON.pretty_generate(result)
File.write(options[:json], JSON.pretty_generate(result)) if options[:json]

%w[wall rss].each do |metric|
  row = result[metric]
  delta = row["delta_pct"]
  next puts("#{metric}: no measurement") if delta.nil?

  verdict = delta <= options[:bound_pct] ? "within" : "OVER"
  puts format("%-4s %s bound: %+.1f%% (bound %.1f%%), off median %.2f, on median %.2f, separated=%s",
              metric, verdict, delta, options[:bound_pct], row["off_median"], row["on_median"],
              row["separated"])
end

if options[:gate]
  over = %w[wall rss].select do |metric|
    row = result[metric]
    row["delta_pct"] && row["delta_pct"] > options[:bound_pct] && row["separated"]
  end
  unless over.empty?
    warn("WD13 budget exceeded on: #{over.join(', ')}")
    exit 1
  end
end
