#!/usr/bin/env ruby
# frozen_string_literal: true

# Issue #134 slice 3 — the acceptance gate for the per-file mutation-result cache: a WARM
# `rigor coverage --protection --mutation --format json` run must be byte-identical to the cold equivalent
# over a corpus.
#
# ADR-46 made this obligation mandatory for the incremental CHECK path (`--verify-incremental` /
# `make check-incremental`), and a cache that serves a per-file *measurement* inherits it: the number the
# cache serves is the number `--threshold` gates CI on, so "the warm run is a bit off" is indistinguishable
# from "the analyzer regressed" at the point where anyone reads it.
#
# Three arms, all over the same corpus and the same flags:
#
#   cold — `--no-cache`: every file measured from scratch, nothing read, nothing written.
#   fill — the cache empty: every file measured, every result written back.
#   warm — every file served from the cache.
#
# All three must agree on stdout, byte for byte. The warm arm must additionally report that it served the
# whole corpus — without that check the gate would pass trivially the day the cache silently disables itself
# (no snapshot, an opaque plugin, a key it cannot build), which is the failure mode the whole degradation
# design makes possible on purpose.
#
# What this gate deliberately does NOT do is edit the tree to exercise invalidation. That arm lives in the
# suite instead (`spec/rigor/cli/coverage_command_spec.rb`, "re-measures the edited file and its dependents"),
# where it runs against a throwaway fixture project rather than against the checkout the gate is measuring.
#
# Usage: bundle exec ruby tool/mutation_cache_gate.rb [--limit N] [PATH...]

require "English"
require "fileutils"
require "open3"

require_relative "../lib/rigor/configuration"

# Drives the three arms and reports. Kept as one object so the arms cannot drift in flags.
class MutationCacheGate
  RIGOR = File.expand_path("../exe/rigor", __dir__)

  # The warm arm's stderr line, which is also the non-vacuity proof.
  CACHE_LINE = /mutation cache — re-measured (\d+) file\(s\), (\d+) served from cache/

  def initialize(argv)
    @limit = nil
    @paths = []
    parse(argv)
  end

  def run
    warm_snapshot
    clear_mutation_entries

    cold = arm("cold", "--no-cache")
    fill = arm("fill")
    warm = arm("warm")

    ok = identical?(cold, fill, warm) & served_everything?(warm)
    puts("rigor: mutation-cache gate OK — warm == fill == cold over #{@paths.join(' ')}") if ok
    ok ? 0 : 1
  end

  private

  def parse(argv)
    until argv.empty?
      argument = argv.shift
      case argument
      when "--limit" then @limit = argv.shift
      when /\A--limit=(.+)\z/ then @limit = Regexp.last_match(1)
      else @paths << argument
      end
    end
    @paths = ["lib/rigor/protection"] if @paths.empty?
  end

  # The cache reads its per-file dependency edges from the ADR-46 snapshot, so the gate warms one for exactly
  # the roots it is about to measure. Without this the cache disables itself and every arm is cold — which
  # `served_everything?` would catch, but late and with a confusing message.
  #
  # The check's EXIT CODE is deliberately ignored: a corpus that is a SUBTREE of the project is analysed
  # without the rest of it in scope, so it may legitimately report diagnostics. What the gate needs from this
  # step is the snapshot, and that is what it asserts.
  def warm_snapshot
    system(RIGOR, "check", "--incremental", "--no-stats", *@paths, out: File::NULL)
    snapshot = File.join(Rigor::Configuration.load(nil).cache_path, "incremental", "snapshot.bin")
    return if File.file?(snapshot)

    abort("rigor: mutation-cache gate could not warm the incremental snapshot (#{snapshot} absent)")
  end

  # `fill` must genuinely start empty, or the gate would compare three warm runs. Only this producer's
  # entries are dropped — the RBS-environment and plugin-producer slices are unrelated to what is being
  # gated, and rebuilding them would triple the gate's wall time for nothing.
  def clear_mutation_entries
    root = Rigor::Configuration.load(nil).cache_path
    FileUtils.rm_rf(File.join(root, "protection.mutation-file-result"))
  end

  def arm(name, *extra)
    command = [RIGOR, "coverage", "--protection", "--mutation", "--format", "json", *sampling, *extra, *@paths]
    out, err, status = Open3.capture3(*command)
    abort("rigor: mutation-cache gate arm #{name} exited #{status.exitstatus}\n#{err}") unless status.success?
    warn("  #{name}: #{err[CACHE_LINE] || err.lines.grep(/mutation cache/).first&.strip}")
    { name: name, out: out, err: err }
  end

  def sampling
    @limit.nil? ? [] : ["--limit", @limit.to_s]
  end

  def identical?(cold, *others)
    mismatched = others.reject { |arm| arm[:out] == cold[:out] }
    return true if mismatched.empty?

    warn("rigor: mutation-cache gate FAILED — #{mismatched.map { |arm| arm[:name] }.join(', ')} " \
         "differ from the cold measurement.")
    warn(diff_hint(cold, mismatched.first))
    false
  end

  # A cache that serves a DIFFERENT number is the failure this gate exists to catch, so name the first line
  # that differs rather than dumping two JSON documents into the CI log.
  def diff_hint(cold, other)
    pair = cold[:out].lines.zip(other[:out].lines).find { |left, right| left != right }
    return "  (the two documents differ in length only)" if pair.nil?

    "  cold: #{pair[0].to_s.strip}\n  #{other[:name]}: #{pair[1].to_s.strip}"
  end

  # The warm arm must have re-measured NOTHING and served at least one file. A gate that cannot say "yes, the
  # cache was used" is not evidence about the cache.
  def served_everything?(warm)
    match = warm[:err][CACHE_LINE]
    remeasured, served = match && [Regexp.last_match(1).to_i, Regexp.last_match(2).to_i]
    return true if match && remeasured.zero? && served.positive?

    warn("rigor: mutation-cache gate FAILED — the warm arm did not serve the corpus from cache " \
         "(#{match || warm[:err].lines.grep(/mutation cache/).first&.strip || 'no cache report'}). " \
         "A vacuous pass is not a pass.")
    false
  end
end

exit(MutationCacheGate.new(ARGV).run) if $PROGRAM_NAME == __FILE__
