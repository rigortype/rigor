engine_root = File.expand_path(ARGV.fetch(0))
$LOAD_PATH.unshift(File.expand_path("lib", engine_root))
require "rigor/cli"; require "json"; require "stringio"
require "rigor/type/combinator"
INCL = Hash.new(0); SIZES = Hash.new(0); KINDS = Hash.new(0)
$d = 0
Rigor::Type::Combinator.singleton_class.prepend(Module.new do
  def sort_members(members)
    return super if $d > 0
    $d += 1
    # The tally runs OUTSIDE the measured window: only `super` is counted.
    b = GC.stat(:total_allocated_objects)
    r = super
    INCL[:sort_members] += GC.stat(:total_allocated_objects) - b
    INCL[:sort_calls] += 1
    INCL[:members] += members.size
    SIZES[[members.size, 6].min] += 1
    members.each { |m| KINDS[m.class] += 1 }
    $d -= 1
    r
  end
end)
# Per-caller split of ScopeIndexer.rebound_self_base: allocations measured around `super` only;
# the caller label is read after the window closes.
require "rigor/inference/scope_indexer"
RSB = Hash.new { |h, k| h[k] = [0, 0] }
Rigor::Inference::ScopeIndexer.singleton_class.prepend(Module.new do
  def rebound_self_base(owner)
    b = GC.stat(:total_allocated_objects)
    r = super
    a = GC.stat(:total_allocated_objects) - b
    e = RSB[caller_locations(1, 1).first.label]
    e[0] += a; e[1] += 1
    r
  end
end)
out = StringIO.new; err = StringIO.new
begin
  Rigor::CLI.new(["check", "--no-cache", "--no-stats", "--format", "json", "lib"], out: out, err: err).run
rescue SystemExit
end
p INCL, SIZES.sort.to_h, KINDS.sort_by { -_2 }.first(12).to_h.transform_keys { _1.name }
p RSB
