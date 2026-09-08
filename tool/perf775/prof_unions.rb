# Where do wide unions come from? Wrap Combinator.union, bucket by caller for arity >= 10.
root = File.expand_path(ARGV[0]); target_root = File.expand_path(ARGV[1]); target = ARGV[2] || 'lib'
Dir.chdir(target_root); $LOAD_PATH.unshift(File.join(root, 'lib'))
require 'rigor/cli'; require 'rigor'; require 'rigor/analysis/runner'; require 'stringio'
WIDE = Hash.new(0); TOTAL = Hash.new(0); ARITY = Hash.new(0)
lib = File.join(root, 'lib') + '/'
mod = Module.new do
  define_method(:union) do |*members|
    n = members.size
    ARITY[n] += 1
    if n >= 10
      locs = caller_locations(1, 6).map { |l| "#{l.path.sub(lib, '')}:#{l.lineno} #{l.label}" }
      WIDE[locs.join(' <- ')] += 1
    end
    super(*members)
  end
end
Rigor::Type::Combinator.singleton_class.prepend(mod)
out = StringIO.new; err = StringIO.new
begin
  Rigor::CLI.new(['check', '--no-cache', '--no-stats', '--format', 'json', target], out: out, err: err).run
rescue SystemExit
end
puts "engine=#{root} union calls=#{ARITY.values.sum} wide(>=10)=#{WIDE.values.sum}"
puts "arity histogram: " + ARITY.sort.map { |k, v| "#{k}:#{v}" }.join(' ')
puts "\n== wide-union call stacks (top 40) =="
WIDE.sort_by { |_, v| -v }.first(40).each { |k, v| puts format("%8d  %s", v, k) }
