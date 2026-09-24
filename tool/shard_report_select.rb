#!/usr/bin/env ruby
# frozen_string_literal: true

# The front half of CI's `shard-coverage` job: choose which run report stands for each shard, and refuse a
# set of reports that were not cut from one timing file.
#
# `binpacker shards-check` trusts the reports it is handed to be the ones that ran. A partial rerun breaks
# that. "Re-run failed jobs" re-runs one shard, which restores a NEWER timing cache than its siblings did
# (they saved theirs at the end of the first attempt) and so cuts a different partition — the silent-skip
# hazard the check exists for. On run 35844873791 it went further: every attempt uploaded under the same
# artifact name, `download-artifact` resolved the duplicate `binpacker-report-2` to the FIRST attempt's
# stale report, shards-check passed "3 shards cover all 506 tests", and a deterministic spec failure that
# the rerun's new bin no longer held went green.
#
# So each shard now uploads `binpacker-report-<shard>-attempt-<n>` holding its run report plus a
# provenance record: the shard, the attempt, and the SHA-256 of the timing file it restored before it ran.
# This script takes the newest attempt per shard — the report of the attempt that actually ran it — and
# fails unless every chosen shard restored the same timing file. Given one timing file the cut is
# deterministic, so matching digests are what makes reports from different attempts one partition; a
# differing digest means the slices may overlap or leave tests out, whatever their counts sum to.
#
# Newest-per-shard is sound only because a green shard always uploads: the provenance record is written
# before the tests start, and the upload runs `if: always()`. A shard that ran but uploaded nothing failed,
# which the `CI required` fan-in already refuses through the `test` result.
#
# Usage: ruby tool/shard_report_select.rb DOWNLOAD_DIR OUTPUT_DIR
#   DOWNLOAD_DIR holds one directory per artifact (download-artifact without `merge-multiple`).
#   OUTPUT_DIR receives the chosen `binpacker-report-<shard>.json` files for `binpacker shards-check`.

require "fileutils"
require "json"

module ShardReportSelect
  Provenance = Data.define(:dir, :shard, :attempt, :timings_sha256)

  class Error < StandardError; end

  module_function

  # @return [Array<Provenance>] the newest attempt of each shard, ordered by shard index
  def choose(download_dir)
    paths = Dir.glob(File.join(download_dir, "*", "binpacker-provenance-*.json"))
    records = paths.map { |path| read_provenance(path) }
    raise Error, "no shard provenance records under #{download_dir}" if records.empty?

    chosen = records.group_by(&:shard).sort.map { |shard, entries| newest(shard, entries) }
    check_one_timing_file(chosen)
    chosen
  end

  def read_provenance(path)
    data = JSON.parse(File.read(path))
    shard, attempt, digest = data.values_at("shard", "run_attempt", "timings_sha256")
    unless shard.is_a?(Integer) && attempt.is_a?(Integer) && digest.is_a?(String)
      raise Error, "#{path}: expected integer shard and run_attempt and a string timings_sha256"
    end

    Provenance.new(dir: File.dirname(path), shard: shard, attempt: attempt, timings_sha256: digest)
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

    lines = chosen.map { |p| "  shard #{p.shard}: attempt #{p.attempt}, timings #{p.timings_sha256}" }
    raise Error, <<~MSG
      the shards partitioned different timing files, so their slices need not cover the suite:
      #{lines.join("\n")}
      This is what "Re-run failed jobs" produces — a re-run shard restores a newer timing cache than the
      shards that already passed. Re-run ALL jobs so every shard cuts the same partition.
    MSG
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
    chosen.each { |p| puts "shard #{p.shard}: attempt #{p.attempt}, timings #{p.timings_sha256}" }
    0
  rescue Error => e
    warn "shard report selection failed: #{e.message}"
    1
  end
end

exit ShardReportSelect.main(ARGV) if $PROGRAM_NAME == __FILE__
