# frozen_string_literal: true

# THROWAWAY — issue #345 spike. Reads the JSON dump produced by `Rigor::UnusedProbe`
# (lib/rigor/unused_probe.rb) and reports project-owned constants that no resolved constant
# reference ever pointed at.
#
#   ruby tool/unused_probe/report.rb PROBE.json [--root DIR] [--limit N] [--json]
#
# Correctness guards (each ABORTS rather than reporting a number it cannot stand behind):
#   * workers != 0        — per-file references accumulated in a worker process and were lost.
#   * cache_enabled       — a cache HIT file is never re-analyzed and contributes zero references.
#   * zero references     — the probe never fired; the run did not reach the choke point at all.

require "json"
require "optparse"

options = { root: nil, limit: nil, json: false }
parser = OptionParser.new do |opts|
  opts.banner = "usage: ruby tool/unused_probe/report.rb PROBE.json [options]"
  opts.on("--root DIR", "restrict declarations to this directory prefix (default: the analyzed file set)") do |v|
    options[:root] = v
  end
  opts.on("--limit N", Integer, "show only the first N candidates") { |v| options[:limit] = v }
  opts.on("--json", "emit machine-readable JSON instead of the text report") { options[:json] = true }
  opts.on("--allow-cache", "do not abort when the run had a cache store attached (UNSAFE)") do
    options[:allow_cache] = true
  end
end
parser.parse!
path = ARGV.shift or abort(parser.banner)

data = JSON.parse(File.read(path))

def summarize_paths(paths)
  return paths.join(", ") if paths.size <= 3

  "#{paths.first(3).join(', ')} (+#{paths.size - 3} more)"
end

def die(message)
  warn "unused-probe: REFUSING TO REPORT — #{message}"
  exit 2
end

workers = data["workers"]
unless workers.nil? || workers.to_i.zero?
  die("run used workers=#{workers}; references from worker processes never reached the dump. " \
      "Re-run with --workers=0.")
end
unless options[:allow_cache] || data["cache_enabled"] == false
  die("run had a persistent cache store attached; cached files are not re-analyzed and contribute " \
      "zero references. Re-run with --no-cache.")
end
references = data.fetch("references")
rbs_references = data.fetch("rbs_references", {})
die("zero constant references recorded; the probe never fired.") if references.empty?

analyzed = data.fetch("analyzed_files").to_set

# --- declaration ownership -------------------------------------------------------------------
# The predicate: a declaration is PROJECT-OWNED when its source file is a member of this run's
# expanded analysis file set (optionally further restricted by --root). Declarations reached only
# through RBS, bundled stdlib signatures, or a gem never pass through `ScopeIndexer.index` at all,
# so they are absent from the tables by construction.
root_prefix = options[:root] && (options[:root].chomp("/") + "/")

def owned?(paths, analyzed, root_prefix)
  paths.any? do |p|
    next false unless analyzed.empty? || analyzed.include?(p)
    next true unless root_prefix

    p.start_with?(root_prefix)
  end
end

declared = {} # fqn => { kind: , paths: [] }
data.fetch("declared_classes").each do |name, paths|
  next unless owned?(paths, analyzed, root_prefix)

  declared[name] = { "kind" => "class/module", "paths" => paths }
end
data.fetch("declared_constants").each do |name, paths|
  next unless owned?(paths, analyzed, root_prefix)

  entry = declared[name]
  if entry
    entry["kind"] = "class/module+value"
    entry["paths"] = (entry["paths"] + paths).uniq
  else
    declared[name] = { "kind" => "value", "paths" => paths }
  end
end

# `class Sub < Base` and `include Mod` are recorded AS WRITTEN by the discovery pre-pass, not as a
# resolved FQN (a superclass never reaches `resolve_constant_type` at all — measured in fixture3).
# Resolve each edge the way Ruby's lexical lookup would, against the DECLARED set: try the
# subclass's own namespace path from most-qualified down to the bare name, first declared name wins.
def resolve_lexically(from, written, declared_names)
  return written if written.start_with?("::") && declared_names.include?(written.delete_prefix("::"))

  prefix = from.split("::")
  while prefix.any?
    cand = (prefix + [written]).join("::")
    return cand if declared_names.include?(cand)

    prefix.pop
  end
  written
