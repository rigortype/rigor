# frozen_string_literal: true

# Issue #630 — `rigor-dry-types`, `rigor-dry-schema`, `rigor-dry-validation` and `rigor-graphql` read the
# project files they derive their contributions from. They used bare `File.read` inside a `Dir.glob` walk,
# so no `IoBoundary` row was recorded and neither the run-result cache (ADR-45) nor `--incremental`
# (ADR-46) had an edge back to the definition file. This spec pins the recorded dependency itself: for each
# plugin, the file the scan consumed appears in its boundary's `Cache::Descriptor` after the run.
#
# The row — not a warm-run counter — is what this gate can discriminate. Each of these four plugins scans
# exactly the project's `paths:`, so in a whole-project run the same file is already an analyzed-file entry
# of the run descriptor: a content-edit gate would pass with the bug still in place. The staleness the
# issue describes bites the paths where those two sets come apart (a producer's own cache entry, a widened
# or subset run), and the row is the single thing all of them are built on.
#
# `spec/docs/plugin_io_boundary_spec.rb` is the static half: no `File.read` creeps back into plugin lib.

require "spec_helper"
require "fileutils"
require "tmpdir"

%w[rigor-dry-types rigor-dry-schema rigor-dry-validation rigor-graphql].each do |gem_name|
  lib = File.expand_path("../../../plugins/#{gem_name}/lib", __dir__)
  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
  require gem_name
end

DRY_TYPES_SOURCE = <<~RUBY
  module Types
    include Dry.Types()
  end
RUBY

DRY_SCHEMA_SOURCE = <<~RUBY
  UserSchema = Dry::Schema.Params do
    required(:name).filled(:string)
    optional(:age).filled(:integer)
  end
RUBY

DRY_VALIDATION_SOURCE = <<~RUBY
  class NewUserContract < Dry::Validation::Contract
    params do
      required(:name).filled(:string)
    end
  end
RUBY

GRAPHQL_SOURCE = <<~RUBY
  class User < GraphQL::Schema::Object
    field :name, String, null: false
  end
RUBY

RSpec.describe "dry-rb / graphql plugin reads are recorded dependencies (#630)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  # Runs the plugin over a one-file project and returns its IoBoundary's recorded FileEntry rows.
  def boundary_rows_for(plugin_class, plugin_gem, source)
    boundaries = []
    plugin_id = plugin_class.manifest.id
    allow(Rigor::Plugin::IoBoundary).to receive(:new).and_wrap_original do |orig, **kwargs|
      orig.call(**kwargs).tap { |b| boundaries << b if b.plugin_id == plugin_id }
    end

    Dir.mktmpdir do |raw_dir|
      # `Dir.mktmpdir` hands back the unresolved `/tmp/...` alias on macOS while the plugin TrustPolicy's
      # read roots come from the symlink-resolved `Dir.pwd`; name the project the way the policy does.
      dir = File.realpath(raw_dir)
      File.write(File.join(dir, "defs.rb"), source)
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: Rigor::Configuration.new(
            Rigor::Configuration::DEFAULTS.merge("paths" => ["defs.rb"], "plugins" => [plugin_gem])
          ),
          cache_store: nil, collect_stats: false,
          plugin_requirer: lambda { |_name|
            Rigor::Plugin.register(plugin_class)
            true
          }
        )
        guarded_run(runner)
      end
      boundaries.flat_map { |b| b.cache_descriptor.files }
    end
  end

  {
    "rigor-dry-types" => [-> { Rigor::Plugin::DryTypes }, "rigor-dry-types", :DRY_TYPES_SOURCE],
    "rigor-dry-schema" => [-> { Rigor::Plugin::DrySchema }, "rigor-dry-schema", :DRY_SCHEMA_SOURCE],
    "rigor-dry-validation" => [-> { Rigor::Plugin::DryValidation }, "rigor-dry-validation",
                               :DRY_VALIDATION_SOURCE],
    "rigor-graphql" => [-> { Rigor::Plugin::Graphql }, "rigor-graphql", :GRAPHQL_SOURCE]
  }.each do |label, (klass, gem_name, source_const)|
    it "records a CONTENT row for the file #{label} read" do
      rows = boundary_rows_for(klass.call, gem_name, self.class.const_get(source_const))
      scanned = rows.find { |entry| entry.path.end_with?("/defs.rb") }
      expect(scanned).not_to be_nil
      # `:stat`/`:digest` is the row a boundary READ records. The classification probe in `scannable_paths`
      # records the weaker `:exists` presence row for the same path, so asserting mere presence would pass
      # with the `File.read` bug still in place — the comparator is what discriminates.
      expect(scanned.comparator.to_s).to match(/\A(stat|digest)\z/)
    end
  end
end
