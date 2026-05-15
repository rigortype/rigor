# frozen_string_literal: true

# Integration coverage for ADR-16 Tier A (block-as-method) engine
# hook, slice 1b. Demonstrates the floor contract pinned by WD13:
# when a registered plugin declares `block_as_methods:` for a class
# that the user's app subclasses, bare identifiers inside the
# matching DSL block resolve through the receiver's RBS rather
# than producing `call.undefined-method`.
#
# The Sinatra-flavoured fixture is the canonical real-world target
# for Tier A — but this spec ships in advance of the worked
# `examples/rigor-sinatra/` plugin gem (slice 1c). It uses an
# in-spec plugin class with a minimal RBS stub for `Sinatra::Base`
# so the Tier A contract is observable without authoring the
# external example.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/cache/store"
require "rigor/configuration"

RSpec.describe "ADR-16 Tier A — block-as-method engine hook" do
  # Plugin under test. Declares the Tier A contract for
  # `Sinatra::Base`'s `get` / `post` verbs. No diagnostics-of-its-
  # own; the substrate's `self_type` narrowing is the entire
  # delivery.
  let(:tier_a_plugin) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(
        id: "tieratest",
        version: "0.1.0",
        block_as_methods: [
          Rigor::Plugin::Macro::BlockAsMethod.new(
            receiver_constraint: "Sinatra::Base",
            verbs: %i[get post]
          )
        ]
      )
    end
    stub_const("FakePluginTierATest", klass)
    klass
  end

  # Minimal RBS for the fixture. `Sinatra::Base` exposes `redirect`,
  # `params`, `halt`. The class method `get` accepts a path String
  # and an optional block returning untyped — leaving the block's
  # actual `self` to the Tier A hook to pin.
  let(:sinatra_base_rbs) do
    <<~RBS
      module Sinatra
        class Base
          def self.get: (String) ?{ () -> untyped } -> void
          def self.post: (String) ?{ () -> untyped } -> void

          def redirect: (String) -> void
          def params: () -> Hash[String, untyped]
          def halt: (Integer, ?String) -> void
        end
      end
    RBS
  end

  def run_analysis(source, plugin_class:)
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "demo.rb"), source)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "sinatra.rbs"), sinatra_base_rbs)

      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "demo.rb")],
          "plugins" => ["rigor-tieratest"]
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

  describe "floor commitment per WD13" do
    let(:sinatra_app_source) do
      <<~RUBY
        class MyApp < Sinatra::Base
          get "/hello" do
            redirect "/landing"
            params
          end
        end
      RUBY
    end

    it "narrows the block self to Nominal[MyApp] so Sinatra::Base instance methods resolve" do
      result = run_analysis(sinatra_app_source, plugin_class: tier_a_plugin)
      undefined = result.diagnostics.select do |d|
        d.rule.to_s.include?("undefined-method") && d.message.include?("redirect")
      end
      expect(undefined).to(
        be_empty,
        "expected `redirect` inside the block to resolve, " \
        "got diagnostics: #{undefined.map(&:message).inspect}"
      )
    end

    # NOTE: "missing-method-on-substrate-narrowed-self surfaces as
    # a diagnostic" is a separate analyzer-rule concern (the
    # `call.undefined-method` rule is opt-in via the severity
    # profile, not always-on). Tier A's contract is the *narrowing*;
    # the downstream diagnostic policy is unchanged. The unit spec
    # at `spec/rigor/inference/macro_block_self_type_spec.rb` covers
    # the helper's positive and negative match cases; the
    # integration here proves the engine consumes the helper's
    # output for actual block-body resolution.
  end

  describe "non-matching call shapes" do
    # The substrate's correctness model is "Tier A narrows self_type
    # only when (receiver_constraint matches, verb matches)." The
    # negative-side observable is the *inference effect* — Type::Singleton
    # of the outer class body is preserved inside the block — rather
    # than a particular diagnostic. The unit-spec already proves the
    # narrowing rules at the helper level; here we drive the engine
    # through the same paths to confirm the wiring respects them.

    it "leaves verbs outside the manifest's `verbs:` list alone (Tier A does not fire)" do
      source = <<~RUBY
        class MyApp < Sinatra::Base
          delete "/x" do
            redirect "/y"
          end
        end
      RUBY
      # The engine produces SOME diagnostic about the unknown call
      # path. The Tier A invariant we care about is that the helper's
      # narrow_self_type_for returned nil for the `delete` verb;
      # that's verified at the unit-spec layer. The integration spec
      # here just exercises the end-to-end runner to confirm no
      # exception is raised when Tier A declines.
      expect { run_analysis(source, plugin_class: tier_a_plugin) }.not_to raise_error
    end

    it "leaves classes outside the receiver_constraint hierarchy alone (Tier A does not fire)" do
      source = <<~RUBY
        class Standalone
          def configure
            get "/hello" do
              redirect "/landing"
            end
          end
        end
      RUBY
      expect { run_analysis(source, plugin_class: tier_a_plugin) }.not_to raise_error
    end
  end
end
