#!/usr/bin/env ruby
# frozen_string_literal: true

# Compares two snapshots of a `data/builtins/ruby_core/<topic>.yml`
# catalog and prints the surface-level diff: per-class additions
# / removals / purity changes / arity changes / cfunc renames.
#
# The motivating use is a `references/ruby` submodule bump: when
# CRuby moves its public API around, individual cfunc names (and
# occasionally classifications) shift. The full YAML diff is
# noisy because it interleaves prose comments, RBS pulls, and
# `defined_at` line numbers; this tool extracts the catalog-
# semantic deltas that a reviewer actually has to look at.
#
# Usage:
#
#   ruby tool/catalog_diff.rb BEFORE.yml AFTER.yml
#
#   make catalog-diff BEFORE=tmp/before.yml AFTER=tmp/after.yml
#
# Typical workflow:
#
#   git stash                                 # park current YAML
#   make extract-builtin-catalogs > /dev/null # regenerate
#   cp data/builtins/ruby_core/time.yml /tmp/after.yml
#   git stash pop                              # restore baseline
#   ruby tool/catalog_diff.rb data/builtins/ruby_core/time.yml /tmp/after.yml

require "yaml"
require "set"

if ARGV.size != 2
  warn "Usage: ruby tool/catalog_diff.rb BEFORE.yml AFTER.yml"
  exit 1
end

before_path, after_path = ARGV
[before_path, after_path].each do |path|
  unless File.file?(path)
    warn "[catalog-diff] not found: #{path}"
    exit 1
  end
end

before = YAML.safe_load_file(before_path, permitted_classes: [Symbol])
after = YAML.safe_load_file(after_path, permitted_classes: [Symbol])

# Compares two `instance_methods` / `singleton_methods` hashes
# under a single class and yields the diff records. Each record
# is `[kind, *details]` where `kind` is one of:
#
# - `:added`   — selector present only in `after`.
# - `:removed` — selector present only in `before`.
# - `:purity_changed` — same selector, different `purity`.
# - `:cfunc_renamed`  — same selector, different `cfunc`.
# - `:arity_changed`  — same selector, different `arity`.
def each_method_diff(before_methods, after_methods)
  before_methods ||= {}
  after_methods ||= {}
  selectors = (before_methods.keys + after_methods.keys).uniq.sort

  selectors.each do |selector|
    b = before_methods[selector]
    a = after_methods[selector]
    if b.nil?
      yield(:added, selector, a)
    elsif a.nil?
      yield(:removed, selector, b)
    else
      yield(:purity_changed, selector, b["purity"], a["purity"]) if b["purity"] != a["purity"]
      yield(:cfunc_renamed, selector, b["cfunc"], a["cfunc"]) if b["cfunc"] && a["cfunc"] && b["cfunc"] != a["cfunc"]
      yield(:arity_changed, selector, b["arity"], a["arity"]) if b["arity"] != a["arity"]
    end
  end
end

before_classes = before["classes"] || {}
after_classes = after["classes"] || {}

added_classes = after_classes.keys - before_classes.keys
removed_classes = before_classes.keys - after_classes.keys
common_classes = before_classes.keys & after_classes.keys

total_changes = 0

unless added_classes.empty?
  total_changes += added_classes.size
  puts "Added classes:"
  added_classes.sort.each { |c| puts "  + #{c}" }
end

unless removed_classes.empty?
  total_changes += removed_classes.size
  puts "Removed classes:"
  removed_classes.sort.each { |c| puts "  - #{c}" }
end

common_classes.sort.each do |class_name|
  before_class = before_classes[class_name]
  after_class = after_classes[class_name]
  records = []

  %w[instance_methods singleton_methods].each do |bucket_name|
    each_method_diff(before_class[bucket_name], after_class[bucket_name]) do |kind, selector, *details|
      records << [bucket_name, kind, selector, *details]
    end
  end

  next if records.empty?

  total_changes += records.size
  puts "#{class_name}:"
  records.each do |bucket, kind, selector, *details|
    prefix = "  [#{bucket.sub('_methods', '')}] #{selector}"
    case kind
    when :added then puts "  + #{bucket.sub('_methods', '').rjust(9)} #{selector} (new, purity=#{details[0]['purity']})"
    when :removed then puts "  - #{bucket.sub('_methods', '').rjust(9)} #{selector} (gone)"
    when :purity_changed then puts "    #{prefix}: purity #{details[0]} → #{details[1]}"
    when :cfunc_renamed then puts "    #{prefix}: cfunc #{details[0]} → #{details[1]}"
    when :arity_changed then puts "    #{prefix}: arity #{details[0]} → #{details[1]}"
    end
  end
end

if total_changes.zero?
  puts "No catalog-level differences."
end
