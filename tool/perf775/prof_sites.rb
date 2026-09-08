# frozen_string_literal: true

# Allocation-site census over a sample of analysed files: every Nth `analyze_file_body` runs under
# ObjectSpace.trace_object_allocations with GC disabled, so every object allocated in the window survives
# to be counted. Aggregated by (engine source file, allocating method), by class, and by file:line.
#
# Usage: bundle exec ruby prof_sites.rb ENGINE_ROOT TARGET_ROOT [target] [every]

require 'json'
require 'stringio'
require 'objspace'

root = File.expand_path(ARGV[0] || '.')
target_root = File.expand_path(ARGV[1] || root)
target = ARGV[2] || 'lib'
every = (ARGV[3] || '4').to_i
Dir.chdir(target_root)
$LOAD_PATH.unshift(File.join(root, 'lib'))
require 'rigor/cli'
require 'rigor'
require 'rigor/analysis/runner'

module Census
  BY_METHOD = Hash.new(0)
  BY_CLASS = Hash.new(0)
  BY_LINE = Hash.new(0)
  STATS = { files: 0, sampled: 0, window_alloc: 0, enumerated: 0, total_alloc: 0 }
  ROOT_PREFIX = nil

  def self.rel(file)
    return 'nil' unless file

    if file.start_with?(ENGINE_ROOT)
      file[ENGINE_ROOT.length + 1..]
    elsif (i = file.index('/gems/'))
      file[i + 6..]
    else
      file
    end
  end

  def self.sample
    GC.start
    GC.disable
    ObjectSpace.trace_object_allocations_start
    before = GC.stat(:total_allocated_objects)
    yield
  ensure
    after = GC.stat(:total_allocated_objects)
    ObjectSpace.trace_object_allocations_stop
    n = 0
    ObjectSpace.each_object do |obj|
      file = ObjectSpace.allocation_sourcefile(obj)
      next unless file

      n += 1
      line = ObjectSpace.allocation_sourceline(obj)
      meth = ObjectSpace.allocation_method_id(obj)
      cpath = ObjectSpace.allocation_class_path(obj)
      key = "#{rel(file)} #{cpath}##{meth}"
      BY_METHOD[key] += 1
      BY_LINE["#{rel(file)}:#{line}"] += 1
      BY_CLASS[obj.class.name || obj.class.inspect] += 1
    rescue StandardError
      nil
    end
    ObjectSpace.trace_object_allocations_clear
    GC.enable
    STATS[:sampled] += 1
    STATS[:window_alloc] += after - before
    STATS[:enumerated] += n
  end

  def self.report(top = 60)
    puts "files=#{STATS[:files]} sampled=#{STATS[:sampled]} window_alloc=#{STATS[:window_alloc]} " \
         "enumerated=#{STATS[:enumerated]} (#{(100.0 * STATS[:enumerated] / [STATS[:window_alloc],
                                                                             1].max).round(1)}%) " \
         "run_total=#{STATS[:total_alloc]}"
    puts "\n== by (file, class#method) top #{top} =="
    BY_METHOD.sort_by { |_, v| -v }.first(top).each { |k, v| puts format('%12d  %s', v, k) }
    puts "\n== by class top 25 =="
    BY_CLASS.sort_by { |_, v| -v }.first(25).each { |k, v| puts format('%12d  %s', v, k) }
    puts "\n== by file:line top #{top} =="
    BY_LINE.sort_by { |_, v| -v }.first(top).each { |k, v| puts format('%12d  %s', v, k) }
    puts "\n== by engine file top 40 =="
    by_file = Hash.new(0)
    BY_METHOD.each { |k, v| by_file[k.split(' ', 2).first] += v }
    by_file.sort_by { |_, v| -v }.first(40).each { |k, v| puts format('%12d  %s', v, k) }
  end
end
Census.const_set(:ENGINE_ROOT, root)

sampler = Module.new do
  define_method(:analyze_file_body) do |path, environment|
    Census::STATS[:files] += 1
    if (Census::STATS[:files] % every).zero?
      result = nil
      Census.sample { result = super(path, environment) }
      result
    else
      super(path, environment)
    end
  end
end
Rigor::Analysis::Runner.prepend(sampler)

out = StringIO.new
err = StringIO.new
GC.start
before = GC.stat(:total_allocated_objects)
begin
  Rigor::CLI.new(['check', '--no-cache', '--no-stats', '--format', 'json', target], out: out, err: err).run
rescue SystemExit
  nil
end
Census::STATS[:total_alloc] = GC.stat(:total_allocated_objects) - before
puts "engine=#{root} target_root=#{target_root} every=#{every} rbs=#{RBS::VERSION}"
Census.report
