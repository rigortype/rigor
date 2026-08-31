# frozen_string_literal: true

# probe_unsupported.rb — enumerate WHICH constructs the :unsupported_syntax cause covers on a target.
# READ-ONLY over the target; plugin-aware environment (same harness as probe_attrib.rb).
# For every expression whose recorded dynamic origin is :unsupported_syntax, bucket it:
#   - non-CallNode  -> the Prism node class IS the unmodeled construct (plus: constant reads)
#   - CallNode, receiver nil      -> implicit-self send that exhausted dispatch (method histogram)
#   - CallNode, receiver precise  -> named-receiver send that exhausted dispatch (Type#method histogram)
#   - CallNode, receiver Dynamic  -> carried provenance (chain), counted but not a construct
# Also reports which Prism node classes present in the corpus have NO PRISM_DISPATCH handler.
#
# Usage (cwd = rigor repo root): bundle exec ruby probe_unsupported.rb TARGET_DIR OUT_JSON

RIGOR_ROOT = Dir.pwd
target = File.expand_path(ARGV.fetch(0))
out_json = File.expand_path(ARGV.fetch(1))

lib = File.join(RIGOR_ROOT, 'lib')
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'rigor/cli'
require 'rigor/language_server/project_context'
require 'rigor/cli/coverage_scan'
require 'rigor/inference/precision_scanner'
require 'rigor/source/node_walker'
require 'json'

Dir.chdir(target)

configuration = Rigor::Configuration.load(nil)
files = configuration.paths.flat_map { |arg| Dir.glob(File.join(arg, '**/*.rb')) }.uniq.sort

environment = Rigor::LanguageServer::ProjectContext.new(configuration: configuration).environment
scope = Rigor::CLI::CoverageScan.discovery_seeded_scope(
  files: files, configuration: configuration, environment: environment,
  parameter_inference: configuration.parameter_inference
)
scanner = Rigor::Inference::PrecisionScanner.new(scope: scope)
non_expr = Rigor::Inference::PrecisionScanner.const_get(:NON_EXPRESSION_NODE_TYPES)
dispatch_table = Rigor::Inference::ExpressionTyper.const_get(:PRISM_DISPATCH)

PRECISE = %i[constant nominal shaped refined bot].to_set
OPAQUE = %i[dynamic_top top].to_set

node_class_hist = Hash.new(0)              # non-CallNode unsupported_syntax nodes
node_class_examples = Hash.new { |h, k| h[k] = [] }
implicit_self = Hash.new(0)
implicit_self_examples = Hash.new { |h, k| h[k] = [] }
typed_recv = Hash.new(0)
typed_recv_examples = Hash.new { |h, k| h[k] = [] }
carried_chain = 0
dynamic_recv_methods = Hash.new(0)
unhandled_classes_seen = Hash.new(0)       # node classes in corpus with no dispatch handler
total_unsupported = 0

files.each do |path|
  source = File.read(path)
  parse_result = Prism.parse(source, filepath: path, version: configuration.target_ruby)
  next if parse_result.errors.any?

  root = parse_result.value
  scope_index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)

  Rigor::Source::NodeWalker.each_with_ancestors(root) do |node, _ancestors|
    next if non_expr.include?(node.class.name)

    sc = scope_index[node]
    type = sc.type_of(node)
    tier = scanner.send(:classify, type)
    unless dispatch_table.key?(node.class) || node.is_a?(Rigor::AST::Node)
      unhandled_classes_seen[node.class.name.sub('Prism::',
                                                 '')] += 1
    end
    next unless OPAQUE.include?(tier)

    cause = sc.dynamic_origins[node]
    next unless cause == :unsupported_syntax

    total_unsupported += 1
    line = "#{path}:#{node.location.start_line}"
    if node.is_a?(Prism::CallNode)
      recv = node.receiver
      if recv.nil?
        implicit_self[node.name.to_s] += 1
        implicit_self_examples[node.name.to_s] << line if implicit_self_examples[node.name.to_s].size < 3
      else
        rtype = scope_index[recv].type_of(recv)
        rtier = scanner.send(:classify, rtype)
        if PRECISE.include?(rtier)
          disp = rtype.describe(:short).to_s
          disp = "#{disp[0, 57]}..." if disp.length > 60
          key = "#{disp}##{node.name}"
          typed_recv[key] += 1
          typed_recv_examples[key] << line if typed_recv_examples[key].size < 3
        else
          carried_chain += 1
          dynamic_recv_methods[node.name.to_s] += 1
        end
      end
    else
      key = node.class.name.sub('Prism::', '')
      node_class_hist[key] += 1
      node_class_examples[key] << line if node_class_examples[key].size < 3
    end
  end
end

sorted = ->(h) { h.sort_by { |_, c| -c }.to_h }
result = {
  'total_unsupported_origin_nodes' => total_unsupported,
  'non_call_node_classes' => sorted.call(node_class_hist),
  'non_call_examples' => node_class_examples.transform_values { |v| v },
  'implicit_self_unresolved' => sorted.call(implicit_self).first(40).to_h,
  'implicit_self_examples' => implicit_self_examples.sort_by { |k, _| -implicit_self[k] }.first(15).to_h,
  'typed_receiver_unresolved' => sorted.call(typed_recv).first(40).to_h,
  'typed_receiver_examples' => typed_recv_examples.sort_by { |k, _| -typed_recv[k] }.first(15).to_h,
  'carried_chain_call_nodes' => carried_chain,
  'carried_chain_methods_top' => sorted.call(dynamic_recv_methods).first(20).to_h,
  'corpus_node_classes_without_handler' => sorted.call(unhandled_classes_seen)
}
File.write(out_json, JSON.pretty_generate(result))
puts "unsupported probe: #{total_unsupported} nodes -> #{out_json}"
