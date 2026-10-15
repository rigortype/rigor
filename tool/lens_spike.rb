# frozen_string_literal: true

# ADR-113 WD2 spike — can a lens read the seeded per-file index the `check` path builds, and what does it cost?
#
#   cd <project> && BUNDLE_GEMFILE=<rigor>/Gemfile bundle exec ruby -I<rigor>/lib <rigor>/tool/lens_spike.rb \
#     [--config FILE] [--workers N] [--rows] FILE...
#
# Runs `IncrementalSession#run_incremental` against the project's own roots (`configuration.paths`, so the snapshot
# fingerprint is the one `rigor check --incremental` writes) with the targets forced into the recheck and an index
# callback. A cold run is a pooled baseline, after which the targets are not yet captured (a pooled file is indexed
# in a worker), so one more forced recheck captures them in process. Prints per-phase wall time, whether each target
# was captured, its diagnostics count, and with `--rows` a declaration row per class / module / def / attr.
#
# Not a product surface: it is the instrument for docs/notes/20261015-lens-computation-spike.md.

require "optparse"
require "json"
require "rigor"
require "rigor/cli"
require "rigor/cli/check_runner_factory"

options = { config: nil, workers: nil, rows: false, skip_templates: false }
OptionParser.new do |o|
  o.on("--config FILE") { |v| options[:config] = v }
  o.on("--workers N", Integer) { |v| options[:workers] = v }
  o.on("--rows") { options[:rows] = true }
  # Sizing probe only: drops #392's always-re-analysed template units from the run. The run is then NOT the check
  # run, so point it at a throwaway cache copy.
  o.on("--skip-templates") { options[:skip_templates] = true }
end.parse!(ARGV)
abort "usage: lens_spike.rb [--config FILE] [--workers N] [--rows] FILE..." if ARGV.empty?

# Declaration rows for one indexed file — the spike's stand-in for the lens row builder. Spelling is the bare
# erasure; provenance is read off the RBS member's buffer name.
class SpikeRows
  def initialize(path, parse_result, scope, index, signature_roots)
    @path = path
    @root = parse_result.value
    @scope = scope
    @index = index
    @signature_roots = signature_roots
    @rows = []
  end

  def build
    walk(@root, [], singleton: false)
    @rows
  end

  private

  def walk(node, nesting, singleton:)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      name = qualify(nesting, node.constant_path.slice)
      @rows << row(kind: node.is_a?(Prism::ClassNode) ? "class" : "module", owner: nil, name: name, node: node)
      node.body && walk(node.body, nesting + [name], singleton: false)
    when Prism::SingletonClassNode
      node.body && walk(node.body, nesting, singleton: node.expression.is_a?(Prism::SelfNode))
    when Prism::DefNode
      def_row(node, nesting, singleton)
    when Prism::StatementsNode
      node.body.each do |child|
        attr_rows(child, nesting) if child.is_a?(Prism::CallNode)
        walk(child, nesting, singleton: singleton)
      end
    when Prism::ProgramNode
      walk(node.statements, nesting, singleton: singleton)
    end
  end

  def qualify(nesting, slice)
    return slice.delete_prefix("::") if slice.start_with?("::") || nesting.empty?

    "#{nesting.last}::#{slice}"
  end

  def def_row(node, nesting, singleton)
    owner = nesting.last || "Object"
    kind = if node.receiver.nil?
             singleton ? :singleton : :instance
           elsif node.receiver.is_a?(Prism::SelfNode)
             :singleton
           end
    if kind.nil?
      return @rows << row(kind: "method", owner: owner, name: node.name.to_s, node: node,
                          status: "unsupported_receiver")
    end

    declared = declared_method(owner, node.name, kind)
    inferred = Rigor::Inference::DefReturnTyper.call(node, @index)
    @rows << row(kind: kind == :singleton ? "singleton_method" : "method", owner: owner, name: node.name.to_s,
                 node: node, declared: declared, inferred: inferred&.erase_to_rbs)
  end

  def attr_rows(call, nesting)
    return unless call.receiver.nil? && %i[attr_reader attr_writer attr_accessor].include?(call.name)
    return if nesting.empty?

    (call.arguments&.arguments || []).each_with_index do |arg, ordinal|
      next unless arg.is_a?(Prism::SymbolNode)

      declared = declared_method(nesting.last, arg.unescaped.to_sym, :instance)
      @rows << row(kind: call.name.to_s, owner: nesting.last, name: arg.unescaped, node: call, ordinal: ordinal,
                   declared: declared)
    end
  end

  def declared_method(owner, name, kind)
    method = if kind == :singleton
               Rigor::Reflection.singleton_method_definition(owner, name, scope: @scope)
             else
               Rigor::Reflection.instance_method_definition(owner, name, scope: @scope)
             end
    return nil if method.nil?

    buffer = method.defs.map { |d| d.member.location&.buffer&.name.to_s }.first
    { types: method.method_types.map(&:to_s), provenance: provenance(buffer.to_s),
      inferred_return: method.annotations.any? { |a| a.string.include?("inferred-return") } }
  rescue StandardError => e
    { error: e.class.name }
  end

  def provenance(buffer)
    return "inline" if buffer.start_with?("virtual:rbs-inline:")
    return "plugin:#{buffer.split(':', 3)[1]}" if buffer.start_with?("virtual:")
    return "unknown(cached)" if buffer.empty? || buffer.include?("<cached>")
    return "sig" if @signature_roots.any? { |root| File.expand_path(buffer).start_with?(root) }

    "library"
  end

  def row(kind:, owner:, name:, node:, ordinal: nil, declared: nil, inferred: nil, status: nil) # rubocop:disable Metrics/ParameterLists
    { kind: kind, owner: owner, name: name, lines: [node.location.start_line, node.location.end_line],
      ordinal: ordinal, declared: declared, inferred: inferred, status: status }.compact
  end
