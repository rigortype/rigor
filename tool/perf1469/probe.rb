# usage: probe.rb ENGINE_ROOT OUT.json [census]
engine_root = File.expand_path(ARGV.fetch(0))
out_path = ARGV.fetch(1)
census = ARGV[2] == "census"
$LOAD_PATH.unshift(File.expand_path("lib", engine_root))
require "rigor/cli"; require "json"; require "stringio"; require "objspace"
PerFile = Hash.new(0)
Sites = Hash.new(0)
$depth = 0
ROOT = engine_root + "/"
def tally!
  g = GC.count
  ObjectSpace.each_object do |o|
    next unless ObjectSpace.allocation_generation(o) == g
    f = ObjectSpace.allocation_sourcefile(o) or next
    f = f.start_with?(ROOT) ? f.delete_prefix(ROOT) : f.sub(%r{.*/gems/}, "gems/")
    Sites["#{f}:#{ObjectSpace.allocation_sourceline(o)} #{o.class rescue '?'}"] += 1
  end
end
require "rigor/analysis/runner"
Windows = Hash.new(0)
HOOKS = (ENV["PROBE_HOOKS"] || "Rigor::Analysis::Runner#analyze_file_body").split(",")
HOOKS.each do |spec|
  cname, meth = spec.split("#")
  req = ENV["PROBE_REQUIRE"]; req&.split(",")&.each { require _1 }
  klass = Object.const_get(cname)
  meth = meth.to_sym
  per_file = meth == :analyze_file_body
  klass.prepend(Module.new do
    define_method(meth) do |*args, **kw, &blk|
      return super(*args, **kw, &blk) if $depth > 0
      $depth += 1
      if census
        GC.start; GC.disable; ObjectSpace.trace_object_allocations_start
      end
      b = GC.stat(:total_allocated_objects)
      begin
        super(*args, **kw, &blk)
      ensure
        d = GC.stat(:total_allocated_objects) - b
        Windows[spec] += d
        PerFile[args.first.to_s.sub(%r{.*/t039/}, "")] += d if per_file
        if census
          ObjectSpace.trace_object_allocations_stop
          tally!
          GC.enable
        end
        $depth -= 1
      end
    end
  end)
end
out = StringIO.new; err = StringIO.new
GC.start
b = GC.stat(:total_allocated_objects)
begin
  Rigor::CLI.new(["check", "--no-cache", "--no-stats", "--format", "json", "lib"], out: out, err: err).run
rescue SystemExit
end
total = GC.stat(:total_allocated_objects) - b
File.write(out_path, JSON.generate(total: total, windows: Windows, per_file_sum: PerFile.values.sum, files: PerFile.size, per_file: PerFile, sites: Sites.sort_by { -_2 }.first(20000).to_h,
  cli: $LOADED_FEATURES.grep(%r{rigor/cli\.rb\z})))
puts "total=#{total} windows=#{Windows} per_file_sum=#{PerFile.values.sum} files=#{PerFile.size} cli=#{$LOADED_FEATURES.grep(%r{rigor/cli\.rb\z}).first}"
