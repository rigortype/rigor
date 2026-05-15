# frozen_string_literal: true

# Integration spec for `examples/rigor-sinatra/`. ADR-16 slice 1c.
# Exercises the substrate's Tier A path end-to-end:
#
# 1. Load the example plugin via `rigor-sinatra`'s entry point.
# 2. Run rigor against a Sinatra-flavoured fixture with a minimal
#    Sinatra::Base RBS stub.
# 3. Assert that bare identifiers inside the route block
#    (`params`, `redirect`, `halt`) resolve through Sinatra::Base's
#    RBS — i.e. the substrate has narrowed the block's self_type.
#
# The integration spec at `spec/integration/macro_block_self_type_integration_spec.rb`
# already proves the engine hook against an *in-spec* fake plugin;
# this spec confirms the same path works through the *real example
# plugin gem entry point* and that the manifest declaration is
# wired correctly.

require "spec_helper"

SINATRA_PLUGIN_LIB = File.expand_path("../../../examples/rigor-sinatra/lib", __dir__)
$LOAD_PATH.unshift(SINATRA_PLUGIN_LIB) unless $LOAD_PATH.include?(SINATRA_PLUGIN_LIB)
require "rigor-sinatra"

RSpec.describe "rigor-sinatra integration" do
  let(:plugin_class) { Rigor::Plugin::Sinatra }

  let(:sinatra_base_rbs) do
    <<~RBS
      module Sinatra
        class Base
          def self.get: (String) ?{ () -> untyped } -> void
          def self.post: (String) ?{ () -> untyped } -> void
          def self.delete: (String) ?{ () -> untyped } -> void

          def params: () -> Hash[String, untyped]
          def redirect: (String) -> void
          def halt: (Integer, ?String) -> void
        end
      end
    RBS
  end

  let(:sinatra_app_source) do
    <<~RUBY
      class MyApp < Sinatra::Base
        get "/users/:id" do
          halt 404 unless params["id"]
          redirect "/users/\#{params['id']}/profile"
        end

        post "/sessions" do
          halt 403 if params["forbidden"]
          "session created"
        end
      end
    RUBY
  end

  it "registers a manifest with Tier A block_as_methods covering the nine Sinatra verbs" do
    manifest = plugin_class.manifest
    expect(manifest.id).to eq("sinatra")
    expect(manifest.block_as_methods.size).to eq(1)
    entry = manifest.block_as_methods.first
    expect(entry).to be_a(Rigor::Plugin::Macro::BlockAsMethod)
    expect(entry.receiver_constraint).to eq("Sinatra::Base")
    expect(entry.verbs).to eq(%i[get post put delete head options patch link unlink])
    expect(entry.self_type).to eq(:receiver_instance)
  end

  it "narrows the route block's self so bare Sinatra::Base methods resolve" do
    result = run_under_plugin(sinatra_app_source)
    undefined = result.diagnostics.select do |d|
      d.rule.to_s.include?("undefined-method") &&
        (d.message.include?("redirect") || d.message.include?("halt") || d.message.include?("params"))
    end
    expect(undefined).to(
      be_empty,
      "expected route block bare identifiers to resolve through Sinatra::Base RBS; " \
      "got: #{undefined.map(&:message).inspect}"
    )
  end

  def run_under_plugin(source)
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "demo.rb"), source)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "sinatra.rbs"), sinatra_base_rbs)

      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "demo.rb")],
          "plugins" => ["rigor-sinatra"]
        )
      )

      Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration,
          cache_store: nil,
          plugin_requirer: lambda do |_name|
            Rigor::Plugin.register(plugin_class)
            true
          end
        ).run
      end
    end
  end
end
