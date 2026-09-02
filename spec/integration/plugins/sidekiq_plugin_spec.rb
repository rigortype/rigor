# frozen_string_literal: true

# Integration spec for `plugins/rigor-sidekiq/`. Tier 3C of the Rails plugins roadmap. Discovers Sidekiq
# workers by walking `app/workers/` and validates `Worker.perform_async(...)` / `.perform_in(...)` /
# `.perform_at(...)` / `.perform_inline(...)` argument count against each class's `#perform`.

require "spec_helper"

SIDEKIQ_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-sidekiq/lib", __dir__)
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

RSpec.describe "plugins/rigor-sidekiq" do
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
      # `perform_in(60, user_id)` — `60` is the schedule, `user_id` is the only forwarded arg → matches
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
      # `perform_in(60)` — `60` is the schedule, 0 args forwarded → fewer than `WelcomeEmailWorker#perform`'s
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

  # #621 — the discoverer used to key `class ::WelcomeEmailWorker` as `"::WelcomeEmailWorker"` (and, nested
  # inside a module, as the nonsense `"Admin::::WelcomeEmailWorker"`), and both consumers papered over the
  # first spelling with a `known?(name) || known?("::#{name}")` retry. Keys are de-rooted at the producer
  # now, which makes a rooted declaration and a plain reopen collide on ONE key — so the `#perform` envelope
  # merges instead of the last file in the glob clobbering the first.
  describe "rooted declarations and reopens (#621)" do
    let(:rooted_files) do
      {
        "app/workers/a_welcome_email_worker.rb" => <<~RUBY
          module Sidekiq
            module Job; end
          end
          class ::WelcomeEmailWorker
            include Sidekiq::Job
            def perform(user_id)
              user_id
            end
          end
        RUBY
      }
    end

    # A later-sorting file reopens the rooted declaration plainly, adding a helper but no `#perform`.
    let(:reopen_files) do
      rooted_files.merge(
        "app/workers/z_welcome_email_worker_ext.rb" => <<~RUBY
          module Sidekiq
            module Job; end
          end
          class WelcomeEmailWorker
            include Sidekiq::Job
            def notify_admins
              :ok
            end
          end
        RUBY
      )
    end

    it "types a rooted worker's `#perform` envelope under its plain spelling" do
      result = run_plugin(source: "WelcomeEmailWorker.perform_async(1)\n", files: rooted_files)
      info = plugin_diagnostics(result).find { |d| d.rule == "worker-call" }
      expect(info).not_to be_nil
      expect(plugin_diagnostics(result).select { |d| d.rule == "wrong-arity" }).to be_empty
    end

    it "recognises a worker that includes the marker module by its rooted name" do
      files = {
        "app/workers/rooted_marker_worker.rb" => <<~RUBY
          module Sidekiq
            module Job; end
          end
          class RootedMarkerWorker
            include ::Sidekiq::Job
            def perform(user_id)
              user_id
            end
          end
        RUBY
      }
      result = run_plugin(source: "RootedMarkerWorker.perform_async(1, 2)\n", files: files)
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
      expect(err.message).to include("got 2")
    end

    it "types a worker declared rooted INSIDE a module as the top-level constant it names" do
      files = {
        "app/workers/admin_welcome_email_worker.rb" => <<~RUBY
          module Sidekiq
            module Job; end
          end
          module Admin
            class ::WelcomeEmailWorker
              include Sidekiq::Job
              def perform(user_id)
                user_id
              end
            end
          end
        RUBY
      }
      result = run_plugin(source: "WelcomeEmailWorker.perform_async(1, 2)\n", files: files)
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
      expect(err.message).to include("WelcomeEmailWorker.perform_async")
      expect(err.message).to include("got 2")
    end

    it "keeps the rooted declaration's `#perform` envelope when a later file reopens the class plainly" do
      result = run_plugin(source: "WelcomeEmailWorker.perform_async(1, 2)\n", files: reopen_files)
      err = plugin_diagnostics(result).find { |d| d.rule == "wrong-arity" }
      expect(err).not_to be_nil
      expect(err.message).to include("got 2")
    end

    it "accepts a call the merged envelope allows" do
      result = run_plugin(source: "WelcomeEmailWorker.perform_async(1)\n", files: reopen_files)
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "wrong-arity" }).to be_empty
      expect(diags.find { |d| d.rule == "worker-call" }).not_to be_nil
    end

    # ADR-5: two declarations that BOTH spell `#perform` disagree about the shape, and the glob order is not
    # the load order — so the envelope widens rather than pinning either one and firing on correct code.
    it "widens the envelope when two declarations spell different `#perform` shapes" do
      files = rooted_files.merge(
        "app/workers/z_welcome_email_worker_redecl.rb" => <<~RUBY
          module Sidekiq
            module Job; end
          end
          class WelcomeEmailWorker
            include Sidekiq::Job
            def perform(user_id, locale)
              [user_id, locale]
            end
          end
        RUBY
      )
      result = run_plugin(
        source: "WelcomeEmailWorker.perform_async(1)\nWelcomeEmailWorker.perform_async(1, 'ja')\n",
        files: files
      )
      expect(plugin_diagnostics(result).select { |d| d.rule == "wrong-arity" }).to be_empty
    end

    it "still ignores a constant no declaration introduces" do
      result = run_plugin(source: "NotAWorkerAtAll.perform_async(1, 2, 3)\n", files: reopen_files)
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

  # Issue #534 item 4. `Sidekiq::Client#push` ends with `payload["jid"]`, so the three enqueue methods
  # return a `String` — ~90 mastodon sites that read `Dynamic[top]` before. The nullable arm of `push`
  # (a client middleware halting the chain) is deliberately not in the answer; the adjudication is on
  # `JID_TYPE` and the spec below pins the shape that rejected it.
  describe "the jid return type (#534)" do
    def dumps(result)
      result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
    end

    def rules(result)
      result.diagnostics.map(&:qualified_rule)
    end

    it "types perform_async / perform_in / perform_at as the jid String" do
      source = <<~RUBY
        Rigor.dump_type(WelcomeEmailWorker.perform_async(1))
        Rigor.dump_type(WelcomeEmailWorker.perform_in(60, 1))
        Rigor.dump_type(WelcomeEmailWorker.perform_at(Time.now, 1))
      RUBY
      result = run_plugin(source: source, files: DEFAULT_WORKERS)
      expect(dumps(result)).to eq(["dump_type: String"] * 3)
    end

    it "leaves `perform_inline` alone — it returns whatever `#perform` returns, not a jid" do
      result = run_plugin(
        source: "Rigor.dump_type(WelcomeEmailWorker.perform_inline(1))\n",
        files: DEFAULT_WORKERS
      )
      expect(dumps(result)).to eq(["dump_type: Dynamic[top]"])
    end

    it "does not type `perform_async` on a class the discoverer did not find" do
      # The gate is the discovered worker set, so a project's own `perform_async` keeps its own answer.
      source = <<~RUBY
        class NotAWorker
          def self.perform_async(x)
            x
          end
        end

        Rigor.dump_type(NotAWorker.perform_async(1))
      RUBY
      result = run_plugin(source: source, files: DEFAULT_WORKERS)
      expect(dumps(result)).to eq(["dump_type: 1"])
    end

    it "draws no possible-nil-receiver on the assigned-then-used jid — the `String?` hazard" do
      # The pin for the adjudication. Under `String | nil` this fixture fires `call.possible-nil-receiver`
      # at error severity on `other.length` (verified red), because the rule fires on
      # local-variable-read receivers for a method `NilClass` lacks. Under the shipped `String` it is
      # silent, and so are the defensive guards a caller might still write.
      source = <<~RUBY
        jid = WelcomeEmailWorker.perform_async(1)
        jid.to_s
        other = WelcomeEmailWorker.perform_in(60, 1)
        other.length
        WelcomeEmailWorker.perform_async(1).to_s
      RUBY
      result = run_plugin(source: source, files: DEFAULT_WORKERS)
      expect(rules(result)).not_to include("call.possible-nil-receiver")
    end

    it "draws no truthiness fold on a defensive jid guard — the non-nil `String` hazard" do
      # The other direction. A non-nil nominal is what licenses `flow.always-truthy-condition`, so the
      # guards a caller writes around an enqueue must stay unfolded.
      source = <<~RUBY
        def guarded
          jid = WelcomeEmailWorker.perform_async(1)
          return if jid.nil?

          jid.upcase
        end

        def guarded2
          return unless (jid = WelcomeEmailWorker.perform_async(1))

          jid.upcase
        end
      RUBY
      result = run_plugin(source: source, files: DEFAULT_WORKERS)
      expect(rules(result)).not_to include("flow.always-truthy-condition")
      expect(rules(result)).not_to include("flow.unreachable-branch")
    end

    it "CONTROL: the harness fires possible-nil-receiver and the truthiness fold in this shape" do
      # The must-fire sibling for the two negatives above.
      source = <<~RUBY
        s = ["a", nil].sample
        s.length
        flag = true
        "y" if flag
      RUBY
      result = run_plugin(source: source, files: DEFAULT_WORKERS)
      expect(rules(result)).to include("call.possible-nil-receiver")
      expect(rules(result)).to include("flow.always-truthy-condition")
    end
  end

  # #613 / ADR-45 WD1b — {ScheduleScan} gated its read on `File.file?(config/sidekiq.yml)`, so on a project
  # with no schedule the boundary read never happened, no absence row was recorded (#577 records it at the
  # READ), and the run-result entry carried no edge for the schedule's later appearance: the warm run was
  # served from cache and never looked at the new file. Every example drives the real Runner against a real
  # on-disk Store with a FRESH Store per run, so a hit has to come off disk — what the next `rigor check`
  # process faces.
  describe "warm-run cache across the appearance of `config/sidekiq.yml` (#613)" do
    SIDEKIQ_SCHEDULE_YAML = <<~YAML # rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration
      :scheduler:
        :schedule:
          nightly_report:
            cron: "0 0 * * *"
            class: "ReportWorker"
    YAML

    # Returns `[result, counters]` — the run-diagnostics slot's `hits:` / `misses:` for this run are the
    # direct read of whether the run was SERVED or RE-ANALYZED.
    def run_warm(dir, cache_root)
      Rigor::Plugin.unregister!
      store = Rigor::Cache::Store.new(root: cache_root)
      result = Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: Rigor::Configuration.new("paths" => ["demo.rb"], "plugins" => ["rigor-sidekiq"]),
          cache_store: store, collect_stats: false, plugin_requirer: build_plugin_requirer
        ).run
      end
      counters = store.stats.fetch(:by_producer)
                      .fetch(Rigor::Analysis::RunCacheKey::RUN_DIAGNOSTICS_PRODUCER_ID) { { hits: 0, misses: 0 } }
      [result, counters.slice(:hits, :misses)]
    end

    def with_project
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |cache_root|
          materialize_files(dir, DEFAULT_WORKERS.merge("demo.rb" => "ReportWorker.perform_async(1)\n"))
          yield dir, cache_root
        end
      end
    end

    it "re-analyzes the warm run once `config/sidekiq.yml` is ADDED" do
      with_project do |dir, cache_root|
        _cold, cold_counters = run_warm(dir, cache_root)
        expect(cold_counters).to eq(hits: 0, misses: 1)

        materialize_files(dir, "config/sidekiq.yml" => SIDEKIQ_SCHEDULE_YAML)
        _warm, counters = run_warm(dir, cache_root)
        expect(counters).to eq(hits: 0, misses: 1)
      end
    end

    it "serves the warm run from cache when nothing changed (a probe row does not thrash)" do
      with_project do |dir, cache_root|
        cold, = run_warm(dir, cache_root)

        warm, counters = run_warm(dir, cache_root)
        expect(counters).to eq(hits: 1, misses: 0)
        expect(warm.diagnostics.map { |d| [d.rule, d.line, d.message] })
          .to eq(cold.diagnostics.map { |d| [d.rule, d.line, d.message] })
      end
    end

    it "re-analyzes the warm run once `config/sidekiq.yml` is REMOVED" do
      with_project do |dir, cache_root|
        materialize_files(dir, "config/sidekiq.yml" => SIDEKIQ_SCHEDULE_YAML)
        _cold, cold_counters = run_warm(dir, cache_root)
        expect(cold_counters).to eq(hits: 0, misses: 1)

        File.unlink(File.join(dir, "config", "sidekiq.yml"))
        _warm, counters = run_warm(dir, cache_root)
        expect(counters).to eq(hits: 0, misses: 1)
      end
    end
  end
end
