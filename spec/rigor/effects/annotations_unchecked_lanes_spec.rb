# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor"
require "rigor/analysis/runner"
require "rigor/cache/store"

ANNOTATIONS_UNCHECKED_INLINE_PLUGIN_LIB =
  File.expand_path("../../../plugins/rigor-rbs-inline/lib", __dir__)
unless $LOAD_PATH.include?(ANNOTATIONS_UNCHECKED_INLINE_PLUGIN_LIB)
  $LOAD_PATH.unshift(ANNOTATIONS_UNCHECKED_INLINE_PLUGIN_LIB)
end
require "rigor-rbs-inline"

# #441 — the two lanes chapter 16 presents as co-equal, held co-equal.
#
# The SAME annotation, written once in `sig/*.rbs` and once as an rbs-inline comment in `.rb` source,
# must earn the same `effect.annotations-unchecked` notice. It did not: the pass took its inline
# stratum off `Runner#@run_environment`, which only the ADR-45 result-cacheable path ever assigns, so
# a `--no-cache` / `--workers N` run reported the `.rbs` spelling and stayed silent about the inline
# one — while a default run reported both. The lane, not the annotation, decided.
#
# The boundary that remains is a run that analyses NO file (a warm `--incremental` null recheck; the
# engine-free warm-cache probe, which an rbs-inline project can never reach because its key omits the
# `rbs.virtual_rbs` entry and so misses). Those have no environment to take the stratum from, and
# building one to find an `:info` is the cost ADR-103 WD13 refused. The last case below pins it, so
# the boundary is a decision rather than a drift.
RSpec.describe "effect.annotations-unchecked across the two annotation lanes" do
  def rule
    "effect.annotations-unchecked"
  end

  def inline_source
    <<~RUBY
      # rbs_inline: enabled
      class Memo
        # @rbs %a{pure}
        # @rbs return: Integer
        def value
          @value ||= 42
        end
      end
    RUBY
  end

  def plain_source
    <<~RUBY
      class Memo
        def value
          @value ||= 42
        end
      end
    RUBY
  end

  def signature_source
    <<~RBS
      class Memo
        %a{pure}
        def value: () -> Integer
      end
    RBS
  end

  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  # `sig/*.rbs` lane: a plain Ruby file plus a hand-written signature carrying the annotation.
  def build_rbs_lane(dir)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    FileUtils.mkdir_p(File.join(dir, "sig"))
    File.write(File.join(dir, "lib", "demo.rb"), plain_source)
    File.write(File.join(dir, "sig", "demo.rbs"), signature_source)
    { "paths" => ["lib"], "signature_paths" => ["sig"] }
  end

  # rbs-inline lane: the identical annotation as a `# @rbs %a{pure}` comment, no `sig/` tree at all.
  def build_inline_lane(dir)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "lib", "demo.rb"), inline_source)
    { "paths" => ["lib"], "plugins" => ["rigor-rbs-inline"] }
  end

  # @param lane [Symbol] `:rbs` or `:inline`
  # @return [Array<Rigor::Analysis::Diagnostic>] the rule's findings for one run of that lane.
  def findings_for(lane, cached: false, **runner_kwargs)
    Dir.mktmpdir("rigor-441-#{lane}-") do |dir|
      data = lane == :rbs ? build_rbs_lane(dir) : build_inline_lane(dir)
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data))
      store = cached ? Rigor::Cache::Store.new(root: File.join(dir, ".rigor", "cache")) : nil
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: store,
          plugin_requirer: ->(_name) { Rigor::Plugin.register(Rigor::Plugin::RbsInline) },
          **runner_kwargs
        )
        guarded_run(runner, ["lib"]).diagnostics.select { |d| d.rule == rule }
      end
    end
  end

  describe "the `sig/*.rbs` lane" do
    it "fires on a run the ADR-45 result cache serves" do
      found = findings_for(:rbs, cached: true)

      expect(found.size).to eq(1)
      expect([found.first.path, found.first.line, found.first.severity]).to eq(["sig/demo.rbs", 2, :info])
    end

    it "fires on a run the result cache does NOT serve (the `--no-cache` shape)" do
      found = findings_for(:rbs)

      expect(found.size).to eq(1)
      expect(found.first.path).to eq("sig/demo.rbs")
    end

    it "fires on a fork-pool run (the `--workers N` shape)" do
      found = findings_for(:rbs, workers: 2)

      expect(found.size).to eq(1)
      expect(found.first.path).to eq("sig/demo.rbs")
    end
  end

  describe "the rbs-inline lane" do
    it "fires on a run the ADR-45 result cache serves" do
      found = findings_for(:inline, cached: true)

      expect(found.size).to eq(1)
      expect([found.first.path, found.first.line, found.first.severity]).to eq(["lib/demo.rb", 3, :info])
    end

    # The #441 regression itself: identical annotation, identical project, silent for want of a
    # carrier. `cache_store: nil` is the shape `--no-cache` takes — and the shape every spec that
    # drives the runner directly takes, which is why the report came from a fixture.
    it "fires on a run the result cache does NOT serve (the `--no-cache` shape)" do
      found = findings_for(:inline)

      expect(found.size).to eq(1)
      expect([found.first.path, found.first.line]).to eq(["lib/demo.rb", 3])
    end

    # The fork pool builds its one environment on the PARENT so children inherit it warm, so the
    # stratum is there to be carried — a pooled run is not an excuse to go quiet.
    it "fires on a fork-pool run (the `--workers N` shape)" do
      found = findings_for(:inline, workers: 2)

      expect(found.size).to eq(1)
      expect([found.first.path, found.first.line]).to eq(["lib/demo.rb", 3])
    end

    # Position is the point of the notice: it names the annotation the author wrote, in the file they
    # wrote it in — NOT the line of the synthesized RBS buffer, which drifts by every body above it.
    it "points at the `# @rbs %a{pure}` comment in the Ruby source" do
      found = findings_for(:inline).first

      expect(inline_source.lines[found.line - 1]).to include("%a{pure}")
    end
  end

  describe "the one boundary that stays" do
    # A run with no files to analyse builds no environment, and the pass will not build one for an
    # `:info` (ADR-103 WD13). The `.rbs` stratum is a glob and survives; the inline stratum cannot.
    # Stated as a spec so the asymmetry is a documented decision and not a silent regression.
    it "reports the `.rbs` lane and not the inline lane when the run analyses nothing" do
      rbs = findings_for(:rbs, analyze_only: [])
      inline = findings_for(:inline, analyze_only: [])

      expect(rbs.size).to eq(1)
      expect(inline).to be_empty
    end
  end
end
