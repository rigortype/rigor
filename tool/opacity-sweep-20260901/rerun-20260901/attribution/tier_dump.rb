# frozen_string_literal: true

# tier_dump.rb — same lens as probe_attrib.rb, but dumps EVERY expression's tier +
# describe(:short), so a tier-bucket delta can be attributed site by site.
#   bundle exec ruby tier_dump.rb TARGET_DIR OUT_TSV [TIER...] [-- PATH...]
# TIER filter defaults to all. cwd MUST be the rigor repo root.

RIGOR_ROOT = Dir.pwd
target = File.expand_path(ARGV.fetch(0))
out_tsv = File.expand_path(ARGV.fetch(1))
rest = ARGV[2..] || []
sep = rest.index('--')
tiers_filter = (sep ? rest[0...sep] : rest).map(&:to_sym)
extra_paths = sep ? rest[(sep + 1)..] : []

lib = ENV['RIGOR_LIB'] || File.join(RIGOR_ROOT, 'lib')
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'rigor/cli'
require 'rigor/language_server/project_context'
require 'rigor/cli/coverage_scan'
require 'rigor/inference/precision_scanner'
require 'rigor/source/node_walker'

Dir.chdir(target)

configuration = Rigor::Configuration.load(nil)
args = extra_paths.empty? ? configuration.paths : extra_paths
files = args.flat_map do |arg|
  File.directory?(arg) ? Dir.glob(File.join(arg, '**/*.rb')) : [arg]
end.uniq.sort

environment = Rigor::LanguageServer::ProjectContext.new(configuration: configuration).environment
scope = Rigor::CLI::CoverageScan.discovery_seeded_scope(
  files: files, configuration: configuration, environment: environment,
  parameter_inference: configuration.parameter_inference
)
scanner = Rigor::Inference::PrecisionScanner.new(scope: scope)
non_expr = Rigor::Inference::PrecisionScanner.const_get(:NON_EXPRESSION_NODE_TYPES)

rows = []
files.each do |path|
  parse_result = Prism.parse(File.read(path), filepath: path, version: configuration.target_ruby)
  next if parse_result.errors.any?

  root = parse_result.value
  scope_index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)
  Rigor::Source::NodeWalker.each_with_ancestors(root) do |node, _anc|
    next if non_expr.include?(node.class.name)

    type = scope_index[node].type_of(node)
    tier = scanner.send(:classify, type)
    next unless tiers_filter.empty? || tiers_filter.include?(tier)

    src = node.slice.split("\n").first.to_s[0, 70]
    rows << [path, node.location.start_line, node.location.start_column,
             node.class.name.sub('Prism::', ''), tier, type.describe(:short).to_s[0, 80], src].join("\t")
  end
end

File.write(out_tsv, "#{rows.join("\n")}\n")
puts "tier_dump: #{rows.size} rows -> #{out_tsv}"
