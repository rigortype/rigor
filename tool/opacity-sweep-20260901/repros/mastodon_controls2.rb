# frozen_string_literal: true

# mastodon_controls2.rb — second control round. READ-ONLY, cwd = rigor repo root.
# 1. Snippet controls: Account.new.id (AR column reader on a plain receiver).
# 2. Real-file check: the origin recorded at app/helpers/formatting_helper.rb:4 (#squish).
# 3. Corpus split of unresolved-constant nodes: child-of-resolving-ConstantPath (artifact)
#    vs terminal unresolved.

RIGOR_ROOT = Dir.pwd
target = '/Users/megurine/repo/ruby/rigor-survey/mastodon'

lib = File.join(RIGOR_ROOT, 'lib')
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'rigor/cli'
require 'rigor/language_server/project_context'
require 'rigor/cli/coverage_scan'
require 'rigor/inference/precision_scanner'
require 'rigor/source/node_walker'

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
OPAQUE = %i[dynamic_top top].to_set

# --- 1. snippet controls ---
{
  'Account.new.id' => 'Account.new.id',
  'Account.new.suspended?' => 'Account.new.suspended?',
  'Account.new.username' => 'Account.new.username',
  'Account.without_suspended (recheck)' => 'Account.without_suspended',
  'User.new.account' => 'User.new.account'
}.each do |label, code|
  parse_result = Prism.parse(code, filepath: "(control:#{label})", version: configuration.target_ruby)
  root = parse_result.value
  scope_index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)
  last = root.statements.body.last
  node_scope = scope_index[last]
  type = node_scope.type_of(last)
  puts format('%-36s => %-35s origin=%s', label, type.describe(:short).to_s[0, 35],
              node_scope.dynamic_origins[last].inspect)
end

# --- 2. real-file squish ---
path = 'app/helpers/formatting_helper.rb'
parse_result = Prism.parse(File.read(path), filepath: path, version: configuration.target_ruby)
root = parse_result.value
scope_index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)
Rigor::Source::NodeWalker.each_with_ancestors(root) do |node, _|
  next if non_expr.include?(node.class.name)

  sc = scope_index[node]
  type = sc.type_of(node)
  next unless node.is_a?(Prism::CallNode) && node.name == :squish

  puts format('REAL squish %s:%d recv=%s => %s origin=%s',
              path, node.location.start_line,
              node.receiver&.class&.name&.sub('Prism::', ''),
              type.describe(:short).to_s[0, 30], sc.dynamic_origins[node].inspect)
end

# --- 3. corpus unresolved-constant split ---
child_of_resolving_path = 0
terminal_unresolved = 0
terminal_names = Hash.new(0)
files.each do |f|
  pr = Prism.parse(File.read(f), filepath: f, version: configuration.target_ruby)
  next if pr.errors.any?

  root = pr.value
  scope_index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)
  Rigor::Source::NodeWalker.each_with_ancestors(root) do |node, ancestors|
    next if non_expr.include?(node.class.name)

    sc = scope_index[node]
    sc.type_of(node)
    next unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
    next unless sc.dynamic_origins[node] == :unsupported_syntax

    parent = ancestors.last
    if parent.is_a?(Prism::ConstantPathNode) && !OPAQUE.include?(scanner.send(:classify,
                                                                              scope_index[parent].type_of(parent)))
      child_of_resolving_path += 1
    else
      terminal_unresolved += 1
      name = node.is_a?(Prism::ConstantReadNode) ? node.name.to_s : (Rigor::Source::ConstantPath.qualified_name_or_nil(node) || '(dyn)')
      terminal_names[name] += 1
    end
  end
end
puts "unresolved constants: child_of_resolving_path=#{child_of_resolving_path} terminal=#{terminal_unresolved}"
puts 'terminal top 20:'
terminal_names.sort_by { |_, c| -c }.first(20).each { |n, c| puts format('  %5d  %s', c, n) }
