# frozen_string_literal: true

# mastodon_controls3.rb — heredoc/interpolation receiver micro-controls. READ-ONLY, cwd = rigor root.

RIGOR_ROOT = Dir.pwd
target = '/Users/megurine/repo/ruby/rigor-survey/mastodon'

lib = File.join(RIGOR_ROOT, 'lib')
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'rigor/cli'
require 'rigor/language_server/project_context'
require 'rigor/cli/coverage_scan'

Dir.chdir(target)
configuration = Rigor::Configuration.load(nil)
files = configuration.paths.flat_map { |arg| Dir.glob(File.join(arg, '**/*.rb')) }.uniq.sort
environment = Rigor::LanguageServer::ProjectContext.new(configuration: configuration).environment
scope = Rigor::CLI::CoverageScan.discovery_seeded_scope(
  files: files, configuration: configuration, environment: environment,
  parameter_inference: configuration.parameter_inference
)

{
  'multiline heredoc .squish' => "<<~CSS.squish\n  height: 1.1em;\n  margin: -.2ex;\nCSS",
  'multiline heredoc recv' => "<<~CSS\n  height: 1.1em;\n  margin: -.2ex;\nCSS",
  'interp string .squish' => '"a#{1}b".squish',
  'plain string .upcase' => "'ab'.upcase",
  'multiline heredoc .upcase' => "<<~T.upcase\n  a\n  b\nT"
}.each do |label, code|
  parse_result = Prism.parse(code, filepath: "(c3:#{label})", version: configuration.target_ruby)
  root = parse_result.value
  scope_index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)
  last = root.statements.body.last
  node_scope = scope_index[last]
  type = node_scope.type_of(last)
  puts format('%-28s node=%-28s => %-30s origin=%s',
              label, last.class.name.sub('Prism::', ''),
              type.describe(:short).to_s[0, 30], node_scope.dynamic_origins[last].inspect)
end
