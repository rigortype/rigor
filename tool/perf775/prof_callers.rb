# Who calls Symbol#to_s (c_call) and RBS::Substitution.build / RBS::AST::TypeParam.* (call)? Aggregated by the
# nearest rigor lib/ caller frames.
root = File.expand_path(ARGV[0]); target_root = File.expand_path(ARGV[1]); target = ARGV[2] || 'lib'
Dir.chdir(target_root); $LOAD_PATH.unshift(File.join(root, 'lib'))
require 'rigor/cli'; require 'rigor'; require 'rigor/analysis/runner'; require 'stringio'
lib = File.join(root, 'lib') + '/'
SYM = Hash.new(0); SUB = Hash.new(0)
tp1 = TracePoint.new(:c_call) do |t|
  next unless t.method_id == :to_s && t.defined_class == Symbol
  loc = caller_locations(1, 3).find { |l| l.path.start_with?(lib) }
  SYM[loc ? "#{loc.path.sub(lib, '')}:#{loc.lineno} #{loc.label}" : 'outside'] += 1
end
tp2 = TracePoint.new(:call) do |t|
  next unless t.defined_class == RBS::Substitution.singleton_class && t.method_id == :build
  locs = caller_locations(1, 12).select { |l| l.path.start_with?(lib) }.first(2)
  SUB[locs.map { |l| "#{l.path.sub(lib, '')}:#{l.lineno} #{l.label}" }.join(' <- ')] += 1
end
out = StringIO.new; err = StringIO.new
tp1.enable; tp2.enable
begin
  Rigor::CLI.new(['check', '--no-cache', '--no-stats', '--format', 'json', target], out: out, err: err).run
rescue SystemExit
ensure
  tp1.disable; tp2.disable
end
puts "== Symbol#to_s callers (total #{SYM.values.sum}) =="
SYM.sort_by { |_, v| -v }.first(25).each { |k, v| puts format('%9d  %s', v, k) }
puts "\n== RBS::Substitution.build rigor-side callers (total #{SUB.values.sum}) =="
SUB.sort_by { |_, v| -v }.first(25).each { |k, v| puts format('%9d  %s', v, k) }
