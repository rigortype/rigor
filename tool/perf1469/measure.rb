engine_root = File.expand_path(ARGV.fetch(0))
$LOAD_PATH.unshift(File.expand_path("lib", engine_root))
require "rigor/cli"; require "json"; require "stringio"
out = StringIO.new; err = StringIO.new
GC.start
b = GC.stat(:total_allocated_objects); t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
status = nil
begin
  status = Rigor::CLI.new(["check", "--no-cache", "--no-stats", "--format", "json", "lib"], out: out, err: err).run
rescue SystemExit => e
  status = e.status
end
a = GC.stat(:total_allocated_objects) - b
w = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
diags = begin
  j = JSON.parse(out.string)
  d = j.is_a?(Hash) ? (j["diagnostics"] || j["results"] || []) : j
  d.size
rescue StandardError => e
  "ERR(#{e.class})"
end
rigor_feats = $LOADED_FEATURES.grep(%r{/rigor/})
wrong = rigor_feats.reject { |f| f.start_with?(engine_root + "/") || !f.include?("/lib/rigor") }
cli = $LOADED_FEATURES.grep(%r{rigor/cli\.rb\z})
File.write(ARGV.fetch(1), out.string) if ARGV[1]
puts JSON.generate(alloc: a, wall: w.round(2), diags: diags, status: status, cli: cli, wrong: wrong.first(5), wrong_n: wrong.size, err: err.string[0, 300])
