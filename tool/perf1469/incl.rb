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
    b = GC.stat(:total_allocated_objects)
    SIZES[[members.size, 6].min] += 1
    members.each { |m| KINDS[m.class.name.split("::").last] += 1 }
    r = super
    INCL[:sort_members] += GC.stat(:total_allocated_objects) - b - 0
    $d -= 1
    r
  end
end)
out = StringIO.new; err = StringIO.new
begin
  Rigor::CLI.new(["check", "--no-cache", "--no-stats", "--format", "json", "lib"], out: out, err: err).run
rescue SystemExit
end
p INCL, SIZES.sort.to_h, KINDS.sort_by { -_2 }.first(12).to_h
