# frozen_string_literal: true

# mastodon_dispatch_controls.rb — controlled dispatch probes for case attribution.
# READ-ONLY. cwd = rigor repo root. Types a handful of synthetic expressions in the
# mastodon plugin-aware, discovery-seeded environment and prints result type + origin.

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

SNIPPETS = {
  'plain-string #squish' => "'hello  world'.squish",
  'heredoc #squish' => "<<~CSS.squish\n  height: 1em;\nCSS",
  'plain-string #present?' => "'x'.present?",
  '1.day' => '1.day',
  'UnfollowService.new' => 'UnfollowService.new',
  'UnfollowService.new.call' => 'UnfollowService.new.call(nil, nil)',
  'TagManager.instance' => 'ActivityPub::TagManager.instance',
  'Rails.configuration' => 'Rails.configuration',
  'Rails constant' => 'Rails',
  'Account.without_suspended' => 'Account.without_suspended',
  'Account.new' => 'Account.new',
  'optional Account #id' => "a = rand > 0.5 ? Account.new : nil\na.id",
  'ActiveRecord::RecordNotFound' => 'ActiveRecord::RecordNotFound',
  'Sidekiq constant' => 'Sidekiq',
  'REST namespace read' => 'REST',
  'REST::AccountSerializer' => 'REST::AccountSerializer'
}.freeze

SNIPPETS.each do |label, code|
  parse_result = Prism.parse(code, filepath: "(control:#{label})", version: configuration.target_ruby)
  if parse_result.errors.any?
    puts format('%-28s PARSE ERROR', label)
    next
  end
  root = parse_result.value
  scope_index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)
  last = root.statements.body.last
  node_scope = scope_index[last]
  type = node_scope.type_of(last)
  origin = node_scope.dynamic_origins[last]
  puts format('%-28s => %-40s origin=%s', label, type.describe(:short).to_s[0, 40], origin.inspect)
end
