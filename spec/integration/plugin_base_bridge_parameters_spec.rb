# frozen_string_literal: true

require "spec_helper"

%w[rigor-graphql rigor-sorbet rigor-grape].each do |plugin|
  lib = File.expand_path("../../plugins/#{plugin}/lib", __dir__)
  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
  require plugin
end

# #2681 — ADR-43's bridge reaches parameter positions, not only call returns. A plugin class known only from Ruby
# source (`class ZzProbe < Base` with no RBS declaration of `ZzProbe`) takes the allow-listed ancestor's RBS for
# the parameters of a block passed to a class-body DSL call, the parameters of an overriding hook `def`, and the
# inherited readers, exactly as an empty RBS declaration of the class (`class ZzProbe < Base; end`) would give it.
#
# The RBS here is the issue's three-line typed `base.rbs`, written hermetically so the table pins the bridge and not
# the current spelling of `sig/rigor/plugin/base.rbs` (whose `_Scope` / `_Services` interfaces still erase, #929).
RSpec.describe "ADR-43 bridge: block, override and reader types for a source-only plugin class (#2681)" do
  include RunnerHelpers

  let(:sig) do
    {
      "base.rbs" => <<~RBS
        module Rigor
          class Scope
          end

          module Plugin
            class Manifest
            end

            class Services
            end

            class CallNode
            end

            class ProgramNode
            end

            class Base
              def self.manifest: (**untyped fields) -> Rigor::Plugin::Manifest
              def self.dynamic_return: (?receivers: untyped, ?methods: untyped) { (Rigor::Plugin::CallNode call_node, Rigor::Scope scope) -> untyped } -> nil
              attr_reader services: Rigor::Plugin::Services
              def initialize: (Integer count) -> void
              def self.load: (Symbol name) -> void
              def self.respond_to_missing?: (Symbol name, bool include_all) -> bool
              def diagnostics_for_file: (path: String, scope: Rigor::Scope, root: Rigor::Plugin::ProgramNode) -> Array[untyped]
            end
          end
        end

        class OpenBase
          def self.manifest: (**untyped fields) -> Rigor::Plugin::Manifest
          def self.dynamic_return: (?receivers: untyped, ?methods: untyped) { (Rigor::Plugin::CallNode call_node, Rigor::Scope scope) -> untyped } -> nil
          attr_reader services: Rigor::Plugin::Services
          def diagnostics_for_file: (path: String, scope: Rigor::Scope, root: Rigor::Plugin::ProgramNode) -> Array[untyped]
        end
      RBS
    }
  end
  let(:probes) do
    {
      4 => :manifest, 7 => :block_call_node, 8 => :block_scope,
      12 => :override_path, 13 => :override_root, 14 => :services
    }
  end
  # The right-hand column of the issue's table.
  let(:bridged) do
    {
      manifest: "Rigor::Plugin::Manifest",
      block_call_node: "Rigor::Plugin::CallNode",
      block_scope: "Rigor::Scope",
      override_path: "String",
      override_root: "Rigor::Plugin::ProgramNode",
      services: "Rigor::Plugin::Services"
    }
  end
  # The source of `Rigor::Plugin::Base` itself, as this repository's `make check-plugins` discovers it from `lib/`:
  # a `def` and an `attr_reader` for each member the RBS declares.
  let(:base_source) do
    <<~RUBY
      module Rigor
        module Plugin
          class Base
            attr_reader :services

            def self.manifest(**fields) = fields
            def self.dynamic_return(receivers: nil, methods: nil, &block) = nil
            def diagnostics_for_file(path:, scope:, root:) = []
          end
        end
      end
    RUBY
  end

  # The issue's probe. Each `Rigor.dump_type` sits on its own line; `probes` names them by line.
  def probe_source(superclass)
    <<~RUBY
      module Rigor
        module Plugin
          class ZzProbe < #{superclass}
            Rigor.dump_type(manifest)

            dynamic_return(receivers: ["Foo"], methods: [:bar]) do |call_node, scope|
              Rigor.dump_type(call_node)
              Rigor.dump_type(scope)
            end

            def diagnostics_for_file(path:, scope:, root:)
              Rigor.dump_type(path)
              Rigor.dump_type(root)
              Rigor.dump_type(services)
              []
            end
          end
        end
      end
    RUBY
  end

  def dumped(files)
    result = analyze(files: files, sig: sig, cache_store: nil)
    result.diagnostics.select { |d| d.rule == "dump.type" && d.path.end_with?("probe.rb") }
          .to_h { |d| [probes.fetch(d.line), d.message.delete_prefix("dump_type: ")] }
  end

  it "types every probe from Base's RBS when Base's source is not in the project (a third-party plugin)" do
    expect(dumped("probe.rb" => probe_source("Base"))).to eq(bridged)
  end

  it "types every probe from Base's RBS when Base's own source is discovered (this repository's plugins)" do
    expect(dumped("probe.rb" => probe_source("Base"), "base.rb" => base_source)).to eq(bridged)
  end

  it "keeps a source subclass of a class off the allow-list on Dynamic[top] block and override parameters" do
    expect(dumped("probe.rb" => probe_source("::OpenBase"))).to eq(bridged.transform_values { "Dynamic[top]" })
  end

  # The override bridge reads the declaration the `def` overrides. A nearer source class that defines the name sits
  # between the two, so the leaf's parameters stay `Dynamic[top]`, as a call's bridge withholds past a nearer `def`.
  # `Mid` lives in another file: `discovered_methods` withholds a cross-file `def`, so only the resolution chain's
  # project-wide def tables see it.
  it "does not bind an override's parameters past a nearer source definer of the same hook" do
    mid = <<~RUBY
      module Rigor
        module Plugin
          class Mid < Base
            def diagnostics_for_file(path:, scope:, root:) = []
          end
        end
      end
    RUBY
    source = <<~RUBY
      module Rigor
        module Plugin
          class ZzProbe < Mid
            def diagnostics_for_file(path:, scope:, root:)
              Rigor.dump_type(path)
              []
            end
          end
        end
      end
    RUBY
    expect(dump_lines(source, "mid.rb" => mid)).to eq([[5, "dump_type: Dynamic[top]"]])
  end

  # A constructor does not override its superclass's contract: a subclass routinely takes other arguments, so binding
  # `name` to Base's `Integer count` would read correct code as a contradiction.
  it "does not bind a source subclass's `initialize` parameters from the ancestor's" do
    source = <<~RUBY
      module Rigor
        module Plugin
          class ZzProbe < Base
            def initialize(name)
              Rigor.dump_type(name)
            end
          end
        end
      end
    RUBY
    expect(dump_lines(source)).to eq([[5, "dump_type: Dynamic[top]"]])
  end

  # The name gate admits `load` and `respond_to_missing?` (Base's RBS declares them on the singleton side), and the
  # instance lookup on Base answers `Kernel#load` and `Kernel#respond_to_missing?`. Those are every class's surface,
  # not Base's contract, so the overrides keep `Dynamic[top]` rather than `String` and `Symbol | String`.
  it "does not bind an override from a declaration Object, Kernel, Module or Class makes" do
    source = <<~RUBY
      module Rigor
        module Plugin
          class ZzProbe < Base
            def load(x)
              Rigor.dump_type(x)
            end

            def respond_to_missing?(name, include_private = false)
              Rigor.dump_type(name)
            end
          end
        end
      end
    RUBY
    expect(dump_lines(source)).to eq([[5, "dump_type: Dynamic[top]"], [9, "dump_type: Dynamic[top]"]])
  end

  # The bridge serves the manifest-declared ancestors too (`rbs_complete_ancestors:`). With rigor-graphql,
  # rigor-sorbet and rigor-grape loaded, some ancestor's RBS declares a `load`, so the name gate admits it; the
  # `GraphQL::Schema::Object` lookup then answers `Kernel#load`, which binds nothing. `T::Struct.from_hash`'s
  # `(untyped hash, ?bool strict)` binds by absolute position: `hash` is not the optional `bool`.
  it "binds a manifest-declared ancestor's overrides per ancestor and by position" do
    source = <<~RUBY
      class Thing < GraphQL::Schema::Object
        def load(record_id)
          Rigor.dump_type(record_id)
        end
      end

      class Doc < T::Struct
        def self.from_hash(hash = {}, strict = false)
          Rigor.dump_type(hash)
          Rigor.dump_type(strict)
        end
      end
    RUBY
    expect(dump_with_plugins(source)).to eq(
      [[3, "dump_type: Dynamic[top]"], [9, "dump_type: Dynamic[top]"], [10, "dump_type: bool"]]
    )
  end

  def dump_with_plugins(source)
    Rigor::Plugin.unregister!
    plugins = [Rigor::Plugin::Graphql, Rigor::Plugin::Sorbet, Rigor::Plugin::Grape]
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "plugins" => %w[rigor-graphql rigor-sorbet rigor-grape],
        "bundler" => { "auto_detect" => false }, "rbs_collection" => { "auto_detect" => false }
      )
    )
    # A bundled plugin is required by its absolute path, so match on the file name.
    requirer = lambda do |name|
      Rigor::Plugin.register(plugins.find { |plugin| File.basename(name.to_s, ".rb") == "rigor-#{plugin.manifest.id}" })
      true
    end
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, plugin_requirer: requirer)
    result = guarded_run_source(runner, source: source)
    result.diagnostics.select { |d| d.rule == "dump.type" }.map { |d| [d.line, d.message] }
  ensure
    Rigor::Plugin.unregister!
  end

  def dump_lines(source, extra = {})
    result = analyze(files: { "probe.rb" => source, **extra }, sig: sig, cache_store: nil)
    result.diagnostics.select { |d| d.rule == "dump.type" }.map { |d| [d.line, d.message] }
  end
end
