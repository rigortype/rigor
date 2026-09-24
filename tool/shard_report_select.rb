#!/usr/bin/env ruby
# frozen_string_literal: true

# The front half of CI's `shard-coverage` job: choose which run report stands for each shard, and refuse a
# set of reports that were not cut from one timing file.
#
# `binpacker shards-check` trusts the reports it is handed to be the ones that ran. A partial rerun breaks
# that. "Re-run failed jobs" re-runs one shard while its siblings' reports stay from the earlier attempt,
# and that shard used to restore a NEWER timing cache than they did (they saved theirs at the end of the
# first attempt), so it cut a different partition — the silent-skip hazard the check exists for. On run
# 35844873791 it went further: every attempt uploaded under the same
# artifact name, `download-artifact` resolved the duplicate `binpacker-report-2` to the FIRST attempt's
# stale report (it keeps the highest artifact ID per name, and IDs do not follow creation order),
# shards-check passed "3 shards cover all 506 tests", and a deterministic spec failure that the rerun's
# new bin no longer held went green.
#
# So each shard now uploads `binpacker-report-<shard>-attempt-<n>` holding its run report plus a
# provenance record: the shard, the attempt, the cache key it restored, and the SHA-256 of the timing
# file it restored before it ran. This script takes the newest attempt per shard — the report of the
# attempt that actually ran it — and fails unless every chosen shard restored the same timing file.
# Given one timing file the cut is deterministic, so matching digests are what makes reports from
# different attempts one partition; a differing digest means the slices may overlap or leave tests out,
# whatever their counts sum to. The workflow's timing-cache job makes the digests agree by construction;
# this is the backstop for when that fails.
#
# Newest-per-shard is sound only because a green shard always uploads: the provenance record is written
# before the tests start, and the upload runs `if: always()`. A shard that ran but uploaded nothing failed,
# which the `CI required` fan-in already refuses through the `test` result.
#
# Usage: ruby tool/shard_report_select.rb DOWNLOAD_DIR OUTPUT_DIR
#   DOWNLOAD_DIR is download-artifact's unmerged output: one directory per artifact, or the files at its
#   top level when only one artifact matched.
#   OUTPUT_DIR receives the chosen `binpacker-report-<shard>.json` files for `binpacker shards-check`.

require "fileutils"
require "json"

module ShardReportSelect
  Provenance = Data.define(:dir, :shard, :attempt, :timings_sha256, :timings_key)

  class Error < StandardError; end

  module_function

  # The newest attempt of each shard, ordered by shard index.
  def choose(download_dir)
    paths = Dir.glob(File.join(download_dir, "**", "binpacker-provenance-*.json"))
    records = paths.map { |path| read_provenance(path) }
    raise Error, "no shard provenance records under #{download_dir}" if records.empty?

    chosen = records.group_by(&:shard).sort.map { |shard, entries| newest(shard, entries) }
    check_one_timing_file(chosen)
    chosen
  end

  def read_provenance(path)
    data = JSON.parse(File.read(path))
    shard, attempt, digest, key = data.values_at("shard", "run_attempt", "timings_sha256", "timings_key")
    unless shard.is_a?(Integer) && attempt.is_a?(Integer) && digest.is_a?(String)
      raise Error, "#{path}: expected integer shard and run_attempt and a string timings_sha256"
    end
    unless File.basename(path) == "binpacker-provenance-#{shard}.json"
      raise Error, "#{path}: records shard #{shard}, which its file name contradicts"
    end

    Provenance.new(dir: File.dirname(path), shard: shard, attempt: attempt, timings_sha256: digest,
                   timings_key: key.to_s)
  rescue JSON::ParserError => e
    raise Error, "#{path}: not valid JSON (#{e.message})"
  end

  def newest(shard, entries)
    latest = entries.map(&:attempt).max
    candidates = entries.select { |e| e.attempt == latest }
    raise Error, "shard #{shard} uploaded more than one report in attempt #{latest}" if candidates.size > 1

    candidates.first
  end

  def check_one_timing_file(chosen)
    return if chosen.map(&:timings_sha256).uniq.size <= 1

    lines = chosen.map { |p| "  #{describe(p)}" }
    cause =
      if chosen.map(&:attempt).uniq.size > 1
        "A re-run shard restored a different timing file than the shards kept from an earlier attempt."
      else
        "The shards of one attempt restored different timing files."
      end
    raise Error, <<~MSG
      the shards partitioned different timing files, so their slices need not cover the suite:
      #{lines.join("\n")}
      #{cause} Re-run ALL jobs so every shard cuts the same partition.
    MSG
  end

  def describe(provenance)
    key = provenance.timings_key.empty? ? "no cache" : provenance.timings_key
    "shard #{provenance.shard}: attempt #{provenance.attempt}, timings #{provenance.timings_sha256} (#{key})"
  end

  # Copies each chosen report into `output_dir`, failing when a shard's attempt produced none.
  def stage(chosen, output_dir)
    FileUtils.mkdir_p(output_dir)
    chosen.each do |p|
      report = File.join(p.dir, "binpacker-report-#{p.shard}.json")
      unless File.file?(report)
        raise Error,
              "shard #{p.shard} attempt #{p.attempt} uploaded no run report — binpacker stopped before writing it"
      end

      FileUtils.cp(report, File.join(output_dir, File.basename(report)))
    end
  end

  def main(argv)
    download_dir, output_dir = argv
    unless download_dir && output_dir && argv.size == 2
      warn "usage: #{$PROGRAM_NAME} DOWNLOAD_DIR OUTPUT_DIR"
      return 2
    end

    chosen = choose(download_dir)
    stage(chosen, output_dir)
    chosen.each { |p| puts describe(p) }
    0
  rescue Error => e
    warn "shard report selection failed: #{e.message}"
    1
  end
end

exit ShardReportSelect.main(ARGV) if $PROGRAM_NAME == __FILE__
