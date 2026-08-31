# frozen_string_literal: true

# probe_dispatch_sites.rb — for chosen FILE:LINE:METHOD sites, print the call node's
# typed tier, recorded dynamic-origin cause, and the scope's self type. READ-ONLY.
# Usage (cwd = rigor root): bundle exec ruby probe_dispatch_sites.rb TARGET_DIR SITES_FILE
# SITES_FILE lines: relative/path.rb:LINE:method_name

RIGOR_ROOT = Dir.pwd
target = File.expand_path(ARGV.fetch(0))
sites_file = File.expand_path(ARGV.fetch(1))

lib = File.join(RIGOR_ROOT, 'lib')
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'rigor/cli'
require 'rigor/language_server/project_context'
require 'rigor/cli/coverage_scan'
require 'rigor/inference/precision_scanner'
require 'rigor/source/node_walker'

sites = File.readlines(sites_file, chomp: true).reject(&:empty?).map do |ln|
  path, line, meth = ln.split(':', 3)
  [path, Integer(line), meth]
end

Dir.chdir(target)
configuration = Rigor::Configuration.load(nil)
files = configuration.paths.flat_map { |arg| Dir.glob(File.join(arg, '**/*.rb')) }.uniq.sort
environment = Rigor::LanguageServer::ProjectContext.new(configuration: configuration).environment
scope = Rigor::CLI::CoverageScan.discovery_seeded_scope(
  files: files, configuration: configuration, environment: environment,
  parameter_inference: configuration.parameter_inference
)
scanner = Rigor::Inference::PrecisionScanner.new(scope: scope)

sites.group_by(&:first).each do |path, group|
  source = File.read(path)
  parse_result = Prism.parse(source, filepath: path, version: configuration.target_ruby)
  root = parse_result.value
  scope_index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)
  Rigor::Source::NodeWalker.each_with_ancestors(root) do |node, _anc|
    next unless node.is_a?(Prism::CallNode)

    group.each do |(_p, line, meth)|
      next unless node.location.start_line == line && node.name.to_s == meth

      sc = scope_index[node]
      type = sc.type_of(node)
      tier = scanner.send(:classify, type)
      cause = sc.dynamic_origins[node]
      selft = begin
        sc.self_type.describe(:short)
      rescue StandardError => e
        "err:#{e.class}"
      end
      recv = node.receiver
      rdesc = recv.nil? ? '(implicit)' : scope_index[recv].type_of(recv).describe(:short)
      puts "#{path}:#{line} #{meth} | tier=#{tier} cause=#{cause.inspect} self=#{selft} recv=#{rdesc} type=#{type.describe(:short)}"
    end
  end
end
