# frozen_string_literal: true

# Integration spec for `examples/rigor-sidekiq/`.
# Tier 3C of the Rails plugins roadmap. Discovers Sidekiq
# workers by walking `app/workers/` and validates
# `Worker.perform_async(...)` / `.perform_in(...)` /
# `.perform_at(...)` / `.perform_inline(...)` argument
# count against each class's `#perform`.

require "spec_helper"

SIDEKIQ_PLUGIN_LIB = File.expand_path("../../../examples/rigor-sidekiq/lib", __dir__)
$LOAD_PATH.unshift(SIDEKIQ_PLUGIN_LIB) unless $LOAD_PATH.include?(SIDEKIQ_PLUGIN_LIB)
require "rigor-sidekiq"

DEFAULT_WORKERS = {
  "app/workers/welcome_email_worker.rb" => <<~RUBY,
    module Sidekiq
      module Job; end
    end
    class WelcomeEmailWorker
      include Sidekiq::Job
      def perform(user_id, locale = "en")
        [user_id, locale]
      end
    end
  RUBY
  "app/workers/report_worker.rb" => <<~RUBY
    module Sidekiq
      module Job; end
    end
    class ReportWorker
      include Sidekiq::Job
      def perform(*report_ids)
        report_ids
      end
    end
  RUBY
}.freeze

RSpec.describe "examples/rigor-sidekiq" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Sidekiq }

  describe "recognised worker calls" do
    it "emits an info diagnostic for `perform_async` matching the discovered `#perform`" do
      result = run_plugin(
        source: "WelcomeEmailWorker.perform_async(1)\n",
        files: DEFAULT_WORKERS
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "worker-call" }
      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
      expect(info.message).to include("WelcomeEmailWorker.perform_async")
      expect(info.message).to include("1..2")
    end

    it "accepts `perform_inline` for the same arity envelope" do
      result = run_plugin(
        source: "WelcomeEmailWorker.perform_inline(1, 'ja')\n",
        files: DEFAULT_WORKERS
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "worker-call" }
      expect(info).not_to be_nil
      expect(info.message).to include("perform_inline")
    end

    it "accepts an unbounded `*args` arity for workers with rest parameters" do
      result = run_plugin(
        source: "ReportWorker.perform_async\nReportWorker.perform_async(1, 2, 3)\n",
        files: DEFAULT_WORKERS
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "wrong-arity" }).to be_empty
      expect(diags.select { |d| d.rule == "worker-call" }.size).to eq(2)
    end
  end

  describe "scheduled entry points" do
    it "treats the first argument of `perform_in` as the schedule" do
      # `perform_in(60, user_id)` — `60` is the schedule,
      # `user_id` is the only forwarded arg → matches
      # `WelcomeEmailWorker#perform`'s 1..2 envelope.
      result = run_plugin(
        source: "WelcomeEmailWorker.perform_in(60, 1)\n",
        files: DEFAULT_WORKERS
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "wrong-arity" }).to be_empty
      info = diags.find { |d| d.rule == "worker-call" }
      expect(info).not_to be_nil
    end

    it "flags wrong arity AFTER consuming the schedule arg" do
      # `perform_in(60)` — `60` is the schedule, 0 args
      # forwarded → fewer than `WelcomeEmailWorker#perform`'s
      # required min (1).
      result = run_plugin(
        source: "WelcomeEmailWorker.perform_in(60)\n",
        files: DEFAULT_WORKERS
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
      expect(err.message).to include("got 0")
      expect(err.message).to include("after the schedule")
    end

    it "flags `perform_at` with zero args as missing-schedule" do
      result = run_plugin(
        source: "ReportWorker.perform_at\n",
        files: DEFAULT_WORKERS
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "missing-schedule" }
      expect(err).not_to be_nil
      expect(err.message).to include("ReportWorker.perform_at")
    end
  end

  describe "wrong-arity diagnostics" do
    it "flags `perform_async` with too few required args" do
      result = run_plugin(
        source: "WelcomeEmailWorker.perform_async\n",
        files: DEFAULT_WORKERS
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
      expect(err.message).to include("got 0")
      expect(err.message).to include("1..2")
    end

    it "flags too many positional args" do
      result = run_plugin(
        source: "WelcomeEmailWorker.perform_async(1, 'ja', :extra)\n",
        files: DEFAULT_WORKERS
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
      expect(err.message).to include("got 3")
    end
  end

  describe "edge cases" do
    it "ignores `perform_async` calls when the receiver is not a discovered worker" do
      result = run_plugin(
        source: "UnrelatedKlass.perform_async(1)\n",
        files: DEFAULT_WORKERS
      )
      expect(plugin_diagnostics(result)).to be_empty
    end

    it "doesn't flag classes that don't include the marker module" do
      files = DEFAULT_WORKERS.merge(
        "app/workers/looks_like_a_worker.rb" => <<~RUBY
          class LooksLikeAWorker
            def perform(arg); arg; end
          end
        RUBY
      )
      result = run_plugin(source: "LooksLikeAWorker.perform_async\n", files: files)
      expect(plugin_diagnostics(result)).to be_empty
    end
  end

  describe "configuration" do
    let(:custom_files) do
      {
        "app/jobs/custom_worker.rb" => <<~RUBY
          module MyMarker; end
          class CustomWorker
            include MyMarker
            def perform(x); x; end
          end
        RUBY
      }
    end

    let(:custom_plugin_entry) do
      {
        "gem" => "rigor-sidekiq",
        "config" => {
          "worker_search_paths" => ["app/jobs"],
          "worker_marker_modules" => ["MyMarker"]
        }
      }
    end

    it "respects custom `worker_search_paths` and `worker_marker_modules`" do
      result = run_plugin(
        source: "CustomWorker.perform_async(1)\n",
        files: custom_files,
        plugin_entry: custom_plugin_entry
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "worker-call" }
      expect(info).not_to be_nil
    end
  end
end
