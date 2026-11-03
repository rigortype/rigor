#!/usr/bin/env ruby
# frozen_string_literal: true

# Lists the plugin integration spec files one CI shard runs (`make test-integration-plugins PLUGIN_SHARD=i/n`).
#
# The files are `spec/integration/plugins/*_spec.rb` and `spec/integration/examples/*_spec.rb`, which the default
# suite excludes. The ADR-128 plugin-boundary gate roughly doubles their run, so CI splits them across jobs.
# The split is a pure function of the file names and sizes: largest file first, each onto the lightest bucket so
# far (ties to the lowest index), so every job computes the same partition without a timing cache to agree on, and
# a new file lands in exactly one shard. Bytes stand in for runtime; a file is the scheduling unit, as in binpacker.
#
# Usage: ruby tool/plugin_integration_shard.rb [I/N]   (prints one path per line; no argument lists every file)
module PluginIntegrationShard
  PATTERNS = %w[spec/integration/plugins/*_spec.rb spec/integration/examples/*_spec.rb].freeze

  module_function

  def all(root = Dir.pwd)
    PATTERNS.flat_map { |pattern| Dir.glob(File.join(root, pattern)) }.sort.map { |path| path.delete_prefix("#{root}/") }
  end

  # The bucket (0-based `index`) of `count` that `files` partition into.
  def partition(files, count, root = Dir.pwd)
    buckets = Array.new(count) { { size: 0, files: [] } }
    files.sort_by { |file| [-File.size(File.join(root, file)), file] }.each do |file|
      bucket = buckets.min_by.with_index { |entry, index| [entry[:size], index] }
      bucket[:size] += File.size(File.join(root, file))
      bucket[:files] << file
    end
    buckets.map { |bucket| bucket[:files].sort }
  end

  def shard(spec, root = Dir.pwd)
    files = all(root)
    return files if spec.nil? || spec.empty?

    index, count = spec.split("/").map { |part| Integer(part) }
    raise ArgumentError, "shard must be I/N with 1 <= I <= N, got #{spec.inspect}" unless count&.positive? && index&.between?(1, count)

    partition(files, count, root)[index - 1]
  end
end

puts PluginIntegrationShard.shard(ARGV[0]) if $PROGRAM_NAME == __FILE__
