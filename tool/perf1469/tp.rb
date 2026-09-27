# usage: tp.rb ENGINE_ROOT OUT.json -- exclusive allocations and call counts per Ruby method, whole run
engine_root = File.expand_path(ARGV.fetch(0))
out_path = ARGV.fetch(1)
$LOAD_PATH.unshift(File.expand_path("lib", engine_root))
require "rigor/cli"; require "json"; require "stringio"
SYM = :total_allocated_objects
EXCL = Hash.new { |h, k| h[k] = Hash.new(0) }   # defined_class => {method_id => exclusive}
CALLS = Hash.new { |h, k| h[k] = Hash.new(0) }
stack = []  # [start, child]
overhead = 0
tp = TracePoint.new(:call, :return) do |t|
  a = GC.stat(SYM)
  now = a - overhead
  if t.event == :call
    stack.push([now, 0])
  else
    fr = stack.pop
    if fr
      tot = now - fr[0]
      EXCL[t.defined_class][t.method_id] += tot - fr[1]
      CALLS[t.defined_class][t.method_id] += 1
      stack.last[1] += tot if stack.last
    end
  end
  overhead += GC.stat(SYM) - a
end
out = StringIO.new; err = StringIO.new
GC.start
b = GC.stat(SYM)
tp.enable
begin
  Rigor::CLI.new(["check", "--no-cache", "--no-stats", "--format", "json", "lib"], out: out, err: err).run
rescue SystemExit
end
tp.disable
total = GC.stat(SYM) - b - overhead
rows = {}
EXCL.each do |k, h|
  h.each { |m, v| rows["#{k}##{m}"] = [v, CALLS[k][m]] }
end
File.write(out_path, JSON.generate(total: total, rows: rows, cli: $LOADED_FEATURES.grep(%r{rigor/cli\.rb\z})))
puts "total=#{total} overhead=#{overhead} methods=#{rows.size} cli=#{$LOADED_FEATURES.grep(%r{rigor/cli\.rb\z}).first[-60..]}"