end

if options[:skip_templates]
  Rigor::Analysis::Runner.prepend(Module.new do
    def template_unit_targets(files) = files
  end)
end

clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
started = clock.call
phases = {}

configuration = Rigor::Configuration.load(options[:config])
cache_root = configuration.cache_path
fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: configuration.paths)
snapshot = Rigor::Cache::IncrementalSnapshot.new(root: cache_root)
store = Rigor::Cache::Store.new(root: cache_root, max_bytes: configuration.cache_max_bytes)
workers = options[:workers] || Rigor::CLI::CheckRunnerFactory.resolve_workers({ workers: nil }, configuration)
signature_roots = Rigor::Environment.project_signature_roots(configuration.signature_paths).map { |p| File.expand_path(p.to_s) }
targets = ARGV.map { |p| File.expand_path(p) }

captured = {}
callback = lambda do |path, parse_result, scope, index|
  next unless targets.include?(File.expand_path(path))

  t = clock.call
  rows = options[:rows] ? SpikeRows.new(path, parse_result, scope, index, signature_roots).build : nil
  captured[File.expand_path(path)] = { rows: rows, row_seconds: clock.call - t }
end

session = Rigor::Analysis::IncrementalSession.new(
  configuration: configuration, cache_store: store, workers: workers,
  force_targets: [], on_file_indexed: callback
)
forced = session.send(:current_files).select { |path| targets.include?(File.expand_path(path)) }
missing = targets - forced.map { |p| File.expand_path(p) }
session.instance_variable_set(:@force_targets, forced.to_set)
phases[:setup] = clock.call - started

t = clock.call
diagnostics, warm = session.run_incremental(snapshot: snapshot, fingerprint: fingerprint)
phases[warm ? :warm_recheck : :cold_baseline] = clock.call - t

unless forced.all? { |path| captured.key?(File.expand_path(path)) }
  t = clock.call
  diagnostics = session.recheck.diagnostics
  phases[:forced_recheck] = clock.call - t
end
phases[:total] = clock.call - started

report = {
  project: Dir.pwd, files: session.analyzed_files.size, workers: workers, warm: warm,
  phases: phases.transform_values { |s| s.round(3) },
  outside_project: missing,
  targets: forced.map do |path|
    key = File.expand_path(path)
    entry = captured[key]
    { path: path, captured: !entry.nil?, row_seconds: entry && entry[:row_seconds].round(4),
      diagnostics: diagnostics.count { |d| File.expand_path(d.path.to_s) == key },
      diagnostic_rows: diagnostics.select { |d| File.expand_path(d.path.to_s) == key }
                                  .map { |d| [d.line, d.column, d.message] }.sort,
      rows: entry && entry[:rows] }.compact
  end
}
puts JSON.pretty_generate(report)
