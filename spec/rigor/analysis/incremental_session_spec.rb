# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/plugin/base"

# ADR-85 WD1 fixture — a synthetic producer-bearing plugin. Its `:probe` producer bumps a class-level
# scan counter and reads nothing (empty dependency descriptor → always fresh after the first write),
# and `#prepare` consults it on every run. So a warm recheck that serves the producer from the disk
# cache never re-runs the block; `.scans` is the scan-count seam the WD1 spec asserts on. Guarded so a
# re-load of this spec file does not redeclare the manifest/producer.
module Rigor
  module Plugin
    unless defined?(Wd1CacheProbe)
      class Wd1CacheProbe < Base
        @scans = 0
        class << self
          attr_accessor :scans
        end

        manifest(id: "wd1-cache-probe", version: "0.1.0")

        producer :probe do |_params|
          Wd1CacheProbe.scans += 1
          "probe-value"
        end

        def prepare(_services)
          producer_value(:probe)
        end
      end

      # ADR-88 WD1 fixture — a plugin whose producer value is a class-level toggle standing in for a Sorbet
      # catalog built from sig files OUTSIDE `signature_paths:`. Flipping `.state` between two "processes"
      # (with no store, so the block recomputes and reflects the toggle) simulates a sig edit that moves the
      # fact surface without touching any analyzed file — the case the global snapshot fingerprint misses.
      class Wd1FactSurfaceProbe < Base
        @state = "s1"
        class << self
          attr_accessor :state
        end
        manifest(id: "wd1-fact-surface", version: "0.1.0")
        producer :catalog do |_params|
          Wd1FactSurfaceProbe.state
        end

        def prepare(_services)
          producer_value(:catalog)
        end
      end

      # ADR-88 WD1 fixture — CONTRIBUTES a per-call type (`dynamic_return`) but declares no fact / producer /
      # hook. The fingerprint cannot see its stale-able state, so it is OPAQUE: the snapshot is never reused.
      class Wd1OpaqueProbe < Base
        manifest(id: "wd1-opaque", version: "0.1.0")
        dynamic_return methods: [:thing] do |_call_node, _scope|
          nil
        end
      end

      # #588 fixture — stands in for rigor-railties' `Rails.` reader gate: a contribution that types
      # `Widget.build` only while the PROJECT does not define that singleton method itself, asked through
      # `Rigor::Reflection.discovered_method?`. `incremental_state_fingerprint` mirrors railties so the
      # fixture is non-opaque (ADR-88 WD1) and its snapshot is reusable, which is the state the staleness
      # this exercises appears in.
      class ProjectDefGateProbe < Base
        manifest(id: "project-def-gate", version: "0.1.0")

        dynamic_return methods: [:build] do |call_node, scope|
          next nil unless call_node.is_a?(Prism::CallNode)
          next nil unless call_node.receiver.is_a?(Prism::ConstantReadNode)
          next nil unless call_node.receiver.name == :Widget
          next nil if Rigor::Reflection.discovered_method?("Widget", :build, kind: :singleton, scope: scope)

          Rigor::Type::Combinator.nominal_of("PluginGadget")
        end

        def incremental_state_fingerprint
          "static-widget-gate"
        end
      end
    end
  end
end

