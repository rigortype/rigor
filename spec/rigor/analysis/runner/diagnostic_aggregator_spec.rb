# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# #194 slice 1 — the `plugin_loader.load-error` diagnostic names the file a plugin loaded from when the
# require SUCCEEDED but a later step (config / instantiation) failed, so an engine↔plugin version skew is a
# one-line diagnosis; a require that failed outright keeps its original message. That message composition
# lives in the aggregator, so it is exercised here directly against a hand-built registry — no real load
# path, no `$LOADED_FEATURES`.
#
# Issue #135 self-mutation sweep — the giant >300 LOC engine-file tier. This file's own convention spec
# originally covered only `plugin_load_diagnostics` (2 examples); the fused mutation pass found every other
# stream in the file (each project-level diagnostic emitter the aggregator concatenates in
# `pre_file_diagnostics`, plus the post-analysis streams `Runner` drains after `analyze_files`) had NO
# dedicated coverage — 166 survivors across nearly every method. The examples below exercise each stream
# directly with realistic per-domain fixtures (a real `Rigor::RbsExtended::Reporter` /
# `BoundaryCrossReporter` / `SourceRbsSynthesisReporter` rather than a mock, since all three are cheap
# accumulators with a public `#record*` API — building a real one and reading it back is no more code than
# a double and additionally proves the accumulator's own contract).
#
# Duck-typed against exactly what `#location_fields` / `#location_path` read (`respond_to?(:buffer)`,
# `buffer.name`, `start_line`, `start_column`) — the production contract is structural (any `RBS::Location`
# satisfies it), so a plain top-level Struct is the real contract, not a stand-in for one. Named constants
# (not block-local) so `RSpec/LeakyConstantDeclaration` stays clean, matching `registry_spec.rb`'s pattern.
RigorDiagnosticAggregatorSpecFakeBuffer = Struct.new(:name)
RigorDiagnosticAggregatorSpecFakeLocation = Struct.new(:buffer, :start_line, :start_column)

