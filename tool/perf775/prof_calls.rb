# frozen_string_literal: true

# Per-method call counts over the whole run (TracePoint :call, engine lib/ only). Counts are
# allocation-independent facts, so an engine A/B on the same target shows which paths are
# exercised more often.
#
# Usage: bundle exec ruby prof_calls.rb ENGINE_ROOT TARGET_ROOT [target]

require 'json'
require 'stringio'

root = File.expand_path(ARGV[0] || '.')
target_root = File.expand_path(ARGV[1] || root)
target = ARGV[2] || 'lib'
Dir.chdir(target_root)
$LOAD_PATH.unshift(File.join(root, 'lib'))
require 'rigor/cli'
require 'rigor'
require 'rigor/analysis/runner'

engine_lib = File.join(root, 'lib') + '/'
counts = Hash.new { |h, k| h[k] = Hash.new(0) }
tp = TracePoint.new(:call) do |t|
  next unless t.path.start_with?(engine_lib)

  counts[t.defined_class][t.method_id] += 1
end

out = StringIO.new
err = StringIO.new
tp.enable
begin
  Rigor::CLI.new(['check', '--no-cache', '--no-stats', '--format', 'json', target], out: out, err: err).run
rescue SystemExit
  nil
ensure
  tp.disable
end

rows = []
counts.each { |klass, methods| methods.each { |m, n| rows << [n, "#{klass}##{m}"] } }
rows.sort_by! { |n, _| -n }
puts "engine=#{root} target_root=#{target_root} total_calls=#{rows.sum(&:first)} methods=#{rows.size}"
rows.each { |n, name| puts format('%12d  %s', n, name) }
