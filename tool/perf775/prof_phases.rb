# frozen_string_literal: true

# Exclusive-allocation phase probe for `rigor check --no-cache lib`, driver-side only
# (Module#prepend from outside the tree; nothing in the repo is modified).
#
# Usage: bundle exec ruby prof_phases.rb ROOT [target]
#   ROOT   the rigor checkout whose lib/ is loaded AND analysed (cwd is set to ROOT)
#
# Accounting: a region's exclusive allocations = its inclusive delta minus the inclusive deltas of every
# nested probed region. Stacks are parallel Arrays of scalars so the probe allocates nothing per call.

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
require 'rigor/analysis/check_rules'
require 'rigor/inference/parameter_inference_collector'
require 'rigor/plugin/loader'

module Probe
  LABELS = []
  STARTS = []
  CHILDREN = []
  EXCL = Hash.new(0)
  INCL = Hash.new(0)
  COUNT = Hash.new(0)

  def self.enter(label)
    LABELS.push(label)
    STARTS.push(GC.stat(:total_allocated_objects))
    CHILDREN.push(0)
  end

  def self.exit
    label = LABELS.pop
    start = STARTS.pop
    child = CHILDREN.pop
    incl = GC.stat(:total_allocated_objects) - start
    EXCL[label] += incl - child
    INCL[label] += incl
    COUNT[label] += 1
    CHILDREN[-1] += incl unless CHILDREN.empty?
  end

  # arity: :one => (a), :two => (a, b), :kw => (**kw), :fwd => (...)
  def self.wrap(owner, name, label, singleton: false, arity: :fwd)
    target = singleton ? owner.singleton_class : owner
    unless target.method_defined?(name, true) || target.private_method_defined?(name, true)
      warn "probe: #{owner}#{singleton ? '.' : '#'}#{name} not found, skipped"
      return
    end
    params, fwd =
      case arity
      when :one then %w[a a]
      when :two then ['a, b', 'a, b']
      when :three then ['a, b, c', 'a, b, c']
      when :kw then ['**kw', '**kw']
      else ['...', '...']
      end
    mod = Module.new
    mod.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
      def #{name}(#{params})
        Probe.enter(#{label.inspect})
        super(#{fwd})
      ensure
        Probe.exit
      end
    RUBY
    target.prepend(mod)
  end

  def self.report(total)
    puts format('%-44s %14s %8s %14s %8s', 'region (exclusive)', 'allocations', 'share', 'inclusive', 'calls')
    EXCL.sort_by { |_, v| -v }.each do |label, v|
      puts format('%-44s %14d %7.2f%% %14d %8d', label, v, 100.0 * v / total, INCL[label], COUNT[label])
    end
    accounted = EXCL.values.sum
    puts format('%-44s %14d %7.2f%%', '(unprobed remainder)', total - accounted, 100.0 * (total - accounted) / total)
    puts format('%-44s %14d', 'TOTAL', total)
  end
end

R = Rigor::Analysis::Runner
L = Rigor::Environment::RbsLoader
Probe.wrap(R, :run_analysis, 'run_analysis', arity: :one)
Probe.wrap(R, :run_project_pre_passes, 'pre_passes', arity: :kw)
Probe.wrap(R, :ensure_project_discovery, 'project_discovery', arity: :one)
Probe.wrap(R, :parse_source, 'parse_source', arity: :one)
Probe.wrap(R, :seed_project_scope, 'seed_project_scope', arity: :one)
Probe.wrap(R, :analyze_file_body, 'analyze_file_body', arity: :two)
Probe.wrap(Rigor::Environment, :for_project, 'Environment.for_project', singleton: true, arity: :kw)
Probe.wrap(L, :build_env_for, 'RbsLoader.build_env_for', singleton: true, arity: :kw)
Probe.wrap(L, :stub_missing_referenced_types, 'RbsLoader.stub_missing_referenced_types', singleton: true, arity: :three)
Probe.wrap(L, :build_instance_definition, 'RbsLoader#build_instance_definition', arity: :one)
Probe.wrap(L, :build_singleton_definition, 'RbsLoader#build_singleton_definition', arity: :one)
Probe.wrap(L, :prewarm, 'RbsLoader#prewarm', arity: :fwd)
Probe.wrap(Rigor::Inference::ScopeIndexer, :index, 'ScopeIndexer.index', singleton: true, arity: :fwd)
Probe.wrap(Rigor::Inference::StatementEvaluator, :evaluate, 'StatementEvaluator#evaluate', arity: :one)
Probe.wrap(Rigor::Inference::ExpressionTyper, :type_of, 'ExpressionTyper#type_of', arity: :one)
Probe.wrap(Rigor::Inference::MethodDispatcher, :dispatch, 'MethodDispatcher#dispatch', arity: :kw)
Probe.wrap(Rigor::Analysis::CheckRules, :diagnose, 'CheckRules.diagnose', singleton: true, arity: :kw)
Probe.wrap(Rigor::Inference::ParameterInferenceCollector, :collect, 'ParameterInferenceCollector.collect',
           singleton: true, arity: :kw)
Probe.wrap(Rigor::Plugin::Loader, :load, 'Plugin::Loader.load', singleton: true, arity: :kw)

out = StringIO.new
err = StringIO.new
GC.start
before = GC.stat(:total_allocated_objects)
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
begin
  Rigor::CLI.new(['check', '--no-cache', '--no-stats', '--format', 'json', target], out: out, err: err).run
rescue SystemExit
  nil
end
wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
total = GC.stat(:total_allocated_objects) - before
diags = begin
  JSON.parse(out.string).fetch('diagnostics', []).size
rescue StandardError
  nil
end
puts "engine=#{root} target_root=#{target_root} target=#{target} wall=#{wall.round(2)}s diagnostics=#{diags} rbs=#{RBS::VERSION}"
Probe.report(total)
