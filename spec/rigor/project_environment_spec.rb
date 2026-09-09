# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::ProjectEnvironment do
  # Every `Environment.for_project` keyword that is NOT a dependency-discovery axis. The gate below asserts
  # that whatever remains after subtracting this list is spelled by
  # {Rigor::ProjectEnvironment.dependency_discovery_options}.
  #
  # An allowlist of the non-discovery names, rather than a `bundler_* / rbs_collection_*` name pattern: the
  # gap being guarded (issue #821) is a keyword that reaches `check` and no other build entry, and a name
  # pattern can only catch the ones that happen to be named after today's two axes. A third dependency
  # source — a `gemspec_*`, a `gem_sig_*` — would be exactly the same bug and would pass a pattern silently.
  # The cost is that a new NON-discovery keyword has to be classified here; the failure message says so, and
  # that classification is the adjudication the gate exists to force.
  def non_discovery_keywords
    %i[
      root
      libraries
      signature_paths
      cache_store
      plugin_registry
      dependency_source_index
      rbs_extended_reporter
      boundary_cross_reporter
      source_rbs_synthesis_reporter
      synthetic_method_index
      project_patched_methods
      source_files
    ].freeze
  end

  # A configuration carrying a non-default value for every discovery axis, so a call site that passes a
  # keyword but hard-codes its value is distinguishable from one that reads the configuration.
  let(:configuration) do
    Rigor::Configuration.new(
      "bundler" => {
        "bundle_path" => "vendor/spec-bundle",
        "auto_detect" => true,
        "lockfile" => "spec/Gemfile.lock"
      },
      "rbs_collection" => {
        "lockfile" => "spec/rbs_collection.lock",
        "auto_detect" => true
      }
    )
  end

  def for_project_keywords
    Rigor::Environment.method(:for_project).parameters
                      .filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
  end

  # Captures the keywords one block's `Environment.for_project` call is made with, without paying a real
  # environment build.
  def capture_for_project_keywords
    captured = nil
    allow(Rigor::Environment).to receive(:for_project) do |**kwargs|
      captured = kwargs
      Rigor::Environment.new(rbs_loader: nil)
    end
    yield
    captured
  end

  describe ".dependency_discovery_options" do
    # Issue #821 was one build entry missing these axes entirely; #864 gated the other producer of the RBS
    # env against its own build method's keyword list. This is the same shape one level up: the helper is
    # the single spelling of the discovery axes, so a new axis added to `for_project` and threaded only
    # through `check` has to fail here rather than ship as a probe/sig-gen divergence.
    it "spells every dependency-discovery keyword Environment.for_project accepts" do
      missing = for_project_keywords - non_discovery_keywords - described_class.dependency_discovery_options(
        configuration
      ).keys

      expect(missing).to be_empty,
                         "Environment.for_project accepts #{missing.join(', ')}, which " \
                         "ProjectEnvironment.dependency_discovery_options does not pass. Every command that " \
                         "types against the project's real dependencies goes through that helper, so an " \
                         "axis missing from it reaches `rigor check` alone and the probes / sig-gen build a " \
                         "different type universe (issue #821). Add it to the helper — or, if it is not a " \
                         "dependency-discovery axis, to non_discovery_keywords in this spec."
    end

    # The keyword names double as the configuration's reader names, so each value can be checked against the
    # configuration it was built from. A hard-coded default in the helper fails here.
    it "reads each value from the configuration reader of the same name" do
      options = described_class.dependency_discovery_options(configuration)

      expect(options).to eq(options.keys.to_h { |key| [key, configuration.public_send(key)] })
      expect(options.values).to include("vendor/spec-bundle", "spec/rbs_collection.lock", true)
    end
  end

  describe "the call sites that must use the helper" do
    let(:discovery_options) { described_class.dependency_discovery_options(configuration) }

    it "is used by .build" do
      captured = capture_for_project_keywords do
        described_class.build(configuration: configuration, source_files: [])
      end

      expect(captured).to include(discovery_options)
    end

    it "is used by .bare" do
      captured = capture_for_project_keywords { described_class.bare(configuration) }

      expect(captured).to include(discovery_options)
    end

    it "is used by PoolCoordinator#build_runner_environment" do
      coordinator = Rigor::Analysis::Runner::PoolCoordinator.new(
        configuration: configuration, cache_store: nil, explain: false, workers: 1,
        collect_stats: false, buffer: nil, environment_override: nil,
        rbs_extended_reporter: nil, boundary_cross_reporter: nil,
        source_rbs_synthesis_reporter: nil, snapshots: nil,
        plugin_registry: -> {}, dependency_source_index: -> {},
        synthetic_method_index: -> {}, project_patched_methods: -> {},
        analyze_file: ->(_path, _environment) { [] }
      )

      captured = capture_for_project_keywords { coordinator.build_runner_environment }

      expect(captured).to include(discovery_options)
    end

    # The remaining build entries are asserted at source level rather than behaviourally: each is
    # reachable only through machinery whose construction is the expensive part and unrelated to what is
    # being checked — `WorkerSession.new` materialises the plugin registry and runs every plugin's
    # `#prepare` before its `for_project` call is reached, `LanguageServer::ProjectContext#environment`
    # first drives a whole project pre-pass through a second `Runner`, and `SigGen`'s two collectors build
    # their environment from inside a full generation run. Driving them here would buy a slower, flakier
    # restatement of what the file already says unambiguously: the helper is splatted in, and no discovery
    # keyword is spelled by hand.
    #
    # `pool_coordinator.rb` builds twice — the runner environment pinned behaviourally above and
    # `prewarm_rbs_cache_for_pool` — so the whole file is read here too: that second build spelled the five
    # axes literally, correct on the day it was written and one added axis away from divergence, which is
    # what issue #882 retired along with `CLI::UnusedCommand`'s missing axes. Every file that reaches
    # `Environment.for_project` outside {ProjectEnvironment} itself is now in this list; the helper's own
    # `minimal` fail-soft floor is the one deliberate omission of the axes in the codebase.
    {
      "Analysis::WorkerSession" => "lib/rigor/analysis/worker_session.rb",
      "LanguageServer::ProjectContext" => "lib/rigor/language_server/project_context.rb",
      "Analysis::Runner::PoolCoordinator" => "lib/rigor/analysis/runner/pool_coordinator.rb",
      "CLI::UnusedCommand" => "lib/rigor/cli/unused_command.rb"
    }.each do |label, path|
      it "is splatted into #{label}'s environment build" do
        source = File.read(File.expand_path("../../#{path}", __dir__))

        expect(source).to include("**ProjectEnvironment.dependency_discovery_options(")
        expect(source).not_to include("rbs_collection_lockfile:")
      end
    end

    # SigGen reaches the axes one hop further out: both collectors delegate the whole build to
    # {ProjectEnvironment.build}, which the behavioural example above already pins to the helper. What is
    # checked here is only that the delegation is still what they do.
    {
      "SigGen::Generator" => "lib/rigor/sig_gen/generator.rb",
      "SigGen::ObservationCollector" => "lib/rigor/sig_gen/observation_collector.rb"
    }.each do |label, path|
      it "is reached by #{label} through ProjectEnvironment.build" do
        source = File.read(File.expand_path("../../#{path}", __dir__))

        expect(source).to include("ProjectEnvironment.build(configuration:")
        expect(source).not_to include("rbs_collection_lockfile:")
      end
    end
  end
end