RSpec.describe Rigor::Analysis::Runner::DiagnosticAggregator do
  let(:services) do
    Rigor::Plugin::Services.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new
    )
  end

  # Every reader defaults to the same inert value the old two-example spec baked in, so each `describe`
  # below only overrides the collaborator its stream actually reads. `configuration:` is a plain object (not
  # behind a reader — the real aggregator takes it positionally too), so tests that need a non-default
  # `.rigor.yml` pass a partial Hash; `Configuration#initialize` falls back to `DEFAULTS` per-key.
  def build_aggregator(configuration: Rigor::Configuration.new(Rigor::Configuration::DEFAULTS), # rubocop:disable Metrics/ParameterLists
                       registry: Rigor::Plugin::Registry::EMPTY,
                       dependency_source_index: Rigor::Analysis::DependencySourceInference::Index::EMPTY,
                       rbs_extended_reporter: Rigor::RbsExtended::Reporter.new,
                       boundary_cross_reporter: Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter.new,
                       source_rbs_synthesis_reporter: Rigor::Plugin::SourceRbsSynthesisReporter.new,
                       pool_mode: false,
                       cached_plugin_prepare_diagnostics: [],
                       pre_eval_diagnostics_from_scanner: [],
                       synthesized_namespaces_snapshot: nil,
                       quarantined_signatures_snapshot: [],
                       env_build_failure_snapshot: nil,
                       conformance_results_snapshot: nil)
    described_class.new(
      configuration: configuration,
      rbs_extended_reporter: rbs_extended_reporter,
      boundary_cross_reporter: boundary_cross_reporter,
      source_rbs_synthesis_reporter: source_rbs_synthesis_reporter,
      plugin_registry: -> { registry },
      dependency_source_index: -> { dependency_source_index },
      pool_mode: -> { pool_mode },
      cached_plugin_prepare_diagnostics: -> { cached_plugin_prepare_diagnostics },
      pre_eval_diagnostics_from_scanner: -> { pre_eval_diagnostics_from_scanner },
      synthesized_namespaces_snapshot: -> { synthesized_namespaces_snapshot },
      quarantined_signatures_snapshot: -> { quarantined_signatures_snapshot },
      env_build_failure_snapshot: -> { env_build_failure_snapshot },
      conformance_results_snapshot: -> { conformance_results_snapshot }
    )
  end

  def load_error(message, resolved_path: nil)
    error = Rigor::Plugin::LoadError.new(message, plugin_ref: "x")
    error.resolved_path = resolved_path
    error
  end

  describe "plugin_load_diagnostics" do
    it "appends the resolved file to a post-require failure so it names the loaded plugin copy" do
      registry = Rigor::Plugin::Registry.new(
        load_errors: [
          load_error('plugin "x" raised during init: RuntimeError: boom',
                     resolved_path: "/checkout/plugins/rigor-x/lib/rigor-x.rb")
        ]
      )

      diagnostic = build_aggregator(registry: registry).plugin_load_diagnostics.first

      expect(diagnostic.rule).to eq("load-error")
      expect(diagnostic.source_family).to eq(:plugin_loader)
      expect(diagnostic.message).to eq(
        'plugin "x" raised during init: RuntimeError: boom ' \
        "(loaded from /checkout/plugins/rigor-x/lib/rigor-x.rb)"
      )
    end

    it "leaves a require-failure message unchanged when no file was resolved" do
      registry = Rigor::Plugin::Registry.new(
        load_errors: [load_error('could not load plugin gem "rigor-y": cannot load such file')]
      )

      diagnostic = build_aggregator(registry: registry).plugin_load_diagnostics.first

      expect(diagnostic.message).to eq('could not load plugin gem "rigor-y": cannot load such file')
      expect(diagnostic.message).not_to include("loaded from")
    end
  end

  describe "pre_eval_diagnostics" do
    it "flags a configured pre_eval path that does not exist on disk" do
      configuration = Rigor::Configuration.new("pre_eval" => ["does/not/exist.rb"])

      diagnostics = build_aggregator(configuration: configuration).pre_eval_diagnostics

      expect(diagnostics.size).to eq(1)
      expect(diagnostics.first.rule).to eq("pre-eval.file-not-found")
      expect(diagnostics.first.severity).to eq(:error)
      expect(diagnostics.first.message).to include('"does/not/exist.rb"')
    end

    it "does not flag a pre_eval path that exists, and folds in the scanner's parse-error stream" do
      Dir.mktmpdir do |dir|
        real_path = File.join(dir, "boot.rb")
        File.write(real_path, "1")
        configuration = Rigor::Configuration.new("pre_eval" => [real_path])
        scanner_hash = { path: "app/models/x.rb", line: 3, column: 5,
                         message: "unexpected token", severity: :warning, rule: "pre-eval.parse-error" }

        diagnostics = build_aggregator(
          configuration: configuration, pre_eval_diagnostics_from_scanner: [scanner_hash]
        ).pre_eval_diagnostics

        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.rule).to eq("pre-eval.parse-error")
        expect(diagnostics.first.path).to eq("app/models/x.rb")
        expect(diagnostics.first.line).to eq(3)
        expect(diagnostics.first.column).to eq(5)
        expect(diagnostics.first.severity).to eq(:warning)
        expect(diagnostics.first.message).to eq("unexpected token")
        expect(diagnostics.first.source_family).to eq(:builtin)
      end
    end
  end

  describe "dependency_source_diagnostics" do
    it "surfaces one warning per unresolvable source_inference gem, naming the gem and the reason" do
      index = Rigor::Analysis::DependencySourceInference::Index.new(
        unresolvable: [
          Rigor::Analysis::DependencySourceInference::GemResolver::Unresolvable.new(
            gem_name: "not-a-real-gem", reason: :not_in_bundle
          )
        ]
      )

      diagnostic = build_aggregator(dependency_source_index: index).dependency_source_diagnostics.first

      expect(diagnostic.rule).to eq("dynamic.dependency-source.gem-not-found")
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to include('"not-a-real-gem"')
      expect(diagnostic.message).to include("not_in_bundle")
    end
  end

  describe "dependency_source_budget_diagnostics" do
    it "names the gem and the configured per-gem cap when a gem's walk exceeded its budget" do
      configuration = Rigor::Configuration.new("dependencies" => { "budget_per_gem" => 1500 })
      index = Rigor::Analysis::DependencySourceInference::Index.new(budget_exceeded: ["huge_gem"])

      diagnostic = build_aggregator(
        configuration: configuration, dependency_source_index: index
      ).dependency_source_budget_diagnostics.first

      expect(diagnostic.rule).to eq("dynamic.dependency-source.budget-exceeded")
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to include('"huge_gem"')
      expect(diagnostic.message).to include("1500")
    end
  end

  describe "dependency_source_config_conflict_diagnostics" do
    it "surfaces one warning per real dedupe-time mode conflict, verbatim from Dependencies#warnings" do
      # `Dependencies.from_h` dedupes `source_inference:` entries by gem name; two entries for the SAME gem
      # with DIFFERENT `mode:` is exactly the `includes:`-chain ambiguity `dedupe_entries` warns about (a
      # `Dependencies` instance is frozen at construction, so this drives the real merge rather than stubbing
      # the frozen `#warnings` reader).
      configuration = Rigor::Configuration.new(
        "dependencies" => { "source_inference" => [
          { "gem" => "foo", "mode" => "when_missing" },
          { "gem" => "foo", "mode" => "full" }
        ] }
      )

      diagnostic = build_aggregator(
        configuration: configuration
      ).dependency_source_config_conflict_diagnostics.first

      expect(diagnostic.rule).to eq("dynamic.dependency-source.config-conflict")
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to eq(
        'dependencies.source_inference[].gem "foo" declared with conflicting modes ' \
        "(:when_missing vs :full); the later (:full) wins."
      )
    end
  end

  describe "rbs_coverage_diagnostics" do
    it "reports an :info diagnostic naming every locked gem none of the four RBS sources cover" do
      locked = { "totally-uncovered-gem" => Rigor::Environment::LockfileResolver::LockedGem.new(
        name: "totally-uncovered-gem", version: "1.0.0", platform: "ruby"
      ) }
      allow(Rigor::Environment::LockfileResolver).to receive(:locked_gems).and_return(locked)
      allow(Rigor::Environment::BundleSigDiscovery).to receive(:discover).and_return([])
      allow(Rigor::Environment::RbsCollectionDiscovery).to receive(:discover).and_return([])

      diagnostic = build_aggregator.rbs_coverage_diagnostics.first

      expect(diagnostic.rule).to eq("rbs.coverage.missing-gem")
      expect(diagnostic.severity).to eq(:info)
      expect(diagnostic.message).to include("totally-uncovered-gem")
      expect(diagnostic.message).to include("1 gem(s)")
    end

    # Two names, both under the 5-sample cap: with a SINGLE uncovered gem `sample.join(', ')` reads
    # identically under any separator (`["x"].join(nil) == "x"`), masking a dropped/altered `, `. Naming both
    # in one assertion bites that mutant.
    it "joins multiple uncovered gem names with a comma" do
      locked = %w[first-gem second-gem].to_h do |name|
        [name, Rigor::Environment::LockfileResolver::LockedGem.new(name: name, version: "1.0.0", platform: "ruby")]
      end
      allow(Rigor::Environment::LockfileResolver).to receive(:locked_gems).and_return(locked)
      allow(Rigor::Environment::BundleSigDiscovery).to receive(:discover).and_return([])
      allow(Rigor::Environment::RbsCollectionDiscovery).to receive(:discover).and_return([])

      diagnostic = build_aggregator.rbs_coverage_diagnostics.first

      expect(diagnostic.message).to include("first-gem, second-gem")
    end

    it "is silent when the project has no lockfile (nothing locked to classify)" do
      allow(Rigor::Environment::LockfileResolver).to receive(:locked_gems).and_return({})

      expect(build_aggregator.rbs_coverage_diagnostics).to eq([])
    end
  end

  describe "rbs_inline_annotation_hint_diagnostics" do
    def expansion_for(*paths)
      { files: paths, errors: [] }
    end

    it "stays silent when the rbs-inline library already resolves" do
      allow(Rigor::Configuration).to receive(:rbs_inline_library_resolvable?).and_return(true)

      expect(build_aggregator.rbs_inline_annotation_hint_diagnostics(expansion_for)).to eq([])
    end

    it "stays silent when an rbs-inline plugin is already active, even with the library absent" do
      allow(Rigor::Configuration).to receive(:rbs_inline_library_resolvable?).and_return(false)
      plugin_class = Class.new(Rigor::Plugin::Base) { manifest(id: "rbs-inline", version: "0.1.0") }
      registry = Rigor::Plugin::Registry.new(plugins: [plugin_class.new(services: services)])

      diagnostics = build_aggregator(registry: registry).rbs_inline_annotation_hint_diagnostics(expansion_for)

      expect(diagnostics).to eq([])
    end

    it "names the first file carrying an inline-RBS-shaped comment when the library is absent" do
      allow(Rigor::Configuration).to receive(:rbs_inline_library_resolvable?).and_return(false)
      Dir.mktmpdir do |dir|
        plain = File.join(dir, "plain.rb")
        annotated = File.join(dir, "annotated.rb")
        File.write(plain, "def foo; end\n")
        File.write(annotated, "#: (Integer) -> String\ndef foo(x); end\n")

        diagnostics = build_aggregator.rbs_inline_annotation_hint_diagnostics(expansion_for(plain, annotated))

        expect(diagnostics.size).to eq(1)
        expect(diagnostics.first.rule).to eq("rbs.coverage.inline-annotations-unsynthesized")
        expect(diagnostics.first.severity).to eq(:info)
        expect(diagnostics.first.message).to include("annotated.rb")
      end
    end

    it "stays silent when no scanned file carries the annotation shape" do
      allow(Rigor::Configuration).to receive(:rbs_inline_library_resolvable?).and_return(false)
      Dir.mktmpdir do |dir|
        plain = File.join(dir, "plain.rb")
        File.write(plain, "def foo; end\n# :nodoc:\n")

        expect(build_aggregator.rbs_inline_annotation_hint_diagnostics(expansion_for(plain))).to eq([])
      end
    end
  end

  describe "rbs_quarantined_signature_diagnostics" do
    it "names an absolute-path quarantined file relative to the project root" do
      # `relative_signature_path` only strips the cwd prefix when the loader-recorded path is absolute AND
      # under it — a plain relative fixture (`"sig/broken.rbs"`) never enters that branch at all.
      absolute = File.join(Dir.pwd, "sig/broken.rbs")
      quarantined = [[absolute, 4]]

      diagnostic = build_aggregator(
        quarantined_signatures_snapshot: quarantined
      ).rbs_quarantined_signature_diagnostics.first

      expect(diagnostic.rule).to eq("rbs.coverage.quarantined-signature")
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to include("1 RBS file(s)")
      expect(diagnostic.message).to include("sig/broken.rbs")
      expect(diagnostic.message).not_to include(Dir.pwd)
    end

    it "samples the first five names, comma-joined, and counts the rest into a `, and N more` suffix" do
      # Seven quarantined files: exercises the `quarantined.size > sample_size` suffix arm (line 426) AND the
      # multi-name `sample.join(', ')` separator (line 432) — a single-item fixture can distinguish neither
      # (a lone element renders identically under any separator, and 1 is never > 5).
      quarantined = (1..7).map { |i| ["sig/broken_#{i}.rbs", 1] }

      diagnostic = build_aggregator(
        quarantined_signatures_snapshot: quarantined
      ).rbs_quarantined_signature_diagnostics.first

      expect(diagnostic.message).to include("7 RBS file(s)")
      expect(diagnostic.message).to include(
        "sig/broken_1.rbs, sig/broken_2.rbs, sig/broken_3.rbs, sig/broken_4.rbs, sig/broken_5.rbs, " \
        "and 2 more"
      )
    end

    it "is silent when nothing was quarantined" do
      expect(build_aggregator(quarantined_signatures_snapshot: []).rbs_quarantined_signature_diagnostics).to eq([])
    end
  end

  describe "rbs_environment_build_failed_diagnostics" do
    it "names the raised error class, the first line, and the conflicting signature files, comma-joined" do
      # Two conflicting buffers (not one) — `sample.join(', ')` (line 448) needs a multi-element array to
      # distinguish a separator mutation from the identical single-element rendering.
      failure = [RBS::DuplicatedDeclarationError, "Foo::Bar is duplicated",
                 ["sig/conflict_a.rbs", "sig/conflict_b.rbs"]]

      diagnostic = build_aggregator(
        env_build_failure_snapshot: failure
      ).rbs_environment_build_failed_diagnostics.first

      expect(diagnostic.rule).to eq("rbs.coverage.environment-build-failed")
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to include("RBS::DuplicatedDeclarationError")
      expect(diagnostic.message).to include("Foo::Bar is duplicated")
      expect(diagnostic.message).to include("sig/conflict_a.rbs, sig/conflict_b.rbs")
    end

    it "is silent (no `Conflicting signature file(s):` clause) when the failure names no buffers" do
      failure = [RBS::DuplicatedDeclarationError, "Foo::Bar is duplicated", []]

      diagnostic = build_aggregator(env_build_failure_snapshot: failure).rbs_environment_build_failed_diagnostics.first

      expect(diagnostic.message).not_to include("Conflicting signature file(s)")
    end

    it "is silent when the environment built successfully (no failure snapshot)" do
      expect(build_aggregator(env_build_failure_snapshot: nil).rbs_environment_build_failed_diagnostics).to eq([])
    end
  end

  describe "rbs_synthesized_namespace_diagnostics" do
    it "names the synthesized namespaces" do
      diagnostic = build_aggregator(
        synthesized_namespaces_snapshot: ["Foo::Bar"]
      ).rbs_synthesized_namespace_diagnostics.first

      expect(diagnostic.rule).to eq("rbs.coverage.synthesized-namespace")
      expect(diagnostic.severity).to eq(:info)
      expect(diagnostic.message).to include("Foo::Bar")
    end

    it "samples the first five names, comma-joined, and counts the rest into a `, and N more` suffix" do
      # Seven namespaces: exercises the `synthesized.size > sample_size` suffix arm (line 474) AND the
      # multi-name `sample.join(', ')` separator (line 481) — a single-item fixture distinguishes neither.
      namespaces = (1..7).map { |i| "Foo::Ns#{i}" }

      diagnostic = build_aggregator(
        synthesized_namespaces_snapshot: namespaces
      ).rbs_synthesized_namespace_diagnostics.first

      expect(diagnostic.message).to include("7 RBS namespace(s)")
      expect(diagnostic.message).to include(
        "Foo::Ns1, Foo::Ns2, Foo::Ns3, Foo::Ns4, Foo::Ns5, and 2 more"
      )
    end

    it "is silent when the snapshot is nil (pool mode never fills it)" do
      expect(build_aggregator(synthesized_namespaces_snapshot: nil).rbs_synthesized_namespace_diagnostics).to eq([])
    end

    it "is silent when the snapshot is an empty set" do
      expect(build_aggregator(synthesized_namespaces_snapshot: []).rbs_synthesized_namespace_diagnostics).to eq([])
    end
  end

  describe "conforms_to_diagnostics" do
    it "names the missing methods for an Unsatisfied conformance record" do
      record = Rigor::RbsExtended::ConformanceChecker::Unsatisfied.new(
        class_name: "MyClass", interface_name: "_Comparable", missing_methods: [:<=>], location: nil
      )

      diagnostic = build_aggregator(conformance_results_snapshot: [record]).conforms_to_diagnostics.first

      expect(diagnostic.rule).to eq("rbs_extended.unsatisfied-conformance")
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to include("MyClass")
      expect(diagnostic.message).to include("_Comparable")
      expect(diagnostic.message).to include("`#<=>`")
      expect(diagnostic.message).to include("required method")
      # Pluralization boundary — a single missing method reads "required method" (singular); the neighbouring
      # multi-method case below exercises the `#{count} required methods` (plural) arm of the same ternary.
    end

    it "pluralizes the required-method count and reports at the record's real location" do
      location = RigorDiagnosticAggregatorSpecFakeLocation.new(
        RigorDiagnosticAggregatorSpecFakeBuffer.new("lib/my_class.rb"), 10, 2
      )
      record = Rigor::RbsExtended::ConformanceChecker::Unsatisfied.new(
        class_name: "MyClass", interface_name: "_Comparable", missing_methods: %i[< >], location: location
      )

      diagnostic = build_aggregator(conformance_results_snapshot: [record]).conforms_to_diagnostics.first

      expect(diagnostic.message).to include("2 required methods")
      # Two names (not one) — `missing_methods.map { … }.join(', ')` (line 397) needs a multi-element array
      # to distinguish a separator mutation from the single-element rendering the case above cannot.
      expect(diagnostic.message).to include("`#<`, `#>`")
      expect(diagnostic.path).to eq("lib/my_class.rb")
      expect(diagnostic.line).to eq(10)
      expect(diagnostic.column).to eq(3)
    end

    it "names the method and the incompatibility detail for an IncompatibleSignature record" do
      record = Rigor::RbsExtended::ConformanceChecker::IncompatibleSignature.new(
        class_name: "MyClass", interface_name: "_Comparable", method_name: :<=>,
        detail: "return type is not a subtype", location: nil
      )

      diagnostic = build_aggregator(conformance_results_snapshot: [record]).conforms_to_diagnostics.first

      expect(diagnostic.rule).to eq("rbs_extended.unsatisfied-conformance")
      expect(diagnostic.method_name).to eq(:<=>)
      expect(diagnostic.message).to include("MyClass#<=>")
      expect(diagnostic.message).to include("return type is not a subtype")
    end

    it "flags an UnresolvedInterface record on the dynamic/info channel, naming the unresolved interface" do
      record = Rigor::RbsExtended::ConformanceChecker::UnresolvedInterface.new(
        class_name: "MyClass", interface_name: "_Nope", location: nil
      )

      diagnostic = build_aggregator(conformance_results_snapshot: [record]).conforms_to_diagnostics.first

      expect(diagnostic.rule).to eq("dynamic.rbs-extended.unresolved")
      expect(diagnostic.severity).to eq(:info)
      expect(diagnostic.message).to include("MyClass")
      expect(diagnostic.message).to include("_Nope")
    end

    it "is silent when the snapshot is nil or empty" do
      expect(build_aggregator(conformance_results_snapshot: nil).conforms_to_diagnostics).to eq([])
      expect(build_aggregator(conformance_results_snapshot: []).conforms_to_diagnostics).to eq([])
    end
  end

  describe "rbs_extended_reporter_diagnostics" do
    it "drains unresolved-payload and lossy-projection events into distinct diagnostic rules" do
      reporter = Rigor::RbsExtended::Reporter.new
      reporter.record_unresolved(payload: "rigor:v1:wat", source_location: nil)
      reporter.record_lossy_projection(head: "pick_of", source_location: nil)

      diagnostics = build_aggregator(rbs_extended_reporter: reporter).rbs_extended_reporter_diagnostics

      unresolved = diagnostics.find { |d| d.rule == "dynamic.rbs-extended.unresolved" }
      lossy = diagnostics.find { |d| d.rule == "dynamic.shape.lossy-projection" }
      expect(unresolved.message).to include("rigor:v1:wat")
      expect(lossy.message).to include("pick_of")
      expect(diagnostics.map(&:severity).uniq).to eq([:info])
    end

    it "is silent when the reporter accumulated nothing" do
      expect(build_aggregator.rbs_extended_reporter_diagnostics).to eq([])
    end
  end

  describe "source_rbs_synthesis_diagnostics" do
    it "reports a synthesis failure naming the plugin, the message, and the no-contribution fallback" do
      reporter = Rigor::Plugin::SourceRbsSynthesisReporter.new
      reporter.record(plugin_id: "rigor-rbs-inline", path: "lib/x.rb", message: "unexpected token", kind: :failed)

      diagnostic = build_aggregator(source_rbs_synthesis_reporter: reporter).source_rbs_synthesis_diagnostics.first

      expect(diagnostic.rule).to eq("source-rbs-synthesis-failed")
      expect(diagnostic.path).to eq("lib/x.rb")
      expect(diagnostic.message).to include("rigor-rbs-inline")
      expect(diagnostic.message).to include("unexpected token")
    end

    it "reports a not-honoured annotation on its own, distinct rule that does not distrust the whole file" do
      reporter = Rigor::Plugin::SourceRbsSynthesisReporter.new
      reporter.record(plugin_id: "rigor-rbs-inline", path: "lib/y.rb", message: "unknown directive @wat",
                      kind: :not_honoured)

      diagnostic = build_aggregator(source_rbs_synthesis_reporter: reporter).source_rbs_synthesis_diagnostics.first

      expect(diagnostic.rule).to eq("source-rbs-annotation-not-honoured")
      expect(diagnostic.message).to include("rigor-rbs-inline")
      expect(diagnostic.message).to include("unknown directive @wat")
      expect(diagnostic.message).to include("other annotations are unaffected")
    end

    it "is silent when the reporter accumulated nothing" do
      expect(build_aggregator.source_rbs_synthesis_diagnostics).to eq([])
    end
  end

  describe "boundary_cross_diagnostics" do
    it "names the class, method, RBS display, and the crossing gem" do
      reporter = Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter.new
      reporter.record(class_name: "Foo", method_name: :bar, gem_name: "foo_gem", rbs_display: "() -> Integer")

      diagnostic = build_aggregator(boundary_cross_reporter: reporter).boundary_cross_diagnostics.first

      expect(diagnostic.rule).to eq("dynamic.dependency-source.boundary-cross")
      expect(diagnostic.severity).to eq(:info)
      expect(diagnostic.message).to include("Foo#bar")
      expect(diagnostic.message).to include("() -> Integer")
      expect(diagnostic.message).to include("foo_gem")
    end

    it "is silent when the reporter accumulated nothing" do
      expect(build_aggregator.boundary_cross_diagnostics).to eq([])
    end
  end

  describe "pre_file_diagnostics ordering" do
    # The class doc's constraint: "callers MUST NOT reorder the concatenation". One diagnostic per stream
    # (each with a distinguishable `rule`) proves both that every stream is actually invoked AND that the
    # documented order (`plugin_load, prepare, pre_eval, dependency_source, budget, config_conflict,
    # rbs_coverage, rbs_inline_hint, expansion errors`) still holds — a `+` swapped for the wrong operand
    # (nil_inject/type_swap) would either drop a stream or shuffle this list.
    it "concatenates every pre-file stream in the documented order" do # rubocop:disable RSpec/ExampleLength
      registry = Rigor::Plugin::Registry.new(load_errors: [load_error("plugin load boom")])
      index = Rigor::Analysis::DependencySourceInference::Index.new(
        unresolvable: [
          Rigor::Analysis::DependencySourceInference::GemResolver::Unresolvable.new(
            gem_name: "g", reason: :not_in_bundle
          )
        ],
        budget_exceeded: ["g2"]
      )
      configuration = Rigor::Configuration.new(
        "dependencies" => { "source_inference" => [
          { "gem" => "foo", "mode" => "when_missing" },
          { "gem" => "foo", "mode" => "full" }
        ] }
      )
      allow(Rigor::Environment::LockfileResolver).to receive(:locked_gems).and_return({})
      allow(Rigor::Configuration).to receive(:rbs_inline_library_resolvable?).and_return(true)

      aggregator = build_aggregator(
        configuration: configuration, registry: registry, dependency_source_index: index,
        cached_plugin_prepare_diagnostics: [
          Rigor::Analysis::Diagnostic.new(path: ".rigor.yml", line: 1, column: 1, message: "prepare",
                                          severity: :error, rule: "prepare-rule")
        ],
        pre_eval_diagnostics_from_scanner: [
          { path: "x.rb", line: 1, column: 1, message: "scan", severity: :warning, rule: "pre-eval.parse-error" }
        ]
      )
      expansion = { files: [], errors: [
        Rigor::Analysis::Diagnostic.new(path: "bad.rb", line: 1, column: 1, message: "no such file",
                                        severity: :error)
      ] }

      rules = aggregator.pre_file_diagnostics(expansion).map(&:rule)

      expect(rules).to eq(%w[
        load-error prepare-rule pre-eval.parse-error dynamic.dependency-source.gem-not-found
        dynamic.dependency-source.budget-exceeded dynamic.dependency-source.config-conflict
      ] + [nil])
    end

    it "omits the coordinator prepare-diagnostic slot under pool mode (each worker re-runs prepare)" do
      aggregator = build_aggregator(
        pool_mode: true,
        cached_plugin_prepare_diagnostics: [
          Rigor::Analysis::Diagnostic.new(path: ".rigor.yml", line: 1, column: 1, message: "prepare",
                                          severity: :error, rule: "prepare-rule")
        ]
      )

      rules = aggregator.pre_file_diagnostics({ files: [], errors: [] }).map(&:rule)

      expect(rules).not_to include("prepare-rule")
    end
  end

  describe "apply_severity_profile" do
    it "delegates to SeverityStamp, dropping a rule the profile resolves to :off" do
      configuration = Rigor::Configuration.new("severity_overrides" => { "some.rule" => "off" })
      diagnostics = [
        Rigor::Analysis::Diagnostic.new(path: "a.rb", line: 1, column: 1, message: "kept", severity: :warning,
                                        rule: "kept.rule"),
        Rigor::Analysis::Diagnostic.new(path: "b.rb", line: 1, column: 1, message: "dropped", severity: :warning,
                                        rule: "some.rule")
      ]

      result = build_aggregator(configuration: configuration).apply_severity_profile(diagnostics)

      expect(result.map(&:rule)).to eq(["kept.rule"])
    end

    it "preserves the structured fields when the profile re-stamps a diagnostic's severity" do
      # `def.return-type-mismatch` is authored :error and the default balanced profile resolves it to
      # :warning, so this exercises SeverityStamp's rebuild path — the one that must carry
      # receiver_type / method_name / project_definition_site through, not just the positional fields.
      diagnostic = Rigor::Analysis::Diagnostic.new(
        path: "a.rb", line: 3, column: 1, message: "return-type mismatch on `to_s'",
        severity: :error, rule: "def.return-type-mismatch",
        receiver_type: "String", method_name: "to_s", project_definition_site: "a.rb:3"
      )

      result = build_aggregator.apply_severity_profile([diagnostic]).first

      expect(result.severity).to eq(:warning)
      expect(result.method_name).to eq("to_s")
      expect(result.receiver_type).to eq("String")
      expect(result.project_definition_site).to eq("a.rb:3")
    end
  end
end