end

declared_names = declared.keys.to_set
structural = Set.new
data.fetch("structural_edges", {}).each do |from, names|
  names.each { |written| structural << resolve_lexically(from, written, declared_names) }
end

referenced = (references.keys + rbs_references.keys + structural.to_a).to_set
candidates = declared.reject { |name, _| referenced.include?(name) }

# A candidate that is a strict namespace prefix of some resolved reference (`A::B` when `A::B::C`
# was resolved) is very likely a probe ARTIFACT rather than a dead constant: the engine resolved
# the full path in one step and never recorded the intermediate segment.
prefixes = Set.new
referenced.each do |fqn|
  parts = fqn.split("::")
  (1...parts.size).each { |i| prefixes << parts[0, i].join("::") }
end
artifacts, real = candidates.partition { |name, _| prefixes.include?(name) }
# MEASURED LIMITATION (fixture2): a VALUE constant declared in one file and read from another
# never resolves — `Scope#in_source_constants` is per-file and the cross-file project seed carries
# only `discovered_classes`, so `resolve_constant_type` returns nil and records nothing. Every
# value-constant candidate is therefore suspect; class/module candidates are not affected (the
# class table IS seeded cross-file).
split = real.partition { |_, e| e["kind"] == "value" }
value_candidates = split[0]
class_candidates = split[1]

if options[:json]
  # `bucket` is the tier the text report prints the candidate under, so a downstream stage filter
  # (tool/unused_probe/stages.rb) does not have to re-derive the ownership + prefix logic.
  bucket = {}
  artifacts.each { |n, _| bucket[n] = "prefix_artifact" }
  value_candidates.each { |n, _| bucket[n] = "value" }
  class_candidates.each { |n, _| bucket[n] = "class" }
  puts JSON.pretty_generate(
    "declared_owned" => declared.size,
    "referenced_distinct" => referenced.size,
    "candidates" => candidates.size,
    "candidates_prefix_of_reference" => artifacts.size,
    "candidates_value_kind" => value_candidates.size,
    "candidates_class_kind" => class_candidates.size,
    "candidates_list" => candidates.map { |n, e| { "name" => n, "bucket" => bucket[n] }.merge(e) }
  )
  exit 0
end

def section(title, rows, limit)
  puts
  puts "-- #{title} (#{rows.size}) --"
  rows.first(limit || rows.size).each_with_index do |(name, entry), i|
    puts format("%3d  %-62s %-18s %s", i + 1, name, entry["kind"], summarize_paths(entry["paths"]))
  end
end

puts "probe:              #{path}"
puts "cwd:                #{data['cwd']}"
puts "analyzed files:     #{analyzed.size}"
puts "workers:            #{workers.inspect}   cache_enabled: #{data['cache_enabled'].inspect}"
puts "declared (owned):   #{declared.size}"
puts "distinct refs:      #{referenced.size}   " \
     "(source: #{references.size} names / #{references.values.sum} resolutions, " \
     "rbs: #{rbs_references.size} names, structural: #{structural.size} names)"
puts "CANDIDATES:         #{candidates.size}"
puts "  namespace-prefix of a resolved reference (artifact):      #{artifacts.size}"
puts "  value constants (UNRELIABLE — a cross-file, parameter-default,"
puts "  or lambda-body value read does not resolve):              #{value_candidates.size}"
puts "  class / module constants (the trustworthy tier):          #{class_candidates.size}"

section("class/module candidates", class_candidates, options[:limit])
section("value-constant candidates", value_candidates, options[:limit])
section("namespace-prefix artifacts", artifacts, options[:limit])
