# frozen_string_literal: true

# Integration spec for `examples/rigor-activejob/`.
# Tier 1D of the Rails plugins roadmap. Discovers
# ActiveJob subclasses by walking `app/jobs/` and validates
# `Job.perform_later` / `.perform_now` / `.perform`
# argument arity against each class's `#perform`.

require "spec_helper"

ACTIVEJOB_PLUGIN_LIB = File.expand_path("../../../examples/rigor-activejob/lib", __dir__)
$LOAD_PATH.unshift(ACTIVEJOB_PLUGIN_LIB) unless $LOAD_PATH.include?(ACTIVEJOB_PLUGIN_LIB)
require "rigor-activejob"

DEFAULT_JOBS = {
  "app/jobs/welcome_email_job.rb" => <<~RUBY,
    class ApplicationJob
    end
    class WelcomeEmailJob < ApplicationJob
      def perform(user_id, locale = "en")
        [user_id, locale]
      end
    end
  RUBY
  "app/jobs/report_job.rb" => <<~RUBY
    class ApplicationJob
    end
    class ReportJob < ApplicationJob
      def perform(*report_ids)
        report_ids
      end
    end
  RUBY
}.freeze

RSpec.describe "examples/rigor-activejob" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Activejob }

  describe "recognised job calls" do
    it "emits an info diagnostic for `perform_later` matching the discovered `#perform`" do
      result = run_plugin(
        source: "WelcomeEmailJob.perform_later(1)\n",
        files: DEFAULT_JOBS
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "job-call" }
      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
      expect(info.message).to include("WelcomeEmailJob.perform_later")
      expect(info.message).to include("1..2")
    end

    it "accepts both `perform_later` and `perform_now`" do
      result = run_plugin(
        source: "WelcomeEmailJob.perform_now(1, 'ja')\n",
        files: DEFAULT_JOBS
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "job-call" }
      expect(info).not_to be_nil
      expect(info.message).to include("perform_now")
    end

    it "accepts an unbounded `*args` arity for jobs with rest parameters" do
      result = run_plugin(
        source: "ReportJob.perform_later\nReportJob.perform_later(1, 2, 3)\n",
        files: DEFAULT_JOBS
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "wrong-arity" }).to be_empty
      expect(diags.select { |d| d.rule == "job-call" }.size).to eq(2)
    end
  end

  describe "wrong-arity diagnostics" do
    it "flags a missing required arg (`WelcomeEmailJob.perform_later` with 0 args)" do
      result = run_plugin(
        source: "WelcomeEmailJob.perform_later\n",
        files: DEFAULT_JOBS
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
      expect(err.message).to include("got 0")
      expect(err.message).to include("1..2")
    end

    it "flags too many positional args" do
      result = run_plugin(
        source: "WelcomeEmailJob.perform_later(1, 'ja', :extra)\n",
        files: DEFAULT_JOBS
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
      expect(err.message).to include("got 3")
    end
  end

  describe "edge cases" do
    it "ignores `Job.perform_later` calls when `Job` is not in `app/jobs/`" do
      # `UnrelatedKlass.perform_later(1)` doesn't trigger a
      # diagnostic — the plugin only validates calls whose
      # receiver is a discovered job class.
      result = run_plugin(
        source: "UnrelatedKlass.perform_later(1)\n",
        files: DEFAULT_JOBS
      )
      diags = plugin_diagnostics(result)
      expect(diags.find { |d| d.message.include?("UnrelatedKlass") }).to be_nil
    end

    it "doesn't flag classes whose superclass is not in `job_base_classes`" do
      files = DEFAULT_JOBS.merge(
        "app/jobs/looks_like_a_job.rb" => <<~RUBY
          class SomeRandomBase
          end
          class LooksLikeAJob < SomeRandomBase
            def perform(arg); arg; end
          end
        RUBY
      )
      result = run_plugin(source: "LooksLikeAJob.perform_later\n", files: files)
      expect(plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }).to be_nil
    end
  end

  describe "configuration" do
    let(:custom_files) do
      {
        "app/jobs/custom_job.rb" => <<~RUBY
          class MyBase; end
          class CustomJob < MyBase
            def perform(x); x; end
          end
        RUBY
      }
    end

    let(:custom_plugin_entry) do
      { "gem" => "rigor-activejob", "config" => { "job_base_classes" => ["MyBase"] } }
    end

    it "respects custom `job_base_classes`" do
      result = run_plugin(
        source: "CustomJob.perform_later(1)\n",
        files: custom_files,
        plugin_entry: custom_plugin_entry
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "job-call" }
      expect(info).not_to be_nil
    end
  end
end
