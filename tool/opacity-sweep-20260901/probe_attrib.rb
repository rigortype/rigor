# frozen_string_literal: true

# probe_attrib.rb — driver-side opacity-attribution probe (2026-09-01 corpus sweep).
# READ-ONLY: never modifies the rigor repo or the target. Mirrors the precision lens
# (CoverageScan seeding, PrecisionScanner walk + classifier) but uses the PLUGIN-AWARE
# environment (like `coverage --protection`), so a hole a plugin already closes is not
# counted. Records, for every opaque (:dynamic_top / :top) expression:
#   - node class histogram
#   - LocalVariableReadNode: def-param / block-param / assigned-local bucket
#   - CallNode: receiver tier; for a PRECISE receiver whose call still lands opaque,
#     the (receiver type, method) pair with counts + examples  ← the "named receiver,
#     Dynamic dispatch" hole the 2026-08-31 audit flagged as the real remainder.
#
# Usage (cwd MUST be the rigor repo root so bundler resolves vendor/bundle):
#   bundle exec ruby probe_attrib.rb TARGET_DIR OUT_JSON [PATH...]
# PATHs are relative to TARGET_DIR; default = the target config's `paths:`.

RIGOR_ROOT = Dir.pwd
target = File.expand_path(ARGV.fetch(0))
out_json = File.expand_path(ARGV.fetch(1))
extra_paths = ARGV[2..] || []

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
args = extra_paths.empty? ? configuration.paths : extra_paths
files = args.flat_map do |arg|
  if File.directory?(arg)
    Dir.glob(File.join(arg, '**/*.rb'))
  elsif File.file?(arg)
    [arg]
  else
    warn "probe: not a file or directory: #{arg}"
    exit 1
  end
end.uniq.sort

environment = Rigor::LanguageServer::ProjectContext.new(configuration: configuration).environment
scope = Rigor::CLI::CoverageScan.discovery_seeded_scope(
  files: files, configuration: configuration, environment: environment,
  parameter_inference: configuration.parameter_inference
)
scanner = Rigor::Inference::PrecisionScanner.new(scope: scope)
non_expr = Rigor::Inference::PrecisionScanner.const_get(:NON_EXPRESSION_NODE_TYPES)

PRECISE = %i[constant nominal shaped refined bot].to_set
OPAQUE = %i[dynamic_top top].to_set

def param_names(params_owner)
  return [] unless params_owner

  names = []
  collect = lambda do |n|
    return unless n.is_a?(Prism::Node)

    names << n.name if n.respond_to?(:name) && n.name.is_a?(Symbol)
    n.child_nodes.compact.each { |c| collect.call(c) }
  end
  collect.call(params_owner)
  names
end

stats = {
  'files' => 0, 'parse_errors' => 0, 'total' => 0,
  'tier_counts' => Hash.new(0),
  'opaque_node_classes' => Hash.new(0),
  'local_read_buckets' => Hash.new(0),
  'call_receiver_tiers' => Hash.new(0),
  'opaque_ivar_reads' => 0
}
pairs = Hash.new { |h, k| h[k] = { 'count' => 0, 'examples' => [] } }
dynamic_recv_methods = Hash.new(0)      # method names on already-Dynamic receivers (propagation)
implicit_self_methods = Hash.new(0)     # opaque implicit-self sends

files.each do |path|
  source = File.read(path)
  parse_result = Prism.parse(source, filepath: path, version: configuration.target_ruby)
  if parse_result.errors.any?
    stats['parse_errors'] += 1
    next
  end
  stats['files'] += 1
  root = parse_result.value
  scope_index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)

  Rigor::Source::NodeWalker.each_with_ancestors(root) do |node, ancestors|
    next if non_expr.include?(node.class.name)

    type = scope_index[node].type_of(node)
    tier = scanner.send(:classify, type)
    stats['tier_counts'][tier.to_s] += 1
    stats['total'] += 1
    next unless OPAQUE.include?(tier)

    stats['opaque_node_classes'][node.class.name.sub('Prism::', '')] += 1

    case node
    when Prism::LocalVariableReadNode
      name = node.name
      bucket = 'assigned_local'
      ancestors.reverse_each do |anc|
        case anc
        when Prism::DefNode
          bucket = 'def_param' if param_names(anc.parameters).include?(name)
          break
        when Prism::BlockNode, Prism::LambdaNode
          if param_names(anc.parameters).include?(name)
            bucket = 'block_param'
            break
          end
        end
      end
      stats['local_read_buckets'][bucket] += 1
    when Prism::InstanceVariableReadNode
      stats['opaque_ivar_reads'] += 1
    when Prism::CallNode
      recv = node.receiver
      if recv.nil?
        stats['call_receiver_tiers']['implicit_self'] += 1
        implicit_self_methods[node.name.to_s] += 1
      else
        rtype = scope_index[recv].type_of(recv)
        rtier = scanner.send(:classify, rtype)
        if PRECISE.include?(rtier)
          stats['call_receiver_tiers']['precise'] += 1
          disp = rtype.describe(:short).to_s
          disp = "#{disp[0, 57]}..." if disp.length > 60
          key = "#{disp}##{node.name}"
          pairs[key]['count'] += 1
          line = node.location.start_line
          pairs[key]['examples'] << "#{path}:#{line}" if pairs[key]['examples'].size < 3
        else
          stats['call_receiver_tiers'][rtier.to_s] += 1
          dynamic_recv_methods[node.name.to_s] += 1 if OPAQUE.include?(rtier)
        end
      end
    end
  end
end

precise = PRECISE.sum { |t| stats['tier_counts'][t.to_s] }
result = stats.merge(
  'target' => target,
  'scanned_paths' => args,
  'parameter_inference' => configuration.parameter_inference,
  'precise' => precise,
  'precision_ratio' => stats['total'].zero? ? 1.0 : (precise.to_f / stats['total']).round(4),
  'named_receiver_opaque_pairs' => pairs.sort_by { |_, v| -v['count'] }.first(80).to_h,
  'dynamic_receiver_methods_top' => dynamic_recv_methods.sort_by { |_, c| -c }.first(40).to_h,
  'implicit_self_methods_top' => implicit_self_methods.sort_by { |_, c| -c }.first(40).to_h
)

File.write(out_json, JSON.pretty_generate(result))
puts "probe: #{stats['files']} files, #{stats['total']} exprs, precise #{result['precision_ratio']}, " \
     "named-receiver-opaque pairs #{pairs.size} (#{pairs.sum { |_, v| v['count'] }} sites) -> #{out_json}"
