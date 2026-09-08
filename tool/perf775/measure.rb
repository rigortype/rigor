# In-process `rigor check --no-cache --no-stats --format json lib` from the CURRENT tree: prints allocations,
# writes stdout JSON to ARGV[0] for byte-identity diffing.
require "json"; require "stringio"
root = Dir.pwd
$LOAD_PATH.unshift(File.join(root, "lib")); require "rigor/cli"
out = StringIO.new; err = StringIO.new
GC.start
before = GC.stat(:total_allocated_objects)
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
begin
  Rigor::CLI.new(["check", "--no-cache", "--no-stats", "--format", "json", ARGV[1] || "lib"], out: out, err: err).run
rescue SystemExit
end
wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
alloc = GC.stat(:total_allocated_objects) - before
File.write(ARGV[0], out.string)
puts "allocations=#{alloc} wall=#{wall.round(2)}s diagnostics=#{JSON.parse(out.string).fetch('diagnostics', []).size rescue 'n/a'} stderr_bytes=#{err.string.bytesize}"
