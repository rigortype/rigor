# frozen_string_literal: true

# Integration spec for `plugins/rigor-railties/` — issue #534 item 2, the four `Rails.` singleton readers.
#
# The plugin's other half (the ADR-103 effect vocabulary and the `rails` entry-point preset) is covered by
# `spec/rigor/effects/rails_layer_spec.rb`; this file covers only the reader typing, and it is written as
# paired must-fire / must-not-fire assertions because the whole value of the answer is that it is LENIENT.
# A nominal that Rigor knows the RBS for would type these sites just as well and put `undefined-method` on
# working Rails code, so every positive assertion here is accompanied by the negative that discriminates it.

require "spec_helper"

unless defined?(RAILTIES_PLUGIN_LIB)
  RAILTIES_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-railties/lib", __dir__)
end
$LOAD_PATH.unshift(RAILTIES_PLUGIN_LIB) unless $LOAD_PATH.include?(RAILTIES_PLUGIN_LIB)
require "rigor-railties"

RSpec.describe "plugins/rigor-railties" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Railties }

  def dumps(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
  end

  def rules(result)
    result.diagnostics.map(&:qualified_rule)
  end

  describe "the singleton-reader types" do
    it "types all four `Rails.` readers with their lenient nominals (#534)" do
      source = <<~RUBY
        Rigor.dump_type(Rails.logger)
        Rigor.dump_type(Rails.cache)
        Rigor.dump_type(Rails.configuration)
        Rigor.dump_type(Rails.application)
      RUBY
      result = run_plugin(source: source)
      expect(dumps(result)).to eq(
        [
          "dump_type: ActiveSupport::BroadcastLogger",
          "dump_type: ActiveSupport::Cache::Store",
          "dump_type: Rails::Application::Configuration",
          "dump_type: Rails::Application"
        ]
      )
    end

    it "types the root-qualified `::Rails` receiver identically" do
      result = run_plugin(source: "Rigor.dump_type(::Rails.cache)\n")
      expect(dumps(result)).to eq(["dump_type: ActiveSupport::Cache::Store"])
    end

    it "CONTROL: the readers are `Dynamic[top]` without this plugin" do
      # The paired must-not-fire for every positive above: it proves the four dumps come from THIS plugin
      # and not from some RBS the environment already carries, so a silently-dropped `dynamic_return` would
      # fail a named assertion instead of passing vacuously.
      source = <<~RUBY
        Rigor.dump_type(Rails.logger)
        Rigor.dump_type(Rails.cache)
        Rigor.dump_type(Rails.configuration)
        Rigor.dump_type(Rails.application)
      RUBY
      Rigor::Plugin.unregister!
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("plugins" => []))
      result = Dir.mktmpdir do |dir|
        File.write(File.join(dir, "demo.rb"), source)
        Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: Rigor::Configuration.new(
              configuration.to_h.merge("paths" => [File.join(dir, "demo.rb")])
            ),
            cache_store: nil
          )
          guarded_run(runner)
        end
      end
      expect(dumps(result).size).to eq(4)
      expect(dumps(result)).to all(eq("dump_type: Dynamic[top]"))
    end
  end

  describe "the receiver gate" do
    it "does not hijack `logger` / `cache` / `configuration` / `application` on other receivers" do
      # These four are ordinary method names. The gate is the syntactic `Rails` constant, so a project's
      # own `logger` reader, a nested `Foo::Rails`, and a call with arguments must all keep their answers.
      source = <<~RUBY
        class Site
          def logger
            "site-logger"
          end

          def probe
            Rigor.dump_type(logger)
            Rigor.dump_type(Foo::Rails.logger)
            Rigor.dump_type(Rails.logger("extra"))
          end
        end
      RUBY
      result = run_plugin(source: source)
      expect(dumps(result)).to eq(
        ['dump_type: "site-logger"', "dump_type: Dynamic[top]", "dump_type: Dynamic[top]"]
      )
    end

    it "does not hijack an inherited singleton reader through a rooted nested `::Baz::Rails` (#626)" do
      # The rooted twin of the unrooted `Foo::Rails` case above. `rails_constant_receiver?` folds onto
      # `Source::ConstantPath.qualified_name_or_nil`, which renders `::Baz::Rails` down to the full dotted
      # "Baz::Rails" rather than the bare "Rails", so the gate still declines here. Folding onto
      # `Source::ConstantPath.rooted?` instead — the naive reading of "re-implements a single-segment slice
      # of rooted?" — would wrongly pass this receiver too: `rooted?` answers true for every node along a
      # rooted chain, not only a single segment, so the gate would hijack `LoggerBase.logger`, inherited by
      # `Baz::Rails`, into the framework's `BroadcastLogger`.
      source = <<~RUBY
        class LoggerBase
          def self.logger
            "base-logger"
          end
        end

        module Baz
          class Rails < LoggerBase
          end
        end

        Rigor.dump_type(::Baz::Rails.logger)
      RUBY
      result = run_plugin(source: source)
      expect(dumps(result)).to eq(["dump_type: Dynamic[top]"])
    end

    it "declines the reader the project defines on its own top-level `Rails` (#588)" do
      # The syntactic gate alone retyped the project's own `Rails.logger` to `BroadcastLogger` over the
      # project's definition. Zero diagnostics either way (both nominals are RBS-less), so this is the
      # project's own answer surviving, not an FP fix. Third dump is the per-reader discrimination: the
      # project defines `logger` and NOT `cache`, so only `logger` is yielded — a decline keyed on the
      # constant rather than the reader would have dropped `Rails.cache` to `Dynamic[top]`.
      source = <<~RUBY
        module Rails
          def self.logger
            "project-logger"
          end
        end

        Rigor.dump_type(Rails.logger)
        Rigor.dump_type(::Rails.logger)
        Rigor.dump_type(Rails.cache)
      RUBY
      result = run_plugin(source: source)
      expect(dumps(result)).to eq(
        [
          'dump_type: "project-logger"',
          'dump_type: "project-logger"',
          "dump_type: ActiveSupport::Cache::Store"
        ]
      )
      expect(rules(result).uniq).to eq(["dump.type"])
    end

    it "declines a lexically nested `MyApp::Rails` reader for a bare `Rails` inside `MyApp` (#588)" do
      # A bare `Rails` inside `module MyApp` is `MyApp::Rails` in Ruby, so the constant whose readers count
      # is the nested one. Same per-reader discrimination in the second dump: `MyApp::Rails` defines
      # `cache` only, so `Rails.logger` at that site keeps the framework nominal.
      source = <<~RUBY
        module MyApp
          module Rails
            def self.cache
              :project_cache
            end
          end

          def self.probe
            Rigor.dump_type(Rails.cache)
            Rigor.dump_type(Rails.logger)
          end
        end
      RUBY
      result = run_plugin(source: source)
      expect(dumps(result)).to eq(
        ["dump_type: :project_cache", "dump_type: ActiveSupport::BroadcastLogger"]
      )
      expect(rules(result).uniq).to eq(["dump.type"])
    end

    it "still types a reopened `module Rails` that answers none of the readers (#588)" do
      # The must-still-type sibling that makes the gate READER-shaped rather than constant-shaped. Both
      # halves are real Rails apps: mastodon's `lib/rails/engine_extensions.rb` reopens `module Rails` to
      # hang an extension off it, and a compact `class Rails::HealthController` makes `Rails` a discovered
      # constant through #528's synthesized namespace prefixes. Nothing in either shape answers
      # `Rails.logger`, so declining would only give up #534's typing (261 mastodon sites) for `Dynamic[top]`.
      source = <<~RUBY
        module Rails
          module EngineExtensions
          end
        end

        class Rails::HealthController
        end

        Rigor.dump_type(Rails.logger)
        Rigor.dump_type(Rails.cache)
      RUBY
      result = run_plugin(source: source)
      expect(dumps(result)).to eq(
        ["dump_type: ActiveSupport::BroadcastLogger", "dump_type: ActiveSupport::Cache::Store"]
      )
      expect(rules(result).uniq).to eq(["dump.type"])
    end

    it "resolves `::Rails` at top level, never to a lexically nested shadow (#588)" do
      # Ruby resolves a root-qualified constant at top level whatever the nesting is, so `::Rails.logger`
      # inside `MyApp` is the framework's reader and `.info` is valid — even though `MyApp::Rails.logger`
      # exists and returns a Symbol. Typing the site from the nested module's reader put a
      # `call.undefined-method` on correct code; the empty-diagnostics assertion is the half that pins it.
      source = <<~RUBY
        module MyApp
          module Rails
            def self.logger
              :nested
            end
          end

          def self.probe
            Rigor.dump_type(::Rails.logger)
            ::Rails.logger.info("x")
          end
        end
      RUBY
      result = run_plugin(source: source)
      expect(dumps(result)).to eq(["dump_type: ActiveSupport::BroadcastLogger"])
      expect(rules(result).uniq).to eq(["dump.type"])
    end

    it "CONTROL: the nested reader's Symbol DOES raise undefined-method when it is really the receiver" do
      # The must-fire discrimination for the example above: same nested `MyApp::Rails.logger` returning a
      # Symbol, but named explicitly so no root-qualification is involved. `call.undefined-method` fires,
      # proving the previous example's silence is `::Rails` resolving to the framework and not a harness
      # that cannot report the rule at all.
      source = <<~RUBY
        module MyApp
          module Rails
            def self.logger
              :nested
            end
          end

          def self.probe
            MyApp::Rails.logger.info("x")
          end
        end
      RUBY
      result = run_plugin(source: source)
      expect(rules(result)).to include("call.undefined-method")
    end

    it "still types the framework `Rails` beside other project-defined modules" do
      # The must-still-type sibling of the declines above: a discovered module elsewhere in the project is
      # not a `Rails` definition, and the unresolved framework constant passes the type-side gate.
      source = <<~RUBY
        module MyApp
          def self.probe
            Rigor.dump_type(Rails.logger)
          end
        end

        Rigor.dump_type(Rails.logger)
      RUBY
      result = run_plugin(source: source)
      expect(dumps(result)).to eq(["dump_type: ActiveSupport::BroadcastLogger"] * 2)
      expect(rules(result).uniq).to eq(["dump.type"])
    end
  end

  describe "leniency — the reason the nominals are RBS-less" do
    it "does not fire undefined-method on the ActiveSupport logger surface (#534)" do
      # The discrimination for the `logger` name choice. Every method below is an ActiveSupport extension
      # that stdlib `::Logger` does NOT have, so typing the reader `Logger` — the name issue #534 suggested
      # — makes all four of these `call.undefined-method` on working Rails code (measured: 4/4). The
      # RBS-less `ActiveSupport::BroadcastLogger` answers the receiver and stays lenient.
      source = <<~RUBY
        Rails.logger.info("x")
        Rails.logger.tagged("req") { 1 }
        Rails.logger.silence { 1 }
        Rails.logger.broadcast_to(Rails.logger)
        Rails.logger.local_level = :debug
      RUBY
      result = run_plugin(source: source)
      expect(rules(result)).not_to include("call.undefined-method")
    end

    it "does not fire undefined-method on the cache / configuration / application surfaces" do
      source = <<~RUBY
        Rails.cache.fetch("k") { 1 }
        Rails.cache.write("k", 1, expires_in: 5)
        Rails.cache.delete_matched(/x/)
        Rails.configuration.x.some_custom_key
        Rails.configuration.action_mailer.default_url_options
        Rails.application.routes.url_helpers
        Rails.application.credentials.dig(:aws, :key)
        Rails.application.config.time_zone
      RUBY
      result = run_plugin(source: source)
      expect(rules(result)).not_to include("call.undefined-method")
    end

    it "stays silent when the project's own partial `sig/` declares `Rails` (#653)" do
      # The reported repro: a project `sig/` (or a community RBS) declaring SOME of the `Rails` singleton
      # surface makes the constant RBS-known, and the existence check then read that partial declaration as
      # a closed world — three errors on working code, where deleting the four-line signature produced
      # none. Adding RBS must never make a plugin-covered call site worse.
      source = <<~RUBY
        Rigor.dump_type(Rails.logger)
        Rigor.dump_type(::Rails.logger)
        ::Rails.logger.info("x")
      RUBY
      result = run_plugin(
        source: source,
        files: { "sig/rails.rbs" => "module Rails\n  def self.env: () -> String\nend\n" },
        signature_paths: ["sig"]
      )
      expect(rules(result)).not_to include("call.undefined-method")
      # Must-still-resolve: a `Rails` collapsed to `Dynamic` would be silent too.
      expect(dumps(result)).to eq(["dump_type: ActiveSupport::BroadcastLogger"] * 2)
    end

    it "CONTROL: the declared half of that partial `sig/` still binds, and its gaps still fire (#653)" do
      # The two discriminations for the example above. `Rails.env` IS declared, so it keeps type-checking
      # against its signature (String, not the plugin's nominal); `Rails.no_such_reader` is answered by
      # neither the RBS nor the plugin, so the rule still reports it — the suppression is per call site.
      source = <<~RUBY
        Rigor.dump_type(Rails.env)
        Rails.no_such_reader
      RUBY
      result = run_plugin(
        source: source,
        files: { "sig/rails.rbs" => "module Rails\n  def self.env: () -> String\nend\n" },
        signature_paths: ["sig"]
      )
      expect(dumps(result)).to eq(["dump_type: String"])
      expect(rules(result)).to include("call.undefined-method")
    end

    it "CONTROL: the harness fires undefined-method in this fixture shape" do
      # The must-fire sibling for the two negatives above — without it, a rule-id rename or an unanalysed
      # fixture would make them pass while reporting nothing.
      result = run_plugin(source: %("a string".no_such_method_on_string\n))
      expect(rules(result)).to include("call.undefined-method")
    end
  end

  describe "the nil question — no fold on defensive Rails idioms" do
    it "leaves every guarded / defensive reader shape unfolded (#534)" do
      # All four readers are non-nil nominals, which is what licenses `flow.always-truthy-condition`. The
      # shapes below are the ones real Rails code writes; none of them may draw a diagnostic.
      source = <<~RUBY
        def fallback
          Rails.logger || ::Logger.new($stdout)
        end

        def raise_guard
          raise "no logger" unless Rails.logger

          Rails.logger.info("x")
        end

        def modifier_if
          Rails.logger.info("x") if Rails.logger
        end

        def assigned_truthy
          app = Rails.application
          return nil unless app

          app.config
        end

        def nil_check
          logger = Rails.logger
          return if logger.nil?

          logger.info("x")
        end
      RUBY
      result = run_plugin(source: source)
      expect(rules(result)).not_to include("flow.always-truthy-condition")
      expect(rules(result)).not_to include("flow.unreachable-branch")
    end

    it "CONTROL: the harness fires the truthiness fold in this fixture shape" do
      result = run_plugin(source: "flag = true\n\"y\" if flag\n")
      expect(rules(result)).to include("flow.always-truthy-condition")
    end
  end
end