# ADR-46 slice 2 — the in-memory incremental orchestrator. The acceptance property (the `--verify-incremental` gate,
# here without disk persistence or CLI wiring): after a real on-disk edit, `#recheck` re-analyzes only the affected
# closure and serves the rest from cache, yet its merged diagnostics are byte-identical — as a sorted set — to a full
# re-analysis of the edited tree.
RSpec.describe Rigor::Analysis::IncrementalSession do
  def configuration(dir)
    Rigor::Configuration.new("paths" => [dir])
  end

  def shared_environment
    @shared_environment ||= Rigor::Environment.for_project
  end

  def full_run(dir)
    config = configuration(dir)
    runner = Rigor::Analysis::Runner.new(
      configuration: config, cache_store: nil, environment: shared_environment
    )
    guarded_run(runner).diagnostics
  end

  def session_for(config, paths: nil)
    described_class.new(configuration: config, paths: paths, environment: shared_environment)
  end

  def sorted(diagnostics)
    diagnostics.map(&:to_h).sort_by { |hash| [hash["path"], hash["line"], hash["column"], hash["rule"]] }
  end

  def write_once(path, content)
    File.write(path, content) unless File.exist?(path)
  end

  def fingerprint(config, dir)
    Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: [dir])
  end

  # A self-contained `def.override-visibility-reduced` (balanced profile → :warning) plus a referenceable class.
  # `reduced:` toggles the diagnostic.
  def write_unit(path, prefix:, reduced: true)
    File.write(path, <<~RUBY)
      class #{prefix}Base
        def tag
          "x"
        end
      end

      class #{prefix}Sub < #{prefix}Base
        #{"private\n" if reduced}
        def tag
          "y"
        end
      end
    RUBY
  end

  it "matches a full re-analysis after a leaf body edit while re-checking one file" do
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.rb")
      b = File.join(dir, "b.rb")
      write_unit(a, prefix: "A")
      write_unit(b, prefix: "B")

      session = session_for(configuration(dir))
      guarded_baseline(session)

      # Body edit to a.rb only — erase its diagnostic. b.rb is untouched.
      write_unit(a, prefix: "A", reduced: false)

      recheck = guarded_recheck(session)

      # Only a.rb was re-analyzed; b.rb was served from cache.
      expect(recheck.changed).to eq(Set[a])
      expect(recheck.affected).to eq(Set[a])
      expect(recheck.reused).to include(b)

      # The merged result equals a full re-analysis of the edited tree.
      expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
    end
  end

  it "matches a full re-analysis when nothing changed (all served from cache)" do
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.rb")
      write_unit(a, prefix: "A")

      session = session_for(configuration(dir))
      guarded_baseline(session)
      recheck = guarded_recheck(session)

      expect(recheck.changed).to be_empty
      expect(recheck.affected).to be_empty
      expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
    end
  end

  it "stays correct across two successive edits (multi-round state)" do
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.rb")
      b = File.join(dir, "b.rb")
      write_unit(a, prefix: "A")
      write_unit(b, prefix: "B")

      session = session_for(configuration(dir))
      guarded_baseline(session)

      # Round 1: erase a.rb's diagnostic.
      write_unit(a, prefix: "A", reduced: false)
      r1 = guarded_recheck(session)
      expect(sorted(r1.diagnostics)).to eq(sorted(full_run(dir)))

      # Round 2: erase b.rb's diagnostic too. The session's cache for a.rb must already reflect round 1, so the merge
      # stays correct.
      write_unit(b, prefix: "B", reduced: false)
      r2 = guarded_recheck(session)
      expect(r2.changed).to eq(Set[b])
      expect(sorted(r2.diagnostics)).to eq(sorted(full_run(dir)))
    end
  end

  # ADR-46 slice 3 — negative-dependency tracking. A top-level call has no class ancestry to walk, so a miss records no
  # positive edge; without the negative edge a caller's `call.unresolved-toplevel` would be served stale after the
  # method is defined elsewhere.
  describe "negative (appeared-symbol) dependencies" do
    it "re-checks a caller whose missed top-level method is defined by an edit" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        File.write(a, "helper()\n")
        File.write(b, "class Placeholder\nend\n")

        session = session_for(configuration(dir))
        baseline = guarded_baseline(session)
        # Baseline: a.rb fires call.unresolved-toplevel for the undefined helper.
        expect(baseline.map(&:rule)).to include("call.unresolved-toplevel")

        # Define the top-level helper in b.rb — a.rb's diagnostic must clear.
        File.write(b, "def helper\n  1\nend\n")
        recheck = guarded_recheck(session)

        # a.rb is pulled into the affected closure by the appeared `helper`, so the merged result matches a full
        # re-analysis (no stale FP).
        expect(recheck.affected).to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        expect(sorted(recheck.diagnostics).map { |h| h["rule"] }).not_to include("call.unresolved-toplevel")
      end
    end

    it "re-checks a subclass when its previously-undefined superclass is added" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        # ASub overrides tag with reduced visibility, but NewBase does not yet exist, so no def.override-* fires at
        # baseline.
        File.write(a, "class ASub < NewBase\n  private\n\n  def tag\n    \"y\"\n  end\nend\n")
        File.write(b, "class Placeholder\nend\n")

        session = session_for(configuration(dir))
        baseline = guarded_baseline(session)
        expect(baseline.map(&:rule)).not_to include("def.override-visibility-reduced")

        # Define NewBase (with a public tag) in b.rb — ASub now reduces its visibility, so the override diagnostic must
        # appear.
        File.write(b, "class NewBase\n  def tag\n    \"x\"\n  end\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        expect(sorted(recheck.diagnostics).map { |h| h["rule"] }).to include("def.override-visibility-reduced")
      end
    end

    it "does not re-check a caller when an unrelated symbol appears" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        File.write(a, "missing_helper()\n")
        File.write(b, "class Thing\n  def existing\n    1\n  end\nend\n")

        session = session_for(configuration(dir))
        guarded_baseline(session)
        # Add an unrelated top-level method — a.rb missed `missing_helper`, not `other`, so it must stay served from
        # cache.
        File.write(b, "class Thing\n  def existing\n    1\n  end\nend\n\ndef other\n  2\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).not_to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end
  end

  # #588 — the same negative edge for a PLUGIN's project-definition gate. `Rigor::Reflection.discovered_method?`
  # is the facade a contribution tier reads to ask "does the project define this method itself?", and a
  # contribution answers BEFORE dispatch reaches the engine's recording accessors (`Scope#user_def_for` /
  # `#singleton_def_for`), so nothing else records the miss. Without the edge a warm recheck kept serving the
  # plugin's answer after the project added the def — rigor-railties' `Rails.logger` gate is the live caller.
  describe "plugin project-definition gate (#588)" do
    def gate_requirer
      lambda do |_name|
        Rigor::Plugin.register(Rigor::Plugin::ProjectDefGateProbe)
        true
      end
    end

    def gate_config(dir)
      Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => [dir], "plugins" => ["project-def-gate"])
      )
    end

    def gate_session(config, dir)
      Rigor::Plugin.unregister!
      described_class.new(configuration: config, paths: [dir], plugin_requirer: gate_requirer)
    end

    # The oracle: a full re-analysis of the edited tree under the same plugin.
    def gate_full_run(config)
      Rigor::Plugin.unregister!
      runner = Rigor::Analysis::Runner.new(
        configuration: config, cache_store: nil, plugin_requirer: gate_requirer
      )
      guarded_run(runner).diagnostics
    end

    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    it "re-checks the gated consumer when the project defines the gated method" do
      Dir.mktmpdir do |dir|
        definer = File.join(dir, "widget.rb")
        consumer = File.join(dir, "consumer.rb")
        File.write(definer, "module Widget\nend\n")
        File.write(consumer, "Rigor.dump_type(Widget.build)\n")

        config = gate_config(dir)
        session = gate_session(config, dir)
        # Baseline: the project defines no `Widget.build`, so the plugin's contribution stands.
        expect(guarded_baseline(session).map(&:message)).to include("dump_type: PluginGadget")

        # The project now answers `Widget.build` itself — the gate declines, so the consumer's cached
        # answer is stale and only the negative edge can pull it back into the closure.
        File.write(definer, "module Widget\n  def self.build\n    1\n  end\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(consumer)
        expect(recheck.diagnostics.map(&:message)).not_to include("dump_type: PluginGadget")
        expect(sorted(recheck.diagnostics)).to eq(sorted(gate_full_run(config)))
      end
    end

    it "does not re-check the gated consumer when an unrelated method appears" do
      Dir.mktmpdir do |dir|
        definer = File.join(dir, "widget.rb")
        consumer = File.join(dir, "consumer.rb")
        File.write(definer, "module Widget\nend\n")
        File.write(consumer, "Rigor.dump_type(Widget.build)\n")

        config = gate_config(dir)
        session = gate_session(config, dir)
        guarded_baseline(session)

        # `Widget.other` is not the symbol the gate missed, so the consumer must stay served from cache —
        # the negative edge is per-symbol, not "any edit to a file the gate looked at".
        File.write(definer, "module Widget\n  def self.other\n    1\n  end\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).not_to include(consumer)
        expect(recheck.diagnostics.map(&:message)).to include("dump_type: PluginGadget")
        expect(sorted(recheck.diagnostics)).to eq(sorted(gate_full_run(config)))
      end
    end
  end

  # Issue #622 — the constant half of the structural tier. A receiver constant that resolves to NOTHING types
  # `Dynamic[top]` and short-circuits *before* the method lookup, so `read_missing(:method, …)` never fired and
  # the read left no edge at all: declaring the constant later never re-checked its readers, and a warm session
  # kept serving the pre-declaration answer. `ExpressionTyper#unresolved_constant_fallback` now records the
  # `class:Name` negative edge that `Incremental.appeared_classes` inverts.
  describe "negative (unresolved-constant) dependencies" do
    it "re-checks a reader of an unresolved constant when an edit declares it" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        File.write(a, "Rails.logger.info(\"x\")\n")
        File.write(b, "class Placeholder\nend\n")

        session = session_for(configuration(dir))
        baseline = guarded_baseline(session)
        # Baseline: nothing declares `Rails`, so the receiver is Dynamic[top] and nothing fires.
        expect(baseline.map(&:rule)).not_to include("call.undefined-method")

        # Declare `Rails` in b.rb — `Rails.logger` now answers `:sym`, which has no `info`.
        File.write(b, "module Rails\n  def self.logger\n    :sym\n  end\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        expect(sorted(recheck.diagnostics).map { |h| h["rule"] }).to include("call.undefined-method")
      end
    end

    it "re-checks a reader of an unresolved qualified constant when a new file declares it" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, "Rails::Config.logger.info(\"x\")\n")

        session = session_for(configuration(dir))
        baseline = guarded_baseline(session)
        expect(baseline.map(&:rule)).not_to include("call.undefined-method")

        # The added file declares the path's LAST segment as a nested class — `appeared_classes` reports it
        # qualified (`Rails::Config`) and `negative_affected` matches it by simple name.
        File.write(File.join(dir, "b.rb"),
                   "module Rails\n  class Config\n    def self.logger\n      :sym\n    end\n  end\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        expect(sorted(recheck.diagnostics).map { |h| h["rule"] }).to include("call.undefined-method")
      end
    end

    # The last segment is the whole key, which rests on every cross-file-resolvable constant form appearing
    # in the pre-pass's class sources. The constant-assigned `Data.define` form is the one that looks like a
    # value assignment and is not, so it is the case that would silently fall out of the key.
    it "re-checks a reader of a constant-assigned Data class when a new file declares it" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, "Rigor.dump_type(Point.new(1, 2))\n")

        session = session_for(configuration(dir))
        baseline = guarded_baseline(session)
        expect(baseline.map(&:message)).to include(a_string_including("Dynamic[top]"))

        File.write(File.join(dir, "b.rb"), "Point = Data.define(:x, :y)\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        expect(recheck.diagnostics.map(&:message)).to include(a_string_including("Point(x: 1, y: 2)"))
      end
    end

    it "does not re-check a constant reader when an unrelated class appears" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        # `Rails` is never declared anywhere in this example, so a.rb's own diagnostics would otherwise be
        # empty throughout — the trailing `Rigor.dump_type` gives the oracle comparison below a real
        # diagnostic to match, per the `write_pair` comment above.
        File.write(a, "Rails.logger.info(\"x\")\nRigor.dump_type(1)\n")
        File.write(b, "class Placeholder\nend\n")

        session = session_for(configuration(dir))
        guarded_baseline(session)
        # a.rb missed `Rails`, not `Unrelated` — the appeared class must not widen the closure to it.
        File.write(b, "class Placeholder\nend\n\nmodule Unrelated\n  def self.thing\n    1\n  end\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).not_to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "re-checks a top-level constant reader when a NESTED class of the same simple name appears" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        # See the sibling example above — `Rails` stays unresolved throughout, so `Rigor.dump_type` is what
        # keeps the oracle comparison below off two coincidentally-equal empty sides.
        File.write(a, "Rails.logger.info(\"x\")\nRigor.dump_type(1)\n")
        File.write(b, "class Placeholder\nend\n")

        session = session_for(configuration(dir))
        guarded_baseline(session)

        # `MyApp::Rails` cannot satisfy a.rb's top-level `Rails` read (a.rb is outside `MyApp`), but the class
        # negatives are matched by SIMPLE name — the grammar `CheckRules`'s override-ancestor negatives already
        # use — so this re-checks a.rb needlessly. Pinned deliberately: over-invalidation is the sound
        # direction, and the merged diagnostics still equal a full run (the read stays unresolved).
        File.write(b, "module MyApp\n  module Rails\n    def self.logger\n      :sym\n    end\n  end\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        expect(sorted(recheck.diagnostics).map { |h| h["rule"] }).not_to include("call.undefined-method")
      end
    end
  end

  # ADR-88 WD3 — `Scope#user_def_site_for` now records the cross-file method edge the sibling `#user_def_for`
  # records, so a caller whose `call.undefined-method` names a project monkey-patch's definition site
  # (`project_definition_site`, a `"path:line"` embedded in the message) re-checks when that site MOVES. A
  # line-shift edit above the def (its body — and so its symbol fingerprint — unchanged) previously left the
  # caller served from cache with the stale line; the file-level edge the recorded read establishes now pulls
  # it back in.
  describe "definition-site line shift (WD3)" do
    it "re-checks the call.undefined-method consumer when the definition site moves" do
      Dir.mktmpdir do |dir|
        patch = File.join(dir, "patch.rb")
        caller = File.join(dir, "caller.rb")
        # patch.rb reopens a core class with a method Rigor will not apply cross-file; the def is at line 2.
        File.write(patch, "class String\n  def shout\n    upcase\n  end\nend\n")
        File.write(caller, "x = \"hi\"\nputs x.shout\n")

        session = session_for(configuration(dir))
        baseline = guarded_baseline(session)
        caller_diag = baseline.find { |d| d.path == caller && d.rule == "call.undefined-method" }
        expect(caller_diag).not_to be_nil
        expect(caller_diag.project_definition_site).to eq("#{patch}:2")

        # Move the def down one line by inserting a blank line above `class String` — the def BODY (its symbol
        # fingerprint) is unchanged, only its `path:line` moves to line 3.
        File.write(patch, "\nclass String\n  def shout\n    upcase\n  end\nend\n")
        recheck = guarded_recheck(session)

        # The caller must be re-analysed (via the WD3 edge) so its cached site line is refreshed; the merged
        # result is byte-identical to a full re-analysis, which now names `patch.rb:3`.
        expect(recheck.affected).to include(caller)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        moved = recheck.diagnostics.find { |d| d.path == caller && d.rule == "call.undefined-method" }
        expect(moved.project_definition_site).to eq("#{patch}:3")
      end
    end
  end

  # ADR-46 slice 3 (structural tier) — files added / removed between runs are reconciled incrementally (the `paths:` set
  # is no longer in the snapshot fingerprint), leaning on the appeared-symbol/class negative edges for additions and the
  # positive dependents of removed files for removals.
  describe "file addition / removal" do
    it "re-checks a caller when a new file defines its missing top-level method" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, "helper()\n")

        session = session_for(configuration(dir))
        baseline = guarded_baseline(session)
        # Baseline: `helper` is undefined, so the diagnostic this test then watches disappear is real.
        expect(baseline.map(&:rule)).to include("call.unresolved-toplevel")

        File.write(File.join(dir, "b.rb"), "def helper\n  1\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        expect(sorted(recheck.diagnostics).map { |h| h["rule"] }).not_to include("call.unresolved-toplevel")
      end
    end

    it "re-checks a subclass when a new file defines its missing superclass" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, "class ASub < NewBase\n  private\n\n  def tag\n    \"y\"\n  end\nend\n")

        session = session_for(configuration(dir))
        guarded_baseline(session)

        File.write(File.join(dir, "b.rb"), "class NewBase\n  def tag\n    \"x\"\n  end\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(a)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "re-checks dependents and drops the cache entry when a file is removed" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        File.write(a, "helper()\n")
        File.write(b, "def helper\n  1\nend\n")

        session = session_for(configuration(dir))
        guarded_baseline(session)

        File.delete(b)
        recheck = guarded_recheck(session)

        # a.rb re-checked (now fires unresolved-toplevel); b.rb gone from the analyzed set and the merged diagnostics.
        expect(recheck.affected).to include(a)
        expect(session.analyzed_files).not_to include(b)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        expect(recheck.diagnostics.map { |d| d.path.to_s }).not_to include(b)
      end
    end

    it "does not re-check unrelated files when a new file is added" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        # `Rigor.dump_type` — see the `write_pair` comment above; a.rb is never re-analyzed here, so its
        # baseline diagnostic is what the oracle comparison below matches.
        File.write(a, "x = 1\nputs x\nRigor.dump_type(x)\n")

        session = session_for(configuration(dir))
        guarded_baseline(session)

        added = File.join(dir, "b.rb")
        File.write(added, "class Wholly\n  def z\n    1\n  end\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).not_to include(a)
        expect(recheck.affected).to include(added)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "reconciles an added file across processes via the snapshot" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        File.write(a, "helper()\n")
        config = configuration(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))
        fp = fingerprint(config, dir)

        # Process 1 — cold baseline. `helper` is undefined yet, so the diagnostic this test then watches
        # disappear is real, not two coincidentally-equal empty sides.
        d1, warm1 = guarded_run_incremental(session_for(config, paths: [dir]), snapshot: snapshot, fingerprint: fp)
        expect(warm1).to be(false)
        expect(d1.map(&:rule)).to include("call.unresolved-toplevel")

        # A new file appears between processes; the roots-keyed fingerprint is unchanged, so the snapshot still loads.
        File.write(File.join(dir, "b.rb"), "def helper\n  1\nend\n")
        diags2, warm2 = guarded_run_incremental(session_for(config, paths: [dir]), snapshot: snapshot,
                                                                                   fingerprint: fp)
        expect(warm2).to be(true)
        expect(sorted(diags2)).to eq(sorted(full_run(dir)))
      end
    end
  end

  describe "#run_incremental (cross-process persistence)" do
    it "is cold on first run and warm (snapshot-reusing) afterwards, matching a full run" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        write_unit(a, prefix: "A")
        write_unit(b, prefix: "B")

        config = configuration(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))
        fp = fingerprint(config, dir)

        # Process 1 — cold: no snapshot yet, full analysis, persists.
        _diags, warm1 = guarded_run_incremental(session_for(config, paths: [dir]), snapshot: snapshot,
                                                                                   fingerprint: fp)
        expect(warm1).to be(false)

        # An edit between "processes" — erase a.rb's diagnostic. Content is not part of the fingerprint, so the snapshot
        # still loads.
        write_unit(a, prefix: "A", reduced: false)

        # Process 2 — warm: a fresh session restores the snapshot and re-analyzes only the changed closure.
        diags2, warm2 = guarded_run_incremental(session_for(config, paths: [dir]), snapshot: snapshot,
                                                                                   fingerprint: fp)
        expect(warm2).to be(true)
        expect(sorted(diags2)).to eq(sorted(full_run(dir)))
      end
    end

    it "falls back to a cold full run when the fingerprint does not match" do
      Dir.mktmpdir do |dir|
        write_unit(File.join(dir, "a.rb"), prefix: "A")
        config = configuration(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))

        guarded_run_incremental(session_for(config, paths: [dir]), snapshot: snapshot, fingerprint: "fp-original")
        # A different fingerprint (config / gem / version drift) → cold.
        _diags, warm = guarded_run_incremental(session_for(config, paths: [dir]), snapshot: snapshot,
                                                                                  fingerprint: "fp-changed")
        expect(warm).to be(false)
      end
    end

    # ADR-87 WD3 — a warm recheck with NO file change leaves the session state byte-equivalent to the
    # snapshot it restored, so `run_incremental` must NOT rewrite it (the 209 ms + 2 MB gitlab null tax). A
    # real edit still persists, and a cold baseline always writes the first snapshot.
    it "skips the snapshot save on a zero-change warm recheck, but writes on cold and on an edit" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        write_unit(a, prefix: "A")
        config = configuration(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))
        fp = fingerprint(config, dir)

        allow(snapshot).to receive(:save).and_call_original

        # Cold baseline: no prior snapshot → MUST save.
        guarded_run_incremental(session_for(config, paths: [dir]), snapshot: snapshot, fingerprint: fp)
        expect(snapshot).to have_received(:save).once

        # Warm, zero changes → MUST NOT save (byte-equivalent snapshot already on disk); the call count stays 1.
        _diags, warm = guarded_run_incremental(session_for(config, paths: [dir]), snapshot: snapshot, fingerprint: fp)
        expect(warm).to be(true)
        expect(snapshot).to have_received(:save).once

        # A real edit → MUST save again so the new state persists (count advances to 2).
        write_unit(a, prefix: "A", reduced: false)
        guarded_run_incremental(session_for(config, paths: [dir]), snapshot: snapshot, fingerprint: fp)
        expect(snapshot).to have_received(:save).twice
      end
    end
  end

  # ADR-85 WD1 — the cross-process win: a warm `--incremental` recheck must serve plugin `#prepare`
  # producers from the disk cache instead of recomputing (the fresh-runner-with-nil-store bug that made a
  # Rails warm incremental ~86% plugin `#prepare`). Two fresh sessions share a cache root + snapshot — the
  # faithful simulation of two `rigor check --incremental` processes, the established pundit /
  # cache-producer cross-process pattern: a fresh `Store` has an empty in-memory memo, so a hit is a real
  # disk read.
  # #146 — editor mode option B: whole-project scope with the editor's buffer substituted for one file. Before
  # this, `--incremental` plus a buffer silently analysed the file on disk.
  describe "#run_buffer_recheck (editor mode option B)" do
    # `other.rb` reads `Widget#name`'s return type, so a buffer that changes it must light up the DEPENDENT —
    # the thing option A (single-file scope) structurally cannot report.
    # The editor's temp file lives OUTSIDE the analysed tree, as a real editor's does — inside it, the buffer
    # would be analysed as a second project file declaring the same class.
    def write_editor_project(dir)
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "widget.rb"), "class Widget\n  def name\n    \"w\"\n  end\nend\n")
      File.write(File.join(dir, "lib", "other.rb"),
                 "class Other\n  def go\n    Widget.new.name.upcase\n  end\nend\n")
      buffer = File.join(dir, "buffer_widget.rb")
      File.write(buffer, "class Widget\n  def name\n    1\n  end\nend\n")
      Rigor::Analysis::BufferBinding.new(
        logical_path: File.join(dir, "lib", "widget.rb"), physical_path: buffer
      )
    end

    def analysis_root(dir)
      File.join(dir, "lib")
    end

    # The run-level gem-RBS info diagnostic is keyed on `.rigor.yml` and recomputed every run; it is not a
    # per-file result and says nothing about scope.
    def project_diagnostics(diagnostics)
      diagnostics.reject { |diagnostic| diagnostic.path.to_s.end_with?(".rigor.yml") }
    end

    def buffer_session(config, dir, buffer)
      described_class.new(configuration: config, paths: [analysis_root(dir)],
                          environment: shared_environment, buffer: buffer)
    end

    def editor_config(dir)
      Rigor::Configuration.new("paths" => [analysis_root(dir)])
    end

    def warm_snapshot(config, dir, snapshot, fingerprint)
      guarded_run_incremental(session_for(config, paths: [analysis_root(dir)]), snapshot: snapshot,
                                                                                fingerprint: fingerprint)
    end

    it "reports a dependent's diagnostic caused by the unsaved buffer, and serves the rest from the snapshot" do
      Dir.mktmpdir do |dir|
        buffer = write_editor_project(dir)
        config = editor_config(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))
        fp = fingerprint(config, analysis_root(dir))

        # Warm the snapshot from the files on disk: clean.
        warm_snapshot(config, dir, snapshot, fp)
        expect(project_diagnostics(full_run(analysis_root(dir)))).to be_empty

        result = guarded_run_buffer_recheck(buffer_session(config, dir, buffer), snapshot: snapshot, fingerprint: fp)

        expect(result.diagnostics.map(&:message)).to include(a_string_matching(/undefined method `upcase' for 1/))
        # The diagnostic is attributed to the DEPENDENT, not the buffer, and the buffer reports under its
        # logical path so the editor highlights the file the user is looking at.
        expect(result.diagnostics.map(&:path)).to all(satisfy { |path| !path.to_s.include?("buffer_widget") })
        expect(result.affected).to include(File.join(dir, "lib", "widget.rb"), File.join(dir, "lib", "other.rb"))
      end
    end

    it "never persists the buffer's state — the next on-disk recheck is unaffected" do
      Dir.mktmpdir do |dir|
        buffer = write_editor_project(dir)
        config = editor_config(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))
        fp = fingerprint(config, analysis_root(dir))
        warm_snapshot(config, dir, snapshot, fp)
        before = File.binread(snapshot.path)

        guarded_run_buffer_recheck(buffer_session(config, dir, buffer), snapshot: snapshot, fingerprint: fp)

        expect(File.binread(snapshot.path)).to eq(before)
        # And the on-disk truth is still what a full run says.
        diags, warm = warm_snapshot(config, dir, snapshot, fp)
        expect(warm).to be(true)
        expect(sorted(diags)).to eq(sorted(full_run(analysis_root(dir))))
      end
    end

    # The closure decision reads the CHANGED files to fingerprint their symbols. Reading the buffer's logical
    # path from disk there looks harmless — the run itself substitutes correctly — but it compares the
    # snapshot against bytes the user already edited away, so every dependent of the unsaved change is served
    # from cache. Caught by this example while building #146; the CLI-level smoke test had passed by luck.
    it "puts the dependents of the UNSAVED change in the closure, not just the buffer's own file" do
      Dir.mktmpdir do |dir|
        buffer = write_editor_project(dir)
        config = editor_config(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))
        fp = fingerprint(config, analysis_root(dir))
        warm_snapshot(config, dir, snapshot, fp)

        result = guarded_run_buffer_recheck(buffer_session(config, dir, buffer), snapshot: snapshot, fingerprint: fp)

        expect(result.affected).to include(File.join(dir, "lib", "other.rb"))
        expect(result.reused).not_to include(File.join(dir, "lib", "other.rb"))
      end
    end

    it "declines (nil) when there is no reusable snapshot, so the caller can fall back to single-file scope" do
      Dir.mktmpdir do |dir|
        buffer = write_editor_project(dir)
        config = editor_config(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))

        # Nothing written yet: a baseline here would repeat on every keystroke, since this session cannot save.
        session = buffer_session(config, dir, buffer)
        fp = fingerprint(config, analysis_root(dir))
        expect(guarded_run_buffer_recheck(session, snapshot: snapshot, fingerprint: fp)).to be_nil
      end
    end

    it "re-analyses the buffer even when its bytes match the file on disk" do
      Dir.mktmpdir do |dir|
        write_editor_project(dir)
        config = editor_config(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))
        fp = fingerprint(config, analysis_root(dir))
        warm_snapshot(config, dir, snapshot, fp)

        identical = File.join(dir, "identical_buffer.rb")
        File.write(identical, File.read(File.join(dir, "lib", "widget.rb")))
        binding_to_identical = Rigor::Analysis::BufferBinding.new(
          logical_path: File.join(dir, "lib", "widget.rb"), physical_path: identical
        )
        result = guarded_run_buffer_recheck(buffer_session(config, dir, binding_to_identical), snapshot: snapshot,
                                                                                               fingerprint: fp)

        # The stat tuple of the temp file says nothing about the logical path, so the buffer is always re-read.
        expect(result.affected).to include(File.join(dir, "lib", "widget.rb"))
        expect(project_diagnostics(result.diagnostics)).to be_empty
      end
    end
  end

  describe "#run_incremental plugin-producer cache reuse (WD1)" do
    let(:probe_producer_id) { "plugin.wd1-cache-probe.probe" }

    def probe_requirer
      lambda do |_name|
        Rigor::Plugin.register(Rigor::Plugin::Wd1CacheProbe)
        true
      end
    end

    def probe_config(dir)
      Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => [dir], "plugins" => ["wd1-cache-probe"])
      )
    end

    def run_probe_incremental(config, dir, snapshot, fingerprint_hex, cache_store)
      # Each "process" unregisters first so the loader's newly-registered diff sees a fresh registration.
      Rigor::Plugin.unregister!
      session = described_class.new(
        configuration: config, paths: [dir], cache_store: cache_store, plugin_requirer: probe_requirer
      )
      guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint_hex)
    end

    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    it "serves the producer from cache on the second process's recheck (no recompute)" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "x = 1\nputs x\n")
        config = probe_config(dir)
        cache_root = File.join(dir, ".rigor", "cache")
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: cache_root)
        fp = fingerprint(config, dir)
        Rigor::Plugin::Wd1CacheProbe.scans = 0

        # Process 1 — cold baseline: the producer misses and computes once, warming the disk cache.
        store1 = Rigor::Cache::Store.new(root: cache_root)
        _d1, warm1 = run_probe_incremental(config, dir, snapshot, fp, store1)
        expect(warm1).to be(false)
        expect(Rigor::Plugin::Wd1CacheProbe.scans).to eq(1)
        expect(store1.stats[:by_producer][probe_producer_id]).to include(misses: 1, writes: 1)

        # Process 2 — warm recheck (fresh session, fresh Store, same disk root): `#prepare` consults the
        # producer, which now serves from disk. The block never re-runs (scans stays 1) and the store records a
        # hit with no miss. The ADR-88 WD1 fact-surface fingerprint reads this producer POST-HOC from the
        # recheck runner (its `producer_value` already memoised by `#prepare`), so it adds no extra `#prepare`
        # and no extra recompute.
        store2 = Rigor::Cache::Store.new(root: cache_root)
        _d2, warm2 = run_probe_incremental(config, dir, snapshot, fp, store2)
        expect(warm2).to be(true)
        expect(Rigor::Plugin::Wd1CacheProbe.scans).to eq(1)
        expect(store2.stats[:by_producer][probe_producer_id]).to include(hits: 1, misses: 0)
      end
    end

    it "recomputes the producer every process when no store is threaded (the pre-WD1 behaviour)" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "x = 1\nputs x\n")
        config = probe_config(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".rigor", "cache"))
        fp = fingerprint(config, dir)
        Rigor::Plugin::Wd1CacheProbe.scans = 0

        run_probe_incremental(config, dir, snapshot, fp, nil)
        run_probe_incremental(config, dir, snapshot, fp, nil)

        # With no store, each process re-runs `#prepare`'s producer block — the regression ADR-85 WD1 fixes.
        # The ADR-88 WD1 fact-surface fingerprint adds no extra scan: it reads the producer POST-HOC from the
        # analysis runner (whose `#prepare` already ran the block), so the count stays at one per process.
        expect(Rigor::Plugin::Wd1CacheProbe.scans).to eq(2)
      end
    end
  end

  # ADR-88 WD1 — the fact-surface fingerprint gates snapshot reuse: a plugin sig/catalog edit that moves the
  # fact surface without touching an analyzed file (a Sorbet `.rbi` outside `signature_paths:`) invalidates the
  # snapshot even though the global fingerprint stays fresh. Opaque plugins (types with no surface) make the
  # snapshot permanently un-reusable.
  describe "#run_incremental fact-surface fingerprint (WD1)" do
    def surface_requirer
      lambda do |_name|
        Rigor::Plugin.register(Rigor::Plugin::Wd1FactSurfaceProbe)
        true
      end
    end

    def opaque_requirer
      lambda do |_name|
        Rigor::Plugin.register(Rigor::Plugin::Wd1OpaqueProbe)
        true
      end
    end

    def surface_config(dir)
      Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => [dir], "plugins" => ["wd1-fact-surface"])
      )
    end

    def run_surface(config, dir, snapshot, fingerprint_hex, requirer)
      Rigor::Plugin.unregister!
      session = described_class.new(
        configuration: config, paths: [dir], cache_store: nil, plugin_requirer: requirer
      )
      guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint_hex)
    end

    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    it "warm-reuses the snapshot when the plugin fact surface is unchanged" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "x = 1\nputs x\n")
        config = surface_config(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".rigor", "cache"))
        fp = fingerprint(config, dir)
        Rigor::Plugin::Wd1FactSurfaceProbe.state = "s1"

        _d1, warm1 = run_surface(config, dir, snapshot, fp, surface_requirer)
        expect(warm1).to be(false) # cold baseline

        _d2, warm2 = run_surface(config, dir, snapshot, fp, surface_requirer)
        expect(warm2).to be(true) # unchanged fact surface + unchanged files → warm
      ensure
        Rigor::Plugin::Wd1FactSurfaceProbe.state = "s1"
      end
    end

    it "runs a full analysis (not warm) when the fact surface changed but no analyzed file did" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "x = 1\nputs x\n")
        config = surface_config(dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".rigor", "cache"))
        fp = fingerprint(config, dir)

        Rigor::Plugin::Wd1FactSurfaceProbe.state = "s1"
        run_surface(config, dir, snapshot, fp, surface_requirer) # cold baseline, stores digest(s1)

        # Flip the fact surface — as a Sorbet `.rbi` edit outside `signature_paths:` would — WITHOUT touching
        # a.rb. The global fingerprint is unchanged, but the fact digest now differs.
        Rigor::Plugin::Wd1FactSurfaceProbe.state = "s2"
        session = described_class.new(
          configuration: config, paths: [dir], cache_store: nil, plugin_requirer: surface_requirer
        )
        Rigor::Plugin.unregister!
        _diags, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fp)

        expect(warm).to be(false) # snapshot invalidated → full analysis
        expect(session.fact_surface_invalidated?).to be(true)
        expect(session.opaque_plugin_ids).to be_empty
      ensure
        Rigor::Plugin::Wd1FactSurfaceProbe.state = "s1"
      end
    end

    it "never warm-reuses (and names the plugin) when a contributing plugin declares no fingerprint surface" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "x = 1\nputs x\n")
        config = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge("paths" => [dir], "plugins" => ["wd1-opaque"])
        )
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".rigor", "cache"))
        fp = fingerprint(config, dir)

        run_surface(config, dir, snapshot, fp, opaque_requirer) # baseline

        session = described_class.new(
          configuration: config, paths: [dir], cache_store: nil, plugin_requirer: opaque_requirer
        )
        Rigor::Plugin.unregister!
        _diags, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fp)

        expect(warm).to be(false) # opaque → never warm, even with unchanged files
        expect(session.opaque_plugin_ids).to eq(["wd1-opaque"])
      end
    end

    it "makes the invalidation decision independent of the session's worker count (pooled/sequential parity)" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "x = 1\nputs x\n")
        config = surface_config(dir)
        Rigor::Plugin::Wd1FactSurfaceProbe.state = "s1"

        # A SEQUENTIAL session reads the fingerprint POST-HOC from its analysis runner (`from_registry`); a
        # POOLED session (whose main process SKIPS `#prepare`) falls back to the always-sequential probe. Both
        # must reach the SAME fact-surface digest and the SAME opacity verdict — the reuse decision cannot
        # diverge by pool mode. The sequential path here is exercised after a `baseline` seeds `@last_runner`;
        # the pooled path via a fresh session (no run yet → probe fallback).
        sequential = described_class.new(
          configuration: config, paths: [dir], cache_store: nil, plugin_requirer: surface_requirer, workers: 0
        )
        Rigor::Plugin.unregister!
        guarded_baseline(sequential) # seeds @last_runner so `compute_plugin_fact_fingerprint` takes the post-hoc path
        d_seq = sequential.send(:compute_plugin_fact_fingerprint)

        pooled = described_class.new(
          configuration: config, paths: [dir], cache_store: nil, plugin_requirer: surface_requirer, workers: 4
        )
        Rigor::Plugin.unregister!
        d_pool = pooled.send(:compute_plugin_fact_fingerprint) # no run → probe fallback (the pooled path)

        expect(d_pool.digest).to eq(d_seq.digest)
        expect(d_pool.opaque_plugin_ids).to eq(d_seq.opaque_plugin_ids)
      ensure
        Rigor::Plugin::Wd1FactSurfaceProbe.state = "s1"
      end
    end
  end

  # ADR-87 WD1 (PR item 1) — change detection stats rather than SHA-256s unchanged files.
  describe "stat-tier change detection" do
    it "detects no change for an unchanged recheck without hashing any content bytes" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        write_unit(a, prefix: "A")
        write_unit(b, prefix: "B")
        session = session_for(configuration(dir))
        guarded_baseline(session)

        # `Digest::SHA256.file` is the sole content-hashing call; the stat tier must not reach it for an
        # unchanged file (the recon anomaly: the old path SHA-256'd every file every recheck).
        allow(Digest::SHA256).to receive(:file).and_call_original
        changed = session.send(:changed_paths, session.analyzed_files)

        expect(changed).to be_empty
        expect(Digest::SHA256).not_to have_received(:file)
      end
    end

    it "detects a touched-but-identical file as fresh (moved stat tuple, unchanged content)" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        write_unit(a, prefix: "A")
        session = session_for(configuration(dir))
        guarded_baseline(session)

        # Move mtime/ctime without changing content (a `git checkout` / `touch`); the digest is the authority.
        future = Time.now + 5
        File.utime(future, future, a)

        expect(session.send(:changed_paths, [a])).to be_empty
      end
    end

    it "detects an edited file" do
      Dir.mktmpdir do |dir|
        a = File.join(dir, "a.rb")
        write_unit(a, prefix: "A")
        session = session_for(configuration(dir))
        guarded_baseline(session)

        write_unit(a, prefix: "A", reduced: false)

        expect(session.send(:changed_paths, [a])).to eq([a])
      end
    end
  end

  # ADR-46 (PR item 2) — the `--incremental` closure re-analysis is wired to the fork pool.
  describe "fork-pool wiring" do
    def write_greeter(dir, body:)
      base = File.join(dir, "greeter_base.rb")
      File.write(base, "class GreeterBase\n  def greet\n    #{body}\n  end\nend\n")
      base
    end

    it "matches a full re-analysis with workers > 0 across successive edits" do
      skip "fork is unavailable on this platform" unless Process.respond_to?(:fork)
      Dir.mktmpdir do |dir|
        write_greeter(dir, body: '"hi"')
        # A subclass whose implicit-self call resolves `greet` cross-file (records an edge to greeter_base.rb)
        # plus filler files so the pool distributes real slices.
        File.write(File.join(dir, "greeter_sub.rb"), <<~RUBY)
          class GreeterSub < GreeterBase
            def announce
              greet
            end
          end
        RUBY
        3.times { |i| write_unit(File.join(dir, "u#{i}.rb"), prefix: "U#{i}") }

        session = described_class.new(configuration: configuration(dir), environment: shared_environment, workers: 3)
        guarded_baseline(session)

        write_greeter(dir, body: '"edited"')
        recheck = guarded_recheck(session)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))

        # A second edit exercises the graph the FIRST pooled recheck rebuilt from the marshalled records.
        write_greeter(dir, body: '"again"')
        recheck2 = guarded_recheck(session)
        expect(sorted(recheck2.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end
  end

  # ADR-46 slice 4 singleton extension (PR item 3) — a class/singleton-method body edit gets symbol
  # granularity: its closure scopes to the method's call sites, not the file's coarse dependents.
  describe "singleton-method symbol granularity" do
    def write_util(dir, unused_body:)
      util = File.join(dir, "util.rb")
      File.write(util, <<~RUBY)
        class Util
          def self.used
            "u"
          end

          def self.unused
            #{unused_body}
          end
        end
      RUBY
      util
    end

    it "scopes a class-method body edit to that method's callers (not the file's dependents)" do
      Dir.mktmpdir do |dir|
        util = write_util(dir, unused_body: '"n"')
        ca = File.join(dir, "caller_a.rb")
        cb = File.join(dir, "caller_b.rb")
        # `ca` is served from cache below (`reused`), so its `Rigor.dump_type` is what keeps the oracle
        # comparison off two coincidentally-equal empty sides for the MERGE half specifically — util.rb
        # itself carries no diagnostic either. See the `write_pair` comment further down for the pattern.
        File.write(ca, "class CallerA\n  def go\n    Rigor.dump_type(1)\n    Util.used\n  end\nend\n")
        File.write(cb, "class CallerB\n  def go\n    Util.used\n  end\nend\n")

        session = session_for(configuration(dir))
        guarded_baseline(session)

        # Edit the UNUSED class method's body — nobody calls it, so no caller is affected.
        write_util(dir, unused_body: '"CHANGED"')
        recheck = guarded_recheck(session)

        expect(recheck.changed).to eq(Set[util])
        expect(recheck.affected).to eq(Set[util])
        expect(recheck.reused).to include(ca, cb)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "re-checks the callers of an edited class method" do
      Dir.mktmpdir do |dir|
        util = File.join(dir, "util.rb")
        File.write(util, "class Util\n  def self.used\n    \"u\"\n  end\nend\n")
        ca = File.join(dir, "caller_a.rb")
        File.write(ca, "class CallerA\n  def go\n    Util.used\n  end\nend\n")

        session = session_for(configuration(dir))
        guarded_baseline(session)

        # Edit the CALLED class method's body — its caller must be re-analysed.
        File.write(util, "class Util\n  def self.used\n    \"CHANGED\"\n  end\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(util, ca)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end
  end

  # B1 — the bundle-equality propagation gate: a changed file whose CODE (comments stripped) is unchanged is
  # declaration-stable, so its ancestry / file-level dependents are skipped. Every case also asserts the
  # merged diagnostics equal a full re-analysis (the `--verify-incremental` soundness property).
  describe "bundle-equality propagation gate" do
    # A base class (with a leading comment) and a subclass that reads its ancestry (an ancestry edge to the
    # base), so an edit to the base normally re-checks the subclass.
    def write_pair(dir, base_comment:)
      base = File.join(dir, "base.rb")
      File.write(base, <<~RUBY)
        # #{base_comment}
        class Base
          def greet
            "hi"
          end
        end
      RUBY
      sub = File.join(dir, "sub.rb")
      # `Rigor.dump_type` gives every case below a REAL diagnostic to compare against `full_run` — none of
      # this section's edits (a comment, a CONST/ivar/cvar/global value) otherwise produces one, so without
      # it the oracle-equality assertions below would hold on two coincidentally-equal EMPTY lists under a
      # crashed check rule just as readily as on a correct recheck (issue #683 review).
      unless File.exist?(sub)
        File.write(sub,
                   "class Sub < Base\n  def announce\n    Rigor.dump_type(greet)\n  end\nend\n")
      end
      [base, sub]
    end

    it "collapses an in-place comment edit to the edited file, skipping its dependents" do
      Dir.mktmpdir do |dir|
        base, sub = write_pair(dir, base_comment: "the original comment")
        session = session_for(configuration(dir))
        guarded_baseline(session)

        # Reword the comment — same line count, so the code (and every def's start line) is byte-identical.
        write_pair(dir, base_comment: "a completely different but single-line comment")
        recheck = guarded_recheck(session)

        expect(recheck.changed).to eq(Set[base])
        expect(recheck.affected).to eq(Set[base]) # sub is skipped despite its ancestry edge to base.rb
        expect(recheck.reused).to include(sub)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "still re-checks dependents on a body edit (the gate must not fire on a code change)" do
      Dir.mktmpdir do |dir|
        base, sub = write_pair(dir, base_comment: "c")
        session = session_for(configuration(dir))
        guarded_baseline(session)

        # A body edit changes the code fingerprint — the gate must NOT skip the dependent.
        File.write(base, "# c\nclass Base\n  def greet\n    \"HELLO\"\n  end\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(base, sub)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "takes the same skip decision on a pooled (workers > 0) recheck as on a sequential one" do
      skip "fork is unavailable on this platform" unless Process.respond_to?(:fork)
      Dir.mktmpdir do |dir|
        base, sub = write_pair(dir, base_comment: "the original comment")
        session = described_class.new(configuration: configuration(dir), environment: shared_environment,
                                      workers: 2)
        guarded_baseline(session)

        # The gate decision (`affected_closure` → `analyze_set`) happens session-side BEFORE worker
        # dispatch, so a pooled recheck must skip exactly the same dependents a sequential one does.
        write_pair(dir, base_comment: "a different comment, same line count")
        recheck = guarded_recheck(session)

        expect(recheck.affected).to eq(Set[base])
        expect(recheck.reused).to include(sub)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    # Fabricated-edit soundness battery — one per surface the audit flagged as a suspect (constant, class
    # ivar, class cvar, global). Each is a CODE edit, so the gate does not fire and the dependent is
    # re-checked; every case asserts byte-identical-to-full, the soundness backstop.
    def write_state_holder(dir, assignment)
      reader = assignment.split(" = ").first
      base = File.join(dir, "base.rb")
      File.write(base, <<~RUBY)
        # note
        class Base
          #{assignment}
          def read
            #{reader}
          end
        end
      RUBY
      # See the matching comment in `write_pair` above — `Rigor.dump_type` keeps the oracle comparisons
      # below off two coincidentally-equal empty lists.
      unless File.exist?(File.join(dir, "consumer.rb"))
        File.write(File.join(dir, "consumer.rb"),
                   "class Consumer < Base\n  def use\n    Rigor.dump_type(read)\n  end\nend\n")
      end
      base
    end

    {
      "a cross-file constant value" => ["CONST = 1", "CONST = 2"],
      "a class ivar write" => ["@field = 1", "@field = 2"],
      "a class cvar write" => ["@@shared = 1", "@@shared = 2"],
      "a program global write" => ["$g = 1", "$g = 2"]
    }.each do |desc, (before, after)|
      it "stays byte-identical to a full run when #{desc} changes (gate declines a code edit)" do
        Dir.mktmpdir do |dir|
          write_state_holder(dir, before)
          session = session_for(configuration(dir))
          guarded_baseline(session)

          write_state_holder(dir, after)
          recheck = guarded_recheck(session)

          # A code edit → the gate declines → the merged result still equals a full re-analysis.
          expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
        end
      end
    end

    it "disables the gate when a comment-ingesting plugin (inline-RBS) is configured" do
      # inline-RBS reads comments as types, so a comment edit could change a cross-file signature the code
      # fingerprint ignores — the gate must fall back to today's full closure. Tested at the gate logic so it
      # does not depend on the plugin gem being on the load path.
      inline = Rigor::Configuration.new("paths" => ["x"], "plugins" => [{ "gem" => "rigor-rbs-inline" }])
      ordinary = Rigor::Configuration.new("paths" => ["x"], "plugins" => ["rigor-sorbet"])

      expect(described_class.new(configuration: inline).send(:comment_ingesting_plugin_loaded?)).to be(true)
      expect(described_class.new(configuration: ordinary).send(:comment_ingesting_plugin_loaded?)).to be(false)

      # Issue #135 self-mutation sweep — the `"gem"` case above never reaches the `|| entry["id"]` fallback
      # (a Hash `||` short-circuits on the first truthy operand), so a manifest-`"id"`-only entry (no `"gem"`
      # key) is the only fixture that proves the fallback read, not just the primary one.
      id_only = Rigor::Configuration.new("paths" => ["x"], "plugins" => [{ "id" => "rigor-rbs-inline" }])
      expect(described_class.new(configuration: id_only).send(:comment_ingesting_plugin_loaded?)).to be(true)

      # With the gate disabled, EVERY changed file is unstable (dependents never skipped), even one whose
      # declaration signature matched.
      session = described_class.new(configuration: inline)
      session.instance_variable_set(:@seed_bundles, { "a.rb" => { declaration_signature: "sig" } })
      expect(session.send(:declaration_unstable, ["a.rb"], { "a.rb" => "sig" })).to eq(["a.rb"])
    end
  end

  # ADR-89 WD1 — the declaration-shape gate. It generalises B1 (comment-only) to BODY edits: a changed file
  # whose per-def SIGNATURE shape (parameter structure / visibility / ancestry / member layout / def line,
  # bodies excluded) is unchanged is declaration-stable, so its ancestry / file-level dependents are skipped
  # even when the code changed. Symbol dependents of a changed method body are still re-checked (the ADR-46
  # symbol tier). Every case asserts byte-identical-to-full — the `--verify-incremental` soundness property.
  describe "declaration-shape propagation gate (WD1)" do
    # A base class carrying an inherited instance method `common` and a utility singleton method `build`, an
    # ANCESTRY dependent that subclasses it and calls the INHERITED `common` (so it reads App's ancestry — a
    # real ancestry edge — but does NOT call `build`), and a SYMBOL dependent that calls `build`. The S5a
    # gitlab shape at unit scale: a `build` body edit should re-check the `build` caller but skip the model
    # (which depends only on App's declaration + `common`, both unchanged).
    def write_wd1_tree(dir, body:, arity: "(value)", extra_method: false)
      added = extra_method ? "def self.added; 1; end" : "# no extra"
      File.write(File.join(dir, "app.rb"), <<~RUBY)
        class App
          def common
            "c"
          end
          def self.build#{arity}
            #{body}
          end
          #{added}
        end
      RUBY
      # Ancestry dependent: reads App's ancestry to resolve the inherited `common`; never touches `build`.
      write_once(File.join(dir, "model.rb"), "class Model < App\n  def name\n    common\n  end\nend\n")
      # `Rigor.dump_type(1)` is deliberately UNRELATED to `App.build` (whose arity/return the tests below
      # edit) — see the `write_pair` comment above for why the oracle comparisons need a real diagnostic
      # somewhere in the merged result at all.
      write_once(File.join(dir, "caller.rb"),
                 "class Caller\n  def go\n    Rigor.dump_type(1)\n    App.build(1)\n  end\nend\n")
    end

    it "collapses a same-line body edit to the edited file + its symbol callers, skipping ancestry dependents" do
      Dir.mktmpdir do |dir|
        app = File.join(dir, "app.rb")
        model = File.join(dir, "model.rb")
        write_wd1_tree(dir, body: 'prefix = "p"; prefix + value.to_s')
        session = session_for(configuration(dir))
        guarded_baseline(session)

        # model.rb IS a recorded ancestry dependent of app.rb (it reads App's ancestry to resolve `common`) —
        # under B1 (code fingerprint) a body edit would re-check it. WD1 must skip it.
        expect(session.instance_variable_get(:@ancestry_dependents)[app]).to include(model)

        # Same-line body edit: rename the local. No signature, line, or ancestry change → App is
        # declaration-stable → the ancestry dependent (model.rb) is skipped.
        write_wd1_tree(dir, body: 'pre = "p"; pre + value.to_s')
        recheck = guarded_recheck(session)

        expect(recheck.changed).to eq(Set[app])
        expect(recheck.affected).not_to include(model) # ancestry dependent skipped — the WD1 collapse
        expect(recheck.reused).to include(model)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "propagates an arity change to ancestry dependents (declaration signature moves, not swallowed)" do
      Dir.mktmpdir do |dir|
        app = File.join(dir, "app.rb")
        model = File.join(dir, "model.rb")
        write_wd1_tree(dir, body: "value", arity: "(value)")
        session = session_for(configuration(dir))
        guarded_baseline(session)

        # An arity change moves App.build's declaration signature (its parameter shape), so app is NOT
        # declaration-stable — its ancestry dependents re-check (WD1 must not swallow a signature change),
        # unlike the same-line body edit above which skips them.
        write_wd1_tree(dir, body: "value", arity: "(value, extra)")
        # Directly assert the arity edit is NOT declaration-stable — before the recheck refreshes the bundle.
        sigs = Rigor::Inference::ScopeIndexer.scan_summary_for_paths([app])[:declaration_signatures]
        expect(session.send(:declaration_unstable, [app], sigs)).to eq([app])

        recheck = guarded_recheck(session)
        expect(recheck.affected).to include(model) # ancestry dependent re-checks on a declaration change
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "propagates a visibility change to ancestry dependents (declaration signature moves)" do
      Dir.mktmpdir do |dir|
        base = File.join(dir, "base.rb")
        File.write(base, "class Base\n  def tag\n    \"x\"\n  end\nend\n")
        sub = File.join(dir, "sub.rb")
        # `Rigor.dump_type(1)` — see the `write_pair` comment above.
        File.write(sub, "class Sub < Base\n  def relay\n    Rigor.dump_type(1)\n    tag\n  end\nend\n")
        session = session_for(configuration(dir))
        guarded_baseline(session)

        # Add `private` — Base#tag's body is byte-identical, only its visibility (a declaration surface the
        # ADR-35 override rule and private-call diagnostics consume) changes.
        File.write(base, "class Base\n  private\n  def tag\n    \"x\"\n  end\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(sub)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "propagates an added method to negative (appeared-symbol) dependents" do
      Dir.mktmpdir do |dir|
        write_wd1_tree(dir, body: "value")
        # A consumer that calls a method not yet defined on App — records a negative edge.
        consumer = File.join(dir, "consumer.rb")
        File.write(consumer, "class Consumer\n  def use\n    App.added\n  end\nend\n")
        session = session_for(configuration(dir))
        guarded_baseline(session)

        # Define `added` — it APPEARS, so the negative-dependent consumer must re-check.
        write_wd1_tree(dir, body: "value", extra_method: true)
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(consumer)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "propagates a return-visible body edit to symbol dependents (changed fingerprint)" do
      Dir.mktmpdir do |dir|
        caller = File.join(dir, "caller.rb")
        write_wd1_tree(dir, body: '"a"')
        session = session_for(configuration(dir))
        guarded_baseline(session)

        # A same-line literal change moves App.build's return (Constant["a"] → Constant["b"]) — its symbol
        # fingerprint changes, so the symbol dependent (caller.rb) re-checks even though the declaration is
        # stable (ancestry deps still collapse).
        write_wd1_tree(dir, body: '"b"')
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(caller)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end
  end

  # ADR-89 WD2 — the observed-key return-summary gate. A declaration-stable changed def whose return type is
  # unchanged at every previously-observed call key AND whose content-mutation effects are unchanged is
  # behaviourally stable, so its symbol dependents are skipped. The gate is restricted to defs whose only
  # cross-file body surfaces are return + content-mutation (no ivar/cvar write, no yield, no self-call), so
  # the two-surface comparison is complete. Every case asserts byte-identical-to-full (soundness).
  describe "observed-key return-summary gate (WD2)" do
    # A gate-ELIGIBLE leaf helper (no self-call / ivar write / yield) and a caller that dispatches to it.
    # `body` is the helper's return expression; `probe` toggles a same-line, return-PRESERVING refactor.
    def write_wd2_tree(dir, body:)
      File.write(File.join(dir, "fmt.rb"), <<~RUBY)
        class Fmt
          def self.label(value)
            #{body}
          end
        end
      RUBY
      # See the `write_pair` comment above — `Rigor.dump_type(1)` is stable across every body variant.
      write_once(File.join(dir, "user.rb"),
                 "class User\n  def show\n    Rigor.dump_type(1)\n    Fmt.label(\"x\")\n  end\nend\n")
    end

    it "skips symbol dependents on a return-preserving refactor (returns unchanged at observed keys)" do
      Dir.mktmpdir do |dir|
        fmt = File.join(dir, "fmt.rb")
        user = File.join(dir, "user.rb")
        write_wd2_tree(dir, body: 'prefix = "tag-"; prefix + value')
        session = session_for(configuration(dir))
        guarded_baseline(session)

        # user.rb IS a symbol dependent of Fmt.label (it calls it) — a naive body-fingerprint gate re-checks it.
        expect(session.instance_variable_get(:@symbol_dependents).keys).to include([fmt, "Fmt.label"])
        # The baseline observed Fmt.label at User's call key and persisted its return summary.
        expect(session.instance_variable_get(:@return_summaries)).to have_key([fmt, "Fmt.label"])

        # A same-line, return-preserving refactor: rename the local. The return at every observed key is
        # unchanged, so WD2 skips the symbol dependent user.rb.
        write_wd2_tree(dir, body: 'pre = "tag-"; pre + value')
        recheck = guarded_recheck(session)

        expect(recheck.changed).to eq(Set[fmt])
        expect(recheck.affected).not_to include(user) # symbol dependent skipped — the WD2 collapse
        expect(recheck.reused).to include(user)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "propagates a return-visible body edit to symbol dependents (return moved at observed key)" do
      Dir.mktmpdir do |dir|
        user = File.join(dir, "user.rb")
        write_wd2_tree(dir, body: '"a-" + value')
        session = session_for(configuration(dir))
        guarded_baseline(session)

        # The return literal moves ("a-…" → "b-…"), so the re-evaluation at the observed key mismatches and
        # WD2 keeps the symbol dependent.
        write_wd2_tree(dir, body: '"b-" + value')
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(user)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "propagates a mutation-effect change (a param the callee starts mutating) to symbol dependents" do
      Dir.mktmpdir do |dir|
        # An eligible def that mutates its array argument's content, and a caller that reads the argument
        # after the call — its post-call type depends on the callee's arg-flooring effect.
        acc = File.join(dir, "acc.rb")
        File.write(acc, "class Acc\n  def self.fill(items)\n    items\n  end\nend\n")
        caller = File.join(dir, "caller.rb")
        # `Rigor.dump_type(1)` — see the `write_pair` comment above.
        File.write(caller, <<~RUBY)
          class Reader
            def run
              Rigor.dump_type(1)
              a = [1]
              Acc.fill(a)
              a.first
            end
          end
        RUBY
        session = session_for(configuration(dir))
        guarded_baseline(session)

        # The callee STARTS mutating its argument's content — a caller-visible arg-flooring effect change,
        # even though the return (`items`) is nominally unchanged. WD2's effect channel keeps the dependent.
        File.write(acc, "class Acc\n  def self.fill(items)\n    items << 2\n    items\n  end\nend\n")
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(caller)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end

    it "keeps dependents for an INELIGIBLE def (ivar write) even when returns match" do
      Dir.mktmpdir do |dir|
        st = File.join(dir, "st.rb")
        # A def that writes an ivar is ineligible: a same-class caller could consume its definite-assignment,
        # a surface WD2 does not compare — so its dependents always re-check (the conservative direction).
        File.write(st, "class St\n  def self.tag(value)\n    @seen = value\n    \"t-\" + value\n  end\nend\n")
        user = File.join(dir, "user.rb")
        # `Rigor.dump_type(1)` — see the `write_pair` comment above.
        File.write(user, "class User\n  def show\n    Rigor.dump_type(1)\n    St.tag(\"x\")\n  end\nend\n")
        session = session_for(configuration(dir))
        guarded_baseline(session)
        # The summary IS harvested (harvest is unconditional); the GATE rejects it because the def is
        # ineligible (an ivar write), so the dependent is never dropped.
        expect(session.instance_variable_get(:@return_summaries)).to have_key([st, "St.tag"])

        # A same-line return-preserving refactor: WD2 must still keep the dependent (ineligible def).
        File.write(st, <<~RUBY)
          class St
            def self.tag(value)
              @seen = value
              prefix = "t-"; prefix + value
            end
          end
        RUBY
        recheck = guarded_recheck(session)

        expect(recheck.affected).to include(user)
        expect(sorted(recheck.diagnostics)).to eq(sorted(full_run(dir)))
      end
    end
  end

  # ADR-67 WD6c lift — `parameter_inference:` composes with the incremental session. The collector pre-pass
  # is whole-project by design, so each recheck recomputes the seed table and diffs it against the
  # snapshot's copy: a changed entry re-checks the CALLEE file (whose own text never moved) and its symbol
  # dependents. `Rigor.dump_type` on the seeded parameter makes the seed byte-visible in the diagnostics —
  # the WD6b guard means a seed change never ADDS a negative diagnostic, so without it the full-run oracle
  # comparison would be vacuous.
  describe "parameter_inference composition (ADR-67 WD6c lift)" do
    def pi_configuration(dir)
      Rigor::Configuration.new("paths" => [dir], "parameter_inference" => true)
    end

    def pi_full_run(dir)
      runner = Rigor::Analysis::Runner.new(
        configuration: pi_configuration(dir), cache_store: nil, environment: shared_environment
      )
      guarded_run(runner).diagnostics
    end

    def pi_session(dir)
      described_class.new(configuration: pi_configuration(dir), environment: shared_environment)
    end

    def write_callee(dir)
      path = File.join(dir, "callee.rb")
      write_once(path, <<~RUBY)
        class Callee
          def run(x)
            Rigor.dump_type(x)
          end
        end
      RUBY
      path
    end

    def write_caller(dir, arg:, extra: nil)
      path = File.join(dir, "caller.rb")
      File.write(path, <<~RUBY)
        class Caller
          def go
            #{extra}
            Callee.new.run(#{arg})
          end
        end
      RUBY
      path
    end

    def dump_messages(diagnostics)
      diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
    end

    it "re-checks the callee when a caller's argument type changes (the callee's own text unchanged)" do
      Dir.mktmpdir do |dir|
        callee = write_callee(dir)
        caller_path = write_caller(dir, arg: "1")
        session = pi_session(dir)
        baseline = guarded_baseline(session)
        expect(dump_messages(baseline)).to eq(["dump_type: Integer"])

        write_caller(dir, arg: '"s"')
        recheck = guarded_recheck(session)

        # The file-digest tier sees only the caller; the param-table diff is what pulls the callee in.
        expect(recheck.changed).to eq(Set[caller_path])
        expect(recheck.affected).to include(callee)
        expect(dump_messages(recheck.diagnostics)).to eq(["dump_type: String"])
        expect(sorted(recheck.diagnostics)).to eq(sorted(pi_full_run(dir)))
      end
    end

    it "keeps the callee cached when a caller edit leaves the argument types unchanged" do
      Dir.mktmpdir do |dir|
        callee = write_callee(dir)
        caller_path = write_caller(dir, arg: "1")
        session = pi_session(dir)
        guarded_baseline(session)

        write_caller(dir, arg: "1", extra: "@noise = :extra")
        recheck = guarded_recheck(session)

        # Same seed table on both sides of the diff → no param invalidation; the callee is served from
        # cache. This is the precision half — the diff must not degrade every caller edit into a
        # whole-project re-check.
        expect(recheck.affected).to eq(Set[caller_path])
        expect(recheck.reused).to include(callee)
        expect(sorted(recheck.diagnostics)).to eq(sorted(pi_full_run(dir)))
      end
    end

    it "invalidates across the persisted snapshot (the diff runs against Marshal-restored types)" do
      Dir.mktmpdir do |dir|
        callee = write_callee(dir)
        write_caller(dir, arg: "1")
        config = pi_configuration(dir)
        fp = fingerprint(config, dir)
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))

        cold_session = described_class.new(configuration: config, environment: shared_environment)
        _cold, warm_first = guarded_run_incremental(cold_session, snapshot: snapshot, fingerprint: fp)
        expect(warm_first).to be(false)

        write_caller(dir, arg: '"s"')
        session = described_class.new(configuration: config, environment: shared_environment)
        diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fp)

        expect(warm).to be(true)
        expect(dump_messages(diagnostics)).to eq(["dump_type: String"])
        expect(sorted(diagnostics)).to eq(sorted(pi_full_run(dir)))
        expect(session.analyzed_files).to include(callee)
      end
    end

    it "matches the full-run oracle on a no-edit warm recheck without re-collecting the table" do
      Dir.mktmpdir do |dir|
        write_callee(dir)
        write_caller(dir, arg: "1")
        session = pi_session(dir)
        guarded_baseline(session)
        oracle = sorted(pi_full_run(dir)) # computed BEFORE the mock — the oracle's own collect is legitimate

        # No file moved → the collector's inputs are unchanged, so the recheck must skip the whole-project
        # re-collect (the ADR-87 null-recheck fast path) and still serve the exact baseline result.
        allow(Rigor::Inference::ParameterInferenceCollector).to receive(:collect)
        recheck = guarded_recheck(session)

        expect(Rigor::Inference::ParameterInferenceCollector).not_to have_received(:collect)
        expect(recheck.affected).to be_empty
        expect(sorted(recheck.diagnostics)).to eq(oracle)
      end
    end
  end
end
